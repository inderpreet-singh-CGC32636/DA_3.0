# DA 3.0 — Direct Assignment Pool Selection Pipeline

Python-based eligibility pipeline for Bajaj Finance and ABFL DA pool selection across two loan segments: **Home Equity (HE / HFLA)** and **MSME**.

---

## Repository Structure

```
├── run_he_final.py           # HE pipeline — production ready
├── run_msme_final.py         # MSME pipeline — production ready
├── archive/
│   ├── run_he_v4.py          # HE v4 — with #%% cell markers
│   └── run_msme_v4.py        # MSME v4 — with #%% cell markers
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

```
Stage 1  Load    : simple_he_eligible + he_assets + he_dpd_history + he_bounce + restructure + abhfl_serviceable
Stage 2  Derive  : age, MOB, CIBIL, LTV, DPD flags, bounce counts, profile, seasoning
Stage 3a Bajaj   : hard filters → BAJAJ_HARD_FILTER_PASS
Stage 3b ABFL    : hard filters → ABFL_HARD_FILTER_PASS
Stage 4  Eligible: CIBIL cutoff + Udyam split → ELIGIBLE_* columns
Stage 5  Output  : CSV with all flags and rejection reasons
```

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
python run_he_final.py      # Home Equity
python run_msme_final.py    # MSME
```

Output CSVs are written to `output/he_final/` and `output/msme_final/` with a datestamp suffix.

---

## Reference

Validated against unified SQL handover queries:
- `unified_da_pool_selection_v3.sql` (HE)
- `unified_da_pool_selection_msme_v3.sql` (MSME)
