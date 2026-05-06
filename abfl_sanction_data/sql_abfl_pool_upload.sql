-- ============================================================
-- ABFL POOL UPLOAD FORMAT — DATA EXTRACTION SQL
-- Entity  : CGHFL (HE loans)
-- Key     : {LAN_LIST} = sz_loan_account_no values (Application Form No. in template)
-- Author  : Auto-generated 2026-05-06
-- ============================================================

-- ============================================================
-- QUERY 1: DEAL AND LOAN DATA
-- ============================================================
-- [QUERY: deal]
WITH disb_advance AS (
    SELECT
        sz_loan_account_no,
        COUNT(CASE WHEN COALESCE(pre_emi_amt,0) > 0 THEN 1 END) AS no_advance_installment
    FROM analytics_reporting.disbursement_cghfl_v2
    WHERE sz_loan_account_no IN ({LAN_LIST})
    GROUP BY sz_loan_account_no
),
next_due AS (
    SELECT
        sz_loan_account_no,
        MIN(dt_installmentdue) AS next_due_date
    FROM analytics_reporting.repayment_schedule_cghfl
    WHERE sz_loan_account_no IN ({LAN_LIST})
      AND dt_installmentdue >= CURRENT_DATE
    GROUP BY sz_loan_account_no
),
asset_top AS (
    SELECT *
    FROM (
        SELECT
            sz_application_no,
            a_i_tot_valuation            AS asset_cost,
            sz_cersai_sec_int_id         AS cersai_id,
            property_type,
            city                         AS property_city,
            state                        AS property_state,
            sz_postal_code               AS property_pincode,
            ROW_NUMBER() OVER (
                PARTITION BY sz_application_no
                ORDER BY a_i_tot_valuation DESC NULLS LAST
            ) AS rk
        FROM analytics_reporting.asset_cghfl
        WHERE sz_application_no IS NOT NULL
    ) t WHERE rk = 1
)
SELECT
    ld.sz_loan_account_no                               AS "Application Form No.",
    app.branch                                          AS "Branch",
    rm_info.sz_rm_name                                  AS "Relationship officer/executive",
    'Home Equity'                                       AS "Product",
    ld.scheme                                           AS "Scheme",
    asset_top.asset_cost                                AS "Asset Cost",
    1                                                   AS "No Of Asset",
    app.eligible_loan_amount                            AS "Requested Loan Amount",
    ld.F_CURR_INTERESTRATE / 100.0                      AS "Final Rate",
    apt.sz_primary_occupation                           AS "Sector Type",
    app.loan_purpose_description                        AS "Loan Purpose",
    next_due.next_due_date                              AS "Next Due Date DD-MM-YYYY",
    ld.installment_start_date                           AS "Repay Effective Date DD-MM-YYYY",
    COALESCE(da.no_advance_installment, 0)              AS "No of Advance Installment",
    NULL                                                AS "Interest Compounding Frequency",
    'M'                                                 AS "Frequency",
    ld.I_TENOR                                          AS "Tenure",
    ld.sz_repayment_mode                                AS "Re-Payment Mode",
    'EMI'                                               AS "Installment Type",
    NULL                                                AS "Credit Period(in days)",
    'NACH'                                              AS "Installment Mode",
    'M'                                                 AS "Interest Frequency",
    NULL                                                AS "Business Type",
    NULL                                                AS "Anchor Id",
    NULL                                                AS "Dealer Id",
    NULL                                                AS "Vendor Id",
    app.sanction_date                                   AS "Sanction Validity Date",
    ld.f_sanctioned_amt                                 AS "Deal Sanction Amount",
    NULL                                                AS "CRM NO",
    ld.sz_customer_no                                   AS "External Customer ID",
    NULL                                                AS "Card_No",
    NULL                                                AS "field_1",
    NULL                                                AS "los_scheme_name",
    NULL                                                AS "merchant_id",
    'Y'                                                 AS "FI_VERIFICATION",
    'Y'                                                 AS "TECH_VERIFICATION",
    'Y'                                                 AS "LEGAL_VERIFICATION",
    asset_top.cersai_id                                 AS "Cersai ID"
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.application_cghfl app
    ON app.sz_application_no = ld.sz_application_no
LEFT JOIN (
    SELECT sz_application_no, sz_primary_occupation
    FROM analytics_reporting.applicant_basic_dtl_cghfl
    WHERE sz_appl_type_code = 'BORROWER'
) apt ON apt.sz_application_no = ld.sz_application_no
LEFT JOIN (
    SELECT sz_loan_account_no, sz_rm_name
    FROM (
        SELECT sz_loan_account_no, sz_rm_name,
               ROW_NUMBER() OVER (PARTITION BY sz_loan_account_no ORDER BY i_tranch_srno) AS rk
        FROM analytics_reporting.disbursement_cghfl_v2
        WHERE sz_loan_account_no IN ({LAN_LIST})
    ) t WHERE rk = 1
) rm_info ON rm_info.sz_loan_account_no = ld.sz_loan_account_no
LEFT JOIN disb_advance da       ON da.sz_loan_account_no  = ld.sz_loan_account_no
LEFT JOIN next_due              ON next_due.sz_loan_account_no = ld.sz_loan_account_no
LEFT JOIN asset_top             ON asset_top.sz_application_no = ld.sz_application_no
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no;


-- ============================================================
-- QUERY 2: CUSTOMER DATA  (borrower + co-borrowers)
-- ============================================================
-- [QUERY: customer]
SELECT
    ld.sz_loan_account_no                                           AS "Application Form No.",
    apt.sz_customer_no                                              AS "Customer ID",
    apt.sz_appl_type_code                                           AS "Applicant Type",
    apt.sz_appl_category_code                                       AS "Applicant Category",
    UPPER(TRIM(apt.sz_lookup_desc))                                 AS "Category",
    NULL                                                            AS "Group Type",
    NULL                                                            AS "Group Name",
    apt.sz_first_name                                               AS "Individual Name",
    apt.sz_middle_name                                              AS "Middle Name",
    apt.sz_last_name                                                AS "Last Name",
    apt.c_gender                                                    AS "Gender",
    'INDIVIDUAL'                                                    AS "Individual Category",
    COALESCE(apt.sz_salary_typ, apt.sz_org_constitution)            AS "Constitution",
    TRIM(COALESCE(apt.sz_fathers_full_name,'') || ' ' ||
         COALESCE(apt.father_last_name,''))                         AS "Father_Husband_Name",
    apt.dt_birth_date                                               AS "Birth Date(DD-MM-YYYY)",
    NVL(NVL(adr.sz_email_id1, adr.sz_email_id2),
        NVL(adr.sz_email, adr.sz_email1))                          AS "Email",
    apt.sz_marital_status                                           AS "Marital Status",
    NVL(apt.sz_id2, apt.sz_panno)                                   AS "Pan No",
    apt.sz_id3                                                      AS "Driving License Number",
    apt.ind_sz_industry_type                                        AS "Industry",
    app.sub_industry_type                                           AS "Sub-Industry",
    apt.sz_voter_id                                                 AS "Voter ID Number",
    apt.sz_id1                                                      AS "PassPort Number",
    apt.sz_uid_no                                                   AS "Aadhaar/UID No",
    apt.sz_relation_to_main_applicant                               AS "Other Relationship",
    apt.sz_education_level                                          AS "Educational Detail",
    NULL                                                            AS "Residential Status",
    NULL                                                            AS "Citizenship",
    NULL                                                            AS "Registration no.",
    app.services_type                                               AS "Business Segment",
    NULL                                                            AS "TIN No",
    NULL                                                            AS "Existing Customer",
    apt.sz_mother_maiden_name                                       AS "MOTHER_NAME",
    NULL                                                            AS "Customer Risk Category",
    NULL                                                            AS "Insurance Flag",
    CASE
        WHEN apt.sz_cibil_score IS NULL THEN NULL
        WHEN UPPER(apt.sz_cibil_score) SIMILAR TO '%[A-Z]%' THEN NULL
        ELSE TRY_CAST(apt.sz_cibil_score AS INT)
    END                                                             AS "CIBIL SCORE",
    apt.sz_ckyc_id                                                  AS "CKYC No",
    NULL                                                            AS "TAN_NO",
    apt.sz_religion                                                 AS "Religion",
    apt.final_income                                                AS "Income",
    ast_top.cersai_id                                               AS "Cersai ID",
    UPPER(TRIM(apt.sz_lookup_desc))                                 AS "Caste",
    apt.sz_primary_occupation                                       AS "Occupation"
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
    ON apt.sz_application_no = ld.sz_application_no
JOIN analytics_reporting.application_cghfl app
    ON app.sz_application_no = ld.sz_application_no
LEFT JOIN analytics_reporting.applicant_address_contact_dtl_cghfl adr
    ON adr.sz_application_no = apt.sz_application_no
    AND adr.i_applicant_id   = apt.i_applicant_id
LEFT JOIN (
    SELECT sz_application_no, sz_cersai_sec_int_id AS cersai_id
    FROM (
        SELECT sz_application_no, sz_cersai_sec_int_id,
               ROW_NUMBER() OVER (
                   PARTITION BY sz_application_no
                   ORDER BY a_i_tot_valuation DESC NULLS LAST
               ) AS rk
        FROM analytics_reporting.asset_cghfl
        WHERE sz_application_no IS NOT NULL
    ) t WHERE rk = 1
) ast_top ON ast_top.sz_application_no = ld.sz_application_no
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no, apt.i_applicant_id;


-- ============================================================
-- QUERY 3: ADDRESS DETAILS
-- ============================================================
-- [QUERY: address]
SELECT
    ld.sz_loan_account_no                   AS "Application Form No.",
    apt.sz_customer_no                      AS "Customer ID",
    'CURRENT'                               AS "Address Type",
    adr.current_sz_address_1                AS "Address Line1",
    adr.current_sz_address_2                AS "Address Line2",
    adr.current_sz_address_3                AS "Address Line3",
    'INDIA'                                 AS "Country",
    NULL                                    AS "State_ID",
    NULL                                    AS "District_ID",
    NULL                                    AS "Tehsil",
    adr.current_sz_postal_code              AS "Pincode",
    NULL                                    AS "Landmark",
    NULL                                    AS "Area",
    adr.current_city                        AS "City",
    NULL                                    AS "Address Category",
    NULL                                    AS "Ownership Type",
    NULL                                    AS "Residence Duration",
    'Y'                                     AS "Correspondence Address Flag",
    adr.current_state                       AS "State",
    NULL                                    AS "District"
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
    ON apt.sz_application_no = ld.sz_application_no
JOIN analytics_reporting.applicant_address_contact_dtl_cghfl adr
    ON adr.sz_application_no = apt.sz_application_no
    AND adr.i_applicant_id   = apt.i_applicant_id
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no, apt.i_applicant_id;


-- ============================================================
-- QUERY 4: REFERENCE DETAILS  (not in DB)
-- ============================================================
-- [QUERY: reference]
SELECT
    ld.sz_loan_account_no   AS "Application Form No.",
    apt.sz_customer_no      AS "Customer ID",
    NULL                    AS "First Name ",
    NULL                    AS "Middle Name",
    NULL                    AS "Last Name ",
    NULL                    AS "Relationship",
    NULL                    AS "Mobile No",
    NULL                    AS "LandLine No",
    NULL                    AS "Knowing Since (In Year)",
    NULL                    AS "Address"
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
    ON apt.sz_application_no = ld.sz_application_no
    AND apt.sz_appl_type_code = 'BORROWER'
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no;


-- ============================================================
-- QUERY 5: BANK DETAILS
-- ============================================================
-- [QUERY: bank]
SELECT
    ld.sz_loan_account_no                   AS "Application Form No.",
    apt.sz_customer_no                      AS "Customer ID",
    bk.SZ_BANK_NAME                         AS "Bank",
    bk.SZ_BRANCH_NAME                       AS "Bank Branch Name",
    bk.SZ_IFSC                              AS "IFSC Code",
    NULL                                    AS "MICR Code",
    bk.SZ_ACCOUNT_NO                        AS "Account No"
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
    ON apt.sz_application_no = ld.sz_application_no
    AND apt.sz_appl_type_code = 'BORROWER'
LEFT JOIN (
    SELECT *
    FROM (
        SELECT
            I_APPLICANT_ID,
            SZ_BANK_NAME, SZ_BRANCH_NAME, SZ_IFSC, SZ_ACCOUNT_NO,
            ROW_NUMBER() OVER (
                PARTITION BY I_APPLICANT_ID
                ORDER BY C_USE_FOR_REPAYMENT_YN DESC NULLS LAST, I_SRNO
            ) AS rk
        FROM analytics_reporting.banking_details_cghfl
    ) t WHERE rk = 1
) bk ON bk.I_APPLICANT_ID =
        CASE WHEN LEFT(apt.i_applicant_id, 1) IN ('I','K')
             THEN SUBSTRING(apt.i_applicant_id, 2)
             ELSE apt.i_applicant_id
        END
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no;


-- ============================================================
-- QUERY 6: MANAGEMENT DETAILS  (stub — no stakeholder table)
-- ============================================================
-- [QUERY: management]
SELECT
    ld.sz_loan_account_no   AS "Application Form No",
    apt.sz_customer_no      AS "Customer ID",
    NULL                    AS "Salutation",
    NULL                    AS "StakeHolder Name",
    NULL                    AS "Management Type",
    NULL                    AS "Date of Birth(DD-MM-YYYY)",
    NULL                    AS "Email ID",
    NULL                    AS "Mobile No",
    NULL                    AS "PAN No."
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
    ON apt.sz_application_no = ld.sz_application_no
    AND apt.sz_appl_type_code = 'BORROWER'
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no;


-- ============================================================
-- QUERY 7: ASSET / COLLATERAL DETAILS
-- ============================================================
-- [QUERY: asset]
SELECT
    ld.sz_loan_account_no                   AS "Application Form No",
    NULL                                    AS "Product Type",
    1                                       AS "Quantity",
    ast.a_i_tot_valuation                   AS " Price",
    NULL                                    AS "Tax Amount",
    NULL                                    AS "Invoice Amount",
    NULL                                    AS "Invoice No",
    NULL                                    AS "Invoice Location",
    NULL                                    AS "Due Date DD-MM-YYYY",
    ast.sz_asset_type_code                  AS "Asset Type",
    NULL                                    AS "Machine Description",
    NULL                                    AS "Machine Cost",
    NULL                                    AS "Discount",
    NULL                                    AS "Machine Value",
    NULL                                    AS "Machine Security Margin",
    NULL                                    AS "Machine Make",
    NULL                                    AS "Machine Model",
    NULL                                    AS "Machine Type",
    NULL                                    AS "Machinery Owner",
    NULL                                    AS "Year Of Manufacturing",
    NULL                                    AS "Identification Number",
    NULL                                    AS "Asset Nature",
    NULL                                    AS "Manufacturer",
    NULL                                    AS "Supplier",
    NULL                                    AS "Invoice Date DD_MM_YYYY",
    NULL                                    AS "Security Type",
    ast.sz_address_1                        AS "Address Line1",
    ast.sz_address_2                        AS "Address Line2",
    ast.sz_address_3                        AS "Address Line3",
    'INDIA'                                 AS "Country",
    ast.state                               AS "State",
    ast.city                                AS "District/City",
    ast.taluka                              AS "Tehsil",
    ast.sz_postal_code                      AS "Pincode",
    NULL                                    AS "Standard",
    ast.sz_description                      AS "Property Description",
    ast.property_owner_name                 AS "Property Owner",
    TRIM(COALESCE(ast.sz_address_1,'') || ', ' || COALESCE(ast.city,'') || ', ' || COALESCE(ast.state,'')) AS "Property Address",
    ast.property_type                       AS "Property Type",
    NULL                                    AS "Property Title",
    ast.property_occupation                 AS "Property Status",
    ast.f_carpet_area                       AS "Carpet Area",
    NULL                                    AS "Property Construction",
    ast.f_builtarea                         AS "Property Area",
    ast.a_i_tot_valuation                   AS "Property Value",
    NULL                                    AS "Document Value",
    NULL                                    AS "Technical Val1",
    NULL                                    AS "Technical Val2",
    NULL                                    AS "Valuation MethodId",
    ast.a_i_tot_valuation                   AS "Valuation Amount",
    NULL                                    AS "Collateral Security Margin",
    NULL                                    AS "Asset Level",
    NULL                                    AS "Additional Construction",
    NULL                                    AS "Machine Collateral Cost",
    NULL                                    AS "Asset Collateral Class",
    NULL                                    AS "Reff Asset Id",
    ast.sz_area_type                        AS "Urban / Rural (as per Census 2011)",
    NULL                                    AS "Asset Insurance",
    ast.town                                AS "Name of Town/Village/City"
FROM analytics_reporting.loan_dtl_cghfl ld
JOIN analytics_reporting.asset_cghfl ast
    ON ast.sz_application_no = ld.sz_application_no
WHERE ld.sz_loan_account_no IN ({LAN_LIST})
ORDER BY ld.sz_loan_account_no, ast.i_asset_srno;


-- ============================================================
-- QUERY 8: UPLOAD CHARGE DETAILS  — not in DB
-- ============================================================
-- [QUERY: charge]
SELECT
    NULL AS "Application Form No.",
    NULL AS "Charge Type",
    NULL AS "Charge Code",
    NULL AS "Business Partner Type",
    NULL AS "Business Partner Name",
    NULL AS "Tax Inclusive",
    NULL AS "Tax Rate1",
    NULL AS "Tax Rate2",
    NULL AS "Charge Amount",
    NULL AS "Final Amount",
    NULL AS "Charge Calculated On",
    NULL AS "Charge Method"
WHERE 1 = 0;


-- ============================================================
-- QUERY 9: UPLOAD DISBURSAL DATA
-- ============================================================
-- [QUERY: disbursal]
SELECT
    d.sz_loan_account_no                                AS "Application Form No.",
    d.dt_disb_date                                      AS "Disbursal Date DD-MM-YYYY",
    NULL                                                AS "Maker Remarks",
    NULL                                                AS "Author Remarks",
    NULL                                                AS "Disbursal To",
    apt.sz_customer_no                                  AS "Customer ID",
    d.f_tranche_amt                                     AS "Disbursal Amount",
    NULL                                                AS "Adjust Total Payable",
    NULL                                                AS "Adjust Total Receivable",
    d.net_disb_amt                                      AS "Net Amount",
    d.c_final_disb_yn                                   AS "Final Disbursal",
    NULL                                                AS "Loan Curtailment",
    NULL                                                AS "Pay To",
    NULL                                                AS "Payee Name",
    'NACH'                                              AS "Payment Mode",
    d.dt_disb_date                                      AS "Payment Date DD-MM-YYYY",
    NULL                                                AS "Instrument No",
    NULL                                                AS "Instrument Date DD-MM-YYYY",
    bk.SZ_ACCOUNT_NO                                    AS "Bank Account",
    NULL                                                AS "Bank Id",
    NULL                                                AS "Branch Id",
    NULL                                                AS "MICR Code",
    bk.SZ_IFSC                                          AS "IFSC Code",
    d.net_disb_amt                                      AS "Payment Amount",
    NULL                                                AS "Tds Amount",
    NULL                                                AS "Remarks",
    NULL                                                AS "Payment Flag",
    d.c_final_disb_yn                                   AS "Disbursal Flag"
FROM analytics_reporting.disbursement_cghfl_v2 d
LEFT JOIN (
    SELECT sz_application_no, sz_customer_no, i_applicant_id
    FROM analytics_reporting.applicant_basic_dtl_cghfl
    WHERE sz_appl_type_code = 'BORROWER'
) apt ON apt.sz_application_no = d.sz_application_no
LEFT JOIN (
    SELECT *
    FROM (
        SELECT
            I_APPLICANT_ID,
            SZ_ACCOUNT_NO, SZ_IFSC,
            ROW_NUMBER() OVER (
                PARTITION BY I_APPLICANT_ID
                ORDER BY C_USE_FOR_REPAYMENT_YN DESC NULLS LAST, I_SRNO
            ) AS rk
        FROM analytics_reporting.banking_details_cghfl
    ) t WHERE rk = 1
) bk ON bk.I_APPLICANT_ID =
        CASE WHEN LEFT(apt.i_applicant_id, 1) IN ('I','K')
             THEN SUBSTRING(apt.i_applicant_id, 2)
             ELSE apt.i_applicant_id
        END
WHERE d.sz_loan_account_no IN ({LAN_LIST})
ORDER BY d.sz_loan_account_no, d.i_tranch_srno;


-- ============================================================
-- QUERY 10: UPLOAD DISBURSAL SCHEDULE
-- ============================================================
-- [QUERY: disbursal_schedule]
SELECT
    d.sz_loan_account_no                                AS "Application Form No.",
    COUNT(*) OVER (PARTITION BY d.sz_loan_account_no)  AS "No Of Disbursal",
    d.dt_disb_date                                      AS "Date Of Disbursal DD-MM-YYYY",
    d.loan_purpose                                      AS "Description",
    d.f_tranche_amt                                     AS "Amount"
FROM analytics_reporting.disbursement_cghfl_v2 d
WHERE d.sz_loan_account_no IN ({LAN_LIST})
ORDER BY d.sz_loan_account_no, d.i_tranch_srno;


-- ============================================================
-- QUERY 11: UPLOAD INSTALLMENT PLAN
-- ============================================================
-- [QUERY: installment]
SELECT
    rs.sz_loan_account_no               AS "Application Form No",
    rs.i_installment_no                 AS "Installment No",
    rs.dt_installmentdue                AS "Installment Date",
    (rs.principal_amt + rs.interest_amt) AS "Installment Amount",
    rs.principal_amt                    AS "Principal Amount",
    rs.interest_amt                     AS "Interest Amount",
    rs.f_closing_bal                    AS "Closing POS"
FROM analytics_reporting.repayment_schedule_cghfl rs
WHERE rs.sz_loan_account_no IN ({LAN_LIST})
ORDER BY rs.sz_loan_account_no, rs.i_installment_no;
