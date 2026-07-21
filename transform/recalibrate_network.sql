-- ============================================================
-- Director-network-risk RE-CALIBRATION on the CURRENT sample
--
-- Reproduces the v1 (naive) / v2 (ratio) / v3 (final) figures against
-- whatever is currently in the warehouse, so the calibration story in
-- docs/risk-flags.md and README.md can be re-derived on the 300-company
-- random sample instead of the retired 50-company one.
--
-- READ-ONLY. Uses TEMP views only (dropped at session end); touches no
-- real tables. Safe to re-run.
--
-- Run:
--   docker exec -i compliance-pg psql -U postgres -d compliance < recalibrate_network.sql
-- ============================================================

-- Assessed universe = active, human directors OF THE CURRENT SAMPLE whose
-- appointment history we hold. Restricting to current-sample officers guards
-- against directors left in bronze.officer_appointments by the old 50-company
-- run (that table was never cleared, so silver.officer_appointments may still
-- carry stale officer_ids; this restriction makes the base correct regardless).
CREATE TEMP VIEW _sample_directors AS
SELECT DISTINCT officer_id
FROM silver.officers
WHERE is_corporate      = false
  AND is_active_officer  = true
  AND officer_id IS NOT NULL;

-- Per-director register-wide profile (sample directors only).
-- status is single-valued per company, so the filtered counts are disjoint.
CREATE TEMP VIEW _pd AS
SELECT
    a.officer_id,
    count(DISTINCT a.linked_company_number) AS total_companies,
    count(DISTINCT a.linked_company_number) FILTER (
        WHERE a.linked_company_status = ANY (ARRAY[
            'liquidation','receivership','administration',
            'insolvency-proceedings','voluntary-arrangement'])) AS insolvent_companies,
    count(DISTINCT a.linked_company_number) FILTER (
        WHERE a.linked_company_status = 'dissolved')            AS dissolved_companies,
    count(DISTINCT a.linked_company_number) FILTER (
        WHERE a.linked_company_status = ANY (ARRAY[
            'dissolved','liquidation','receivership','administration',
            'insolvency-proceedings','voluntary-arrangement']))  AS adverse_companies
FROM silver.officer_appointments a
JOIN _sample_directors s ON s.officer_id = a.officer_id
GROUP BY a.officer_id;

-- ------------------------------------------------------------
-- 0. SANITY / contamination check
--    If directors_in_appt_history >> assessed_directors, stale old-sample
--    rows are present in bronze.officer_appointments -- the _pd restriction
--    still makes the numbers below correct, but it's worth knowing.
-- ------------------------------------------------------------
SELECT '0. sanity' AS section,
   (SELECT count(*) FROM _sample_directors)                              AS sample_active_directors,
   (SELECT count(DISTINCT officer_id) FROM silver.officer_appointments)  AS directors_in_appt_history,
   (SELECT count(*) FROM _pd)                                            AS assessed_directors,
   (SELECT count(*) FROM gold.company_network_flag)                      AS assessable_companies;

-- ------------------------------------------------------------
-- 1. DIRECTOR-LEVEL flag rates, all three versions + isolation
-- ------------------------------------------------------------

-- v1 naive: linked to 3+ DISSOLVED-OR-INSOLVENT companies
SELECT '1a. v1 directors (adverse>=3)' AS metric,
   count(*) FILTER (WHERE adverse_companies >= 3)                          AS flagged,
   count(*)                                                                AS base,
   round(100.0*count(*) FILTER (WHERE adverse_companies >= 3)/count(*),1)  AS pct
FROM _pd;

-- v2 ratio: v1 count PLUS a failure-ratio gate.
-- NOTE: the 0.5 ratio threshold is made EXPLICIT here. The original v2 did
-- not record its exact cutoff, so this is a reconstruction choice -- change
-- the 0.5 and re-run to see sensitivity before you commit to a number.
SELECT '1b. v2 directors (adverse>=3 AND ratio>=0.5)' AS metric,
   count(*) FILTER (
     WHERE adverse_companies >= 3
       AND adverse_companies::numeric/NULLIF(total_companies,0) >= 0.5)    AS flagged,
   count(*)                                                                AS base
FROM _pd;

-- ISOLATION: v3 definition (insolvent only) held at the v1 threshold (>=3).
-- Comparing 1a, this row, and 1d separates the DEFINITIONAL effect from the
-- THRESHOLD effect -- the distinction risk-flags.md v0.7 was careful about.
SELECT '1c. insolvent-only at threshold>=3' AS metric,
   count(*) FILTER (WHERE insolvent_companies >= 3)                        AS flagged,
   count(*)                                                                AS base
FROM _pd;

-- v3 final: involuntary insolvency only. High >=10, Medium 5-9.
SELECT '1d. v3 directors (final)' AS metric,
   count(*) FILTER (WHERE insolvent_companies >= 10)                       AS high,
   count(*) FILTER (WHERE insolvent_companies BETWEEN 5 AND 9)             AS medium,
   count(*) FILTER (WHERE insolvent_companies >= 5)                        AS total_flagged,
   count(*)                                                                AS base
FROM _pd;

-- ------------------------------------------------------------
-- 2. COMPANY-LEVEL flag rates, v1 vs v3, same denominator
--    A company inherits the worst classification among its active human
--    directors (High dominates Medium), matching gold.company_network_flag.
-- ------------------------------------------------------------
SELECT '2. companies (v1 vs v3)' AS metric,
   count(*)                                          AS assessable_companies,
   count(*) FILTER (WHERE v1_flag)                   AS v1_flagged,
   count(*) FILTER (WHERE v3_high)                   AS v3_high,
   count(*) FILTER (WHERE v3_medium AND NOT v3_high) AS v3_medium,
   count(*) FILTER (WHERE v3_high OR v3_medium)      AS v3_flagged
FROM (
   SELECT o.company_number,
      bool_or(pd.adverse_companies  >= 3)             AS v1_flag,
      bool_or(pd.insolvent_companies >= 10)           AS v3_high,
      bool_or(pd.insolvent_companies BETWEEN 5 AND 9) AS v3_medium
   FROM silver.officers o
   JOIN _pd pd ON pd.officer_id = o.officer_id
   WHERE o.is_corporate = false AND o.is_active_officer = true
   GROUP BY o.company_number
) q;

-- ------------------------------------------------------------
-- 3. DIAGNOSTICS -- the qualitative evidence behind the story
--    officer_id only (no names): director records are personal data;
--    redact/aggregate before anything publishable.
-- ------------------------------------------------------------

-- 3a. The most-linked directors (the "463 companies" / insolvency-professional
--     case that motivated moving away from a raw count).
SELECT '3a. top-linked' AS metric,
   officer_id, total_companies, insolvent_companies, dissolved_companies
FROM _pd
ORDER BY total_companies DESC
LIMIT 5;

-- 3b. Dissolved-vs-insolvent inflation (the "5.7x / 34x" cases): directors
--     for whom treating dissolution as failure most overstates true distress.
SELECT '3b. inflation' AS metric,
   officer_id, dissolved_companies, insolvent_companies, adverse_companies,
   round(adverse_companies::numeric / NULLIF(insolvent_companies,0), 1) AS adverse_to_insolvent_x
FROM _pd
WHERE insolvent_companies >= 1
ORDER BY adverse_to_insolvent_x DESC NULLS LAST
LIMIT 5;