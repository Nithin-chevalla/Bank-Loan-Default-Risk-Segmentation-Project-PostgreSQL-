# 🏦 Lending Club — Loan Default Risk Segmentation Framework

<div align="center">

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-336791?style=for-the-badge&logo=postgresql&logoColor=white)
![SQL](https://img.shields.io/badge/SQL-Advanced-4479A1?style=for-the-badge&logo=databricks&logoColor=white)
![Dataset](https://img.shields.io/badge/Dataset-10K_Loans-10b981?style=for-the-badge&logo=files&logoColor=white)
![Status](https://img.shields.io/badge/Status-Complete-brightgreen?style=for-the-badge)

A production-grade **PostgreSQL analytics pipeline** for loan default risk segmentation, interest rate adequacy modelling, and composite borrower risk scoring — built on 10,000 Lending Club loan records.

[Overview](#-overview) · [Pipeline](#-pipeline) · [Schema](#-schema) · [Metrics](#-key-metrics) · [Functions](#-stored-functions--procedures) · [Quick Start](#-quick-start) · [Design Notes](#-design-decisions)

</div>

---

## 📌 Overview

This project implements an end-to-end credit risk framework across **19 sequential SQL steps**, answering three core questions:

| Question | Approach |
|---|---|
| Which borrower segments default most? | Grade, purpose, DTI band, income tier, employment, geography |
| Is the lender charging enough for the risk? | Expected Loss model · LGD = 70% · Pricing gap per grade |
| Who are the highest compound-risk borrowers? | 7-factor additive composite risk score (max ≈ 17 pts) |

### Dataset

| Attribute | Detail |
|---|---|
| **File** | `lending_club_10k.csv` |
| **Records** | 10,000 loans |
| **Features** | 21 columns |
| **Target** | `is_default` (binary: 0 = performing · 1 = defaulted) |
| **Database** | PostgreSQL 14+ |
| **Data Source** | Claude.ai & Kaggle |

---

## 🔄 Pipeline

```
Step 0  ──▶  Schema Setup & Indexes
Step 1  ──▶  Data Load (COPY from CSV)
Step 2  ──▶  EDA & Portfolio Snapshot
Step 3  ──▶  CASE Bucketing (DTI / Loan / Income Tiers)
Step 4  ──▶  Risk by Grade (A–G)
Step 5  ──▶  Risk by Loan Purpose
Step 6  ──▶  Risk by Employment Length
Step 7  ──▶  Risk by DTI Band
Step 8  ──▶  Cross-Dimensional: Grade × Purpose
Step 9  ──▶  CUBE: Grade × DTI Band × Term
Step 10 ──▶  ROLLUP: Purpose → Grade Hierarchy
Step 11 ──▶  Interest Rate Adequacy Analysis
Step 12 ──▶  Composite Risk Score (7 Factors)
Step 13 ──▶  Function: calculate_grade_risk_metrics()
Step 14 ──▶  Function: get_segment_risk_profile()
Step 15 ──▶  Procedure: build_risk_segment_cache()
Step 16 ──▶  Window Functions: Sub-grade Ranking
Step 17 ──▶  Rate Fairness by Income Tier
Step 18 ──▶  State-Level Risk Heatmap
Step 19 ──▶  Executive Summary View
```

> **Dependency note:** Step 3 (CASE bucketing) must run before Steps 7, 9, 15, and 17 which reference the derived columns. All other steps are independent after schema + data load.

---

## 🗄 Schema

### Primary Table — `loans`

| Column | Type | Description |
|---|---|---|
| `loan_id` | `VARCHAR(10)` | Primary key |
| `loan_amnt` | `NUMERIC(10,2)` | Funded amount (USD) |
| `term` | `SMALLINT` | 36 or 60 months |
| `int_rate` | `NUMERIC(5,2)` | Annual interest rate (%) |
| `installment` | `NUMERIC(10,2)` | Monthly payment |
| `grade` | `CHAR(1)` | Credit grade A–G |
| `sub_grade` | `VARCHAR(3)` | Sub-grade (e.g. B3) |
| `emp_length` | `VARCHAR(15)` | Employment tenure |
| `home_ownership` | `VARCHAR(10)` | RENT / OWN / MORTGAGE |
| `annual_inc` | `NUMERIC(12,2)` | Self-reported income |
| `loan_status` | `VARCHAR(30)` | Lending Club status string |
| `purpose` | `VARCHAR(30)` | Stated loan purpose |
| `dti` | `NUMERIC(5,2)` | Debt-to-income ratio (%) |
| `delinq_2yrs` | `SMALLINT` | Delinquencies (past 2 yrs) |
| `open_acc` | `SMALLINT` | Open credit accounts |
| `pub_rec` | `SMALLINT` | Public derogatory records |
| `revol_util` | `NUMERIC(5,1)` | Revolving utilisation (%) |
| `total_acc` | `SMALLINT` | Total credit lines |
| `addr_state` | `CHAR(2)` | US state code |
| `issue_d` | `DATE` | Origination date |
| `is_default` | `SMALLINT` | **Target: 1 = default · 0 = performing** |
| `dti_band` ⭐ | `VARCHAR(20)` | Derived — DTI bucket (Step 3) |
| `loan_tier` ⭐ | `VARCHAR(20)` | Derived — loan amount tier (Step 3) |
| `income_tier` ⭐ | `VARCHAR(20)` | Derived — annual income tier (Step 3) |

> ⭐ Derived columns are added and populated by Step 3 (CASE bucketing).

### Indexes

```sql
CREATE INDEX idx_loans_grade       ON loans(grade);
CREATE INDEX idx_loans_purpose     ON loans(purpose);
CREATE INDEX idx_loans_emp_length  ON loans(emp_length);
CREATE INDEX idx_loans_is_default  ON loans(is_default);
CREATE INDEX idx_loans_dti         ON loans(dti);
```

### Cache Table — `risk_segment_cache`

Materialised by `build_risk_segment_cache()`. Stores pre-computed segment statistics across 5 dimensions for fast dashboard queries without re-scanning the loans table.

---

## 📊 CASE Bucketing Bands

### DTI Band (`dti_band`)

| Band | DTI Range |
|---|---|
| `01_Low (0-10)` | DTI < 10 |
| `02_Moderate (10-20)` | 10 ≤ DTI < 20 |
| `03_High (20-30)` | 20 ≤ DTI < 30 |
| `04_Very High (30-40)` | 30 ≤ DTI < 40 |
| `05_Extreme (40+)` | DTI ≥ 40 |

> Ordinal prefixes (`01_`, `02_` …) ensure alphabetical `ORDER BY` produces numerically correct sequence — no `CASE` in the `ORDER BY` clause needed.

### Income Tier (`income_tier`) · Loan Tier (`loan_tier`)

Similar 5-band structure applied to `annual_inc` (<30K → 150K+) and `loan_amnt` (Micro <7.5K → Jumbo 35K+).

---

## 📐 Key Metrics

| Metric | Formula | Interpretation |
|---|---|---|
| **Default Rate (%)** | `SUM(is_default) / COUNT(*) × 100` | Percentage of loans that defaulted in a segment |
| **Risk Ratio** | `Segment DR / Benchmark DR` | How many times riskier vs benchmark (Grade A / Low DTI) |
| **Expected Loss (%)** | `Default Rate × 0.70` | Estimated loss per $100 lent (LGD = 70%) |
| **Required Min Rate** | `EL + 5%` | Break-even rate (cost of funds 3% + ops 2%) |
| **Pricing Gap** | `Avg Int Rate − Required Min Rate` | ✅ Positive = margin cushion · ⚠️ Negative = uncompensated risk |
| **Composite Risk Score** | `Σ 7 factor scores (max ≈ 17)` | <3 Low · 3–4 Moderate · 5–6 High · 7–9 Very High · ≥10 Extreme |
| **Rate per Unit Risk** | `Avg Int Rate / Default Rate` | Higher = borrower pays disproportionately vs actual default risk |
| **At-Risk Exposure ($)** | `SUM(loan_amnt) WHERE is_default=1` | Dollar value of defaulted loans in a segment |

---

## ⚖️ Interest Rate Adequacy

```
Expected Loss (EL)   = Default Rate (%) × LGD (0.70)
Required Minimum Rate = EL + 3% cost of funds + 2% operating cost
Pricing Gap          = Avg Interest Rate − Required Minimum Rate
```

| Verdict | Condition |
|---|---|
| 🟢 **ADEQUATELY PRICED** | `avg_int_rate ≥ EL + 7.0` |
| 🟡 **MARGINALLY PRICED** | `EL + 5.0 ≤ avg_int_rate < EL + 7.0` |
| 🔴 **UNDERPRICED** | `avg_int_rate < EL + 5.0` — lender bears uncompensated risk |

---

## 🧮 Composite Risk Score

Seven additive factors, stacked to identify compound-risk borrowers:

| Factor | Max Points | Rule |
|---|---|---|
| Credit Grade | 6 | A/B=1 · C=2 · D=3 · E=4 · F=5 · G=6 |
| DTI | 3 | >35=3 · >25=2 · >15=1 · else 0 |
| Delinquencies (2yr) | 2 | ≥2=2 · =1=1 · else 0 |
| Public Records | 2 | ≥1=2 · else 0 |
| Revolving Utilisation | 2 | >80%=2 · >60%=1 · else 0 |
| Employment Tenure | 1 | <1yr or 1yr = 1 · else 0 |
| Loan Purpose | 1 | `small_business` / `vacation` / `moving` = 1 |

**Risk Tiers:** `LOW (<3)` · `MODERATE (3–4)` · `HIGH (5–6)` · `VERY HIGH (7–9)` · `EXTREME (≥10)`

---

## 🔧 Stored Functions & Procedures

### `calculate_grade_risk_metrics(p_grade)`

Returns full risk metrics for one grade or all grades.

```sql
-- All grades
SELECT * FROM calculate_grade_risk_metrics();

-- Grade D only
SELECT * FROM calculate_grade_risk_metrics('D');
```

**Returns:** `grade, total_loans, default_count, default_rate_pct, avg_int_rate, avg_dti, total_exposure, expected_loss, pricing_gap, pricing_status`

---

### `get_segment_risk_profile(grade, purpose, emp_length, dti_min, dti_max)`

Parameterised risk profile for any borrower segment. All parameters optional.

```sql
-- Grade E · small_business · DTI 25–45
SELECT * FROM get_segment_risk_profile('E', 'small_business', NULL, 25, 45);

-- All loans with DTI 30–45 (named params)
SELECT * FROM get_segment_risk_profile(p_dti_min => 30, p_dti_max => 45);
```

---

### `build_risk_segment_cache()` — Stored Procedure

Truncates and rebuilds `risk_segment_cache` across 5 dimensions. Designed for scheduled refresh via `pg_cron`.

```sql
CALL build_risk_segment_cache();

-- Query the cache
SELECT * FROM risk_segment_cache
ORDER BY dimension, default_rate_pct DESC;
```

**Segments materialised:** Grade · Purpose · DTI Band · Employment Length · Income Tier

---

### `v_risk_executive_summary` — View

Single-row portfolio dashboard. No storage cost.

```sql
SELECT * FROM v_risk_executive_summary;
```

**Returns:** total loans · portfolio value · overall default rate · total defaulted value · high-risk loan count & exposure · high-risk % of portfolio · underpriced grade count · loss rate %

---

## 🚀 Quick Start

### Prerequisites

- PostgreSQL 14+
- `psql` CLI or compatible GUI (pgAdmin, DBeaver, TablePlus)
- `lending_club_10k.csv` at a known absolute path

### Run

```bash
# 1. Create the database
createdb lending_club

# 2. Connect
psql -d lending_club

# 3. Run the script (Steps 0–19)
\i /path/to/lending_club_risk_framework.sql

# 4. Load data (update path)
\COPY loans FROM '/absolute/path/to/lending_club_10k.csv' CSV HEADER;

# 5. Populate the segment cache
CALL build_risk_segment_cache();

# 6. Run the executive summary
SELECT * FROM v_risk_executive_summary;
```

> If running the SQL file without `\i`, execute each numbered step block sequentially in your SQL client. Step 3 must precede Steps 7, 9, 15, and 17.

---

## 🏗 Project Structure

```
lending_club/
├── lending_club_risk_framework.sql   # Full 19-step pipeline
├── lending_club_10k.csv              # Source dataset (10K loans)
└── README.md                         # This file
```

---

## 🎯 Design Decisions

**LGD = 70%**
Applied uniformly as an industry rule-of-thumb for unsecured consumer lending. Isolated in the formula so it can be updated in one place across all steps.

**Minimum cell size filters**
`HAVING COUNT(*) >= 10` (cross-dimensional), `>= 15` (window ranking), `>= 50` (state heatmap) — suppresses high-variance estimates from thin segments.

**CUBE vs ROLLUP**
`CUBE` for `Grade × DTI Band × Term` because all three are peer-level dimensions. `ROLLUP` for `Purpose → Grade` because it models a logical containment hierarchy (Purpose is the parent dimension).

**PROCEDURE vs FUNCTION**
`build_risk_segment_cache()` is a `PROCEDURE` (invoked with `CALL`) because it performs DML (`DELETE` + `INSERT`). The two analytics routines are `FUNCTION`s (invoked with `SELECT`) because they only read data and return result sets.

**Composite score calibration**
Tier boundaries (3, 5, 7, 10) are heuristic thresholds tuned on this dataset. Recalibrate if applying to a materially different loan population or if default rate distributions shift.

---

## 📄 License

This project is released for educational and analytical purposes. The Lending Club dataset is publicly available.
