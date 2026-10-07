# Planted findings (answer key for the business questions)

> **Synthetic data.** These stories were written into the generator on purpose so the dashboard has real findings to surface and so verification has something concrete to check. Figures come from the *clean* data before defects are injected (`data/truth/answer_key.json`, produced by `src/generate_data.py`, seed `20260930`). As-of date: **30 Sep 2026**.

## Story 1: margin fade (Q1)

Three active jobs have estimates to complete that are well above remaining budget on specific cost codes.

| Job | Business unit | Bid margin | Projected margin | Fade (pts) | Cause planted |
|---|---|---|---|---|---|
| P-103 Riverbend Hotel Renovation | Building | 11.0% | 4.4% | **6.6** | MEP, finishes and concrete subcontract overruns, both in actuals and in the estimate to complete |
| P-110 Precast Wall Panel Supply | Manufacturing | 17.0% | 11.0% | **6.0** | Steel and fabrication-material price shock |
| P-107 Lakeshore Levee Segment 4 | Heavy Civil | 10.5% | 4.9% | **5.6** | Earthwork, aggregate and paving overruns, plus four weather months |

These three jobs hold about **88% of all margin-fade dollars** in the active portfolio (and 18.3 of 20.4 fade points). Every other active job is within about one point of its bid margin (some slightly better).

**Expected dashboard headline:** "3 jobs account for about 88% of margin fade."

## Story 2: heavy pending change orders (Q2)

| Job | Pending change orders | Pending revenue | Age planted |
|---|---|---|---|
| P-104 Cypress Parish School Addition | 7 | ~$2.59M (14% of contract) | 45 to 240 days since submission |
| P-109 Eastbank Community Center | 7 | ~$1.66M (13% of contract) | 45 to 240 days since submission |

Other jobs have only a recent change order or two waiting on a decision (P-107 has one, ~$0.13M).

## Story 3: billing position (Q3)

| Job | Position | Amount |
|---|---|---|
| P-105 Bayou Road Bridge Replacement | **Badly over-billed** (front-loaded schedule of values) | ~ +$4.3M billed ahead of earned revenue |
| P-108 Industrial Blvd Drainage Upgrade | **Under-billed** (stalled pay applications) | ~ -$1.8M earned but not billed |

All other jobs sit within a few percent of earned revenue.

## Story 4: safety cluster (Q6)

P-106 I-10 Interchange Widening has a clustered run of struck-by and equipment incidents between March and May 2026 (night-work phase): 7 planted events including 3 recordables and 1 lost-time case, on top of its normal background rate. Other jobs have an occasional background incident only.

## ERP expansion stories (procurement, cash, field)

| # | Story | What the data shows | Expected dashboard finding |
|---|---|---|---|
| 5 | **Chronically late supplier** | Pelican Metal Works delivers on time on only **20%** of lines, about 18 days late on average, and owns **6 of the 8** overdue open PO lines. Other suppliers sit at 75% to 89%. | "One supplier causes most late deliveries." |
| 6 | **Steel delays on P-102** | Crescent Steel deliveries to P-102 (structural steel, Aug 2025 to Jul 2026) average **22 days late** (worst 55); Crescent is on time everywhere else. P-102's structure milestone slips about 40 days and shop-drawing submittals cycle more than once. | "Late steel is pushing P-102's schedule." |
| 7 | **Three-way match exceptions** | **7** receipts older than 30 days with no invoice (about $0.52M unrecorded liability), **4** invoices with nothing received, and **32** invoice lines more than 5% above the value received, concentrated on P-110 steel and fabrication codes (up to 6 invoices on hold). | "Fix match exceptions before the next payment run." |
| 8 | **Slow-paying owners** | Overdue owner billings (net of retainage): **P-108 about $2.2M**, **P-104 about $1.2M**, **P-109 about $0.7M**. About $1.4M is more than 90 days past due. | "Three owners hold $4.0M of overdue receivables." |
| 9 | **Disputed subcontractor pay** | **3** Magnolia Mechanical pay applications on **P-103** are in dispute (gross about $1.06M), on the same job that is fading. | "A disputed MEP subcontract sits on the worst-fade job." |
| 10 | **Plant stock below reorder** | **Welded wire mesh, Embed plates, Rebar #4/#5** are below their reorder points, and days of cover is shorter than supplier lead time (stock-out risk) for all three. | "3 manufacturing items will run out before a new order lands." |
| 11 | **Overdue RFIs** | **10** open RFIs are past due: P-104 (4), P-109 (4), P-101 (1), P-108 (1). | "Owner answers are slow on the same jobs with stalled change orders." |
| 12 | **Schedule slip** | Final-milestone forecast slip: **P-107 61 days**, **P-102 40**, **P-105 38**, **P-109 31**, **P-108 27**, **P-106 26**. | "4 jobs are forecast more than 30 days late." |

Portfolio figures at the as-of date: 59 open PO lines worth about $6.56M, 71% on-time delivery, AP open about $14.0M (of which about $1.95M overdue), AR open about $16.3M net of retainage, retainage receivable about $21.1M and retainage payable about $8.5M, equipment utilisation 75% with about $0.88M of idle rented-equipment cost.

*Definitions note:* AR amounts are shown net of the 10% retainage held back on each pay application (retainage is reported separately). The generator's answer key stores gross amounts, and the tests apply the 90% factor.

## Supporting context

- Weather: P-105, P-106, P-107 and P-108 have months with sharply reduced spend (storms, a January freeze, summer heat), so they are behind on percent complete without a cost problem.
- Pipeline: 42 open opportunities across Lead, Qualified, Proposal and Negotiation; win rate on closed opportunities is 15 of 35 (43%); three awards worth $48.7M are won but not yet started and count toward backlog.
- Portfolio: roughly $102M remaining contract on active jobs plus $48.7M awarded-unstarted gives about **$151M backlog**; weighted pipeline is about **$178M**.

## How these are verified

At the end of the build the SQL metric views are compared to `answer_key.json`: the top-three fade jobs, the two pending-CO jobs, the over/under-billed pair, the safety cluster, the ERP stories above and the headline portfolio numbers must all match. The same key is used to check that data-quality rejects reconcile exactly to the planted defect log.
