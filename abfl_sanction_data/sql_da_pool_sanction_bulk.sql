-- ============================================================
-- DA POOL SANCTION FORMAT – Full HE Book Extract (~17,000 cases)
-- Sheet: "Required for pool shortlisting"  |  132 columns
-- Universe: ALL loans in DA_HE_AB (full HE book, no eligibility filter)
--           Eligibility flags (abfl_overall_eligibility_at_675, bajaj_overall_eligibility_at_700)
--           are available in DA_HE_AB for downstream filtering if needed.
-- POS / Overdue / Rate: CURRENT_DATE live snapshot from loan_dtl_cghfl
-- DPD history / Bounce strings: loan_status_monthly + CBR tables
-- NO {LAN_LIST} placeholder – universe is embedded as a subquery
-- Generated: 2026-05-07
-- ============================================================

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 0: Universe — ALL loans in DA_HE_AB (full HE book, ~17,000 cases)
-- Remove eligibility filter to get complete book; eligibility flags remain
-- available in DA_HE_AB for downstream slicing (ABFL @675, Bajaj @700, etc.)
-- ─────────────────────────────────────────────────────────────────────────────
target_lans AS (
    SELECT sz_loan_account_no, sz_application_no
    FROM "prod_analytics_db"."EXTERNAL_CURATED"."DA_HE_AB"
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
        NULLIF(NULLIF(TRIM(ld.sz_risk_grade), ''), 'None')      AS ld_risk_grade,
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
        app.foir_with_insurance,
        app.eligible_foir,
        app.sz_parent_application,
        app.bt                                                      AS bt_type,
        app.total_eligible_income,
        app.ltv_wo_insurance,
        app.cibil_score                                         AS app_cibil_score,
        NULLIF(NULLIF(TRIM(app.sz_risk_grade), ''), 'None')     AS app_risk_grade,
        app.loan_purpose_description,
        app.loan_purpose_code,
        disb_c.constitution,
        -- Application-level occupation/industry fields
        app.services_type,
        app.nature_of_business,
        app.industry_type,
        app.sub_industry_type,
        -- Specific income-program industry details (18% fill, very specific values)
        app.income_program_industry_details_industry_type    AS ipid_industry,
        app.income_program_industry_details_sub_industry_type AS ipid_sub_industry,
        NULLIF(NULLIF(TRIM(app.latest_emp_designation), ''), 'None') AS app_latest_emp_designation
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
-- CTE 1b: Kuliza FOIR fallback (Kuliza-Flexcube originated loans)
-- ─────────────────────────────────────────────────────────────────────────────
kuliza_foir AS (
    SELECT
        CAST(lmsaccountid AS VARCHAR)                                   AS sz_loan_account_no,
        ROUND(
            COALESCE(
                NULLIF(TRY_CAST(foirmain_hl AS DECIMAL(10,2)), 0),
                CASE WHEN TRY_CAST(monthlycombinedincome_hl AS DECIMAL(15,2)) > 0
                     THEN ROUND(TRY_CAST(totalemi_hl AS DECIMAL(15,2))
                                / TRY_CAST(monthlycombinedincome_hl AS DECIMAL(15,2)) * 100, 2)
                END
            ),
        2)                                                              AS kuliza_foir
    FROM kuliza_datamart_snapshort.kuliza_act_ru_variable_transposed
    WHERE lmsaccountid IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 1c: Linked / parent loan account number (for Top-Up and BT cases)
-- ─────────────────────────────────────────────────────────────────────────────
linked_lan AS (
    SELECT
        la.sz_loan_account_no,
        ld_parent.sz_loan_account_no AS parent_lan
    FROM loan_app la
    JOIN analytics_reporting.loan_dtl_cghfl ld_parent
        ON ld_parent.sz_application_no = la.sz_parent_application
    WHERE la.sz_parent_application IS NOT NULL
      AND NULLIF(TRIM(la.sz_parent_application), '') IS NOT NULL
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
        -- Customer sub-type: Salaried / SEP / SENP / Individual / Non-Individual
        -- NOTE: SEP checked BEFORE SENP/NIP to avoid 'sep - nip' being caught by %nip%
        CASE
            WHEN LOWER(apt.income_program) LIKE '%salar%'
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SAL'               THEN 'Salaried'
            WHEN LOWER(apt.income_program) LIKE '%sep%'
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SEP'               THEN 'SEP'
            WHEN LOWER(apt.income_program) LIKE '%senp%'
              OR LOWER(apt.income_program) LIKE '%nip%'
              OR LOWER(apt.income_program) LIKE '%cpm%'
              OR LOWER(apt.income_program) LIKE '%lip%'
              OR apt.income_program IN ('Self Employed - NIP-CPM', 'Self Employed - NIP')
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SENP'              THEN 'SENP'
            WHEN apt.income_program IS NOT NULL                        THEN INITCAP(apt.income_program)
            WHEN apt.sz_org_name IS NOT NULL                           THEN 'Non-Individual'
            WHEN apt.person_name IS NOT NULL                           THEN 'Individual'
            ELSE NULL
        END                                                     AS cust_subtype,
        -- Col 11: In case of self employed (SENP/SEP) — show Salaried/SENP/SEP for all
        -- SEP checked first to prevent 'sep - nip' being caught by %nip%
        CASE
            WHEN LOWER(apt.income_program) LIKE '%salar%'
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SAL'               THEN 'Salaried'
            WHEN LOWER(apt.income_program) LIKE '%sep%'
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SEP'               THEN 'SEP'
            WHEN LOWER(apt.income_program) LIKE '%senp%'
              OR LOWER(apt.income_program) LIKE '%nip%'
              OR LOWER(apt.income_program) LIKE '%cpm%'
              OR LOWER(apt.income_program) LIKE '%lip%'
              OR apt.income_program IN ('Self Employed - NIP-CPM', 'Self Employed - NIP')
              OR UPPER(TRIM(apt.sz_salary_typ)) = 'SENP'              THEN 'SENP'
            ELSE NULL
        END                                                     AS senp_sep_type,
        -- Occupation/Industry — applicant-level fallback chain (used only if app-level sources fail)
        -- REMOVED: self_employment_sz_org_type_code / employment_sz_org_type_code (AES-encrypted)
        -- REMOVED: sz_primary_occupation (garbage: 'ok','friend','NP_SELF','EMP')
        COALESCE(
            NULLIF(TRIM(apt.ind_sz_industry_type), ''),
            NULLIF(TRIM(apt.org_sz_industry_type), ''),
            lk_nob.szdescription,
            NULLIF(TRIM(apt.ind_sz_nature_off_business), ''),
            NULLIF(TRIM(apt.org_sz_nature_off_business), ''),
            NULLIF(TRIM(apt.sznature_emp_buss), '')
        )                                                       AS occupation,
        -- Employment sector industry (salaried-specific, 42% fill, clean readable)
        NULLIF(TRIM(apt.employment_sz_industry_type), '')       AS emp_industry,
        NULLIF(TRIM(apt.employment_sz_sub_industry), '')        AS emp_sub_industry,
        -- Designation for salaried borrowers (93.9% fill: TEACHER/Driver/MECHANIC/etc.)
        NULLIF(NULLIF(TRIM(apt.employment_sz_designation), ''), 'None') AS emp_designation,
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
        NULLIF(NULLIF(TRIM(apt.sz_kyc_risk), ''), 'None')      AS kyc_risk,
        ROW_NUMBER() OVER (
            PARTITION BY apt.sz_application_no
            ORDER BY
                CASE WHEN apt.sz_appl_type_code = 'BORROWER' THEN 0 ELSE 1 END,
                apt.i_applicant_id
        )                                                       AS seq
    FROM analytics_reporting.applicant_basic_dtl_cghfl apt
    -- Decode ind_sz_nature_off_business codes (e.g. GROCERY -> 'Grocery')
    LEFT JOIN analytics_reporting.base_app_mst_lookups_cghfl lk_nob
        ON lk_nob.szlookupefinedfor = 'L_NATURE_OFF_BUSINESS'
        AND lk_nob.szcode = apt.ind_sz_nature_off_business
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
        MAX(CASE WHEN seq = 1 THEN senp_sep_type END) AS a1_senp_sep,
        MAX(CASE WHEN seq = 1 THEN occupation END)              AS a1_occupation,
        MAX(CASE WHEN seq = 1 THEN emp_industry END)            AS a1_emp_industry,
        MAX(CASE WHEN seq = 1 THEN emp_sub_industry END)        AS a1_emp_sub_industry,
        MAX(CASE WHEN seq = 1 THEN emp_designation END)         AS a1_emp_designation,
        MAX(CASE WHEN seq = 1 THEN income_type END)             AS a1_income_type,
        MAX(CASE WHEN seq = 1 THEN constitution END)            AS a1_constitution,
        MAX(CASE WHEN seq = 1 THEN dt_birth_date END)          AS a1_dob,
        MAX(CASE WHEN seq = 1 THEN pan END)                    AS a1_pan,
        MAX(CASE WHEN seq = 1 THEN sz_cibil_score END)         AS a1_cibil,
        MAX(CASE WHEN seq = 1 THEN kyc_risk END)               AS a1_kyc_risk,
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
            -- Collateral Description: sub-type (Row House, Flat, Bungalow etc.)
            -- property_subtype is cleanest; fall back to decoded sz_subtype codes
            COALESCE(
                NULLIF(INITCAP(NULLIF(TRIM(ast.property_subtype), '')), 'None'),
                CASE UPPER(TRIM(ast.sz_subtype))
                    WHEN 'RHO'  THEN 'Row House'
                    WHEN 'FLT'  THEN 'Flat'
                    WHEN 'BUNG' THEN 'Bungalow'
                    WHEN 'SHOP' THEN 'Shop'
                    WHEN 'OTH'  THEN 'Others'
                    WHEN 'APRT' THEN 'Apartment'
                    WHEN 'VILLA' THEN 'Villa'
                    WHEN 'PENT' THEN 'Penthouse'
                    WHEN 'INDP' THEN 'Independent House'
                    WHEN 'PLOT' THEN 'Plot'
                    ELSE NULLIF(INITCAP(NULLIF(TRIM(ast.sz_subtype), '')), 'None')
                END
            )                                                              AS collateral_desc,
            -- Collateral Use: property_occupation is 100% filled; normalize inconsistent codes
            CASE
                WHEN UPPER(TRIM(ast.property_occupation)) IN ('SELF', 'SELF-OCCUPIED', 'SELF OCCUPIED',
                     'SELF OWNED AND SELF OCCUPIED', 'FAMILY OWNED AND FAMILY OCCUPIED')
                                                           THEN 'Self-Occupied'
                WHEN UPPER(TRIM(ast.property_occupation)) IN ('SELF + RENTED', 'SELF+RENTED')
                                                           THEN 'Self + Rented'
                WHEN UPPER(TRIM(ast.property_occupation)) IN ('RENTED', 'RENT')
                                                           THEN 'Rented'
                WHEN UPPER(TRIM(ast.property_occupation)) IN ('VACANT', 'VCNT')
                                                           THEN 'Vacant'
                WHEN UPPER(TRIM(ast.property_occupation)) IN ('UNDERCONSTRUCTION', 'UNDER CONSTRUCTION',
                     'UNDER-CONSTRUCTION')                 THEN 'Under Construction'
                WHEN NULLIF(NULLIF(TRIM(ast.property_occupation), ''), 'None') IS NOT NULL
                                                           THEN INITCAP(TRIM(ast.property_occupation))
                ELSE NULL
            END                                                            AS collateral_use,
            ast.property_type,
            CASE
                WHEN UPPER(TRIM(ast.property_type)) LIKE '%PLOT%'
                  OR UPPER(TRIM(ast.sz_subtype))    LIKE '%PLOT%'
                THEN 'Y' ELSE 'N'
            END                                                 AS open_plot_flag,
            COALESCE(ast.is_under_construction, 'N')            AS is_under_construction,
            ast.a_i_tot_valuation                               AS collateral_value,
            ast.sz_area_type,
            SUM(ast.a_i_tot_valuation) OVER (
                PARTITION BY ast.sz_application_no
            )                                                   AS total_property_value,
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

    -- Col 12 — priority: specific > generic; encrypted sources removed
    -- ipid_sub (18%): "Kirana Store","Dairy Farm","Civil Contractors" (most specific)
    -- ipid_type (18%): "FMCG Retail","Contractors","Dairy and allied"
    -- emp_industry (42%): "Other Services","Food Processing","Other Traders" (salaried)
    -- industry_type (23%): "FOOD PROCESSING","KIRANA & GROCERY"
    -- services_type (75%): "SERVICE","TRADERS" (generic fallback)
    COALESCE(
        NULLIF(TRIM(la.ipid_sub_industry), ''),
        NULLIF(TRIM(la.ipid_industry), ''),
        NULLIF(TRIM(ap.a1_emp_industry), ''),
        NULLIF(TRIM(ap.a1_emp_sub_industry), ''),
        NULLIF(TRIM(la.industry_type), ''),
        NULLIF(TRIM(la.sub_industry_type), ''),
        NULLIF(TRIM(ap.a1_occupation), ''),
        -- Salaried fallback 1: applicant-level designation (93.9% fill)
        NULLIF(TRIM(ap.a1_emp_designation), ''),
        -- Salaried fallback 2: application-level latest designation (100% fill for gap cases)
        NULLIF(TRIM(la.app_latest_emp_designation), ''),
        NULLIF(TRIM(la.services_type), ''),
        NULLIF(TRIM(la.nature_of_business), '')
    )                                                          AS "Occupation/Industry",

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

    -- Col 68 — app.sz_risk_grade is 99.8% filled; loan_dtl is only 47% and has 'None' strings
    INITCAP(COALESCE(la.app_risk_grade, la.ld_risk_grade, ap.a1_kyc_risk)) AS "Risk Categorization",

    -- Col 69  (normalize + fallback to loan_purpose_code for HE Semi-Fixed cases)
    CASE
        WHEN LOWER(TRIM(la.end_use_loan_description)) LIKE '%top%up%'
          OR LOWER(TRIM(la.end_use_loan_description)) LIKE '%top-up%'
                                                     THEN 'Top-Up Loan'
        WHEN LOWER(TRIM(la.end_use_loan_description)) LIKE '%balance transfer%'
                                                     THEN 'Balance Transfer of Loan'
        WHEN LOWER(TRIM(la.end_use_loan_description)) LIKE '%business%'
                                                     THEN 'Business Expansion and/or Working Capital Needs'
        WHEN LOWER(TRIM(la.end_use_loan_description)) LIKE '%purchase%'
          OR LOWER(TRIM(la.end_use_loan_description)) LIKE '%construct%'
          OR LOWER(TRIM(la.end_use_loan_description)) LIKE '%renovation%'
                                                     THEN 'Purchase/Construction/Extension/Renovation of Property'
        WHEN NULLIF(TRIM(la.end_use_loan_description), '') IS NOT NULL
                                                     THEN INITCAP(TRIM(la.end_use_loan_description))
        WHEN UPPER(TRIM(la.loan_purpose_code)) = 'LAP'
                                                     THEN 'Purchase/Construction/Extension/Renovation of Property'
        WHEN LOWER(TRIM(la.loan_purpose_description)) LIKE '%refinance%'
          OR LOWER(TRIM(la.loan_purpose_description)) LIKE '%balance transfer%'
                                                     THEN 'Balance Transfer of Loan'
        WHEN LOWER(TRIM(la.loan_purpose_description)) LIKE '%top%up%'
                                                     THEN 'Top-Up Loan'
        WHEN LOWER(TRIM(la.loan_purpose_description)) LIKE '%business%'
                                                     THEN 'Business Expansion and/or Working Capital Needs'
        WHEN NULLIF(TRIM(la.loan_purpose_description), '') IS NOT NULL
                                                     THEN INITCAP(TRIM(la.loan_purpose_description))
        ELSE NULL
    END                                                        AS "End use as per end use letter /Sanction letter",

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

    -- Col 80  (c_interest_rate_type: V=Floating, M=Mixed, F=Fixed)
    CASE UPPER(TRIM(la.c_interest_rate_type))
        WHEN 'V'          THEN 'Floating'
        WHEN 'F'          THEN 'Fixed'
        WHEN 'M'          THEN 'Mixed'
        WHEN 'FLOATING'   THEN 'Floating'
        WHEN 'FIXED'      THEN 'Fixed'
        WHEN 'MIXED'      THEN 'Mixed'
        WHEN 'SEMI-FIXED' THEN 'Semi-Fixed'
        ELSE INITCAP(NULLIF(TRIM(la.c_interest_rate_type), ''))
    END                                                        AS "Rate Type",

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

    -- Col 109: if PDD complete = Y → 'No' (no pending docs); else list pending docs
    CASE
        WHEN COALESCE(pdd.pdd_complete, 'Y') = 'Y' THEN 'No'
        ELSE NULLIF(pdd.pdd_pending_docs, '')
    END                                                        AS "PDD status, if pending (Mention any critical docs)",

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
    CASE
        WHEN LOWER(NULLIF(TRIM(la.bt_type), '')) IN ('topup', 'balance transfer + topup',
             'balance transfer + topup + child')                THEN 'Y'
        WHEN lnk.parent_lan IS NOT NULL                        THEN 'Y'
        ELSE 'N'
    END                                                        AS "Link loan Part of pool (Yes/ No)",

    -- Col 118  [not tracked in analytics tables]
    CAST(lnk.parent_lan AS VARCHAR)                            AS "Link Loan/Top up loan Number if applicable",

    -- ── NPA & PSL (Cols 119-120) ─────────────────────────────────────────

    -- Col 119
    CASE WHEN UPPER(COALESCE(la.npa_flag, 'N')) = 'Y' THEN 'Y' ELSE 'N' END
                                                               AS "Loan became NPA since origination (Y/N)",

    -- Col 120  PSL/NPSL — RBI criteria: Urban <45L prop / <35L sanction = Y; Rural <30L/<25L = Y
    CASE
        WHEN NULLIF(TRIM(la.c_psl), '') IS NOT NULL
            THEN UPPER(TRIM(la.c_psl))
        WHEN UPPER(TRIM(ast.sz_area_type)) IN ('RURAL')
            AND ast.total_property_value < 3000000
            AND la.f_sanctioned_amt      < 2500000
            THEN 'Y'
        WHEN (UPPER(TRIM(ast.sz_area_type)) IN ('URBAN') OR ast.sz_area_type IS NULL)
            AND ast.total_property_value < 4500000
            AND la.f_sanctioned_amt      < 3500000
            THEN 'Y'
        ELSE 'N'
    END                                                        AS "PSL/NPSL flag",

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

    -- Col 128: FOIR chain — with_insurance > wo_insurance > eligible_foir > Kuliza datamart
    ROUND(
        NULLIF(
            COALESCE(
                NULLIF(TRY_CAST(la.foir_with_insurance AS DECIMAL(10,2)), 0),
                NULLIF(TRY_CAST(la.foir_wo_insurance   AS DECIMAL(10,2)), 0),
                NULLIF(TRY_CAST(la.eligible_foir       AS DECIMAL(10,2)), 0),
                NULLIF(kfoir.kuliza_foir,               0)
            ),
        0),
    2)                                                             AS "FOIR",

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
LEFT JOIN linked_lan    lnk   ON lnk.sz_loan_account_no  = la.sz_loan_account_no
LEFT JOIN kuliza_foir   kfoir ON kfoir.sz_loan_account_no = la.sz_loan_account_no

ORDER BY la.sz_loan_account_no;
