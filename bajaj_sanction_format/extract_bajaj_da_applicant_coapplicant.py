"""
Bajaj DA Applicant + Co-Applicant extraction.

Builds one Excel with two sheets:
1) Applicant
2) Co applicant

Loan universe source:
- external_curated.da_he_ab
- external_curated.da_msme_ab

Default universe filter:
- Bajaj eligibility at 700 == 1
"""

from __future__ import annotations

import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Dict, Tuple

import pandas as pd
import yaml


ROOT_DIR = Path(__file__).resolve().parents[2]
BAJAJ_DIR = ROOT_DIR / "bajaj_da"
CONFIG_PATH = BAJAJ_DIR / "config" / "database.yaml"
GLOBAL_CONFIG_PATH = ROOT_DIR / "config" / "database.yaml"
OUTPUT_DIR = Path(os.getenv("BAJAJ_OUTPUT_DIR", str(BAJAJ_DIR / "outputs")))
LOG_DIR = Path(os.getenv("BAJAJ_LOG_DIR", str(OUTPUT_DIR / "logs")))

TIMESTAMP = datetime.now().strftime("%Y%m%d_%H%M%S")

# Options: "700", "675", "all"
# "675" is a superset of "700" — includes all 675-eligible loans (CIBIL >= 675)
ELIGIBILITY_MODE = os.getenv("BAJAJ_ELIGIBILITY_MODE", "675").strip().lower()

# Snapshot anchor: last calendar day of the previous month (e.g. 30-Apr-2026)
CUTOFF_SQL = "DATEADD(day, -1, DATE_TRUNC('month', CURRENT_DATE))"


def setup_logging() -> logging.Logger:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_file = LOG_DIR / f"bajaj_da_applicant_coapp_{TIMESTAMP}.log"
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[
            logging.FileHandler(log_file, encoding="utf-8"),
            logging.StreamHandler(),
        ],
    )
    logger = logging.getLogger(__name__)
    logger.info("Log file: %s", log_file)
    return logger


def load_yaml(path: Path) -> Dict:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def load_db_config() -> Dict:
    cfg = load_yaml(CONFIG_PATH)
    db_cfg = cfg.get("database") or cfg.get("db") or {}
    host_val = str(db_cfg.get("host", "")).strip()
    if (not host_val) or host_val.startswith("<"):
        global_cfg = load_yaml(GLOBAL_CONFIG_PATH)
        db_cfg = global_cfg.get("database") or global_cfg.get("db") or {}
    return db_cfg


def get_connection(db_cfg: Dict):
    import redshift_connector

    required = ["host", "port", "database", "user", "password"]
    missing = [k for k in required if not db_cfg.get(k)]
    if missing:
        raise ValueError(f"Missing DB config keys: {missing}")

    return redshift_connector.connect(
        host=db_cfg["host"],
        port=int(db_cfg["port"]),
        database=db_cfg["database"],
        user=db_cfg["user"],
        password=db_cfg["password"],
        timeout=1800,
    )


def eligibility_clause(alias: str) -> str:
    if ELIGIBILITY_MODE == "675":
        return f"COALESCE({alias}.bajaj_overall_eligibility_at_675, 0) = 1"
    if ELIGIBILITY_MODE == "all":
        return "1 = 1"
    return f"COALESCE({alias}.bajaj_overall_eligibility_at_700, 0) = 1"


def build_common_target_loans_sql() -> str:
    he_filter = eligibility_clause("h")
    msme_filter = eligibility_clause("m")
    return f"""
WITH target_loans AS (
    SELECT
        'HFLA' AS pool_type,
        'CGHFL' AS entity_type,
        CAST(h.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        CAST(h.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(h.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        h.customer_name,
        h.pan,
        h.dt_birth_date,
        h.c_gender,
        h.phone_number,
        h.email,
        h.pin_code,
        h.city,
        h.state,
        h.loan_status,
        h.sanctioned_amount,
        h.first_disb_date,
        h.sanction_date,
        h.latest_disb_date,
        h.loan_amount_w_insurance,
        h.current_interest_rate,
        h.tenure_at_sanction,
        h.pos_current,
        h.emi_amount,
        h.emis_paid,
        h.current_total_tenure,
        h.balance_tenure,
        h.final_maturity_date,
        h.foir,
        h.cibil_score,
        h.current_dpd,
        h.dpd_last_month,
        h.bounce_count_l6m,
        h.bounce_count_l12m,
        h.max_dpd_ever,
        h.age_current,
        h.age_at_maturity,
        h.sz_repayment_mode,
        h.ltv,
        h.calculated_ltv,
        h.property_type,
        h.sz_cersai_sec_int_id,
        h.cersai_registration_date
    FROM external_curated.da_he_ab h
    WHERE {he_filter}

    UNION ALL

    SELECT
        'MSME' AS pool_type,
        'CGCL' AS entity_type,
        CAST(m.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        CAST(m.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(m.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        m.customer_name,
        m.pan,
        m.dt_birth_date,
        m.c_gender,
        m.phone_number,
        m.email,
        m.pin_code,
        m.city,
        m.state,
        m.loan_status,
        m.sanctioned_amount,
        m.first_disb_date,
        m.sanction_date,
        m.latest_disb_date,
        m.loan_amount_w_insurance,
        m.current_interest_rate,
        m.tenure_at_sanction,
        m.pos_current,
        m.emi_amount,
        m.emis_paid,
        m.current_total_tenure,
        m.balance_tenure,
        m.final_maturity_date,
        m.foir,
        m.cibil_score,
        m.current_dpd,
        m.dpd_last_month,
        m.bounce_count_l6m,
        m.bounce_count_l12m,
        m.max_dpd_ever,
        m.age_current,
        m.age_at_maturity,
        m.sz_repayment_mode,
        m.ltv,
        m.calculated_ltv,
        m.property_type,
        m.sz_cersai_sec_int_id,
        m.cersai_registration_date
    FROM external_curated.da_msme_ab m
    WHERE {msme_filter}
)
"""


def build_applicant_sql() -> str:
    common = build_common_target_loans_sql()
    sql = (
        common
        + """
, borrower_dim AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(apt.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(apt.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CAST(apt.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        COALESCE(apt.person_name, apt.sz_org_name) AS customer_name,
        NVL(NULLIF(TRIM(apt.sz_id2), ''), NULLIF(TRIM(apt.sz_panno), '')) AS pan,
        apt.dt_birth_date AS dob,
        apt.dt_birth_date AS doi,
        apt.c_gender,
        apt.sz_primary_occupation AS employment_type,
        apt.final_income,
        apt.c_incm_consid,
        apt.sz_cibil_score
    FROM analytics_reporting.applicant_basic_dtl_cghfl apt
    WHERE apt.sz_appl_type_code = 'BORROWER'

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(apt.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(apt.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CAST(apt.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        COALESCE(apt.person_name, apt.sz_org_name) AS customer_name,
        NVL(NULLIF(TRIM(apt.sz_id2), ''), NULLIF(TRIM(apt.sz_panno), '')) AS pan,
        apt.dt_birth_date AS dob,
        apt.dt_birth_date AS doi,
        apt.c_gender,
        apt.sz_primary_occupation AS employment_type,
        apt.final_income,
        apt.c_incm_consid,
        apt.sz_cibil_score
    FROM analytics_reporting.applicant_basic_dtl_cgcl apt
    WHERE apt.sz_appl_type_code = 'BORROWER'
),
contact_dim AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(addr.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(addr.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CASE
            WHEN LENGTH(addr.SZ_MOBILE1) = 10 THEN addr.SZ_MOBILE1::VARCHAR
            WHEN LENGTH(addr.SZ_MOBILE2) = 10 THEN addr.SZ_MOBILE2::VARCHAR
            WHEN LENGTH(addr.sz_mobile_no) = 10 THEN addr.sz_mobile_no::VARCHAR
            WHEN LENGTH(CAST(addr.current_i_mobileno AS VARCHAR)) >= 10 THEN CAST(addr.current_i_mobileno AS VARCHAR)
            ELSE NULL
        END AS mobile_number,
        NVL(NVL(addr.sz_email_id1, addr.sz_email_id2), NVL(addr.sz_email, addr.sz_email1)) AS email,
        TRIM(COALESCE(addr.current_sz_address_1, '') || ' ' ||
             COALESCE(addr.current_sz_address_2, '') || ' ' ||
             COALESCE(addr.current_sz_address_3, '')) AS complete_address,
        addr.current_sz_postal_code AS pin,
        addr.current_city AS city,
        addr.current_state AS state
    FROM analytics_reporting.applicant_address_contact_dtl_cghfl addr

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(addr.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(addr.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CASE
            WHEN LENGTH(addr.SZ_MOBILE1) = 10 THEN addr.SZ_MOBILE1::VARCHAR
            WHEN LENGTH(addr.SZ_MOBILE2) = 10 THEN addr.SZ_MOBILE2::VARCHAR
            WHEN LENGTH(addr.sz_mobile_no) = 10 THEN addr.sz_mobile_no::VARCHAR
            WHEN LENGTH(CAST(addr.current_i_mobileno AS VARCHAR)) >= 10 THEN CAST(addr.current_i_mobileno AS VARCHAR)
            ELSE NULL
        END AS mobile_number,
        NVL(NVL(addr.sz_email_id1, addr.sz_email_id2), NVL(addr.sz_email, addr.sz_email1)) AS email,
        TRIM(COALESCE(addr.current_sz_address_1, '') || ' ' ||
             COALESCE(addr.current_sz_address_2, '') || ' ' ||
             COALESCE(addr.current_sz_address_3, '')) AS complete_address,
        addr.current_sz_postal_code AS pin,
        addr.current_city AS city,
        addr.current_state AS state
    FROM analytics_reporting.applicant_address_contact_dtl_cgcl addr
),
loan_dim AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(ld.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        ld."cumulative amount disbursed" AS disbursed_amount,
        ld.i_cycleday AS presentation_day,
        ld.sanction_date AS loan_agreement_sign_date,
        ld.f_sanctioned_amt AS sanction_amount_raw
    FROM analytics_reporting.loan_dtl_cghfl ld

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(ld.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        ld."cumulative amount disbursed" AS disbursed_amount,
        ld.i_cycleday AS presentation_day,
        ld.sanction_date AS loan_agreement_sign_date,
        ld.f_sanctioned_amt AS sanction_amount_raw
    FROM analytics_reporting.loan_dtl_cgcl ld
),
asset_best AS (
    SELECT
        entity_type,
        sz_application_no,
        collateral_description,
        collateral_use,
        property_ownership,
        age_of_property
    FROM (
        SELECT
            'CGHFL' AS entity_type,
            CAST(a.sz_application_no AS VARCHAR(100)) AS sz_application_no,
            a.sz_description AS collateral_description,
            a.property_occupation AS collateral_use,
            a.property_ownership_mode AS property_ownership,
            a.i_asset_age AS age_of_property,
            ROW_NUMBER() OVER (
                PARTITION BY a.sz_application_no
                ORDER BY a.a_i_tot_valuation DESC NULLS LAST, a.dt_valdate DESC NULLS LAST
            ) AS rn
        FROM analytics_reporting.asset_cghfl a
        WHERE a.sz_application_no IS NOT NULL

        UNION ALL

        SELECT
            'CGCL' AS entity_type,
            CAST(a.sz_application_no AS VARCHAR(100)) AS sz_application_no,
            a.sz_description AS collateral_description,
            a.property_occupation AS collateral_use,
            a.property_ownership_mode AS property_ownership,
            a.i_asset_age AS age_of_property,
            ROW_NUMBER() OVER (
                PARTITION BY a.sz_application_no
                ORDER BY a.a_i_tot_valuation DESC NULLS LAST, a.dt_valdate DESC NULLS LAST
            ) AS rn
        FROM analytics_reporting.asset_cgcl a
        WHERE a.sz_application_no IS NOT NULL
    ) x
    WHERE rn = 1
),
active_loans AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(ld.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        COUNT(DISTINCT ld.sz_loan_account_no) AS number_of_active_loans
    FROM analytics_reporting.loan_dtl_cghfl ld
    WHERE ld.loan_status = 'APPROVED'
      AND UPPER(NVL(ld.c_final_disb_yn, '')) = 'Y'
    GROUP BY ld.sz_customer_no

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(ld.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        COUNT(DISTINCT ld.sz_loan_account_no) AS number_of_active_loans
    FROM analytics_reporting.loan_dtl_cgcl ld
    WHERE ld.loan_status = 'APPROVED'
      AND UPPER(NVL(ld.c_final_disb_yn, '')) = 'Y'
    GROUP BY ld.sz_customer_no
),
repay_rollup AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(r.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        MIN(r.dt_installmentdue) AS first_emi_due_date
    FROM analytics_reporting.lms_repay_schedule_cghfl r
    GROUP BY r.sz_loan_account_no

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(r.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        MIN(r.dt_installmentdue) AS first_emi_due_date
    FROM analytics_reporting.lms_repay_schedule_cgcl r
    GROUP BY r.sz_loan_account_no
),
lsm_latest AS (
    -- Row = latest LSM snapshot on or before the cutoff (previous month-end)
    -- CGHFL: pos = overdue_principal + future_principal; balance_tenure column name differs from CGCL
    SELECT
        'CGHFL' AS entity_type,
        CAST(lsm.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        lsm.dt_businessdate                                          AS lsm_date,
        (lsm.f_overdue_principal + lsm.f_future_principal)          AS pos_lsm,
        lsm.i_dpd                                                    AS dpd_lsm,
        lsm.loan_status                                              AS loan_status_lsm,
        lsm.balance_tenure                                           AS balance_tenure_lsm,
        COALESCE(NULLIF(TRIM(CAST(lsm.i_no_of_paid_emi AS VARCHAR(100))), ''), '0')::DECIMAL(18,2) AS paid_emi_lsm
    FROM analytics_reporting.loan_status_monthly_cghfl lsm
    WHERE lsm.dt_businessdate <= {CUTOFF_SQL}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY lsm.sz_loan_account_no ORDER BY lsm.dt_businessdate DESC) = 1

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(lsm.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        lsm.dt_businessdate                                          AS lsm_date,
        (lsm.f_overdue_principal + lsm.f_future_principal)          AS pos_lsm,
        lsm.i_dpd                                                    AS dpd_lsm,
        lsm.loan_status                                              AS loan_status_lsm,
        lsm.balance_tenure                                           AS balance_tenure_lsm,
        COALESCE(NULLIF(TRIM(CAST(lsm.i_no_of_paid_emi AS VARCHAR(100))), ''), '0')::DECIMAL(18,2) AS paid_emi_lsm
    FROM analytics_reporting.loan_status_monthly_cgcl lsm
    WHERE lsm.dt_businessdate <= {CUTOFF_SQL}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY lsm.sz_loan_account_no ORDER BY lsm.dt_businessdate DESC) = 1
),
dpd_rollup AS (
    -- 12-month window ending at cutoff (previous month-end)
    SELECT
        'CGHFL' AS entity_type,
        CAST(lsm.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        LISTAGG(CAST(COALESCE(lsm.i_dpd, 0) AS VARCHAR), '-')
            WITHIN GROUP (ORDER BY lsm.dt_businessdate) AS dpd_string,
        SUM(CASE WHEN lsm.i_dpd >= 30
                 AND lsm.dt_businessdate >= DATEADD(month, -6, {CUTOFF_SQL})
                 THEN 1 ELSE 0 END) AS no_of_times_30p_in_l6m,
        SUM(CASE WHEN lsm.i_dpd >= 30 THEN 1 ELSE 0 END) AS no_of_times_30p_in_l12m
    FROM analytics_reporting.loan_status_monthly_cghfl lsm
    WHERE lsm.dt_businessdate >= DATEADD(month, -12, {CUTOFF_SQL})
      AND lsm.dt_businessdate <= {CUTOFF_SQL}
    GROUP BY lsm.sz_loan_account_no

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(lsm.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        LISTAGG(CAST(COALESCE(lsm.i_dpd, 0) AS VARCHAR), '-')
            WITHIN GROUP (ORDER BY lsm.dt_businessdate) AS dpd_string,
        SUM(CASE WHEN lsm.i_dpd >= 30
                 AND lsm.dt_businessdate >= DATEADD(month, -6, {CUTOFF_SQL})
                 THEN 1 ELSE 0 END) AS no_of_times_30p_in_l6m,
        SUM(CASE WHEN lsm.i_dpd >= 30 THEN 1 ELSE 0 END) AS no_of_times_30p_in_l12m
    FROM analytics_reporting.loan_status_monthly_cgcl lsm
    WHERE lsm.dt_businessdate >= DATEADD(month, -12, {CUTOFF_SQL})
      AND lsm.dt_businessdate <= {CUTOFF_SQL}
    GROUP BY lsm.sz_loan_account_no
),
bounce_rollup AS (
    -- 12-month bounce window ending at cutoff (previous month-end)
    SELECT
        'CGHFL' AS entity_type,
        CAST(cbr.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        LISTAGG(CASE WHEN cbr.bounce_status_same_day = 'BOUNCE' THEN 'B' ELSE 'NB' END, '-')
            WITHIN GROUP (ORDER BY cbr.dt_installmentdue) AS bounce_string
    FROM external_curated.nb_cbr_cghfl_final_new cbr
    WHERE cbr.dt_installmentdue >= DATEADD(month, -12, {CUTOFF_SQL})
      AND cbr.dt_installmentdue <= {CUTOFF_SQL}
    GROUP BY cbr.sz_loan_account_no

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(cbr.sz_loan_account_no AS VARCHAR(100)) AS sz_loan_account_no,
        LISTAGG(CASE WHEN cbr.bounce_status_same_day = 'BOUNCE' THEN 'B' ELSE 'NB' END, '-')
            WITHIN GROUP (ORDER BY cbr.dt_installmentdue) AS bounce_string
    FROM external_curated.nb_cbr_cgcl_final_new cbr
    WHERE cbr.dt_installmentdue >= DATEADD(month, -12, {CUTOFF_SQL})
      AND cbr.dt_installmentdue <= {CUTOFF_SQL}
    GROUP BY cbr.sz_loan_account_no
),
bank_first AS (
    SELECT
        entity_type,
        sz_application_no,
        i_applicant_id,
        bank_name,
        branch_name
    FROM (
        SELECT
            'CGHFL' AS entity_type,
            CAST(apt.sz_application_no AS VARCHAR(100)) AS sz_application_no,
            CAST(apt.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
            bd.sz_bank_name AS bank_name,
            bd.sz_branch_name AS branch_name,
            ROW_NUMBER() OVER (
                PARTITION BY apt.sz_application_no, apt.i_applicant_id
                ORDER BY COALESCE(bd.c_use_for_repayment_yn, 'N') DESC,
                         COALESCE(NULLIF(TRIM(CAST(bd.i_srno AS VARCHAR(100))), ''), '999999')::INT
            ) AS rn
        FROM analytics_reporting.applicant_basic_dtl_cghfl apt
        LEFT JOIN analytics_reporting.banking_details_cghfl bd
          ON CAST(apt.i_applicant_id AS VARCHAR(100)) = CAST(bd.i_applicant_id AS VARCHAR(100))
        WHERE apt.sz_appl_type_code = 'BORROWER'

        UNION ALL

        SELECT
            'CGCL' AS entity_type,
            CAST(apt.sz_application_no AS VARCHAR(100)) AS sz_application_no,
            CAST(apt.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
            bd.sz_bank_name AS bank_name,
            bd.sz_branch_name AS branch_name,
            ROW_NUMBER() OVER (
                PARTITION BY apt.sz_application_no, apt.i_applicant_id
                ORDER BY COALESCE(bd.c_use_for_repayment_yn, 'N') DESC,
                         COALESCE(NULLIF(TRIM(CAST(bd.i_srno AS VARCHAR(100))), ''), '999999')::INT
            ) AS rn
        FROM analytics_reporting.applicant_basic_dtl_cgcl apt
        LEFT JOIN analytics_reporting.banking_details_cgcl bd
          ON CAST(apt.i_applicant_id AS VARCHAR(100)) = CAST(bd.i_applicant_id AS VARCHAR(100))
        WHERE apt.sz_appl_type_code = 'BORROWER'
    ) x
    WHERE rn = 1
)
SELECT
    t.pool_type                                           AS "POOL_TYPE",
    t.sz_loan_account_no                                    AS "ACCOUNT_NUMBER",
    COALESCE(b.sz_customer_no, t.sz_customer_no)            AS "CUSTOMER_ID",
    COALESCE(b.customer_name, t.customer_name)              AS "NAME OF CUSTOMER",
    'Capri Global Housing Finance Limited'                  AS "NAME OF INSTITUTION",
    COALESCE(b.pan, t.pan)                                  AS "PAN",
    COALESCE(b.dob, t.dt_birth_date)                        AS "DOB",
    COALESCE(b.doi, t.dt_birth_date)                        AS "DOI",
    COALESCE(c.mobile_number, t.phone_number)               AS "MOBILE_NUMBER",
    COALESCE(b.c_gender, t.c_gender)                        AS "GENDER",
    c.complete_address                                      AS "COMPLETE_ADDRESS",
    COALESCE(c.pin, t.pin_code)                             AS "PIN",
    COALESCE(c.city, t.city)                                AS "CITY",
    COALESCE(c.state, t.state)                              AS "STATE",
    COALESCE(c.email, t.email)                              AS "EMAIL",
    b.employment_type                                       AS "EMPLOYMENT_TYPE",
    COALESCE(al.number_of_active_loans, 1)                  AS "NUMBER_OF_ACTIVE_LOANS",
    t.first_disb_date                                       AS "DISBURSED_DATE",
    COALESCE(l.sanction_amount_raw, t.sanctioned_amount)    AS "SANCTION_AMOUNT",
    l.disbursed_amount                                      AS "DISBURSED_AMOUNT",
    t.current_interest_rate                                 AS "DISBURSED_ROI",
    t.tenure_at_sanction                                    AS "DISBURSED_TENURE",
    COALESCE(ll.pos_lsm, t.pos_current)                     AS "PRINCIPAL_OUTSTANDING_AMOUNT",
    COALESCE(r.first_emi_due_date, t.first_disb_date)       AS "FIRST_EMI_DUE_DATE",
    l.presentation_day                                      AS "PRESENTATION_DAY",
    t.final_maturity_date                                   AS "NATURAL_CLOSURE_DATE",
    t.emi_amount                                            AS "EMI_AMOUNT",
    COALESCE(ll.paid_emi_lsm,
        COALESCE(NULLIF(TRIM(CAST(t.emis_paid AS VARCHAR(100))), ''), NULL)::DECIMAL(18,2)
    )                                                       AS "PAID_EMI",
    t.current_total_tenure                                  AS "TOTAL_TENURE",
    COALESCE(ll.balance_tenure_lsm, t.balance_tenure)       AS "BALANCE_TENURE",
    COALESCE(l.loan_agreement_sign_date, t.sanction_date)   AS "LOAN_AGREEMENT_SIGN_DATE",
    t.foir                                                  AS "FOIR",
    CASE WHEN COALESCE(b.c_incm_consid, 'N') = 'Y'
         THEN COALESCE(NULLIF(TRIM(CAST(b.final_income AS VARCHAR(100))), ''), '0')::DECIMAL(18,2) * 12
         ELSE 0 END                                         AS "VALIDATED_INCOME",
    'CIBIL'                                                 AS "BUREAU_SCORE_PROVIDER",
    t.cibil_score                                           AS "BUREAU_SCORE_DISBURSAL",
    t.cibil_score                                           AS "BUREAU_SCORE_UPDATED",
    NULL                                                    AS "BUREAU_SCORE_UPDATED_DATE",
    COALESCE(ll.dpd_lsm, t.current_dpd)                     AS "CURRENT_DPD",
    COALESCE(ll.dpd_lsm, t.current_dpd)                     AS "DPD_AS_ON_CUT_OFF_DATE",
    COALESCE(br.bounce_string, 'NO_DATA')                   AS "BOUNCE_STRING",
    COALESCE(d.dpd_string, 'NO_DATA')                       AS "DPD_STRING",
    COALESCE(t.bounce_count_l6m, 0)                         AS "NO_OF_BOUNCES_IN_L6M",
    COALESCE(t.bounce_count_l12m, 0)                        AS "NO_OF_BOUNCES_IN_L12M",
    COALESCE(d.no_of_times_30p_in_l6m, 0)                   AS "NO_OF_TIMES_30P_IN_L6M",
    COALESCE(d.no_of_times_30p_in_l12m, 0)                  AS "NO_OF_TIMES_30P_IN_L12M",
    COALESCE(t.max_dpd_ever, 0)                             AS "MAX_DPD_EVER",
    t.age_current                                           AS "CUSTOMER_AGE_DISBURSAL",
    t.age_at_maturity                                       AS "CUSTOMER_AGE_MATURITY",
    COALESCE(ll.loan_status_lsm, t.loan_status)             AS "LOAN_STATUS_AS_ON_CUTOFF",
    CASE
        WHEN COALESCE(b.pan, t.pan) IS NOT NULL THEN 'PAN'
        ELSE 'OTHER'
    END                                                     AS "KYC_TYPE",
    bf.bank_name                                            AS "BANK_NAME",
    bf.branch_name                                          AS "BRANCH_NAME",
    t.sz_repayment_mode                                     AS "PAYMENT_MODE",
    NULL                                                    AS "INTERNAL_SCORE",
    NULL                                                    AS "ASSET_COST",
    t.calculated_ltv                                        AS "LTV",
    t.property_type                                         AS "ASSET_TYPE",
    t.property_type                                         AS "PROPERTY_TYPE",
    a.collateral_description                                AS "COLLATERAL_DESCRIPTION",
    a.collateral_use                                        AS "COLLATERAL_USE",
    a.property_ownership                                    AS "PROPERTY_OWNERSHIP",
    a.age_of_property                                       AS "AGE_OF_PROPERTY",
    t.sz_cersai_sec_int_id                                  AS "CERSAI ID",
    NULL                                                    AS "PMAY_SUBSIDY_NUMBER",
    t.cersai_registration_date                              AS "CERSAI DATE",
    {CUTOFF_SQL}                                            AS "AS_ON_DATE"
FROM target_loans t
LEFT JOIN borrower_dim b
  ON t.entity_type = b.entity_type
 AND t.sz_application_no = b.sz_application_no
LEFT JOIN contact_dim c
  ON b.entity_type = c.entity_type
 AND b.sz_application_no = c.sz_application_no
 AND b.i_applicant_id = c.i_applicant_id
LEFT JOIN loan_dim l
  ON t.entity_type = l.entity_type
 AND t.sz_loan_account_no = l.sz_loan_account_no
LEFT JOIN asset_best a
  ON t.entity_type = a.entity_type
 AND t.sz_application_no = a.sz_application_no
LEFT JOIN active_loans al
  ON t.entity_type = al.entity_type
 AND COALESCE(b.sz_customer_no, t.sz_customer_no) = al.sz_customer_no
LEFT JOIN repay_rollup r
  ON t.entity_type = r.entity_type
 AND t.sz_loan_account_no = r.sz_loan_account_no
LEFT JOIN lsm_latest ll
  ON t.entity_type = ll.entity_type
 AND t.sz_loan_account_no = ll.sz_loan_account_no
LEFT JOIN dpd_rollup d
  ON t.entity_type = d.entity_type
 AND t.sz_loan_account_no = d.sz_loan_account_no
LEFT JOIN bounce_rollup br
  ON t.entity_type = br.entity_type
 AND t.sz_loan_account_no = br.sz_loan_account_no
LEFT JOIN bank_first bf
  ON b.entity_type = bf.entity_type
 AND b.sz_application_no = bf.sz_application_no
 AND b.i_applicant_id = bf.i_applicant_id
ORDER BY t.pool_type, t.sz_loan_account_no
"""
    )
    return sql.replace("{CUTOFF_SQL}", CUTOFF_SQL)


def build_coapplicant_sql() -> str:
    common = build_common_target_loans_sql()
    return (
        common
        + """
, co_borrower_dim AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(apt.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(apt.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CAST(apt.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        COALESCE(apt.person_name, apt.sz_org_name) AS customer_name,
        NVL(NULLIF(TRIM(apt.sz_id2), ''), NULLIF(TRIM(apt.sz_panno), '')) AS pan,
        apt.dt_birth_date AS dob,
        apt.c_gender
    FROM analytics_reporting.applicant_basic_dtl_cghfl apt
    WHERE apt.sz_appl_type_code = 'COBORROWER'

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(apt.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(apt.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CAST(apt.sz_customer_no AS VARCHAR(100)) AS sz_customer_no,
        COALESCE(apt.person_name, apt.sz_org_name) AS customer_name,
        NVL(NULLIF(TRIM(apt.sz_id2), ''), NULLIF(TRIM(apt.sz_panno), '')) AS pan,
        apt.dt_birth_date AS dob,
        apt.c_gender
    FROM analytics_reporting.applicant_basic_dtl_cgcl apt
    WHERE apt.sz_appl_type_code = 'COBORROWER'
),
co_contact_dim AS (
    SELECT
        'CGHFL' AS entity_type,
        CAST(addr.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(addr.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CASE
            WHEN LENGTH(addr.SZ_MOBILE1) = 10 THEN addr.SZ_MOBILE1::VARCHAR
            WHEN LENGTH(addr.SZ_MOBILE2) = 10 THEN addr.SZ_MOBILE2::VARCHAR
            WHEN LENGTH(addr.sz_mobile_no) = 10 THEN addr.sz_mobile_no::VARCHAR
            WHEN LENGTH(CAST(addr.current_i_mobileno AS VARCHAR)) >= 10 THEN CAST(addr.current_i_mobileno AS VARCHAR)
            ELSE NULL
        END AS mobile_number,
        TRIM(COALESCE(addr.current_sz_address_1, '') || ' ' ||
             COALESCE(addr.current_sz_address_2, '') || ' ' ||
             COALESCE(addr.current_sz_address_3, '')) AS complete_address,
        addr.current_sz_postal_code AS pin,
        addr.current_city AS city,
        addr.current_state AS state
    FROM analytics_reporting.applicant_address_contact_dtl_cghfl addr

    UNION ALL

    SELECT
        'CGCL' AS entity_type,
        CAST(addr.sz_application_no AS VARCHAR(100)) AS sz_application_no,
        CAST(addr.i_applicant_id AS VARCHAR(100)) AS i_applicant_id,
        CASE
            WHEN LENGTH(addr.SZ_MOBILE1) = 10 THEN addr.SZ_MOBILE1::VARCHAR
            WHEN LENGTH(addr.SZ_MOBILE2) = 10 THEN addr.SZ_MOBILE2::VARCHAR
            WHEN LENGTH(addr.sz_mobile_no) = 10 THEN addr.sz_mobile_no::VARCHAR
            WHEN LENGTH(CAST(addr.current_i_mobileno AS VARCHAR)) >= 10 THEN CAST(addr.current_i_mobileno AS VARCHAR)
            ELSE NULL
        END AS mobile_number,
        TRIM(COALESCE(addr.current_sz_address_1, '') || ' ' ||
             COALESCE(addr.current_sz_address_2, '') || ' ' ||
             COALESCE(addr.current_sz_address_3, '')) AS complete_address,
        addr.current_sz_postal_code AS pin,
        addr.current_city AS city,
        addr.current_state AS state
    FROM analytics_reporting.applicant_address_contact_dtl_cgcl addr
)
SELECT
    t.pool_type                                           AS "POOL_TYPE",
    t.sz_loan_account_no                                    AS "ACCOUNT_NUMBER",
    cb.sz_customer_no                                       AS "CUSTOMER_ID",
    cb.customer_name                                        AS "NAME OF CUSTOMER",
    'Capri Global Housing Finance Limited'                  AS "NAME OF INSTITUTION",
    cb.pan                                                  AS "PAN",
    cb.dob                                                  AS "DOB",
    cc.mobile_number                                        AS "MOBILE_NUMBER",
    cb.c_gender                                             AS "GENDER",
    cc.complete_address                                     AS "COMPLETE_ADDRESS",
    cc.pin                                                  AS "PIN",
    cc.city                                                 AS "CITY",
    cc.state                                                AS "STATE"
FROM target_loans t
INNER JOIN co_borrower_dim cb
  ON t.entity_type = cb.entity_type
 AND t.sz_application_no = cb.sz_application_no
LEFT JOIN co_contact_dim cc
  ON cb.entity_type = cc.entity_type
 AND cb.sz_application_no = cc.sz_application_no
 AND cb.i_applicant_id = cc.i_applicant_id
ORDER BY t.pool_type, t.sz_loan_account_no, cb.i_applicant_id
"""
    )


def execute_query(conn, sql: str, logger: logging.Logger, label: str) -> pd.DataFrame:
    logger.info("Executing %s query...", label)
    df = pd.read_sql_query(sql, conn)
    logger.info("%s rows: %s | cols: %s", label, f"{len(df):,}", len(df.columns))
    return df


def run_eval_checks(app_df: pd.DataFrame, co_df: pd.DataFrame, logger: logging.Logger) -> None:
    def _col(df: pd.DataFrame, target: str) -> str | None:
        m = {c.lower(): c for c in df.columns}
        return m.get(target.lower())

    logger.info("=" * 70)
    logger.info("EVAL CHECKS")
    logger.info("=" * 70)
    logger.info("Applicant rows: %s", f"{len(app_df):,}")
    logger.info("Co applicant rows: %s", f"{len(co_df):,}")

    if not app_df.empty:
        app_lan_col = _col(app_df, "ACCOUNT_NUMBER")
        app_unique_lans = app_df[app_lan_col].nunique() if app_lan_col else 0
        logger.info("Applicant unique LANs: %s", f"{app_unique_lans:,}")
        for col in ["ACCOUNT_NUMBER", "CUSTOMER_ID", "NAME OF CUSTOMER", "PAN", "MOBILE_NUMBER"]:
            actual = _col(app_df, col)
            if actual:
                nulls = app_df[actual].isna().sum() + (app_df[actual].astype(str).str.strip() == "").sum()
                logger.info("Applicant blanks - %s: %s", col, f"{int(nulls):,}")
        dup_lans = app_df[app_lan_col].duplicated().sum() if app_lan_col else 0
        logger.info("Applicant duplicate ACCOUNT_NUMBER rows: %s", f"{int(dup_lans):,}")

    if not co_df.empty:
        co_lan_col = _col(co_df, "ACCOUNT_NUMBER")
        co_unique_lans = co_df[co_lan_col].nunique() if co_lan_col else 0
        logger.info("Co-app unique LANs: %s", f"{co_unique_lans:,}")
        for col in ["ACCOUNT_NUMBER", "CUSTOMER_ID", "NAME OF CUSTOMER", "PAN", "MOBILE_NUMBER"]:
            actual = _col(co_df, col)
            if actual:
                nulls = co_df[actual].isna().sum() + (co_df[actual].astype(str).str.strip() == "").sum()
                logger.info("Co-app blanks - %s: %s", col, f"{int(nulls):,}")

    logger.info("Eval checks completed.")
    logger.info("=" * 70)


def export_excel(app_df: pd.DataFrame, co_df: pd.DataFrame, logger: logging.Logger, pool_label: str) -> Path:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_file = OUTPUT_DIR / f"bajaj_da_applicant_coapplicant_{pool_label}_{ELIGIBILITY_MODE}_{TIMESTAMP}.xlsx"
    with pd.ExcelWriter(out_file, engine="openpyxl") as writer:
        app_df.to_excel(writer, index=False, sheet_name="Applicant")
        co_df.to_excel(writer, index=False, sheet_name="Co applicant")
    logger.info("Output written: %s", out_file)
    return out_file


def main() -> None:
    logger = setup_logging()
    logger.info("Starting Bajaj DA applicant/co-applicant extraction")
    logger.info("Eligibility mode: %s", ELIGIBILITY_MODE)

    db_cfg = load_db_config()
    conn = get_connection(db_cfg)
    try:
        applicant_sql = build_applicant_sql()
        coapp_sql = build_coapplicant_sql()
        applicant_df = execute_query(conn, applicant_sql, logger, "Applicant")
        coapp_df = execute_query(conn, coapp_sql, logger, "Co applicant")
    finally:
        conn.close()

    applicant_df = applicant_df.fillna("")
    coapp_df = coapp_df.fillna("")

    app_pool_col = next((c for c in applicant_df.columns if c.lower() == "pool_type"), None)
    co_pool_col = next((c for c in coapp_df.columns if c.lower() == "pool_type"), None)

    pool_map = [("HFLA", "he"), ("MSME", "msme")]
    output_files: list[Path] = []
    for pool_value, pool_label in pool_map:
        app_part = applicant_df[applicant_df[app_pool_col] == pool_value].copy() if app_pool_col else pd.DataFrame()
        co_part = coapp_df[coapp_df[co_pool_col] == pool_value].copy() if co_pool_col else pd.DataFrame()
        logger.info("Processing pool=%s", pool_value)
        run_eval_checks(app_part, co_part, logger)
        out_file = export_excel(app_part, co_part, logger, pool_label)
        output_files.append(out_file)

    for out_file in output_files:
        try:
            os.startfile(str(out_file))
        except Exception:
            logger.info("Auto-open unavailable. File at: %s", out_file)

    logger.info("Completed.")


if __name__ == "__main__":
    main()
