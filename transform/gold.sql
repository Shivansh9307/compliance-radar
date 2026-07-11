-- ============================================================
-- GOLD LAYER (part 1): fact_risk_flag
--
-- Base = ALL 10,000 companies (silver.companies).
-- Enrichment + AI extraction are LEFT JOINed, so enriched/extracted
-- companies get the richer flags and everyone else falls back to
-- bulk-derived flags. To scale later: enrich + extract more companies,
-- then re-run. No code changes needed.
--
-- RUN ORDER: silver.sql -> network_risk.sql -> ai/extract_flags.py -> gold.sql
--   (this file depends on gold.ai_extracted_flags, populated by the Python
--    extraction step; a guard below creates it empty if extraction hasn't run)
--
-- Run: docker exec -i compliance-pg psql -U postgres -d compliance < transform/gold.sql
-- ============================================================

-- guard: ensure the AI-extraction table exists so the JOIN never fails.
-- The canonical, fully-populated definition lives in ai/extract_flags.py.
CREATE TABLE IF NOT EXISTS gold.ai_extracted_flags (
    company_number      text PRIMARY KEY,
    going_concern       boolean,
    going_concern_ev    text,
    auditor_resignation boolean,
    auditor_resign_ev   text,
    related_party       boolean,
    related_party_ev    text,
    accounts_kind       text,
    model               text,
    extracted_at        timestamptz DEFAULT now()
);

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
        (ai.company_number IS NOT NULL)                                    AS is_ai_extracted,

        -- rule-based flags -------------------------------------------------
        COALESCE(cl.accounts_overdue,  c.accounts_overdue,  false)         AS f_accounts_overdue,
        COALESCE(cl.conf_stmt_overdue, c.conf_stmt_overdue, false)         AS f_conf_stmt_overdue,
        COALESCE(cl.live_status = 'active-proposal-to-strike-off', false)  AS f_strike_off,
        (COALESCE(cl.has_insolvency_history, false)
         OR COALESCE(cl.has_been_liquidated, false))                       AS f_insolvency_history,
        COALESCE(cl.company_type = 'dormant', false)                       AS f_dormant,
        (COALESCE(t.recent_officer_changes, 0) >= 3)                       AS f_officer_turnover,
        COALESCE(
            (COALESCE(cl.date_of_creation, c.incorporation_date) >= current_date - 365
             AND c.sic_code = ANY (ARRAY['64999','68209','82990','96090','64209'])),
            false
        )                                                                  AS f_new_watched_sector,
        COALESCE(nf.network_risk_level, 0)                                 AS network_risk_level,

        -- AI-extracted flags (from accounts PDFs) --------------------------
        COALESCE(ai.going_concern,       false)                            AS f_going_concern,
        COALESCE(ai.auditor_resignation, false)                            AS f_auditor_resignation,
        COALESCE(ai.related_party,       false)                            AS f_related_party
    FROM silver.companies c
    LEFT JOIN silver.company_live       cl ON cl.company_number = c.company_number
    LEFT JOIN turnover                  t  ON t.company_number  = c.company_number
    LEFT JOIN gold.company_network_flag nf ON nf.company_number = c.company_number
    LEFT JOIN gold.ai_extracted_flags   ai ON ai.company_number = c.company_number
),
scored AS (
    SELECT
        company_number, company_name, company_status, sic_code,
        is_enriched, is_ai_extracted,
        f_accounts_overdue, f_conf_stmt_overdue, f_strike_off,
        f_insolvency_history, f_dormant, f_officer_turnover, f_new_watched_sector,
        (network_risk_level = 3) AS f_network_risk_high,
        (network_risk_level = 2) AS f_network_risk_medium,
        f_going_concern, f_auditor_resignation, f_related_party,
        -- additive score: High=3, Medium=2, Low=1
        (
            f_accounts_overdue::int    * 3 +
            f_conf_stmt_overdue::int   * 2 +
            f_strike_off::int          * 3 +
            f_insolvency_history::int  * 3 +
            f_dormant::int             * 2 +
            f_officer_turnover::int    * 2 +
            f_new_watched_sector::int  * 1 +
            CASE network_risk_level WHEN 3 THEN 3 WHEN 2 THEN 2 ELSE 0 END +
            -- AI flags: going concern (High), auditor resignation (High),
            -- related party (Medium)
            f_going_concern::int       * 3 +
            f_auditor_resignation::int * 3 +
            f_related_party::int       * 2
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