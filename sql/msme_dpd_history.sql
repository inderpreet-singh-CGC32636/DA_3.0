-- Full DPD history for MSME (CGCL) — no date filter
-- Used by run_msme_v3.py: Python derives MAX_DPD_EVER, MAX_DPD_18M, EVER_30_DPD_6M,
-- EVER_NPA, EVER_BUCKET from this single pull.
SELECT
    sz_loan_account_no,
    dt_businessdate,
    i_dpd,
    npa_flag,
    f_overdue_principal,
    f_overdue_interest,
    i_no_of_paid_emi
FROM analytics_reporting.loan_status_monthly_CGCL
WHERE dt_businessdate <= (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 day')::DATE
