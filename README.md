# UK Corporate Compliance Radar

An end-to-end data and AI pipeline that ingests the UK Companies House register, computes explainable risk flags, reads company accounts with an LLM, and surfaces a ranked, evidence-backed watchlist of companies worth a closer look, presented in an interactive Power BI dashboard.

Every risk score in this project traces back to a named rule or a verifiable piece of evidence. The guiding principle throughout is that **a risk signal a compliance team cannot explain is a signal they will not trust**, so the emphasis is on calibration, verification, and honestly documented limitations rather than on impressive-looking but unaccountable numbers.

> Built as a portfolio project to demonstrate UK data-analyst, BI, and applied-AI skills on real public data. It is a decision-support triage aid, not an automated decision-maker: every flag is a prompt for human review, never a verdict on a company.

---

## What it does

Starting from raw Companies House data, the pipeline:

1. **Ingests** the bulk company register plus live API enrichment (company profiles, officers, filing histories, and accounts documents).
2. **Cleans and models** it into a bronze → silver → gold layered warehouse, ending in a star schema.
3. **Computes risk flags** — rule-based (overdue filings, insolvency history, strike-off), a calibrated director-network-risk flag, and AI-extracted flags read from PDF accounts.
4. **Scores and ranks** every company with a simple, hand-checkable additive score.
5. **Presents** the result as a two-page Power BI dashboard: an executive watchlist and a director-network drill-down.

## Architecture

```
Companies House (bulk CSV + REST API + Document API)
        │
        ▼
  BRONZE   raw register (10,000 companies), API enrichment (300, random sample),
           director appointment histories (596), accounts PDFs (240)
        │
        ▼
  SILVER   cleaned, typed, JSON flattened into relational tables
        │
        ▼
  GOLD     ├─ director-network-risk flag (re-calibrated on the 300-company sample)
           ├─ AI extraction flags (Claude reads accounts PDFs; 239 of 300 covered)
           ├─ fact_risk_flag  (all 10,000 companies, additive risk score)
           └─ star schema: dim_company, dim_officer, dim_sic, fact_filing
        │
        ▼
  POWER BI  executive overview + director network-risk pages
```

The whole stack runs locally and free (Postgres + pgvector in Docker, the Anthropic API for extraction, Power BI Desktop). The intended cloud target is **Azure** (Power BI-native, UK-market fit); the project is built to deploy there but developed locally to keep it free and reproducible.

## The two calibration stories (the interesting part)

Most of the analytical value in this project is not that the flags exist, but that they were **interrogated and corrected** when found to be wrong.

### 1. Director network risk — "dissolved is not failed"

A naive first version flagged directors linked to 3+ dissolved or insolvent companies. On the reproducible 300-company random sample it flags **60 of 596 active directors (10.1%)** and **50 of 287 assessable companies (17.4%)** — one company in six, far too broad for a shortlist. Investigation showed the usual professional-director signature (the most-linked director sits on **687 companies, 215 dissolved, only 27 truly insolvent**) and, more importantly, that most "adverse" companies were **routine dissolutions**, not failures — treating them as failures inflated individual directors' adverse counts by up to **65x** (one director: 130 "adverse", 2 insolvent).

The decisive fix was **definitional** — counting only **involuntary insolvency** (liquidation, receivership, administration, insolvency-proceedings, voluntary-arrangement) rather than all closures. Holding the threshold constant, that single change takes the flag from **60 → 4 directors**, a fifteen-fold cut from the definition alone. Raising the cut-off to the final High ≥ 10 / Medium 5–9 removes no one further (no director sits in the 3–4-insolvency band), so the *entire* reduction is the definition, not the threshold. A ratio gate (v2) helped less: **60 → 23**, because it still counted dissolutions.

| | v1 (naive) | v2 (+ratio) | v3 (final) |
|---|---|---|---|
| Directors flagged | 60 of 596 (**10.1%**) | 23 (3.9%) | 4 of 596 (**0.7%**) — 2 High, 2 Medium |
| Companies flagged | 50 of 287 (**17.4%**) | — | 3 of 287 (**1.0%**) — 2 High, 1 Medium |

A small, defensible, reviewable set. 287 of the 300 enriched companies have an active human director with an `officer_id`, so 287 is the correct base for any director-derived figure. The whole three-version comparison is reproducible from one committed script, [`transform/recalibrate_network.sql`](transform/recalibrate_network.sql). Full write-up in [`docs/risk-flags.md`](docs/risk-flags.md).

### 2. LLM extraction — verifying the model against the source

Claude (Haiku) reads scanned PDF accounts and extracts three flags as structured JSON: going concern, auditor resignation, related party. On a first pass over an initial 20-company sample it flagged **related-party transactions in 18 of 20 companies** — too high to be useful.

Rather than trust or discard the output, three companies were opened and read by hand, and their true labels recorded in [`ai/evals/datasets/extraction_labels.csv`](ai/evals/datasets/extraction_labels.csv). All three were false positives, caused by routine intra-group balances and, in one case, an accounts note that **explicitly stated no related-party transactions occurred** (the model quoted a real sentence but reached the wrong conclusion). The prompt was hardened to require a material, actual connected-party transaction and to respect negations and exemptions. On that sample, related-party flags fell from **18/20 to 3/20**, matching hand-verified ground truth on **3 of 3** checked cases, while the genuine going-concern positive (a company being liquidated) survived the tightening.

The calibrated prompt was then run across the full random sample. Of the **239 of 300** companies with a readable accounts document, related party now fires on **22 (9.2%)**, going concern on **6 (2.5%)**, and auditor resignation on **0** — the ~90% pre-calibration related-party rate has generalised to under 10% at scale. Precision on the full 239 is not separately labelled (the three hand-verified companies remain the ground truth), so 9.2% is a flag rate consistent with the calibration holding, not a measured precision figure. Full results and methodology in [`EVALUATION.md`](EVALUATION.md).

## The dashboard

A two-page interactive Power BI report built on the gold star schema. Screenshots and the Git-friendly `.pbip` project files are in [`powerbi/`](powerbi/) (with its own [README](powerbi/README.md)).

- **Executive Overview** — KPI cards, risk-tier distribution, a "flags firing" breakdown, and a ranked watchlist with conditional formatting.
- **Director Network Risk** — the calibrated network flag, with a caption explaining the methodology on the visual itself.

## Tech stack

| Layer | Tools |
|---|---|
| Ingestion | Python (`requests`, `SQLAlchemy`), Companies House REST + Document APIs |
| Warehouse | PostgreSQL (with pgvector), Docker |
| Transform | SQL (dbt-style bronze → silver → gold layering) |
| AI extraction | Anthropic API (Claude Haiku reads PDF accounts natively) |
| Evaluation | Hand-labelled ground truth; before/after calibration metrics |
| BI | Power BI Desktop (`.pbip` project format) |

## Repository structure

```
compliance-radar/
├── ingestion/      # Python: bulk load, API enrichment, officer histories, accounts PDFs
├── transform/      # SQL: silver, gold, network_risk, recalibrate_network, gold_star, powerbi_export
├── ai/             # LLM extraction + evaluation datasets
├── docs/           # risk-flags.md (flag definitions + calibration)
├── powerbi/        # .pbip dashboard + screenshots + README
├── EVALUATION.md   # AI-layer evaluation report (real results)
├── requirements.md # business requirements / BA artefact
└── README.md       # you are here
```

## Honest limitations

Stating these is part of the work; a risk tool that hides its blind spots is worse than one that names them.

- **Sample size.** 300 companies are API-enriched (a reproducible random sample) out of 10,000 loaded, out of ~5 million on the register. Flags that depend on links between companies are limited by this.
- **Sampling bias (identified and corrected).** The original enriched sample was drawn from the lowest company numbers — Britain's oldest companies — and over-represented overdue filers (92% overdue vs an ~8% register baseline). It was replaced by a reproducible random sample of 300 (`md5(company_number || 'radar-seed-v1')`); the enriched overdue rate is now 11.3%, in line with the 8.6% bulk cohort. Found and fixed, not hidden.
- **AI-extraction coverage.** Extraction covers 239 of the 300 enriched companies (80%); the other 61 have no readable digital accounts document (46 incorporated 2024–2026 with no first accounts yet, and one 2007 legacy-format filing that would not extract). All 10,000 companies still carry rule-based flags; AI flags refine the 239 with readable accounts.
- **Absolute-count network flag.** The director-network flag counts absolute insolvencies, so a very high-volume professional director can reach the High threshold on volume alone (one flagged director: 27 insolvencies across 687 companies, ~4% — near baseline). Flagged directors are review signals, not conclusions.
- **Single-annotator evaluation.** The AI eval uses hand-labelled ground truth from one annotator on a small set. It demonstrates the *method* — pre-registered gates, verification against source, documented calibration — not a production-scale accuracy figure. Precision at 239-scale is not separately hand-labelled.
- **Snapshot freshness.** The bulk register is a monthly snapshot; live facts come from the API at enrichment time.

## What I'd do next

- Hand-label a larger extraction set (say 50–100 of the 239) to turn the 9.2% flag rate into a real precision/recall figure.
- Scale enrichment beyond the current 300-company random sample toward the target book.
- Add the remaining AI components scoped in the blueprint: RAG over filings, text-to-SQL, and a human-in-the-loop triage agent.
- Deploy the thin cloud layer on Azure.

## Author

**[Shivansh Chauhan]** — [@Shivansh9307](https://github.com/Shivansh9307)

A public portfolio project. Data is from Companies House (UK), used under its open data terms. This is a demonstration of data and AI engineering practice, not a commercial compliance product.