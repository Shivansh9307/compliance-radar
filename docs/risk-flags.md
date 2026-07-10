# Risk Flag Definitions

**Author:** Shivansh
**Version:** 0.3
**Date:** 10 July 2026

These flags are applied to each company during the silver-to-gold transformation. A flag is a signal that a company may be worth a closer look. It is not a verdict on the company. Every flag traces back to a named source or rule, so a reviewer can check it by hand.

## Data sources and provenance

Two sources feed these flags, and where they overlap the live source wins:

- **Bulk register** (`silver.companies`, all 10,000 loaded companies). Used for company-wide coverage. Dates and overdue status here are computed from a snapshot that can be up to a month old.
- **Live API enrichment** (`silver.company_live`, `silver.officers`, `silver.filings`, currently 50 companies). Used where available because it is current and carries authoritative fields such as the API's own `overdue` booleans, insolvency history, and officer detail.

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
| **Director network risk** | *(pending, see note below)* | *to be finalised* | live + extra endpoint | High |

### Note on the director network risk flag (status: pending)

The original definition was "a director linked to three or more dissolved or insolvent companies." Inspecting the enriched data showed this cannot be evaluated on the current 50-company sample: the largest observed link is a single director appearing at two companies, and no director reaches three. The sample simply shows too small a slice of each director's wider network.

Two candidate resolutions are under consideration, and this line will be finalised once one is chosen:

- **Option B (full network):** for each active human director, call the `/officers/{officer_id}/appointments` endpoint, which returns that person's appointments across the entire register, then flag directors linked to three or more dissolved or insolvent companies. This matches the original intent and uses real register-wide data.
- **Option C (scoped to the book):** redefine the flag as "a director holding appointments at two or more companies within our enriched set," and state plainly that the scope is limited to the book rather than the whole register.

Whichever is chosen, the reasoning is recorded here so the change is auditable rather than silent.

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
- **Officers are stored per appointment, not per person.** The same individual can appear more than once at a company (for example as both secretary and director). Counts of "directors" are deduplicated by `officer_id` in the gold layer to avoid overcounting.
- **Officer identity is stable but not perfect.** `officer_id` and `person_number` link the same person across companies far more reliably than name matching, but the register is known to be imperfect and a single person can occasionally hold more than one id. This is used as a strong starting key, not treated as flawless.
- **Pre-1992 appointments lack exact dates.** In the sample, about 32 percent of officer appointments predate 1992 and carry only `appointed_before` rather than `appointed_on`. The `appointed_effective` column falls back to this date, so time-window flags may slightly undercount activity for these older records.
- **Officer lists can be truncated.** The API returns officers one page at a time (35 per page). Companies with more officers than one page are flagged by `officers_truncated`, and their officer-based flags may undercount until pagination is added.
- **Corporate officers are excluded.** Around 4 percent of officers are companies rather than people. They are excluded from all director-based flags.
- **Dormancy recency is not reliably available.** Current sources give present dormant status but not a dependable date of transition, so the flag detects that a company is dormant now, not that it became dormant recently.
- **Snapshot age.** The bulk register can be up to a month old. Live facts come from the API at the time of enrichment.
- **Flags are triage signals for human review only.** They are not a statement that a company has done anything wrong.

## Changelog

| Version | Date | Change |
| :--- | :--- | :--- |
| 0.2 | 2 July 2026 | Initial merged definitions. |
| 0.3 | 10 July 2026 | Rewritten after inspecting the enriched data. Added provenance, insolvency-history flag, officer deduplication and corporate exclusion, pre-1992 date handling, truncation caveat. Marked director-network flag pending pending the sample-size decision. |