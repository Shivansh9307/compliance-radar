-- ============================================================
-- SILVER LAYER: clean and structure the bronze data
-- Re-runnable: each table is dropped and rebuilt.
-- Run with:
--   docker exec -i compliance-pg psql -U postgres -d compliance < transform/silver.sql
-- ============================================================

-- ---------- 1. Cleaned companies (from the bulk register) ----------
DROP TABLE IF EXISTS silver.companies CASCADE;

CREATE TABLE silver.companies AS
WITH base AS (
    SELECT
        companynumber                                             AS company_number,
        trim(companyname)                                         AS company_name,
        companystatus                                             AS company_status,
        upper(regexp_replace(coalesce(regaddress_postcode,''), '\s', '', 'g')) AS postcode_key,
        regaddress_posttown                                       AS post_town,
        -- Companies House bulk dates are DD/MM/YYYY text; NULLIF guards blanks
        to_date(NULLIF(incorporationdate, ''),   'DD/MM/YYYY')    AS incorporation_date,
        to_date(NULLIF(accounts_nextduedate, ''),'DD/MM/YYYY')    AS accounts_next_due,
        to_date(NULLIF(confstmtnextduedate, ''), 'DD/MM/YYYY')    AS conf_stmt_next_due,
        -- SIC code split out of "12345 - Description"
        NULLIF(split_part(coalesce(siccode_sictext_1,''), ' - ', 1), '') AS sic_code,
        siccode_sictext_1                                         AS sic_text
    FROM bronze.companies_raw
    WHERE companynumber IS NOT NULL
)
SELECT
    base.*,
    (company_status = 'Active')                                          AS is_active,
    (accounts_next_due  < current_date AND company_status = 'Active')     AS accounts_overdue,
    (conf_stmt_next_due < current_date AND company_status = 'Active')     AS conf_stmt_overdue
FROM base;

-- ---------- 2. Live company status (from the enriched profile JSON) ----------
DROP TABLE IF EXISTS silver.company_live CASCADE;

CREATE TABLE silver.company_live AS
SELECT
    company_number,
    profile->>'company_name'                                    AS company_name,
    profile->>'company_status'                                  AS live_status,
    profile->>'type'                                            AS company_type,
    (profile->'accounts'->'next_accounts'->>'due_on')::date     AS accounts_due_on,
    (profile->'accounts'->'next_accounts'->>'overdue')::boolean AS accounts_overdue,
    (profile->'confirmation_statement'->>'next_due')::date      AS conf_stmt_due,
    (profile->'confirmation_statement'->>'overdue')::boolean    AS conf_stmt_overdue,
    (profile->>'has_insolvency_history')::boolean               AS has_insolvency_history,
    (profile->>'has_charges')::boolean                          AS has_charges,
    fetched_at
FROM bronze.company_enrichment
WHERE profile IS NOT NULL;

-- ---------- 3. Officers, one row per officer (from the officers JSON) ----------
DROP TABLE IF EXISTS silver.officers CASCADE;

CREATE TABLE silver.officers AS
SELECT
    e.company_number,
    off->>'name'                             AS officer_name,
    off->>'officer_role'                     AS officer_role,
    (off->>'appointed_on')::date             AS appointed_on,
    (off->>'resigned_on')::date              AS resigned_on,
    (off->'date_of_birth'->>'month')::int    AS dob_month,
    (off->'date_of_birth'->>'year')::int     AS dob_year,
    off->>'nationality'                      AS nationality
FROM bronze.company_enrichment e,
     jsonb_array_elements(e.officers->'items') AS off
WHERE jsonb_typeof(e.officers->'items') = 'array';

-- ---------- 4. Filings, one row per filing (from the filing_history JSON) ----------
DROP TABLE IF EXISTS silver.filings CASCADE;

CREATE TABLE silver.filings AS
SELECT
    e.company_number,
    (fil->>'date')::date        AS filing_date,
    fil->>'type'                AS filing_type,
    fil->>'category'            AS filing_category,
    fil->>'description'         AS filing_description
FROM bronze.company_enrichment e,
     jsonb_array_elements(e.filing_history->'items') AS fil
WHERE jsonb_typeof(e.filing_history->'items') = 'array';