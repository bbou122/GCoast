# Verification report

> **Synthetic data.** Gulf Coast Builders is fictional. This report records what was checked, how, and what is weak. Everything here is reproducible with `python run_all.py --regen`.

## Summary

| # | Verification | Result |
|---|---|---|
| 1 | Planted stories are the top findings | **Pass** (8 of 8 ERP and 4 of 4 core stories, section 1) |
| 2 | Every planted defect is caught or fixed, and nothing else is rejected | **Pass** (593 planted rows: 501 fixed, 76 rejected, 16 de-duplicated; 92 quarantined = 76 + 16 exactly) |
| 3 | Headline numbers recomputed independently in pandas | **Pass** (21 of 21 match, 12 projects x 3 per-project measures match) |
| 4 | Dollars reconcile raw to staging to mart to metrics | **Pass** (checks `STG-060..066`, `MRT-010..015`, `MET-001..024`) |
| 5 | The data-quality suite fails the build when data is broken | **Pass** (13 of 13 deliberate corruptions caught; exit code 1) |
| 6 | Dashboard numbers equal the SQL layer | **Pass** (27 numbers computed in the browser) |
| 7 | Role restrictions remove data | **Pass** (10 roles; rows, pages, fields and rendered text) |
| 8 | Screenshots of every page, desktop and phone, both themes | **Done** (21 screenshots, section 7) |
| 9 | Accessibility rules engine | **Pass** (axe-core 4.10.2, WCAG 2.0/2.1 A and AA plus best practices: 0 violations, 7 pages x 2 themes) |
| 10 | Clean-checkout run | **Pass** (section 8) |
| 11 | Weak or failed checks | **See section 9. Read it.** |

## 1. Planted stories are the top findings

The generator writes the stories in before any defects are added and records the answer key in `data/truth/answer_key.json`. `tests/test_planted_defects.py` and `tests/test_dashboard.py` assert that the metric layer and the dashboard's **Needs attention** list surface them.

| Story | Planted answer | Metric layer / dashboard shows |
|---|---|---|
| Margin fade (3 jobs) | P-103, P-107, P-110; about 88% of fade dollars | Top 3 by fade rank = P-103, P-107, P-110; share 87.65%. Executive headline: "3 jobs account for 88% of margin fade" |
| Heavy pending change orders | P-104, P-109 | Top 2 by pending CO revenue ($2.6M, $1.7M); both flagged with age (201 and 213 days) |
| Billing position | P-105 over (+$4.3M), P-108 under (-$1.8M) | Max and min of over/under billing; chart title "P-105 is billed $4.3M ahead of earned revenue; P-108 is $1.8M behind" |
| Safety cluster | P-106 (night-work phase, Mar to May 2026) | Only job with `safety_cluster = true` (9 incidents in 90 days including background) |
| Chronically late supplier | Pelican Metal Works, 20% on time | Lowest on-time rate (20%), 6 of 8 overdue open lines; Executive finding and Procurement chart title |
| Late steel on one job | Crescent Steel on P-102, about 22 days late | Only job where Crescent averages more than 15 days late (22.5); Executive finding "Crescent Steel Supply deliveries to P-102 average 22 days late" |
| Three-way match exceptions | 7 received-not-invoiced lines, 4 invoiced-not-received | Exact line IDs match the key |
| Slow-paying owners | P-108, P-104, P-109 | Top 3 by overdue receivables; amounts equal the key x 0.9 (retainage) |
| Disputed subcontract pay | Magnolia Mechanical, P-103, 3 applications, $1.06M | Match on project, vendor, count and gross |
| Plant stock | Welded wire mesh, Embed plates, Rebar #4/#5 | Exactly these three below reorder point, all with stock-out risk |
| Overdue RFIs | P-101 1, P-104 4, P-108 1, P-109 4 | Exact match to the key |
| Schedule slip | P-107 61, P-102 40, P-105 38 days ... | All 12 final-slip values equal the key |

## 2. Planted defects are all handled; nothing is over-rejected

`data/truth/planted_defects.json` (and `docs/planted_defects.md`) lists every bad row with its table, key, defect type and expected action.

| Expected action | Planted rows | Result |
|---|---:|---|
| Rejected (quarantined with a reason) | 76 | all 76 found in `stg.rejects` with the expected reason |
| Deduplicated | 16 | all 16 found in `stg.rejects` (duplicate rows removed) |
| Fixed (kept, corrected) | 501 | none quarantined; vendor spellings standardised (16 canonical vendors), cost codes normalised, currency text parsed, date formats parsed, stage labels standardised |
| **Total quarantined** | **92** | equals 76 + 16 exactly: **no good row was rejected** |

Legitimate vendor credit memos (negative amounts with a credit-memo description) survive, while negative amounts with no explanation are rejected.

## 3. Headline numbers recomputed independently

`tests/independent_recompute.py` reads only the raw CSVs, does its own cleaning in pandas (no SQL reused), and compares to the warehouse.

| Metric | pandas | SQL warehouse |
|---|---:|---:|
| Total actual cost | $208,397,168.23 | $208,397,168.23 |
| Total billed | $229,832,030.98 | $229,832,030.98 |
| Backlog (active remaining + awarded not started) | $150,907,393.55 | $150,907,393.55 |
| Weighted pipeline | $177,927,435.14 | $177,927,435.14 |
| Win rate | 0.4286 | 0.4286 |
| Pending change-order revenue | $4,386,598.35 | $4,386,598.35 |
| TRIR (all history) | 3.6183 | 3.6183 |
| Portfolio projected margin | 8.24% | 8.24% |
| Top-3 fade jobs | P-103, P-107, P-110 | P-103, P-107, P-110 |
| Top-3 share of fade | 87.65% | 87.65% |
| Open PO lines / value | 59 / $6,559,528.33 | 59 / $6,559,528.33 |
| Overdue PO lines / value | 8 / $750,064.97 | 8 / $750,064.97 |
| On-time delivery rate | 71.01% | 71.01% |
| AR open / overdue / over 90 days | $16,299,949.88 / $4,048,837.21 / $1,409,153.35 | identical |
| AP open | $14,041,875.97 | $14,041,875.97 |
| Overdue RFIs / items below reorder | 10 / 3 | 10 / 3 |

The independent logic found one real definition difference during development: pay applications dated after the as-of date are excluded from AP (documented in `metric_definitions.md`).

## 4. Reconciliation chain

Each hop has a critical check: raw rows = staged + rejected (`STG-060..062`), raw dollars minus rejected dollars = staged dollars (`STG-064..065`), staged = mart (`MRT-010..015`), mart totals = metric totals (`MET-003..008`, `MET-020..024`), and project summary has one row per project (`MET-024`) after all joins, which also guards against join fan-out. Receipts, invoices, pay applications and commitments are reconciled to their metric views in `MET-020..023`.

## 5. The checks fail loudly

`tests/test_checks_fail_loudly.py` corrupts copies of the warehouse and requires the build to fail with exit code 1:

duplicate invoice survives staging; orphan project reaches staging; cost row lost between staging and mart; bad domain value; unexplained negative cost; rejected row silently dropped; confidential column leaks into a mart; receipt for a PO line that does not exist; duplicate PO line survives; unknown vendor spelling; negative stock on hand; pay application lost from the mart; metric fan-out. **13 of 13 caught**, each by the check intended for it.

## 6. Dashboard tests

`tests/test_dashboard.py` (headless Chromium):

- 70 renders (10 roles x 7 pages): no JavaScript errors or console errors, synthetic banner present, no external network requests.
- 27 numbers computed in the browser from the embedded rows equal `v_portfolio_kpis`; all planted stories appear in the Executive findings.
- Role scope, measured on the page's own data:

| Role | Projects | Pages | Safety incident rows | Pipeline rows | Plant inventory |
|---|---:|---:|---:|---:|---:|
| Executive | 12 | 7 | 32 | 3 | 14 |
| Finance | 12 | 7 | **0** | 3 | 14 |
| BU Lead: Building | 6 | 7 | 7 | 1 | 0 |
| BU Lead: Heavy Civil | 4 | 7 | 24 | 1 | 0 |
| BU Lead: Manufacturing | 2 | 7 | 1 | 1 | 14 |
| Project Manager (5 people) | 2 to 3 each | **6** (no pipeline) | own jobs only | **0** | Manufacturing PM only |

- At 390 px width there is no horizontal page scroll on any page (Executive and Project Manager roles).

**Accessibility:** axe-core 4.10.2 with rule tags wcag2a, wcag2aa, wcag21aa and best-practice reported 0 violations on all seven pages in light and dark themes (this includes colour-contrast). The first run found one best-practice issue (content outside landmarks), which was fixed. Not a substitute for a screen-reader audit.

## 7. Screenshots (`docs/screenshots/`)

| Page | Desktop, light | Phone, light |
|---|---|---|
| Executive | `desktop_exec_light.png` | `phone_exec_light.png` |
| Project drill-down | `desktop_projects_light.png` | `phone_projects_light.png` |
| Procurement and materials | `desktop_proc_light.png` | `phone_proc_light.png` |
| Subcontracts and cash | `desktop_cash_light.png` | `phone_cash_light.png` |
| Field operations | `desktop_field_light.png` | `phone_field_light.png` |
| Pipeline | `desktop_pipeline_light.png` | `phone_pipeline_light.png` |
| Data quality and definitions | `desktop_quality_light.png` | `phone_quality_light.png` |

Also: dark theme (`desktop_exec_dark.png`, `desktop_cash_dark.png`, `desktop_quality_dark.png`, `phone_exec_dark.png`) and role views (`role_finance_field.png` shows safety removed; `role_pm_joshua_garcia_exec.png`; `role_bu_manufacturing_proc.png`). Regenerate with `python src/make_screenshots.py`.

Defects found by reviewing these screenshots during the build, all fixed: an over-long findings list pushing charts off screen; repeated "$2M, $2M, $1M" axis labels from rounding; every other label dropped on two bar charts; a commitments-vs-budget metric that flagged 60 of 72 lines (threshold too tight; now 5%, 10 lines); an unclear "Fade" column header; a clipped stacked bar.

## 8. Clean-checkout run

A fresh copy of **only the source files** (no `data/`, no generated docs, no alerts, no screenshots, no caches) was placed in an empty folder, with a new virtual environment holding **older pinned libraries than the development environment**: Python 3.13, DuckDB 1.1.3, pandas 2.2.3, numpy 2.1.3, Playwright 1.56. Then `python run_all.py --regen` was run.

| Step | Result |
|---|---|
| Generate synthetic data | ok (1.6 s) |
| Build warehouse | ok (1.1 s) |
| Data-quality checks | ok: 82 pass, 19 informational, 0 fail (24.7 s) |
| Answer-key tests | 12 of 12 pass |
| Corruption (negative) tests | 13 of 13 caught (346 s) |
| Independent pandas recompute | 21 of 21 match |
| Export, dashboard, alerts, data dictionary | ok |
| Dashboard browser tests | all pass |
| **Total** | **exit 0, 386 s** |

Outputs compared with the development run: all 24 raw CSVs byte-identical (SHA-256), answer key and planted-defect log identical, the dashboard data identical (ignoring the timestamp), and the weekly alert report identical (ignoring the date line). The seed makes the pipeline fully deterministic, and results do not depend on the library versions tested. The same run also showed that the DuckDB 1.1 checks and corruption tests are several times slower than on 1.5.


## 9. Failed or weak checks (read this)

1. **The planted-defect proof is partly circular.** The checks catch the defects the generator plants, so a perfect score shows the checks match the log, not that they would catch every real-world defect. The negative tests (corrupting the warehouse in ways the generator never did) are the stronger evidence.
2. **The GitHub Actions workflow has not been run on GitHub.** Its steps were run locally in a clean environment, but the workflow file itself is untested; expect to adjust the first time.
3. **Snowflake and Power BI examples were not executed.** The SQL for Snowflake (comments in the model, the policies in `access_matrix.md`) and the DAX are written from the documented syntax but never run.
4. **The role selector is not security** (stated on the page, in the README and in `access_matrix.md`). The tests prove removal from what the page holds and shows for each role, not that a determined user cannot read the file.
5. **Metric design limits** (full list in `limitations.md`): cost-to-cost trusts the PM's estimate to complete; the plan curve is an assumed S-curve; schedule variance is a spend-based proxy; weighted pipeline uses generic stage probabilities; AP excludes items dated after the as-of date; a 5% over-commitment threshold is a judgment call.
6. **One snapshot only.** No history, so there is no week-over-week "what changed" in the alert report.
7. **The corruption test suite is slow** (about 60 seconds locally, longer on older library versions) because it copies the warehouse 13 times.
8. **Accessibility** was checked with an automated engine and visual review, not with assistive technology.
9. **During development one independent recompute disagreed with the warehouse** (AP open, about $4.0M apart). The cause was my pandas test omitting the as-of-date filter on subcontractor pay applications; the warehouse was right. The test was fixed and the rule documented, with no check weakened.
