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
  BRONZE   raw register (10,000 companies), API enrichment (50),
           director appointment histories (102), accounts PDFs (20)
        │
        ▼
  SILVER   cleaned, typed, JSON flattened into relational tables
        │
        ▼
  GOLD     ├─ director-network-risk flag (calibrated over 3 iterations)
           ├─ AI extraction flags (Claude reads accounts PDFs)
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

A naive first version flagged directors linked to 3+ dissolved or insolvent companies. It flagged **68 of 102 directors (67%)** and **27 of 33 assessable companies (82%)** — implausibly high for a risk signal. Investigation showed two things: the highest counts belonged to insolvency professionals (one director linked to 463 companies, 177 closed), and, more importantly, most "adverse" companies were **routine dissolutions**, not failures — treating them as failures inflated individual directors' adverse counts several-fold (5.7x to 34x in the worst cases).

Two changes were made across three versions. Adding a failure-*ratio* to the count (v1→v2) barely helped: 68 → 48 directors (1.4x). The decisive fix was **definitional** (v2→v3) — counting only **involuntary insolvency** (liquidation, receivership, administration, insolvency-proceedings, voluntary-arrangement) rather than all closures — which took it 48 → 15.

| | v1 (naive) | v2 (+ratio) | v3 (final) |
|---|---|---|---|
| Directors flagged | 68 of 102 (**67%**) | 48 (47%) | 15 of 102 (**15%**) — 9 High, 6 Medium |
| Companies flagged | 27 of 33 (**82%**) | — | 7 of 33 (**21%**) — 3 High, 4 Medium |

A small, defensible, reviewable set. Note the denominator: 33 of the 50 enriched companies have an active human director with an `officer_id`, so 33 is the correct base for any director-derived flag. Full write-up in [`docs/risk-flags.md`](docs/risk-flags.md).

### 2. LLM extraction — verifying the model against the source

Claude (Haiku) reads scanned PDF accounts and extracts three flags as structured JSON: going concern, auditor resignation, related party. The first pass flagged **related-party transactions in 18 of 20 companies** — again, too high to be useful.

Rather than trust or discard the output, three companies were opened and read by hand, and their true labels recorded in [`ai/evals/datasets/extraction_labels.csv`](ai/evals/datasets/extraction_labels.csv). All three were false positives, caused by routine intra-group balances and, in one case, an accounts note that **explicitly stated no related-party transactions occurred** (the model quoted a real sentence but reached the wrong conclusion). The prompt was hardened to require a material, actual connected-party transaction and to respect negations and exemptions. Related-party flags fell from **18/20 to 3/20**, matching hand-verified ground truth on **3 of 3** checked cases, while the genuine going-concern positive (a company being liquidated) survived the tightening. One residual false positive is left in and documented rather than hidden. Full results and methodology in [`EVALUATION.md`](EVALUATION.md).

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
├── transform/      # SQL: silver, gold, network_risk, gold_star, powerbi_export
├── ai/             # LLM extraction + evaluation datasets
├── docs/           # risk-flags.md (flag definitions + calibration)
├── powerbi/        # .pbip dashboard + screenshots + README
├── EVALUATION.md   # AI-layer evaluation report (real results)
├── requirements.md # business requirements / BA artefact
└── README.md       # you are here
```

## Honest limitations

Stating these is part of the work; a risk tool that hides its blind spots is worse than one that names them.

- **Sample size.** 50 companies are API-enriched out of 10,000 loaded, out of ~5 million on the register. Flags that depend on links between companies are limited by this.
- **Sampling bias.** The enriched sample was drawn from the lowest company numbers, which are the oldest companies in Britain and over-represent overdue filers (92% overdue in the enriched sample vs 8.3% in the bulk register). This is surfaced, not hidden.
- **Single-annotator evaluation.** The AI eval uses hand-labelled ground truth from one annotator on a small set. It demonstrates the *method* — pre-registered gates, verification against source, documented calibration — not a production-scale accuracy figure.
- **AI flags are triage signals.** Extraction covers only companies whose accounts were read; going-concern and related-party flags prompt review, they do not conclude anything.
- **Snapshot freshness.** The bulk register is a monthly snapshot; live facts come from the API at enrichment time.

## What I'd do next

- Scale enrichment with a random (not lowest-number) sample to remove sampling bias.
- Grow the labelled eval set to 50–100 companies for a real precision/recall figure.
- Add the remaining AI components scoped in the blueprint: RAG over filings, text-to-SQL, and a human-in-the-loop triage agent.
- Deploy the thin cloud layer on Azure.

## Author

**[Your Name]** — [@Shivansh9307](https://github.com/Shivansh9307)

A public portfolio project. Data is from Companies House (UK), used under its open data terms. This is a demonstration of data and AI engineering practice, not a commercial compliance product.