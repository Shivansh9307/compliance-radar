-- ============================================================
-- DIRECTOR NETWORK RISK  (v3 - final, insolvency-based)
--
-- Calibration journey (documented in risk-flags.md v0.4):
--   v1: "linked to 3+ dissolved companies" -> flagged ~half the sample.
--   Cause: most "adverse" companies were ROUTINE dissolutions (companies
--   age out and close cleanly), not failures. Treating dissolved = failed
--   overstated risk roughly 5x.
--   v3 fix: count only INVOLUNTARY insolvency (liquidation, receivership,
--   administration, insolvency-proceedings, voluntary-arrangement).
--   Result: 15% of directors flagged instead of ~50%. Clean signal.
--
--   'dissolved' is kept as a separate, weaker context column, not as risk.
--
-- Run: docker exec -i compliance-pg psql -U postgres -d compliance < transform/network_risk.sql
-- ============================================================

-- ---------- SILVER: one row per (director, linked company) ----------
DROP TABLE IF EXISTS silver.officer_appointments CASCADE;

CREATE TABLE silver.officer_appointments AS
SELECT
    oa.officer_id,
    oa.officer_name,
    appt->'appointed_to'->>'company_number' AS linked_company_number,
    appt->'appointed_to'->>'company_name'   AS linked_company_name,
    appt->'appointed_to'->>'company_status' AS linked_company_status,
    appt->>'officer_role'                    AS officer_role,
    (appt->>'appointed_on')::date            AS appointed_on,
    (appt->>'resigned_on')::date             AS resigned_on
FROM bronze.officer_appointments oa,
     jsonb_array_elements(oa.appointments->'items') AS appt
WHERE jsonb_typeof(oa.appointments->'items') = 'array';

-- ---------- GOLD: per-director network profile + classification ----------
DROP TABLE IF EXISTS gold.director_network_risk CASCADE;

CREATE TABLE gold.director_network_risk AS
WITH counts AS (
    SELECT
        officer_id,
        max(officer_name) AS officer_name,
        count(DISTINCT linked_company_number) AS total_companies,
        -- TRUE distress: involuntary endings only
        count(DISTINCT linked_company_number) FILTER (
            WHERE linked_company_status = ANY (ARRAY[
                'liquidation','receivership','administration',
                'insolvency-proceedings','voluntary-arrangement'
            ])
        ) AS insolvent_companies,
        -- routine closures kept as weaker context, NOT counted as risk
        count(DISTINCT linked_company_number) FILTER (
            WHERE linked_company_status = 'dissolved'
        ) AS dissolved_companies
    FROM silver.officer_appointments
    GROUP BY officer_id
)
SELECT
    officer_id,
    officer_name,
    total_companies,
    insolvent_companies,
    dissolved_companies,
    CASE
        WHEN insolvent_companies >= 10 THEN 'network_risk_high'
        WHEN insolvent_companies >= 5  THEN 'network_risk_medium'
        ELSE 'none'
    END AS classification
FROM counts;

-- ---------- GOLD: flag OUR companies via their active directors ----------
DROP TABLE IF EXISTS gold.company_network_flag CASCADE;

CREATE TABLE gold.company_network_flag AS
SELECT
    o.company_number,
    max(CASE d.classification
            WHEN 'network_risk_high'   THEN 3
            WHEN 'network_risk_medium' THEN 2
            ELSE 0 END)                          AS network_risk_level,
    max(d.insolvent_companies)                   AS worst_director_insolvencies
FROM silver.officers o
JOIN gold.director_network_risk d ON d.officer_id = o.officer_id
WHERE o.is_corporate = false
  AND o.is_active_officer = true
GROUP BY o.company_number;