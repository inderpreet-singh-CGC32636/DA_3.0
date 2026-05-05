-- Stage 1 SQL: Raw base data — loan + application + applicant + address
-- Only JOINs here. No aggregation, no date logic, no derivation.
-- Python handles: age, MOB, LTV, residential_pct, DPD/bounce aggregation, CIBIL clean-up

SELECT
    ld.sz_loan_account_no,
    ld.sz_application_no,
    ld.sz_customer_no,
    ld.loan_status,
    ld.c_final_disb_yn,
    ld."principal outstanding"            AS pos_current,
    ld."loan amount with insurance"       AS loan_amount_w_insurance,
    ld.f_sanctioned_amt                   AS sanctioned_amount,
    ld.I_TENOR                            AS tenure_at_sanction,
    ld."balance tenure"                   AS balance_tenure,
    ld."first disbursement date"          AS first_disb_date,
    ld."latest disbursement date"         AS latest_disb_date,
    ld."maturity date"                    AS maturity_date_ld,
    ld.i_cur_dpd                          AS current_dpd,
    ld."overdue principal"                AS overdue_principal_current,
    ld."interest overdue"                 AS overdue_interest_current,
    ld.F_CURR_INTERESTRATE                AS current_interest_rate,
    ld.installment_amount                 AS emi_amount,
    ld.sanction_date,
    ld.sz_product_desc,
    ld.sz_repayment_mode,
    ld.i_cycleday                         AS cycle_day,
    ld.C_COV_MORAT                        AS morat_flag,
    ld.npa_flag,
    ld.sz_funder_status,
    ld.sz_funder_name,
    ld.nhb,
    ld.sz_nabard_name,
    ld.refinance_scheme,
    ld."direct assignment"                AS direct_assignment,
    ld.C_COV_RESTRUCTURE                  AS restructure_flag,
    -- application
    app.foir_wo_insurance                 AS foir,
    app.ltv_wo_insurance                  AS ltv_origination,
    app.case_status,
    app.branch,
    app.region,
    app.sz_appln_type                     AS application_type,
    -- applicant (primary borrower)
    apt.sz_cibil_score,
    apt.dt_birth_date,
    NVL(apt.person_name, apt.sz_org_name) AS customer_name,
    NVL(apt.sz_id2, apt.sz_panno)         AS pan,
    apt.c_gender,
    apt.sz_primary_occupation,
    apt.income_program,
    apt.income_type,
    apt.final_income,
    apt.sz_appl_category_code,
    apt.udyam_aadhar_number,
    -- contact / address
    CASE
        WHEN LENGTH(addr.factory_i_mobileno) = 10 THEN addr.factory_i_mobileno::VARCHAR
        WHEN LENGTH(addr.SZ_MOBILE1) = 10         THEN addr.SZ_MOBILE1::VARCHAR
        WHEN LENGTH(addr.SZ_MOBILE2) = 10         THEN addr.SZ_MOBILE2::VARCHAR
        WHEN LENGTH(addr.sz_mobile_no) = 10       THEN addr.sz_mobile_no::VARCHAR
        WHEN LENGTH(addr.current_i_mobileno) >= 10 THEN addr.current_i_mobileno::VARCHAR
    END AS phone_number,
    NVL(NVL(addr.sz_email_id1, addr.sz_email_id2),
        NVL(addr.sz_email, addr.sz_email1))       AS email,
    addr.current_sz_postal_code                   AS pin_code,
    addr.current_city                             AS city,
    addr.current_state                            AS state

FROM analytics_reporting.loan_dtl_cghfl ld
LEFT JOIN analytics_reporting.application_cghfl app
       ON ld.sz_application_no = app.sz_application_no
LEFT JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
       ON ld.sz_application_no = apt.sz_application_no
      AND apt.sz_appl_type_code = 'BORROWER'
LEFT JOIN analytics_reporting.applicant_address_contact_dtl_cghfl addr
       ON apt.sz_application_no = addr.sz_application_no
      AND apt.i_applicant_id    = addr.i_applicant_id

WHERE ld.loan_status = 'APPROVED'
  AND UPPER(NVL(ld.c_final_disb_yn, '')) = 'Y'
  AND (
      UPPER(ld.sz_product_desc) LIKE '%LAP%'
      OR UPPER(ld.sz_product_desc) LIKE '%HOME EQUITY%'
      OR UPPER(ld.sz_portfolio_desc) LIKE '%HE%'
      OR UPPER(ld.sz_portfolio_desc) LIKE '%HOME EQUITY%'
      OR UPPER(ld.sz_portfolio_desc) LIKE '%HOUSING LOAN EQUITY%'
  )
