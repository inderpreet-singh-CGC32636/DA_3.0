# %% ── Imports & File Paths ─────────────────────────────────────────────────
"""
MSME DA Pool Selection — v5
===========================
This script identifies which MSME loans are eligible for Direct Assignment (DA)
to Bajaj Finance and/or ABFL.

HOW IT WORKS (5 stages):
  Stage 1 — Load    : Pull raw loan + property + DPD + bounce data from Redshift
  Stage 2 — Derive  : Calculate helper columns (age, months-on-book, DPD history, etc.)
  Stage 3a— Bajaj   : Apply all Bajaj hard filters, record why each loan is rejected
  Stage 3b— ABFL    : Apply all ABFL hard filters, record why each loan is rejected
  Stage 4 — Eligible: Layer CIBIL score cutoffs on the hard-filter-passing loans
  Stage 5 — Output  : Write a CSV with Eligible/Ineligible flags per pool

SQL FILES USED (all in the sql/ folder):
  simple_msme_eligible.sql  — base loan universe
  msme_assets.sql           — property / collateral details
  msme_dpd_history.sql      — monthly DPD history (we derive peak DPD from this)
  msme_bounce.sql           — EMI bounce events
  restructure.sql           — restructured loan flags
  abhfl_serviceable.sql     — ABFL serviceable pincodes

KEY DIFFERENCES vs HE (run_he_v5.py):
  - Bajaj property filter ALSO blocks "Under Construction" (HE does not)
  - ABFL LTV is tiered: residential <= 70%, commercial/mixed <= 60%
  - ABFL NHB check uses a pattern match (NOT LIKE '%NHB%'), not IS NULL like HE

v4 → v5 change: code simplified for readability; logic unchanged.
"""

import math
import os
from pathlib import Path

import pandas as pd
import redshift_connector
import yaml

# Paths — relative to this file so the script runs from any machine
THIS_FOLDER     = Path(__file__).resolve().parent
SQL_LOANS       = THIS_FOLDER / "sql" / "simple_msme_eligible.sql"
SQL_ASSETS      = THIS_FOLDER / "sql" / "msme_assets.sql"
SQL_DPD         = THIS_FOLDER / "sql" / "msme_dpd_history.sql"
SQL_BOUNCE      = THIS_FOLDER / "sql" / "msme_bounce.sql"
SQL_RESTRUCTURE = THIS_FOLDER / "sql" / "restructure.sql"
SQL_SERVICEABLE = THIS_FOLDER / "sql" / "abhfl_serviceable.sql"
OUTPUT_FOLDER   = THIS_FOLDER / "output" / "msme_v5"


# %% ── Database Helpers ──────────────────────────────────────────────────────

def get_connection():
    """Connect to Redshift. Reads credentials from env vars or database.yaml."""
    env_keys = ["REDSHIFT_HOST", "REDSHIFT_PORT", "REDSHIFT_DB", "REDSHIFT_USER", "REDSHIFT_PASSWORD"]
    if all(os.getenv(k) for k in env_keys):
        return redshift_connector.connect(
            host=os.environ["REDSHIFT_HOST"],
            port=int(os.environ["REDSHIFT_PORT"]),
            database=os.environ["REDSHIFT_DB"],
            user=os.environ["REDSHIFT_USER"],
            password=os.environ["REDSHIFT_PASSWORD"],
            timeout=900,
        )
    # Fallback: read from local config file
    config = yaml.safe_load(Path("d:/2.0/config/database.yaml").read_text(encoding="utf-8"))["database"]
    return redshift_connector.connect(
        host=str(config["host"]),
        port=int(config["port"]),
        database=str(config["database"]),
        user=str(config["user"]),
        password=str(config["password"]),
        timeout=900,
    )


def run_query(conn, sql_text: str) -> pd.DataFrame:
    """Run a SQL string and return a DataFrame with UPPER-CASE column names."""
    result = pd.read_sql_query(sql_text, conn)
    result.columns = [col.strip().upper() for col in result.columns]
    return result


def last_month_end() -> pd.Timestamp:
    """Return the last calendar day of the previous month."""
    today = pd.Timestamp.today().normalize()
    return pd.Timestamp(today.replace(day=1) - pd.Timedelta(days=1))


def to_number(df, column, default=0.0) -> pd.Series:
    """
    Safely convert a DataFrame column to numeric.
    - If the column doesn't exist, return a Series filled with `default`.
    - Non-numeric values (strings, nulls) are replaced with `default`.
    """
    if column not in df.columns:
        return pd.Series(default, index=df.index, dtype="float64")
    return pd.to_numeric(df[column], errors="coerce").fillna(default)


# %% ── Stage 2 Helper: Derive Base Fields ───────────────────────────────────

def derive_base_fields(df: pd.DataFrame) -> pd.DataFrame:
    """
    Add derived columns to the loan DataFrame.
    Source columns come from simple_msme_eligible.sql.
    """
    df = df.copy()
    today = pd.Timestamp.today().normalize()

    # DISBURSEMENT_STATUS: is the loan fully disbursed?
    df["DISBURSEMENT_STATUS"] = df["C_FINAL_DISB_YN"].fillna("").str.upper().apply(
        lambda flag: "FULLY" if flag == "Y" else "PARTIAL"
    )

    # FIRST_DISB_DATE: parse to date
    df["FIRST_DISB_DATE"] = pd.to_datetime(df["FIRST_DISB_DATE"], errors="coerce")

    # MOB_FIRST_DISB: months on book (rounded up)
    df["MOB_FIRST_DISB"] = df["FIRST_DISB_DATE"].apply(
        lambda d: math.ceil((today - d).days / 30.44) if pd.notna(d) else 0
    )

    # AGE_CURRENT: borrower's age today
    df["DT_BIRTH_DATE"] = pd.to_datetime(df["DT_BIRTH_DATE"], errors="coerce")
    df["AGE_CURRENT"] = ((today - df["DT_BIRTH_DATE"]).dt.days / 365.25).apply(
        lambda x: int(x) if pd.notna(x) else 0
    )

    # AGE_AT_MATURITY: borrower's age when the loan ends
    df["MATURITY_DATE_LD"] = pd.to_datetime(df["MATURITY_DATE_LD"], errors="coerce")
    df["AGE_AT_MATURITY"] = df.apply(
        lambda row: int((row["MATURITY_DATE_LD"] - row["DT_BIRTH_DATE"]).days / 365.25)
        if pd.notna(row["MATURITY_DATE_LD"]) and pd.notna(row["DT_BIRTH_DATE"])
        else 999,    # 999 = unknown; treated as NULL in filter logic
        axis=1,
    )

    # CIBIL_SCORE: clean to integer; -1 means "no score on file"
    def clean_cibil(raw_value):
        text = str(raw_value).strip() if pd.notna(raw_value) else ""
        if not text or not text.isdigit():
            return -1
        score = int(text)
        return -1 if score < 300 else score
    df["CIBIL_SCORE"] = df["SZ_CIBIL_SCORE"].apply(clean_cibil)

    # HAS_UDYAM: 1 if borrower has a Udyam registration number
    df["HAS_UDYAM"] = df["UDYAM_AADHAR_NUMBER"].fillna("").str.strip().ne("").astype(int)

    # PROFILE_TYPE: classify income program into SALARIED / SENP / OTHER
    def classify_profile(income_program):
        prog = str(income_program).lower()
        if "salar" in prog:
            return "SALARIED"
        elif "senp" in prog or "sep" in prog:
            return "SENP"
        else:
            return "OTHER"
    df["PROFILE_TYPE"] = df["INCOME_PROGRAM"].fillna("").apply(classify_profile)

    # SEASONING_DAYS: calendar days since first disbursement (ABFL >= 180 day rule)
    df["SEASONING_DAYS"] = df["FIRST_DISB_DATE"].apply(
        lambda d: (today - d).days if pd.notna(d) else 0
    )

    return df


# %% ── Stage 2 Helper: Derive Property Summary ──────────────────────────────

def derive_property_summary(assets_df: pd.DataFrame, loans_df: pd.DataFrame) -> pd.DataFrame:
    """
    Aggregate the asset/property table from one-row-per-asset
    to one-row-per-application.

    Columns produced:
      TOTAL_PROPERTY_VALUE     — sum of all property valuations
      RESIDENTIAL_PCT          — % of total value that is residential
      PLOT_COUNT               — number of plot / land assets
      INDUSTRIAL_SHED_COUNT    — number of industrial shed assets
      COMMERCIAL_PROPERTY_CNT  — number of commercial assets (used in ABFL LTV tier logic)
      PROPERTY_TYPE / SUBTYPE  — from the highest-value asset
      PROPERTY_OCCUPATION      — occupation of highest-value asset
      PROPERTY_PINCODE         — pincode of highest-value asset
      DT_CERSAI                — CERSAI registration date (used for MOB anchor)
    """
    assets = assets_df.copy()

    # Keep only assets linked to loans in our universe
    valid_apps = set(loans_df["SZ_APPLICATION_NO"].astype(str))
    assets = assets[assets["SZ_APPLICATION_NO"].astype(str).isin(valid_apps)].copy()

    # Numeric valuation column
    assets["VAL"] = pd.to_numeric(assets["A_I_TOT_VALUATION"], errors="coerce").fillna(0)

    # Flag each asset by type
    assets["IS_RESIDENTIAL"] = assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("residential").astype(int)
    assets["IS_PLOT"]         = (
        assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("plot")
        | assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("land")
    ).astype(int)
    assets["IS_SHED"]         = (
        assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("industrial")
        | assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("shed")
    ).astype(int)
    assets["IS_COMMERCIAL"]   = assets["PROPERTY_TYPE"].fillna("").str.lower().str.contains("commercial").astype(int)

    # Aggregate to application level
    summary = assets.groupby("SZ_APPLICATION_NO").agg(
        TOTAL_PROPERTY_VALUE    = ("VAL",          "sum"),
        PLOT_COUNT              = ("IS_PLOT",       "sum"),
        INDUSTRIAL_SHED_COUNT   = ("IS_SHED",       "sum"),
        COMMERCIAL_PROPERTY_CNT = ("IS_COMMERCIAL", "sum"),
    ).reset_index()

    # Residential value and percentage
    res_value = (
        assets[assets["IS_RESIDENTIAL"] == 1]
        .groupby("SZ_APPLICATION_NO")["VAL"].sum()
        .reindex(summary["SZ_APPLICATION_NO"])
        .values
    )
    summary["RESIDENTIAL_PROPERTY_VALUE"] = pd.array(res_value, dtype="float64")
    summary["RESIDENTIAL_PROPERTY_VALUE"] = summary["RESIDENTIAL_PROPERTY_VALUE"].fillna(0)
    summary["RESIDENTIAL_PCT"] = (
        summary["RESIDENTIAL_PROPERTY_VALUE"] * 100.0
        / summary["TOTAL_PROPERTY_VALUE"].replace(0, pd.NA)
    ).fillna(0)

    # Top asset details (highest-value asset per application)
    top_asset = (
        assets.sort_values("VAL", ascending=False)
        .groupby("SZ_APPLICATION_NO")
        .first()[["PROPERTY_TYPE", "PROPERTY_SUBTYPE", "PROPERTY_OCCUPATION",
                  "PROPERTY_PINCODE", "SZ_CERSAI_SEC_INT_ID", "DT_CERSAI"]]
        .reset_index()
    )

    return summary.merge(top_asset, on="SZ_APPLICATION_NO", how="left")


# %% ── Stage 2 Helper: Derive DPD Summary ───────────────────────────────────

def derive_dpd_summary(dpd_history_df: pd.DataFrame) -> pd.DataFrame:
    """
    Summarise the full monthly DPD history into one row per loan.

    Columns produced:
      OVERDUE_PRINCIPAL_LM  — overdue principal at last month-end
      OVERDUE_INTEREST_LM   — overdue interest at last month-end
      DPD_LAST_MONTH        — DPD value at last month-end
      EVER_30_DPD_6M        — 1 if DPD ever reached 30+ in last 6 months
      MAX_DPD_18M           — highest DPD in last 18 months  (Bajaj filter)
      MAX_DPD_EVER          — highest DPD across all history  (ABFL filter)
      EVER_NPA              — 1 if loan was ever marked NPA
      EVER_BUCKET           — 1 if loan was ever in SMA/DBT/SUB/LSS or DPD >= 90
    """
    dpd = dpd_history_df.copy()
    dpd["DT_BUSINESSDATE"]     = pd.to_datetime(dpd["DT_BUSINESSDATE"], errors="coerce")
    dpd["I_DPD"]               = pd.to_numeric(dpd["I_DPD"], errors="coerce").fillna(0)
    dpd["F_OVERDUE_PRINCIPAL"] = pd.to_numeric(dpd["F_OVERDUE_PRINCIPAL"], errors="coerce").fillna(0)
    dpd["F_OVERDUE_INTEREST"]  = pd.to_numeric(dpd["F_OVERDUE_INTEREST"], errors="coerce").fillna(0)

    lme                 = last_month_end()
    six_months_ago      = lme - pd.DateOffset(months=6)
    eighteen_months_ago = lme - pd.DateOffset(months=18)

    # ── Last month-end snapshot ──────────────────────────────────────────────
    last_month_rows = dpd[dpd["DT_BUSINESSDATE"] == lme]
    last_month_agg  = last_month_rows.groupby("SZ_LOAN_ACCOUNT_NO").agg(
        OVERDUE_PRINCIPAL_LM = ("F_OVERDUE_PRINCIPAL", "max"),
        OVERDUE_INTEREST_LM  = ("F_OVERDUE_INTEREST",  "max"),
        DPD_LAST_MONTH       = ("I_DPD",               "max"),
    ).reset_index()

    # ── 6-month window: ever DPD >= 30? ─────────────────────────────────────
    rows_6m    = dpd[(dpd["DT_BUSINESSDATE"] >= six_months_ago) & (dpd["DT_BUSINESSDATE"] <= lme)]
    ever_30_6m = rows_6m.groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].apply(
        lambda dpd_values: int((dpd_values >= 30).any())
    ).reset_index().rename(columns={"I_DPD": "EVER_30_DPD_6M"})

    # ── 18-month window: peak DPD ────────────────────────────────────────────
    rows_18m = dpd[(dpd["DT_BUSINESSDATE"] >= eighteen_months_ago) & (dpd["DT_BUSINESSDATE"] <= lme)]
    peak_18m = rows_18m.groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].max().reset_index()
    peak_18m = peak_18m.rename(columns={"I_DPD": "MAX_DPD_18M"})

    # ── All history: absolute peak DPD ──────────────────────────────────────
    all_history = dpd[dpd["DT_BUSINESSDATE"] <= lme]
    peak_ever   = all_history.groupby("SZ_LOAN_ACCOUNT_NO")["I_DPD"].max().reset_index()
    peak_ever   = peak_ever.rename(columns={"I_DPD": "MAX_DPD_EVER"})

    # ── NPA ever ─────────────────────────────────────────────────────────────
    dpd["IS_NPA_ROW"] = (dpd["NPA_FLAG"].fillna("") == "Y").astype(int)
    ever_npa          = dpd.groupby("SZ_LOAN_ACCOUNT_NO")["IS_NPA_ROW"].max().reset_index()
    ever_npa          = ever_npa.rename(columns={"IS_NPA_ROW": "EVER_NPA"})

    # ── Stressed bucket: SMA / DBT / SUB / LSS or DPD >= 90 ────────────────
    all_history = all_history.copy()
    all_history["IS_STRESSED"] = (
        all_history["NPA_FLAG"].fillna("").isin(["SMA", "DBT", "SUB", "LSS"])
        | (all_history["I_DPD"] >= 90)
    ).astype(int)
    ever_bucket = all_history.groupby("SZ_LOAN_ACCOUNT_NO")["IS_STRESSED"].max().reset_index()
    ever_bucket = ever_bucket.rename(columns={"IS_STRESSED": "EVER_BUCKET"})

    # ── Merge all pieces together ─────────────────────────────────────────────
    result = last_month_agg
    for part in [ever_30_6m, peak_18m, peak_ever, ever_npa, ever_bucket]:
        result = result.merge(part, on="SZ_LOAN_ACCOUNT_NO", how="outer")

    numeric_cols = ["OVERDUE_PRINCIPAL_LM", "OVERDUE_INTEREST_LM",
                    "EVER_30_DPD_6M", "MAX_DPD_18M", "MAX_DPD_EVER", "EVER_NPA", "EVER_BUCKET"]
    for col in numeric_cols:
        result[col] = result.get(col, pd.Series(0)).fillna(0)

    return result


# %% ── Stage 2 Helper: Derive Bounce Summary ────────────────────────────────

def derive_bounce_summary(bounce_df: pd.DataFrame) -> pd.DataFrame:
    """
    Count EMI bounces per loan over 3, 6, and 12 month windows.

    Columns produced:
      BOUNCE_COUNT_L3M   — bounces in last 3 months
      BOUNCE_COUNT_L6M   — bounces in last 6 months
      BOUNCE_COUNT_L12M  — bounces in last 12 months
    """
    bounces = bounce_df.copy()
    bounces["DT_INSTALLMENTDUE"] = pd.to_datetime(bounces["DT_INSTALLMENTDUE"], errors="coerce")
    lme = last_month_end()

    def count_bounces_in_window(months_back):
        """Count distinct bounce dates within the last N months."""
        window_start = lme - pd.DateOffset(months=months_back)
        in_window    = bounces[
            (bounces["DT_INSTALLMENTDUE"] >= window_start)
            & (bounces["DT_INSTALLMENTDUE"] <= lme)
        ]
        return in_window.groupby("SZ_LOAN_ACCOUNT_NO")["DT_INSTALLMENTDUE"].nunique().reset_index()

    bounces_3m  = count_bounces_in_window(3).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L3M"})
    bounces_6m  = count_bounces_in_window(6).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L6M"})
    bounces_12m = count_bounces_in_window(12).rename(columns={"DT_INSTALLMENTDUE": "BOUNCE_COUNT_L12M"})

    result = bounces_3m.merge(bounces_6m, on="SZ_LOAN_ACCOUNT_NO", how="outer")
    result = result.merge(bounces_12m,    on="SZ_LOAN_ACCOUNT_NO", how="outer")
    return result.fillna(0)


# %% ── Bajaj Hard Filters ────────────────────────────────────────────────────

# %% Filter - Live Case
def filter_live_case(df):
    """Keep only loans that are: status=APPROVED, fully disbursed, and have POS > 0."""
    is_approved   = df["LOAN_STATUS"].fillna("").str.upper().eq("APPROVED")
    is_fully_disb = df["DISBURSEMENT_STATUS"].fillna("").str.upper().isin(["FULL", "FULLY"])
    has_pos       = to_number(df, "POS_CURRENT") > 0
    return df.loc[is_approved & is_fully_disb & has_pos]


# %% Filter - Not Funded
def filter_not_funded(df):
    """Reject loans already funded or assigned to another party."""
    no_funder        = df["SZ_FUNDER_STATUS"].isna()
    no_direct_assign = df["DIRECT_ASSIGNMENT"].isna()
    no_nhb           = ~df["NHB"].fillna("").str.upper().str.contains("NHB")  # pattern match
    no_nabard        = df["SZ_NABARD_NAME"].isna()
    no_refinance     = df["REFINANCE_SCHEME"].isna()
    no_funder_name   = df["SZ_FUNDER_NAME"].isna()
    return df.loc[no_funder & no_direct_assign & no_nhb & no_nabard & no_refinance & no_funder_name]


# %% Filter - MOB
def filter_mob(df):
    """Keep loans with at least 6 months on book (MOB >= 6)."""
    return df.loc[to_number(df, "MOB_FIRST_DISB") >= 6]


# %% Filter - Restructured
def filter_not_restructured(df):
    """Reject loans that have been restructured, under moratorium, ever NPA, or ever in stressed bucket."""
    not_restructured = to_number(df, "IS_RESTRUCTURED") == 0
    not_morat        = df["MORAT_FLAG"].fillna("N").str.upper().ne("Y")
    never_npa        = to_number(df, "EVER_NPA") == 0
    never_bucket     = to_number(df, "EVER_BUCKET") == 0
    return df.loc[not_restructured & not_morat & never_npa & never_bucket]


# %% Filter - DPD
def filter_dpd(df):
    """
    Reject loans with recent or high DPD, or with outstanding overdue amounts.
    Rules:
      - No DPD of 30+ in the last 6 months
      - Peak DPD in last 18 months must be below 30
      - Overdue principal and interest must each be <= Rs 1,000
    """
    no_30_dpd_in_6m = to_number(df, "EVER_30_DPD_6M") == 0
    peak_18m_ok     = to_number(df, "MAX_DPD_18M", 0) < 30
    overdue_prin_ok = to_number(df, "OVERDUE_PRINCIPAL_LM", 0) <= 1000
    overdue_int_ok  = to_number(df, "OVERDUE_INTEREST_LM", 0) <= 1000
    return df.loc[no_30_dpd_in_6m & peak_18m_ok & overdue_prin_ok & overdue_int_ok]


# %% Filter - Bounce
def filter_bounce(df):
    """
    Bajaj bounce norms depend on loan age (MOB):
      MOB 0–6   : zero bounces in last 6 months
      MOB 7–12  : max 1 bounce in L6M AND zero in last 3 months
      MOB > 12  : max 2 bounces in L12M AND max 1 in L6M AND zero in last 3 months
    """
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
    """
    MSME property rules (stricter than HE):
      - No plot or land assets
      - No industrial sheds
      - No vacant property (type or subtype)
      - No "Under Construction" in subtype or occupation  ← MSME only, HE does NOT have this
      - At least 80% of total property value must be residential
    """
    no_plots        = to_number(df, "PLOT_COUNT") == 0
    no_sheds        = to_number(df, "INDUSTRIAL_SHED_COUNT") == 0
    ptype           = df["PROPERTY_TYPE"].fillna("").str.upper()
    psub            = df["PROPERTY_SUBTYPE"].fillna("").str.upper()
    occ             = df["PROPERTY_OCCUPATION"].fillna("").str.upper()
    no_vacant       = ~ptype.str.contains("VACANT") & ~psub.str.contains("VACANT")
    no_under_cons   = ~psub.str.contains("UNDER CONS") & ~occ.str.contains("UNDER CONS")
    mostly_res      = to_number(df, "RESIDENTIAL_PCT", 0) >= 80
    return df.loc[no_plots & no_sheds & no_vacant & no_under_cons & mostly_res]


# %% Filter - Occupation
def filter_occupation(df):
    """Reject loans where the borrower works in a blocked occupation category."""
    blocked_keywords = ["LAWYER", "POLICE", "PEP", "REAL ESTATE", "BROKER", "BUILDER"]
    occupation       = df["SZ_PRIMARY_OCCUPATION"].fillna("").str.upper()
    is_blocked       = pd.Series(False, index=df.index)
    for keyword in blocked_keywords:
        is_blocked = is_blocked | occupation.str.contains(keyword)
    return df.loc[~is_blocked]


# %% Filter - Loan Amount
def filter_loan_amount(df):
    """Minimum loan amount is Rs 3 lakh."""
    return df.loc[to_number(df, "LOAN_AMOUNT_W_INSURANCE") >= 300_000]


# %% Filter - Age (Bajaj)
def filter_age_bajaj(df):
    """
    Bajaj age rules:
      - Current age 21 to 75
      - Age at loan maturity <= 75 (NULL age_at_maturity is allowed to pass)
    """
    current_age     = to_number(df, "AGE_CURRENT")
    age_at_maturity = pd.to_numeric(df.get("AGE_AT_MATURITY"), errors="coerce")
    maturity_age_ok = (age_at_maturity <= 75) | age_at_maturity.isna()
    return df.loc[(current_age >= 21) & maturity_age_ok]


# %% Filter - Tenure (Bajaj)
def filter_tenure_bajaj(df):
    """
    Bajaj tenure limits by loan amount:
      - Loan <= 30L  : tenure <= 180 months
      - Loan >  30L  : tenure <= 240 months
    """
    loan_amount     = to_number(df, "LOAN_AMOUNT_W_INSURANCE")
    sanction_tenure = to_number(df, "TENURE_AT_SANCTION", 9999)

    small_loan_ok = (loan_amount <= 3_000_000) & (sanction_tenure <= 180)
    large_loan_ok = (loan_amount >  3_000_000) & (sanction_tenure <= 240)
    return df.loc[small_loan_ok | large_loan_ok]


# %% Filter - LTV (Bajaj)
def filter_ltv_bajaj(df):
    """
    Bajaj current LTV rules:
      - If CIBIL > 750 OR property is self-occupied: current LTV < 75%
      - Otherwise: current LTV < 70%
    """
    cibil       = to_number(df, "CIBIL_SCORE", -10)
    current_ltv = to_number(df, "CALCULATED_LTV", 999)
    occupation  = df["PROPERTY_OCCUPATION"].fillna("").str.upper()

    high_cibil_or_self_occ = (cibil > 750) | occupation.str.contains("SELF")
    premium_ok  = high_cibil_or_self_occ & (current_ltv < 75)
    standard_ok = current_ltv < 70
    return df.loc[premium_ok | standard_ok]


# %% ── Bajaj Filter Dictionary ───────────────────────────────────────────────

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


# %% ── ABFL Hard Filters ─────────────────────────────────────────────────────

# %% ABFL Filter - Not Funded
def filter_not_funded_abfl(df):
    """
    ABFL MSME version — NHB uses a pattern match (NOT LIKE '%NHB%'),
    same as Bajaj's check. This differs from HE ABFL which uses IS NULL.
    Funder_status = 'A' (active funder) is the only funder check ABFL applies.
    """
    funder_not_active = df["SZ_FUNDER_STATUS"].fillna("").str.upper().ne("A")
    no_direct_assign  = df["DIRECT_ASSIGNMENT"].isna()
    no_refinance      = df["REFINANCE_SCHEME"].isna()
    no_nabard         = df["SZ_NABARD_NAME"].isna()
    no_nhb            = ~df["NHB"].fillna("").str.upper().str.contains("NHB")   # pattern match (MSME)
    no_funder_name    = df["SZ_FUNDER_NAME"].isna()
    return df.loc[funder_not_active & no_direct_assign & no_refinance & no_nabard & no_nhb & no_funder_name]


# %% ABFL Filter - Seasoning
def filter_seasoning_abfl(df):
    """ABFL requires at least 180 calendar days since first disbursement."""
    return df.loc[to_number(df, "SEASONING_DAYS") >= 180]


# %% ABFL Filter - Sanction Amount
def filter_sanction_amount_abfl(df):
    """ABFL: sanctioned amount must be between Rs 3 lakh and Rs 2 crore."""
    sanction_amt = to_number(df, "SANCTIONED_AMOUNT")
    return df.loc[(sanction_amt >= 300_000) & (sanction_amt <= 20_000_000)]


# %% ABFL Filter - Balance Tenure
def filter_balance_tenure_abfl(df):
    """ABFL: remaining tenure must be 174 months or less."""
    return df.loc[to_number(df, "BALANCE_TENURE", 9999) <= 174]


# %% ABFL Filter - Original Tenure
def filter_original_tenure_abfl(df):
    """ABFL: original (sanction) tenure must be 180 months or less."""
    return df.loc[to_number(df, "TENURE_AT_SANCTION", 9999) <= 180]


# %% ABFL Filter - Age
def filter_age_abfl(df):
    """
    ABFL age rules (stricter than Bajaj):
      - Current age >= 18
      - SALARIED  : age at maturity <= 60 (NULL is allowed)
      - SENP/NULL : age at maturity <= 70 (NULL is allowed)
      - OTHER     : REJECTED — no pass condition for OTHER in SQL
    """
    current_age     = to_number(df, "AGE_CURRENT")
    age_at_maturity = pd.to_numeric(df.get("AGE_AT_MATURITY"), errors="coerce")
    profile         = df["PROFILE_TYPE"].fillna("").str.upper()

    salaried_ok  = (profile == "SALARIED") & ((age_at_maturity <= 60) | age_at_maturity.isna())
    senp_ok      = (profile == "SENP")     & ((age_at_maturity <= 70) | age_at_maturity.isna())
    null_prof_ok = (profile == "")         & ((age_at_maturity <= 70) | age_at_maturity.isna())
    maturity_ok  = salaried_ok | senp_ok | null_prof_ok

    return df.loc[(current_age >= 18) & maturity_ok]


# %% ABFL Filter - LTV Origination
def filter_ltv_origination_abfl(df):
    """
    ABFL MSME uses TIERED origination LTV (at-sanction LTV = ltv_wo_insurance):
      - Pure residential property : LTV <= 70%
      - Commercial or mixed-use   : LTV <= 60%

    "Pure residential" = no commercial assets AND property type starts with "residential"
    AND does not contain "commercial" or "mix" anywhere.

    NOTE: This uses LTV_ORIGINATION (at-sanction), NOT CALCULATED_LTV (current).
    """
    ptype    = df["PROPERTY_TYPE"].fillna("").str.lower()
    psub     = df["PROPERTY_SUBTYPE"].fillna("").str.lower()
    ltv      = to_number(df, "LTV_ORIGINATION", 999)
    comm_cnt = to_number(df, "COMMERCIAL_PROPERTY_CNT", 1)

    is_pure_residential = (
        (comm_cnt == 0)
        & ptype.str.startswith("residential")
        & ~ptype.str.contains("commercial")
        & ~ptype.str.contains("mix")
        & ~psub.str.contains("commercial")
        & ~psub.str.contains("mix")
    )

    has_property    = to_number(df, "TOTAL_PROPERTY_VALUE", 0) > 0
    res_ltv_ok      = is_pure_residential  & (ltv <= 70)
    comm_ltv_ok     = ~is_pure_residential & (ltv <= 60)

    return df.loc[has_property & (res_ltv_ok | comm_ltv_ok)]


# %% ABFL Filter - Property Type
def filter_property_type_abfl(df):
    """
    ABFL accepts only residential, commercial, or mixed-use.
    Blocks: industrial, plot/land, vacant, Under Construction.
    """
    ptype = df["PROPERTY_TYPE"].fillna("").str.lower()
    psub  = df["PROPERTY_SUBTYPE"].fillna("").str.lower()
    pocc  = df["PROPERTY_OCCUPATION"].fillna("").str.lower()

    is_allowed_type = (
        ptype.str.startswith("residential") | ptype.str.startswith("commercial") | ptype.str.startswith("mix")
        | psub.str.startswith("residential") | psub.str.startswith("commercial") | psub.str.startswith("mix")
    )
    is_blocked_type = (
        ptype.str.contains("industrial") | ptype.str.contains("plot") | ptype.str.contains("vacant")
        | psub.str.contains("industrial") | psub.str.contains("plot")
        | psub.str.contains("vacant") | psub.str.contains("under cons")
        | pocc.str.contains("under cons")
    )
    return df.loc[is_allowed_type & ~is_blocked_type]


# %% ABFL Filter - Overdue
def filter_overdue_abfl(df):
    """ABFL requires ZERO overdue amount (Bajaj allows up to Rs 1,000)."""
    no_overdue_principal = to_number(df, "OVERDUE_PRINCIPAL_LM", 0) == 0
    no_overdue_interest  = to_number(df, "OVERDUE_INTEREST_LM",  0) == 0
    return df.loc[no_overdue_principal & no_overdue_interest]


# %% ABFL Filter - NPA and Current DPD
def filter_npa_current_dpd_abfl(df):
    """ABFL: NPA flag must be 'N' AND current DPD must be below 30."""
    npa_clear      = df["NPA_FLAG"].fillna("N").str.upper().eq("N")
    current_dpd_ok = to_number(df, "CURRENT_DPD", 0) < 30
    return df.loc[npa_clear & current_dpd_ok]


# %% ABFL Filter - Peak DPD Ever
def filter_peak_dpd_ever_abfl(df):
    """ABFL: all-time peak DPD must be below 90."""
    return df.loc[to_number(df, "MAX_DPD_EVER", 0) < 90]


# %% ABFL Filter - DPD 18M
def filter_dpd_18m_abfl(df):
    """ABFL: peak DPD in last 18 months must be below 30."""
    return df.loc[to_number(df, "MAX_DPD_18M", 0) < 30]


# %% ABFL Filter - Bounce L12M
def filter_bounce_l12m_abfl(df):
    """ABFL: zero EMI bounces in the last 12 months."""
    return df.loc[to_number(df, "BOUNCE_COUNT_L12M", 0) == 0]


# %% ABFL Filter - Restructured Flag
def filter_restructured_abfl(df):
    """ABFL: the loan's RESTRUCTURE_FLAG must not be 'Y'."""
    return df.loc[df["RESTRUCTURE_FLAG"].fillna("N").str.upper().ne("Y")]


# %% ABFL Filter - Serviceable Pincode
def filter_serviceable_pincode_abfl(df):
    """ABFL: the property pincode must appear in the ABFL serviceable pincode list."""
    return df.loc[to_number(df, "IS_ABHFL_SERVICEABLE", 0) == 1]


# %% ── ABFL Filter Dictionary ────────────────────────────────────────────────

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
    "Pincode not ABHFL serviceable":             filter_serviceable_pincode_abfl,
}


# %% ── Bajaj Eligibility (CIBIL + Udyam) ────────────────────────────────────

def bajaj_eligible_700(df):
    """Bajaj pool: CIBIL >= 700 (or no score = -1)."""
    cibil = to_number(df, "CIBIL_SCORE", -10)
    return df.loc[(cibil >= 700) | (cibil == -1)]

def bajaj_eligible_675(df):
    """Bajaj pool: CIBIL >= 675 (or no score = -1)."""
    cibil = to_number(df, "CIBIL_SCORE", -10)
    return df.loc[(cibil >= 675) | (cibil == -1)]

def bajaj_eligible_700_udyam(df):
    """Bajaj 700 pool with Udyam registration."""
    return bajaj_eligible_700(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 1]

def bajaj_eligible_700_no_udyam(df):
    """Bajaj 700 pool without Udyam registration."""
    return bajaj_eligible_700(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 0]

def bajaj_eligible_675_udyam(df):
    """Bajaj 675 pool with Udyam registration."""
    return bajaj_eligible_675(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 1]

def bajaj_eligible_675_no_udyam(df):
    """Bajaj 675 pool without Udyam registration."""
    return bajaj_eligible_675(df).loc[lambda x: to_number(x, "HAS_UDYAM") == 0]

BAJAJ_ELIGIBILITY = {
    "BAJAJ_700":             bajaj_eligible_700,
    "BAJAJ_675":             bajaj_eligible_675,
    "BAJAJ_700_WITH_UDYAM":  bajaj_eligible_700_udyam,
    "BAJAJ_700_NO_UDYAM":    bajaj_eligible_700_no_udyam,
    "BAJAJ_675_WITH_UDYAM":  bajaj_eligible_675_udyam,
    "BAJAJ_675_NO_UDYAM":    bajaj_eligible_675_no_udyam,
}


# %% ── ABFL Eligibility (CIBIL) ──────────────────────────────────────────────

def abfl_eligible(df, cibil_threshold):
    """ABFL: Individual applicants need CIBIL >= threshold; Org applicants auto-pass."""
    is_org   = df["SZ_APPL_CATEGORY_CODE"].fillna("").str.upper().isin(["CO", "CORP", "TRUST", "HUF"])
    cibil    = to_number(df, "CIBIL_SCORE", -10)
    cibil_ok = (cibil >= cibil_threshold) | (cibil == -1) | is_org
    return df.loc[cibil_ok]

def abfl_eligible_700(df):
    return abfl_eligible(df, 700)

def abfl_eligible_675(df):
    return abfl_eligible(df, 675)

ABFL_ELIGIBILITY = {
    "ABFL_700": abfl_eligible_700,
    "ABFL_675": abfl_eligible_675,
}


# %% ── Filter Tracking Helpers ───────────────────────────────────────────────

def record_rejections(all_loans, passed_loans, reason, rejection_log, rejected_so_far):
    """
    Find which loans did NOT pass the current filter and record the reason.
    Returns updated (rejection_log, rejected_so_far).
    """
    newly_rejected  = all_loans.loc[~all_loans["LAN"].isin(passed_loans["LAN"])].copy()
    rejected_so_far = pd.concat([rejected_so_far, newly_rejected]).drop_duplicates(subset=["LAN"])
    for lan in newly_rejected["LAN"]:
        rejection_log.setdefault(lan, []).append(reason)
    return rejection_log, rejected_so_far


def add_rejection_reason_column(df, rejection_log, prefix):
    """Add a BAJAJ_REJECTION_REASON or ABFL_REJECTION_REASON column. 'NA' means passed all filters."""
    df = df.copy()
    col_name = f"{prefix}_REJECTION_REASON"
    df[col_name] = df["LAN"].map(
        lambda lan: ", ".join(rejection_log[lan]) if lan in rejection_log else "NA"
    )
    return df


def flag_column(df, eligible_lans, col_name):
    """Add an Eligible/Ineligible column based on whether a LAN is in eligible_lans."""
    df[col_name] = df["LAN"].isin(eligible_lans).map({True: "Eligible", False: "Ineligible"})
    return df


# %% ── Main ──────────────────────────────────────────────────────────────────

def main():
    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)
    run_timestamp = pd.Timestamp.now().strftime("%Y%m%d_%H%M%S")

    # ── Stage 1: Load data ────────────────────────────────────────────────────
    print("Stage 1: loading data from Redshift...")
    with get_connection() as conn:
        loans_df       = run_query(conn, SQL_LOANS.read_text(encoding="utf-8"))
        assets_df      = run_query(conn, SQL_ASSETS.read_text(encoding="utf-8"))
        dpd_df         = run_query(conn, SQL_DPD.read_text(encoding="utf-8"))
        bounce_df      = run_query(conn, SQL_BOUNCE.read_text(encoding="utf-8"))
        restructure_df = run_query(conn, SQL_RESTRUCTURE.read_text(encoding="utf-8"))
        serviceable_df = run_query(conn, SQL_SERVICEABLE.read_text(encoding="utf-8"))
    print(f"  raw rows loaded = {len(loans_df)}")

    # ── Stage 2: Derive fields ────────────────────────────────────────────────
    print("Stage 2: calculating derived fields...")
    df = derive_base_fields(loans_df)
    df["LAN"] = df["SZ_LOAN_ACCOUNT_NO"].astype(str)

    property_summary  = derive_property_summary(assets_df, df)
    dpd_summary       = derive_dpd_summary(dpd_df)
    bounce_summary    = derive_bounce_summary(bounce_df)
    restructured_lans = set(restructure_df["SZ_LOAN_ACCOUNT_NO"].astype(str))

    df = df.merge(property_summary, on="SZ_APPLICATION_NO",  how="left")
    df = df.merge(dpd_summary,      on="SZ_LOAN_ACCOUNT_NO", how="left")
    df = df.merge(bounce_summary,   on="SZ_LOAN_ACCOUNT_NO", how="left")
    df["IS_RESTRUCTURED"] = df["LAN"].isin(restructured_lans).astype(int)

    serviceable_pincodes   = set(serviceable_df["PINCODE"].astype(str).str.strip())
    df["IS_ABHFL_SERVICEABLE"] = df["PIN_CODE"].astype(str).str.strip().isin(serviceable_pincodes).astype(int)

    # MOB and SEASONING_DAYS: anchored to CERSAI date if available, else first disbursement
    today           = pd.Timestamp.today().normalize()
    df["DT_CERSAI"] = pd.to_datetime(df.get("DT_CERSAI"), errors="coerce")
    date_anchor     = df["DT_CERSAI"].fillna(df["FIRST_DISB_DATE"])
    df["MOB_FIRST_DISB"]  = date_anchor.apply(
        lambda d: math.ceil((today - d).days / 30.44) if pd.notna(d) else 0
    )
    df["SEASONING_DAYS"] = date_anchor.apply(
        lambda d: (today - d).days if pd.notna(d) else 0
    )

    # CALCULATED_LTV: current POS / current property value (used by Bajaj LTV filter)
    df["CALCULATED_LTV"] = (
        to_number(df, "POS_CURRENT") * 100.0
        / df["TOTAL_PROPERTY_VALUE"].replace(0, pd.NA)
    )
    # LTV_ORIGINATION comes directly from SQL (ltv_wo_insurance = at-sanction LTV)
    df["LTV_ORIGINATION"] = pd.to_numeric(df.get("LTV_ORIGINATION"), errors="coerce")

    # Fill nulls in all numeric derived columns
    derived_numeric_cols = [
        "BOUNCE_COUNT_L3M", "BOUNCE_COUNT_L6M", "BOUNCE_COUNT_L12M",
        "EVER_30_DPD_6M", "MAX_DPD_18M", "MAX_DPD_EVER",
        "EVER_NPA", "EVER_BUCKET",
        "OVERDUE_PRINCIPAL_LM", "OVERDUE_INTEREST_LM",
        "COMMERCIAL_PROPERTY_CNT",
    ]
    for col in derived_numeric_cols:
        df[col] = df.get(col, pd.Series(0.0)).fillna(0)

    # ── Stage 3a: Bajaj hard filters ─────────────────────────────────────────
    print("Stage 3a: applying Bajaj filters...")
    bajaj_rejection_log = {}
    bajaj_rejected      = pd.DataFrame(columns=df.columns)

    for reason, filter_fn in BAJAJ_FILTERS.items():
        passed = filter_fn(df)
        bajaj_rejection_log, bajaj_rejected = record_rejections(
            df, passed, reason, bajaj_rejection_log, bajaj_rejected
        )

    bajaj_passed = df.loc[~df["LAN"].isin(bajaj_rejected["LAN"])].copy()
    print(f"  passed = {len(bajaj_passed)}  |  rejected = {len(bajaj_rejected)}")

    # ── Stage 3b: ABFL hard filters ──────────────────────────────────────────
    print("Stage 3b: applying ABFL filters...")
    abfl_rejection_log = {}
    abfl_rejected      = pd.DataFrame(columns=df.columns)

    for reason, filter_fn in ABFL_FILTERS.items():
        passed = filter_fn(df)
        abfl_rejection_log, abfl_rejected = record_rejections(
            df, passed, reason, abfl_rejection_log, abfl_rejected
        )

    abfl_passed = df.loc[~df["LAN"].isin(abfl_rejected["LAN"])].copy()
    print(f"  passed = {len(abfl_passed)}  |  rejected = {len(abfl_rejected)}")

    # ── Stage 4: CIBIL eligibility ────────────────────────────────────────────
    print("Stage 4: applying eligibility criteria...")
    bajaj_eligible_pools = {}
    for pool_name, elig_fn in BAJAJ_ELIGIBILITY.items():
        bajaj_eligible_pools[pool_name] = elig_fn(bajaj_passed)
        print(f"  {pool_name} = {len(bajaj_eligible_pools[pool_name])}")

    abfl_eligible_pools = {}
    for pool_name, elig_fn in ABFL_ELIGIBILITY.items():
        abfl_eligible_pools[pool_name] = elig_fn(abfl_passed)
        print(f"  {pool_name} = {len(abfl_eligible_pools[pool_name])}")

    # ── Stage 5: Write output ─────────────────────────────────────────────────
    print("Stage 5: writing output...")

    df = add_rejection_reason_column(df, bajaj_rejection_log, prefix="BAJAJ")
    df = add_rejection_reason_column(df, abfl_rejection_log,  prefix="ABFL")

    df = flag_column(df, bajaj_passed["LAN"], "BAJAJ_HARD_FILTER_PASS")
    df = flag_column(df, abfl_passed["LAN"],  "ABFL_HARD_FILTER_PASS")

    for pool_name, elig_df in bajaj_eligible_pools.items():
        df = flag_column(df, elig_df["LAN"], f"ELIGIBLE_{pool_name}")
    for pool_name, elig_df in abfl_eligible_pools.items():
        df = flag_column(df, elig_df["LAN"], f"ELIGIBLE_{pool_name}")

    out_file = OUTPUT_FOLDER / f"msme_v5_{run_timestamp}.csv"
    df.to_csv(out_file, index=False)

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"\n{'='*50}")
    print(f"  total loans              = {len(df)}")
    print(f"  bajaj_hard_filter_pass   = {(df['BAJAJ_HARD_FILTER_PASS'] == 'Eligible').sum()}")
    print(f"  abfl_hard_filter_pass    = {(df['ABFL_HARD_FILTER_PASS'] == 'Eligible').sum()}")
    for pool_name in bajaj_eligible_pools:
        count = (df[f"ELIGIBLE_{pool_name}"] == "Eligible").sum()
        print(f"  eligible_{pool_name:<22} = {count}")
    for pool_name in abfl_eligible_pools:
        count = (df[f"ELIGIBLE_{pool_name}"] == "Eligible").sum()
        print(f"  eligible_{pool_name:<22} = {count}")
    print(f"  output file              = {out_file}")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()
