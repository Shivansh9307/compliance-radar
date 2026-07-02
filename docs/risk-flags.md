# Risk Flag Definitions

These flags are applied to each company during the silver-to-gold transformation. A flag is a signal that a company may be worth a closer look. It is not a verdict on the company. Every flag traces back to a named source or rule, so a reviewer can check it by hand.

## Rule-based flags

| Risk flag | What it means | Detection logic | Severity |
| :--- | :--- | :--- | :--- |
| **Overdue accounts** | The company missed the statutory deadline to file its annual accounts. | `next_accounts_due < current_date AND status = 'active'` | High |
| **Overdue confirmation statement** | The company missed its confirmation statement deadline. | `conf_stmt_next_due < current_date AND status = 'active'` | Medium |
| **Recently dormant** | The company became dormant in the last 12 months. | `is_dormant = true AND dormant_since > (current_date - 365)` | Medium |
| **Strike-off risk** | Companies House has proposed to strike the company off, or a strike-off notice exists. | `status = 'active-proposal-to-strike-off'` | High |
| **Rapid officer turnover** | Three or more directors appointed or resigned in the last 12 months. | `count(officer_changes where date > current_date - 365) >= 3` | Medium |
| **Director network risk** | A director of this company is also linked to three or more dissolved or insolvent companies. | `for each officer_id: count(distinct dissolved_or_insolvent_companies) > 3` | High |
| **New company in a watched sector** | Incorporated less than 12 months ago and trading in a sector on the watchlist. | `incorporation_date > (current_date - 365) AND sic_code IN watchlist` | Low |

## AI-extracted flags

These come from reading the text of company accounts with an LLM. They are suggestions for a person to confirm, not facts. Their accuracy (precision and recall) is reported in `EVALUATION.md`.

| Risk flag | What it means | Detection logic | Severity |
| :--- | :--- | :--- | :--- |
| **Going concern** | The accounts express material uncertainty about the company continuing to trade. | LLM reads the latest accounts text and identifies language such as "material uncertainty" or "going concern". | High |
| **Auditor resignation** | The filing text shows the auditor resigned or was removed. | LLM identifies auditor resignation or removal in the filing text. | High |
| **Related party concern** | The accounts note significant related-party transactions. | LLM identifies related-party transaction disclosures in the accounts. | Medium |

## Scoring

I use a simple additive score so anyone can check the maths by hand. This is on purpose. A score you cannot explain is a score a compliance team will not trust.

- Each High flag adds 3 points, each Medium adds 2 points, each Low adds 1 point.
- A company's risk score is the sum of its active flag points.
- Tiers: **High priority** is 6 or more, **Medium** is 3 to 5, **Low** is 1 to 2, and **None** is 0.

The dashboard sorts by score and opens on the High priority tier, so the analyst sees the companies that need attention first.

*Optional variant:* if a 0 to 100 score is preferred for reporting, define it explicitly, for example `min(100, total_points * 8)`, and keep the formula here so it stays auditable. The additive score above is the default because it is the easiest to defend.

## Limitations

- The bulk snapshot can be up to a month old, so a company's live status may differ. Live checks come from the API at review time.
- Director matching across companies is not perfect (the "John Smith" problem), so the network risk flag can miss real links or count the wrong ones. This is a known limit and is documented in the build notes.
- AI-extracted flags depend on the accounts text being available and readable. Scanned images or missing accounts reduce coverage.
- Flags are triage signals for human review only. They are not a statement that a company has done anything wrong.