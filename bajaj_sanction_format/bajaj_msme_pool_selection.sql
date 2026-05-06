-- ============================================================================
-- BAJAJ DA POOL - MSME in CGCL
-- Exclude: Pre-approved, HE assignment, Retail construction finance under HE
--          (Pure HE and HE in Home Loan)
-- Cutoff Date: February 2026 Month End (2026-02-28)
-- Entity: CGCL
-- ============================================================================

-- ============================================================================
-- VARIABLE DEFINITIONS
-- ============================================================================
WITH cutoff_date AS (
    SELECT '2026-02-28'::DATE AS cutoff
),

-- PDD (Post Disbursement Documents) Check
pdd AS (
    SELECT
        DISTINCT otc_pdd_1.sz_application_no
    FROM analytics_reporting.otc_pdd_table_cgcl otc_pdd_1
    WHERE otc_pdd = 'PDD'
        AND LOWER(doc_receivd_flag) IN ('n', 'no')
        AND NOT is_deleted
),

-- ============================================================================
-- MAIN DATA CTE
-- ============================================================================
main AS (
    SELECT
        ld.sz_loan_account_no,
        ld.sz_application_no,
        ld.source_system AS lms,
        lsm2.max_dpd_ever,
        lsm3.ever_npa,
        lsm4.cust_level_ever_npa_count,
        max_dpd_12mon.max_dpd_in_last_12months,
        ld.f_curr_interestrate,
        ld.f_interest_rate AS interest_rate_at_sanction,
        ld.c_interest_rate_type,
        ld.c_final_disb_yn,
        lsm.i_dpd,
        ld.i_cycleday,
        ld.installment_amount AS emi_amount,
        ld.c_cov_morat,
        ld.c_cov_morat_status,
        ld.dt_morat_start,
        ld.dt_morat_end,
        ld.sz_payment_recovery_mode,
        ld.loan_status,
        app.portfolio_description,
        ld.sz_portfolio_code,
        ld.sz_portfolio_desc,
        ld.sz_product_desc,
        app.case_status,
        ld.i_tenor AS tenure_at_sanction,
        ld."current total tenure" AS current_total_tenure,
        CEIL(MONTHS_BETWEEN((SELECT cutoff FROM cutoff_date), ld."latest disbursement date")) AS mob_based_on_last_disbursal,
        CEIL(MONTHS_BETWEEN((SELECT cutoff FROM cutoff_date), ld.installment_start_date)) AS mob_from_first_installment,
        CEIL(MONTHS_BETWEEN((SELECT cutoff FROM cutoff_date), ld."first disbursement date")) AS mob_based_on_first_disbursal,
        ld."latest disbursement date" AS latest_disbursal_date,
        ld."first disbursement date" AS first_disbursal_date,
        ld.installment_start_date AS emi_start_date,
        ld."balance tenure" AS balance_tenure_as_on_query_run_day,
        ld.npa_flag AS c_npa_yn,
        ld."total principal outstanding" AS total_pos_current,
        ld."principal outstanding" AS pos_current,
        ld."overdue principal" AS overdue_principal_current,
        ld."interest overdue" AS overdue_interest_current,
        ld.interest_accrud AS interest_accrud_current,
        ld.sz_repayment_mode,

        apt.dt_birth_date,
        FLOOR(DATEDIFF(day, apt.dt_birth_date, (SELECT cutoff FROM cutoff_date)) / 365.25) AS age_last_month,
        FLOOR(DATEDIFF(day, apt.dt_birth_date, NVL(ld."maturity date", repay.maturity_date)) / 365.25) AS age_at_maturity,
        apt.udyam_aadhar_number,
        apt.c_existing_customer_yn,
        app.sz_exist_apln_no AS existing_application_lan_level,
        apt.sz_exist_apln_no AS existing_application_cust_level,
        apt.sz_customer_no,
        apt4.count_co_applicant,
        apt.sz_appln_type,
        apt.sz_appl_type_code,
        apt.sz_appl_category_code,
        NVL(apt.sz_id2, apt.sz_panno) AS pan,
        apt_type.org_borrower_count,
        apt_type.org_coborrower_count,
        apt_type.org_guarantor_count,

        ld.c_psl,
        app.bt,
        app.portfolio_code,
        app.sz_appln_type AS top_up_flag,
        app.sz_parent_application,
        app.sz_servicing_branch_code,
        app.spoke,
        app.branch,
        app.region,
        apt.sz_apprsl_schm AS sz_apprsl_schm,
        apt.sz_field2 AS customer_title,
        NVL(apt.person_name, apt.sz_org_name) AS customer_name,
        (apt.sz_fathers_full_name || ' ' || apt.father_last_name) AS father_name,
        apt.sz_mother_maiden_name,
        apt.c_gender,
        apt.sz_religion,
        NVL(apt_add.sz_mobile1, apt_add.sz_mobile2) AS mobile,
        apt.sz_emp_bus_nm,
        NVL(apt.employment_sz_org_type_code, apt.self_employment_sz_org_type_code) AS business_type,

        apt_add.current_sz_address_1 AS sz_address_1,
        apt_add.current_sz_address_2 AS sz_address_2,
        apt_add.current_sz_postal_code AS sz_postal_code,
        apt_add.current_city AS city_code,
        apt_add.current_state AS state_code,
        (NVL(apt_add.current_sz_address_1, '') || ' ' || NVL(apt_add.current_sz_address_2, '') ||
         ' ' || NVL(apt_add.current_sz_address_3, '') || ' ' || NVL(apt_add.current_city, '') ||
         ' ' || NVL(apt_add.current_sz_postal_code, '') || ' ' || NVL(apt_add.current_state, '')) AS current_address,

        lsm.f_outstanding_amt,
        lsm.f_overdue_interest,
        lsm.f_overdue_principal,
        lsm.f_future_principal,
        lsm.pos,
        lsm.balance_tenure_last_month,

        ld.sz_funder_agree_no,
        ld.dt_funderdisb,
        ld.sz_funder_name,
        ld.sz_funder_status,
        ld.dt_funder_tagging,
        ld.nhb,
        ld.sz_nabard_name,
        ld.refinance_scheme,
        ld.c_cov_restructure,
        ld.c_cov_res_status,
        ld.sz_loan_purpose,

        app.foir,
        app.foir_wo_insurance,
        app.ltv,
        app.ltv_w_insurance,
        ld.f_sanctioned_amt AS system_sanctioned_amount,
        ld.insurance_amount AS total_insurance_amt,
        ld."loan amount with insurance" AS total_loan_amount_w_insurance,
        ld."loan amount without insurance" AS total_loan_amount_wo_insurance,
        ld.sanction_date,
        ld."cumulative amount disbursed" AS cumulative_amount_disbursed,
        ld.i_cur_dpd AS current_dpd,
        ld.sz_product_code,
        CASE
            WHEN ld.sz_product_desc IN (
                'Samriddhi Loans', 'Pre-Approved Loan', 'Emergency Credit Line Guarantee Scheme',
                'Saathi preapproved topup', 'Emergency Credit Line Guarantee Scheme 2',
                'RETAILS CONSTRUCTION FINANCE', 'HE – Assignment', 'RCF FUNDING'
            ) THEN 'PA_RCF'
            ELSE 'Other'
        END AS pre_approved_rcf_tag,

        asset.property_city,
        asset.property_state,
        asset.property_address,
        asset.total_property_value AS property_market_value,
        asset.residential_property_value,
        asset.asset_vacant_land_count,
        (lsm.pos * 100 / NULLIF(asset.total_property_value, 0)) AS ltv_derived_pos_value,
        asset.property_occupation,
        asset.property_type,
        asset.property_type AS collateral_type,
        asset.property_type AS nature_of_security,
        asset.property_ownership_mode,
        asset.property_subtype,
        asset.sz_development AS location_of_the_property_offered,
        asset.sz_subtype AS property_sub_type,
        asset.residual_asset_age,
        asset.is_under_construction,
        asset.construction_completion_de,
        asset.stage_of_construction_techval,
        asset.overall_completion_de,
        asset.local_authority,
        asset.dt_cersai,
        asset.sz_cersai_sec_int_id,
        asset.property_count,
        asset.residential_property_cnt,
        asset.industrial_property_cnt,
        asset.asset_plot_count,
        MONTHS_BETWEEN((SELECT cutoff FROM cutoff_date), asset.dt_cersai) AS months_btw_cersai_last_month,

        NVL(apt.sz_id2, apt.sz_panno) AS pan_no,
        apt.sz_voter_id AS voter_id,
        apt.sz_id3 AS driving_lic,
        apt.sz_ration_card_no AS ration_card,
        apt.sz_id1 AS passport,
        apt.sz_uid_no AS aadhar_number,
        COALESCE(apt.sz_uid_no, apt.sz_voter_id, apt.sz_id3, apt.sz_ration_card_no, apt.sz_id1) AS kyc_doc_id,

        CASE
            WHEN LOWER(apt.sz_cibil_score) LIKE '%[a-z]%'
                OR UPPER(apt.sz_cibil_score) LIKE '%[A-Z]%'
                OR LOWER(apt.sz_cibil_score) LIKE '%=%'
                OR LOWER(apt.sz_cibil_score) LIKE '%-%'
                OR LOWER(apt.sz_cibil_score) LIKE '%.%'
                OR LOWER(apt.sz_cibil_score) LIKE '%n%'
                OR LOWER(apt.sz_cibil_score) LIKE '%o%'
                OR UPPER(apt.sz_cibil_score) LIKE '%U%'
                OR UPPER(apt.sz_cibil_score) LIKE '%S%'
                OR UPPER(apt.sz_cibil_score) LIKE '%C%'
                OR apt.sz_cibil_score IN ('SUC')
                OR LOWER(apt.sz_cibil_score) IS NULL
            THEN -1
            WHEN CAST(apt.sz_cibil_score AS INT) < 300 THEN -1
            ELSE CAST(apt.sz_cibil_score AS INT)
        END AS sz_cibil_score,

        apt.income_program,
        apt.income_type,
        CASE
            WHEN LOWER(apt.income_program) LIKE '%salar%' THEN 'SALARIED'
            WHEN LOWER(apt.income_program) LIKE '%senp%'
                OR LOWER(apt.income_program) LIKE '%sep%'
                OR apt.income_program IN ('Self Employed - NIP-CPM', 'Self Employed - NIP')
            THEN 'SENP'
            ELSE UPPER(apt.income_program)
        END AS profile_type,
        apt.sz_primary_occupation,
        apt.sz_ucic,
        SUM(ld."principal outstanding") OVER (PARTITION BY ld.sz_customer_no) AS customer_level_pos,
        apt.sz_ckyc_id,
        apt2.income_at_application_level,
        COUNT(ld.sz_loan_account_no) OVER (PARTITION BY apt.sz_customer_no) AS cust_no_lanscount,
        COUNT(ld.sz_loan_account_no) OVER (PARTITION BY NVL(apt.sz_id2, apt.sz_panno)) AS pan_lanscount,
        COUNT(ld.sz_loan_account_no) OVER (PARTITION BY apt.sz_ucic) AS ucic_lanscount,

        ld2.sz_product_code AS parent_prod_code,
        ld2.sz_application_no AS parent_application_no,
        NVL(ld."maturity date", repay.maturity_date) AS final_maturity_date,
        repay.tenure_repayment_details,
        repay.emis_paid,
        ld.scheme,
        ld."direct assignment" AS direct_assignment,

        CASE
            WHEN UPPER(apt.sz_org_constitution) IN ('FIR', 'PARTNER', 'PAR') THEN 'PART'
            WHEN UPPER(apt.sz_org_constitution) IN ('HNUF', 'HUF')
                OR UPPER(apt.sz_org_name) LIKE '%HUF%' THEN 'HUF'
            WHEN UPPER(apt.sz_org_constitution) IN ('SELF EMP NON PROF', 'HUF')
                OR apt.sz_resi_status IN ('Indian', 'RI') THEN 'RESI'
            WHEN UPPER(apt.sz_org_constitution) IN ('LIMITED LIABILITY', 'LLP')
                OR UPPER(apt.sz_org_name) LIKE '%LLP' THEN 'LLP'
            WHEN UPPER(apt.sz_org_constitution) IN ('PSU', 'PUBLIC', 'PUL') THEN 'PUBL'
            WHEN UPPER(apt.sz_org_constitution) IN ('PROPRIETOR', 'SPR', 'PROPR') THEN 'PROP'
            WHEN UPPER(apt.sz_org_constitution) IN ('TST') THEN 'TRST'
            WHEN UPPER(apt.sz_org_constitution) IN ('SOCIETY')
                OR UPPER(apt.sz_org_name) LIKE '%SOCIETY%'
                OR UPPER(apt.sz_org_name) LIKE '%SOSIETY%' THEN 'SOCT'
            WHEN UPPER(apt.sz_org_name) LIKE '%SAMITI%'
                OR UPPER(apt.sz_org_name) LIKE '%SANSTHA%'
                OR UPPER(apt.sz_org_name) LIKE '%SCHOOL%' THEN 'AOP'
            WHEN UPPER(apt.sz_org_constitution) IN ('TST')
                OR UPPER(apt.sz_org_name) LIKE '%TRUST' THEN 'TRST'
            WHEN UPPER(apt.sz_org_constitution) IN ('PRIVATE LIMITED', 'PRL')
                OR UPPER(apt.sz_org_name) LIKE '%PRIVATE LIMITED'
                OR UPPER(apt.sz_org_name) LIKE '%PVT LTD'
                OR UPPER(apt.sz_org_name) LIKE '%PRIVATE LTD'
                OR UPPER(apt.sz_org_name) LIKE '%P LTD'
                OR UPPER(apt.sz_org_name) LIKE '%P LIMITED'
                OR UPPER(apt.sz_org_name) LIKE '%PRIVATED LIMITED' THEN 'PVTL'
            WHEN UPPER(apt.sz_org_name) LIKE '%LIMITED' THEN 'PUBL'
            WHEN UPPER(apt.sz_resi_status) IN ('FR', 'NRI') THEN 'NRI'
            ELSE 'PROP'
        END AS legal_constitution,

        NVL(bounce.no_of_bounce_last_6_month_same_day, 0) AS no_of_bounce_last_6_month_same_day,
        NVL(bounce.no_of_bounce_last_6_month_3_day, 0) AS no_of_bounce_last_6_month_3_day,
        NVL(bounce.no_of_bounce_last_6_month_5_day, 0) AS no_of_bounce_last_6_month_5_day,
        NVL(bounce.no_of_bounce_last_6_month_same_month, 0) AS no_of_bounce_last_6_month_same_month,
        NVL(bounce2.no_of_bounce_last_last_7_12_month_same_day, 0) AS no_of_bounce_last_last_7_12_month_same_day,
        NVL(bounce2.no_of_bounce_last_last_7_12_month_3_day, 0) AS no_of_bounce_last_last_7_12_month_3_day,
        NVL(bounce2.no_of_bounce_last_last_7_12_month_5_day, 0) AS no_of_bounce_last_last_7_12_month_5_day,
        NVL(bounce2.no_of_bounce_last_7_12_month_same_month, 0) AS no_of_bounce_last_7_12_month_same_month,

        app.pd_status,
        app.pd_done_date

    FROM analytics_reporting.loan_dtl_cgcl ld
    LEFT JOIN (
        SELECT
            sz_application_no,
            sz_lan_no,
            dt_creation,
            sz_exist_apln_no,
            sz_parent_application,
            portfolio_code,
            portfolio_description,
            sz_servicing_branch_code,
            branch,
            spoke,
            sz_appln_type,
            CASE
                WHEN sz_servicing_branch_code = 'JNJ' THEN 'RJ1'
                WHEN region = 'NR' THEN 'North'
                WHEN region = 'WT' THEN 'West'
                ELSE region
            END AS region,
            foir_wo_insurance,
            foir_with_insurance AS foir,
            ltv_wo_insurance AS ltv,
            ltv_w_insurance,
            bt,
            case_status,
            pd_status,
            pd_done_date
        FROM analytics_reporting.application_cgcl
    ) app ON app.sz_application_no = ld.sz_application_no
    INNER JOIN (
SELECT *
        FROM analytics_reporting.applicant_basic_dtl_cgcl
        WHERE TRIM(sz_loan_account_no) NOT IN ('53000001013188')
            AND sz_appl_type_code = 'BORROWER'
    ) apt ON app.sz_application_no = apt.sz_application_no
    LEFT JOIN (
        SELECT
            sz_application_no,
            SUM(final_income) AS income_at_application_level
        FROM analytics_reporting.applicant_basic_dtl_cgcl
        WHERE sz_appl_type_code = 'BORROWER'
            OR (sz_appl_type_code = 'COBORROWER' AND (c_incm_consid = 'Y' OR sz_appl_category_code = 'O'))
        GROUP BY sz_application_no
    ) apt2 ON app.sz_application_no = apt2.sz_application_no
    LEFT JOIN (
        SELECT
            sz_application_no,
            COUNT(sz_application_no) AS count_co_applicant
        FROM analytics_reporting.applicant_basic_dtl_cgcl
        WHERE sz_appl_type_code = 'COBORROWER'
        GROUP BY sz_application_no
    ) apt4 ON app.sz_application_no = apt4.sz_application_no
    LEFT JOIN analytics_reporting.loan_dtl_cgcl ld2
        ON apt.sz_exist_apln_no = ld2.sz_application_no
        AND apt.sz_appl_type_code = 'BORROWER'
    LEFT JOIN (
        SELECT
            sz_loan_account_no,
            dt_businessdate,
            loan_status,
            i_dpd,
            f_outstanding_amt,
            f_overdue_interest,
            f_overdue_principal,
            f_future_principal,
            (f_overdue_principal + f_future_principal) AS pos,
            i_no_of_paid_emi,
            i_no_of_unpaid_emi,
            balance_tenure AS balance_tenure_last_month
        FROM analytics_reporting.loan_status_monthly_cgcl
        WHERE dt_businessdate = (SELECT cutoff FROM cutoff_date)
            AND UPPER(NVL(loan_status, '')) IN ('LIVE', 'APPROVED')
    ) lsm ON ld.sz_loan_account_no = lsm.sz_loan_account_no
    LEFT JOIN (
        SELECT
            TRIM(sz_loan_account_no) AS sz_loan_account_no,
            MAX(i_dpd) AS max_dpd_ever
        FROM analytics_reporting.loan_status_monthly_cgcl
        GROUP BY sz_loan_account_no
    ) lsm2 ON ld.sz_loan_account_no = lsm2.sz_loan_account_no
    LEFT JOIN (
        SELECT
            sz_loan_account_no,
            MAX(CASE
                WHEN npa_flag = 'Y' THEN 1
                WHEN npa_flag = 'N' THEN 0
            END) AS ever_npa
        FROM analytics_reporting.loan_status_monthly_cgcl
        GROUP BY sz_loan_account_no
    ) lsm3 ON ld.sz_loan_account_no = lsm3.sz_loan_account_no
    LEFT JOIN (
        SELECT
            DISTINCT sz_loan_account_no,
            SUM(CASE
                WHEN npa_flag = 'Y' THEN 1
                WHEN npa_flag = 'N' THEN 0
            END) OVER (PARTITION BY sz_customer_no) AS cust_level_ever_npa_count
        FROM analytics_reporting.loan_status_monthly_cgcl
        GROUP BY sz_loan_account_no, sz_customer_no, npa_flag
    ) lsm4 ON ld.sz_loan_account_no = lsm4.sz_loan_account_no
    LEFT JOIN (
        SELECT
            sz_loan_account_no,
            MAX(i_dpd) AS max_dpd_in_last_12months
        FROM analytics_reporting.loan_status_monthly_cgcl
        WHERE dt_businessdate >= DATEADD(month, -12, (SELECT cutoff FROM cutoff_date))
            AND dt_businessdate <= (SELECT cutoff FROM cutoff_date)
        GROUP BY sz_loan_account_no
    ) max_dpd_12mon ON ld.sz_loan_account_no = max_dpd_12mon.sz_loan_account_no
    LEFT JOIN (
        SELECT
            DISTINCT sz_application_no,
            SUM(CASE WHEN sz_appl_type_code = 'BORROWER' AND sz_appl_category_code = 'O' THEN 1 ELSE 0 END) AS org_borrower_count,
            SUM(CASE WHEN sz_appl_type_code = 'COBORROWER' AND sz_appl_category_code = 'O' THEN 1 ELSE 0 END) AS org_coborrower_count,
            SUM(CASE WHEN sz_appl_type_code = 'GUARANTOR' AND sz_appl_category_code = 'O' THEN 1 ELSE 0 END) AS org_guarantor_count
        FROM analytics_reporting.applicant_basic_dtl_cgcl
        GROUP BY sz_application_no
    ) apt_type ON ld.sz_application_no = apt_type.sz_application_no
    LEFT JOIN (
        SELECT
            sz_loan_account_no,
            MIN(dt_installmentdue) AS installment_start_date,
            MAX(dt_installmentdue) AS maturity_date,
            MAX(i_installment_no) AS tenure_repayment_details,
            MAX(CASE WHEN dt_installmentdue <= (SELECT cutoff FROM cutoff_date) THEN i_installment_no END) AS emis_paid
        FROM analytics_reporting.lms_repay_schedule_cgcl
        GROUP BY sz_loan_account_no
    ) repay ON ld.sz_loan_account_no = repay.sz_loan_account_no
    LEFT JOIN analytics_reporting.applicant_address_contact_dtl_cgcl apt_add
        ON apt.sz_application_no = apt_add.sz_application_no
        AND apt.i_applicant_id = apt_add.i_applicant_id
    LEFT JOIN (
        SELECT * FROM (
            SELECT
                sz_application_no,
                i_asset_srno,
                property_type,
                sz_description,
                sz_cersai_sec_int_id,
                dt_cersai,
                i_asset_age,
                (60 - i_asset_age) AS residual_asset_age,
                property_subtype,
                a_sz_prop_usage,
                is_under_construction,
                construction_completion_de,
                overall_completion_de,
                stage_of_construction_techval,
                sz_development,
                property_occupation,
                property_ownership_mode,
                sz_subtype,
                city AS property_city,
                state AS property_state,
                property_local_authority AS local_authority,
                SUM(a_i_tot_valuation) OVER (PARTITION BY sz_application_no) AS total_property_value,
                COUNT(i_asset_srno) OVER (PARTITION BY sz_application_no) AS property_count,
                SUM(CASE WHEN LOWER(property_type) LIKE '%residential%' THEN a_i_tot_valuation ELSE 0 END) OVER (PARTITION BY sz_application_no) AS residential_property_value,
                COUNT(CASE WHEN LOWER(property_type) LIKE '%residential%' THEN property_type ELSE NULL END) OVER (PARTITION BY sz_application_no) AS residential_property_cnt,
                COUNT(CASE WHEN LOWER(property_type) LIKE '%industrial%' THEN property_type ELSE NULL END) OVER (PARTITION BY sz_application_no) AS industrial_property_cnt,
                COUNT(CASE WHEN LOWER(property_type) LIKE '%plot%' THEN i_asset_srno ELSE NULL END) OVER (PARTITION BY sz_application_no) AS asset_plot_count,
                COUNT(CASE
                    WHEN UPPER(property_occupation) LIKE '%VCNT%'
                        OR UPPER(property_occupation) LIKE '%VACANT%'
                        OR LOWER(property_type) LIKE '%plot%'
                        OR sz_subtype IN ('VACANT LAND', 'PLOT')
                    THEN i_asset_srno
                    ELSE NULL
                END) OVER (PARTITION BY sz_application_no) AS asset_vacant_land_count,
                is_pni,
                ROW_NUMBER() OVER (PARTITION BY sz_application_no ORDER BY a_i_tot_valuation DESC, dt_valdate DESC, is_pni ASC) AS rk,
                (NVL(sz_address_1, '') || ' ' || NVL(sz_address_2, '') || ' ' ||
                 NVL(sz_address_3, '') || ' ' || NVL(city, '') || ' ' ||
                 NVL(sz_postal_code, '') || ' ' || NVL(state, '')) AS property_address
            FROM analytics_reporting.asset_cgcl
            WHERE sz_application_no IS NOT NULL
        ) ranked_asset
        WHERE rk = 1
    ) asset ON ld.sz_application_no = asset.sz_application_no
    LEFT JOIN (
        SELECT
            sz_loan_account_no,
            COUNT(
                DISTINCT CASE
                    WHEN bounce_status_same_day = 'BOUNCE'
                        AND tech_bounce_ind = 0
                        AND not_presented_ind = 'PRESENTED'
                        AND manual_hold_ind = 'NO_HOLD'
                    THEN dt_installmentdue
                    ELSE NULL
                END
            ) AS no_of_bounce_last_6_month_same_day,
            SUM(CASE WHEN bounce_status_3_day = 'BOUNCE' THEN 1 ELSE 0 END) AS no_of_bounce_last_6_month_3_day,
            SUM(CASE WHEN bounce_status_5_day = 'BOUNCE' THEN 1 ELSE 0 END) AS no_of_bounce_last_6_month_5_day,
            SUM(CASE WHEN bounce_status_same_month = 'BOUNCE' THEN 1 ELSE 0 END) AS no_of_bounce_last_6_month_same_month
        FROM external_curated.nb_cbr_cgcl_final_new
        WHERE dt_installmentdue >= DATEADD(month, -6, (SELECT cutoff FROM cutoff_date))
            AND dt_installmentdue <= (SELECT cutoff FROM cutoff_date)
        GROUP BY sz_loan_account_no
    ) bounce ON ld.sz_loan_account_no = bounce.sz_loan_account_no
    LEFT JOIN (
        SELECT
            sz_loan_account_no,
            COUNT(
                DISTINCT CASE
                    WHEN bounce_status_same_day = 'BOUNCE'
                        AND tech_bounce_ind = 0
                        AND not_presented_ind = 'PRESENTED'
                        AND manual_hold_ind = 'NO_HOLD'
                    THEN dt_installmentdue
                    ELSE NULL
                END
            ) AS no_of_bounce_last_last_7_12_month_same_day,
            SUM(CASE WHEN bounce_status_3_day = 'BOUNCE' THEN 1 ELSE 0 END) AS no_of_bounce_last_last_7_12_month_3_day,
            SUM(CASE WHEN bounce_status_5_day = 'BOUNCE' THEN 1 ELSE 0 END) AS no_of_bounce_last_last_7_12_month_5_day,
            SUM(CASE WHEN bounce_status_same_month = 'BOUNCE' THEN 1 ELSE 0 END) AS no_of_bounce_last_7_12_month_same_month
        FROM external_curated.nb_cbr_cgcl_final_new
        WHERE dt_installmentdue >= DATEADD(month, -12, (SELECT cutoff FROM cutoff_date))
            AND dt_installmentdue < DATEADD(month, -6, (SELECT cutoff FROM cutoff_date))
        GROUP BY sz_loan_account_no
    ) bounce2 ON ld.sz_loan_account_no = bounce2.sz_loan_account_no
)

SELECT
    *,
    CASE
        WHEN approved_eligibility_status = 1
            AND c_final_disb_eligibility_status = 1
            AND property_type_eligibility_status_v2 = 1
            AND profile_type_eligibility_status = 1
            AND loan_amt_eligibility_status = 1
            AND tenure_at_sanction_eligibility_status = 1
            AND balance_tenure_eligibility_status = 1
            AND age_at_maturity_eligibility_status = 1
            AND ltv_eligibility_status = 1
            AND mob_first_disbursal_eligibility_status = 1
            AND asset_plot_eligibility_status = 1
            AND industrial_property_eligibility_status = 1
            AND cibil_eligibility_status = 1
            AND max_dpd_ever_eligibility_status = 1
            AND all_applicant_individual_eligibility_status = 1
            AND individual_only_eligibility_status = 1
            AND overdue_eligibility_status = 1
            AND current_dpd_eligibility_status = 1
            AND cust_level_ever_npa_eligibility_status = 1
            AND funder_flag = 1
            AND direct_assignment_flag = 1
            AND nhb_flag = 1
            AND nabard_flag = 1
            AND refinance_scheme_flag = 1
            AND current_npa_flag_flag = 1
            AND installment_start_date_flag = 1
            AND msme_flag = 1
            AND pdd_eligibility_status = 1
            AND bounce_last_six_months_same_day_eligibility_status = 1
            AND bounce_last_seven_twelve_months_same_day_eligibility_status = 1
        THEN 1
        ELSE 0
    END AS final_eligibility_status
FROM (
    SELECT
        -- ================================================================
        -- SECTION 1: LOAN IDENTIFICATION
        -- ================================================================
        main.sz_loan_account_no,
        main.sz_application_no,
        main.lms,
        main.sz_parent_application,
        main.existing_application_lan_level,
        main.existing_application_cust_level,
        main.sz_appln_type,
        main.sz_customer_no              AS customer_id,
        main.customer_name,
        main.count_co_applicant,
        main.pan,
        main.sz_ckyc_id,
        main.udyam_aadhar_number,
        main.c_gender                    AS applicant_gender,
        main.dt_birth_date               AS dob,
        main.age_last_month,
        NULL                             AS rate_method,

        -- ================================================================
        -- SECTION 2: LOAN STATUS  →  approved_eligibility_status
        -- ================================================================
        main.loan_status,
        CASE WHEN main.loan_status = 'APPROVED' THEN 1 ELSE 0 END AS approved_eligibility_status,

        -- ================================================================
        -- SECTION 3: DISBURSEMENT STATUS  →  c_final_disb_eligibility_status
        -- ================================================================
        main.c_final_disb_yn,
        CASE
            WHEN main.c_final_disb_yn = 'Y' THEN 'Fully_Disbursed'
            WHEN main.c_final_disb_yn = 'N' THEN 'Partially_Disbursed'
        END AS disbursal_status,
        CASE WHEN main.c_final_disb_yn = 'Y' THEN 1 ELSE 0 END AS c_final_disb_eligibility_status,

        -- ================================================================
        -- SECTION 4: LOAN AMOUNT  →  loan_amt_eligibility_status
        -- ================================================================
        main.system_sanctioned_amount,
        main.total_loan_amount_w_insurance,
        CASE
            WHEN main.total_loan_amount_w_insurance >= 500000
             AND main.total_loan_amount_w_insurance <= 5000000 THEN 1
            ELSE 0
        END AS loan_amt_eligibility_status,

        -- ================================================================
        -- SECTION 5: TENURE  →  tenure / balance_tenure eligibility
        -- ================================================================
        main.tenure_at_sanction,
        CASE
            WHEN main.total_loan_amount_w_insurance <= 3000000
                AND main.tenure_at_sanction <= 180 THEN 1
            WHEN main.total_loan_amount_w_insurance > 3000000
                AND main.tenure_at_sanction <= 240 THEN 1
            ELSE 0
        END AS tenure_at_sanction_eligibility_status,
        main.balance_tenure_last_month,
        CASE
            WHEN main.balance_tenure_last_month <= 240
             AND main.balance_tenure_last_month > 12 THEN 1
            ELSE 0
        END AS balance_tenure_eligibility_status,

        -- ================================================================
        -- SECTION 6: DATES & MOB  →  mob / installment_start eligibility
        -- ================================================================
        main.sanction_date,
        main.latest_disbursal_date,
        main.first_disbursal_date,
        main.mob_based_on_first_disbursal,
        -- MOB rule (single source of truth): first disbursal seasoning >= 5 months
        CASE WHEN main.mob_based_on_first_disbursal >= 5 THEN 1 ELSE 0 END AS mob_first_disbursal_eligibility_status,
        main.emi_start_date,
        CASE WHEN main.emi_start_date > (SELECT cutoff FROM cutoff_date) THEN 0 ELSE 1 END AS installment_start_date_flag,
        main.final_maturity_date,
        main.age_at_maturity,
        CASE WHEN main.age_at_maturity <= 70 THEN 1 ELSE 0 END AS age_at_maturity_eligibility_status,
        main.emis_paid                   AS no_of_emis_paid,
        main.dt_morat_start,
        main.dt_morat_end,
        main.c_cov_morat,
        CASE WHEN main.c_cov_morat = 'Y' THEN 0 ELSE 1 END AS c_cov_morat_flag,

        -- ================================================================
        -- SECTION 7: DPD / NPA  →  dpd / npa eligibility flags
        -- ================================================================
        main.current_dpd,
        CASE WHEN main.current_dpd = 0 THEN 1 ELSE 0 END AS current_dpd_eligibility_status,
        main.max_dpd_in_last_12months,
        main.max_dpd_ever,
        CASE WHEN main.max_dpd_ever < 30 THEN 1 ELSE 0 END AS max_dpd_ever_eligibility_status,
        main.ever_npa,
        main.c_npa_yn,
        CASE WHEN main.c_npa_yn = 'Y' THEN 0 ELSE 1 END AS current_npa_flag_flag,
        main.cust_level_ever_npa_count,
        CASE WHEN main.cust_level_ever_npa_count = 0 THEN 1 ELSE 0 END AS cust_level_ever_npa_eligibility_status,

        -- ================================================================
        -- SECTION 8: OVERDUE / OUTSTANDING  →  overdue_eligibility_status
        -- ================================================================
        main.overdue_principal_current,
        main.overdue_interest_current,
        main.f_overdue_interest,
        main.f_overdue_principal,
        CASE WHEN (NVL(main.f_overdue_interest, 0) + NVL(main.f_overdue_principal, 0)) = 0 THEN 1 ELSE 0 END AS overdue_eligibility_status,
        main.pos_current,
        main.f_outstanding_amt           AS last_month_end_outstanding,
        main.pos                         AS last_month_end_pos,

        -- ================================================================
        -- SECTION 9: INTEREST / EMI / INCOME / LTV  →  ltv_eligibility_status
        -- ================================================================
        main.f_curr_interestrate         AS current_interest_rate,
        main.emi_amount                  AS current_emi,
        main.i_cycleday                  AS cycle_day,
        main.income_at_application_level,
        main.ltv,
        CASE WHEN main.ltv < 70 THEN 1 ELSE 0 END AS ltv_eligibility_status,

        -- ================================================================
        -- SECTION 10: PROFILE / CIBIL  →  profile / cibil eligibility
        -- ================================================================
        main.profile_type,
        main.income_program,
        CASE WHEN main.profile_type IN ('SALARIED', 'SENP', 'SEP') THEN 1 ELSE 0 END AS profile_type_eligibility_status,
        main.sz_cibil_score,
        CASE WHEN main.sz_cibil_score >= 650 OR main.sz_cibil_score = -1 THEN 1 ELSE 0 END AS cibil_eligibility_status,

        -- ================================================================
        -- SECTION 11: PORTFOLIO / PRODUCT / MSME  -> msme_flag
        -- ================================================================
        main.sz_portfolio_code,
        main.sz_portfolio_desc,
        main.portfolio_description,
        main.sz_product_desc,
        main.sz_product_code,
        main.sz_loan_purpose             AS loan_purpose,
        CASE
            WHEN (
                UPPER(NVL(main.sz_product_desc, '')) LIKE '%MSME%'
                OR UPPER(NVL(main.sz_product_desc, '')) LIKE '%SME%'
            )
            THEN CASE
                WHEN UPPER(NVL(main.sz_portfolio_desc, ''))     LIKE '%EQUITY%'
                  OR UPPER(NVL(main.portfolio_description, '')) LIKE '%EQUITY%'
                  OR UPPER(NVL(main.sz_product_desc, ''))       LIKE '%MICROLAP%'
                  OR UPPER(NVL(main.sz_product_desc, ''))       LIKE '%MICRO LAP%'
                  OR UPPER(NVL(main.sz_product_desc, '')) IN (
                        'PRE-APPROVED LOAN',
                        'SAATHI PREAPPROVED TOPUP',
                        'EMERGENCY CREDIT LINE GUARANTEE SCHEME',
                        'EMERGENCY CREDIT LINE GUARANTEE SCHEME 2',
                        'RETAILS CONSTRUCTION FINANCE',
                        'HE – ASSIGNMENT',
                        'RCF FUNDING',
                        'SAMRIDDHI LOANS'
                     )
                THEN 0
                ELSE 1
            END
            ELSE 0
        END AS msme_flag,

        -- ================================================================
        -- SECTION 12: APPLICANT CONSTITUTION  →  individual eligibility flags
        -- ================================================================
        main.sz_appl_category_code,
        CASE WHEN UPPER(TRIM(NVL(main.sz_appl_category_code, ''))) = 'I' THEN 1 ELSE 0 END AS individual_only_eligibility_status,
        main.org_borrower_count,
        main.org_coborrower_count,
        main.org_guarantor_count,
        CASE
            WHEN main.org_borrower_count = 0
             AND main.org_coborrower_count = 0
             AND main.org_guarantor_count = 0 THEN 1
            ELSE 0
        END AS all_applicant_individual_eligibility_status,
        main.legal_constitution,

        -- ================================================================
        -- SECTION 13: PROPERTY  -> property / plot / seasoning eligibility
        -- (Do not rely on CERSAI date for eligibility)
        -- ================================================================
        main.property_type,
        CASE WHEN UPPER(main.property_type) IN ('RESIDENTIAL', 'COMMERCIAL') THEN 1 ELSE 0 END AS property_type_eligibility_status_v2,
        main.property_subtype,
        main.property_ownership_mode,
        main.property_state,
        main.property_market_value,
        main.residential_property_cnt,
        main.industrial_property_cnt,
        CASE WHEN NVL(main.industrial_property_cnt, 0) > 0 THEN 0 ELSE 1 END AS industrial_property_eligibility_status,
        main.asset_plot_count,
        CASE WHEN NVL(main.asset_plot_count, 0) > 0 THEN 0 ELSE 1 END AS asset_plot_eligibility_status,
        main.is_under_construction,
        main.construction_completion_de,
        main.stage_of_construction_techval,
        main.overall_completion_de,
        main.sz_cersai_sec_int_id,
        main.dt_cersai,
        main.months_btw_cersai_last_month,

        -- ================================================================
        -- SECTION 14: LOCATION
        -- ================================================================
        main.state_code,
        main.branch,
        main.city_code                   AS city,
        main.sz_postal_code              AS pin_code,
        main.current_address,

        -- ================================================================
        -- SECTION 15: BOUNCE - LAST 6 MONTHS -> bounce eligibility (6M)
        -- Keep only same-day bounce as used in final_eligibility_status.
        -- ================================================================
        main.no_of_bounce_last_6_month_same_day,
        CASE WHEN main.no_of_bounce_last_6_month_same_day = 0 THEN 1 ELSE 0 END AS bounce_last_six_months_same_day_eligibility_status,

        -- ================================================================
        -- SECTION 16: BOUNCE - MONTHS 7-12 -> bounce eligibility (7-12M)
        -- Keep only same-day bounce as used in final_eligibility_status.
        -- ================================================================
        main.no_of_bounce_last_last_7_12_month_same_day,
        CASE WHEN main.no_of_bounce_last_last_7_12_month_same_day <= 1 THEN 1 ELSE 0 END AS bounce_last_seven_twelve_months_same_day_eligibility_status,

        -- ================================================================
        -- SECTION 17: REPAYMENT MODE  →  repayment_mode_eligibility_status
        -- ================================================================
        main.sz_repayment_mode,
        CASE WHEN main.sz_repayment_mode = 'NACH' THEN 1 ELSE 0 END AS repayment_mode_eligibility_status,

        -- ================================================================
        -- SECTION 18: FUNDER / ASSIGNMENT / NHB / NABARD / REFINANCE
        --              →  funder_flag / direct_assignment_flag / nhb_flag
        --              →  nabard_flag / refinance_scheme_flag
        -- ================================================================
        main.sz_funder_status,
        main.sz_funder_name,
        main.sz_funder_agree_no,
        main.dt_funderdisb,
        main.dt_funder_tagging,
        CASE
            WHEN NULLIF(TRIM(NVL(main.sz_funder_status,    '')), '') IS NOT NULL THEN 0
            WHEN NULLIF(TRIM(NVL(main.sz_funder_name,      '')), '') IS NOT NULL THEN 0
            WHEN NULLIF(TRIM(NVL(main.sz_funder_agree_no,  '')), '') IS NOT NULL THEN 0
            WHEN main.dt_funderdisb    IS NOT NULL THEN 0
            WHEN main.dt_funder_tagging IS NOT NULL THEN 0
            ELSE 1
        END AS funder_flag,
        main.direct_assignment,
        CASE WHEN main.direct_assignment IS NOT NULL THEN 0 ELSE 1 END AS direct_assignment_flag,
        main.nhb,
        main.scheme,
        CASE WHEN UPPER(main.nhb) LIKE '%NHB%' OR UPPER(main.scheme) LIKE '%NHB%' THEN 0 ELSE 1 END AS nhb_flag,
        main.sz_nabard_name,
        CASE WHEN main.sz_nabard_name IS NULL THEN 1 ELSE 0 END AS nabard_flag,
        main.refinance_scheme,
        CASE WHEN main.refinance_scheme IS NULL THEN 1 ELSE 0 END AS refinance_scheme_flag,

        -- ================================================================
        -- SECTION 19: RESTRUCTURE  →  c_cov_restructure_eligibility_status
        -- ================================================================
        main.c_cov_restructure           AS restructure_flag,
        CASE WHEN main.c_cov_restructure = 'Y' THEN 0 ELSE 1 END AS c_cov_restructure_eligibility_status,

        -- ================================================================
        -- SECTION 20: PDD  →  pdd_eligibility_status
        -- ================================================================
        CASE WHEN pdd.sz_application_no IS NOT NULL THEN 0 ELSE 1 END AS pdd_eligibility_status
    FROM main
    LEFT JOIN pdd ON main.sz_application_no = pdd.sz_application_no
    WHERE (
            UPPER(NVL(main.sz_product_desc, '')) LIKE '%MSME%'
            OR UPPER(NVL(main.sz_product_desc, '')) LIKE '%SME%'
        )
        AND UPPER(NVL(main.sz_product_desc, '')) NOT LIKE '%MICROLAP%'
        AND UPPER(NVL(main.sz_product_desc, '')) NOT LIKE '%MICRO LAP%'
        AND UPPER(TRIM(NVL(main.sz_appl_category_code, ''))) = 'I'
        AND UPPER(NVL(main.loan_status, '')) = 'APPROVED'
        AND NOT (
            UPPER(NVL(main.sz_portfolio_desc, '')) LIKE '%EQUITY%'
            OR UPPER(NVL(main.portfolio_description, '')) LIKE '%EQUITY%'
            OR UPPER(NVL(main.sz_product_desc, '')) LIKE '%MICROLAP%'
            OR UPPER(NVL(main.sz_product_desc, '')) LIKE '%MICRO LAP%'
            OR UPPER(NVL(main.sz_product_desc, '')) IN (
                'PRE-APPROVED LOAN',
                'SAATHI PREAPPROVED TOPUP',
                'EMERGENCY CREDIT LINE GUARANTEE SCHEME',
                'EMERGENCY CREDIT LINE GUARANTEE SCHEME 2',
                'RETAILS CONSTRUCTION FINANCE',
                'HE – ASSIGNMENT',
                'RCF FUNDING',
                'SAMRIDDHI LOANS'
            )
        )
) subquery
ORDER BY sz_loan_account_no;