"""
Granular Eval – ABFL Sanction Format (132 columns)
Checks: fill rate, nulls, duplicates, ranges, enum validity,
        PAN format, CIBIL range, LTV sanity, DPD format, age, FOIR.
"""
import re
import yaml
import redshift_connector
import pandas as pd
from pathlib import Path
from datetime import datetime

ROOT     = Path(__file__).resolve().parents[1]
ABFL_DIR = ROOT / "ABFL_Formats"
SQL_FILE = ABFL_DIR / "sql_abfl_sanction_format.sql"
CFG_FILE = ROOT / "config" / "database.yaml"

cfg = yaml.safe_load(CFG_FILE.read_text())["database"]
conn = redshift_connector.connect(
    host=cfg["host"], port=int(cfg.get("port", 5439)),
    database=cfg["database"], user=cfg["user"],
    password=cfg["password"], timeout=300
)

# ── load LANs ────────────────────────────────────────────────────────────────
src = ABFL_DIR / "Pool Upload Format - Final_.xlsm"
raw = pd.read_excel(src, sheet_name="Deal and Loan data", header=None, engine="openpyxl")
best_row = max(range(min(10, len(raw))), key=lambda i: raw.iloc[i].notna().sum())
df_src = pd.read_excel(src, sheet_name="Deal and Loan data", header=best_row, engine="openpyxl")
loan_col = next((c for c in df_src.columns if "application form" in str(c).lower()), df_src.columns[0])
lans = df_src[loan_col].dropna().astype(str).str.strip()
lans = lans[lans.str.match(r"^\d{10,}$")].unique().tolist()
lan_str = "'" + "','".join(lans) + "'"
print(f"LANs loaded: {len(lans)}")

# ── run SQL ──────────────────────────────────────────────────────────────────
sql_raw   = SQL_FILE.read_text(encoding="utf-8")
sql_body  = sql_raw.split("\n\n\n-- ===")[0].strip()
sql_final = sql_body.replace("{LAN_LIST}", lan_str)

cur = conn.cursor()
cur.execute(sql_final)
cols = [d[0] for d in cur.description]
rows = cur.fetchall()
conn.close()

df = pd.DataFrame(rows, columns=cols)
print(f"Result: {len(df)} rows x {len(df.columns)} columns\n")

# ── helper to get column by partial match ────────────────────────────────────
def gcol(substr):
    substr = substr.lower()
    matches = [c for c in df.columns if substr in c.lower()]
    return matches[0] if matches else None

# ── collect results ──────────────────────────────────────────────────────────
results = []

def check(col_no, col_name, check_name, passed, detail=""):
    status = "PASS" if passed else "FAIL"
    results.append({
        "Col#": col_no,
        "Column": col_name[:50],
        "Check": check_name,
        "Status": status,
        "Detail": detail
    })

N = len(df)

# ── 1. FILL RATE per column ──────────────────────────────────────────────────
NOT_FOUND_COLS = {
    "Subvention Scheme if any",
    "NRI Loan (Yes/No)",
    "ECLGS",
    "Link loan Part of pool (Yes/ No)",
    "Link Loan/Top up loan Number if applicable",
    "Legal Report ",
}

for i, c in enumerate(df.columns, 1):
    col_data = df.iloc[:, i - 1]
    filled   = col_data.notna().sum()
    pct      = round(filled / N * 100, 1)
    if c in NOT_FOUND_COLS:
        check(i, c, "Fill Rate", True, f"N/A (no DB source) - {filled}/{N} filled")
    else:
        check(i, c, "Fill Rate", filled > 0, f"{filled}/{N} ({pct}%)")

# ── 2. DUPLICATE Loan No. ────────────────────────────────────────────────────
loan_col_df = gcol("loan no")
if loan_col_df:
    dups = df[loan_col_df].duplicated().sum()
    check(2, "Loan No.", "No Duplicates", dups == 0, f"{dups} duplicates")

# ── 3. PAN FORMAT (all PAN columns) ─────────────────────────────────────────
pan_cols = [(i+1, c) for i, c in enumerate(df.columns)
            if "pan" in c.lower() and "number" in c.lower()]
for col_no, c in pan_cols:
    col_data = df.iloc[:, col_no - 1].dropna().astype(str).str.strip()
    if len(col_data) == 0:
        continue
    invalid = col_data[~col_data.str.match(r"^[A-Z]{5}[0-9]{4}[A-Z]$")]
    check(col_no, c, "PAN Format (XXXXX9999X)", len(invalid) == 0,
          f"{len(invalid)} invalid PANs" + (f": {invalid.head(3).tolist()}" if len(invalid) > 0 else ""))

# ── 4. CIBIL SCORE RANGE (300-900) ──────────────────────────────────────────
for substr, col_no in [("originated cibil", 106), ("current cibil", 107)]:
    c = gcol(substr)
    if c:
        scores = pd.to_numeric(df[c], errors="coerce").dropna()
        out_of_range = scores[(scores < 300) | (scores > 900)]
        check(col_no, c, "CIBIL Range (300-900)", len(out_of_range) == 0,
              f"{len(scores)} valid, {df[c].isna().sum()} null, {len(out_of_range)} out of range")

# ── 5. CURRENT ROI (1-40%) ──────────────────────────────────────────────────
c = gcol("current roi")
if c:
    roi = pd.to_numeric(df[c], errors="coerce").dropna()
    bad = roi[(roi < 1) | (roi > 40)]
    check(81, c, "ROI Range (1-40%)", len(bad) == 0,
          f"min={roi.min():.2f}, max={roi.max():.2f}, bad={len(bad)}")

# ── 6. CURRENT LTV (0-150%) ─────────────────────────────────────────────────
c = gcol("current ltv")
if c:
    ltv = pd.to_numeric(df[c], errors="coerce").dropna()
    bad = ltv[(ltv < 0) | (ltv > 150)]
    check(91, c, "Current LTV Range (0-150%)", len(bad) == 0,
          f"min={ltv.min():.1f}, max={ltv.max():.1f}, bad={len(bad)}")

# ── 7. SANCTION LTV (0-100%) ────────────────────────────────────────────────
c = gcol("time of original sanction")
if c:
    ltv2 = pd.to_numeric(df[c], errors="coerce").dropna()
    bad2 = ltv2[(ltv2 < 0) | (ltv2 > 100)]
    check(92, c, "Sanction LTV Range (0-100%)", len(bad2) == 0,
          f"min={ltv2.min():.1f}, max={ltv2.max():.1f}, bad={len(bad2)}")

# ── 8. SANCTION AMOUNT > 0 ──────────────────────────────────────────────────
c = gcol("sanctioned amount")
if c:
    amt = pd.to_numeric(df[c], errors="coerce")
    bad = (amt <= 0).sum()
    check(76, c, "Sanction Amount > 0", bad == 0,
          f"min={amt.min():,.0f}, max={amt.max():,.0f}, zero/neg={bad}")

# ── 9. PRINCIPAL O/S >= 0 ───────────────────────────────────────────────────
c = gcol("principal o/s")
if c:
    pos = pd.to_numeric(df[c], errors="coerce")
    neg = (pos < 0).sum()
    check(82, c, "Principal O/s >= 0", neg == 0,
          f"min={pos.min():,.0f}, max={pos.max():,.0f}, negative={neg}")

# ── 10. DISBURSED <= SANCTIONED ─────────────────────────────────────────────
c_disb = gcol("disbursed amount")
c_sanc = gcol("sanctioned amount")
if c_disb and c_sanc:
    disb = pd.to_numeric(df[c_disb], errors="coerce")
    sanc = pd.to_numeric(df[c_sanc], errors="coerce")
    over = (disb > sanc * 1.05).sum()
    check(77, "Disbursed vs Sanctioned", "Disbursed <= Sanctioned (+5%)", over == 0,
          f"{over} loans where disbursed > sanctioned + 5%")

# ── 11. BALANCE TENURE <= SANCTIONED TENURE ─────────────────────────────────
c_bal = gcol("balance tenure")
c_ten = gcol("sanctioned tenure")
if c_bal and c_ten:
    bal = pd.to_numeric(df[c_bal], errors="coerce")
    ten = pd.to_numeric(df[c_ten], errors="coerce")
    bad = (bal > ten).sum()
    check(79, "Balance vs Sanction Tenure", "Balance <= Sanctioned Tenure", bad == 0,
          f"{bad} loans with balance tenure > sanctioned tenure")

# ── 12. FINANCIAL APPLICANT AGE (18-80) ─────────────────────────────────────
c = gcol("financial applicant age")
if c:
    age = pd.to_numeric(df[c], errors="coerce").dropna()
    bad = age[(age < 18) | (age > 80)]
    check(127, c, "Age Range (18-80 yrs)", len(bad) == 0,
          f"min={age.min():.0f}, max={age.max():.0f}, out-of-range={len(bad)}")

# ── 13. FOIR RANGE (0-1) ────────────────────────────────────────────────────
c = gcol("foir")
if c:
    foir = pd.to_numeric(df[c], errors="coerce").dropna()
    bad  = foir[(foir <= 0) | (foir > 1)]
    check(128, c, "FOIR Range (0-1)", len(bad) == 0,
          f"min={foir.min():.4f}, max={foir.max():.4f}, out-of-range={len(bad)}")

# ── 14. ANNUAL INCOME > 0 ───────────────────────────────────────────────────
c = gcol("annual income")
if c:
    inc = pd.to_numeric(df[c], errors="coerce")
    bad = (inc <= 0).sum()
    check(129, c, "Annual Income > 0", bad == 0,
          f"min={inc.min():,.0f}, max={inc.max():,.0f}, zero/neg={bad}")

# ── 15. BOUNCE STRING FORMAT ─────────────────────────────────────────────────
c = gcol("bounce dpd string for last 12")
if c:
    vals = df[c].dropna().astype(str)
    bad  = vals[~vals.str.match(r"^[BC](-[BC])*$")]
    check(123, c, "Bounce String Format (B/C pattern)", len(bad) == 0,
          f"{len(vals)} non-null, {len(bad)} malformed")

c2 = gcol("gross bounce string")
if c2:
    vals2 = df[c2].dropna().astype(str)
    bad2  = vals2[~vals2.str.match(r"^[BC](-[BC])*$")]
    check(124, c2, "Bounce String Format (B/C pattern)", len(bad2) == 0,
          f"{len(vals2)} non-null, {len(bad2)} malformed")

# ── 16. MAX DPD >= 0 ────────────────────────────────────────────────────────
c = gcol("max ever dpd")
if c:
    dpd = pd.to_numeric(df[c], errors="coerce").dropna()
    bad = (dpd < 0).sum()
    check(126, c, "Max DPD >= 0", bad == 0,
          f"min={dpd.min():.0f}, max={dpd.max():.0f}, negative={bad}")

# ── 17. OVERDUE PRINCIPAL >= 0 ──────────────────────────────────────────────
c = gcol("overdue amt")
if c:
    od = pd.to_numeric(df[c], errors="coerce")
    neg = (od < 0).sum()
    check(83, c, "Overdue Amt >= 0", neg == 0,
          f"min={od.min():,.0f}, max={od.max():,.0f}, negative={neg}")

# ── 18. GENDER ENUM ──────────────────────────────────────────────────────────
c = gcol("gender for primary")
if c:
    vals = df[c].dropna().astype(str).str.upper().str.strip()
    bad = vals[~vals.isin({"M", "F", "O", "MALE", "FEMALE", "OTHER"})]
    check(7, c, "Gender Enum (M/F/O)", len(bad) == 0,
          f"values: {vals.value_counts().to_dict()}")

# ── 19. FULLY DISBURSED ENUM ─────────────────────────────────────────────────
c = gcol("fully disbursed")
if c:
    vals = df[c].dropna().astype(str).str.strip()
    bad  = vals[~vals.isin({"Yes", "No", "YES", "NO", "Y", "N"})]
    check(74, c, "Fully Disbursed (Yes/No)", len(bad) == 0,
          f"values: {vals.value_counts().to_dict()}")

# ── 20. RESTRUCTURED FLAG ENUM ───────────────────────────────────────────────
c = gcol("restructured flag")
if c:
    vals = df[c].dropna().astype(str).str.strip()
    bad  = vals[~vals.isin({"Yes", "No", "YES", "NO", "Y", "N"})]
    check(115, c, "Restructured Flag (Yes/No)", len(bad) == 0,
          f"values: {vals.value_counts().to_dict()}")

# ── 21. NPA FLAG ENUM ────────────────────────────────────────────────────────
c = gcol("loan became npa")
if c:
    vals = df[c].dropna().astype(str).str.strip()
    bad  = vals[~vals.isin({"Y", "N", "Yes", "No", "YES", "NO"})]
    check(119, c, "NPA Flag (Y/N)", len(bad) == 0,
          f"values: {vals.value_counts().to_dict()}")

# ── 22. PDD COMPLETE ENUM ────────────────────────────────────────────────────
c = gcol("pdd status complete")
if c:
    vals = df[c].dropna().astype(str).str.strip()
    bad  = vals[~vals.isin({"Y", "N"})]
    check(108, c, "PDD Complete (Y/N)", len(bad) == 0,
          f"values: {vals.value_counts().to_dict()}")

# ── 23. PMAY FLAG = 'N' for all HE ──────────────────────────────────────────
c = gcol("pmay flag")
if c:
    non_n = (df[c].astype(str).str.strip() != "N").sum()
    check(111, c, "PMAY Flag = 'N' (all HE)", non_n == 0,
          f"{non_n} rows not 'N'")

# ── 24. SANCTION DATE valid ──────────────────────────────────────────────────
c = gcol("sanctioned date")
if c:
    dates = pd.to_datetime(df[c], errors="coerce")
    future = (dates > pd.Timestamp("today")).sum()
    old    = (dates < pd.Timestamp("2010-01-01")).sum()
    check(71, c, "Sanction Date (2010-today)", future == 0 and old == 0,
          f"future={future}, before-2010={old}, null={dates.isna().sum()}")

# ── 25. FIRST DISBURSEMENT <= LAST DISBURSEMENT ──────────────────────────────
c_first = gcol("first disbursement")
c_last  = gcol("last disbursement")
if c_first and c_last:
    d1 = pd.to_datetime(df[c_first], errors="coerce")
    d2 = pd.to_datetime(df[c_last],  errors="coerce")
    bad = (d1 > d2).sum()
    check(72, "Disbursement Dates", "First Disb <= Last Disb", bad == 0,
          f"{bad} loans where first disb > last disb")

# ── 26. COLLATERAL VALUE > 0 ─────────────────────────────────────────────────
c = gcol("collateral  value")
if c:
    cv = pd.to_numeric(df[c], errors="coerce")
    bad = (cv <= 0).sum()
    check(98, c, "Collateral Value > 0", bad == 0,
          f"min={cv.min():,.0f}, max={cv.max():,.0f}, zero/neg={bad}")

# ── 27. CURRENT EMI > 0 ──────────────────────────────────────────────────────
c = gcol("current emi")
if c:
    emi = pd.to_numeric(df[c], errors="coerce")
    bad = (emi <= 0).sum()
    check(89, c, "Current EMI > 0", bad == 0,
          f"min={emi.min():,.0f}, max={emi.max():,.0f}, zero/neg={bad}")

# ── 28. PRIMARY APPLICANT NAME not null ──────────────────────────────────────
c = gcol("customer name (primary")
if c:
    nulls = df[c].isna().sum()
    check(6, c, "Primary Applicant Name not null", nulls == 0, f"{nulls} nulls")

# ── 29. PINCODE FORMAT (6-digit) ─────────────────────────────────────────────
c = gcol("zip code")
if c:
    pins = df[c].dropna().astype(str).str.strip()
    bad  = pins[~pins.str.match(r"^\d{6}$")]
    check(18, c, "Pincode Format (6 digits)", len(bad) == 0,
          f"{len(bad)} invalid: {bad.head(3).tolist()}")

c2 = gcol("pincode of property")
if c2:
    pins2 = df[c2].dropna().astype(str).str.strip()
    bad2  = pins2[~pins2.str.match(r"^\d{6}$")]
    check(103, c2, "Property Pincode Format (6 digits)", len(bad2) == 0,
          f"{len(bad2)} invalid: {bad2.head(3).tolist()}")

# ── 30. UNDER CONSTRUCTION FLAG ENUM ─────────────────────────────────────────
c = gcol("under construction")
if c:
    vals = df[c].dropna().astype(str).str.strip().str.upper()
    bad  = vals[~vals.isin({"Y", "N", "YES", "NO"})]
    check(96, c, "Under Construction (Y/N)", len(bad) == 0,
          f"values: {vals.value_counts().to_dict()}")

# ── 31. CERSAI ID fill rate ───────────────────────────────────────────────────
c = gcol("cersai id")
if c:
    filled = df[c].notna().sum()
    check(131, c, "CERSAI ID fill rate (>=85%)", filled >= int(N * 0.85),
          f"{filled}/{N} ({filled/N*100:.1f}%) filled")

# ── 32. BOUNCE COVERAGE ───────────────────────────────────────────────────────
c = gcol("gross bounce string")
if c:
    filled = df[c].notna().sum()
    check(124, c, "Bounce String (inception) coverage (>=80%)", filled >= int(N * 0.80),
          f"{filled}/{N} ({filled/N*100:.1f}%) filled")

# ── print report ──────────────────────────────────────────────────────────────
rdf = pd.DataFrame(results)
pass_c = (rdf["Status"] == "PASS").sum()
fail_c = (rdf["Status"] == "FAIL").sum()

print("=" * 90)
print(f"GRANULAR EVAL REPORT  --  {datetime.now().strftime('%Y-%m-%d %H:%M')}")
print(f"Total checks: {len(rdf)}  |  PASS: {pass_c}  |  FAIL: {fail_c}")
print("=" * 90)

for status in ["FAIL", "PASS"]:
    subset = rdf[rdf["Status"] == status]
    if subset.empty:
        continue
    print(f"\n{'='*40} {status} {'='*40}")
    for _, row in subset.iterrows():
        print(f"  [Col{row['Col#']:03d}] {row['Column'][:45]:<45}  |  {row['Check']:<40}  |  {row['Detail']}")

ts = datetime.now().strftime("%Y%m%d_%H%M%S")
out = ABFL_DIR / f"eval_sanction_granular_{ts}.xlsx"
rdf.to_excel(out, index=False)
print(f"\nEval saved to: {out}")

import os
try:
    os.startfile(str(out))
except Exception:
    pass
