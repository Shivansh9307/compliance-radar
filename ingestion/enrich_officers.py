"""
Enrich each active human director with their FULL appointment history
across the entire Companies House register.

Why this exists:
  The company 'officers' endpoint only lists officers of THAT company.
  To find a director's OTHER companies (their network), we call the
  officer-centric endpoint: /officers/{officer_id}/appointments,
  which returns every company that person is appointed to, with each
  company's status. That is what lets us evaluate the network-risk flag
  ("director linked to 3+ dissolved/insolvent companies") against the
  whole register, not just our small sample.

Pagination: the API returns 35 appointments per page by default. Directors
with long histories (exactly the high-risk ones) would be silently
truncated, so this script fetches ALL pages and stitches them together.

Raw JSON is stored in bronze.officer_appointments. Resumable: re-running
skips directors already fetched.

Usage:
    python ingestion/enrich_officers.py --limit 3     # small test FIRST
    python ingestion/enrich_officers.py               # default batch
    python ingestion/enrich_officers.py --limit 1000  # everyone
"""
import os, sys, time, json, requests
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

load_dotenv()
CH_API_KEY = os.environ["CH_API_KEY"]
DATABASE_URL = os.environ["DATABASE_URL"]
BASE = "https://api.company-information.service.gov.uk"

DEFAULT_LIMIT = 500    # active human directors is a small set; this covers most
PAGE_SIZE = 50         # appointments per API page (max is 50)
PAUSE = 0.6            # seconds between API calls (stays under 600 / 5 min)
TIMEOUT = 30

session = requests.Session()
session.auth = (CH_API_KEY, "")   # key = username, blank password


def get(path):
    """Call one API endpoint, handling rate limits and missing data."""
    while True:
        resp = session.get(BASE + path, timeout=TIMEOUT)
        if resp.status_code == 200:
            return resp.json()
        if resp.status_code == 404:
            return None
        if resp.status_code == 429:                       # rate limited
            wait = int(resp.headers.get("Retry-After", 30))
            print(f"  rate limited, waiting {wait}s ...")
            time.sleep(wait)
            continue
        resp.raise_for_status()


def get_all_appointments(officer_id):
    """
    Fetch EVERY appointment page for one officer and stitch them into a
    single response. Returns the first page's envelope (which carries the
    counts, date_of_birth, etc.) with its 'items' replaced by the full list.
    """
    items, start, envelope = [], 0, None
    while True:
        page = get(
            f"/officers/{officer_id}/appointments"
            f"?items_per_page={PAGE_SIZE}&start_index={start}"
        )
        if not page:
            break
        if envelope is None:
            envelope = page                               # keep the metadata
        batch = page.get("items", [])
        items.extend(batch)
        total = page.get("total_results", 0)
        start += len(batch)
        if not batch or start >= total:                   # got everything
            break
        time.sleep(PAUSE)                                 # pace between pages

    if envelope is None:
        return None
    envelope["items"] = items                             # full list, not one page
    return envelope


def main(limit):
    engine = create_engine(DATABASE_URL)

    # 1. target table
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS bronze.officer_appointments (
                officer_id     text PRIMARY KEY,
                officer_name   text,
                appointments   jsonb,
                total_results  int,
                pages_complete boolean,
                fetched_at     timestamptz DEFAULT now()
            )
        """))

    # 2. pick active, human directors not yet fetched
    with engine.begin() as conn:
        rows = conn.execute(text("""
            SELECT o.officer_id, min(o.officer_name) AS officer_name
            FROM silver.officers o
            LEFT JOIN bronze.officer_appointments oa
                   ON oa.officer_id = o.officer_id
            WHERE o.is_corporate = false
              AND o.is_active_officer = true
              AND o.officer_id IS NOT NULL
             AND EXISTS (
    SELECT 1
    FROM bronze.sample_targets st
    WHERE st.company_number = o.company_number
)                  
              AND oa.officer_id IS NULL
            GROUP BY o.officer_id
            ORDER BY o.officer_id
            LIMIT :limit
        """), {"limit": limit}).fetchall()

    targets = [(r[0], r[1]) for r in rows]
    if not targets:
        print("Nothing new to enrich. All active directors already done.")
        return
    print(f"Enriching appointment history for {len(targets)} directors ...")

    # 3. fetch (all pages) and store
    done = 0
    for officer_id, officer_name in targets:
        try:
            data = get_all_appointments(officer_id)
            time.sleep(PAUSE)
        except Exception as e:
            print(f"  {officer_id}: failed ({e}) - skipping")
            continue

        total = (data or {}).get("total_results")
        fetched = len((data or {}).get("items", []))
        pages_complete = (total is None) or (fetched >= total)

        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO bronze.officer_appointments
                    (officer_id, officer_name, appointments, total_results,
                     pages_complete, fetched_at)
                VALUES
                    (:oid, :name, CAST(:appts AS jsonb), :total, :complete, now())
                ON CONFLICT (officer_id) DO UPDATE SET
                    officer_name   = EXCLUDED.officer_name,
                    appointments   = EXCLUDED.appointments,
                    total_results  = EXCLUDED.total_results,
                    pages_complete = EXCLUDED.pages_complete,
                    fetched_at     = now()
            """), {
                "oid": officer_id,
                "name": officer_name,
                "appts": json.dumps(data),
                "total": total,
                "complete": pages_complete,
            })
        done += 1
        flag = "" if pages_complete else "  (INCOMPLETE)"
        print(f"  [{done}/{len(targets)}] {officer_name} "
              f"- {fetched}/{total} appts{flag}")

    print(f"\nFinished. {done} directors enriched this run.")


if __name__ == "__main__":
    limit = DEFAULT_LIMIT
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    main(limit)