-- ============================================================
-- DA POOL SANCTION FORMAT – Bulk Extract (ABFL-Eligible HE/LAP @ CIBIL 675)
-- Sheet: "Required for pool shortlisting"  |  132 columns
-- Universe: DA_HE_AB table (abfl_overall_eligibility_at_675 = 1)
--           All eligibility criteria pre-computed in EXTERNAL_CURATED.DA_HE_AB
-- POS / Overdue / Rate: CURRENT_DATE live snapshot from loan_dtl_cghfl
-- DPD history / Bounce strings: loan_status_monthly + CBR tables
-- NO {LAN_LIST} placeholder – universe is embedded as a subquery
-- Generated: 2026-05-06
-- ============================================================

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 0: Universe — pull directly from DA_HE_AB where abfl_overall_eligibility_at_675 = 1
-- All 18 ABFL criteria (LTV<=70, property type, seasoning>=180d, age, bounces, etc.)
-- are pre-evaluated in EXTERNAL_CURATED.DA_HE_AB. No recomputation needed here.
-- ─────────────────────────────────────────────────────────────────────────────
target_lans AS (
    SELECT sz_loan_account_no, sz_application_no
    FROM "prod_analytics_db"."EXTERNAL_CURATED"."DA_HE_AB"
    WHERE abfl_overall_eligibility_at_675 = 1
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 1: Loan + Application  (one row per LAN)
-- All financial columns (POS, overdue, rate) from loan_dtl = CURRENT_DATE live
-- ─────────────────────────────────────────────────────────────────────────────
loan_app AS (
    SELECT
        ld.sz_loan_account_no,
        ld.sz_application_no,
        ld.sz_customer_no,
        ld.f_sanctioned_amt,
        ld.i_tenor,
        ld."balance tenure",
        ld."current total tenure",
        ld.c_interest_rate_type,
        ld.f_curr_interestrate,
        ld."principal outstanding",
        ld."overdue principal",
        ld."cumulative amount disbursed",
        ld.c_final_disb_yn,
        ld.installment_start_date,
        ld."first disbursement date",
        ld."latest disbursement date",
        ld.sz_delinquency_str,
        ld.i_cur_dpd,
        ld.c_psl,
        ld.c_staff_loan_yn,
        ld."pmay - clss",
        ld.c_restructure_yn,
        ld.npa_flag,
        ld.sz_risk_grade                                        AS ld_risk_grade,
        ld.sz_repayment_mode,
        ld.f_ltv_per,
        ld.f_adv_amt,
        ld.installment_amount,
        app.branch,
        app.region,
        app.end_use_loan_description,
        app.sanction_date,
        app.sanction_amount,
        app.foir_wo_insurance,
        app.total_eligible_income,
        app.ltv_wo_insurance,
        app.cibil_score                                         AS app_cibil_score,
        app.sz_risk_grade                                       AS app_risk_grade,
        app.loan_purpose_description,
        disb_c.constitution
    FROM analytics_reporting.loan_dtl_cghfl ld
    JOIN analytics_reporting.application_cghfl app
        ON app.sz_application_no = ld.sz_application_no
    JOIN target_lans tl
        ON tl.sz_loan_account_no = ld.sz_loan_account_no
    LEFT JOIN (
        SELECT sz_loan_account_no, constitution
        FROM (
            SELECT sz_loan_account_no, constitution,
                   ROW_NUMBER() OVER (PARTITION BY sz_loan_account_no ORDER BY i_tranch_srno) AS rk
            FROM analytics_reporting.disbursement_cghfl_v2
            WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
        ) t WHERE rk = 1
    ) disb_c ON disb_c.sz_loan_account_no = ld.sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 2: Applicants ranked (Borrower first, then co-borrowers by i_applicant_id)
-- ─────────────────────────────────────────────────────────────────────────────
appl_ranked AS (
    SELECT
        apt.sz_application_no,
        apt.i_applicant_id,
        apt.sz_appl_type_code,
        apt.sz_relation_to_main_applicant,
        NVL(apt.person_name, apt.sz_org_name)                  AS cust_name,
        CASE
            WHEN apt.person_name IS NOT NULL THEN 'Individual'
            WHEN apt.sz_org_name  IS NOT NULL THEN 'Non-Individual'
            ELSE NULL
        END                                                     AS cust_type,
        -- Customer sub-type from sz_appl_category_code (better coverage than sz_salary_typ)
        apt.sz_appl_category_code                               AS cust_subtype,
        -- SENP/SEP classification via income_program (most populated field)
        CASE
            WHEN LOWER(apt.income_program) LIKE '%salar%'             THEN 'SALARIED'
            WHEN LOWER(apt.income_program) LIKE '%senp%'
              OR LOWER(apt.income_program) LIKE '%sep%'
              OR apt.income_program IN ('Self Employed - NIP-CPM', 'Self Employed - NIP')
                                                                      THEN 'SENP'
            WHEN UPPER(TRIM(apt.sz_salary_typ)) IN ('SENP','SEP')     THEN 'SENP'
            WHEN apt.income_program IS NOT NULL THEN UPPER(apt.income_program)
            ELSE NULL
        END                                                     AS senp_sep_type,
        -- Occupation: sz_primary_occupation is most populated; industry types as fallback
        COALESCE(
            NULLIF(TRIM(apt.sz_primary_occupation), ''),
            NULLIF(TRIM(apt.ind_sz_industry_type), ''),
            NULLIF(TRIM(apt.org_sz_industry_type), '')
        )                                                       AS occupation,
        -- Income assessment method
        apt.income_type                                         AS income_type,
        -- Constitution: derived from org constitution code → full name,
        -- or from income_program/salary_typ for individual borrowers
        CASE
            -- Non-individual: map org constitution codes to readable names
            WHEN apt.sz_org_constitution IS NOT NULL
            THEN CASE
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) IN ('SPR','PROP','SOLE PROP','SOLE PROPRIETOR','SOLE PROPRIETORSHIP')
                          OR LOWER(apt.sz_org_constitution) LIKE '%sole prop%'     THEN 'Sole Proprietor'
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) IN ('P','PAR','PART','PARTNERSHIP')
                          OR LOWER(apt.sz_org_constitution) LIKE '%partner%'       THEN 'Partnership'
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) IN ('PVT','PVT LTD','PRIVATE LIMITED','PRIVATE LTD')
                          OR LOWER(apt.sz_org_constitution) LIKE '%private limit%' THEN 'Private Limited'
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) IN ('PLC','PUBLIC LIMITED','PUBLIC LTD')
                          OR LOWER(apt.sz_org_constitution) LIKE '%public limit%'  THEN 'Public Limited'
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) = 'LLP'
                          OR LOWER(apt.sz_org_constitution) LIKE '%llp%'           THEN 'LLP'
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) = 'HUF'            THEN 'HUF'
                     WHEN UPPER(TRIM(apt.sz_org_constitution)) IN ('TRUST','NGO')  THEN UPPER(TRIM(apt.sz_org_constitution))
                     WHEN LOWER(apt.sz_org_constitution) LIKE '%societ%'          THEN 'Society'
                     WHEN LOWER(apt.sz_org_constitution) LIKE '%co-op%'
                          OR LOWER(apt.sz_org_constitution) LIKE '%coop%'          THEN 'Co-operative Society'
                     ELSE INITCAP(apt.sz_org_constitution)
                 END
            -- Individual salaried
            WHEN LOWER(apt.income_program) LIKE '%salar%'
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SAL'
            THEN 'Salaried'
            -- Individual self-employed (SENP/SEP = Sole Proprietor)
            WHEN LOWER(apt.income_program) LIKE '%senp%'
              OR LOWER(apt.income_program) LIKE '%sep%'
              OR apt.income_program IN ('Self Employed - NIP-CPM', 'Self Employed - NIP')
              OR UPPER(TRIM(apt.sz_salary_typ)) IN ('SENP', 'SEP')
            THEN 'Sole Proprietor'
            -- Fallback for other individuals
            WHEN apt.person_name IS NOT NULL
            THEN 'Individual'
            WHEN apt.sz_org_name IS NOT NULL
            THEN 'Non-Individual'
            ELSE NULL
        END                                                     AS constitution,
        apt.c_gender,
        apt.dt_birth_date,
        NULLIF(TRIM(NVL(apt.sz_id2, apt.sz_panno)), '')        AS pan,
        apt.sz_cibil_score,
        apt.c_incm_consid,
        ROW_NUMBER() OVER (
            PARTITION BY apt.sz_application_no
            ORDER BY
                CASE WHEN apt.sz_appl_type_code = 'BORROWER' THEN 0 ELSE 1 END,
                apt.i_applicant_id
        )                                                       AS seq
    FROM analytics_reporting.applicant_basic_dtl_cghfl apt
    WHERE apt.sz_application_no IN (SELECT sz_application_no FROM target_lans)
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 3: Pre-pivot applicants 1–9 into columns (one row per application)
-- ─────────────────────────────────────────────────────────────────────────────
appl_pivot AS (
    SELECT
        sz_application_no,
        -- Applicant 1 (primary borrower)
        MAX(CASE WHEN seq = 1 THEN cust_name  END)             AS a1_name,
        MAX(CASE WHEN seq = 1 THEN c_gender   END)             AS a1_gender,
        MAX(CASE WHEN seq = 1 THEN cust_type  END)             AS a1_cust_type,
        MAX(CASE WHEN seq = 1 THEN c_incm_consid END)          AS a1_is_financial,
        MAX(CASE WHEN seq = 1 THEN cust_subtype END)           AS a1_subtype,
        MAX(CASE WHEN seq = 1 AND senp_sep_type IN ('SENP','SEP') THEN senp_sep_type END) AS a1_senp_sep,
        MAX(CASE WHEN seq = 1 THEN occupation END)              AS a1_occupation,
        MAX(CASE WHEN seq = 1 THEN income_type END)             AS a1_income_type,
        MAX(CASE WHEN seq = 1 THEN constitution END)            AS a1_constitution,
        MAX(CASE WHEN seq = 1 THEN dt_birth_date END)          AS a1_dob,
        MAX(CASE WHEN seq = 1 THEN pan END)                    AS a1_pan,
        MAX(CASE WHEN seq = 1 THEN sz_cibil_score END)         AS a1_cibil,
        -- Applicant 2
        MAX(CASE WHEN seq = 2 THEN cust_name  END)             AS a2_name,
        MAX(CASE WHEN seq = 2 THEN cust_type  END)             AS a2_cust_type,
        MAX(CASE WHEN seq = 2 THEN cust_subtype END)           AS a2_subtype,
        MAX(CASE WHEN seq = 2 THEN dt_birth_date END)          AS a2_dob,
        MAX(CASE WHEN seq = 2 THEN pan END)                    AS a2_pan,
        MAX(CASE WHEN seq = 2 THEN sz_relation_to_main_applicant END) AS a2_relation,
        -- Applicant 3
        MAX(CASE WHEN seq = 3 THEN cust_name  END)             AS a3_name,
        MAX(CASE WHEN seq = 3 THEN cust_type  END)             AS a3_cust_type,
        MAX(CASE WHEN seq = 3 THEN cust_subtype END)           AS a3_subtype,
        MAX(CASE WHEN seq = 3 THEN dt_birth_date END)          AS a3_dob,
        MAX(CASE WHEN seq = 3 THEN pan END)                    AS a3_pan,
        MAX(CASE WHEN seq = 3 THEN sz_relation_to_main_applicant END) AS a3_relation,
        -- Applicant 4
        MAX(CASE WHEN seq = 4 THEN cust_name  END)             AS a4_name,
        MAX(CASE WHEN seq = 4 THEN cust_type  END)             AS a4_cust_type,
        MAX(CASE WHEN seq = 4 THEN cust_subtype END)           AS a4_subtype,
        MAX(CASE WHEN seq = 4 THEN dt_birth_date END)          AS a4_dob,
        MAX(CASE WHEN seq = 4 THEN pan END)                    AS a4_pan,
        MAX(CASE WHEN seq = 4 THEN sz_relation_to_main_applicant END) AS a4_relation,
        -- Applicant 5
        MAX(CASE WHEN seq = 5 THEN cust_name  END)             AS a5_name,
        MAX(CASE WHEN seq = 5 THEN cust_type  END)             AS a5_cust_type,
        MAX(CASE WHEN seq = 5 THEN cust_subtype END)           AS a5_subtype,
        MAX(CASE WHEN seq = 5 THEN dt_birth_date END)          AS a5_dob,
        MAX(CASE WHEN seq = 5 THEN pan END)                    AS a5_pan,
        MAX(CASE WHEN seq = 5 THEN sz_relation_to_main_applicant END) AS a5_relation,
        -- Applicant 6
        MAX(CASE WHEN seq = 6 THEN cust_name  END)             AS a6_name,
        MAX(CASE WHEN seq = 6 THEN cust_type  END)             AS a6_cust_type,
        MAX(CASE WHEN seq = 6 THEN cust_subtype END)           AS a6_subtype,
        MAX(CASE WHEN seq = 6 THEN dt_birth_date END)          AS a6_dob,
        MAX(CASE WHEN seq = 6 THEN pan END)                    AS a6_pan,
        MAX(CASE WHEN seq = 6 THEN sz_relation_to_main_applicant END) AS a6_relation,
        -- Applicant 7
        MAX(CASE WHEN seq = 7 THEN cust_name  END)             AS a7_name,
        MAX(CASE WHEN seq = 7 THEN cust_type  END)             AS a7_cust_type,
        MAX(CASE WHEN seq = 7 THEN cust_subtype END)           AS a7_subtype,
        MAX(CASE WHEN seq = 7 THEN dt_birth_date END)          AS a7_dob,
        MAX(CASE WHEN seq = 7 THEN pan END)                    AS a7_pan,
        MAX(CASE WHEN seq = 7 THEN sz_relation_to_main_applicant END) AS a7_relation,
        -- Applicant 8
        MAX(CASE WHEN seq = 8 THEN cust_name  END)             AS a8_name,
        MAX(CASE WHEN seq = 8 THEN cust_type  END)             AS a8_cust_type,
        MAX(CASE WHEN seq = 8 THEN cust_subtype END)           AS a8_subtype,
        MAX(CASE WHEN seq = 8 THEN dt_birth_date END)          AS a8_dob,
        MAX(CASE WHEN seq = 8 THEN pan END)                    AS a8_pan,
        MAX(CASE WHEN seq = 8 THEN sz_relation_to_main_applicant END) AS a8_relation,
        -- Applicant 9
        MAX(CASE WHEN seq = 9 THEN cust_name  END)             AS a9_name,
        MAX(CASE WHEN seq = 9 THEN cust_type  END)             AS a9_cust_type,
        MAX(CASE WHEN seq = 9 THEN cust_subtype END)           AS a9_subtype,
        MAX(CASE WHEN seq = 9 THEN dt_birth_date END)          AS a9_dob,
        MAX(CASE WHEN seq = 9 THEN pan END)                    AS a9_pan,
        MAX(CASE WHEN seq = 9 THEN sz_relation_to_main_applicant END) AS a9_relation
    FROM appl_ranked
    GROUP BY sz_application_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 4: Primary borrower current address
-- ─────────────────────────────────────────────────────────────────────────────
borrow_addr AS (
    SELECT *
    FROM (
        SELECT
            ld.sz_loan_account_no,
            TRIM(
                COALESCE(adr.current_sz_address_1, '') || ' ' ||
                COALESCE(adr.current_sz_address_2, '') || ' ' ||
                COALESCE(adr.current_sz_address_3, '')
            )                                                   AS customer_address,
            adr.current_city,
            adr.current_state,
            adr.current_sz_postal_code,
            ROW_NUMBER() OVER (
                PARTITION BY ld.sz_loan_account_no
                ORDER BY adr.i_applicant_id
            )                                                   AS rk
        FROM analytics_reporting.applicant_address_contact_dtl_cghfl adr
        JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
            ON  apt.sz_application_no = adr.sz_application_no
            AND apt.i_applicant_id    = adr.i_applicant_id
            AND apt.sz_appl_type_code = 'BORROWER'
        JOIN analytics_reporting.loan_dtl_cghfl ld
            ON ld.sz_application_no = adr.sz_application_no
        WHERE ld.sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
    ) t WHERE rk = 1
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 5: Top collateral / asset for each application
-- ─────────────────────────────────────────────────────────────────────────────
asset_top AS (
    SELECT *
    FROM (
        SELECT
            ast.sz_application_no,
            ast.i_asset_srno,
            ast.sz_description                                  AS collateral_desc,
            ast.a_sz_prop_usage                                 AS collateral_use,
            ast.property_type,
            CASE
                WHEN UPPER(TRIM(ast.property_type)) LIKE '%PLOT%'
                  OR UPPER(TRIM(ast.sz_subtype))    LIKE '%PLOT%'
                THEN 'Y' ELSE 'N'
            END                                                 AS open_plot_flag,
            COALESCE(ast.is_under_construction, 'N')            AS is_under_construction,
            ast.a_i_tot_valuation                               AS collateral_value,
            TRIM(
                COALESCE(ast.sz_address_1, '') || ' ' ||
                COALESCE(ast.sz_address_2, '') || ' ' ||
                COALESCE(ast.sz_address_3, '')
            )                                                   AS property_address,
            ast.city                                            AS property_city,
            ast.state                                           AS property_state,
            ast.sz_postal_code                                  AS property_pincode,
            ast.property_owner_name,
            ast.sz_cersai_sec_int_id,
            ast.dt_cersai,
            ROW_NUMBER() OVER (
                PARTITION BY ast.sz_application_no
                ORDER BY ast.a_i_tot_valuation DESC NULLS LAST
            )                                                   AS rk
        FROM analytics_reporting.asset_cghfl ast
        WHERE ast.sz_application_no IN (SELECT sz_application_no FROM target_lans)
    ) t WHERE rk = 1
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 6: Latest loan_status_monthly snapshot  (one row per LAN)
-- Used ONLY for i_no_of_overdue_emi (overdue instalment count).
-- POS / overdue amounts come from loan_dtl (live).
-- ─────────────────────────────────────────────────────────────────────────────
lsm_latest AS (
    SELECT *
    FROM (
        SELECT
            sz_loan_account_no,
            total_principal_outstanding,
            f_overdue_principal,
            i_no_of_overdue_emi,
            i_dpd                                               AS lsm_dpd,
            ROW_NUMBER() OVER (
                PARTITION BY sz_loan_account_no
                ORDER BY dt_businessdate DESC
            )                                                   AS rk
        FROM analytics_reporting.loan_status_monthly_cghfl
        WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
    ) t WHERE rk = 1
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 7: DPD string – last 12 months
-- ─────────────────────────────────────────────────────────────────────────────
dpd_last12 AS (
    SELECT
        sz_loan_account_no,
        LISTAGG(
            LPAD(CAST(COALESCE(i_dpd, 0) AS VARCHAR), 3, '0'),
            '-'
        ) WITHIN GROUP (ORDER BY dt_businessdate DESC)         AS dpd_str_12m
    FROM (
        SELECT
            sz_loan_account_no,
            dt_businessdate,
            i_dpd,
            ROW_NUMBER() OVER (
                PARTITION BY sz_loan_account_no
                ORDER BY dt_businessdate DESC
            )                                                   AS rk
        FROM analytics_reporting.loan_status_monthly_cghfl
        WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
          AND dt_businessdate >= ADD_MONTHS(CURRENT_DATE, -12)
    ) t
    WHERE rk <= 12
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 7b: DPD string – since inception (all months; oldest first)
-- Inactive loans (not APPROVED) show their loan_status instead of DPD string
-- ─────────────────────────────────────────────────────────────────────────────
dpd_inception AS (
    SELECT
        sz_loan_account_no,
        LISTAGG(
            LPAD(CAST(COALESCE(i_dpd, 0) AS VARCHAR), 3, '0'),
            '-'
        ) WITHIN GROUP (ORDER BY dt_businessdate)               AS dpd_str_inception,
        MAX(UPPER(loan_status))                                  AS last_loan_status
    FROM analytics_reporting.loan_status_monthly_cghfl
    WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 8: Max ever DPD
-- ─────────────────────────────────────────────────────────────────────────────
dpd_max AS (
    SELECT
        sz_loan_account_no,
        MAX(COALESCE(i_dpd, 0))                                AS max_ever_dpd
    FROM analytics_reporting.loan_status_monthly_cghfl
    WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 8b: Max ever DPD from lms_provision_dtls_cghfl (daily provision records)
-- Conservative cross-check: provision goes back to 2018, LSM may have gaps.
-- ─────────────────────────────────────────────────────────────────────────────
prov_max_dpd AS (
    SELECT
        sz_loan_account_no,
        MAX(COALESCE(i_dpd, 0))                                AS max_ever_dpd_prov
    FROM analytics_reporting.lms_provision_dtls_cghfl
    WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 9: Pre-EMI / advance instalment info
-- ─────────────────────────────────────────────────────────────────────────────
advance_info AS (
    SELECT
        sz_loan_account_no,
        SUM(COALESCE(pre_emi_amt, 0))                          AS total_advance_amt,
        COUNT(CASE WHEN COALESCE(pre_emi_amt, 0) > 0 THEN 1 END) AS no_advance_installments
    FROM analytics_reporting.disbursement_cghfl_v2
    WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 10: Next EMI due date
-- ─────────────────────────────────────────────────────────────────────────────
next_due AS (
    SELECT
        sz_loan_account_no,
        MIN(dt_installmentdue)                                 AS next_emi_due_date
    FROM analytics_reporting.repayment_schedule_cghfl
    WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
      AND dt_installmentdue >= CURRENT_DATE
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 11: Bounce string – last 12 months (from CBR table)
-- ─────────────────────────────────────────────────────────────────────────────
bounce_last12 AS (
    SELECT
        sz_loan_account_no,
        LISTAGG(
            CASE WHEN bounce_status_3_day = 'BOUNCE' THEN 'B' ELSE 'C' END,
            '-'
        ) WITHIN GROUP (ORDER BY dt_installmentdue DESC)       AS bounce_str_12m
    FROM (
        SELECT
            sz_loan_account_no,
            dt_installmentdue,
            bounce_status_3_day,
            ROW_NUMBER() OVER (
                PARTITION BY sz_loan_account_no
                ORDER BY dt_installmentdue DESC
            )                                                  AS rk
        FROM external_curated.nb_cbr_cghfl_final_new
        WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
          AND dt_installmentdue >= ADD_MONTHS(CURRENT_DATE, -12)
          AND i_installment_no IS NOT NULL
    ) t
    WHERE rk <= 12
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 12: Bounce string – since inception
-- ─────────────────────────────────────────────────────────────────────────────
bounce_inception AS (
    SELECT
        sz_loan_account_no,
        LISTAGG(
            CASE WHEN bounce_status_3_day = 'BOUNCE' THEN 'B' ELSE 'C' END,
            '-'
        ) WITHIN GROUP (ORDER BY dt_installmentdue DESC)       AS bounce_str_all
    FROM external_curated.nb_cbr_cghfl_final_new
    WHERE sz_loan_account_no IN (SELECT sz_loan_account_no FROM target_lans)
      AND i_installment_no IS NOT NULL
    GROUP BY sz_loan_account_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 13: PDD status
-- ─────────────────────────────────────────────────────────────────────────────
pdd_status AS (
    SELECT
        loan_acc_no                                            AS sz_loan_account_no,
        CASE
            WHEN SUM(CASE
                    WHEN UPPER(otc_pdd) = 'PDD'
                     AND UPPER(TRIM(critical)) ILIKE '%critical%'
                     AND UPPER(TRIM(doc_receivd_flag)) != 'YES'
                    THEN 1 ELSE 0
                 END) = 0
            THEN 'Y'
            ELSE 'N'
        END                                                    AS pdd_complete,
        LISTAGG(
            CASE
                WHEN UPPER(otc_pdd) = 'PDD'
                 AND UPPER(TRIM(critical)) ILIKE '%critical%'
                 AND UPPER(TRIM(doc_receivd_flag)) != 'YES'
                THEN COALESCE(NULLIF(TRIM(document_name),''), NULLIF(TRIM(document_desc),''), 'Unknown Doc')
                ELSE NULL
            END,
            '; '
        ) WITHIN GROUP (ORDER BY document_name)               AS pdd_pending_docs
    FROM analytics_reporting.otc_pdd_table_cghfl
    WHERE loan_acc_no IN (SELECT sz_loan_account_no FROM target_lans)
      AND is_deleted IS DISTINCT FROM TRUE
    GROUP BY loan_acc_no
)

-- ─────────────────────────────────────────────────────────────────────────────
-- MAIN SELECT  –  132 columns in template order
-- POS / Overdue / Rate: CURRENT_DATE live from loan_dtl_cghfl
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    -- Col 1
    ROW_NUMBER() OVER (ORDER BY la.sz_loan_account_no)         AS "Sl. No.",

    -- Col 2
    la.sz_loan_account_no                                      AS "Loan No.",

    -- Col 3
    la.sz_customer_no                                          AS "Unique Cutomer ID No. ",

    -- Col 4
    la.branch                                                  AS "Branch Name/State",

    -- Col 5
    la.region                                                  AS "State",

    -- ── Primary Applicant (Cols 6-19) ─────────────────────────────────────

    -- Col 6
    ap.a1_name                                                 AS "Customer Name (Primary Applicant)",

    -- Col 7
    ap.a1_gender                                               AS "Gender for Primary Applicant",

    -- Col 8
    ap.a1_cust_type                                            AS "Customer Type (Primary Applicant)",

    -- Col 9
    ap.a1_is_financial                                         AS "is primary applicant a financial applicant",

    -- Col 10
    ap.a1_subtype                                              AS "Customer Sub-type (Primary Applicant)",

    -- Col 11  (SENP or SEP when self-employed; NULL for salaried)
    ap.a1_senp_sep                                             AS "In case of self employed (SENP/ SEP)",

    -- Col 12
    ap.a1_occupation                                           AS "Occupation/Industry",

    -- Col 13 (sz_org_constitution from applicant_basic_dtl_cghfl for non-individual borrowers)
    ap.a1_constitution                                         AS "Constitution",

    -- Col 14
    ap.a1_dob                                                  AS "DOB/DOI \n(Primary Applicant)",

    -- Col 15
    ba.customer_address                                        AS "Customer Address",

    -- Col 16
    ba.current_city                                            AS "City",

    -- Col 17
    ba.current_state                                           AS "State.1",

    -- Col 18  (current_sz_postal_code from applicant_address_contact_dtl_cghfl)
    ba.current_sz_postal_code                                  AS "Zip code",

    -- Col 19
    ap.a1_pan                                                  AS "Pan Number",

    -- ── Applicant 2 (Cols 20-25) ──────────────────────────────────────────

    -- Col 20
    ap.a2_name                                                 AS "Customer Name (Applicant  2)",

    -- Col 21
    ap.a2_cust_type                                            AS "Customer Type (Applicant 2)",

    -- Col 22
    ap.a2_subtype                                              AS "Customer Sub-type (Applicant 2)",

    -- Col 23
    ap.a2_dob                                                  AS "DOB/DOI (Applicant 2)",

    -- Col 24
    ap.a2_pan                                                  AS "PAN Number",

    -- Col 25
    ap.a2_relation                                             AS "Relation with Primary Applicant",

    -- ── Applicant 3 (Cols 26-31) ──────────────────────────────────────────

    -- Col 26
    ap.a3_name                                                 AS "Customer Name (Applicant  3)",

    -- Col 27
    ap.a3_cust_type                                            AS "Customer Type (Applicant 3)",

    -- Col 28
    ap.a3_subtype                                              AS "Customer Sub-type (Applicant 3)",

    -- Col 29
    ap.a3_dob                                                  AS "DOB/DOI (Applicant 3)",

    -- Col 30
    ap.a3_pan                                                  AS "PAN Number.1",

    -- Col 31
    ap.a3_relation                                             AS "Relation with Primary Applicant.1",

    -- ── Applicant 4 (Cols 32-37) ──────────────────────────────────────────

    -- Col 32
    ap.a4_name                                                 AS "Customer Name (Applicant  4)",

    -- Col 33
    ap.a4_cust_type                                            AS "Customer Type (Applicant 4)",

    -- Col 34
    ap.a4_subtype                                              AS "Customer Sub-type (Applicant 4)",

    -- Col 35
    ap.a4_dob                                                  AS "DOB/DOI (Applicant 4)",

    -- Col 36
    ap.a4_pan                                                  AS "PAN Number.2",

    -- Col 37
    ap.a4_relation                                             AS "Relation with Primary Applicant.2",

    -- ── Applicant 5 (Cols 38-43) ──────────────────────────────────────────

    -- Col 38
    ap.a5_name                                                 AS "Customer Name (Applicant  5)",

    -- Col 39
    ap.a5_cust_type                                            AS "Customer Type (Applicant 5)",

    -- Col 40
    ap.a5_subtype                                              AS "Customer Sub-type (Applicant 5)",

    -- Col 41
    ap.a5_dob                                                  AS "DOB/DOI (Applicant 5)",

    -- Col 42
    ap.a5_pan                                                  AS "PAN Number.3",

    -- Col 43
    ap.a5_relation                                             AS "Relation with Primary Applicant.3",

    -- ── Applicant 6 (Cols 44-49) ──────────────────────────────────────────

    -- Col 44
    ap.a6_name                                                 AS "Customer Name (Applicant  6)",

    -- Col 45
    ap.a6_cust_type                                            AS "Customer Type (Applicant 6)",

    -- Col 46
    ap.a6_subtype                                              AS "Customer Sub-type (Applicant 6)",

    -- Col 47
    ap.a6_dob                                                  AS "DOB/DOI (Applicant 6)",

    -- Col 48
    ap.a6_pan                                                  AS "PAN Number.4",

    -- Col 49
    ap.a6_relation                                             AS "Relation with Primary Applicant.4",

    -- ── Applicant 7 (Cols 50-55) ──────────────────────────────────────────

    -- Col 50
    ap.a7_name                                                 AS "Customer Name (Applicant  7)",

    -- Col 51
    ap.a7_cust_type                                            AS "Customer Type (Applicant 7)",

    -- Col 52
    ap.a7_subtype                                              AS "Customer Sub-type (Applicant 7)",

    -- Col 53
    ap.a7_dob                                                  AS "DOB/DOI (Applicant 7)",

    -- Col 54
    ap.a7_pan                                                  AS "PAN Number.5",

    -- Col 55
    ap.a7_relation                                             AS "Relation with Primary Applicant.5",

    -- ── Applicant 8 (Cols 56-61) ──────────────────────────────────────────

    -- Col 56
    ap.a8_name                                                 AS "Customer Name (Applicant  8)",

    -- Col 57
    ap.a8_cust_type                                            AS "Customer Type (Applicant 8)",

    -- Col 58
    ap.a8_subtype                                              AS "Customer Sub-type (Applicant 8)",

    -- Col 59
    ap.a8_dob                                                  AS "DOB/DOI (Applicant 8)",

    -- Col 60
    ap.a8_pan                                                  AS "PAN Number.6",

    -- Col 61
    ap.a8_relation                                             AS "Relation with Primary Applicant.6",

    -- ── Applicant 9 (Cols 62-67) ──────────────────────────────────────────

    -- Col 62
    ap.a9_name                                                 AS "Customer Name (Applicant  9)",

    -- Col 63
    ap.a9_cust_type                                            AS "Customer Type (Applicant 9)",

    -- Col 64
    ap.a9_subtype                                              AS "Customer Sub-type (Applicant 9)",

    -- Col 65
    ap.a9_dob                                                  AS "DOB/DOI (Applicant 9)",

    -- Col 66
    ap.a9_pan                                                  AS "PAN Number.7",

    -- Col 67
    ap.a9_relation                                             AS "Relation with Primary Applicant.7",

    -- ── Risk & Classification (Cols 68-70) ───────────────────────────────

    -- Col 68
    COALESCE(la.ld_risk_grade, la.app_risk_grade)              AS "Risk Categorization",

    -- Col 69
    la.end_use_loan_description                                AS "End use as per end use letter /Sanction letter",

    -- Col 70
    ap.a1_income_type                                          AS "Income Assesment method - Income /Surrogate/Assessed",

    -- ── Key Dates (Cols 71-75) ────────────────────────────────────────────

    -- Col 71
    la.sanction_date                                           AS "Sanctioned date",

    -- Col 72
    la."first disbursement date"                               AS "Agreement date/First Disbursement Date",

    -- Col 73
    la."latest disbursement date"                              AS "Last Disbursement Date",

    -- Col 74
    CASE WHEN UPPER(la.c_final_disb_yn) = 'Y' THEN 'Yes' ELSE 'No' END
                                                               AS "fully disbursed Yes/No",

    -- Col 75
    la.installment_start_date                                  AS "First instalment date",

    -- ── Loan Amounts & Tenure (Cols 76-79) ───────────────────────────────

    -- Col 76
    COALESCE(la.sanction_amount, la.f_sanctioned_amt)          AS "Sanctioned Amount - as of now Sanction+Ins Provided",

    -- Col 77
    la."cumulative amount disbursed"                           AS "disbursed amount",

    -- Col 78
    la.i_tenor                                                 AS "Sanctioned Tenure (Months)",

    -- Col 79  ← CURRENT_DATE live from loan_dtl
    la."balance tenure"                                        AS "Balance Tenure (Months)",

    -- ── Rate & Outstanding (Cols 80-84) ──────────────────────────────────

    -- Col 80
    la.c_interest_rate_type                                    AS "Rate Type",

    -- Col 81  ← CURRENT_DATE live rate from loan_dtl
    la.f_curr_interestrate                                     AS "Current ROI",

    -- Col 82  ← CURRENT_DATE live POS from loan_dtl
    la."principal outstanding"                                 AS "Principal O/s",

    -- Col 83  ← live overdue principal from loan_dtl (fallback to monthly snapshot)
    COALESCE(la."overdue principal", lsm.f_overdue_principal)  AS "Overdue Amt - Principal",

    -- Col 84  (overdue instalment count; latest monthly snapshot)
    lsm.i_no_of_overdue_emi                                    AS "Overdue Installments",

    -- ── Advance / EMI (Cols 85-89) ────────────────────────────────────────

    -- Col 85
    COALESCE(adv.total_advance_amt, la.f_adv_amt)              AS "Advance Amt (if any)",

    -- Col 86
    adv.no_advance_installments                                AS "Advance Installments (if any)",

    -- Col 87
    'Monthly'                                                  AS "EMI Frequency",

    -- Col 88
    nd.next_emi_due_date                                       AS "EMI due date",

    -- Col 89  ← CURRENT_DATE live EMI from loan_dtl
    TRY_CAST(la.installment_amount AS DECIMAL(18, 2))          AS "Current EMI ",

    -- ── Asset / Collateral (Cols 90-103) ─────────────────────────────────

    -- Col 90
    ast.i_asset_srno                                           AS "asset id/ Property ID",

    -- Col 91  (live POS / collateral value)
    CASE
        WHEN COALESCE(ast.collateral_value, 0) > 0
        THEN ROUND(
            la."principal outstanding" / NULLIF(ast.collateral_value, 0) * 100,
            2)
        ELSE NULL
    END                                                        AS "Current LTV at asset level",

    -- Col 92  (ltv_wo_insurance from application_cghfl — direct, no fallback)
    TRY_CAST(la.ltv_wo_insurance AS DECIMAL(10,2))             AS "LTV (%) at collateral level at the time of original sanction ",

    -- Col 93
    ast.collateral_desc                                        AS "Collateral Description",

    -- Col 94
    ast.property_type                                          AS "Property type ",

    -- Col 95
    ast.collateral_use                                         AS "Collateral use",

    -- Col 96
    ast.is_under_construction                                  AS "Under construction flag (Y/N)",

    -- Col 97
    ast.open_plot_flag                                         AS "Open Plot (Y/N)",

    -- Col 98
    ast.collateral_value                                       AS "Collateral  value",

    -- Col 99
    ast.collateral_value                                       AS "Valuation amount",

    -- Col 100
    ast.property_address                                       AS "Address of the Property",

    -- Col 101
    ast.property_city                                          AS "Property City",

    -- Col 102
    ast.property_state                                         AS "Property State",

    -- Col 103
    ast.property_pincode                                       AS "Pincode of property location",

    -- Col 104
    ast.property_owner_name                                    AS "Name of registed property owner",

    -- ── Repayment & Bureau (Cols 105-107) ────────────────────────────────

    -- Col 105
    la.sz_repayment_mode                                       AS "Repayment mode",

    -- Col 106
    la.app_cibil_score                                         AS "Originated cibil score( for all apllicants)",

    -- Col 107
    COALESCE(ap.a1_cibil, la.app_cibil_score)                 AS "Current CIBIL score( for all applicants)",

    -- ── PDD (Cols 108-109) ───────────────────────────────────────────────

    -- Col 108
    COALESCE(pdd.pdd_complete, 'Y')                            AS "PDD status complete (Y/N)",

    -- Col 109
    NULLIF(pdd.pdd_pending_docs, '')                           AS "PDD status, if pending (Mention any critical docs)",

    -- ── Scheme & Social Flags (Cols 110-118) ─────────────────────────────

    -- Col 110  [no source in DB]
    NULL                                                       AS "Subvention Scheme if any",

    -- Col 111
    'N'                                                        AS "PMAY Flag (Y/N) - All are HE cases thus marked as No",

    -- Col 112  [flag only in loan_dtl, subsidy claim/receipt status not available]
    NULL                                                       AS "PMAY subsidy status \n(Claimed & received/ Claimed but not received)",

    -- Col 113
    CASE WHEN UPPER(COALESCE(la.c_staff_loan_yn, 'N')) = 'Y' THEN 'Yes' ELSE 'No' END
                                                               AS "Staff Loan (Yes/No)",

    -- Col 114  [NRI flag not in DB]
    NULL                                                       AS "NRI Loan (Yes/No)",

    -- Col 115 (standardised to Y/N)
    CASE
        WHEN UPPER(COALESCE(la.c_restructure_yn, 'N')) = 'Y' THEN 'Y'
        ELSE 'N'
    END                                                        AS "Restructured Flag (including OTR 1/OTR 2)",

    -- Col 116  [not applicable / not in DB]
    NULL                                                       AS "ECLGS",

    -- Col 117  [not tracked in analytics tables]
    NULL                                                       AS "Link loan Part of pool (Yes/ No)",

    -- Col 118  [not tracked in analytics tables]
    NULL                                                       AS "Link Loan/Top up loan Number if applicable",

    -- ── NPA & PSL (Cols 119-120) ─────────────────────────────────────────

    -- Col 119
    CASE WHEN UPPER(COALESCE(la.npa_flag, 'N')) = 'Y' THEN 'Y' ELSE 'N' END
                                                               AS "Loan became NPA since origination (Y/N)",

    -- Col 120
    la.c_psl                                                   AS "PSL/NPSL flag",

    -- ── DPD Strings (Cols 121-126) ────────────────────────────────────────

    -- Col 121
    dpd12.dpd_str_12m                                          AS "DPD string - Last 12 months (At customer level)",

    -- Col 122
    -- LISTAGG of all monthly DPD from inception; inactive loans show status
    CASE
        WHEN UPPER(COALESCE(dinc.last_loan_status, '')) NOT IN ('APPROVED', 'LIVE', 'ACTIVE', '')
        THEN REPLACE(UPPER(dinc.last_loan_status), ' - ', '-')
        ELSE COALESCE(dinc.dpd_str_inception, 'NO_DATA')
    END                                                        AS "DPD string (Since Inception)",

    -- Col 123
    bl12.bounce_str_12m                                        AS "bounce dpd string for last 12 month (no of days uptil bounce is cleared)",

    -- Col 124
    binc.bounce_str_all                                        AS "Gross Bounce String (Since Inception)",

    -- Col 125
    bl12.bounce_str_12m                                        AS "bounce string since last 12 month",

    -- Col 126  (GREATEST of LSM and Provision — conservative, covers LSM history gaps)
    GREATEST(
        COALESCE(dmax.max_ever_dpd, 0),
        COALESCE(pmax.max_ever_dpd_prov, 0)
    )                                                          AS "Max Ever DPD at customer level",

    -- ── Financials (Cols 127-129) ─────────────────────────────────────────

    -- Col 127
    DATEDIFF(YEAR, ap.a1_dob, CURRENT_DATE)                   AS "financial applicant age",

    -- Col 128  (stored as percentage 0-100; divide by 100 → decimal 0-1)
    -- foir_wo_insurance stored as percentage e.g. 45.3 → output as-is in %
    ROUND(TRY_CAST(la.foir_wo_insurance AS DECIMAL(10, 2)), 2)  AS "FOIR",

    -- Col 129  (monthly income × 12 = annual)
    TRY_CAST(la.total_eligible_income AS DECIMAL(18, 2)) * 12  AS "Annual Income",

    -- ── Legal & CERSAI (Cols 130-132) ─────────────────────────────────────

    -- Col 130  [legal report completeness not in analytics tables]
    NULL                                                       AS "Legal Report ",

    -- Col 131
    ast.sz_cersai_sec_int_id                                   AS "CERSAI ID",

    -- Col 132
    ast.dt_cersai                                              AS "CERSAI Registration date"

FROM loan_app la
LEFT JOIN appl_pivot    ap   ON ap.sz_application_no  = la.sz_application_no
LEFT JOIN borrow_addr   ba   ON ba.sz_loan_account_no  = la.sz_loan_account_no
LEFT JOIN asset_top     ast  ON ast.sz_application_no  = la.sz_application_no
LEFT JOIN lsm_latest    lsm  ON lsm.sz_loan_account_no = la.sz_loan_account_no
LEFT JOIN dpd_last12    dpd12 ON dpd12.sz_loan_account_no = la.sz_loan_account_no
LEFT JOIN dpd_inception dinc  ON dinc.sz_loan_account_no = la.sz_loan_account_no
LEFT JOIN dpd_max       dmax  ON dmax.sz_loan_account_no = la.sz_loan_account_no
LEFT JOIN advance_info  adv   ON adv.sz_loan_account_no  = la.sz_loan_account_no
LEFT JOIN next_due      nd    ON nd.sz_loan_account_no   = la.sz_loan_account_no
LEFT JOIN bounce_last12 bl12  ON bl12.sz_loan_account_no = la.sz_loan_account_no
LEFT JOIN bounce_inception binc ON binc.sz_loan_account_no = la.sz_loan_account_no
LEFT JOIN pdd_status    pdd   ON pdd.sz_loan_account_no  = la.sz_loan_account_no
LEFT JOIN prov_max_dpd  pmax  ON pmax.sz_loan_account_no = la.sz_loan_account_no

ORDER BY la.sz_loan_account_no;
