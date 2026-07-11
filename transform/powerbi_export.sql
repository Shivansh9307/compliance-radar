-- ============================================================
-- POWER BI EXPORT LAYER
-- Flattened, report-ready views over the gold star. Power BI receives
-- clean tables and does minimal modelling. One wide fact view + dims.
-- Run: docker exec -i compliance-pg psql -U postgres -d compliance < transform/powerbi_export.sql
-- ============================================================

-- Wide, report-ready company risk table: fact + key company attributes,
-- one row per company, every flag as a readable Yes/No, plus the score.
DROP VIEW IF EXISTS gold.pbi_company_risk CASCADE;
CREATE VIEW gold.pbi_company_risk AS
SELECT
    f.company_number,
    d.company_name,
    d.company_status,
    d.company_type,
    d.post_town,
    d.date_of_creation,
    s.sic_description,
    f.risk_score,
    f.risk_tier,
    f.is_enriched,
    f.is_ai_extracted,
    -- flags as 1/0 (Power BI sums these easily)
    f.f_accounts_overdue::int    AS flag_accounts_overdue,
    f.f_conf_stmt_overdue::int   AS flag_conf_overdue,
    f.f_strike_off::int          AS flag_strike_off,
    f.f_insolvency_history::int  AS flag_insolvency,
    f.f_dormant::int             AS flag_dormant,
    f.f_officer_turnover::int    AS flag_officer_turnover,
    f.f_network_risk_high::int   AS flag_network_high,
    f.f_network_risk_medium::int AS flag_network_medium,
    f.f_going_concern::int       AS flag_going_concern,
    f.f_auditor_resignation::int AS flag_auditor_resignation,
    f.f_related_party::int       AS flag_related_party
FROM gold.fact_risk_flag f
LEFT JOIN gold.dim_company d ON d.company_number = f.company_number
LEFT JOIN gold.dim_sic     s ON s.sic_code       = d.sic_code;

-- Long/unpivoted flag table: one row per (company, active flag).
-- Powers a "which flags are firing" bar chart and lets you filter by flag.
DROP VIEW IF EXISTS gold.pbi_flags_long CASCADE;
CREATE VIEW gold.pbi_flags_long AS
SELECT company_number, company_name, risk_tier, flag_name, flag_severity
FROM (
    SELECT f.company_number, d.company_name, f.risk_tier,
           v.flag_name, v.flag_severity, v.is_on
    FROM gold.fact_risk_flag f
    LEFT JOIN gold.dim_company d ON d.company_number = f.company_number
    CROSS JOIN LATERAL (VALUES
        ('Accounts overdue',        'High',   f.f_accounts_overdue),
        ('Confirmation overdue',    'Medium', f.f_conf_stmt_overdue),
        ('Strike-off proposed',     'High',   f.f_strike_off),
        ('Insolvency history',      'High',   f.f_insolvency_history),
        ('Dormant',                 'Medium', f.f_dormant),
        ('Officer turnover',        'Medium', f.f_officer_turnover),
        ('Network risk (high)',     'High',   f.f_network_risk_high),
        ('Network risk (medium)',   'Medium', f.f_network_risk_medium),
        ('Going concern (AI)',      'High',   f.f_going_concern),
        ('Auditor resignation (AI)','High',   f.f_auditor_resignation),
        ('Related party (AI)',      'Medium', f.f_related_party)
    ) AS v(flag_name, flag_severity, is_on)
) x
WHERE is_on = true;