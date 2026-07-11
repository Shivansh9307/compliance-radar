-- ============================================================
-- GOLD LAYER (part 2): star schema dimensions + fact_filing
--
-- Completes the star around gold.fact_risk_flag:
--   dim_company  - one row per company (the descriptive attributes)
--   dim_officer  - one row per unique person (deduped by officer_id)
--   dim_sic      - SIC code -> description lookup
--   fact_filing  - one row per filing event (from enriched companies)
--
-- Run AFTER gold.sql and network_risk.sql.
-- Run: docker exec -i compliance-pg psql -U postgres -d compliance < transform/gold_star.sql
-- ============================================================

-- ---------- DIM: company ----------
DROP TABLE IF EXISTS gold.dim_company CASCADE;

CREATE TABLE gold.dim_company AS
SELECT
    c.company_number,                               -- primary key
    c.company_name,
    COALESCE(cl.live_status, c.company_status)  AS company_status,
    cl.company_type,
    c.incorporation_date,
    COALESCE(cl.date_of_creation, c.incorporation_date) AS date_of_creation,
    c.postcode_key,
    c.post_town,
    c.sic_code,
    (cl.company_number IS NOT NULL)             AS is_enriched
FROM silver.companies c
LEFT JOIN silver.company_live cl ON cl.company_number = c.company_number;

ALTER TABLE gold.dim_company ADD PRIMARY KEY (company_number);

-- ---------- DIM: officer (one row per unique person) ----------
-- silver.officers is one row per APPOINTMENT; here we collapse to one
-- row per person (officer_id) so it can be a proper dimension.
DROP TABLE IF EXISTS gold.dim_officer CASCADE;

CREATE TABLE gold.dim_officer AS
SELECT
    o.officer_id,                                   -- primary key
    max(o.officer_name)                          AS officer_name,
    max(o.nationality)                           AS nationality,
    max(o.dob_year)                              AS dob_year,
    max(o.dob_month)                             AS dob_month,
    count(DISTINCT o.company_number)             AS appointments_in_book,
    -- carry the network-risk classification if we computed one
    max(d.insolvent_companies)                   AS insolvent_companies,
    max(d.classification)                        AS network_classification
FROM silver.officers o
LEFT JOIN gold.director_network_risk d ON d.officer_id = o.officer_id
WHERE o.is_corporate = false
  AND o.officer_id IS NOT NULL
GROUP BY o.officer_id;

ALTER TABLE gold.dim_officer ADD PRIMARY KEY (officer_id);

-- ---------- DIM: SIC code lookup ----------
DROP TABLE IF EXISTS gold.dim_sic CASCADE;

CREATE TABLE gold.dim_sic AS
SELECT DISTINCT
    sic_code,
    -- the sic_text held "12345 - Description"; keep the description half
    NULLIF(trim(split_part(sic_text, ' - ', 2)), '') AS sic_description
FROM silver.companies
WHERE sic_code IS NOT NULL;

-- some companies share a code; keep one description per code
DROP TABLE IF EXISTS gold.dim_sic_clean CASCADE;
CREATE TABLE gold.dim_sic_clean AS
SELECT sic_code, max(sic_description) AS sic_description
FROM gold.dim_sic
GROUP BY sic_code;
DROP TABLE gold.dim_sic;
ALTER TABLE gold.dim_sic_clean RENAME TO dim_sic;
ALTER TABLE gold.dim_sic ADD PRIMARY KEY (sic_code);

-- ---------- FACT: filings ----------
DROP TABLE IF EXISTS gold.fact_filing CASCADE;

CREATE TABLE gold.fact_filing AS
SELECT
    company_number,                                 -- foreign key -> dim_company
    filing_date,
    filing_type,
    filing_category,
    filing_subcategory,
    filing_description
FROM silver.filings
WHERE filing_date IS NOT NULL;

CREATE INDEX idx_fact_filing_company ON gold.fact_filing (company_number);
CREATE INDEX idx_fact_filing_date    ON gold.fact_filing (filing_date DESC);