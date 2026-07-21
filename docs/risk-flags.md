# Risk Flag Definitions

**Author:** Shivansh
**Version:** 0.10
**Date:** 21 July 2026

These flags are applied to each company during the silver-to-gold transformation. A flag is a signal that a company may be worth a closer look. It is not a verdict on the company. Every flag traces back to a named source or rule, so a reviewer can check it by hand.

## Data sources and provenance

Three sources feed these flags, and where they overlap the live source wins:

- **Bulk register** (`silver.companies`, all 10,000 loaded companies). Used for company-wide coverage. Dates and overdue status here are computed from a snapshot that can be up to a month old.
- **Live company enrichment** (`silver.company_live`, `silver.officers`, `silver.filings`, currently 300 companies — a reproducible random sample). Used where available because it is current and carries authoritative fields such as the API's own `overdue` booleans, insolvency history, and officer detail.
- **Officer appointment history** (`silver.officer_appointments`, `gold.director_network_risk`, currently 596 active human directors). Each director's full register-wide appointment history, used only for the director-network-risk flag.

A company only gets the enrichment-based flags if it has been enriched. Companies that are loaded but not yet enriched fall back to the bulk-only flags. This split is itself recorded, so a reviewer can tell which source produced each flag.

## Rule-based flags

| Risk flag | What it means | Detection logic | Source | Severity |
| :--- | :--- | :--- | :--- | :--- |
| **Overdue accounts** | The company missed the statutory deadline to file its annual accounts. | `company_live.accounts_overdue = true`, or where not enriched `companies.accounts_overdue = true` | live, bulk fallback | High |
| **Overdue confirmation statement** | The company missed its confirmation statement deadline. | `company_live.conf_stmt_overdue = true`, or where not enriched `companies.conf_stmt_overdue = true` | live, bulk fallback | Medium |
| **Strike-off risk** | Companies House has proposed to strike the company off. | `company_live.live_status = 'active-proposal-to-strike-off'` | live | High |
| **Insolvency history** | The company has a recorded insolvency or liquidation history. | `company_live.has_insolvency_history = true OR company_live.has_been_liquidated = true` | live | High |
| **Currently dormant** | The company is presently dormant. | `company_live.company_type = 'dormant'` (current status only, see limitations) | live | Medium |
| **Rapid officer turnover** | Three or more human directors appointed or resigned in the last 12 months. | Per company, count non-corporate officers where `appointed_effective` or `resigned_on` falls within the last 365 days; flag when the count is 3 or more. Deduplicated by `officer_id`. | live | Medium |
| **New company in a watched sector** | Incorporated less than 12 months ago and trading in a sector on the watchlist. | `date_of_creation > (current_date - 365) AND sic_code IN watchlist` | live, bulk | Low |
| **Director network risk** | An active director is linked to companies that have entered involuntary insolvency. See the finalised definition below. | See "Director network risk (finalised)" | appointment history | High / Medium |

## Director network risk (finalised)

**Definition.** A company is flagged when one or more of its **active, human** directors is linked to companies that have entered **involuntary insolvency** (`liquidation`, `receivership`, `administration`, `insolvency-proceedings`, or `voluntary-arrangement`) anywhere across the Companies House register.

- **High:** an active director linked to 10 or more insolvent companies.
- **Medium:** an active director linked to 5 to 9 insolvent companies.

Each director's full appointment history is fetched from `/officers/{officer_id}/appointments` with all pages retrieved, so the count reflects the entire register, not just the enriched sample. Directors are keyed by `officer_id`, which links the same person across companies far more reliably than name matching.

**How this was calibrated (re-derived on the 300-company random sample).** The value of this flag is in how it was tuned, not just the final rule. Every figure below is computed on the reproducible random sample — 596 active human directors, 287 assessable companies — by `transform/recalibrate_network.sql`, so all three versions can be reproduced against the current data.

1. **v1, naive.** "Linked to 3 or more dissolved or insolvent companies." This flagged 60 of 596 directors (10.1%), carrying through to 50 of 287 assessable companies (17.4%). Not the extreme rate seen on the earlier lowest-company-number sample, but still far too broad for a triage signal — one company in six is not a shortlist.
2. **Diagnosis.** Ranking directors by their total links surfaced the familiar professional-director signature: the most-linked director sits on 687 companies, 215 of them dissolved but only 27 genuinely insolvent. A naive count mostly catches the people who *wind companies up* (liquidators, formation agents), not those who cause failures.
3. **v2, ratio.** Adding a failure-ratio gate (adverse share of a director's companies ≥ 0.5) cut the flag to 23 of 596 directors (3.9%). It moved the number, but it still counts routine dissolution as failure — so it is still the wrong quantity, measured more strictly.
4. **v3, definitional (the decisive change).** "Dissolved" is not "failed." Most closures are routine — a company ages out and is dissolved cleanly — and treating dissolution as failure inflated individual directors' adverse-company counts several-fold, up to 65x in the worst case (one director: 130 "adverse" companies, only 2 truly insolvent). Counting only involuntary insolvency, *holding the threshold at 3*, drops the flag from 60 to 4 directors — a fifteen-fold reduction from the definition alone. Note two quantities that are easy to conflate: the per-director count inflation (up to 65x) and the flag-rate change are different things — the former is why the latter had such leverage.
5. **v3, final.** Counting only involuntary insolvency with High ≥ 10 and Medium 5–9, the flag lands on 4 of 596 directors (0.7%: 2 High, 2 Medium) and 3 of 287 assessable companies (1.0%: 2 High, 1 Medium). Raising the threshold from 3 to 5/10 removes no one — no director sits in the 3-to-4-insolvency band — so the entire reduction from v1 is attributable to the definition, not the cut-off. A small, defensible, reviewable set.

   Note the denominator: 287 of the 300 enriched companies have at least one active human director with an `officer_id`. The other 13 have only corporate officers, no active officers, or officers without an id, so they cannot be assessed by this rule. 287 is the correct base for any director-derived company figure.

**Known limitations of this flag.**
- `dissolved` status is retained as separate context (`dissolved_companies`), not counted as risk.
- Insolvency links include historical directorships, so a flag reflects a director's career pattern rather than only current exposure. This is deliberate and disclosed.
- Coverage: only companies with enrichable active human directors are assessed (287 of 300 in the current sample). The rest have no active human director on record, only corporate officers, or officers without an `officer_id`.
- Because the rule counts *absolute* insolvencies, a very high-volume professional director can reach the High threshold on volume alone — e.g. a director on 687 companies with 27 insolvencies (~4%, near the register baseline). A flagged director is a signal for human review, not a conclusion.
- Officer histories are fully paginated, so the previous 35-per-page truncation no longer applies to this flag. Completeness is recorded per director in `bronze.officer_appointments.pages_complete`.

## AI-extracted flags

These come from reading company accounts with an LLM. They are suggestions for a person to confirm, not facts. The extraction was implemented and calibrated against hand-labelled ground truth on an initial 20-company sample (the full method and before/after are in `EVALUATION.md`), then run across the 300-company random sample. It now covers **239 of the 300** enriched companies — the rest have no readable digital accounts document (see the coverage limitation below) — and its results are populated in `gold.fact_risk_flag` (`is_ai_extracted = true` for those 239).

On the 239 companies, the flags fire as follows: going concern **6 (2.5%)**, auditor resignation **0**, related party **22 (9.2%)**. The related-party rate is the key generalisation check: the pre-calibration prompt fired on roughly 90% of companies; after it was hardened to require a material, actual connected-party transaction and to respect negations and group exemptions, it fires on 9.2% at scale — discriminating between companies rather than firing on nearly all of them. Precision on the full 239 is **not** separately labelled — the hand-verified ground truth remains the three checked companies in `EVALUATION.md` — so 9.2% is a flag rate consistent with the calibration holding, not a measured precision figure.

| Risk flag | What it means | Detection logic | Severity |
| :--- | :--- | :--- | :--- |
| **Going concern** | The accounts express material uncertainty about the company continuing to trade. | LLM reads the latest accounts text and identifies language such as "material uncertainty" or "going concern". | High |
| **Auditor resignation** | The filing text shows the auditor resigned or was removed. | LLM identifies auditor resignation or removal in the filing text. | High |
| **Related party concern** | The accounts note significant related-party transactions. | LLM identifies related-party transaction disclosures in the accounts. | Medium |

## Scoring

A simple additive score, so anyone can check the maths by hand. This is on purpose. A score you cannot explain is a score a compliance team will not trust.

- Each High flag adds 3 points, each Medium adds 2 points, each Low adds 1 point.
- A company's risk score is the sum of its active flag points.
- Tiers: **High priority** is 6 or more, **Medium** is 3 to 5, **Low** is 1 to 2, and **None** is 0.

The dashboard sorts by score and opens on the High priority tier, so the analyst sees the companies that need attention first.

## Limitations

These are real constraints found while building, not hypothetical ones. Stating them is part of the work.

- **Enrichment coverage.** 300 companies are currently enriched (a reproducible random sample), out of 10,000 loaded, out of roughly 5 million on the register. Any flag that depends on links between companies is limited by this sample; 287 of the 300 are assessable for the director-network flag.
- **AI-extraction coverage.** Extraction covers 239 of the 300 enriched companies (80%). It runs only where a company has a linked digital accounts document, so the 61 not covered are a property of the register, not a pipeline failure: 60 have no linked accounts document — 46 incorporated in 2024–2026 with no first accounts filed or not yet due, 5 from 2022, and 9 older companies (one per year across 1959–2019) whose filings predate linked digital documents — and 1 (`04103318`, a 2007 "legacy"-format filing) had a document that would not extract to text. All 10,000 companies still carry rule-based flags; AI flags refine the 239 with readable accounts.
- **Dissolved is not failed.** Routine dissolution is separated from involuntary insolvency. Conflating the two inflated individual directors' adverse-company counts by up to 65x on the random sample (one director: 130 "adverse" companies against 2 true insolvencies), and lifted the naive network flag to 17.4% of assessable companies against 1.0% for the corrected rule (see the calibration notes above).
- **Officers are stored per appointment, not per person.** The same individual can appear more than once at a company (for example as both secretary and director). Counts of "directors" are deduplicated by `officer_id` in the gold layer to avoid overcounting.
- **Officer identity is stable but not perfect.** `officer_id` and `person_number` link the same person across companies far more reliably than name matching, but the register is known to be imperfect and a single person can occasionally hold more than one id. This is used as a strong starting key, not treated as flawless.
- **Pre-1992 appointments lack exact dates.** A proportion of officer appointments predate 1992 and carry only `appointed_before` rather than `appointed_on`. The `appointed_effective` column falls back to this date, so time-window flags may slightly undercount activity for these older records. (The proportion was about 32% on the initial sample and has not been re-measured on the random sample.)
- **Company-officer lists can be truncated.** The company officers endpoint returns officers one page at a time (35 per page). Companies with more officers than one page are flagged by `officers_truncated`. Note this affects the company-officers data only; director appointment histories are fully paginated.
- **Corporate officers are excluded.** A small share of officers (about 4% on the initial sample) are companies rather than people. They are excluded from all director-based flags.
- **Professional directors appear in network data.** Insolvency practitioners and formation agents legitimately hold hundreds of company links. The network-risk flag counts only involuntary insolvency to reduce this effect, but any flagged director is a signal for human review, not a conclusion.
- **Dormancy recency is not reliably available.** Current sources give present dormant status but not a dependable date of transition, so the flag detects that a company is dormant now, not that it became dormant recently.
- **Snapshot age.** The bulk register can be up to a month old. Live facts come from the API at the time of enrichment.
- **Flags are triage signals for human review only.** They are not a statement that a company has done anything wrong.
- **Sampling bias (identified and corrected).** The enriched sample was originally drawn from the lowest company numbers, which skew toward Britain's oldest companies and over-represented overdue filers — 92% overdue, against a register baseline near 8–9%. It has been replaced by a reproducible random sample of 300 companies, ordered deterministically by `md5(company_number || 'radar-seed-v1')` so the exact sample regenerates on demand. After re-enrichment and a full gold rebuild, the enriched cohort's overdue rate fell from 92% to 11.3%, in line with the 8.6% bulk-cohort baseline — the contrast is the evidence the bias is gone. The residual gap (11.3% vs 8.6%) is expected: the enriched figure uses the live API `overdue` flag, the bulk figure the month-old snapshot, and n=300 carries roughly ±1.8% sampling error.

## Changelog

| Version | Date | Change |
| :--- | :--- | :--- |
| 0.2 | 2 July 2026 | Initial merged definitions. |
| 0.3 | 10 July 2026 | Rewritten after inspecting the enriched data. Added provenance, insolvency-history flag, officer deduplication and corporate exclusion, pre-1992 date handling, truncation caveat. Marked director-network flag pending the sample-size decision. |
| 0.4 | 10 July 2026 | Finalised the director-network-risk flag via full paginated officer appointment history. Documented the three-iteration calibration (naive count, professional-director diagnosis, dissolved-versus-insolvent correction). Set High and Medium thresholds on true insolvency. |
| 0.5 | 11 July 2026 | Added sampling-bias limitation: enriched sample drawn from lowest company numbers over-represents old, overdue companies. |
| 0.6 | 18 July 2026 | Corrected calibration figures to state directors and companies separately with consistent denominators (v1: 68/102 directors, 27/33 companies; v3: 15/102, 7/33). Clarified that 33, not 50, is the assessable base for director-derived flags. |
| 0.7 | 18 July 2026 | Corrected calibration figures: flag rate moved 68→48→15 directors (v1→v2→v3); separated per-director count inflation (5.7x–34x) from flag-rate change; attributed the 1.4x ratio step and the definitional v2→v3 step distinctly. |
| 0.8 | 18 July 2026 | Replaced the lowest-company-number enriched sample with a reproducible random sample of 300 (seed `radar-seed-v1`) and rebuilt the warehouse. Enriched overdue rate fell 92% → 11.3%, matching the 8.6% bulk baseline; the sampling-bias limitation moves from open issue to corrected. |
| 0.9 | 18 July 2026 | Re-derived the director-network calibration on the 300-company random sample (base: 596 active human directors, 287 assessable companies). v1 naive 60/596 directors (10.1%) / 50/287 companies (17.4%); v2 ratio 23/596 (3.9%); v3 final 4/596 (0.7%: 2 High, 2 Medium) / 3/287 (1.0%: 2 High, 1 Medium). Confirmed the entire v1→v3 reduction is definitional, not threshold — no director sits in the 3–4-insolvency band. Per-director dissolved-as-failure inflation up to 65x. Calibration reproducible via `transform/recalibrate_network.sql`. |
| 0.10 | 21 July 2026 | Ran AI extraction across the 300-company random sample and populated the AI flags in gold: 239 of 300 covered (61 have no readable accounts document — 46 incorporated 2024–2026, plus one 2007 legacy-format filing that would not extract). On the 239: going concern 6 (2.5%), auditor resignation 0, related party 22 (9.2%) — the calibrated related-party prompt generalised from ~90% pre-calibration to 9.2% at scale. Cleared 20 stale extractions and 20 stale PDFs left over from the retired 50-company sample. |