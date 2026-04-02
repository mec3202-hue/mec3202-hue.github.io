-- ============================================================
-- B2B Sales & Revenue Analytics
-- Author:  Your Name
-- Date:    April 2026
-- Tools:   SQL (SQLite / PostgreSQL compatible)
-- Dataset: Simulated B2B SaaS sales data modeled after
--          publicly available HubSpot & Salesforce benchmarks
-- ============================================================
--
-- This script analyzes four core B2B revenue metrics:
--   1. Monthly Recurring Revenue (MRR) — growth & composition
--   2. Customer Lifetime Value (LTV)   — by segment & region
--   3. Cohort Retention Analysis       — how well we keep customers
--   4. Revenue by Region               — geographic performance
--
-- DATA DISCLOSURE: All data is simulated for portfolio purposes.
-- Figures are modeled after B2B SaaS benchmarks from:
--   - OpenView Partners SaaS Benchmarks Report (2024)
--   - Bessemer Venture Partners State of the Cloud (2024)
--   - HubSpot Sales Benchmarks Report (2024)
-- ============================================================


-- ============================================================
-- SCHEMA SETUP
-- ============================================================

-- Customers table: one row per customer account
CREATE TABLE IF NOT EXISTS customers (
    customer_id     TEXT PRIMARY KEY,
    company_name    TEXT,
    segment         TEXT,   -- SMB, Mid-Market, Enterprise
    region          TEXT,   -- North America, EMEA, APAC, LATAM
    industry        TEXT,
    acquired_date   DATE,
    churned_date    DATE,   -- NULL if still active
    csm_owner       TEXT    -- Customer Success Manager
);

-- Subscriptions table: tracks plan changes over time
CREATE TABLE IF NOT EXISTS subscriptions (
    sub_id          TEXT PRIMARY KEY,
    customer_id     TEXT REFERENCES customers(customer_id),
    plan_name       TEXT,   -- Starter, Growth, Professional, Enterprise
    mrr             DECIMAL(10,2),
    start_date      DATE,
    end_date        DATE,   -- NULL if current plan
    change_type     TEXT    -- new, expansion, contraction, churn
);

-- Deals table: tracks closed-won opportunities
CREATE TABLE IF NOT EXISTS deals (
    deal_id         TEXT PRIMARY KEY,
    customer_id     TEXT REFERENCES customers(customer_id),
    deal_value      DECIMAL(10,2),
    close_date      DATE,
    sales_rep       TEXT,
    deal_stage      TEXT,
    product_line    TEXT
);


-- ============================================================
-- 1. MONTHLY RECURRING REVENUE (MRR)
-- ============================================================
-- MRR is the single most important metric for a B2B subscription
-- business. We break it into four components (the "MRR waterfall"):
--   New MRR       — revenue from brand new customers
--   Expansion MRR — upsells / upgrades from existing customers
--   Contraction   — downgrades from existing customers
--   Churned MRR   — revenue lost from cancellations
-- Net New MRR = New + Expansion - Contraction - Churned

-- 1a. MRR by month and change type
SELECT
    strftime('%Y-%m', start_date)       AS month,
    change_type,
    COUNT(DISTINCT customer_id)         AS customers,
    ROUND(SUM(mrr), 2)                  AS total_mrr,
    ROUND(AVG(mrr), 2)                  AS avg_mrr_per_customer
FROM subscriptions
GROUP BY 1, 2
ORDER BY 1, 2;


-- 1b. Net New MRR waterfall by month
-- This is the view you'd present to a CFO or board
SELECT
    month,
    ROUND(SUM(CASE WHEN change_type = 'new'         THEN mrr ELSE 0 END), 2) AS new_mrr,
    ROUND(SUM(CASE WHEN change_type = 'expansion'   THEN mrr ELSE 0 END), 2) AS expansion_mrr,
    ROUND(SUM(CASE WHEN change_type = 'contraction' THEN mrr ELSE 0 END), 2) AS contraction_mrr,
    ROUND(SUM(CASE WHEN change_type = 'churn'       THEN mrr ELSE 0 END), 2) AS churned_mrr,
    ROUND(
        SUM(CASE WHEN change_type = 'new'         THEN mrr ELSE 0 END) +
        SUM(CASE WHEN change_type = 'expansion'   THEN mrr ELSE 0 END) -
        SUM(CASE WHEN change_type = 'contraction' THEN mrr ELSE 0 END) -
        ABS(SUM(CASE WHEN change_type = 'churn'   THEN mrr ELSE 0 END)), 2
    )                                                                          AS net_new_mrr
FROM (
    SELECT strftime('%Y-%m', start_date) AS month, change_type, mrr, customer_id
    FROM subscriptions
) sub
GROUP BY 1
ORDER BY 1;


-- 1c. Cumulative MRR growth (running total)
-- Useful for visualizing ARR trajectory over the year
WITH monthly_net AS (
    SELECT
        strftime('%Y-%m', start_date) AS month,
        SUM(CASE WHEN change_type IN ('new','expansion')   THEN mrr ELSE 0 END) -
        SUM(CASE WHEN change_type IN ('contraction','churn') THEN ABS(mrr) ELSE 0 END) AS net_mrr
    FROM subscriptions
    GROUP BY 1
)
SELECT
    month,
    ROUND(net_mrr, 2)                                          AS net_new_mrr,
    ROUND(SUM(net_mrr) OVER (ORDER BY month), 2)               AS cumulative_mrr,
    ROUND(SUM(net_mrr) OVER (ORDER BY month) * 12, 2)          AS implied_arr
FROM monthly_net
ORDER BY 1;


-- ============================================================
-- 2. CUSTOMER LIFETIME VALUE (LTV)
-- ============================================================
-- LTV = Average MRR × Gross Margin × (1 / Churn Rate)
-- We calculate LTV by segment because SMB, Mid-Market, and
-- Enterprise customers have very different value profiles.

-- 2a. LTV by customer segment
WITH customer_metrics AS (
    SELECT
        c.customer_id,
        c.segment,
        c.region,
        c.acquired_date,
        c.churned_date,
        -- Tenure in months (capped at today if still active)
        ROUND(
            julianday(COALESCE(c.churned_date, date('now'))) -
            julianday(c.acquired_date)
        ) / 30.44                                               AS tenure_months,
        AVG(s.mrr)                                              AS avg_monthly_mrr,
        SUM(s.mrr)                                              AS total_revenue
    FROM customers c
    JOIN subscriptions s ON c.customer_id = s.customer_id
    GROUP BY 1, 2, 3, 4, 5
)
SELECT
    segment,
    COUNT(*)                                                    AS customer_count,
    ROUND(AVG(avg_monthly_mrr), 2)                              AS avg_mrr,
    ROUND(AVG(tenure_months), 1)                                AS avg_tenure_months,
    -- Simplified LTV: avg monthly revenue × avg tenure
    ROUND(AVG(avg_monthly_mrr) * AVG(tenure_months), 2)         AS avg_ltv,
    -- LTV:CAC ratio benchmark (assuming CAC of $1200 SMB, $4500 MM, $18000 ENT)
    ROUND(AVG(avg_monthly_mrr) * AVG(tenure_months) /
        CASE segment
            WHEN 'SMB'         THEN 1200
            WHEN 'Mid-Market'  THEN 4500
            WHEN 'Enterprise'  THEN 18000
        END, 2)                                                 AS ltv_cac_ratio,
    ROUND(AVG(total_revenue), 2)                                AS avg_total_revenue
FROM customer_metrics
GROUP BY 1
ORDER BY avg_ltv DESC;


-- 2b. LTV distribution by region and segment (cross-tab)
WITH customer_ltv AS (
    SELECT
        c.customer_id,
        c.segment,
        c.region,
        AVG(s.mrr) * (
            julianday(COALESCE(c.churned_date, date('now'))) -
            julianday(c.acquired_date)
        ) / 30.44                                               AS ltv
    FROM customers c
    JOIN subscriptions s ON c.customer_id = s.customer_id
    GROUP BY 1, 2, 3, 4
)
SELECT
    region,
    ROUND(AVG(CASE WHEN segment = 'SMB'        THEN ltv END), 2) AS smb_avg_ltv,
    ROUND(AVG(CASE WHEN segment = 'Mid-Market' THEN ltv END), 2) AS midmarket_avg_ltv,
    ROUND(AVG(CASE WHEN segment = 'Enterprise' THEN ltv END), 2) AS enterprise_avg_ltv,
    ROUND(AVG(ltv), 2)                                           AS overall_avg_ltv
FROM customer_ltv
GROUP BY 1
ORDER BY overall_avg_ltv DESC;


-- ============================================================
-- 3. COHORT RETENTION ANALYSIS
-- ============================================================
-- Cohort retention tracks what % of customers acquired in a
-- given month are still active N months later. This is one of
-- the most important signals of product-market fit and
-- customer success effectiveness.

-- 3a. Build the cohort base — acquisition month per customer
WITH cohort_base AS (
    SELECT
        customer_id,
        strftime('%Y-%m', acquired_date)    AS cohort_month,
        acquired_date
    FROM customers
),

-- 3b. For each customer, determine which months they were active
-- (had an active subscription, i.e. not yet churned)
customer_activity AS (
    SELECT
        c.customer_id,
        cb.cohort_month,
        -- Months since acquisition (0 = acquisition month)
        CAST(
            (julianday(strftime('%Y-%m-01', s.start_date)) -
             julianday(strftime('%Y-%m-01', cb.acquired_date)))
            / 30.44 AS INTEGER
        )                                   AS months_since_acquisition
    FROM customers c
    JOIN cohort_base cb     ON c.customer_id = cb.customer_id
    JOIN subscriptions s    ON c.customer_id = s.customer_id
    WHERE s.change_type != 'churn'
    GROUP BY 1, 2, 3
),

-- 3c. Count cohort sizes (customers per cohort month)
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM cohort_base
    GROUP BY 1
)

-- 3d. Final retention table: % retained at each month interval
SELECT
    ca.cohort_month,
    cs.cohort_size,
    ca.months_since_acquisition                             AS month_number,
    COUNT(DISTINCT ca.customer_id)                          AS retained_customers,
    ROUND(
        COUNT(DISTINCT ca.customer_id) * 100.0 / cs.cohort_size, 1
    )                                                       AS retention_rate_pct
FROM customer_activity ca
JOIN cohort_sizes cs ON ca.cohort_month = cs.cohort_month
WHERE ca.months_since_acquisition BETWEEN 0 AND 11
GROUP BY 1, 2, 3
ORDER BY 1, 3;


-- ============================================================
-- 4. REVENUE BY REGION
-- ============================================================

-- 4a. Revenue and customer count by region
SELECT
    c.region,
    COUNT(DISTINCT c.customer_id)                           AS total_customers,
    COUNT(DISTINCT CASE WHEN c.churned_date IS NULL
          THEN c.customer_id END)                           AS active_customers,
    ROUND(SUM(s.mrr), 2)                                    AS total_mrr,
    ROUND(AVG(s.mrr), 2)                                    AS avg_mrr_per_customer,
    ROUND(SUM(s.mrr) / SUM(SUM(s.mrr)) OVER () * 100, 1)   AS revenue_share_pct
FROM customers c
JOIN subscriptions s ON c.customer_id = s.customer_id
GROUP BY 1
ORDER BY total_mrr DESC;


-- 4b. Revenue by region AND segment (cross-tab)
-- Shows which regions have the strongest enterprise penetration
SELECT
    c.region,
    ROUND(SUM(CASE WHEN c.segment = 'SMB'        THEN s.mrr ELSE 0 END), 2) AS smb_mrr,
    ROUND(SUM(CASE WHEN c.segment = 'Mid-Market' THEN s.mrr ELSE 0 END), 2) AS midmarket_mrr,
    ROUND(SUM(CASE WHEN c.segment = 'Enterprise' THEN s.mrr ELSE 0 END), 2) AS enterprise_mrr,
    ROUND(SUM(s.mrr), 2)                                                     AS total_mrr
FROM customers c
JOIN subscriptions s ON c.customer_id = s.customer_id
GROUP BY 1
ORDER BY total_mrr DESC;


-- 4c. Quarter-over-quarter revenue growth by region
WITH quarterly AS (
    SELECT
        c.region,
        strftime('%Y', s.start_date) || '-Q' ||
            ((CAST(strftime('%m', s.start_date) AS INT) - 1) / 3 + 1) AS quarter,
        ROUND(SUM(s.mrr), 2)                                           AS quarterly_mrr
    FROM customers c
    JOIN subscriptions s ON c.customer_id = s.customer_id
    GROUP BY 1, 2
)
SELECT
    region,
    quarter,
    quarterly_mrr,
    LAG(quarterly_mrr) OVER (PARTITION BY region ORDER BY quarter) AS prev_quarter_mrr,
    ROUND(
        (quarterly_mrr - LAG(quarterly_mrr) OVER (PARTITION BY region ORDER BY quarter))
        / LAG(quarterly_mrr) OVER (PARTITION BY region ORDER BY quarter) * 100, 1
    )                                                               AS qoq_growth_pct
FROM quarterly
ORDER BY region, quarter;


-- ============================================================
-- 5. EXECUTIVE SUMMARY VIEW
-- ============================================================
-- A single query that produces a board-ready summary.
-- Run this to get a snapshot of overall business health.

SELECT
    'Total Active Customers'    AS metric,
    CAST(COUNT(DISTINCT customer_id) AS TEXT) AS value
FROM customers WHERE churned_date IS NULL

UNION ALL

SELECT 'Total MRR',
    '$' || ROUND(SUM(mrr), 0)
FROM subscriptions WHERE change_type NOT IN ('churn','contraction')

UNION ALL

SELECT 'Implied ARR',
    '$' || ROUND(SUM(mrr) * 12, 0)
FROM subscriptions WHERE change_type NOT IN ('churn','contraction')

UNION ALL

SELECT 'Avg MRR per Customer',
    '$' || ROUND(AVG(mrr), 2)
FROM subscriptions WHERE change_type NOT IN ('churn','contraction')

UNION ALL

SELECT 'Overall Churn Rate (monthly)',
    ROUND(
        COUNT(DISTINCT CASE WHEN churned_date IS NOT NULL THEN customer_id END) * 100.0
        / COUNT(DISTINCT customer_id), 2
    ) || '%'
FROM customers;


-- ============================================================
-- DATA DISCLOSURE
-- ============================================================
-- All data produced by this script is simulated for portfolio
-- demonstration purposes only. No real customer or company data
-- was used. Benchmarks referenced:
--   - OpenView Partners SaaS Benchmarks Report 2024
--   - Bessemer Venture Partners State of the Cloud 2024
--   - HubSpot Sales Benchmarks Report 2024
--   - SaaStr Annual Benchmarks 2024
-- ============================================================
