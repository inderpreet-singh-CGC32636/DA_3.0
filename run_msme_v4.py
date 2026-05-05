# %% Imports & Config
"""
MSME DA Pool Selection — 5-Stage Pipeline  (v4)
================================================
v3 change: MAX_DPD_EVER derived inline from full DPD history (msme_dpd_history.sql)
v4 change: #%% cell markers added for interactive VS Code / Jupyter execution

Stage 1  SQL   : simple_msme_eligible.sql + msme_assets.sql + msme_dpd_history.sql
                 + msme_bounce.sql + restructure.sql + abhfl_serviceable.sql
Stage 2  Python: age, MOB, CIBIL, LTV, residential_pct, DPD flags (6M/18M/ever),
                 bounce counts, HAS_UDYAM, PROFILE_TYPE, SEASONING_DAYS,
                 COMMERCIAL_PROPERTY_CNT, IS_ABHFL_SERVICEABLE
Stage 3a Python: Bajaj Filters  (live, funder, MOB, DPD, bounce, property+UNDER CONS,
                                  occ, amount, age, tenure, LTV)
Stage 3b Python: ABFL Filters   (live, funder-A, seasoning, sanction, tenure, age,
                                  origLTV res<=70/comm<=60, propType, overdue, NPA/DPD,
                                  peakDPD, DPD18M, bounce, restructure, pincode)
Stage 4  Python: Eligibility    (Bajaj: CIBIL 700/675 x Udyam | ABFL: CIBIL 700/675 Ind/Org)
Stage 5  Python: Output CSV     (filter flags, eligibility flags, rejection reasons)
"""

import math
import os
from pathlib import Path

import pandas as pd
import redshift_connector
import yaml

ROOT            = Path(__file__).resolve().parent
SQL_PATH        = ROOT / "sql" / "simple_msme_eligible.sql"
SQL_ASSETS      = ROOT / "sql" / "msme_assets.sql"
SQL_DPD         = ROOT / "sql" / "msme_dpd_history.sql"   # full history — MAX_DPD_EVER derived here
SQL_BOUNCE      = ROOT / "sql" / "msme_bounce.sql"
SQL_RESTRUCTURE = ROOT / "sql" / "restructure.sql"
SQL_SERVICEABLE = ROOT / "sql" / "abhfl_serviceable.sql"
OUT_DIR         = ROOT / "output" / "msme_v4"


# %% DB Helpers
def get_connection():
    keys = ["REDSHIFT_HOST", "REDSHIFT_PORT", "REDSHIFT_DB", "REDSHIFT_USER", "REDSHIFT_PASSWORD"]
    if all(os.getenv(k) for k in keys):
        return redshift_connector.connect(
            host=os.environ["REDSHIFT_HOST"], port=int(os.environ["REDSHIFT_PORT"]),
            database=os.environ["REDSHIFT_DB"], user=os.environ["REDSHIFT_USER"],
            password=os.environ["REDSHIFT_PASSWORD"], timeout=900,
        )
    cfg = yaml.safe_load(Path("d:/2.0/config/database.yaml").read_text(encoding="utf-8"))["database"]
    return redshift_connector.connect(
        host=str(cfg["host"]), port=int(cfg["port"]), database=str(cfg["database"]),
        user=str(cfg["user"]), password=str(cfg["password"]), timeout=900,
    )


def run_sql(conn, sql: str) -> pd.DataFrame:
    df = pd.read_sql_query(sql, conn)
    df.columns = [c.strip().upper() for c in df.columns]
    return df


def last_month_end() -> pd.Timestamp:
    today = pd.Timestamp.today().normalize()
    return pd.Timestamp(today.replace(day=1) - pd.Timedelta(days=1))


def num(df, col, default=0.0) -> pd.Series:
    if col not in df.columns:
        return pd.Series(default, index=df.index, dtype="float64")
    return pd.to_numeric(df[col], errors="coerce").fillna(default)


# %% Calc - Base Fields  (age, MOB, CIBIL, HAS_UDYAM, profile, seasoning)
def calc_base_fields(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    today = pd.Timestamp.today().normalize()

    df["DISBURSEMENT_STATUS"] = df["C_FINAL_DISB_YN"].fillna("").str.upper().map(
        lambda x: "FULLY" if x == "Y" else "PARTIAL"
    )

    df["FIRST_DISB_DATE"] = pd.to_datetime(df["FIRST_DISB_DATE"], errors="coerce")
    df["MOB_FIRST_DISB"] = df["FIRST_DISB_DATE"].apply(
        lambda d: math.ceil((today - d).days / 30.44) if pd.notna(d) else 0
    )

    df["DT_BIRTH_DATE"] = pd.to_datetime(df["DT_BIRTH_DATE"], errors="coerce")
    df["AGE_CURRENT"] = ((today - df["DT_BIRTH_DATE"]).dt.days / 365.25).apply(
        lambda x: int(x) if pd.notna(x) else 0
    )

    df["MATURITY_DATE_LD"] = pd.to_datetime(df["MATURITY_DATE_LD"], errors="coerce")
    df["AGE_AT_MATURITY"] = df.apply(
        lambda r: int((r["MATURITY_DATE_LD"] - r["DT_BIRTH_DATE"]).days / 365.25)
        if pd.notna(r["MATURITY_DATE_LD"]) and pd.notna(r["DT_BIRTH_DATE"]) else 999,
        axis=1,
    )

    def clean_cibil(val):
        s = str(val).strip() if pd.notna(val) else ""
        if not s or not s.isdigit():
            return -1
        v = int(s)
        return -1 if v < 300 else v

    df["CIBIL_SCORE"] = df["SZ_CIBIL_SCORE"].apply(clean_cibil)

    df["HAS_UDYAM"] = (
        df["UDYAM_AADHAR_NUMBER"].fillna("").str.strip().ne("")
    ).astype(int)

    df["PROFILE_TYPE"] = df["INCOME_PROGRAM"].fillna("").str.lower().apply(
        lambda x: "SALARIED" if "salar" in x
        else ("SENP" if ("senp" in x or "sep" in x) else "OTHER")
    )
    df["SEASONING_DAYS"] = df["FIRST_DISB_DATE"].apply(
        lambda d: (today - d).days if pd.notna(d) else 0
    )

    return df


# %% Calc - Property  (value, residential_pct, plot/shed/comm counts, UNDER CONS, top asset type)
def calc_property(assets: pd.DataFrame, loans: pd.DataFrame) -> pd.DataFrame:
    """Aggregate raw asset rows -> one row per application."""
    assets = assets.copy()
    loans_apps = set(loans["SZ_APPLICATION_NO"].astype(str))
    assets = assets[assets["SZ_APPLICATION_NO"].astype(str).isin(loans_apps)].copy()

    assets["VAL"]     = pd.to_numeric(assets["A_I_TOT_VALUATION"], errors="coerce").fillna(0)
    assets["IS_RES"]  = assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("residential").astype(int)
    assets["IS_PLOT"] = (
        assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("plot")
        | assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("land")
    ).astype(int)
    assets["IS_SHED"] = (
        assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("industrial")
        | assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("shed")
    ).astype(int)
    assets["IS_COMM"] = assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("commercial").astype(int)

    grp = assets.groupby("SZ_APPLICATION_NO").agg(
        TOTAL_PROPERTY_VALUE    = ("VAL", "sum"),
        PLOT_COUNT              = ("IS_PLOT", "sum"),
        INDUSTRIAL_SHED_COUNT   = ("IS_SHED", "sum"),
        COMMERCIAL_PROPERTY_CNT = ("IS_COMM", "sum"),
    ).reset_index()
    grp["RESIDENTIAL_PROPERTY_VALUE"] = (
        assets[assets["IS_RES"] == 1].groupby("SZ_APPLICATION_NO")["VAL"].sum()
        .reindex(grp["SZ_APPLICATION_NO"]).values
    )
    grp["RESIDENTIAL_PROPERTY_VALUE"] = grp["RESIDENTIAL_PROPERTY_VALUE"].fillna(0)
    grp["RESIDENTIAL_PCT"] = (
        grp["RESIDENTIAL_PROPERTY_VALUE"] * 100.0 / grp["TOTAL_PROPERTY_VALUE"].replace(0, pd.NA)
    ).fillna(0)

    top = (
        assets.sort_values("VAL", ascending=False)
        .groupby("SZ_APPLICATION_NO")
        .first()[["PROPERTY_TYPE", "PROPERTY_SUBTYPE", "PROPERTY_OCCUPATION",
                  "PROPERTY_PINCODE", "SZ_CERSAI_SEC_INT_ID", "DT_CERSAI"]]
        .reset_index()
    )
    return grp.merge(top, on="SZ_APPLICATION_NO", how="left")


# %% Calc - DPD  (last month / 6M ever-30 / 18M peak / All-time peak / NPA / Bucket)
def calc_dpd(dpd_df: pd.DataFrame) -> pd.DataFrame:
    """Aggregate full DPD history -> per-LAN flags.

    Windows computed:
      DPD_LAST_MONTH   : DPD at last month-end
      EVER_30_DPD_6M   : ever >= 30 DPD in last 6 months        (Bajaj filter)
      MAX_DPD_18M      : peak DPD in last 18 months             (Bajaj filter)
      MAX_DPD_EVER     : peak DPD across ALL history             (ABFL filter)
      EVER_NPA         : ever NPA flag = 'Y'                    (Bajaj filter)
      EVER_BUCKET      : ever SMA/DBT/SUB/LSS or DPD >= 90     (Bajaj filter)
    """
    df = dpd_df.copy()
    df["DT_BUSINESSDATE"]     = pd.to_datetime(df["DT_BUSINESSDATE"], errors="coerce")
    df["I_DPD"]               = pd.to_numeric(df["I_DPD"], errors="coerce").fillna(0)
    df["F_OVERDUE_PRINCIPAL"] = pd.to_numeric(df["F_OVERDUE_PRINCIPAL"], errors="coerce").fillna(0)
    df["F_OVERDUE_INTEREST"]  = pd.to_numeric(df["F_OVERDUE_INTEREST"], errors="coerce").fillna(0)

    lme       = last_month_end()
    m6_start  = lme - pd.DateOffset(months=6)
    m18_start = lme - pd.DateOffset(months=18)

    # last month-end snapshot
    lm = df[df["DT_BUSINESSDATE"] == lme].groupby("SZ_LOAN_ACCOUNT_NO").agg(
        OVERDUE_PRINCIPAL_LM = ("F_OVERDUE_PRINCIPAL", "max"),
        OVERDUE_INTEREST_LM  = ("F_OVERDUE_INTEREST",  "max"),
        DPD_LAST_MONTH       = ("I_DPD",               "max"),
    ).reset_index()

    # last 6 months: ever DPD >= 30
    d6 = df[(df["DT_BUSINESSDATE"] >= m6_start) & (df["DT_BUSINESSDATE"] <= lme)]
    d6_agg = d6.groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].apply(
        lambda x: int((x >= 30).any())
    ).reset_index().rename(columns={"I_DPD": "EVER_30_DPD_6M"})

    # last 18 months: peak DPD  (Bajaj filter)
    d18 = df[(df["DT_BUSINESSDATE"] >= m18_start) & (df["DT_BUSINESSDATE"] <= lme)]
    d18_agg = d18.groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].max().reset_index().rename(
        columns={"I_DPD": "MAX_DPD_18M"}
    )

    # all history: peak DPD ever  (ABFL filter)
    ever_agg = df[df["DT_BUSINESSDATE"] <= lme].groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].max(
    ).reset_index().rename(columns={"I_DPD": "MAX_DPD_EVER"})

    # NPA ever
    df["IS_NPA"] = (df["NPA_FLAG"].fillna("") == "Y").astype(int)
    npa_agg = df.groupby("SZ_LOAN_ACCOUNT_NO")["IS_NPA"].max().reset_index().rename(
        columns={"IS_NPA": "EVER_NPA"}
    )

    # ever stressed bucket: SMA / DBT / SUB / LSS or DPD >= 90
    bkt = df[df["DT_BUSINESSDATE"] <= lme].copy()
    bkt["IS_BUCKET"] = (
        bkt["NPA_FLAG"].fillna("").isin(["SMA", "DBT", "SUB", "LSS"]) | (bkt["I_DPD"] >= 90)
    ).astype(int)
    bkt_agg = bkt.groupby("SZ_LOAN_ACCOUNT_NO")["IS_BUCKET"].max().reset_index().rename(
        columns={"IS_BUCKET": "EVER_BUCKET"}
    )

    result = lm.merge(d6_agg,   on="SZ_LOAN_ACCOUNT_NO", how="outer")
    result = result.merge(d18_agg,  on="SZ_LOAN_ACCOUNT_NO", how="outer")
    result = result.merge(ever_agg, on="SZ_LOAN_ACCOUNT_NO", how="outer")
    result = result.merge(npa_agg,  on="SZ_LOAN_ACCOUNT_NO", how="outer")
    result = result.merge(bkt_agg,  on="SZ_LOAN_ACCOUNT_NO", how="outer")
    for c in ["OVERDUE_PRINCIPAL_LM", "OVERDUE_INTEREST_LM",
              "EVER_30_DPD_6M", "MAX_DPD_18M", "MAX_DPD_EVER", "EVER_NPA", "EVER_BUCKET"]:
        result[c] = result.get(c, pd.Series(0)).fillna(0)
    return result


# %% Calc - Bounce  (L3M / L6M / L12M counts per LAN)
def calc_bounce(bounce_df: pd.DataFrame) -> pd.DataFrame:
    df = bounce_df.copy()
    df["DT_INSTALLMENTDUE"] = pd.to_datetime(df["DT_INSTALLMENTDUE"], errors="coerce")
    lme = last_month_end()

    def count(months_back):
        start = lme - pd.DateOffset(months=months_back)
        sub = df[(df["DT_INSTALLMENTDUE"] >= start) & (df["DT_INSTALLMENTDUE"] <= lme)]
        return sub.groupby("SZ_LOAN_ACCOUNT_NO")["DT_INSTALLMENTDUE"].nunique().reset_index()

    b3  = count(3).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L3M"})
    b6  = count(6).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L6M"})
    b12 = count(12).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L12M"})

    result = b3.merge(b6, on="SZ_LOAN_ACCOUNT_NO", how="outer")
    result = result.merge(b12, on="SZ_LOAN_ACCOUNT_NO", how="outer")
    return result.fillna(0)


# %% Bajaj Filter Functions  (MSME: includes UNDER CONS check unlike HE)

# %% Filter - Live Case  (approved + fully disbursed + POS > 0)
def filterLiveCase(df):
    return df.loc[
        df["LOAN_STATUS"].fillna("").str.upper().eq("APPROVED")
        & df["DISBURSEMENT_STATUS"].fillna("").str.upper().isin(["FULL", "FULLY"])
        & (num(df, "POS_CURRENT") > 0)
    ]

# %% Filter - Not Funded  (no funder / DA / NHB / NABARD)
def filterNotFunded(df):
    return df.loc[
        df["SZ_FUNDER_STATUS"].isna()
        & df["DIRECT_ASSIGNMENT"].isna()
        & (~df["NHB"].fillna("").str.upper().str.contains("NHB"))
        & df["SZ_NABARD_NAME"].isna()
        & df["REFINANCE_SCHEME"].isna()
        & df["SZ_FUNDER_NAME"].isna()
    ]

# %% Filter - MOB  (>= 6 months on book)
def filterMOB(df):
    return df.loc[num(df, "MOB_FIRST_DISB") >= 6]

# %% Filter - Restructured  (no restructure / morat / NPA / bucket)
def filterRestructured(df):
    return df.loc[
        (num(df, "IS_RESTRUCTURED") == 0)
        & df["MORAT_FLAG"].fillna("N").str.upper().ne("Y")
        & (num(df, "EVER_NPA") == 0)
        & (num(df, "EVER_BUCKET") == 0)
    ]

# %% Filter - DPD  (no 30+ DPD in 6M, max DPD 18M < 30, overdue <= 1000)
def filterDPD(df):
    return df.loc[
        (num(df, "EVER_30_DPD_6M") == 0)
        & (num(df, "MAX_DPD_18M", 0) < 30)
        & (num(df, "OVERDUE_PRINCIPAL_LM", 0) <= 1000)
        & (num(df, "OVERDUE_INTEREST_LM", 0) <= 1000)
    ]

# %% Filter - Bounce  (MOB-dependent: 0 in L6M if MOB<=6, <=1 in L6M if MOB<=12, <=2 in L12M)
def filterBounce(df):
    mob = num(df, "MOB_FIRST_DISB")
    b3  = num(df, "BOUNCE_COUNT_L3M")
    b6  = num(df, "BOUNCE_COUNT_L6M")
    b12 = num(df, "BOUNCE_COUNT_L12M")
    return df.loc[
        ((mob <= 6)  & (b6 == 0))
        | ((mob > 6)  & (mob <= 12) & (b6 <= 1) & (b3 == 0))
        | ((mob > 12) & (b12 <= 2)  & (b3 == 0) & (b6 <= 1))
    ]

# %% Filter - Property  (MSME: no plot/shed/vacant/UNDER CONS, residential >= 80%)
def filterProperty(df):
    # MSME: also blocks UNDER CONS in subtype / occupation (HE does NOT have this check)
    ptype = df["PROPERTY_TYPE"].fillna("").str.upper()
    psub  = df["PROPERTY_SUBTYPE"].fillna("").str.upper()
    occ   = df["PROPERTY_OCCUPATION"].fillna("").str.upper()
    return df.loc[
        (num(df, "PLOT_COUNT") == 0)
        & (num(df, "INDUSTRIAL_SHED_COUNT") == 0)
        & (~ptype.str.contains("VACANT"))
        & (~psub.str.contains("VACANT"))
        & (~psub.str.contains("UNDER CONS"))
        & (~occ.str.contains("UNDER CONS"))
        & (num(df, "RESIDENTIAL_PCT", 0) >= 80)
    ]

# %% Filter - Occupation  (block lawyers / police / PEP / real estate / broker / builder)
def filterOccupation(df):
    occ = df["SZ_PRIMARY_OCCUPATION"].fillna("").str.upper()
    blocked = pd.Series(False, index=df.index)
    for b in ["LAWYER", "POLICE", "PEP", "REAL ESTATE", "BROKER", "BUILDER"]:
        blocked |= occ.str.contains(b)
    return df.loc[~blocked]

# %% Filter - Loan Amount  (>= 3 lakh)
def filterLoanAmount(df):
    return df.loc[num(df, "LOAN_AMOUNT_W_INSURANCE") >= 300000]

# %% Filter - Age  (current 21-75; maturity age <= 75 or NULL)
def filterAge(df):
    age     = num(df, "AGE_CURRENT")
    mat_age = pd.to_numeric(df.get("AGE_AT_MATURITY"), errors="coerce")
    mat_ok  = (mat_age <= 75) | mat_age.isna()   # NULL age_at_maturity = pass (SQL behaviour)
    return df.loc[(age >= 21) & mat_ok]

# %% Filter - Tenure  (<= 180M if loan <= 30L; <= 240M if loan > 30L)
def filterTenure(df):
    amt = num(df, "LOAN_AMOUNT_W_INSURANCE")
    ten = num(df, "TENURE_AT_SANCTION", 9999)
    return df.loc[
        ((amt <= 3000000) & (ten <= 180))
        | ((amt >  3000000) & (ten <= 240))
    ]

# %% Filter - LTV  (< 75% if CIBIL > 750 or self-occ; < 70% otherwise)
def filterLTV(df):
    cibil = num(df, "CIBIL_SCORE", -10)
    ltv   = num(df, "CALCULATED_LTV", 999)
    occ   = df["PROPERTY_OCCUPATION"].fillna("").str.upper()
    return df.loc[
        (((cibil > 750) | occ.str.contains("SELF")) & (ltv < 75))
        | (ltv < 70)
    ]


# %% Bajaj Filter Dict
BAJAJ_FILTER_DICT = {
    "Not live / approved / disbursed":      filterLiveCase,
    "Funder / DA / NHB / NABARD assigned":  filterNotFunded,
    "Seasoning < 6 months (MOB < 6)":       filterMOB,
    "Restructured / Morat / NPA / Bucket":  filterRestructured,
    "DPD or overdue breach":                filterDPD,
    "Bounce norms not met":                 filterBounce,
    "Property restrictions":                filterProperty,
    "Blacklisted occupation":               filterOccupation,
    "Loan amount < 3L":                     filterLoanAmount,
    "Age not in 21-75 range":               filterAge,
    "Tenure exceeds limit by amount":       filterTenure,
    "LTV breach":                           filterLTV,
}


# %% ABFL Filter Functions

# %% ABFL Filter - Not Funded  (funder_status = 'A' only; Bajaj blocks any non-null)
def filterNotFundedABFL(df):
    """ABFL MSME: NHB uses pattern match (NOT LIKE '%NHB%') — same as Bajaj.
    HE SQL uses IS NULL; MSME SQL uses NOT LIKE '%NHB%' (line 1288 unified_msme_v3.sql).
    """
    return df.loc[
        df["SZ_FUNDER_STATUS"].fillna("").str.upper().ne("A")
        & df["DIRECT_ASSIGNMENT"].isna()
        & df["REFINANCE_SCHEME"].isna()
        & df["SZ_NABARD_NAME"].isna()
        & (~df["NHB"].fillna("").str.upper().str.contains("NHB"))
        & df["SZ_FUNDER_NAME"].isna()
    ]

# %% ABFL Filter - Seasoning  (>= 180 calendar days)
def filterSeasoningABFL(df):
    """ABFL: >= 180 calendar days from first disbursal."""
    return df.loc[num(df, "SEASONING_DAYS") >= 180]

# %% ABFL Filter - Sanction Amount  (3L to 2Cr)
def filterSanctionAmountABFL(df):
    """ABFL: 3L <= sanctioned_amount <= 2Cr."""
    sa = num(df, "SANCTIONED_AMOUNT")
    return df.loc[(sa >= 300_000) & (sa <= 20_000_000)]

# %% ABFL Filter - Balance Tenure  (<= 174 months)
def filterBalanceTenureABFL(df):
    """ABFL: balance tenure <= 174 months."""
    return df.loc[num(df, "BALANCE_TENURE", 9999) <= 174]

# %% ABFL Filter - Original Tenure  (<= 180 months)
def filterOriginalTenureABFL(df):
    """ABFL: original (sanction) tenure <= 180 months."""
    return df.loc[num(df, "TENURE_AT_SANCTION", 9999) <= 180]

# %% ABFL Filter - Age  (>= 18; SALARIED <= 60, SENP/NULL <= 70; OTHER profile rejected)
def filterAgeABFL(df):
    """ABFL: SQL only allows SALARIED/SENP/NULL profile types in age-at-maturity check.
    Loans with profile_type = 'OTHER' are rejected — SQL has no ELSE/default pass for them.
    Null age_at_maturity is allowed (matches SQL: age_at_maturity <= 60 OR IS NULL).
    """
    age     = num(df, "AGE_CURRENT")
    mat_age = pd.to_numeric(df.get("AGE_AT_MATURITY"), errors="coerce")
    profile = df["PROFILE_TYPE"].fillna("").str.upper()  # NULL → "" matches SQL IS NULL
    mat_ok = (
        ((profile == "SALARIED") & ((mat_age <= 60) | mat_age.isna()))
        | ((profile == "SENP")   & ((mat_age <= 70) | mat_age.isna()))
        | ((profile == "")       & ((mat_age <= 70) | mat_age.isna()))  # NULL profile
    )
    return df.loc[(age >= 18) & mat_ok]

# %% ABFL Filter - LTV Origination  (res <= 70%, comm/mix <= 60%; matches SQL md.ltv = ltv_wo_insurance)
def filterLTVOriginationABFL(df):
    """ABFL MSME: origination LTV (ltv_wo_insurance): res <= 70%, comm/mix <= 60%.
    SQL uses md.ltv = app.ltv_wo_insurance — NOT current/calculated LTV.
    """
    ptype    = df["PROPERTY_TYPE"].fillna("").str.lower()
    psub     = df["PROPERTY_SUBTYPE"].fillna("").str.lower()
    ltv      = num(df, "LTV_ORIGINATION", 999)
    comm_cnt = num(df, "COMMERCIAL_PROPERTY_CNT", 1)
    is_pure_res = (
        (comm_cnt == 0)
        & ptype.str.startswith("residential")
        & ~ptype.str.contains("commercial")
        & ~ptype.str.contains("mix")
        & ~psub.str.contains("commercial")
        & ~psub.str.contains("mix")
    )
    return df.loc[
        (num(df, "TOTAL_PROPERTY_VALUE", 0) > 0)
        & (
            (is_pure_res & (ltv <= 70))
            | (~is_pure_res & (ltv <= 60))
        )
    ]

# %% ABFL Filter - Property Type  (res / comm / mix only; no industrial / plot / vacant / UNDER CONS)
def filterPropertyTypeABFL(df):
    """ABFL: res/comm/mix only; no industrial/plot/vacant/under-construction."""
    ptype = df["PROPERTY_TYPE"].fillna("").str.lower()
    psub  = df["PROPERTY_SUBTYPE"].fillna("").str.lower()
    pocc  = df["PROPERTY_OCCUPATION"].fillna("").str.lower()
    allowed = (
        ptype.str.startswith("residential") | ptype.str.startswith("commercial")
        | ptype.str.startswith("mix")
        | psub.str.startswith("residential") | psub.str.startswith("commercial")
        | psub.str.startswith("mix")
    )
    blocked = (
        ptype.str.contains("industrial") | ptype.str.contains("plot")
        | ptype.str.contains("vacant")
        | psub.str.contains("industrial") | psub.str.contains("plot")
        | psub.str.contains("vacant") | psub.str.contains("under cons")
        | pocc.str.contains("under cons")
    )
    return df.loc[allowed & ~blocked]

# %% ABFL Filter - Overdue  (must be exactly 0; Bajaj allows <= 1000)
def filterOverdueABFL(df):
    """ABFL: overdue exactly 0 (Bajaj allows up to 1000)."""
    return df.loc[
        (num(df, "OVERDUE_PRINCIPAL_LM", 0) == 0)
        & (num(df, "OVERDUE_INTEREST_LM", 0) == 0)
    ]

# %% ABFL Filter - NPA & Current DPD  (NPA flag = N, current DPD < 30)
def filterNpaCurrentDpdABFL(df):
    """ABFL: NPA flag = N AND current DPD < 30."""
    return df.loc[
        df["NPA_FLAG"].fillna("N").str.upper().eq("N")
        & (num(df, "CURRENT_DPD", 0) < 30)
    ]

# %% ABFL Filter - Peak DPD Ever  (all-time peak < 90)
def filterPeakDpdABFL(df):
    """ABFL: peak DPD (all history) < 90."""
    return df.loc[num(df, "MAX_DPD_EVER", 0) < 90]

# %% ABFL Filter - DPD 18M  (max DPD in last 18 months < 30)
def filterDpd18mABFL(df):
    """ABFL: max DPD in last 18 months < 30."""
    return df.loc[num(df, "MAX_DPD_18M", 0) < 30]

# %% ABFL Filter - Bounce L12M  (zero bounces in last 12 months)
def filterBounceL12mABFL(df):
    """ABFL: zero bounces in last 12 months."""
    return df.loc[num(df, "BOUNCE_COUNT_L12M", 0) == 0]

# %% ABFL Filter - Restructured Flag  (restructure_flag != 'Y' from loan table)
def filterRestructuredFlagABFL(df):
    """ABFL: restructure_flag != 'Y' (from loan table)."""
    return df.loc[df["RESTRUCTURE_FLAG"].fillna("N").str.upper().ne("Y")]

# %% ABFL Filter - Serviceable Pincode  (must be in ABHFL serviceable list)
def filterServiceableABFL(df):
    """ABFL: property pincode must be in ABHFL serviceable list."""
    return df.loc[num(df, "IS_ABHFL_SERVICEABLE", 0) == 1]


# %% ABFL Filter Dict
ABFL_FILTER_DICT = {
    "Not live / approved / disbursed":         filterLiveCase,
    "Funder / DA assigned (ABFL rules)":       filterNotFundedABFL,
    "Seasoning < 180 days":                    filterSeasoningABFL,
    "Sanction not in 3L-2Cr range":            filterSanctionAmountABFL,
    "Balance tenure > 174 months":             filterBalanceTenureABFL,
    "Original tenure > 180 months":            filterOriginalTenureABFL,
    "Age / maturity breach (ABFL)":            filterAgeABFL,
    "LTV origination breach (res>70/comm>60)": filterLTVOriginationABFL,
    "Property type not res/comm/mix":          filterPropertyTypeABFL,
    "Overdue not zero":                        filterOverdueABFL,
    "NPA flag or current DPD >= 30":           filterNpaCurrentDpdABFL,
    "Peak DPD ever >= 90":                     filterPeakDpdABFL,
    "DPD 18M >= 30":                           filterDpd18mABFL,
    "Bounce in L12M":                          filterBounceL12mABFL,
    "Restructured (loan flag)":                filterRestructuredFlagABFL,
    "Pincode not ABHFL serviceable":           filterServiceableABFL,
}


# %% Bajaj Eligibility Dict  (CIBIL threshold x Udyam split)
BAJAJ_ELIGIBILITY_DICT = {
    "BAJAJ_700": lambda df: df.loc[
        (num(df, "CIBIL_SCORE", -10) >= 700) | (num(df, "CIBIL_SCORE", -10) == -1)
    ],
    "BAJAJ_675": lambda df: df.loc[
        (num(df, "CIBIL_SCORE", -10) >= 675) | (num(df, "CIBIL_SCORE", -10) == -1)
    ],
    "BAJAJ_700_WITH_UDYAM": lambda df: df.loc[
        ((num(df, "CIBIL_SCORE", -10) >= 700) | (num(df, "CIBIL_SCORE", -10) == -1))
        & (num(df, "HAS_UDYAM", 0) == 1)
    ],
    "BAJAJ_700_NO_UDYAM": lambda df: df.loc[
        ((num(df, "CIBIL_SCORE", -10) >= 700) | (num(df, "CIBIL_SCORE", -10) == -1))
        & (num(df, "HAS_UDYAM", 0) == 0)
    ],
    "BAJAJ_675_WITH_UDYAM": lambda df: df.loc[
        ((num(df, "CIBIL_SCORE", -10) >= 675) | (num(df, "CIBIL_SCORE", -10) == -1))
        & (num(df, "HAS_UDYAM", 0) == 1)
    ],
    "BAJAJ_675_NO_UDYAM": lambda df: df.loc[
        ((num(df, "CIBIL_SCORE", -10) >= 675) | (num(df, "CIBIL_SCORE", -10) == -1))
        & (num(df, "HAS_UDYAM", 0) == 0)
    ],
}


# %% ABFL Eligibility Dict  (Individual: CIBIL >= threshold | Org: auto-pass)
def _abfl_cibil(df, threshold):
    """ABFL: Individual >= threshold; Org applicants auto-pass CIBIL."""
    is_org   = df["SZ_APPL_CATEGORY_CODE"].fillna("").str.upper().isin(["CO", "CORP", "TRUST", "HUF"])
    cibil    = num(df, "CIBIL_SCORE", -10)
    cibil_ok = (cibil >= threshold) | (cibil == -1) | is_org
    return df.loc[cibil_ok]

ABFL_ELIGIBILITY_DICT = {
    "ABFL_700": lambda df: _abfl_cibil(df, 700),
    "ABFL_675": lambda df: _abfl_cibil(df, 675),
}


# %% Filter Tracking Helpers
def checkRejected(df, filtered_df, filter_name, reject_dict, rejected_df):
    rejected = df.loc[~df["LAN"].isin(filtered_df["LAN"])].copy()
    rejected_df = pd.concat([rejected_df, rejected]).drop_duplicates(subset=["LAN"])
    for lan in rejected["LAN"]:
        reject_dict.setdefault(lan, []).append(filter_name)
    return reject_dict, rejected_df


def addRejectionReason(df, reject_dict, prefix="BAJAJ"):
    df = df.copy()
    col = f"{prefix}_REJECTION_REASON"
    df[col] = df["LAN"].map(
        lambda x: ", ".join(reject_dict[x]) if x in reject_dict else "NA"
    )
    return df


# %% Main
def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ts = pd.Timestamp.now().strftime("%Y%m%d_%H%M%S")

    # Stage 1: load raw data from SQL
    print("Stage 1: loading data from Redshift...")
    with get_connection() as conn:
        df             = run_sql(conn, SQL_PATH.read_text(encoding="utf-8"))
        assets_df      = run_sql(conn, SQL_ASSETS.read_text(encoding="utf-8"))
        dpd_df         = run_sql(conn, SQL_DPD.read_text(encoding="utf-8"))       # full history
        bounce_df      = run_sql(conn, SQL_BOUNCE.read_text(encoding="utf-8"))
        restructure_df = run_sql(conn, SQL_RESTRUCTURE.read_text(encoding="utf-8"))
        serviceable_df = run_sql(conn, SQL_SERVICEABLE.read_text(encoding="utf-8"))
    print(f"  raw_rows = {len(df)}")

    # Stage 2: calculate derived fields
    print("Stage 2: calculating derived fields...")
    df  = calc_base_fields(df)
    df["LAN"] = df["SZ_LOAN_ACCOUNT_NO"].astype(str)

    prop      = calc_property(assets_df, df)
    dpd       = calc_dpd(dpd_df)          # MAX_DPD_EVER computed from full history
    bounce    = calc_bounce(bounce_df)
    rest_lans = set(restructure_df["SZ_LOAN_ACCOUNT_NO"].astype(str))

    df = df.merge(prop,   on="SZ_APPLICATION_NO",  how="left")
    df = df.merge(dpd,    on="SZ_LOAN_ACCOUNT_NO", how="left")
    df = df.merge(bounce, on="SZ_LOAN_ACCOUNT_NO", how="left")
    df["IS_RESTRUCTURED"] = df["LAN"].isin(rest_lans).astype(int)

    svc_pins = set(serviceable_df["PINCODE"].astype(str).str.strip())
    df["IS_ABHFL_SERVICEABLE"] = df["PIN_CODE"].astype(str).str.strip().isin(svc_pins).astype(int)

    # re-compute MOB/seasoning using NVL(dt_cersai, first_disb_date) — same as SQL
    today = pd.Timestamp.today().normalize()
    df["DT_CERSAI"]   = pd.to_datetime(df.get("DT_CERSAI"), errors="coerce")
    cersai_anchor     = df["DT_CERSAI"].fillna(df["FIRST_DISB_DATE"])
    df["MOB_FIRST_DISB"] = cersai_anchor.apply(
        lambda d: math.ceil((today - d).days / 30.44) if pd.notna(d) else 0
    )
    df["SEASONING_DAYS"] = cersai_anchor.apply(
        lambda d: (today - d).days if pd.notna(d) else 0
    )

    df["CALCULATED_LTV"] = (
        num(df, "POS_CURRENT") * 100.0 / df["TOTAL_PROPERTY_VALUE"].replace(0, pd.NA)
    )
    df["LTV_ORIGINATION"] = pd.to_numeric(df.get("LTV_ORIGINATION"), errors="coerce")

    for c in ["BOUNCE_COUNT_L3M", "BOUNCE_COUNT_L6M", "BOUNCE_COUNT_L12M",
              "EVER_30_DPD_6M", "MAX_DPD_18M", "MAX_DPD_EVER", "EVER_NPA", "EVER_BUCKET",
              "OVERDUE_PRINCIPAL_LM", "OVERDUE_INTEREST_LM", "COMMERCIAL_PROPERTY_CNT"]:
        df[c] = df.get(c, pd.Series(0.0)).fillna(0)

    # Stage 3a: Bajaj filters
    print("Stage 3a: applying Bajaj filters...")
    reject_dict = {}
    rejected_df = pd.DataFrame(columns=df.columns)
    for reason, func in BAJAJ_FILTER_DICT.items():
        filtered    = func(df)
        reject_dict, rejected_df = checkRejected(df, filtered, reason, reject_dict, rejected_df)

    accepted_df = df.loc[~df["LAN"].isin(rejected_df["LAN"])].copy()
    print(f"  bajaj filter_pass = {len(accepted_df)}  |  filter_reject = {len(rejected_df)}")

    # Stage 3b: ABFL filters
    print("Stage 3b: applying ABFL filters...")
    abfl_reject_dict = {}
    abfl_rejected_df = pd.DataFrame(columns=df.columns)
    for reason, func in ABFL_FILTER_DICT.items():
        filtered             = func(df)
        abfl_reject_dict, abfl_rejected_df = checkRejected(
            df, filtered, reason, abfl_reject_dict, abfl_rejected_df
        )

    abfl_accepted_df = df.loc[~df["LAN"].isin(abfl_rejected_df["LAN"])].copy()
    print(f"  abfl  filter_pass = {len(abfl_accepted_df)}  |  filter_reject = {len(abfl_rejected_df)}")

    # Stage 4: eligibility
    print("Stage 4: applying eligibility criteria...")
    eligible = {}
    for name, func in BAJAJ_ELIGIBILITY_DICT.items():
        eligible[name] = func(accepted_df)
        print(f"  {name} = {len(eligible[name])}")
    for name, func in ABFL_ELIGIBILITY_DICT.items():
        eligible[name] = func(abfl_accepted_df)
        print(f"  {name} = {len(eligible[name])}")

    # Stage 5: output
    print("Stage 5: writing output...")
    df = addRejectionReason(df, reject_dict,      prefix="BAJAJ")
    df = addRejectionReason(df, abfl_reject_dict, prefix="ABFL")
    df["BAJAJ_HARD_FILTER_PASS"] = df["LAN"].isin(accepted_df["LAN"]).map({True: "Eligible", False: "Ineligible"})
    df["ABFL_HARD_FILTER_PASS"]  = df["LAN"].isin(abfl_accepted_df["LAN"]).map({True: "Eligible", False: "Ineligible"})
    for name, elig_df in eligible.items():
        df[f"ELIGIBLE_{name}"] = df["LAN"].isin(elig_df["LAN"]).map({True: "Eligible", False: "Ineligible"})

    out_file = OUT_DIR / f"msme_v4_{ts}.csv"
    df.to_csv(out_file, index=False)

    print(f"\n{'='*50}")
    print(f"  raw_rows              = {len(df)}")
    print(f"  bajaj_hard_filter_pass = {(df['BAJAJ_HARD_FILTER_PASS'] == 'Eligible').sum()}")
    print(f"  abfl_hard_filter_pass  = {(df['ABFL_HARD_FILTER_PASS'] == 'Eligible').sum()}")
    for name in eligible:
        print(f"  eligible_{name:<20} = {(df[f'ELIGIBLE_{name}'] == 'Eligible').sum()}")
    print(f"  output                = {out_file}")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()
