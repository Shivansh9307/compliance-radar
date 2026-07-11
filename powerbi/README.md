# Power BI Dashboard — UK Corporate Compliance Radar

An interactive, two-page compliance-triage dashboard built on the project's gold star schema. It turns 10,000 UK Companies House records and their computed risk flags into a ranked, explainable watchlist that a compliance analyst could actually work from.

The report is committed in the Git-friendly **`.pbip`** (Power BI Project) format, so the report layout and the semantic model are stored as readable JSON and TMDL text rather than a binary file. To open and edit it, use Power BI Desktop (`File > Open` the `.pbip`). If you don't have Power BI, the screenshots below show both pages.

## Page 1 — Executive Overview

![Executive Overview](screenshots/overview.png)

The headline view. Four KPI cards summarise the whole register, then the breakdown and the watchlist sit below.

- **KPI cards:** total companies assessed (10,000), high-risk count, AI-flagged count, and the high-risk rate.
- **Risk Tier Distribution (donut):** the split across High / Medium / Low / None. Most of the register is low-risk, as expected; the value is in isolating the small high-risk tip.
- **Volume by Risk Flag (bar):** how often each flag fires across the register. The bulk register-wide flags (accounts / confirmation overdue) dominate by design; the enrichment-only flags (network risk, going concern, related party) are rarer because they depend on companies having been enriched.
- **Watchlist (table):** every company ranked by composite risk score, with conditional formatting on the score. This is the "what do I look at first" list, and each row's score traces back to the specific flags that produced it.
- **Risk Tier slicer:** clicking a tier filters every visual on the page at once.

## Page 2 — Director Network Risk

![Director Network Risk](screenshots/director-network-risk.png)

A drill-down into the director-network-risk flag, the analytical centrepiece of the project.

- **Director Portfolio Risk Summary (table):** directors ranked by the number of companies they are linked to that entered involuntary insolvency, alongside their total and merely-dissolved company counts.
- **Highest Risk Directors by Insolvency Volume (bar):** the top directors by insolvency exposure.
- **Data Calibration (note):** a short caption stating the key methodological decision, directors are flagged on *involuntary insolvency* (liquidation, receivership, administration), not routine dissolution. Conflating dissolved companies with failures overstated risk roughly fivefold before this correction. The full calibration story is in [`docs/risk-flags.md`](../docs/risk-flags.md).

## Data model

The dashboard sits on three tables exported from the gold layer (see [`transform/powerbi_export.sql`](../transform/powerbi_export.sql)):

| Table | Grain | Role |
|---|---|---|
| `company_risk` | one row per company (10,000) | fact + company attributes and all flags; the main table |
| `flags_long` | one row per (company, active flag) | unpivoted flags, powers the "flags firing" chart and per-flag filtering |
| `director_risk` | one row per flagged director | standalone table for the network-risk page |

`flags_long` relates to `company_risk` many-to-one on `company_number` (single cross-filter direction). `director_risk` is standalone. All heavy joining is done in SQL, so Power BI receives clean, report-ready tables and the model stays simple.

A handful of DAX measures drive the KPI cards: `Total Companies`, `High Risk`, `Medium Risk`, `% High Risk`, and `AI-Flagged Companies` (companies carrying a going-concern, auditor-resignation, or related-party flag from the LLM extraction layer).

## What this dashboard demonstrates

Every layer of the pipeline surfaces here in one place: rule-based flags (overdue filings, insolvency history, strike-off), the calibrated director-network-risk flag, and the AI-extracted flags read from scanned PDF accounts, all feeding a single, transparent, additive risk score. The scoring is deliberately simple and hand-checkable, because a risk score a compliance team cannot explain is a risk score they will not trust.