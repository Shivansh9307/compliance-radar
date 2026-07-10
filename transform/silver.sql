-- ============================================================
-- SILVER LAYER: clean and structure the bronze data
--
-- Re-runnable: each table is dropped and rebuilt from bronze.
-- Run with:
--   docker exec -i compliance-pg psql -U postgres -d compliance < transform/silver.sql
--
-- v2 changes (from inspecting jsonb_pretty(officers)):
--   - capture person_number + officer_id (stable-ish identifiers)
--   - flag corporate officers (companies, not people)
--   - handle pre-1992 appointments (appointed_before, not appointed_on)
--   - derive is_active_officer from absence of resigned_on
--   - pull the free active/resigned/total counts from the officers envelope
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
    (company_status = 'Active')                                       AS is_active,
    (accounts_next_due  < current_date AND company_status = 'Active') AS accounts_overdue,
    (conf_stmt_next_due < current_date AND company_status = 'Active') AS conf_stmt_overdue
FROM base;


-- ---------- 2. Live company status (from the enriched profile JSON) ----------
DROP TABLE IF EXISTS silver.company_live CASCADE;

CREATE TABLE silver.company_live AS
SELECT
    e.company_number,
    e.profile->>'company_name'                                     AS company_name,
    e.profile->>'company_status'                                   AS live_status,
    e.profile->>'type'                                             AS company_type,
    (e.profile->'accounts'->'next_accounts'->>'due_on')::date      AS accounts_due_on,
    (e.profile->'accounts'->'next_accounts'->>'overdue')::boolean  AS accounts_overdue,
    (e.profile->'accounts'->'last_accounts'->>'type')              AS last_accounts_type,
    (e.profile->'confirmation_statement'->>'next_due')::date       AS conf_stmt_due,
    (e.profile->'confirmation_statement'->>'overdue')::boolean     AS conf_stmt_overdue,
    (e.profile->>'has_insolvency_history')::boolean                AS has_insolvency_history,
    (e.profile->>'has_charges')::boolean                           AS has_charges,
    (e.profile->>'has_been_liquidated')::boolean                   AS has_been_liquidated,
    (e.profile->>'date_of_creation')::date                         AS date_of_creation,
    -- free summary counts from the officers envelope (no need to compute them)
    (e.officers->>'active_count')::int                             AS active_officer_count,
    (e.officers->>'resigned_count')::int                           AS resigned_officer_count,
    (e.officers->>'total_results')::int                            AS total_officer_count,
    -- if a company has more officers than one page, our data is truncated
    ((e.officers->>'total_results')::int
       > (e.officers->>'items_per_page')::int)                     AS officers_truncated,
    e.fetched_at
FROM bronze.company_enrichment e
WHERE e.profile IS NOT NULL;


-- ---------- 3. Officers, one row per officer appointment ----------
-- NOTE: one row = one APPOINTMENT, not one person. The same person can appear
-- twice at the same company (e.g. secretary and director). Dedupe in gold.
DROP TABLE IF EXISTS silver.officers CASCADE;

CREATE TABLE silver.officers AS
SELECT
    e.company_number,
    off->>'name'                                                   AS officer_name,
    off->>'officer_role'                                           AS officer_role,
    off->>'person_number'                                          AS person_number,
    -- stable-ish officer id, extracted from /officers/{id}/appointments
    NULLIF(split_part(off->'links'->'officer'->>'appointments', '/', 3), '') AS officer_id,
    -- corporate officers are companies, not people (no DOB, no nationality)
    (off->>'officer_role' LIKE 'corporate-%')                      AS is_corporate,
    (off->>'appointed_on')::date                                   AS appointed_on,
    (off->>'appointed_before')::date                               AS appointed_before,
    -- one usable date: real appointment date, or the pre-1992 fallback
    COALESCE((off->>'appointed_on')::date,
             (off->>'appointed_before')::date)                     AS appointed_effective,
    (off->>'resigned_on')::date                                    AS resigned_on,
    (off->>'resigned_on' IS NULL)                                  AS is_active_officer,
    COALESCE((off->>'is_pre_1992_appointment')::boolean, false)    AS is_pre_1992,
    (off->'date_of_birth'->>'month')::int                          AS dob_month,
    (off->'date_of_birth'->>'year')::int                           AS dob_year,
    off->>'nationality'                                            AS nationality,
    off->>'country_of_residence'                                   AS country_of_residence,
    off->'address'->>'postal_code'                                 AS officer_postcode
FROM bronze.company_enrichment e,
     jsonb_array_elements(e.officers->'items') AS off
WHERE jsonb_typeof(e.officers->'items') = 'array';


-- ---------- 4. Filings, one row per filing ----------
DROP TABLE IF EXISTS silver.filings CASCADE;

CREATE TABLE silver.filings AS
SELECT
    e.company_number,
    (fil->>'date')::date                                           AS filing_date,
    fil->>'type'                                                   AS filing_type,
    fil->>'category'                                               AS filing_category,
    fil->>'subcategory'                                            AS filing_subcategory,
    fil->>'description'                                            AS filing_description
FROM bronze.company_enrichment e,
     jsonb_array_elements(e.filing_history->'items') AS fil
WHERE jsonb_typeof(e.filing_history->'items') = 'array';


-- ---------- 5. Indexes (make the gold-layer joins fast) ----------
CREATE INDEX IF NOT EXISTS idx_companies_number   ON silver.companies (company_number);
CREATE INDEX IF NOT EXISTS idx_live_number        ON silver.company_live (company_number);
CREATE INDEX IF NOT EXISTS idx_officers_number    ON silver.officers (company_number);
CREATE INDEX IF NOT EXISTS idx_officers_officerid ON silver.officers (officer_id);
CREATE INDEX IF NOT EXISTS idx_filings_number     ON silver.filings (company_number);