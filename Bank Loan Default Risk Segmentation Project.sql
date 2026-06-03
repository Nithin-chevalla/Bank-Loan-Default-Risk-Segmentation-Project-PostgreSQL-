CREATE TABLE loans (
    loan_id         VARCHAR(10)     PRIMARY KEY,
    loan_amnt       NUMERIC(10,2)   NOT NULL,
    term            SMALLINT        NOT NULL,   -- 36 or 60 months
    int_rate        NUMERIC(5,2)    NOT NULL,
    installment     NUMERIC(10,2)   NOT NULL,
    grade           CHAR(1)         NOT NULL,
    sub_grade       VARCHAR(3)      NOT NULL,
    emp_length      VARCHAR(15),
    home_ownership  VARCHAR(10),
    annual_inc      NUMERIC(12,2),
    loan_status     VARCHAR(30),
    purpose         VARCHAR(30),
    dti             NUMERIC(5,2),
    delinq_2yrs     SMALLINT        DEFAULT 0,
    open_acc        SMALLINT,
    pub_rec         SMALLINT        DEFAULT 0,
    revol_util      NUMERIC(5,1),
    total_acc       SMALLINT,
    addr_state      CHAR(2),
    issue_d         DATE,
    is_default      SMALLINT        NOT NULL CHECK (is_default IN (0,1))
);
CREATE INDEX idx_loans_grade       ON loans(grade);
CREATE INDEX idx_loans_purpose     ON loans(purpose);
CREATE INDEX idx_loans_emp_length  ON loans(emp_length);
CREATE INDEX idx_loans_is_default  ON loans(is_default);
CREATE INDEX idx_loans_dti         ON loans(dti);
select * from loans
-- STEP 2: DATA QUALITY & EXPLORATORY OVERVIEW
SELECT
    COUNT(*)                            AS total_loans,
    SUM(loan_amnt)                      AS total_portfolio_value,
    ROUND(AVG(loan_amnt),2)             AS avg_loan_size,
    ROUND(AVG(int_rate),2)              AS avg_interest_rate,
    ROUND(AVG(dti),2)                   AS avg_dti,
    SUM(is_default)                     AS total_defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2) AS overall_default_rate_pct,
    SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END) AS defaulted_portfolio_value
FROM loans;
SELECT
    loan_status,
    COUNT(*)                                   AS count,
    ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER(),2) AS pct
FROM loans
GROUP BY loan_status
ORDER BY count DESC;
-- STEP 3: CASE BUCKETING — DTI BANDS & RISK TIERS
-- 3a. DTI Band Definition (CASE bucketing)
ALTER TABLE loans ADD COLUMN IF NOT EXISTS dti_band VARCHAR(20);

UPDATE loans
SET dti_band = CASE
    WHEN dti < 10            THEN '01_Low (0-10)'
    WHEN dti BETWEEN 10 AND 19.99 THEN '02_Moderate (10-20)'
    WHEN dti BETWEEN 20 AND 29.99 THEN '03_High (20-30)'
    WHEN dti BETWEEN 30 AND 39.99 THEN '04_Very High (30-40)'
    ELSE                          '05_Extreme (40+)'
END;
-- 3b. Loan Amount Tier (CASE bucketing)
ALTER TABLE loans ADD COLUMN IF NOT EXISTS loan_tier VARCHAR(20);

UPDATE loans
SET loan_tier = CASE
    WHEN loan_amnt < 7500            THEN 'Micro (<7.5K)'
    WHEN loan_amnt BETWEEN 7500 AND 14999 THEN 'Small (7.5-15K)'
    WHEN loan_amnt BETWEEN 15000 AND 24999 THEN 'Medium (15-25K)'
    WHEN loan_amnt BETWEEN 25000 AND 34999 THEN 'Large (25-35K)'
    ELSE                                  'Jumbo (35K+)'
END;

-- 3c. Income Tier (CASE bucketing)
ALTER TABLE loans ADD COLUMN IF NOT EXISTS income_tier VARCHAR(20);

UPDATE loans
SET income_tier = CASE
    WHEN annual_inc < 30000                 THEN '01_Low (<30K)'
    WHEN annual_inc BETWEEN 30000 AND 59999 THEN '02_Lower-Mid (30-60K)'
    WHEN annual_inc BETWEEN 60000 AND 99999 THEN '03_Mid (60-100K)'
    WHEN annual_inc BETWEEN 100000 AND 149999 THEN '04_Upper-Mid (100-150K)'
    ELSE                                        '05_High (150K+)'
END;
-- STEP 4: RISK ANALYSIS BY GRADE (Core Segmentation)
SELECT
    grade,
    COUNT(*)                                         AS total_loans,
    SUM(is_default)                                  AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)          AS default_rate_pct,
    ROUND(AVG(int_rate),2)                           AS avg_int_rate,
    ROUND(AVG(dti),2)                                AS avg_dti,
    ROUND(AVG(loan_amnt),2)                          AS avg_loan_amnt,
    SUM(loan_amnt)                                   AS total_exposure,
    SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END)
                                                     AS defaulted_exposure,
    -- Risk Ratio: default rate vs Grade A benchmark
    ROUND(
        (100.0*SUM(is_default)/COUNT(*)) /
        NULLIF( (SELECT 100.0*SUM(is_default)/COUNT(*) FROM loans WHERE grade='A'), 0)
    ,2)                                              AS risk_ratio_vs_A,
    -- Interest Rate Premium vs Grade A
    ROUND(AVG(int_rate) - (SELECT AVG(int_rate) FROM loans WHERE grade='A'), 2)
                                                     AS int_rate_premium_vs_A
FROM loans
GROUP BY grade
ORDER BY grade;

-- STEP 5: RISK ANALYSIS BY LOAN PURPOSE
SELECT
    purpose,
    COUNT(*)                                          AS total_loans,
    SUM(is_default)                                   AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)           AS default_rate_pct,
    ROUND(AVG(int_rate),2)                            AS avg_int_rate,
    ROUND(AVG(loan_amnt),2)                           AS avg_loan_amnt,
    ROUND(AVG(dti),2)                                 AS avg_dti,
    -- Risk Ratio vs overall portfolio default rate
    ROUND(
        (100.0*SUM(is_default)/COUNT(*)) /
        NULLIF((SELECT 100.0*SUM(is_default)/COUNT(*) FROM loans),0)
    ,2)                                               AS risk_ratio_vs_portfolio,
    -- Is the interest rate adequate? Compare rate to expected loss
    ROUND(AVG(int_rate) - (100.0*SUM(is_default)/COUNT(*)),2)
                                                      AS rate_minus_default_rate
FROM loans
GROUP BY purpose
ORDER BY default_rate_pct DESC;

-- STEP 6: RISK ANALYSIS BY EMPLOYMENT LENGTH
SELECT
    COALESCE(emp_length,'Unknown')                    AS emp_length,
    COUNT(*)                                          AS total_loans,
    SUM(is_default)                                   AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)           AS default_rate_pct,
    ROUND(AVG(int_rate),2)                            AS avg_int_rate,
    ROUND(AVG(annual_inc),2)                          AS avg_annual_income,
    ROUND(AVG(dti),2)                                 AS avg_dti,
    ROUND(
        (100.0*SUM(is_default)/COUNT(*)) /
        NULLIF((SELECT 100.0*SUM(is_default)/COUNT(*) FROM loans WHERE emp_length='10+ years'),0)
    ,2)                                               AS risk_ratio_vs_10plus
FROM loans
GROUP BY emp_length
ORDER BY default_rate_pct DESC;

-- STEP 7: RISK ANALYSIS BY DTI BAND
SELECT
    dti_band,
    COUNT(*)                                          AS total_loans,
    SUM(is_default)                                   AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)           AS default_rate_pct,
    ROUND(AVG(int_rate),2)                            AS avg_int_rate,
    ROUND(AVG(loan_amnt),2)                           AS avg_loan_amnt,
    ROUND(AVG(annual_inc),2)                          AS avg_income,
    ROUND(
        (100.0*SUM(is_default)/COUNT(*)) /
        NULLIF((SELECT 100.0*SUM(is_default)/COUNT(*) FROM loans WHERE dti_band='01_Low (0-10)'),0)
    ,2)                                               AS risk_ratio_vs_low_dti
FROM loans
GROUP BY dti_band
ORDER BY dti_band;

-- STEP 8: CROSS-DIMENSIONAL ANALYSIS — GRADE × PURPOSE
SELECT
    grade,
    purpose,
    COUNT(*)                                         AS total_loans,
    SUM(is_default)                                  AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)          AS default_rate_pct,
    ROUND(AVG(int_rate),2)                           AS avg_int_rate
FROM loans
GROUP BY grade, purpose
HAVING COUNT(*) >= 10
ORDER BY default_rate_pct DESC
LIMIT 25;

-- STEP 9: CUBE — Multi-Dimensional Rollup Analysis
-- CUBE on Grade × DTI Band × Term for full combinatorial rollup

SELECT
    COALESCE(grade, '** ALL **')     AS grade,
    COALESCE(dti_band, '** ALL **')  AS dti_band,
    COALESCE(CAST(term AS TEXT), '** ALL **') AS term,
    COUNT(*)                                         AS total_loans,
    SUM(is_default)                                  AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)          AS default_rate_pct,
    ROUND(AVG(int_rate),2)                           AS avg_int_rate,
    SUM(loan_amnt)                                   AS total_exposure
FROM loans
GROUP BY CUBE(grade, dti_band, term)
ORDER BY
    GROUPING(grade), grade,
    GROUPING(dti_band), dti_band,
    GROUPING(term), term;

-- STEP 10: ROLLUP — Hierarchical Summary (Purpose → Grade)
SELECT
    COALESCE(purpose,  '*** GRAND TOTAL ***')   AS purpose,
    COALESCE(grade,    '  * SUBTOTAL *')        AS grade,
    COUNT(*)                                    AS total_loans,
    SUM(is_default)                             AS defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)     AS default_rate_pct,
    ROUND(AVG(int_rate),2)                      AS avg_int_rate,
    SUM(loan_amnt)                              AS total_exposure
FROM loans
GROUP BY ROLLUP(purpose, grade)
ORDER BY
    GROUPING(purpose),
    purpose,
    GROUPING(grade),
    grade;
	
-- STEP 11: INTEREST RATE ADEQUACY — PRICING ACCURACY ANALYSIS
-- Is the lender charging enough for the risk they're taking?
-- Rule of thumb: int_rate should cover expected loss + spread
-- Expected Loss ≈ default_rate × LGD (assume LGD = 70%)

WITH segment_stats AS (
    SELECT
        grade,
        COUNT(*)                                        AS n,
        ROUND(100.0*SUM(is_default)/COUNT(*),2)        AS default_rate_pct,
        ROUND(AVG(int_rate),2)                         AS avg_int_rate,
        ROUND(AVG(loan_amnt),2)                        AS avg_loan_amnt
    FROM loans
    GROUP BY grade
)
SELECT
    grade,
    n                                                   AS total_loans,
    default_rate_pct,
    avg_int_rate,
    -- Expected Loss = default_rate * LGD (70%)
    ROUND(default_rate_pct * 0.70, 2)                  AS expected_loss_pct,
    -- Required rate = expected_loss + 3% cost_of_funds + 2% operating_cost
    ROUND(default_rate_pct * 0.70 + 5.0, 2)           AS required_min_rate,
    -- Pricing gap: positive = overpriced, negative = UNDERPRICED (risky!)
    ROUND(avg_int_rate - (default_rate_pct * 0.70 + 5.0), 2)
                                                        AS pricing_gap,
    CASE
        WHEN avg_int_rate < (default_rate_pct * 0.70 + 5.0)
            THEN '🔴 UNDERPRICED — Lender takes uncompensated risk'
        WHEN avg_int_rate < (default_rate_pct * 0.70 + 7.0)
            THEN '🟡 MARGINALLY PRICED — Thin margin'
        ELSE '🟢 ADEQUATELY PRICED'
    END                                                 AS pricing_verdict
FROM segment_stats
ORDER BY grade;

-- STEP 12: HIGH-RISK BORROWER PROFILE IDENTIFICATION
-- Identify compound risk: multiple risk factors stacked
WITH risk_scored AS (
    SELECT
        loan_id,
        grade,
        purpose,
        emp_length,
        dti_band,
        int_rate,
        loan_amnt,
        is_default,
        -- Stack risk scores
        (CASE grade WHEN 'F' THEN 5 WHEN 'G' THEN 6 WHEN 'E' THEN 4
                    WHEN 'D' THEN 3 WHEN 'C' THEN 2 ELSE 1 END)                     AS grade_risk,
        (CASE WHEN dti > 35 THEN 3 WHEN dti > 25 THEN 2 WHEN dti > 15 THEN 1 ELSE 0 END)
                                                                                     AS dti_risk,
        (CASE WHEN delinq_2yrs >= 2 THEN 2 WHEN delinq_2yrs = 1 THEN 1 ELSE 0 END) AS delinq_risk,
        (CASE WHEN pub_rec >= 1 THEN 2 ELSE 0 END)                                  AS pub_rec_risk,
        (CASE WHEN revol_util > 80 THEN 2 WHEN revol_util > 60 THEN 1 ELSE 0 END)  AS revol_risk,
        (CASE WHEN emp_length IN ('< 1 year','1 year') THEN 1 ELSE 0 END)           AS emp_risk,
        (CASE WHEN purpose IN ('small_business','vacation','moving') THEN 1 ELSE 0 END)
                                                                                     AS purpose_risk
    FROM loans
),
scored AS (
    SELECT *,
        grade_risk + dti_risk + delinq_risk + pub_rec_risk + revol_risk + emp_risk + purpose_risk
            AS composite_risk_score
    FROM risk_scored
),
buckets AS (
    SELECT *,
        CASE
            WHEN composite_risk_score >= 10 THEN 'EXTREME RISK'
            WHEN composite_risk_score >= 7  THEN 'VERY HIGH RISK'
            WHEN composite_risk_score >= 5  THEN 'HIGH RISK'
            WHEN composite_risk_score >= 3  THEN 'MODERATE RISK'
            ELSE                                 'LOW RISK'
        END AS risk_tier
    FROM scored
)
SELECT
    risk_tier,
    COUNT(*)                                         AS total_loans,
    SUM(is_default)                                  AS actual_defaults,
    ROUND(100.0*SUM(is_default)/COUNT(*),2)          AS actual_default_rate,
    ROUND(AVG(composite_risk_score),2)               AS avg_risk_score,
    ROUND(AVG(int_rate),2)                           AS avg_int_rate,
    ROUND(AVG(loan_amnt),2)                          AS avg_loan_amnt,
    SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END) AS at_risk_exposure
FROM buckets
GROUP BY risk_tier
ORDER BY avg_risk_score DESC;

-- STEP 13: STORED PROCEDURE — calculate_grade_risk_metrics()
-- Recompute risk metrics for any grade on-demand

CREATE OR REPLACE FUNCTION calculate_grade_risk_metrics(p_grade CHAR DEFAULT NULL)
RETURNS TABLE (
    grade               CHAR(1),
    total_loans         BIGINT,
    default_count       BIGINT,
    default_rate_pct    NUMERIC,
    avg_int_rate        NUMERIC,
    avg_dti             NUMERIC,
    total_exposure      NUMERIC,
    expected_loss       NUMERIC,
    pricing_gap         NUMERIC,
    pricing_status      TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    WITH stats AS (
        SELECT
            l.grade,
            COUNT(*)                                        AS n,
            SUM(l.is_default)                              AS def_count,
            ROUND(100.0*SUM(l.is_default)/COUNT(*),2)     AS dr,
            ROUND(AVG(l.int_rate),2)                       AS ir,
            ROUND(AVG(l.dti),2)                            AS avg_d,
            SUM(l.loan_amnt)                               AS exposure
        FROM loans l
        WHERE p_grade IS NULL OR l.grade = p_grade
        GROUP BY l.grade
    )
    SELECT
        s.grade,
        s.n,
        s.def_count,
        s.dr,
        s.ir,
        s.avg_d,
        s.exposure,
        ROUND(s.dr * 0.70, 2)                              AS exp_loss,
        ROUND(s.ir - (s.dr * 0.70 + 5.0), 2)             AS pr_gap,
        CASE
            WHEN s.ir < (s.dr * 0.70 + 5.0) THEN 'UNDERPRICED'
            WHEN s.ir < (s.dr * 0.70 + 7.0) THEN 'MARGINAL'
            ELSE 'ADEQUATE'
        END
    FROM stats s
    ORDER BY s.grade;
END;
$$;
-- Usage:
SELECT * FROM calculate_grade_risk_metrics();        -- all grades
SELECT * FROM calculate_grade_risk_metrics('D');     -- grade D only

-- STEP 14: STORED PROCEDURE — get_segment_risk_profile()
-- Full risk profile for any borrower segment
CREATE OR REPLACE FUNCTION get_segment_risk_profile(
    p_grade       CHAR    DEFAULT NULL,
    p_purpose     TEXT    DEFAULT NULL,
    p_emp_length  TEXT    DEFAULT NULL,
    p_dti_min     NUMERIC DEFAULT 0,
    p_dti_max     NUMERIC DEFAULT 100
)
RETURNS TABLE (
    segment_description  TEXT,
    total_loans          BIGINT,
    default_rate_pct     NUMERIC,
    avg_int_rate         NUMERIC,
    avg_loan_amnt        NUMERIC,
    avg_dti              NUMERIC,
    avg_annual_income    NUMERIC,
    total_exposure       NUMERIC,
    at_risk_dollars      NUMERIC,
    pricing_gap          NUMERIC
)
LANGUAGE plpgsql AS $$
DECLARE
    v_desc TEXT;
BEGIN
    v_desc := FORMAT(
        'Grade=%s | Purpose=%s | EmpLen=%s | DTI=[%s-%s]',
        COALESCE(p_grade::TEXT,'ANY'),
        COALESCE(p_purpose,'ANY'),
        COALESCE(p_emp_length,'ANY'),
        p_dti_min, p_dti_max
    );

    RETURN QUERY
    SELECT
        v_desc,
        COUNT(*),
        ROUND(100.0*SUM(is_default)/NULLIF(COUNT(*),0), 2),
        ROUND(AVG(int_rate),2),
        ROUND(AVG(loan_amnt),2),
        ROUND(AVG(dti),2),
        ROUND(AVG(annual_inc),2),
        SUM(loan_amnt),
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END),
        ROUND(AVG(int_rate) -
            (ROUND(100.0*SUM(is_default)/NULLIF(COUNT(*),0),2) * 0.70 + 5.0), 2)
    FROM loans
    WHERE
        (p_grade      IS NULL OR grade      = p_grade)
        AND (p_purpose    IS NULL OR purpose    = p_purpose)
        AND (p_emp_length IS NULL OR emp_length = p_emp_length)
        AND dti BETWEEN p_dti_min AND p_dti_max;
END;
$$;
-- Usage examples:
SELECT * FROM get_segment_risk_profile('E', 'small_business', NULL, 25, 45);
SELECT * FROM get_segment_risk_profile(p_dti_min=>30, p_dti_max=>45);

-- STEP 15: STORED PROCEDURE — build_risk_segment_cache()
-- Materialise all segments into a summary table

DROP TABLE IF EXISTS risk_segment_cache;
CREATE TABLE risk_segment_cache (
    segment_key         TEXT,
    dimension           TEXT,
    segment_value       TEXT,
    total_loans         BIGINT,
    defaults            BIGINT,
    default_rate_pct    NUMERIC,
    avg_int_rate        NUMERIC,
    avg_dti             NUMERIC,
    total_exposure      NUMERIC,
    at_risk_exposure    NUMERIC,
    risk_ratio          NUMERIC,
    pricing_gap         NUMERIC,
    last_refreshed      TIMESTAMP DEFAULT NOW()
);

CREATE OR REPLACE PROCEDURE build_risk_segment_cache()
LANGUAGE plpgsql AS $$
DECLARE
    v_portfolio_dr NUMERIC;
BEGIN
    -- Get portfolio-level default rate
    SELECT ROUND(100.0*SUM(is_default)/COUNT(*),4) INTO v_portfolio_dr FROM loans;

    -- Clear and rebuild
    DELETE FROM risk_segment_cache;

    -- Segment by Grade
    INSERT INTO risk_segment_cache
    SELECT
        'grade:' || grade,
        'Grade', grade,
        COUNT(*), SUM(is_default),
        ROUND(100.0*SUM(is_default)/COUNT(*),2),
        ROUND(AVG(int_rate),2), ROUND(AVG(dti),2),
        SUM(loan_amnt),
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END),
        ROUND((100.0*SUM(is_default)/COUNT(*)) / NULLIF(v_portfolio_dr,0), 2),
        ROUND(AVG(int_rate)-(100.0*SUM(is_default)/COUNT(*)*0.70+5.0),2),
        NOW()
    FROM loans GROUP BY grade;

    -- Segment by Purpose
    INSERT INTO risk_segment_cache
    SELECT
        'purpose:' || purpose,
        'Purpose', purpose,
        COUNT(*), SUM(is_default),
        ROUND(100.0*SUM(is_default)/COUNT(*),2),
        ROUND(AVG(int_rate),2), ROUND(AVG(dti),2),
        SUM(loan_amnt),
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END),
        ROUND((100.0*SUM(is_default)/COUNT(*)) / NULLIF(v_portfolio_dr,0), 2),
        ROUND(AVG(int_rate)-(100.0*SUM(is_default)/COUNT(*)*0.70+5.0),2),
        NOW()
    FROM loans GROUP BY purpose;

    -- Segment by DTI Band
    INSERT INTO risk_segment_cache
    SELECT
        'dti_band:' || dti_band,
        'DTI Band', dti_band,
        COUNT(*), SUM(is_default),
        ROUND(100.0*SUM(is_default)/COUNT(*),2),
        ROUND(AVG(int_rate),2), ROUND(AVG(dti),2),
        SUM(loan_amnt),
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END),
        ROUND((100.0*SUM(is_default)/COUNT(*)) / NULLIF(v_portfolio_dr,0), 2),
        ROUND(AVG(int_rate)-(100.0*SUM(is_default)/COUNT(*)*0.70+5.0),2),
        NOW()
    FROM loans GROUP BY dti_band;

    -- Segment by Employment Length
    INSERT INTO risk_segment_cache
    SELECT
        'emp:' || COALESCE(emp_length,'Unknown'),
        'Employment Length', COALESCE(emp_length,'Unknown'),
        COUNT(*), SUM(is_default),
        ROUND(100.0*SUM(is_default)/COUNT(*),2),
        ROUND(AVG(int_rate),2), ROUND(AVG(dti),2),
        SUM(loan_amnt),
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END),
        ROUND((100.0*SUM(is_default)/COUNT(*)) / NULLIF(v_portfolio_dr,0), 2),
        ROUND(AVG(int_rate)-(100.0*SUM(is_default)/COUNT(*)*0.70+5.0),2),
        NOW()
    FROM loans GROUP BY emp_length;

    -- Segment by Income Tier
    INSERT INTO risk_segment_cache
    SELECT
        'income:' || income_tier,
        'Income Tier', income_tier,
        COUNT(*), SUM(is_default),
        ROUND(100.0*SUM(is_default)/COUNT(*),2),
        ROUND(AVG(int_rate),2), ROUND(AVG(dti),2),
        SUM(loan_amnt),
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END),
        ROUND((100.0*SUM(is_default)/COUNT(*)) / NULLIF(v_portfolio_dr,0), 2),
        ROUND(AVG(int_rate)-(100.0*SUM(is_default)/COUNT(*)*0.70+5.0),2),
        NOW()
    FROM loans GROUP BY income_tier;

    RAISE NOTICE 'Risk segment cache built: % segments inserted.',
        (SELECT COUNT(*) FROM risk_segment_cache);
END;
$$;
-- CALL build_risk_segment_cache();
SELECT * FROM risk_segment_cache ORDER BY dimension, default_rate_pct DESC;

-- STEP 16: WINDOW FUNCTIONS — Ranking Within Segments
-- Top 10 riskiest sub_grade × purpose combos (ranked by default rate)
WITH ranked AS (
    SELECT
        sub_grade,
        purpose,
        COUNT(*)                                        AS total_loans,
        SUM(is_default)                                 AS defaults,
        ROUND(100.0*SUM(is_default)/COUNT(*),2)        AS default_rate_pct,
        ROUND(AVG(int_rate),2)                          AS avg_int_rate,
        RANK() OVER (ORDER BY 100.0*SUM(is_default)/COUNT(*) DESC) AS risk_rank
    FROM loans
    GROUP BY sub_grade, purpose
    HAVING COUNT(*) >= 15
)
SELECT * FROM ranked WHERE risk_rank <= 15 ORDER BY risk_rank;

-- STEP 17 (FIXED): Interest Rate Fairness by Borrower Income Tier
-- Prereq: income_tier column must exist (run Step 3 bucketing first)

-- Step 3 bucketing (safe to re-run with IF NOT EXISTS guard):
ALTER TABLE loans ADD COLUMN IF NOT EXISTS income_tier VARCHAR(25);

UPDATE loans
SET income_tier = CASE
    WHEN annual_inc < 30000   THEN '01_Low (<30K)'
    WHEN annual_inc < 60000   THEN '02_Lower-Mid (30-60K)'
    WHEN annual_inc < 100000  THEN '03_Mid (60-100K)'
    WHEN annual_inc < 150000  THEN '04_Upper-Mid (100-150K)'
    ELSE                           '05_High (150K+)'
END
WHERE income_tier IS NULL;   -- idempotent: skip rows already bucketed

-- Main query
WITH tier_stats AS (
    -- CTE 1: compute all per-tier aggregates cleanly in one place
    SELECT
        income_tier,
        COUNT(*)                                              AS total_loans,
        ROUND(100.0 * SUM(is_default) / COUNT(*), 2)        AS default_rate_pct,
        ROUND(AVG(int_rate), 2)                              AS avg_int_rate,
        ROUND(AVG(dti), 2)                                   AS avg_dti,
        ROUND(AVG(annual_inc), 0)                            AS avg_income,
        -- Rate per unit of default risk:
        -- a high value means the borrower pays a lot relative to their actual risk
        ROUND(
            AVG(int_rate)
            / NULLIF(100.0 * SUM(is_default) / COUNT(*), 0)
        , 2)                                                  AS rate_per_unit_risk
    FROM loans
    GROUP BY income_tier
),
mid_tier AS (
    -- CTE 2: isolate the Mid-income benchmark as a plain scalar row
    -- CROSS JOIN below makes this a single comparable value, not a subquery
    SELECT rate_per_unit_risk AS benchmark_rpur
    FROM tier_stats
    WHERE income_tier = '03_Mid (60-100K)'
)
SELECT
    t.income_tier,
    t.total_loans,
    t.default_rate_pct,
    t.avg_int_rate,
    t.avg_dti,
    t.avg_income,
    t.rate_per_unit_risk,
    -- Benchmark is now a plain column value — CASE can compare it safely
    CASE
        WHEN t.rate_per_unit_risk > m.benchmark_rpur
            THEN 'Relatively Overcharged vs Risk'
        ELSE
            'Fairly Priced or Undercharged'
    END                                                       AS pricing_fairness
FROM tier_stats  t
CROSS JOIN mid_tier m          -- one benchmark row × N tier rows = safe scalar
ORDER BY t.income_tier;

-- STEP 18 (FIXED): State-Level Risk Heatmap with Percentile Rank
WITH state_agg AS (
    SELECT
        addr_state,
        COUNT(*)                                              AS total_loans,
        SUM(is_default)                                       AS defaults,
        ROUND(100.0 * SUM(is_default) / COUNT(*) * 1.0, 2)  AS default_rate_pct,
        ROUND(AVG(int_rate) * 1.0, 2)                        AS avg_int_rate,
        ROUND(AVG(dti) * 1.0, 2)                             AS avg_dti,
        SUM(loan_amnt)                                        AS total_exposure
    FROM loans
    GROUP BY addr_state
    HAVING COUNT(*) >= 50
)
SELECT
    addr_state,
    total_loans,
    defaults,
    default_rate_pct,
    avg_int_rate,
    avg_dti,
    total_exposure,
    ROUND(
        (PERCENT_RANK() OVER (ORDER BY default_rate_pct) * 100)::NUMERIC
    , 1)                                                      AS risk_percentile,
    CASE
        WHEN PERCENT_RANK() OVER (ORDER BY default_rate_pct) >= 0.80
            THEN 'Top 20% — High Risk State'
        WHEN PERCENT_RANK() OVER (ORDER BY default_rate_pct) >= 0.50
            THEN 'Middle Tier'
        ELSE 'Lower Risk State'
    END                                                       AS state_risk_tier
FROM state_agg
ORDER BY default_rate_pct DESC;


-- STEP 19: FINAL EXECUTIVE SUMMARY VIEW
CREATE OR REPLACE VIEW v_risk_executive_summary AS
WITH portfolio AS (
    SELECT
        COUNT(*)                                   AS total_loans,
        SUM(loan_amnt)                             AS total_portfolio,
        ROUND(100.0*SUM(is_default)/COUNT(*),2)   AS overall_dr,
        SUM(CASE WHEN is_default=1 THEN loan_amnt ELSE 0 END) AS defaulted_amt
    FROM loans
),
high_risk AS (
    SELECT COUNT(*) AS n, SUM(loan_amnt) AS exp
    FROM loans
    WHERE grade IN ('E','F','G') OR dti > 35
),
underpriced AS (
    SELECT COUNT(*) AS n
    FROM (
        SELECT grade,
            ROUND(100.0*SUM(is_default)/COUNT(*),2) AS dr,
            ROUND(AVG(int_rate),2) AS ir
        FROM loans GROUP BY grade
        HAVING ROUND(AVG(int_rate),2) < ROUND(100.0*SUM(is_default)/COUNT(*),2)*0.70+5.0
    ) x
)
SELECT
    p.total_loans,
    p.total_portfolio,
    p.overall_dr                              AS portfolio_default_rate_pct,
    p.defaulted_amt                           AS total_defaulted_value,
    h.n                                       AS high_risk_loan_count,
    h.exp                                     AS high_risk_exposure,
    ROUND(100.0*h.n/p.total_loans,1)          AS high_risk_pct_of_portfolio,
    u.n                                       AS grades_underpriced_count,
    ROUND(p.defaulted_amt/p.total_portfolio*100,2) AS loss_rate_pct
FROM portfolio p, high_risk h, underpriced u;

SELECT * FROM v_risk_executive_summary;





