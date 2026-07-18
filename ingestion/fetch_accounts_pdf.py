"""
Fetch the most recent ACCOUNTS document (PDF) for each enriched company from
the Companies House Document API and store the raw PDF bytes in
bronze.accounts_pdfs, ready for Claude to read directly.

Usage:
    python ingestion/fetch_accounts_pdf.py --company 00063121   # test one
    python ingestion/fetch_accounts_pdf.py --limit 3
    python ingestion/fetch_accounts_pdf.py                      # all available
"""
import os, sys, time, requests
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

load_dotenv()
CH_API_KEY = os.environ["CH_API_KEY"]
DATABASE_URL = os.environ["DATABASE_URL"]
PAUSE = 0.6
TIMEOUT = 90

session = requests.Session()
session.auth = (CH_API_KEY, "")


def fetch_pdf(doc_url):
    """Return raw PDF bytes for an accounts document, or None."""
    r = session.get(doc_url + "/content",
                    headers={"Accept": "application/pdf"},
                    timeout=TIMEOUT)
    if r.status_code == 200 and r.content[:4] == b"%PDF":   # sanity: real PDF
        return r.content
    return None


def main(limit=None, company=None):
    engine = create_engine(DATABASE_URL)

    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS bronze.accounts_pdfs (
                company_number text PRIMARY KEY,
                filing_date    date,
                accounts_type  text,
                pdf_bytes      bytea,
                size_bytes     int,
                fetched_at     timestamptz DEFAULT now()
            )
        """))

    query = """
    WITH candidates AS (
        SELECT DISTINCT ON (e.company_number)
            e.company_number,
            (fil->>'date')::date               AS filing_date,
            fil->>'description'                AS description,
            fil->'links'->>'document_metadata' AS doc_url
        FROM bronze.company_enrichment e,
             jsonb_array_elements(e.filing_history->'items') AS fil
        WHERE fil->>'category' = 'accounts'
          AND fil->'links'->>'document_metadata' IS NOT NULL
          AND e.company_number IN (
                SELECT company_number
                FROM bronze.sample_targets
          )
        ORDER BY e.company_number,
                 (fil->>'date')::date DESC
    )
    SELECT c.*
    FROM candidates c
    LEFT JOIN bronze.accounts_pdfs ap
           ON ap.company_number = c.company_number
    WHERE ap.company_number IS NULL
"""
    params = {}
    if company:
        query += " AND c.company_number = :company"
        params["company"] = company
    query += " ORDER BY c.filing_date DESC"
    if limit:
        query += " LIMIT :limit"
        params["limit"] = limit

    with engine.begin() as conn:
        rows = conn.execute(text(query), params).fetchall()

    if not rows:
        print("Nothing new to fetch.")
        return
    print(f"Fetching PDFs for {len(rows)} companies ...")

    done = 0
    for r in rows:
        try:
            pdf = fetch_pdf(r.doc_url)
            time.sleep(PAUSE)
        except Exception as e:
            print(f"  {r.company_number}: failed ({e}) - skipping")
            continue
        if pdf is None:
            print(f"  {r.company_number}: no PDF returned - skipping")
            continue

        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO bronze.accounts_pdfs
                    (company_number, filing_date, accounts_type,
                     pdf_bytes, size_bytes, fetched_at)
                VALUES (:cn, :fd, :at, :pdf, :sz, now())
                ON CONFLICT (company_number) DO UPDATE SET
                    filing_date = EXCLUDED.filing_date,
                    accounts_type = EXCLUDED.accounts_type,
                    pdf_bytes = EXCLUDED.pdf_bytes,
                    size_bytes = EXCLUDED.size_bytes,
                    fetched_at = now()
            """), {
                "cn": r.company_number, "fd": r.filing_date,
                "at": r.description, "pdf": pdf, "sz": len(pdf),
            })
        done += 1
        print(f"  [{done}/{len(rows)}] {r.company_number} - {len(pdf):,} bytes")

    print(f"\nFinished. {done} PDFs stored.")


if __name__ == "__main__":
    limit = None
    company = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    if "--company" in sys.argv:
        company = sys.argv[sys.argv.index("--company") + 1]
    main(limit=limit, company=company)