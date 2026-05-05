-- Valid bounce rows for HE (CGHFL) — last 12 months
-- Python groups into L3M / L6M / L12M counts per LAN
SELECT
    sz_loan_account_no,
    dt_installmentdue
FROM external_curated.nb_cbr_cghfl_final_new
WHERE dt_installmentdue >= DATEADD(month, -12,
        (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 day')::DATE)
  AND dt_installmentdue <= (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 day')::DATE
  AND bounce_status_same_day = 'BOUNCE'
  AND tech_bounce_ind        = 0
  AND not_presented_ind      = 'PRESENTED'
  AND manual_hold_ind        = 'NO_HOLD'
