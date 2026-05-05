-- Raw asset rows for MSME (CGCL) — Python aggregates into residential_pct, LTV, plot_count, etc.
SELECT
    sz_application_no,
    property_type,
    property_subtype,
    property_occupation,
    a_i_tot_valuation,
    sz_postal_code        AS property_pincode,
    sz_cersai_sec_int_id,
    dt_cersai
FROM analytics_reporting.asset_CGCL
WHERE sz_application_no IS NOT NULL
