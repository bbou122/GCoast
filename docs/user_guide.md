# User guide: reading the dashboard

> **Synthetic data.** Gulf Coast Builders is fictional. Open `docs/index.html` in any modern browser (no server, no internet needed).

## The controls

- **View as** (top right) switches between Executive, Finance, Business Unit Lead and Project Manager. Pages, rows and some fields change with the role; the yellow note under the header says what the current role can see. This is a **demonstration of the access design, not security** (see `access_matrix.md`).
- **Theme** switches light and dark. The first visit follows your system setting.
- **Tabs** move between the seven pages. On a phone the tab bar scrolls sideways.
- **Open / row clicks:** the "Open" buttons on the Executive page and rows in the project table take you to the job in question. Bars in the margin-fade and billing charts are clickable too.
- **Show the SQL** under each chart reveals the metric view behind it, so any number can be traced to its definition.
- **Web address options** (handy for screenshots): `index.html?role=pm|Joshua Garcia&page=cash&theme=dark`.

## Page by page

| Page | Question it answers | Look first at |
|---|---|---|
| **Executive** | Where should leadership look first? | "Needs attention": one line per finding, most severe first. Then the margin-fade chart (jobs earning less than they were bid to earn) and the billing chart (cash ahead of or behind the work). |
| **Project drill-down** | What is happening on one job? | The job picker, then the cost curve (plan vs actual vs forecast), the cost codes forecast over budget, change orders, milestones, open RFIs. |
| **Procurement and materials** | What is on order, what is late, and does what we pay match what we received? | Supplier on-time chart, overdue orders, long-lead watch list, three-way match exceptions, plant inventory against reorder points. |
| **Subcontracts and cash** | Who owes us, whom do we owe, how old is it, how much retainage is held? | AR and AP aging charts, largest overdue owner billings, subcontract position (disputes first), commitments over budget. |
| **Field operations** | Is the work flowing? | Schedule slip by job, equipment utilization and idle rented cost, overdue RFIs, safety cluster and injury rate. |
| **Pipeline** | Will there be enough work to replace what is burning off? | Weighted pipeline vs backlog (coverage), stage funnel, win rate by business unit. Hidden for project managers. |
| **Data quality and definitions** | Can I trust this? | "Last refresh: Passed", quarantined rows by table and reason, the list of source problems found, metric definitions. |

## Reading the key numbers

- **Margin vs bid** (project table) and **margin fade** (chart): how far projected margin sits below the margin the job was priced to earn. Fade of 2 points or more is highlighted; 5 or more is shown in the strongest colour.
- **Billing position:** billed to date minus earned revenue. A positive number means cash has been collected ahead of the work (a liability if the job later struggles); a negative number means the company is financing the owner.
- **Unapproved change orders:** work requested or done but not yet agreed in writing. The dollars are *not* in the forecast; the age shows how long the decision has been waiting.
- **Weighted pipeline:** each open deal counted at its stage probability, not its full value.
- **TRIR:** recordable injuries per 200,000 hours. With few hours a single case moves it a lot, so the tooltip shows the counts.
- **Aging buckets:** days past the due date. "Not yet due" is on time.
- **Utilization:** days worked out of 22 working days per month on site.

## Colours and accessibility

Charts use the Okabe-Ito colour-blind-safe palette. Orange-red always means "worse" and blue "ordinary"; amber means "watch". Status is never colour alone: every tag carries its word (Late, At risk, Disputed, Overdue). Charts are described to screen readers through their labels, and every chart has its numbers available in a table or tooltip. All controls work with the keyboard.

## Frequently asked

**Why does the Finance view have no safety information?** Incident records can carry injury detail and are restricted by design. See `access_matrix.md`.

**Why does a Project Manager not see the pipeline?** Company-wide sales data is outside a project manager's remit; their backlog is just their own jobs.

**A number looks wrong. How do I check it?** Open "Show the SQL" on that chart, run the view in `sql/05_metrics.sql` against the warehouse, and compare. The tests also recompute the headline numbers independently in pandas.

**Is any of this real?** No. The company, people, owners, vendors and every amount are generated.
