# Risk Flag Definitions

**Author:** Shivansh
**Version:** 0.7
**Date:** 18 July 2026

These flags are applied to each company during the silver-to-gold transformation. A flag is a signal that a company may be worth a closer look. It is not a verdict on the company. Every flag traces back to a named source or rule, so a reviewer can check it by hand.

## Data sources and provenance

Three sources feed these flags, and where they overlap the live source wins:

- **Bulk register** (`silver.companies`, all 10,000 loaded companies). Used for company-wide coverage. Dates and overdue status here are computed from a snapshot that can be up to a month old.
- **Live company enrichment** (`silver.company_live`, `silver.officers`, `silver.filings`, currently 50 companies). Used where available because it is current and carries authoritative fields such as the API's own `overdue` booleans, insolvency history, and officer detail.
- **Officer appointment history** (`silver.officer_appointments`, `gold.director_network_risk`, currently 102 active human directors). Each director's full register-wide appointment history, used only for the director-network-risk flag.

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

**How this was calibrated (three iterations).** The value of this flag is in how it was tuned, not just the final rule:

1. **v1, naive.** "Linked to 3 or more dissolved or insolvent companies." This flagged 68 of 102 directors (67 percent), carrying through to 27 of 33 assessable companies (82 percent) — implausibly high for a risk signal.
2. **Diagnosis.** Ranking directors by the *proportion* of their companies that failed showed that the highest raw counts belonged to insolvency professionals. One director was linked to 463 companies, 177 of them closed. A naive count mostly catches the people who *clean up* failures (liquidators, insolvency practitioners), not those who cause them.
3. **v2, key insight.** "Dissolved" is not "failed." Most company closures are routine: a company ages out and is dissolved cleanly. Treating dissolution as failure inflated each director's *adverse-company count* several-fold — one director showed 154 "adverse" companies but only 27 true insolvencies (5.7x), another 103 dissolved but only 3 insolvent (34x). Two changes followed. Adding a failure-ratio to the count (v1→v2) barely moved the flag rate: 68 to 48 directors (1.4x), because it still counted dissolutions as failures. The decisive change was definitional (v2→v3): counting only involuntary insolvency. Note the per-director count inflation and the flag-rate change are different quantities — the former is why the latter had leverage.
4. **v3, final.** Counting only involuntary insolvency, flagged directors fell from 68 of 102 (67 percent) to 15 of 102 (15 percent: 9 High, 6 Medium), and flagged companies from 27 of 33 (82 percent) to 7 of 33 (21 percent: 3 High, 4 Medium). A small, defensible, reviewable set.

   Note the denominator: 33 of the 50 enriched companies have at least one active human director with an `officer_id`. The other 17 have only corporate officers, no active officers, or officers without an id, so they cannot be assessed by this rule. 33 is the correct base for any director-derived company figure.

**Known limitations of this flag.**
- `dissolved` status is retained as separate context (`dissolved_companies`), not counted as risk.
- Insolvency links include historical directorships, so a flag reflects a director's career pattern rather than only current exposure. This is deliberate and disclosed.
- Coverage: only companies with enrichable active human directors are assessed (33 of 50 in the current sample). The rest have no active human director on record, only corporate officers, or officers without an `officer_id`.
- Officer histories are fully paginated, so the previous 35-per-page truncation no longer applies to this flag. Completeness is recorded per director in `bronze.officer_appointments.pages_complete`.

## AI-extracted flags

These come from reading the text of company accounts with an LLM. They are suggestions for a person to confirm, not facts. Their accuracy (precision and recall) is reported in `EVALUATION.md`. Not yet implemented.

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

- **Enrichment coverage.** Only 50 companies are currently enriched, out of 10,000 loaded, out of roughly 5 million on the register. Any flag that depends on links between companies is limited by this small sample.
- **Dissolved is not failed.** Routine dissolution is separated from involuntary insolvency. Conflating the two inflated the network-risk flag roughly fivefold before it was corrected (see the calibration notes above).
- **Officers are stored per appointment, not per person.** The same individual can appear more than once at a company (for example as both secretary and director). Counts of "directors" are deduplicated by `officer_id` in the gold layer to avoid overcounting.
- **Officer identity is stable but not perfect.** `officer_id` and `person_number` link the same person across companies far more reliably than name matching, but the register is known to be imperfect and a single person can occasionally hold more than one id. This is used as a strong starting key, not treated as flawless.
- **Pre-1992 appointments lack exact dates.** In the sample, about 32 percent of officer appointments predate 1992 and carry only `appointed_before` rather than `appointed_on`. The `appointed_effective` column falls back to this date, so time-window flags may slightly undercount activity for these older records.
- **Company-officer lists can be truncated.** The company officers endpoint returns officers one page at a time (35 per page). Companies with more officers than one page are flagged by `officers_truncated`. Note this affects the company-officers data only; director appointment histories are fully paginated.
- **Corporate officers are excluded.** Around 4 percent of officers are companies rather than people. They are excluded from all director-based flags.
- **Professional directors appear in network data.** Insolvency practitioners and formation agents legitimately hold hundreds of company links. The network-risk flag counts only involuntary insolvency to reduce this effect, but any flagged director is a signal for human review, not a conclusion.
- **Dormancy recency is not reliably available.** Current sources give present dormant status but not a dependable date of transition, so the flag detects that a company is dormant now, not that it became dormant recently.
- **Snapshot age.** The bulk register can be up to a month old. Live facts come from the API at the time of enrichment.
- **Flags are triage signals for human review only.** They are not a statement that a company has done anything wrong.
- **The enriched sample was drawn from the lowest company numbers**, which skew toward very old companies and over-represent overdue filers; a production run would sample randomly or by the target book.

## Changelog

| Version | Date | Change |
| :--- | :--- | :--- |
| 0.2 | 2 July 2026 | Initial merged definitions. |
| 0.3 | 10 July 2026 | Rewritten after inspecting the enriched data. Added provenance, insolvency-history flag, officer deduplication and corporate exclusion, pre-1992 date handling, truncation caveat. Marked director-network flag pending the sample-size decision. |
| 0.4 | 10 July 2026 | Finalised the director-network-risk flag via full paginated officer appointment history. Documented the three-iteration calibration (naive count, professional-director diagnosis, dissolved-versus-insolvent correction). Set High and Medium thresholds on true insolvency. |
| 0.5 | 11 July 2026 | Added sampling-bias limitation: enriched sample drawn from lowest company numbers over-represents old, overdue companies. |
| 0.6 | 18 July 2026 | Corrected calibration figures to state directors and companies separately with consistent denominators (v1: 68/102 directors, 27/33 companies; v3: 15/102, 7/33). Clarified that 33, not 50, is the assessable base for director-derived flags. |
| 0.7 | 18 July 2026 | Corrected calibration figures: flag rate moved 68→48→15 directors (v1→v2→v3); separated per-director count inflation (5.7x–34x) from flag-rate change; attributed the 1.4x ratio step and the definitional v2→v3 step distinctly. |