"""
LLM EXTRACTION: send each stored accounts PDF to Claude and extract three
risk signals as structured JSON:
  - going_concern       (material uncertainty about continuing to trade)
  - auditor_resignation (auditor resigned or was removed)
  - related_party       (significant related-party transactions)

Claude reads the PDF natively (no separate PDF parser needed). Results are
stored in gold.ai_extracted_flags, ready to feed fact_risk_flag.

Usage:
    python ai/extract_flags.py --company 00063121   # test one first
    python ai/extract_flags.py --limit 3
    python ai/extract_flags.py                       # all stored PDFs
"""
import os, sys, json, base64, time
from dotenv import load_dotenv
from anthropic import Anthropic
from sqlalchemy import create_engine, text

load_dotenv()
client = Anthropic(api_key=os.environ["LLM_API_KEY"])
engine = create_engine(os.environ["DATABASE_URL"])
MODEL = "claude-haiku-4-5-20251001"   # cheap model for bulk extraction

PROMPT = """You are a compliance analyst reading a UK company's filed accounts.
Read the attached accounts PDF and determine, strictly from its text, whether
each of the following is present. Answer only about what the document actually says.

Return ONLY a JSON object, no other text, in exactly this shape:
{
  "going_concern": {"present": true/false, "evidence": "<short quote or ''>"},
  "auditor_resignation": {"present": true/false, "evidence": "<short quote or ''>"},
  "related_party": {"present": true/false, "evidence": "<short quote or ''>"},
  "accounts_kind": "full | dormant | micro | abridged | unknown"
}

Rules:
- going_concern.present = true ONLY if the accounts express material uncertainty
  about the company continuing as a going concern. A routine "prepared on a going
  concern basis" statement is NOT material uncertainty; mark it false.
- auditor_resignation.present = true only if the text indicates the auditor
  resigned or was removed.
- related_party.present = true only if significant related-party transactions are disclosed.
- evidence must be a short phrase copied from the document, or "" if not present.
"""


def extract_one(company_number, pdf_bytes):
    b64 = base64.standard_b64encode(pdf_bytes).decode("utf-8")
    resp = client.messages.create(
        model=MODEL,
        max_tokens=1000,
        messages=[{
            "role": "user",
            "content": [
                {"type": "document",
                 "source": {"type": "base64",
                            "media_type": "application/pdf",
                            "data": b64}},
                {"type": "text", "text": PROMPT},
            ],
        }],
    )
    raw = resp.content[0].text.strip()
    # be forgiving if the model wraps JSON in ```json fences
    raw = raw.replace("```json", "").replace("```", "").strip()
    return json.loads(raw)


def main(limit=None, company=None):
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS gold.ai_extracted_flags (
                company_number      text PRIMARY KEY,
                going_concern       boolean,
                going_concern_ev    text,
                auditor_resignation boolean,
                auditor_resign_ev   text,
                related_party       boolean,
                related_party_ev    text,
                accounts_kind       text,
                model               text,
                extracted_at        timestamptz DEFAULT now()
            )
        """))

    q = "SELECT company_number, pdf_bytes FROM bronze.accounts_pdfs WHERE pdf_bytes IS NOT NULL"
    params = {}
    if company:
        q += " AND company_number = :c"; params["c"] = company
    if limit:
        q += " LIMIT :l"; params["l"] = limit

    with engine.begin() as conn:
        rows = conn.execute(text(q), params).fetchall()

    print(f"Extracting from {len(rows)} PDFs with {MODEL} ...")
    done = 0
    for r in rows:
        try:
            result = extract_one(r.company_number, r.pdf_bytes)
        except Exception as e:
            print(f"  {r.company_number}: failed ({e}) - skipping")
            continue

        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO gold.ai_extracted_flags
                    (company_number, going_concern, going_concern_ev,
                     auditor_resignation, auditor_resign_ev,
                     related_party, related_party_ev, accounts_kind,
                     model, extracted_at)
                VALUES (:cn, :gc, :gce, :ar, :are, :rp, :rpe, :ak, :m, now())
                ON CONFLICT (company_number) DO UPDATE SET
                    going_concern=:gc, going_concern_ev=:gce,
                    auditor_resignation=:ar, auditor_resign_ev=:are,
                    related_party=:rp, related_party_ev=:rpe,
                    accounts_kind=:ak, model=:m, extracted_at=now()
            """), {
                "cn": r.company_number,
                "gc": result["going_concern"]["present"],
                "gce": result["going_concern"]["evidence"],
                "ar": result["auditor_resignation"]["present"],
                "are": result["auditor_resignation"]["evidence"],
                "rp": result["related_party"]["present"],
                "rpe": result["related_party"]["evidence"],
                "ak": result.get("accounts_kind", "unknown"),
                "m": MODEL,
            })
        done += 1
        gc = "GC" if result["going_concern"]["present"] else "  "
        rp = "RP" if result["related_party"]["present"] else "  "
        print(f"  [{done}/{len(rows)}] {r.company_number} - {result.get('accounts_kind','?'):8} {gc} {rp}")
        time.sleep(0.5)

    print(f"\nFinished. {done} extractions stored.")


if __name__ == "__main__":
    limit = None; company = None
    if "--limit" in sys.argv: limit = int(sys.argv[sys.argv.index("--limit")+1])
    if "--company" in sys.argv: company = sys.argv[sys.argv.index("--company")+1]
    main(limit=limit, company=company)