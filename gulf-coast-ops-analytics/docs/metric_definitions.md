# Metric definitions

> **Synthetic data.** Gulf Coast Builders is fictional. Definitions follow common construction-finance practice (cost-to-cost percentage of completion, WIP over/under billing, contracted backlog, OSHA incident rate) and are implemented once, in `sql/05_metrics.sql`. Every dashboard number comes from one of the views named below.

**Why one place:** when each report computes "margin" its own way, trust collapses. These views are the single source of truth, and each maps directly to a DAX measure in a Power BI semantic model (example measures are shown for the main ones). As-of date for this build: **30 Sep 2026** (`ops.etl_params`).

| Group | View | Grain |
|---|---|---|
| Cost progress | `metrics.v_project_cost_progress` | project |
| Margin | `metrics.v_project_margin` | project |
| WIP / billing | `metrics.v_project_wip` | project |
| Change orders | `metrics.v_change_order_exposure`, `v_change_order_detail` | project / change order |
| Backlog | `metrics.v_backlog` | active project + awarded-not-started deal |
| Pipeline | `metrics.v_pipeline_by_stage`, `v_pipeline_by_bu` | BU x stage / BU |
| Safety | `metrics.v_safety_by_project`, `v_safety_by_bu`, `v_safety_by_cause`, `v_safety_detail` | project / BU |
| Drill-down series | `metrics.v_project_cost_curve`, `v_project_billing_curve`, `v_project_cost_by_code` | project x month / project x code |
| Procurement | `metrics.v_po_line_status`, `v_vendor_scorecard`, `v_long_lead_watch`, `v_three_way_match_exceptions`, `v_project_procurement` | PO line / vendor / project |
| Subcontracts | `metrics.v_subcontract_position`, `v_commitment_vs_budget` | commitment / project x cost code |
| Cash | `metrics.v_ap_open_items`, `v_ar_open_items`, `v_aging_summary`, `v_retainage_position` | open item / bucket / project |
| Equipment | `metrics.v_equipment_by_unit`, `v_equipment_by_project` | unit / project |
| Inventory | `metrics.v_inventory_status` | stocked item |
| RFIs and submittals | `metrics.v_rfi_by_project`, `v_rfi_open_detail`, `v_submittal_by_project` | project / open RFI |
| Schedule | `metrics.v_schedule_by_project`, `v_project_schedule_variance`, `v_milestone_detail` | project / milestone |
| Dashboard feeds | `metrics.v_project_summary`, `v_portfolio_kpis` | project / portfolio (one row) |

## 1. Percent complete, estimated cost at completion, cost to complete

| Metric | Plain-English formula |
|---|---|
| **Cost to complete (CTC)** | Sum of the project manager's `estimate_to_complete` across every cost-code line. The PM owns this number; it is the forecast. |
| **Estimated cost at completion (EAC)** | Actual cost to date + cost to complete. |
| **Percent complete (cost-to-cost)** | Actual cost to date / EAC, capped at 100%. |

*Why:* cost-to-cost is the standard percentage-of-completion input for revenue recognition on long-duration contracts, and it needs only data the ERP already holds. Its weakness is that it trusts the PM's estimate: an optimistic CTC overstates percent complete and earned revenue.

```dax
Actual Cost = SUM ( fact_cost[actual_cost] )
Cost To Complete = SUM ( fact_budget[estimate_to_complete] )
EAC = [Actual Cost] + [Cost To Complete]
Percent Complete = DIVIDE ( [Actual Cost], [EAC] )
```

## 2. Projected margin and margin fade

| Metric | Plain-English formula |
|---|---|
| **Revised contract value** | Original contract + approved change-order revenue. |
| **Projected profit** | Revised contract value - EAC. |
| **Projected margin** | Projected profit / revised contract value. |
| **Bid margin** | (Original contract - original budget cost) / original contract. This is the benchmark. |
| **Margin fade (pts)** | (Bid margin - projected margin) x 100. Positive means the job is earning less than it was bid to earn. |
| **Margin fade ($)** | (Bid margin - projected margin) x revised contract value: profit lost versus the bid. |
| **Share of fade** | A job's fade $ / total fade $ of active jobs that have positive fade. "Top 3 share" adds the three largest. |
| **Portfolio projected margin** | Sum of projected profit / sum of revised contract value, active jobs. |

*Design choice:* fade is measured against the **bid** margin (what the company priced the job to earn), not against the revised budget, because budgets can be quietly rebaselined and hide erosion. Approved change orders add both revenue and budgeted cost, so they do not by themselves create fade.

```dax
Revised Contract = SUM ( dim_project[original_contract_value] ) + [Approved CO Revenue]
Projected Margin = DIVIDE ( [Revised Contract] - [EAC], [Revised Contract] )
Margin Fade Pts = ( SELECTEDVALUE ( dim_project[original_margin_pct] ) - [Projected Margin] ) * 100
```

## 3. Over / under billing (WIP)

| Metric | Plain-English formula |
|---|---|
| **Earned revenue** | Percent complete x revised contract value. |
| **Billed to date** | Sum of gross pay applications (before retainage). |
| **Over / (under) billing** | Billed to date - earned revenue. Positive = over-billed (cash collected ahead of work, a liability); negative = under-billed (the company is financing the owner). |
| **Billing position** | `Over-billed` or `Under-billed` when the gap exceeds 2% of revised contract value (`billing_balance_threshold`); otherwise `Balanced`; `Closed` for completed jobs. |

*Why it matters:* a large over-billing can mask a job that is behind or losing money, and a large under-billing is a cash and sometimes a bonding-capacity problem. The timeline view (`v_project_billing_curve`) restates earlier months at the **current** EAC, so it shows direction, not the WIP report as it stood each month.

## 4. Pending change-order exposure

| Metric | Plain-English formula |
|---|---|
| **Pending CO revenue** | Sum of `amount` on change orders with status Pending: work requested or performed but not yet contractually approved. |
| **Pending CO cost at risk** | Sum of `estimated_cost` on the same change orders: the cost the company carries if the owner never approves. |
| **Age (days)** | As-of date - submitted date, for pending change orders. Oldest and average are reported. |
| **Exposure % of contract** | Pending CO revenue / revised contract value. |
| **Approval cycle (days)** | Average days from submission to decision on decided change orders. |

Pending change orders are **not** included in revised contract value or EAC; they are reported separately so exposure is visible rather than blended into margin.

## 5. Backlog

| Metric | Plain-English formula |
|---|---|
| **Backlog, active jobs** | Revised contract value - earned revenue, for active jobs (contracted work not yet performed). |
| **Backlog, awarded not started** | Amount of CRM opportunities in stage Won that have no ERP project yet. |
| **Total backlog** | Sum of the two. **Unsigned pipeline is excluded.** |

Cross-checked against published definitions of construction backlog as work secured under contract but not yet completed, including signed contracts not yet started.

## 6. Pipeline, weighted pipeline and win rate

| Metric | Plain-English formula |
|---|---|
| **Open pipeline** | Sum of `amount` for opportunities in Lead, Qualified, Proposal or Negotiation. |
| **Weighted pipeline** | Sum of `amount x probability` over open opportunities. Probability is the CRM's stage probability (about 10% / 25% / 50% / 75%). |
| **Win rate** | Won / (Won + Lost), by count. Value-based win rate (won $ / (won $ + lost $)) is provided alongside. |
| **Pipeline coverage** | Weighted pipeline / total backlog. |

*Caveat:* stage probabilities are generic defaults, not calibrated to history; a real implementation would replace them with observed stage-to-win conversion rates.

## 7. Safety

| Metric | Plain-English formula |
|---|---|
| **Recordable incident** | Incident type `Recordable` or `Lost Time` (flag `Y`). Near misses and first-aid cases are tracked but are not recordable. |
| **TRIR** (total recordable incident rate) | Recordable incidents x 200,000 / hours worked. 200,000 = 100 full-time workers x 40 hours x 50 weeks (OSHA convention). Reported for all history (24 months) and trailing 12 months, by project and business unit. |
| **Safety cluster** | A project with at least 5 incidents (any type) inside any 90-day window. Thresholds are parameters in `ops.etl_params`. |

*Caveat:* hours come from timecards of field staff only; small hour bases make rates volatile, so counts are always shown next to rates.

## 8. Drill-down series (assumptions)

- **Budget (plan) curve:** the ERP export carries no baseline schedule, so revised budget is spread over the planned duration on a standard S-curve, cumulative = 3u^2 - 2u^3 where u is the share of planned months elapsed. It is labelled as an assumption on the dashboard.
- **Forecast curve:** equals actuals through the as-of month, then spreads cost to complete over the remaining planned months with the same S-curve shape, ending at EAC.

## 9. Procurement (purchase orders and three-way match)

| Metric | Plain-English formula |
|---|---|
| **Open order** | PO line with status Ordered, Shipped or Partially Received. |
| **Overdue open order** | Open line whose promised date is before the as-of date. Days overdue = as-of minus promised date. |
| **On-time delivery rate** | Fully received lines delivered on or before the promised date / all fully received lines. Cancelled lines are excluded. |
| **Days late (delivered)** | Received date minus promised date; negative means early. |
| **Long-lead item** | Flagged by the ERP (typical lead time 60+ days); the watch list shows open ones as Overdue, Due within 30 days, or On order. |
| **Received, not invoiced** | More receipts than vendor invoices on a PO line (one invoice is expected per receipt) and the last receipt is more than 30 days old: an unrecorded liability. |
| **Invoiced, not received** | A vendor invoice exists but nothing has been received on a non-cancelled line. |
| **Invoice price exception** | Where every receipt has been invoiced: (invoiced - received value) / received value above 5%. |

## 10. Subcontract position

| Metric | Plain-English formula |
|---|---|
| **Committed** | Original commitment + approved changes. |
| **Billed / paid** | Sum of pay applications (gross) / cash paid (net of retainage). |
| **Retainage held** | 10% withheld on each pay application until released. |
| **Net payable** | Billed - retainage held + retainage released - paid. |
| **Over-committed** | Cost-code commitments (subcontracts and purchase orders) exceed the revised budget by more than 5%. Commitments normally run a few percent above the original budget as scope grows, so a tighter threshold would flag nearly every line. |

## 11. AP and AR aging

- **Days past due** = as-of date - due date. **Buckets:** Current (not yet due), 1-30, 31-60, 61-90, 90+.
- **AP open items:** unpaid vendor invoices (full amount) plus unpaid subcontractor pay applications (gross less retainage, less any payment). Items dated after the as-of date (for example a pay application received 3 October) are not yet received and are excluded. Held and disputed items are flagged.
- **AR open items:** submitted owner billings not yet paid, valued at gross less retainage. Retainage receivable is reported separately in `v_retainage_position`, together with retainage payable to subcontractors.

## 12. Equipment

- **Utilisation** = days used / (22 working days x unit-months), averaged over the units and months considered.
- **Standby days** = days on site not working. **Idle cost** = standby days x daily rate, counted for *rented* units only (rent is owed whether or not the machine works).
- **Equipment cost** = cost charged to the job, split rented vs owned.

## 13. Manufacturing inventory

- **Days of cover** = on hand / average daily usage. **Reorder status:** *Below reorder point* (on hand < reorder point), *Low* (< 1.25 x reorder point), else *OK*.
- **Stock-out risk** = days of cover is less than the supplier lead time (a new order cannot arrive in time).
- **Suggested order value** = reorder quantity x unit cost, for items below the reorder point.

## 14. RFIs and submittals

- **Open RFI** has no response yet; **overdue** when open and past its due date (14 days after submission). **Days open** = as-of - submitted.
- **Pending submittal** has not been returned; **late** when pending and past its required-by date. **Resubmittal** = more than one review cycle.

## 15. Schedule

- **Milestone slip (days)** = forecast (or actual) date - planned date. **Schedule status** from the final milestone: *Late* (more than 30 days), *At risk* (more than 7), else *On track*.
- **Schedule variance (points)** = cost-to-cost percent complete - planned percent complete (baseline S-curve, assumption in section 8). Negative means behind plan. Because spend, not physical progress, drives both numbers, this is a spend-based proxy, not a critical-path schedule.

## Parameters

| Parameter | Value | Where |
|---|---|---|
| As-of date | 2026-09-30 | `ops.etl_params.as_of_date` |
| Billing balance threshold | 2% of revised contract | `billing_balance_threshold` |
| Safety cluster | 5 incidents in 90 days | `safety_cluster_min_incidents`, `safety_cluster_window_days` |
| TRIR base | 200,000 hours | hard-coded in `05_metrics.sql` (OSHA constant) |
| Working days per month (equipment) | 22 | hard-coded in `05_metrics.sql` |
| Overdue / aging reference | as-of date | `ops.etl_params.as_of_date` |
| Three-way-match thresholds | 30 days uninvoiced, 5% price variance | `05_metrics.sql` |

## Reconciliation guarantees

The data-quality suite (`sql/04_quality_checks.sql`) asserts that portfolio backlog equals the sum of its parts, weighted pipeline equals the sum over open opportunities in staging, billed to date equals staged billings, margin-fade shares sum to 100%, and the project summary has exactly one row per project. `tests/independent_recompute.py` separately recomputes the headline metrics in pandas from the raw CSVs and matches them to the cent.
