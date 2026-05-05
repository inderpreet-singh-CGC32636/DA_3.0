-- Restructured LANs — shared across MSME and HE
SELECT DISTINCT loan_number AS sz_loan_account_no
FROM analytics_reporting.restructuresaha_data_monthly
WHERE universe_mapping_rest_saha = 'Restructuring'
