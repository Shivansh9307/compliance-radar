-- ============================================================
-- GOLD LAYER (part 1): fact_risk_flag
--
-- Base = ALL 10,000 companies (silver.companies).
-- Enrichment is LEFT JOINed, so enriched companies get the richer
-- live flags and everyone else falls back to bulk-derived flags.
-- To scale later: enrich more companies, re-run silver + network_risk,
-- then re-run this file. No code changes needed.
--
-- DEPENDS ON: silver.companies, silver.company_live, silver.officers,
--             gold.company_network_flag  (run network_risk.sql first)
-- Run: docker exec -i compliance-pg psql -U postgres -d compliance < transform/gold.sql
-- ============================================================

DROP TABLE IF EXISTS gold.fact_risk_flag CASCADE;

CREATE TABLE gold.fact_risk_flag AS
WITH
-- recent officer churn per company (enriched only; others get 0)
turnover AS (
    SELECT company_number,
           count(*) FILTER (
               WHERE appointed_effective >= current_date - 365
                  OR resigned_on         >= current_date - 365
           ) AS recent_officer_changes
    FROM silver.officers
    WHERE is_corporate = false
    GROUP BY company_number
),
-- every flag, computed per company, base = all 10,000
flags AS (
    SELECT
        c.company_number,
        c.company_name,
        c.company_status,
        c.sic_code,
        (cl.company_number IS NOT NULL)                                    AS is_enriched,

        -- High: overdue accounts (live wins, else bulk fallback)
        COALESCE(cl.accounts_overdue,  c.accounts_overdue,  false)         AS f_accounts_overdue,
        -- Medium: overdue confirmation statement
        COALESCE(cl.conf_stmt_overdue, c.conf_stmt_overdue, false)         AS f_conf_stmt_overdue,
        -- High: strike-off proposed (live only)
        COALESCE(cl.live_status = 'active-proposal-to-strike-off', false)  AS f_strike_off,
        -- High: insolvency history (live only)
        (COALESCE(cl.has_insolvency_history, false)
         OR COALESCE(cl.has_been_liquidated, false))                       AS f_insolvency_history,
        -- Medium: currently dormant (live only)
        COALESCE(cl.company_type = 'dormant', false)                       AS f_dormant,
        -- Medium: 3+ officer changes in last year (live only)
        (COALESCE(t.recent_officer_changes, 0) >= 3)                       AS f_officer_turnover,
        -- Low: new company in a watched sector (bulk + live)
        COALESCE(
            (COALESCE(cl.date_of_creation, c.incorporation_date) >= current_date - 365
             AND c.sic_code = ANY (ARRAY['64999','68209','82990','96090','64209'])),
            false
        )                                                                  AS f_new_watched_sector,

        -- network risk level (3=High, 2=Medium, 0=none) from the calibrated flag
        COALESCE(nf.network_risk_level, 0)                                 AS network_risk_level
    FROM silver.companies c
    LEFT JOIN silver.company_live       cl ON cl.company_number = c.company_number
    LEFT JOIN turnover                  t  ON t.company_number  = c.company_number
    LEFT JOIN gold.company_network_flag nf ON nf.company_number = c.company_number
),
scored AS (
    SELECT
        company_number, company_name, company_status, sic_code, is_enriched,
        f_accounts_overdue, f_conf_stmt_overdue, f_strike_off,
        f_insolvency_history, f_dormant, f_officer_turnover, f_new_watched_sector,
        (network_risk_level = 3) AS f_network_risk_high,
        (network_risk_level = 2) AS f_network_risk_medium,
        -- additive score: High=3, Medium=2, Low=1
        (
            f_accounts_overdue::int   * 3 +
            f_conf_stmt_overdue::int  * 2 +
            f_strike_off::int         * 3 +
            f_insolvency_history::int * 3 +
            f_dormant::int            * 2 +
            f_officer_turnover::int   * 2 +
            f_new_watched_sector::int * 1 +
            CASE network_risk_level WHEN 3 THEN 3 WHEN 2 THEN 2 ELSE 0 END
        ) AS risk_score
    FROM flags
)
SELECT
    *,
    CASE
        WHEN risk_score >= 6 THEN 'High'
        WHEN risk_score >= 3 THEN 'Medium'
        WHEN risk_score >= 1 THEN 'Low'
        ELSE 'None'
    END AS risk_tier
FROM scored;

CREATE INDEX IF NOT EXISTS idx_frf_number ON gold.fact_risk_flag (company_number);
CREATE INDEX IF NOT EXISTS idx_frf_score  ON gold.fact_risk_flag (risk_score DESC);