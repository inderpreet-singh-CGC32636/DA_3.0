-- ============================================================================
-- BAJAJ FINAL LANs EXTRACTION – SHEET 2: CO-APPLICANT (ROW-LEVEL)
-- ============================================================================
-- Purpose : Extract DS Team fields for ALL co-borrowers per LAN.
--           Each co-applicant is a separate row.
--           Non-DS fields are returned as blank.
-- Granularity : One row per co-applicant per LAN.
-- Placeholder : <LAN_LIST>  – Python injects quoted, comma-separated LANs.
-- ============================================================================

WITH loan_app AS (
    -- Map LANs to application numbers
    SELECT
        ld.sz_loan_account_no,
        ld.sz_application_no
    FROM analytics_reporting.loan_dtl_cghfl ld
    WHERE ld.sz_loan_account_no IN (<LAN_LIST>)
),

co_borrowers AS (
    SELECT
        la.sz_loan_account_no,
        apt.sz_application_no,
        apt.sz_customer_no,
        apt.i_applicant_id,
        apt.person_name,
        apt.sz_field2        AS salutation,
        apt.sz_org_name,
        apt.sz_mother_maiden_name,
        TRIM(NVL(apt.sz_fathers_full_name, '') || ' ' || NVL(apt.father_last_name, '')) AS father_name,
        apt.dt_birth_date,
        apt.c_gender,
        apt.sz_appl_category_code,
        apt.sz_org_constitution,
        apt.udyam_aadhar_number,
        apt.sz_ckyc_id,
        NVL(apt.sz_id2, apt.sz_panno) AS pan,
        apt.sz_uid_no       AS aadhaar,
        apt.sz_voter_id     AS voter_id,
        apt.sz_id3          AS driving_lic,
        apt.sz_relation_to_main_applicant AS relation,
        -- Sequence number for co-applicants within each LAN
        ROW_NUMBER() OVER (
            PARTITION BY la.sz_loan_account_no
            ORDER BY apt.i_applicant_id
        ) AS co_applicant_seq
    FROM loan_app la
    INNER JOIN analytics_reporting.applicant_basic_dtl_cghfl apt
        ON la.sz_application_no = apt.sz_application_no
       AND apt.sz_appl_type_code = 'COBORROWER'
),

co_borrower_contact AS (
    SELECT
        addr.sz_application_no,
        addr.i_applicant_id,
        addr.current_sz_address_1,
        addr.current_sz_address_2,
        addr.current_sz_address_3,
        addr.current_sz_postal_code,
        addr.current_city,
        addr.current_state,
        CASE
            WHEN LENGTH(addr.SZ_MOBILE1) = 10 THEN addr.SZ_MOBILE1
            WHEN LENGTH(addr.SZ_MOBILE2) = 10 THEN addr.SZ_MOBILE2
            WHEN LENGTH(addr.sz_mobile_no) = 10 THEN addr.sz_mobile_no
            WHEN LENGTH(CAST(addr.current_i_mobileno AS VARCHAR)) = 10 THEN CAST(addr.current_i_mobileno AS VARCHAR)
        END AS phone,
        NVL(
            NVL(addr.sz_email_id1, addr.sz_email_id2),
            NVL(addr.sz_email, addr.sz_email1)
        ) AS email
    FROM analytics_reporting.applicant_address_contact_dtl_cghfl addr
    WHERE addr.sz_application_no IN (SELECT sz_application_no FROM co_borrowers)
)

-- ==================== FINAL SELECT ====================
SELECT
    -- ---- DS Team: Co-Applicant Identifier ----
    'Co-Applicant ' || CAST(cb.co_applicant_seq AS VARCHAR(5))
                                                        AS "Co-Applicant #",

    -- ---- Product Team → blank (but LAN populated for matching) ----
    COALESCE(cb.sz_loan_account_no, '')                 AS "Partner LAN",

    -- ---- DS Team fields ----
    COALESCE(cb.sz_customer_no, '')                     AS "CUST ID",
    COALESCE(
        CASE
            WHEN cb.person_name IS NOT NULL
            THEN SPLIT_PART(cb.person_name, ' ', 1)
            ELSE ''
        END, '')                                        AS "Customer First Name",
    COALESCE(
        CASE
            WHEN cb.person_name IS NOT NULL
                 AND LENGTH(cb.person_name) - LENGTH(REPLACE(cb.person_name, ' ', '')) >= 2
            THEN SPLIT_PART(cb.person_name, ' ', 2)
            ELSE ''
        END, '')                                        AS "Customer Middle Name",
    COALESCE(
        CASE
            WHEN cb.person_name IS NOT NULL
                 AND LENGTH(cb.person_name) - LENGTH(REPLACE(cb.person_name, ' ', '')) >= 1
            THEN REVERSE(SPLIT_PART(REVERSE(cb.person_name), ' ', 1))
            ELSE ''
        END, '')                                        AS "Customer Last Name",
    COALESCE(cb.salutation, '')                         AS "Salutation",
    ''                                                  AS "Short Name (Corporate Name)",

    -- ---- DS Team: Personal Details ----
    COALESCE(cb.sz_mother_maiden_name, '')               AS "Mother Name",
    COALESCE(cb.father_name, '')                         AS "Father Name",
    COALESCE(TO_CHAR(cb.dt_birth_date, 'DD-MM-YYYY'), '') AS "Date Of Birth",
    COALESCE(cb.c_gender, '')                            AS "Gender",
    ''                                                   AS "Marital Status (M/U)",
    COALESCE(
        CASE
            WHEN cb.sz_appl_category_code = 'I' THEN 'Individual'
            WHEN UPPER(cb.sz_org_constitution) IN ('PART','PARTNER','PAR','FIR') THEN 'Partnership'
            WHEN UPPER(cb.sz_org_constitution) IN ('PROP','PROPR','SPR','PROPRIETOR') THEN 'Proprietorship'
            WHEN UPPER(cb.sz_org_constitution) IN ('PVT','PRL','PRIVATE LIMITED') THEN 'Company'
            WHEN UPPER(cb.sz_org_constitution) IN ('HUF','HNUF') THEN 'HUF'
            WHEN UPPER(cb.sz_org_constitution) IN ('LLP','LIMITED LIABILITY') THEN 'LLP'
            WHEN UPPER(cb.sz_org_constitution) = 'IND' THEN 'Individual'
            ELSE cb.sz_org_constitution
        END, '')                                         AS "Customer Type (Partnership/Proprietorship/Company)",
    COALESCE(cb.udyam_aadhar_number, '')                 AS "Udhyam Aadhar Number",
    COALESCE(cb.sz_ckyc_id, '')                          AS "CKYC Details",
    CASE
        WHEN cb.pan IS NOT NULL        THEN 'PAN'
        WHEN cb.aadhaar IS NOT NULL    THEN 'AADHAAR'
        WHEN cb.voter_id IS NOT NULL   THEN 'VOTER ID'
        WHEN cb.driving_lic IS NOT NULL THEN 'DRIVING LICENSE'
        ELSE ''
    END                                                  AS "ID Type (Gov ID)",
    TRIM(
        COALESCE(cb.pan, '')
        || CASE WHEN cb.aadhaar IS NOT NULL    THEN ' | ' || cb.aadhaar    ELSE '' END
        || CASE WHEN cb.voter_id IS NOT NULL   THEN ' | ' || cb.voter_id   ELSE '' END
        || CASE WHEN cb.driving_lic IS NOT NULL THEN ' | ' || cb.driving_lic ELSE '' END
    )                                                    AS "PAN, AADHAR, VOTER ID & DL",
    'Current'                                            AS "Address Type (Current/Permanent)",
    ''                                                   AS "Building No",
    ''                                                   AS "Flat No",
    ''                                                   AS "Street",
    COALESCE(cc.current_sz_address_1, '')                AS "Address Line 1",
    COALESCE(cc.current_sz_address_2, '')                AS "Address Line 2",
    COALESCE(cc.current_sz_postal_code, '')              AS "Pin Code",
    COALESCE(cc.phone, '')                               AS "Phone Number",
    COALESCE(cc.email, '')                               AS "Customer EMail"

FROM co_borrowers cb
LEFT JOIN co_borrower_contact cc
    ON  cb.sz_application_no = cc.sz_application_no
    AND cb.i_applicant_id    = cc.i_applicant_id
ORDER BY cb.sz_loan_account_no, cb.co_applicant_seq;
