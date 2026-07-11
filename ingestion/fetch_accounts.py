"""
Fetch the most recent ACCOUNTS document for each enriched company from the
Companies House Document API, extract its text, and store it in
bronze.accounts_documents for LLM extraction.

Prefers iXBRL (application/xhtml+xml), which carries the accounts narrative
as text (going concern, auditor's report, related-party notes). Companies
whose latest accounts are PDF-only are recorded as 'pdf_only' and skipped
for now (handled in a later step).

Usage:
    python ingestion/fetch_accounts.py --company 00063121   # test one first
    python ingestion/fetch_accounts.py --limit 3            # small batch
    python ingestion/fetch_accounts.py                      # all available
"""
import os, sys, time, requests
from bs4 import BeautifulSoup
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

load_dotenv()
CH_API_KEY = os.environ["CH_API_KEY"]
DATABASE_URL = os.environ["DATABASE_URL"]
PAUSE = 0.6
TIMEOUT = 60

session = requests.Session()
session.auth = (CH_API_KEY, "")   # key = username, blank password


def fetch_document_text(doc_url):
    """Return (format, text) for an accounts document, preferring iXBRL."""
    meta = session.get(doc_url, timeout=TIMEOUT)          # 1. what formats exist?
    if meta.status_code != 200:
        return None, None
    resources = (meta.json() or {}).get("resources", {})
    content_url = doc_url + "/content"

    if "application/xhtml+xml" in resources:              # 2. prefer iXBRL -> text
        r = session.get(content_url,
                        headers={"Accept": "application/xhtml+xml"},
                        timeout=TIMEOUT)
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, "html.parser")
            return "xhtml", soup.get_text(separator=" ", strip=True)

    if "application/pdf" in resources:                    # 3. pdf-only: note + skip
        return "pdf_only", None
    return None, None


def main(limit=None, company=None):
    engine = create_engine(DATABASE_URL)

    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS bronze.accounts_documents (
                company_number text PRIMARY KEY,
                filing_date    date,
                accounts_type  text,
                doc_format     text,
                doc_text       text,
                char_count     int,
                fetched_at     timestamptz DEFAULT now()
            )
        """))

    # most recent accounts filing per company that has a document link
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
            ORDER BY e.company_number, (fil->>'date')::date DESC
        )
        SELECT c.* FROM candidates c
        LEFT JOIN bronze.accounts_documents ad ON ad.company_number = c.company_number
        WHERE ad.company_number IS NULL
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
    print(f"Fetching accounts for {len(rows)} companies ...")

    done = 0
    for r in rows:
        try:
            fmt, txt = fetch_document_text(r.doc_url)
            time.sleep(PAUSE)
        except Exception as e:
            print(f"  {r.company_number}: failed ({e}) - skipping")
            continue

        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO bronze.accounts_documents
                    (company_number, filing_date, accounts_type, doc_format,
                     doc_text, char_count, fetched_at)
                VALUES (:cn, :fd, :at, :fmt, :txt, :cc, now())
                ON CONFLICT (company_number) DO UPDATE SET
                    filing_date = EXCLUDED.filing_date,
                    accounts_type = EXCLUDED.accounts_type,
                    doc_format = EXCLUDED.doc_format,
                    doc_text = EXCLUDED.doc_text,
                    char_count = EXCLUDED.char_count,
                    fetched_at = now()
            """), {
                "cn": r.company_number, "fd": r.filing_date,
                "at": r.description, "fmt": fmt,
                "txt": txt, "cc": len(txt) if txt else 0,
            })
        done += 1
        print(f"  [{done}/{len(rows)}] {r.company_number} - {fmt}, "
              f"{len(txt) if txt else 0} chars")

    print(f"\nFinished. {done} companies processed.")


if __name__ == "__main__":
    limit = None
    company = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    if "--company" in sys.argv:
        company = sys.argv[sys.argv.index("--company") + 1]
    main(limit=limit, company=company)