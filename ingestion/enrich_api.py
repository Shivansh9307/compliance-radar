"""
Enrich a subset of companies with live data from the Companies House API.

For each company it fetches:
  - the company profile   (live status: active / dormant / strike-off)
  - the officers          (directors, appointments, resignations)
  - the filing history    (recent filings)

Raw JSON is stored in bronze.company_enrichment. The script is resumable:
re-running it skips companies already enriched and picks up new ones.

Usage:
    python ingestion/enrich_api.py                # enrich the default number
    python ingestion/enrich_api.py --limit 500    # enrich up to 500 new companies
"""
import os
import sys
import time
import json
import requests
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

load_dotenv()

CH_API_KEY = os.environ["CH_API_KEY"]
DATABASE_URL = os.environ["DATABASE_URL"]
BASE = "https://api.company-information.service.gov.uk"

DEFAULT_LIMIT = 50     # how many NEW companies to enrich per run
PAUSE = 0.6            # seconds between API calls (stays under 600 / 5 min)
TIMEOUT = 30           # seconds before giving up on a single request

session = requests.Session()
session.auth = (CH_API_KEY, "")   # key = username, blank password


def get(path):
    """Call one API endpoint, handling rate limits and missing data."""
    while True:
        resp = session.get(BASE + path, timeout=TIMEOUT)
        if resp.status_code == 200:
            return resp.json()
        if resp.status_code == 404:
            return None                       # e.g. a company with no officers
        if resp.status_code == 429:           # rate limited -> wait and retry
            wait = int(resp.headers.get("Retry-After", 30))
            print(f"  rate limited, waiting {wait}s ...")
            time.sleep(wait)
            continue
        resp.raise_for_status()               # anything else is a real error


def enrich_one(company_number):
    profile = get(f"/company/{company_number}")
    time.sleep(PAUSE)
    officers = get(f"/company/{company_number}/officers")
    time.sleep(PAUSE)
    filings = get(f"/company/{company_number}/filing-history")
    time.sleep(PAUSE)
    return profile, officers, filings


def main(limit):
    engine = create_engine(DATABASE_URL)

    # 1. make sure the target table exists
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS bronze.company_enrichment (
                company_number  text PRIMARY KEY,
                profile         jsonb,
                officers        jsonb,
                filing_history  jsonb,
                fetched_at      timestamptz DEFAULT now()
            )
        """))

    # 2. pick companies we haven't enriched yet
    with engine.begin() as conn:
        rows = conn.execute(text("""
            SELECT c.companynumber
            FROM bronze.companies_raw c
            LEFT JOIN bronze.company_enrichment e
                   ON e.company_number = c.companynumber
            WHERE e.company_number IS NULL
              AND c.companynumber IS NOT NULL
            ORDER BY c.companynumber
            LIMIT :limit
        """), {"limit": limit}).fetchall()

    targets = [r[0] for r in rows]
    if not targets:
        print("Nothing new to enrich. All selected companies already done.")
        return
    print(f"Enriching {len(targets)} companies ...")

    # 3. enrich and store, one at a time
    done = 0
    for cn in targets:
        try:
            profile, officers, filings = enrich_one(cn)
        except Exception as e:
            print(f"  {cn}: failed ({e}) - skipping")
            continue

        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO bronze.company_enrichment
                    (company_number, profile, officers, filing_history, fetched_at)
                VALUES
                    (:cn, CAST(:profile AS jsonb), CAST(:officers AS jsonb),
                     CAST(:filings AS jsonb), now())
                ON CONFLICT (company_number) DO UPDATE SET
                    profile        = EXCLUDED.profile,
                    officers       = EXCLUDED.officers,
                    filing_history = EXCLUDED.filing_history,
                    fetched_at     = now()
            """), {
                "cn": cn,
                "profile":  json.dumps(profile),
                "officers": json.dumps(officers),
                "filings":  json.dumps(filings),
            })
        done += 1
        print(f"  [{done}/{len(targets)}] {cn} done")

    print(f"\nFinished. {done} companies enriched this run.")


if __name__ == "__main__":
    limit = DEFAULT_LIMIT
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    main(limit)