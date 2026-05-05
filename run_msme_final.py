# %% ── Imports & Config ──────────────────────────────────────────────────────
"""
MSME DA Pool Selection — Final
Stage 1  Load    : simple_msme_eligible + msme_assets + msme_dpd_history + msme_bounce + restructure + abhfl_serviceable
Stage 2  Derive  : age, MOB, CIBIL, LTV, DPD flags, bounce counts, profile, seasoning
Stage 3a Bajaj   : hard filters → BAJAJ_HARD_FILTER_PASS
Stage 3b ABFL    : hard filters → ABFL_HARD_FILTER_PASS
Stage 4  Eligible: CIBIL cutoff + Udyam split → ELIGIBLE_* columns
Stage 5  Output  : CSV with all flags and rejection reasons

Key differences vs HE:
  - Bajaj property filter also blocks "Under Construction"
  - ABFL LTV is tiered: residential <= 70%, commercial/mixed <= 60%
  - ABFL NHB check uses pattern match (NOT LIKE '%NHB%'), not IS NULL
"""
import math
import os
from pathlib import Path

import pandas as pd
import redshift_connector
import yaml

THIS_FOLDER     = Path(__file__).resolve().parent
SQL_LOANS       = THIS_FOLDER / "sql" / "simple_msme_eligible.sql"
SQL_ASSETS      = THIS_FOLDER / "sql" / "msme_assets.sql"
SQL_DPD         = THIS_FOLDER / "sql" / "msme_dpd_history.sql"
SQL_BOUNCE      = THIS_FOLDER / "sql" / "msme_bounce.sql"
SQL_RESTRUCTURE = THIS_FOLDER / "sql" / "restructure.sql"
SQL_SERVICEABLE = THIS_FOLDER / "sql" / "abhfl_serviceable.sql"
OUTPUT_FOLDER   = THIS_FOLDER / "output" / "msme_final"


# %% ── Database Helpers ───────────────────────────────────────────────────────

def get_connection():
    env_keys = ["REDSHIFT_HOST", "REDSHIFT_PORT", "REDSHIFT_DB", "REDSHIFT_USER", "REDSHIFT_PASSWORD"]
    if all(os.getenv(k) for k in env_keys):
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

def run_query(conn, sql_text: str) -> pd.DataFrame:
    result = pd.read_sql_query(sql_text, conn)
    result.columns = [c.strip().upper() for c in result.columns]
    return result

def last_month_end() -> pd.Timestamp:
    today = pd.Timestamp.today().normalize()
    return pd.Timestamp(today.replace(day=1) - pd.Timedelta(days=1))

def to_number(df, col, default=0.0) -> pd.Series:
    """Safe numeric cast; returns `default` for missing/non-numeric values."""
    if col not in df.columns:
        return pd.Series(default, index=df.index, dtype="float64")
    return pd.to_numeric(df[col], errors="coerce").fillna(default)


# %% ── Derive: Base Fields ────────────────────────────────────────────────────

def derive_base_fields(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    today = pd.Timestamp.today().normalize()

    df["DISBURSEMENT_STATUS"] = df["C_FINAL_DISB_YN"].fillna("").str.upper().apply(
        lambda x: "FULLY" if x == "Y" else "PARTIAL"
    )
    df["FIRST_DISB_DATE"] = pd.to_datetime(df["FIRST_DISB_DATE"], errors="coerce")
    df["MOB_FIRST_DISB"]  = df["FIRST_DISB_DATE"].apply(
        lambda d: math.ceil((today - d).days / 30.44) if pd.notna(d) else 0
    )
    df["DT_BIRTH_DATE"] = pd.to_datetime(df["DT_BIRTH_DATE"], errors="coerce")
    df["AGE_CURRENT"]   = ((today - df["DT_BIRTH_DATE"]).dt.days / 365.25).apply(
        lambda x: int(x) if pd.notna(x) else 0
    )
    df["MATURITY_DATE_LD"] = pd.to_datetime(df["MATURITY_DATE_LD"], errors="coerce")
    df["AGE_AT_MATURITY"]  = df.apply(
        lambda r: int((r["MATURITY_DATE_LD"] - r["DT_BIRTH_DATE"]).days / 365.25)
        if pd.notna(r["MATURITY_DATE_LD"]) and pd.notna(r["DT_BIRTH_DATE"]) else 999,
        axis=1,
    )

    def clean_cibil(v):
        s = str(v).strip() if pd.notna(v) else ""
        if not s or not s.isdigit(): return -1
        n = int(s)
        return -1 if n < 300 else n

    df["CIBIL_SCORE"]  = df["SZ_CIBIL_SCORE"].apply(clean_cibil)
    df["HAS_UDYAM"]    = df["UDYAM_AADHAR_NUMBER"].fillna("").str.strip().ne("").astype(int)
    df["PROFILE_TYPE"] = df["INCOME_PROGRAM"].fillna("").str.lower().apply(
        lambda x: "SALARIED" if "salar" in x else ("SENP" if "senp" in x or "sep" in x else "OTHER")
    )
    df["SEASONING_DAYS"] = df["FIRST_DISB_DATE"].apply(
        lambda d: (today - d).days if pd.notna(d) else 0
    )
    return df


# %% ── Derive: Property Summary ───────────────────────────────────────────────

def derive_property_summary(assets_df: pd.DataFrame, loans_df: pd.DataFrame) -> pd.DataFrame:
    assets = assets_df.copy()
    assets = assets[assets["SZ_APPLICATION_NO"].astype(str).isin(
        set(loans_df["SZ_APPLICATION_NO"].astype(str))
    )].copy()

    assets["VAL"]     = pd.to_numeric(assets["A_I_TOT_VALUATION"], errors="coerce").fillna(0)
    assets["IS_RES"]  = assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("residential").astype(int)
    assets["IS_PLOT"] = (assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("plot")
                         | assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("land")).astype(int)
    assets["IS_SHED"] = (assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("industrial")
                         | assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("shed")).astype(int)
    assets["IS_COMM"] = assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("commercial").astype(int)

    grp = assets.groupby("SZ_APPLICATION_NO").agg(
        TOTAL_PROPERTY_VALUE    = ("VAL",     "sum"),
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


# %% ── Derive: DPD Summary ────────────────────────────────────────────────────

def derive_dpd_summary(dpd_history_df: pd.DataFrame) -> pd.DataFrame:
    dpd = dpd_history_df.copy()
    dpd["DT_BUSINESSDATE"]     = pd.to_datetime(dpd["DT_BUSINESSDATE"], errors="coerce")
    dpd["I_DPD"]               = pd.to_numeric(dpd["I_DPD"], errors="coerce").fillna(0)
    dpd["F_OVERDUE_PRINCIPAL"] = pd.to_numeric(dpd["F_OVERDUE_PRINCIPAL"], errors="coerce").fillna(0)
    dpd["F_OVERDUE_INTEREST"]  = pd.to_numeric(dpd["F_OVERDUE_INTEREST"], errors="coerce").fillna(0)

    lme = last_month_end()
    m6  = lme - pd.DateOffset(months=6)
    m18 = lme - pd.DateOffset(months=18)

    last_mo = dpd[dpd["DT_BUSINESSDATE"] == lme].groupby("SZ_LOAN_ACCOUNT_NO").agg(
        OVERDUE_PRINCIPAL_LM=("F_OVERDUE_PRINCIPAL", "max"),
        OVERDUE_INTEREST_LM =("F_OVERDUE_INTEREST",  "max"),
        DPD_LAST_MONTH      =("I_DPD",               "max"),
    ).reset_index()

    ever_30_6m = (dpd[(dpd["DT_BUSINESSDATE"] >= m6) & (dpd["DT_BUSINESSDATE"] <= lme)]
                  .groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"]
                  .apply(lambda x: int((x >= 30).any()))
                  .reset_index().rename(columns={"I_DPD": "EVER_30_DPD_6M"}))

    peak_18m = (dpd[(dpd["DT_BUSINESSDATE"] >= m18) & (dpd["DT_BUSINESSDATE"] <= lme)]
                .groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].max()
                .reset_index().rename(columns={"I_DPD": "MAX_DPD_18M"}))

    peak_ever = (dpd[dpd["DT_BUSINESSDATE"] <= lme]
                 .groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].max()
                 .reset_index().rename(columns={"I_DPD": "MAX_DPD_EVER"}))

    dpd["IS_NPA_ROW"] = (dpd["NPA_FLAG"].fillna("") == "Y").astype(int)
    ever_npa = dpd.groupby("SZ_LOAN_ACCOUNT_NO")["IS_NPA_ROW"].max().reset_index().rename(
        columns={"IS_NPA_ROW": "EVER_NPA"})

    hist = dpd[dpd["DT_BUSINESSDATE"] <= lme].copy()
    hist["IS_STRESSED"] = (hist["NPA_FLAG"].fillna("").isin(["SMA","DBT","SUB","LSS"])
                           | (hist["I_DPD"] >= 90)).astype(int)
    ever_bucket = hist.groupby("SZ_LOAN_ACCOUNT_NO")["IS_STRESSED"].max().reset_index().rename(
        columns={"IS_STRESSED": "EVER_BUCKET"})

    result = last_mo
    for part in [ever_30_6m, peak_18m, peak_ever, ever_npa, ever_bucket]:
        result = result.merge(part, on="SZ_LOAN_ACCOUNT_NO", how="outer")
    for c in ["OVERDUE_PRINCIPAL_LM","OVERDUE_INTEREST_LM","EVER_30_DPD_6M",
              "MAX_DPD_18M","MAX_DPD_EVER","EVER_NPA","EVER_BUCKET"]:
        result[c] = result.get(c, pd.Series(0)).fillna(0)
    return result


# %% ── Derive: Bounce Summary ─────────────────────────────────────────────────

def derive_bounce_summary(bounce_df: pd.DataFrame) -> pd.DataFrame:
    b = bounce_df.copy()
    b["DT_INSTALLMENTDUE"] = pd.to_datetime(b["DT_INSTALLMENTDUE"], errors="coerce")
    lme = last_month_end()

    def count_window(months):
        start = lme - pd.DateOffset(months=months)
        return (b[(b["DT_INSTALLMENTDUE"] >= start) & (b["DT_INSTALLMENTDUE"] <= lme)]
                .groupby("SZ_LOAN_ACCOUNT_NO")["DT_INSTALLMENTDUE"].nunique().reset_index())

    b3  = count_window(3).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L3M"})
    b6  = count_window(6).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L6M"})
    b12 = count_window(12).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L12M"})
    result = b3.merge(b6, on="SZ_LOAN_ACCOUNT_NO", how="outer").merge(b12, on="SZ_LOAN_ACCOUNT_NO", how="outer")
    return result.fillna(0)


# %% ── Bajaj Filters ──────────────────────────────────────────────────────────

# %% Filter - Live Case
def filter_live_case(df):
    return df.loc[
        df["LOAN_STATUS"].fillna("").str.upper().eq("APPROVED")
        & df["DISBURSEMENT_STATUS"].fillna("").str.upper().isin(["FULL", "FULLY"])
        & (to_number(df, "POS_CURRENT") > 0)
    ]

# %% Filter - Not Funded
def filter_not_funded(df):
    return df.loc[
        df["SZ_FUNDER_STATUS"].isna()
        & df["DIRECT_ASSIGNMENT"].isna()
        & ~df["NHB"].fillna("").str.upper().str.contains("NHB")
        & df["SZ_NABARD_NAME"].isna()
        & df["REFINANCE_SCHEME"].isna()
        & df["SZ_FUNDER_NAME"].isna()
    ]

# %% Filter - MOB
def filter_mob(df):
    return df.loc[to_number(df, "MOB_FIRST_DISB") >= 6]

# %% Filter - Restructured
def filter_not_restructured(df):
    return df.loc[
        (to_number(df, "IS_RESTRUCTURED") == 0)
        & df["MORAT_FLAG"].fillna("N").str.upper().ne("Y")
        & (to_number(df, "EVER_NPA") == 0)
        & (to_number(df, "EVER_BUCKET") == 0)
    ]

# %% Filter - DPD
def filter_dpd(df):
    return df.loc[
        (to_number(df, "EVER_30_DPD_6M") == 0)
        & (to_number(df, "MAX_DPD_18M", 0) < 30)
        & (to_number(df, "OVERDUE_PRINCIPAL_LM", 0) <= 1000)
        & (to_number(df, "OVERDUE_INTEREST_LM",  0) <= 1000)
    ]

# %% Filter - Bounce
def filter_bounce(df):
    mob = to_number(df, "MOB_FIRST_DISB")
    b3  = to_number(df, "BOUNCE_COUNT_L3M")
    b6  = to_number(df, "BOUNCE_COUNT_L6M")
    b12 = to_number(df, "BOUNCE_COUNT_L12M")
    new_loans = (mob <= 6)  & (b6 == 0)
    mid_loans = (mob > 6)   & (mob <= 12) & (b6 <= 1) & (b3 == 0)
    old_loans = (mob > 12)  & (b12 <= 2)  & (b6 <= 1) & (b3 == 0)
    return df.loc[new_loans | mid_loans | old_loans]

# %% Filter - Property (MSME)
def filter_property(df):
    # MSME also blocks Under Construction — HE does NOT have this check
    ptype = df["PROPERTY_TYPE"].fillna("").str.upper()
    psub  = df["PROPERTY_SUBTYPE"].fillna("").str.upper()
    occ   = df["PROPERTY_OCCUPATION"].fillna("").str.upper()
    return df.loc[
        (to_number(df, "PLOT_COUNT") == 0)
        & (to_number(df, "INDUSTRIAL_SHED_COUNT") == 0)
        & ~ptype.str.contains("VACANT") & ~psub.str.contains("VACANT")
        & ~psub.str.contains("UNDER CONS") & ~occ.str.contains("UNDER CONS")
        & (to_number(df, "RESIDENTIAL_PCT", 0) >= 80)
    ]

# %% Filter - Occupation
def filter_occupation(df):
    occ     = df["SZ_PRIMARY_OCCUPATION"].fillna("").str.upper()
    blocked = pd.Series(False, index=df.index)
    for kw in ["LAWYER", "POLICE", "PEP", "REAL ESTATE", "BROKER", "BUILDER"]:
        blocked |= occ.str.contains(kw)
    return df.loc[~blocked]

# %% Filter - Loan Amount
def filter_loan_amount(df):
    return df.loc[to_number(df, "LOAN_AMOUNT_W_INSURANCE") >= 300_000]

# %% Filter - Age (Bajaj)
def filter_age_bajaj(df):
    age     = to_number(df, "AGE_CURRENT")
    mat_age = pd.to_numeric(df.get("AGE_AT_MATURITY"), errors="coerce")
    return df.loc[(age >= 21) & ((mat_age <= 75) | mat_age.isna())]

# %% Filter - Tenure
def filter_tenure_bajaj(df):
    amt = to_number(df, "LOAN_AMOUNT_W_INSURANCE")
    ten = to_number(df, "TENURE_AT_SANCTION", 9999)
    return df.loc[((amt <= 3_000_000) & (ten <= 180)) | ((amt > 3_000_000) & (ten <= 240))]

# %% Filter - LTV (Bajaj)
def filter_ltv_bajaj(df):
    cibil = to_number(df, "CIBIL_SCORE", -10)
    ltv   = to_number(df, "CALCULATED_LTV", 999)
    occ   = df["PROPERTY_OCCUPATION"].fillna("").str.upper()
    return df.loc[
        (((cibil > 750) | occ.str.contains("SELF")) & (ltv < 75))
        | (ltv < 70)
    ]


# %% ── Bajaj Filter Dict ──────────────────────────────────────────────────────

BAJAJ_FILTERS = {
    "Not live / approved / disbursed":      filter_live_case,
    "Funder / DA / NHB / NABARD assigned":  filter_not_funded,
    "Seasoning < 6 months (MOB < 6)":       filter_mob,
    "Restructured / Morat / NPA / Bucket":  filter_not_restructured,
    "DPD or overdue breach":                filter_dpd,
    "Bounce norms not met":                 filter_bounce,
    "Property restrictions":                filter_property,
    "Blacklisted occupation":               filter_occupation,
    "Loan amount < 3L":                     filter_loan_amount,
    "Age not in 21-75 range":               filter_age_bajaj,
    "Tenure exceeds limit by amount":       filter_tenure_bajaj,
    "LTV breach":                           filter_ltv_bajaj,
}


# %% ── ABFL Filters ───────────────────────────────────────────────────────────

# %% ABFL Filter - Not Funded
def filter_not_funded_abfl(df):
    # ABFL blocks funder_status = 'A'; NHB uses pattern match (MSME) vs IS NULL (HE)
    return df.loc[
        df["SZ_FUNDER_STATUS"].fillna("").str.upper().ne("A")
        & df["DIRECT_ASSIGNMENT"].isna()
        & df["REFINANCE_SCHEME"].isna()
        & df["SZ_NABARD_NAME"].isna()
        & ~df["NHB"].fillna("").str.upper().str.contains("NHB")
        & df["SZ_FUNDER_NAME"].isna()
    ]

# %% ABFL Filter - Seasoning
def filter_seasoning_abfl(df):
    return df.loc[to_number(df, "SEASONING_DAYS") >= 180]

# %% ABFL Filter - Sanction Amount
def filter_sanction_amount_abfl(df):
    sa = to_number(df, "SANCTIONED_AMOUNT")
    return df.loc[(sa >= 300_000) & (sa <= 20_000_000)]

# %% ABFL Filter - Balance Tenure
def filter_balance_tenure_abfl(df):
    return df.loc[to_number(df, "BALANCE_TENURE", 9999) <= 174]

# %% ABFL Filter - Original Tenure
def filter_original_tenure_abfl(df):
    return df.loc[to_number(df, "TENURE_AT_SANCTION", 9999) <= 180]

# %% ABFL Filter - Age
def filter_age_abfl(df):
    # SALARIED <= 60, SENP/NULL <= 70; OTHER profile is rejected (no pass in SQL)
    age     = to_number(df, "AGE_CURRENT")
    mat_age = pd.to_numeric(df.get("AGE_AT_MATURITY"), errors="coerce")
    profile = df["PROFILE_TYPE"].fillna("").str.upper()
    mat_ok  = (
        ((profile == "SALARIED") & ((mat_age <= 60) | mat_age.isna()))
        | ((profile == "SENP")   & ((mat_age <= 70) | mat_age.isna()))
        | ((profile == "")       & ((mat_age <= 70) | mat_age.isna()))
    )
    return df.loc[(age >= 18) & mat_ok]

# %% ABFL Filter - LTV Origination
def filter_ltv_origination_abfl(df):
    # Tiered: residential <= 70%, commercial/mixed <= 60%
    # Uses LTV_ORIGINATION (ltv_wo_insurance from SQL), NOT current LTV
    ptype    = df["PROPERTY_TYPE"].fillna("").str.lower()
    psub     = df["PROPERTY_SUBTYPE"].fillna("").str.lower()
    ltv      = to_number(df, "LTV_ORIGINATION", 999)
    comm_cnt = to_number(df, "COMMERCIAL_PROPERTY_CNT", 1)
    is_pure_res = (
        (comm_cnt == 0)
        & ptype.str.startswith("residential")
        & ~ptype.str.contains("commercial") & ~ptype.str.contains("mix")
        & ~psub.str.contains("commercial")  & ~psub.str.contains("mix")
    )
    return df.loc[
        (to_number(df, "TOTAL_PROPERTY_VALUE", 0) > 0)
        & ((is_pure_res & (ltv <= 70)) | (~is_pure_res & (ltv <= 60)))
    ]

# %% ABFL Filter - Property Type
def filter_property_type_abfl(df):
    ptype  = df["PROPERTY_TYPE"].fillna("").str.lower()
    psub   = df["PROPERTY_SUBTYPE"].fillna("").str.lower()
    pocc   = df["PROPERTY_OCCUPATION"].fillna("").str.lower()
    allowed = (ptype.str.startswith("residential") | ptype.str.startswith("commercial") | ptype.str.startswith("mix")
               | psub.str.startswith("residential") | psub.str.startswith("commercial") | psub.str.startswith("mix"))
    blocked = (ptype.str.contains("industrial") | ptype.str.contains("plot") | ptype.str.contains("vacant")
               | psub.str.contains("industrial") | psub.str.contains("plot")
               | psub.str.contains("vacant") | psub.str.contains("under cons")
               | pocc.str.contains("under cons"))
    return df.loc[allowed & ~blocked]

# %% ABFL Filter - Overdue
def filter_overdue_abfl(df):
    return df.loc[
        (to_number(df, "OVERDUE_PRINCIPAL_LM", 0) == 0)
        & (to_number(df, "OVERDUE_INTEREST_LM",  0) == 0)
    ]

# %% ABFL Filter - NPA & Current DPD
def filter_npa_current_dpd_abfl(df):
    return df.loc[
        df["NPA_FLAG"].fillna("N").str.upper().eq("N")
        & (to_number(df, "CURRENT_DPD", 0) < 30)
    ]

# %% ABFL Filter - Peak DPD Ever
def filter_peak_dpd_ever_abfl(df):
    return df.loc[to_number(df, "MAX_DPD_EVER", 0) < 90]

# %% ABFL Filter - DPD 18M
def filter_dpd_18m_abfl(df):
    return df.loc[to_number(df, "MAX_DPD_18M", 0) < 30]

# %% ABFL Filter - Bounce L12M
def filter_bounce_l12m_abfl(df):
    return df.loc[to_number(df, "BOUNCE_COUNT_L12M", 0) == 0]

# %% ABFL Filter - Restructured
def filter_restructured_abfl(df):
    return df.loc[df["RESTRUCTURE_FLAG"].fillna("N").str.upper().ne("Y")]

# %% ABFL Filter - Serviceable Pincode
def filter_serviceable_abfl(df):
    return df.loc[to_number(df, "IS_ABHFL_SERVICEABLE", 0) == 1]


# %% ── ABFL Filter Dict ───────────────────────────────────────────────────────

ABFL_FILTERS = {
    "Not live / approved / disbursed":           filter_live_case,
    "Funder / DA assigned (ABFL rules)":         filter_not_funded_abfl,
    "Seasoning < 180 days":                      filter_seasoning_abfl,
    "Sanction not in 3L-2Cr range":              filter_sanction_amount_abfl,
    "Balance tenure > 174 months":               filter_balance_tenure_abfl,
    "Original tenure > 180 months":              filter_original_tenure_abfl,
    "Age / maturity breach (ABFL)":              filter_age_abfl,
    "LTV origination breach (res>70/comm>60)":   filter_ltv_origination_abfl,
    "Property type not res/comm/mix":            filter_property_type_abfl,
    "Overdue not zero":                          filter_overdue_abfl,
    "NPA flag or current DPD >= 30":             filter_npa_current_dpd_abfl,
    "Peak DPD ever >= 90":                       filter_peak_dpd_ever_abfl,
    "DPD 18M >= 30":                             filter_dpd_18m_abfl,
    "Bounce in L12M":                            filter_bounce_l12m_abfl,
    "Restructured (loan flag)":                  filter_restructured_abfl,
    "Pincode not ABHFL serviceable":             filter_serviceable_abfl,
}


# %% ── Bajaj Eligibility Dict ─────────────────────────────────────────────────
# CIBIL = -1 means no score on file; Bajaj includes these loans.

def bajaj_eligible_700(df):
    cibil = to_number(df, "CIBIL_SCORE", -10)
    return df.loc[(cibil >= 700) | (cibil == -1)]

def bajaj_eligible_675(df):
    cibil = to_number(df, "CIBIL_SCORE", -10)
    return df.loc[(cibil >= 675) | (cibil == -1)]

def bajaj_eligible_700_udyam(df):
    return bajaj_eligible_700(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 1]

def bajaj_eligible_700_no_udyam(df):
    return bajaj_eligible_700(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 0]

def bajaj_eligible_675_udyam(df):
    return bajaj_eligible_675(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 1]

def bajaj_eligible_675_no_udyam(df):
    return bajaj_eligible_675(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 0]

BAJAJ_ELIGIBILITY = {
    "BAJAJ_700":            bajaj_eligible_700,
    "BAJAJ_675":            bajaj_eligible_675,
    "BAJAJ_700_WITH_UDYAM": bajaj_eligible_700_udyam,
    "BAJAJ_700_NO_UDYAM":   bajaj_eligible_700_no_udyam,
    "BAJAJ_675_WITH_UDYAM": bajaj_eligible_675_udyam,
    "BAJAJ_675_NO_UDYAM":   bajaj_eligible_675_no_udyam,
}


# %% ── ABFL Eligibility Dict ──────────────────────────────────────────────────
# Individual applicants: CIBIL >= threshold. Org applicants: auto-pass.

def abfl_eligible(df, threshold):
    # SQL: LIKE '%I%' = Individual needs CIBIL >= threshold (no-score excluded); NOT LIKE '%I%' = Org auto-passes
    is_individual = df["SZ_APPL_CATEGORY_CODE"].fillna("").str.upper().str.contains("I")
    cibil = to_number(df, "CIBIL_SCORE", -10)
    return df.loc[(is_individual & (cibil >= threshold)) | ~is_individual]

def abfl_eligible_700(df): return abfl_eligible(df, 700)
def abfl_eligible_675(df): return abfl_eligible(df, 675)

ABFL_ELIGIBILITY = {
    "ABFL_700": abfl_eligible_700,
    "ABFL_675": abfl_eligible_675,
}


# %% ── Tracking Helpers ───────────────────────────────────────────────────────

def record_rejections(all_df, passed_df, reason, log, rejected_df):
    new_rej     = all_df.loc[~all_df["LAN"].isin(passed_df["LAN"])].copy()
    rejected_df = pd.concat([rejected_df, new_rej]).drop_duplicates(subset=["LAN"])
    for lan in new_rej["LAN"]:
        log.setdefault(lan, []).append(reason)
    return log, rejected_df

def add_rejection_col(df, log, prefix):
    df = df.copy()
    df[f"{prefix}_REJECTION_REASON"] = df["LAN"].map(
        lambda x: ", ".join(log[x]) if x in log else "NA"
    )
    return df

def flag_col(df, eligible_lans, col):
    df[col] = df["LAN"].isin(eligible_lans).map({True: "Eligible", False: "Ineligible"})
    return df


# %% ── Main ───────────────────────────────────────────────────────────────────

def main():
    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)
    ts = pd.Timestamp.now().strftime("%Y%m%d_%H%M%S")

    print("Stage 1: loading data from Redshift...")
    with get_connection() as conn:
        loans_df       = run_query(conn, SQL_LOANS.read_text(encoding="utf-8"))
        assets_df      = run_query(conn, SQL_ASSETS.read_text(encoding="utf-8"))
        dpd_df         = run_query(conn, SQL_DPD.read_text(encoding="utf-8"))
        bounce_df      = run_query(conn, SQL_BOUNCE.read_text(encoding="utf-8"))
        restructure_df = run_query(conn, SQL_RESTRUCTURE.read_text(encoding="utf-8"))
        serviceable_df = run_query(conn, SQL_SERVICEABLE.read_text(encoding="utf-8"))
    print(f"  raw_rows = {len(loans_df)}")

    print("Stage 2: calculating derived fields...")
    df = derive_base_fields(loans_df)
    df["LAN"] = df["SZ_LOAN_ACCOUNT_NO"].astype(str)

    df = df.merge(derive_property_summary(assets_df, df), on="SZ_APPLICATION_NO",  how="left")
    df = df.merge(derive_dpd_summary(dpd_df),             on="SZ_LOAN_ACCOUNT_NO", how="left")
    df = df.merge(derive_bounce_summary(bounce_df),        on="SZ_LOAN_ACCOUNT_NO", how="left")

    df["IS_RESTRUCTURED"]      = df["LAN"].isin(set(restructure_df["SZ_LOAN_ACCOUNT_NO"].astype(str))).astype(int)
    df["IS_ABHFL_SERVICEABLE"] = df["PIN_CODE"].astype(str).str.strip().isin(
        set(serviceable_df["PINCODE"].astype(str).str.strip())
    ).astype(int)

    today           = pd.Timestamp.today().normalize()
    df["DT_CERSAI"] = pd.to_datetime(df.get("DT_CERSAI"), errors="coerce")
    anchor          = df["DT_CERSAI"].fillna(df["FIRST_DISB_DATE"])
    df["MOB_FIRST_DISB"]  = anchor.apply(lambda d: math.ceil((today - d).days / 30.44) if pd.notna(d) else 0)
    df["SEASONING_DAYS"]  = anchor.apply(lambda d: (today - d).days if pd.notna(d) else 0)
    df["CALCULATED_LTV"]  = to_number(df, "POS_CURRENT") * 100.0 / df["TOTAL_PROPERTY_VALUE"].replace(0, pd.NA)
    df["LTV_ORIGINATION"] = pd.to_numeric(df.get("LTV_ORIGINATION"), errors="coerce")

    for c in ["BOUNCE_COUNT_L3M","BOUNCE_COUNT_L6M","BOUNCE_COUNT_L12M",
              "EVER_30_DPD_6M","MAX_DPD_18M","MAX_DPD_EVER","EVER_NPA","EVER_BUCKET",
              "OVERDUE_PRINCIPAL_LM","OVERDUE_INTEREST_LM","COMMERCIAL_PROPERTY_CNT"]:
        df[c] = df.get(c, pd.Series(0.0)).fillna(0)

    print("Stage 3a: applying Bajaj filters...")
    bajaj_log, bajaj_rej = {}, pd.DataFrame(columns=df.columns)
    for reason, fn in BAJAJ_FILTERS.items():
        bajaj_log, bajaj_rej = record_rejections(df, fn(df), reason, bajaj_log, bajaj_rej)
    bajaj_passed = df.loc[~df["LAN"].isin(bajaj_rej["LAN"])].copy()
    print(f"  passed = {len(bajaj_passed)}  |  rejected = {len(bajaj_rej)}")

    print("Stage 3b: applying ABFL filters...")
    abfl_log, abfl_rej = {}, pd.DataFrame(columns=df.columns)
    for reason, fn in ABFL_FILTERS.items():
        abfl_log, abfl_rej = record_rejections(df, fn(df), reason, abfl_log, abfl_rej)
    abfl_passed = df.loc[~df["LAN"].isin(abfl_rej["LAN"])].copy()
    print(f"  passed = {len(abfl_passed)}  |  rejected = {len(abfl_rej)}")

    print("Stage 4: applying eligibility criteria...")
    bajaj_pools = {name: fn(bajaj_passed) for name, fn in BAJAJ_ELIGIBILITY.items()}
    abfl_pools  = {name: fn(abfl_passed)  for name, fn in ABFL_ELIGIBILITY.items()}
    for name, pool in {**bajaj_pools, **abfl_pools}.items():
        print(f"  {name} = {len(pool)}")

    print("Stage 5: writing output...")
    df = add_rejection_col(df, bajaj_log, "BAJAJ")
    df = add_rejection_col(df, abfl_log,  "ABFL")
    df = flag_col(df, bajaj_passed["LAN"], "BAJAJ_HARD_FILTER_PASS")
    df = flag_col(df, abfl_passed["LAN"],  "ABFL_HARD_FILTER_PASS")
    for name, pool in {**bajaj_pools, **abfl_pools}.items():
        df = flag_col(df, pool["LAN"], f"ELIGIBLE_{name}")

    out_file = OUTPUT_FOLDER / f"msme_final_{ts}.csv"
    df.to_csv(out_file, index=False)

    print(f"\n{'='*50}")
    print(f"  total loans            = {len(df)}")
    print(f"  bajaj_hard_filter_pass = {(df['BAJAJ_HARD_FILTER_PASS'] == 'Eligible').sum()}")
    print(f"  abfl_hard_filter_pass  = {(df['ABFL_HARD_FILTER_PASS'] == 'Eligible').sum()}")
    for name in {**bajaj_pools, **abfl_pools}:
        print(f"  eligible_{name:<22} = {(df[f'ELIGIBLE_{name}'] == 'Eligible').sum()}")
    print(f"  output = {out_file}")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()
