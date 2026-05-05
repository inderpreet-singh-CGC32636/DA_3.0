# DA 3.0 — Direct Assignment Pool Selection Pipeline

Python-based eligibility pipeline for Bajaj Finance and ABFL DA pool selection across two loan segments: **Home Equity (HE / HFLA)** and **MSME**.

---

## Repository Structure

```
├── run_he_v4.py              # HE pipeline — Bajaj + ABFL filters & eligibility
├── run_msme_v4.py            # MSME pipeline — Bajaj + ABFL filters & eligibility
└── sql/
    ├── simple_he_eligible.sql        # Base HE loan universe
    ├── he_assets.sql                 # HE collateral / property data
    ├── he_dpd_history.sql            # Full HE DPD history (Peak DPD derived inline)
    ├── he_bounce.sql                 # HE bounce history
    ├── simple_msme_eligible.sql      # Base MSME loan universe
    ├── msme_assets.sql               # MSME collateral / property data
    ├── msme_dpd_history.sql          # Full MSME DPD history (Peak DPD derived inline)
    ├── msme_bounce.sql               # MSME bounce history
    ├── restructure.sql               # Restructure / NPA flags (shared)
    └── abhfl_serviceable.sql         # ABFL serviceable pincode list (shared)
```

---

## Pipeline Stages

| Stage | Description |
|---|---|
| 1 — Load | Pull base loans + assets + DPD history + bounce + restructure + pincode from Redshift |
| 2 — Derive | Calculate `MOB`, `SEASONING_DAYS`, `PEAK_DPD_EVER`, `BOUNCE_COUNT`, `LTV_ORIGINATION`, `CALCULATED_LTV`, `AGE_CURRENT`, `AGE_AT_MATURITY`, `PROFILE_TYPE`, property fields |
| 3a — Bajaj filters | Apply all Bajaj hard filters in sequence; record first rejection reason per loan |
| 3b — ABFL filters | Apply all ABFL hard filters in sequence; record first rejection reason per loan |
| 4 — Eligibility | Layer CIBIL score thresholds (700 / 675) + UDYAM flag on hard-filter-passing loans |
| 5 — Output | Write CSV with all flags, rejection reasons, and eligibility columns |

---

## Output Columns

### Hard Filter Pass (pre-CIBIL)

| Column | Meaning |
|---|---|
| `BAJAJ_HARD_FILTER_PASS` | Passed all Bajaj hard filters (CIBIL not yet applied) |
| `ABFL_HARD_FILTER_PASS` | Passed all ABFL hard filters (CIBIL not yet applied) |

### Eligibility Flags (hard filters + CIBIL threshold)

| Column | Threshold |
|---|---|
| `ELIGIBLE_BAJAJ_700` | Bajaj hard pass + CIBIL ≥ 700 |
| `ELIGIBLE_BAJAJ_675` | Bajaj hard pass + CIBIL ≥ 675 |
| `ELIGIBLE_BAJAJ_700_WITH_UDYAM` | Bajaj ≥ 700 + UDYAM registered |
| `ELIGIBLE_BAJAJ_700_NO_UDYAM` | Bajaj ≥ 700 + no UDYAM |
| `ELIGIBLE_BAJAJ_675_WITH_UDYAM` | Bajaj ≥ 675 + UDYAM registered |
| `ELIGIBLE_BAJAJ_675_NO_UDYAM` | Bajaj ≥ 675 + no UDYAM |
| `ELIGIBLE_ABFL_700` | ABFL hard pass + CIBIL ≥ 700 |
| `ELIGIBLE_ABFL_675` | ABFL hard pass + CIBIL ≥ 675 |

All flag columns use `"Eligible"` / `"Ineligible"` strings.

---

## Key Filter Logic Notes

- **Peak DPD** is derived inline from full DPD history — no separate `dpd_ever.sql` needed.
- **LTV** for ABFL filters uses `LTV_ORIGINATION` (`ltv_wo_insurance`) — not current/calculated LTV.
- **ABFL Age at Maturity**: only `SALARIED` (≤ 60) and `SENP` / `NULL` profile (≤ 70) pass; `OTHER` profile is rejected.
- **MOB / SEASONING** anchored to `CERSAI_DATE` (first disbursement date).
- **NHB check** (MSME ABFL): pattern match `NOT LIKE '%NHB%'` — consistent with SQL reference.

---

## Configuration

Redshift connection details are read from environment variables or a local config. Set the following before running:

```
RS_HOST, RS_PORT, RS_DB, RS_USER, RS_PASSWORD
```

---

## Running

```bash
python run_he_v4.py      # Home Equity
python run_msme_v4.py    # MSME
```

Output CSVs are written to `output/he_v4/` and `output/msme_v4/` with a datestamp suffix.

---

## Reference

Validated against unified SQL handover queries:
- `unified_da_pool_selection_v3.sql` (HE)
- `unified_da_pool_selection_msme_v3.sql` (MSME)
