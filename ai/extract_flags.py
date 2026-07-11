"""
LLM EXTRACTION (v2 - calibrated): send each stored accounts PDF to Claude and
extract three risk signals as structured JSON:
  - going_concern       (material uncertainty, or accounts on a non-going-concern basis)
  - auditor_resignation (auditor resigned or was removed)
  - related_party       (a MATERIAL connected-party transaction, not routine group balances)

Claude reads the PDF natively (no separate PDF parser needed). Results are
stored in gold.ai_extracted_flags, ready to feed fact_risk_flag.

v2 calibration (see EVALUATION.md): v1 flagged related_party in 100% of
companies - all false positives from routine intra-group balances, and in some
cases the note explicitly said no related-party transactions occurred. The
prompt below hardens the related-party rule to require a material connected-party
transaction and to respect negations / FRS 102 group exemptions.

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
Read the attached accounts PDF and determine, STRICTLY from what the document
actually says, whether each item below is present. Base every answer only on the
document's own words. When in doubt, answer false.

Return ONLY a JSON object, no other text, in exactly this shape:
{
  "going_concern": {"present": true/false, "evidence": "<short quote or ''>"},
  "auditor_resignation": {"present": true/false, "evidence": "<short quote or ''>"},
  "related_party": {"present": true/false, "evidence": "<short quote or ''>"},
  "accounts_kind": "full | dormant | micro | abridged | unknown"
}

GOING CONCERN
- present = true ONLY if the accounts express material uncertainty about the
  company continuing as a going concern, OR state they are prepared on a basis
  OTHER than going concern (e.g. because the company will be liquidated or cease
  operations), OR the auditor gives a going-concern emphasis of matter.
- A routine "prepared on the going concern basis" statement with no caveat is
  NOT material uncertainty. Mark it false.

AUDITOR RESIGNATION
- present = true ONLY if the text says the auditor resigned or was removed.
- Reappointment, or willingness to be reappointed, is NOT resignation. Mark false.

RELATED PARTY  (be strict - this is the hard one)
- present = true ONLY if the accounts disclose a MATERIAL, ACTUAL transaction with
  a connected party: a director, a director's close family, key management, or an
  entity personally connected to a director, especially on non-commercial terms.
- present = FALSE if the only related-party content is routine intra-group
  balances or trading, i.e. "amounts owed to/from group undertakings", parent,
  subsidiaries, or fellow subsidiaries. These are normal and are NOT the signal.
- present = FALSE if the related-party note says there were NO related-party
  transactions, or that the company has taken the FRS 102 group exemption from
  disclosing intra-group transactions. Respect these negations even if the words
  "related party" appear nearby.
- evidence must quote the specific connected-party transaction. If the only thing
  you can quote is a group balance or a "no transactions"/exemption statement,
  then present = false and evidence = "".

accounts_kind: classify the document (full / dormant / micro / abridged / unknown).
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