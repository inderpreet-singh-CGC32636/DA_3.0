-- ============================================================================
-- BAJAJ FINANCE — HE (LAP) POOL SELECTION — INTEGRATED v2
-- Combines BFL LAP pool selection criteria with Aditya Birla-style
-- eligibility flag architecture for unified dashboard consumption.
-- Cutoff Date: Dynamic — last calendar month-end (auto-computed)
-- Entity: CGHFL
-- Schema: analytics_reporting
-- ============================================================================

WITH cutoff_date AS (
    -- Auto: last day of the previous month
    SELECT (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 day')::DATE AS cutoff
),

-- ============================================================================
-- BASE LOAN DATA — LAP / HE PRODUCTS ONLY
-- ============================================================================
base_loans AS (
    SELECT
        ld.sz_loan_account_no,
        ld.sz_application_no,
        ld.sz_customer_no,
        ld.loan_status,
        ld.c_final_disb_yn,
        ld."first disbursement date"           AS first_disb_date,
        ld."latest disbursement date"          AS latest_disb_date,
        ld.installment_start_date,
        ld."total principal outstanding"       AS total_pos,
        ld."principal outstanding"             AS pos_current,
        ld."overdue principal"                 AS overdue_principal_current,
        ld."interest overdue"                  AS overdue_interest_current,
        ld.interest_accrud                     AS interest_accrued_current,
        ld.f_sanctioned_amt                    AS sanctioned_amount,
        ld."loan amount with insurance"        AS loan_amount_w_insurance,
        ld."loan amount without insurance"     AS loan_amount_wo_insurance,
        ld."cumulative amount disbursed"       AS cumulative_disbursed,
        ld.I_TENOR                             AS tenure_at_sanction,
        ld."current total tenure"              AS current_total_tenure,
        ld."balance tenure"                    AS balance_tenure,
        ld."maturity date"                     AS maturity_date_ld,
        ld.i_cur_dpd                           AS current_dpd,
        ld.sz_product_desc,
        ld.sz_product_code,
        ld.sz_portfolio_desc,
        ld.sz_loan_purpose,
        ld.C_COV_RESTRUCTURE                   AS restructure_flag,
        ld.c_cov_res_status,
        ld.C_COV_MORAT                         AS morat_flag,
        ld.npa_flag,
        ld.sz_repayment_mode,
        ld.F_CURR_INTERESTRATE                 AS current_interest_rate,
        ld.f_interest_rate                     AS interest_rate_at_sanction,
        ld.c_interest_rate_type,
        ld.sanction_date,
        ld.installment_amount                  AS emi_amount,
        ld.i_cycleday                          AS cycle_day,
        ld.insurance_amount                    AS total_insurance_amt,
        ld.sz_funder_status,
        ld.sz_funder_name,
        ld.sz_funder_agree_no,
        ld.dt_funderdisb,
        ld.dt_funder_tagging,
        ld.nhb,
        ld.sz_nabard_name,
        ld.refinance_scheme,
        ld.scheme,
        ld."direct assignment"                 AS direct_assignment,
        ld.c_psl,
        ld.source_system                       AS lms,
        CEIL(MONTHS_BETWEEN(
            (SELECT cutoff FROM cutoff_date),
            ld."first disbursement date"
        ))                                     AS mob_first_disb
    FROM analytics_reporting.loan_dtl_cghfl ld
    WHERE ld.loan_status = 'APPROVED'
      AND UPPER(NVL(ld.c_final_disb_yn, '')) = 'Y'
      AND (
          UPPER(ld.sz_product_desc) LIKE '%LAP%'
          OR UPPER(ld.sz_product_desc) LIKE '%HOME EQUITY%'
          OR UPPER(ld.sz_portfolio_desc) LIKE '%HE%'
          OR UPPER(ld.sz_portfolio_desc) LIKE '%HOME EQUITY%'
          OR UPPER(ld.sz_portfolio_desc) LIKE '%HOUSING LOAN EQUITY%'
      )
),

-- ============================================================================
-- APPLICATION DATA
-- ============================================================================
application_data AS (
    SELECT
        app.sz_application_no,
        app.sz_appln_type                      AS top_up_flag,
        app.sz_parent_application,
        app.sz_exist_apln_no                   AS existing_application,
        app.portfolio_description,
        app.portfolio_code,
        app.bt,
        app.case_status,
        app.foir_wo_insurance                  AS foir,
        app.ltv_wo_insurance                   AS ltv,
        app.ltv_w_insurance,
        app.sz_servicing_branch_code,
        app.branch,
        app.spoke,
        app.region
    FROM analytics_reporting.application_cghfl app
),

-- ============================================================================
-- APPLICANT DATA (PRIMARY BORROWER)
-- ============================================================================
applicant_data AS (
    SELECT
        apt.sz_application_no,
        apt.i_applicant_id,
        apt.dt_birth_date,
        FLOOR(DATEDIFF(day, apt.dt_birth_date,
              (SELECT cutoff FROM cutoff_date)) / 365.25)  AS age_current,
        NVL(apt.sz_id2, apt.sz_panno)                      AS pan,
        apt.sz_uid_no                                       AS aadhar,
        apt.sz_voter_id                                     AS voter_id,
        apt.sz_ckyc_id,
        apt.udyam_aadhar_number,
        apt.sz_appl_type_code,
        apt.sz_appl_category_code,
        NVL(apt.person_name, apt.sz_org_name)               AS customer_name,
        apt.c_gender,
        apt.income_program,
        apt.income_type,
        apt.sz_primary_occupation,
        apt.sz_emp_bus_nm                                    AS business_name,
        apt.sz_ucic,
        apt.sz_customer_no,
        apt.final_income,
        apt.sz_resi_status,
        apt.sz_org_constitution,

        -- CIBIL Score validation (clean non-numeric values)
        CASE
            WHEN LOWER(apt.sz_cibil_score) LIKE '%[a-z]%'
                OR UPPER(apt.sz_cibil_score) LIKE '%[A-Z]%'
                OR apt.sz_cibil_score LIKE '%=%'
                OR apt.sz_cibil_score LIKE '%-%'
                OR apt.sz_cibil_score LIKE '%.%'
                OR LOWER(apt.sz_cibil_score) LIKE '%n%'
                OR LOWER(apt.sz_cibil_score) LIKE '%o%'
                OR UPPER(apt.sz_cibil_score) LIKE '%U%'
                OR UPPER(apt.sz_cibil_score) LIKE '%S%'
                OR UPPER(apt.sz_cibil_score) LIKE '%C%'
                OR apt.sz_cibil_score IN ('SUC')
                OR apt.sz_cibil_score IS NULL
            THEN -1
            WHEN CAST(apt.sz_cibil_score AS INT) < 300 THEN -1
            ELSE CAST(apt.sz_cibil_score AS INT)
        END AS cibil_score_validated,

        -- Profile type classification
        CASE
            WHEN LOWER(apt.income_program) LIKE '%salar%' THEN 'SALARIED'
            WHEN LOWER(apt.income_program) LIKE '%senp%'
                OR LOWER(apt.income_program) LIKE '%sep%'
                OR apt.income_program IN ('Self Employed - NIP-CPM', 'Self Employed - NIP')
            THEN 'SENP'
            ELSE UPPER(apt.income_program)
        END AS profile_type
    FROM analytics_reporting.applicant_basic_dtl_cghfl apt
    WHERE apt.sz_appl_type_code = 'BORROWER'
),

-- ============================================================================
-- APPLICANT ADDRESS/CONTACT
-- ============================================================================
applicant_address AS (
    SELECT
        apt_add.sz_application_no,
        apt_add.i_applicant_id,
        -- High-rank phone extraction
        CASE
            WHEN LENGTH(apt_add.factory_i_mobileno) = 10 THEN apt_add.factory_i_mobileno::VARCHAR
            WHEN LENGTH(apt_add.SZ_MOBILE1) = 10 THEN apt_add.SZ_MOBILE1::VARCHAR
            WHEN LENGTH(apt_add.SZ_MOBILE2) = 10 THEN apt_add.SZ_MOBILE2::VARCHAR
            WHEN LENGTH(apt_add.sz_mobile_no) = 10 THEN apt_add.sz_mobile_no::VARCHAR
            WHEN LENGTH(apt_add.current_i_mobileno) >= 10 THEN apt_add.current_i_mobileno::VARCHAR
        END AS phone_number,
        NVL(NVL(apt_add.sz_email_id1, apt_add.sz_email_id2),
            NVL(apt_add.sz_email, apt_add.sz_email1))     AS email,
        apt_add.current_sz_postal_code                     AS pin_code,
        apt_add.current_city                               AS city,
        apt_add.current_state                              AS state
    FROM analytics_reporting.applicant_address_contact_dtl_cghfl apt_add
),

-- ============================================================================
-- PROPERTY/ASSET DATA (HIGHEST-VALUED ASSET PER APPLICATION)
-- ============================================================================
property_data AS (
    SELECT * FROM (
        SELECT
            asset.sz_application_no,
            asset.property_type,
            asset.property_subtype,
            asset.property_occupation,
            asset.sz_cersai_sec_int_id,
            asset.dt_cersai,
            asset.city                                     AS property_city,
            asset.state                                    AS property_state,
            SUM(asset.a_i_tot_valuation) OVER (PARTITION BY asset.sz_application_no)
                                                           AS total_property_value,
            COUNT(asset.i_asset_srno) OVER (PARTITION BY asset.sz_application_no)
                                                           AS property_count,
            SUM(CASE WHEN LOWER(asset.property_type) LIKE '%residential%'
                     THEN asset.a_i_tot_valuation ELSE 0 END)
                OVER (PARTITION BY asset.sz_application_no)
                                                           AS residential_property_value,
            COUNT(CASE WHEN LOWER(asset.property_type) LIKE '%residential%'
                       THEN asset.property_type ELSE NULL END)
                OVER (PARTITION BY asset.sz_application_no)
                                                           AS residential_property_cnt,
            COUNT(CASE WHEN LOWER(asset.property_type) LIKE '%commercial%'
                       THEN asset.property_type ELSE NULL END)
                OVER (PARTITION BY asset.sz_application_no)
                                                           AS commercial_property_cnt,
            COUNT(CASE WHEN LOWER(asset.property_type) LIKE '%plot%'
                            OR LOWER(asset.property_type) LIKE '%land%'
                       THEN asset.i_asset_srno ELSE NULL END)
                OVER (PARTITION BY asset.sz_application_no)
                                                           AS plot_count,
            COUNT(CASE WHEN LOWER(asset.property_type) LIKE '%industrial%'
                            OR LOWER(asset.property_type) LIKE '%shed%'
                       THEN asset.i_asset_srno ELSE NULL END)
                OVER (PARTITION BY asset.sz_application_no)
                                                           AS industrial_shed_count,
            ROW_NUMBER() OVER (
                PARTITION BY asset.sz_application_no
                ORDER BY asset.a_i_tot_valuation DESC, asset.dt_valdate DESC
            ) AS rk
        FROM analytics_reporting.asset_cghfl asset
        WHERE asset.sz_application_no IS NOT NULL
    ) ranked_asset
    WHERE rk = 1
),

-- ============================================================================
-- LOAN STATUS MONTHLY — LAST MONTH END
-- ============================================================================
loan_status_last_month AS (
    SELECT
        lsm.sz_loan_account_no,
        lsm.i_dpd                              AS dpd_last_month,
        lsm.f_overdue_principal                 AS overdue_principal_lm,
        lsm.f_overdue_interest                  AS overdue_interest_lm,
        lsm.f_outstanding_amt                   AS outstanding_amt_lm,
        (lsm.f_overdue_principal + lsm.f_future_principal) AS pos_lm,
        lsm.balance_tenure                      AS balance_tenure_lm
    FROM analytics_reporting.loan_status_monthly_cghfl lsm
    WHERE lsm.dt_businessdate = (SELECT cutoff FROM cutoff_date)
),

-- ============================================================================
-- DPD HISTORY — EVER, LAST 6M, LAST 12M, LAST 18M
-- ============================================================================
dpd_ever AS (
    SELECT
        sz_loan_account_no,
        MAX(i_dpd) AS max_dpd_ever
    FROM analytics_reporting.loan_status_monthly_cghfl
    GROUP BY sz_loan_account_no
),
dpd_6m AS (
    SELECT
        sz_loan_account_no,
        MAX(i_dpd) AS max_dpd_6m,
        MAX(CASE WHEN i_dpd >= 30 THEN 1 ELSE 0 END) AS ever_30_dpd_6m
    FROM analytics_reporting.loan_status_monthly_cghfl
    WHERE dt_businessdate >= DATEADD(month, -6, (SELECT cutoff FROM cutoff_date))
      AND dt_businessdate <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),
dpd_12m AS (
    SELECT
        sz_loan_account_no,
        MAX(i_dpd) AS max_dpd_12m
    FROM analytics_reporting.loan_status_monthly_cghfl
    WHERE dt_businessdate >= DATEADD(month, -12, (SELECT cutoff FROM cutoff_date))
      AND dt_businessdate <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),
dpd_18m AS (
    SELECT
        sz_loan_account_no,
        MAX(i_dpd) AS max_dpd_18m
    FROM analytics_reporting.loan_status_monthly_cghfl
    WHERE dt_businessdate >= DATEADD(month, -18, (SELECT cutoff FROM cutoff_date))
      AND dt_businessdate <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),

-- NPA History
npa_history AS (
    SELECT
        sz_loan_account_no,
        MAX(CASE WHEN npa_flag = 'Y' THEN 1 ELSE 0 END) AS ever_npa
    FROM analytics_reporting.loan_status_monthly_cghfl
    GROUP BY sz_loan_account_no
),

-- Restructure History
restructure_history AS (
    SELECT DISTINCT
        loan_number AS sz_loan_account_no
    FROM analytics_reporting.restructuresaha_data_monthly
    WHERE universe_mapping_rest_saha = 'Restructuring'
),

-- Bucket History (SMA/DBT/SUB/LSS/90+)
bucket_history AS (
    SELECT
        sz_loan_account_no,
        MAX(CASE WHEN npa_flag IN ('SMA','DBT','SUB','LSS') OR i_dpd >= 90 THEN 1 ELSE 0 END) AS ever_bucket
    FROM analytics_reporting.loan_status_monthly_cghfl
    WHERE dt_businessdate <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),

-- ============================================================================
-- CBR BOUNCE DATA — L3M, L6M, L12M
-- ============================================================================
bounce_l3m AS (
    SELECT sz_loan_account_no,
        COUNT(DISTINCT CASE
            WHEN bounce_status_same_day = 'BOUNCE'
                AND tech_bounce_ind = 0
                AND not_presented_ind = 'PRESENTED'
                AND manual_hold_ind = 'NO_HOLD'
            THEN dt_installmentdue ELSE NULL END
        ) AS bounce_count_l3m
    FROM external_curated.nb_cbr_cghfl_final_new
    WHERE dt_installmentdue >= DATEADD(month, -3, (SELECT cutoff FROM cutoff_date))
      AND dt_installmentdue <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),
bounce_l6m AS (
    SELECT sz_loan_account_no,
        COUNT(DISTINCT CASE
            WHEN bounce_status_same_day = 'BOUNCE'
                AND tech_bounce_ind = 0
                AND not_presented_ind = 'PRESENTED'
                AND manual_hold_ind = 'NO_HOLD'
            THEN dt_installmentdue ELSE NULL END
        ) AS bounce_count_l6m
    FROM external_curated.nb_cbr_cghfl_final_new
    WHERE dt_installmentdue >= DATEADD(month, -6, (SELECT cutoff FROM cutoff_date))
      AND dt_installmentdue <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),
bounce_l12m AS (
    SELECT sz_loan_account_no,
        COUNT(DISTINCT CASE
            WHEN bounce_status_same_day = 'BOUNCE'
                AND tech_bounce_ind = 0
                AND not_presented_ind = 'PRESENTED'
                AND manual_hold_ind = 'NO_HOLD'
            THEN dt_installmentdue ELSE NULL END
        ) AS bounce_count_l12m
    FROM external_curated.nb_cbr_cghfl_final_new
    WHERE dt_installmentdue >= DATEADD(month, -12, (SELECT cutoff FROM cutoff_date))
      AND dt_installmentdue <= (SELECT cutoff FROM cutoff_date)
    GROUP BY sz_loan_account_no
),

-- ============================================================================
-- REPAYMENT SCHEDULE — MATURITY DATE
-- ============================================================================
repay_schedule AS (
    SELECT
        sz_loan_account_no,
        MAX(dt_installmentdue)   AS maturity_date,
        MAX(i_installment_no)    AS tenure_from_schedule,
        MAX(CASE WHEN dt_installmentdue <= (SELECT cutoff FROM cutoff_date)
                 THEN i_installment_no END) AS emis_paid
    FROM analytics_reporting.lms_repay_schedule_cghfl
    GROUP BY sz_loan_account_no
),

-- ============================================================================
-- UDYAM DETAILS (for Udyam eligibility tagging)
-- ============================================================================
udyam_data AS (
    SELECT
        TRIM(UPPER(udyamregistrationno)) AS udyam_reg_no,
        MAX(enterprisetype_1) AS enterprise_type
    FROM analytics_reporting.udyam_details
    WHERE udyamregistrationno IS NOT NULL
    GROUP BY TRIM(UPPER(udyamregistrationno))
),

-- ============================================================================
-- MAIN DATA AGGREGATION
-- ============================================================================
main_data AS (
    SELECT
        bl.*,
        app.top_up_flag,
        app.bt,
        app.foir,
        app.ltv,
        app.ltv_w_insurance,
        app.portfolio_description,
        app.branch,
        app.region,
        apt.dt_birth_date,
        apt.age_current,
        apt.pan,
        apt.aadhar,
        apt.voter_id,
        apt.sz_ckyc_id,
        apt.udyam_aadhar_number,
        apt.customer_name,
        apt.c_gender,
        apt.income_program,
        apt.profile_type,
        apt.sz_primary_occupation,
        apt.business_name,
        apt.sz_appl_category_code,
        apt.cibil_score_validated              AS cibil_score,
        addr.phone_number,
        addr.email,
        addr.pin_code,
        addr.city,
        addr.state,
        prop.property_type,
        prop.property_subtype,
        prop.property_occupation,
        prop.total_property_value,
        prop.residential_property_value,
        prop.residential_property_cnt,
        prop.commercial_property_cnt,
        prop.plot_count,
        prop.industrial_shed_count,
        prop.sz_cersai_sec_int_id,
        prop.property_city,
        prop.property_state,
        CASE WHEN prop.total_property_value > 0
             THEN (prop.residential_property_value * 100.0 / prop.total_property_value)
             ELSE 0 END                        AS residential_pct,
        CASE WHEN prop.total_property_value > 0
             THEN (bl.pos_current * 100.0 / prop.total_property_value)
             ELSE NULL END                     AS calculated_ltv,
        lsm.dpd_last_month,
        lsm.overdue_principal_lm,
        lsm.overdue_interest_lm,
        lsm.pos_lm,
        lsm.balance_tenure_lm,
        dpd_e.max_dpd_ever,
        d6.max_dpd_6m,
        NVL(d6.ever_30_dpd_6m, 0)             AS ever_30_dpd_6m,
        d12.max_dpd_12m,
        d18.max_dpd_18m,
        NVL(npa.ever_npa, 0)                   AS ever_npa,
        CASE WHEN rest.sz_loan_account_no IS NOT NULL THEN 1 ELSE 0 END AS is_restructured,
        NVL(bkt.ever_bucket, 0)                AS ever_bucket,
        COALESCE(b3.bounce_count_l3m, 0)       AS bounce_count_l3m,
        COALESCE(b6.bounce_count_l6m, 0)       AS bounce_count_l6m,
        COALESCE(b12.bounce_count_l12m, 0)     AS bounce_count_l12m,
        NVL(bl.maturity_date_ld, repay.maturity_date) AS final_maturity_date,
        FLOOR(DATEDIFF(day, apt.dt_birth_date,
              NVL(bl.maturity_date_ld, repay.maturity_date)) / 365.25)
                                               AS age_at_maturity,
        repay.emis_paid,
        ud.enterprise_type                     AS udyam_enterprise_type,
        CASE WHEN apt.udyam_aadhar_number IS NOT NULL
                  AND TRIM(apt.udyam_aadhar_number) != ''
             THEN 1 ELSE 0 END                AS has_udyam
    FROM base_loans bl
    LEFT JOIN application_data app  ON bl.sz_application_no = app.sz_application_no
    LEFT JOIN applicant_data apt    ON bl.sz_application_no = apt.sz_application_no
    LEFT JOIN applicant_address addr
        ON apt.sz_application_no = addr.sz_application_no
        AND apt.i_applicant_id   = addr.i_applicant_id
    LEFT JOIN property_data prop    ON bl.sz_application_no = prop.sz_application_no
    LEFT JOIN loan_status_last_month lsm ON bl.sz_loan_account_no = lsm.sz_loan_account_no
    LEFT JOIN dpd_ever dpd_e        ON bl.sz_loan_account_no = dpd_e.sz_loan_account_no
    LEFT JOIN dpd_6m d6             ON bl.sz_loan_account_no = d6.sz_loan_account_no
    LEFT JOIN dpd_12m d12           ON bl.sz_loan_account_no = d12.sz_loan_account_no
    LEFT JOIN dpd_18m d18           ON bl.sz_loan_account_no = d18.sz_loan_account_no
    LEFT JOIN npa_history npa       ON bl.sz_loan_account_no = npa.sz_loan_account_no
    LEFT JOIN restructure_history rest ON bl.sz_loan_account_no = rest.sz_loan_account_no
    LEFT JOIN bucket_history bkt    ON bl.sz_loan_account_no = bkt.sz_loan_account_no
    LEFT JOIN bounce_l3m b3         ON bl.sz_loan_account_no = b3.sz_loan_account_no
    LEFT JOIN bounce_l6m b6         ON bl.sz_loan_account_no = b6.sz_loan_account_no
    LEFT JOIN bounce_l12m b12       ON bl.sz_loan_account_no = b12.sz_loan_account_no
    LEFT JOIN repay_schedule repay  ON bl.sz_loan_account_no = repay.sz_loan_account_no
    LEFT JOIN udyam_data ud         ON TRIM(REPLACE(UPPER(apt.udyam_aadhar_number), 'UDYAM-', '')) = ud.udyam_reg_no
)

-- ============================================================================
-- FINAL SELECT WITH ELIGIBILITY FLAGS
-- ============================================================================
SELECT
    -- ── IDENTIFICATION ──
    'Bajaj_HE'                                             AS bank,
    md.sz_loan_account_no,
    md.sz_application_no,
    md.sz_customer_no,
    md.customer_name,
    md.pan,
    md.aadhar,
    md.c_gender,
    md.phone_number,
    md.email,
    md.pin_code,
    md.city,
    md.state,

    -- ── LOAN DETAILS ──
    md.loan_status,
    md.sanctioned_amount,
    md.loan_amount_w_insurance,
    md.loan_amount_wo_insurance,
    md.pos_current,
    md.pos_lm,
    md.total_pos,
    md.tenure_at_sanction,
    md.current_total_tenure,
    md.balance_tenure,
    md.balance_tenure_lm,
    md.current_dpd,
    md.dpd_last_month,
    md.current_interest_rate,
    md.emi_amount,
    md.first_disb_date,
    md.latest_disb_date,
    md.sanction_date,
    md.final_maturity_date,
    md.mob_first_disb,
    md.emis_paid,
    md.sz_repayment_mode,
    md.profile_type,
    md.income_program,
    md.foir,
    md.ltv,
    md.calculated_ltv,
    md.bt,
    md.branch,
    md.region,

    -- ── APPLICANT ──
    md.dt_birth_date,
    md.age_current,
    md.age_at_maturity,
    md.cibil_score,
    md.sz_ckyc_id,
    md.udyam_aadhar_number,
    md.has_udyam,
    md.udyam_enterprise_type,
    md.sz_primary_occupation,
    md.business_name,
    md.sz_appl_category_code,

    -- ── PROPERTY ──
    md.property_type,
    md.property_subtype,
    md.property_occupation,
    md.total_property_value,
    md.residential_property_value,
    md.residential_property_cnt,
    md.commercial_property_cnt,
    md.plot_count,
    md.industrial_shed_count,
    md.residential_pct,
    md.sz_cersai_sec_int_id,
    md.property_city,
    md.property_state,

    -- ── DPD / NPA / BOUNCE ──
    md.max_dpd_ever,
    md.max_dpd_6m,
    md.max_dpd_12m,
    md.max_dpd_18m,
    md.ever_30_dpd_6m,
    md.ever_npa,
    md.is_restructured,
    md.ever_bucket,
    md.bounce_count_l3m,
    md.bounce_count_l6m,
    md.bounce_count_l12m,
    md.overdue_principal_current,
    md.overdue_interest_current,
    md.overdue_principal_lm,
    md.overdue_interest_lm,
    md.npa_flag,
    md.restructure_flag,
    md.morat_flag,

    -- ── FUNDER / ASSIGNMENT ──
    md.sz_funder_status,
    md.sz_funder_name,
    md.direct_assignment,
    md.nhb,
    md.sz_nabard_name,
    md.refinance_scheme,

    -- ══════════════════════════════════════════════════════════════
    -- ELIGIBILITY FLAGS
    -- ══════════════════════════════════════════════════════════════

    -- 1. CIBIL >= 700
    CASE WHEN md.cibil_score >= 700 OR md.cibil_score = -1 THEN 1 ELSE 0 END
        AS cibil_700_eligibility,

    -- 1b. CIBIL >= 675 (alternate threshold for comparison)
    CASE WHEN md.cibil_score >= 675 OR md.cibil_score = -1 THEN 1 ELSE 0 END
        AS cibil_675_eligibility,

    -- 2. Min ticket ≥ 3L
    CASE WHEN md.loan_amount_w_insurance >= 300000 THEN 1 ELSE 0 END
        AS min_ticket_eligibility,

    -- 3. Min age ≥ 21
    CASE WHEN md.age_current >= 21 THEN 1 ELSE 0 END
        AS min_age_eligibility,

    -- 4. Max age at maturity ≤ 75
    CASE WHEN md.age_at_maturity <= 75 THEN 1 ELSE 0 END
        AS max_age_maturity_eligibility,

    -- 5. LTV < 70 (or < 75 for CIBIL > 750 / self-occupied)
    CASE
        WHEN md.calculated_ltv IS NULL THEN 0
        WHEN (md.cibil_score > 750 OR UPPER(md.property_occupation) LIKE '%SELF%')
             AND md.calculated_ltv < 75 THEN 1
        WHEN md.calculated_ltv < 70 THEN 1
        ELSE 0
    END AS ltv_eligibility,

    -- 6. Booking tenor
    CASE
        WHEN md.loan_amount_w_insurance <= 3000000 AND md.tenure_at_sanction <= 180 THEN 1
        WHEN md.loan_amount_w_insurance >  3000000 AND md.tenure_at_sanction <= 240 THEN 1
        ELSE 0
    END AS tenure_eligibility,

    -- 7. MOB / seasoning ≥ 6 months
    CASE WHEN md.mob_first_disb >= 6 THEN 1 ELSE 0 END
        AS seasoning_eligibility,

    -- 8. Never bucket/restructured/morat/NPA
    CASE
        WHEN md.ever_bucket = 0
            AND md.is_restructured = 0
            AND NVL(md.morat_flag, 'N') != 'Y'
            AND md.ever_npa = 0
        THEN 1 ELSE 0
    END AS never_adverse_eligibility,

    -- 9. DPD 6M: never 30+ in last 6 months
    CASE WHEN md.ever_30_dpd_6m = 0 THEN 1 ELSE 0 END
        AS dpd_6m_eligibility,

    -- 10. DPD 18M: < 30 in last 18 months
    CASE WHEN COALESCE(md.max_dpd_18m, 0) < 30 THEN 1 ELSE 0 END
        AS dpd_18m_eligibility,

    -- 11. Current overdue ≤ 1000
    CASE
        WHEN COALESCE(md.overdue_principal_lm, 0) <= 1000
             AND COALESCE(md.overdue_interest_lm, 0) <= 1000
        THEN 1 ELSE 0
    END AS overdue_eligibility,

    -- 12. Bounce (MOB-dependent)
    CASE
        WHEN md.mob_first_disb <= 6 THEN
            CASE WHEN md.bounce_count_l6m = 0 THEN 1 ELSE 0 END
        WHEN md.mob_first_disb > 6 AND md.mob_first_disb <= 12 THEN
            CASE WHEN md.bounce_count_l6m <= 1 AND md.bounce_count_l3m = 0 THEN 1 ELSE 0 END
        WHEN md.mob_first_disb > 12 THEN
            CASE WHEN md.bounce_count_l12m <= 2
                      AND md.bounce_count_l3m = 0
                      AND md.bounce_count_l6m <= 1 THEN 1 ELSE 0 END
        ELSE 0
    END AS bounce_eligibility,

    -- 13. Collateral: no plot/land, no industrial/shed
    CASE
        WHEN NVL(md.plot_count, 0) = 0
             AND NVL(md.industrial_shed_count, 0) = 0
        THEN 1 ELSE 0
    END AS collateral_eligibility,

    -- 14. Residential ≥ 80%
    CASE WHEN md.residential_pct >= 80 THEN 1 ELSE 0 END
        AS residential_ratio_eligibility,

    -- 15. Profile check (exclude lawyers, police, PEPs, brokers, builders)
    CASE
        WHEN UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%LAWYER%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%POLICE%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%PEP%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%REAL ESTATE%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BROKER%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BUILDER%'
        THEN 0 ELSE 1
    END AS profile_eligibility,

    -- 16. Not already assigned / funded
    CASE
        WHEN md.sz_funder_status IS NOT NULL THEN 0
        WHEN md.direct_assignment IS NOT NULL THEN 0
        WHEN UPPER(NVL(md.nhb, '')) LIKE '%NHB%' THEN 0
        WHEN md.sz_nabard_name IS NOT NULL THEN 0
        WHEN md.refinance_scheme IS NOT NULL THEN 0
        ELSE 1
    END AS not_assigned_eligibility,

    -- 17. NACH/ECS repayment mode
    CASE WHEN UPPER(NVL(md.sz_repayment_mode, '')) IN ('NACH', 'ECS') THEN 1 ELSE 0 END
        AS repayment_mode_eligibility,

    -- ══════════════════════════════════════════════════════════════
    -- OVERALL ELIGIBILITY — AT CIBIL 700
    -- ══════════════════════════════════════════════════════════════
    CASE
        WHEN (md.cibil_score >= 700 OR md.cibil_score = -1)  -- CIBIL 700
            AND md.loan_amount_w_insurance >= 300000
            AND md.age_current >= 21
            AND md.age_at_maturity <= 75
            AND (
                (md.cibil_score > 750 OR UPPER(md.property_occupation) LIKE '%SELF%')
                    AND md.calculated_ltv < 75
                OR md.calculated_ltv < 70
            )
            AND (
                (md.loan_amount_w_insurance <= 3000000 AND md.tenure_at_sanction <= 180)
                OR (md.loan_amount_w_insurance >  3000000 AND md.tenure_at_sanction <= 240)
            )
            AND md.mob_first_disb >= 6
            AND md.ever_bucket = 0
            AND md.is_restructured = 0
            AND NVL(md.morat_flag, 'N') != 'Y'
            AND md.ever_npa = 0
            AND md.ever_30_dpd_6m = 0
            AND COALESCE(md.max_dpd_18m, 0) < 30
            AND COALESCE(md.overdue_principal_lm, 0) <= 1000
            AND COALESCE(md.overdue_interest_lm, 0) <= 1000
            AND (
                (md.mob_first_disb <= 6 AND md.bounce_count_l6m = 0)
                OR (md.mob_first_disb > 6 AND md.mob_first_disb <= 12
                    AND md.bounce_count_l6m <= 1 AND md.bounce_count_l3m = 0)
                OR (md.mob_first_disb > 12
                    AND md.bounce_count_l12m <= 2
                    AND md.bounce_count_l3m = 0
                    AND md.bounce_count_l6m <= 1)
            )
            AND NVL(md.plot_count, 0) = 0
            AND NVL(md.industrial_shed_count, 0) = 0
            AND md.residential_pct >= 80
            AND NOT (
                UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%LAWYER%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%POLICE%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%PEP%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%REAL ESTATE%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BROKER%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BUILDER%'
            )
            AND md.sz_funder_status IS NULL
            AND md.direct_assignment IS NULL
            AND (UPPER(NVL(md.nhb, '')) NOT LIKE '%NHB%')
            AND md.sz_nabard_name IS NULL
            AND md.refinance_scheme IS NULL
        THEN 1 ELSE 0
    END AS overall_eligibility_at_700,

    -- ══════════════════════════════════════════════════════════════
    -- OVERALL ELIGIBILITY — AT CIBIL 675
    -- ══════════════════════════════════════════════════════════════
    CASE
        WHEN (md.cibil_score >= 675 OR md.cibil_score = -1)  -- CIBIL 675
            AND md.loan_amount_w_insurance >= 300000
            AND md.age_current >= 21
            AND md.age_at_maturity <= 75
            AND (
                (md.cibil_score > 750 OR UPPER(md.property_occupation) LIKE '%SELF%')
                    AND md.calculated_ltv < 75
                OR md.calculated_ltv < 70
            )
            AND (
                (md.loan_amount_w_insurance <= 3000000 AND md.tenure_at_sanction <= 180)
                OR (md.loan_amount_w_insurance >  3000000 AND md.tenure_at_sanction <= 240)
            )
            AND md.mob_first_disb >= 6
            AND md.ever_bucket = 0
            AND md.is_restructured = 0
            AND NVL(md.morat_flag, 'N') != 'Y'
            AND md.ever_npa = 0
            AND md.ever_30_dpd_6m = 0
            AND COALESCE(md.max_dpd_18m, 0) < 30
            AND COALESCE(md.overdue_principal_lm, 0) <= 1000
            AND COALESCE(md.overdue_interest_lm, 0) <= 1000
            AND (
                (md.mob_first_disb <= 6 AND md.bounce_count_l6m = 0)
                OR (md.mob_first_disb > 6 AND md.mob_first_disb <= 12
                    AND md.bounce_count_l6m <= 1 AND md.bounce_count_l3m = 0)
                OR (md.mob_first_disb > 12
                    AND md.bounce_count_l12m <= 2
                    AND md.bounce_count_l3m = 0
                    AND md.bounce_count_l6m <= 1)
            )
            AND NVL(md.plot_count, 0) = 0
            AND NVL(md.industrial_shed_count, 0) = 0
            AND md.residential_pct >= 80
            AND NOT (
                UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%LAWYER%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%POLICE%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%PEP%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%REAL ESTATE%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BROKER%'
                OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BUILDER%'
            )
            AND md.sz_funder_status IS NULL
            AND md.direct_assignment IS NULL
            AND (UPPER(NVL(md.nhb, '')) NOT LIKE '%NHB%')
            AND md.sz_nabard_name IS NULL
            AND md.refinance_scheme IS NULL
        THEN 1 ELSE 0
    END AS overall_eligibility_at_675,

    -- ══════════════════════════════════════════════════════════════
    -- REJECTION REASON (primary reason for ineligibility)
    -- ══════════════════════════════════════════════════════════════
    CASE
        WHEN md.cibil_score < 675 AND md.cibil_score != -1 THEN 'CIBIL < 675'
        WHEN md.cibil_score >= 675 AND md.cibil_score < 700 AND md.cibil_score != -1 THEN 'CIBIL 675-699'
        WHEN md.loan_amount_w_insurance < 300000 THEN 'Ticket < 3L'
        WHEN md.age_current < 21 THEN 'Age < 21'
        WHEN md.age_at_maturity > 75 THEN 'Age at Maturity > 75'
        WHEN md.calculated_ltv >= 70 AND NOT (md.cibil_score > 750 OR UPPER(md.property_occupation) LIKE '%SELF%') THEN 'LTV >= 70%'
        WHEN md.calculated_ltv >= 75 THEN 'LTV >= 75%'
        WHEN md.calculated_ltv IS NULL THEN 'LTV Not Available'
        WHEN md.mob_first_disb < 6 THEN 'Seasoning < 6 months'
        WHEN md.ever_bucket = 1 THEN 'Ever in Bucket (SMA/DBT/SUB/LSS/90+)'
        WHEN md.is_restructured = 1 THEN 'Restructured'
        WHEN NVL(md.morat_flag, 'N') = 'Y' THEN 'Moratorium'
        WHEN md.ever_npa = 1 THEN 'Ever NPA'
        WHEN md.ever_30_dpd_6m = 1 THEN 'DPD >= 30 in last 6M'
        WHEN COALESCE(md.max_dpd_18m, 0) >= 30 THEN 'DPD >= 30 in last 18M'
        WHEN COALESCE(md.overdue_principal_lm, 0) > 1000 THEN 'Overdue Principal > 1000'
        WHEN COALESCE(md.overdue_interest_lm, 0) > 1000 THEN 'Overdue Interest > 1000'
        WHEN NVL(md.plot_count, 0) > 0 THEN 'Plot/Land Property'
        WHEN NVL(md.industrial_shed_count, 0) > 0 THEN 'Industrial/Shed Property'
        WHEN md.residential_pct < 80 THEN 'Residential < 80%'
        WHEN UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%LAWYER%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%POLICE%'
            OR UPPER(NVL(md.sz_primary_occupation, '')) LIKE '%BUILDER%' THEN 'Excluded Profile'
        WHEN md.sz_funder_status IS NOT NULL
            OR md.direct_assignment IS NOT NULL THEN 'Already Assigned/Funded'
        WHEN md.tenure_at_sanction > 240 THEN 'Tenure > 240M'
        ELSE 'Eligible'
    END AS rejection_reason

FROM main_data md
ORDER BY md.sz_loan_account_no;
