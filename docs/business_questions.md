# Business questions

> **Synthetic data.** Gulf Coast Builders is a fictional company created for this portfolio project. Nothing here is derived from any real company's data or systems.

Every table, metric and visual in this project exists to answer one of the decisions below. If something cannot be tied back to a question here, it does not belong in the build.

| # | Decision | Who decides | Metric(s) | Dashboard page |
|---|---|---|---|---|
| Q1 | **Which active jobs are losing margin versus the original bid?** Where should leadership intervene first? | Executive, BU Lead | Projected margin, margin fade (pts vs. bid margin) | Executive portfolio |
| Q2 | **Which jobs carry the most unapproved change-order exposure?** Which pending change orders are aging and need a decision from the owner? | PM, Finance | Pending change-order revenue, cost at risk, age in days | Executive portfolio, Project drill-down |
| Q3 | **Which jobs are over- or under-billed?** Where is cash being pulled forward, and where are we financing the owner? | Finance, PM | Over/under billing (WIP), billed vs. earned revenue | Executive portfolio, Project drill-down |
| Q4 | **What is our backlog, and does the pipeline back it up?** Is there enough weighted pipeline to replace work as it burns off? | Executive, BU Lead | Backlog (remaining contract + awarded-unstarted), weighted pipeline, pipeline coverage | Executive portfolio, Pipeline |
| Q5 | **Where are we winning and losing bids?** Which business units convert, and at what stage do we lose volume? | BU Lead, Estimating | Win rate, funnel by stage, weighted value by BU | Pipeline |
| Q6 | **Where are safety incidents clustering?** Which job or business unit needs a stand-down or extra supervision? | Executive, BU Lead, Safety | Incident counts by type and cause, recordable incident rate (TRIR) by BU | Project drill-down, Executive portfolio |
| Q7 | **Is the budget forecast credible?** For one job, how do plan, actual and forecast cost compare month by month, and does cost-to-complete look believable? | PM, Finance | Cumulative budget vs. actual vs. forecast, estimate at completion, cost to complete | Project drill-down |
| Q8 | **Can we trust the numbers on the screen?** Did the last refresh pass, and which source problems were found and quarantined? | Everyone (data owner: analytics) | Data-quality check results, rejected-row counts | Data quality and definitions |
| Q9 | **What do we still have on order, what is late, and who is the problem vendor?** Open purchase orders, shipped or not, delivered or not, cost, long-lead items at risk. | Project managers, purchasing, executives | Open order value, overdue lines, on-time delivery rate, vendor scorecard, long-lead watch | Procurement and materials |
| Q10 | **Are we paying for what we received, at the price we agreed?** Three-way match: ordered vs received vs invoiced. | Finance, purchasing | Received-not-invoiced, invoiced-not-received, invoice price variance | Procurement and materials |
| Q11 | **How much have we committed to subcontractors, what have they billed and been paid, and what retainage do we hold?** Which commitments exceed budget? | Project managers, finance | Committed, billed, paid, retainage held, balance to bill, commitment vs. budget | Subcontracts and cash |
| Q12 | **Who owes us, who do we owe, and how old is it?** AP and AR aging, held and disputed items, retainage both ways. | Finance, executives | AP and AR by aging bucket, held and disputed items, retainage receivable and payable | Subcontracts and cash |
| Q13 | **Is our equipment earning its keep?** Rented and owned cost by job, utilisation, idle rented cost. | Operations, project managers | Utilisation, standby days, rented idle cost, equipment cost by job | Field operations |
| Q14 | **Will the plant run out of material?** Stock on hand against reorder points and days of cover for manufacturing inventory. | Manufacturing lead, purchasing | On hand vs. reorder point, days of cover, stock-out risk | Procurement and materials |
| Q15 | **Which jobs are waiting on answers or slipping?** Open and overdue RFIs, late submittals, milestone slip and percent complete against plan. | Project managers, executives | Open and overdue RFIs, late submittals, milestone slip, schedule variance (points) | Project drill-down, Field operations |

## What is out of scope

- Payroll accuracy, certified-payroll reporting and union rules (timecards exist only to supply safety-rate hours).
- Fleet maintenance, fuel logs and plant production scheduling (equipment utilisation and cost by job are in scope).
- Cash-flow forecasting and collections workflow (AP and AR *aging* and retainage balances are in scope; payment runs and dunning are not).
- Anything requiring real vendor, employee or customer data.

## How each question is checked

Each question has a planted answer in `docs/planted_findings.md` (for example: the three jobs with margin fade, the over- and under-billed jobs, the safety cluster). Verification at the end of the build confirms that the dashboard's top findings match those planted stories and that headline numbers recompute independently in pandas.
