# Weekly flagged jobs

> **Synthetic data.** Gulf Coast Builders is a fictional company; nothing below describes a real business.

**Data as of Wednesday, September 30, 2026** | report generated 2026-10-07 | data-quality checks: 82 passed, 0 failed, 0 warnings

## Summary

9 of 10 active jobs are flagged. Portfolio projected margin is **8.2%** against a **10.1%** bid margin; the three largest margin losses account for **88%** of all fade dollars. Backlog is **$150.9M** with **$177.9M** weighted pipeline behind it. Owners owe **$4.0M** past due ($1.4M over 90 days) and **8** purchase-order lines are overdue.

## Flagged jobs, most urgent first

| Job | Unit | Manager | Flags |
|---|---|---|---|
| **P-107** Lakeshore Levee Segment 4 | Heavy Civil | Brian Robichaux | Margin, Schedule |
| **P-110** Precast Wall Panel Supply - Gulf Terminal | Manufacturing | Elizabeth Jones | Margin, Procurement |
| **P-103** Riverbend Hotel Renovation | Building | Michelle Walker | Margin |
| **P-106** I-10 Interchange Widening | Heavy Civil | Terrence Martin | Safety |
| **P-109** Eastbank Community Center | Building | Joshua Garcia | Change orders, RFIs, Receivables, Schedule |
| **P-104** Cypress Parish School Addition | Building | Joshua Garcia | Change orders, RFIs, Receivables |
| **P-108** Industrial Blvd Drainage Upgrade | Heavy Civil | Brian Robichaux | Billing, Procurement, Receivables |
| **P-102** Lakeview Medical Office Building | Building | Joshua Garcia | Procurement, Schedule |
| **P-105** Bayou Road Bridge Replacement | Heavy Civil | Terrence Martin | Billing, Schedule |

### P-107 Lakeshore Levee Segment 4

- **Margin:** projected margin 4.9% vs 10.5% bid (-5.6 pts, $2.6M of profit)
- **Schedule:** final milestone forecast 61 days late

### P-110 Precast Wall Panel Supply - Gulf Terminal

- **Margin:** projected margin 11.0% vs 17.0% bid (-6.0 pts, $577K of profit)
- **Procurement:** 3 overdue purchase-order lines ($100K)

### P-103 Riverbend Hotel Renovation

- **Margin:** projected margin 4.3% vs 11.0% bid (-6.7 pts, $2.1M of profit)

### P-106 I-10 Interchange Widening

- **Safety:** 9 incidents inside 90 days (from Mar 07, 2026)

### P-109 Eastbank Community Center

- **Change orders:** 7 unapproved, $1.7M (13% of contract), oldest 213 days
- **Receivables:** $663K past due from the owner
- **Schedule:** final milestone forecast 31 days late
- **RFIs:** 4 RFIs past their response date

### P-104 Cypress Parish School Addition

- **Change orders:** 7 unapproved, $2.6M (13% of contract), oldest 201 days
- **Receivables:** $1.2M past due from the owner
- **RFIs:** 4 RFIs past their response date

### P-108 Industrial Blvd Drainage Upgrade

- **Billing:** under-billed by $1.8M
- **Receivables:** $2.2M past due from the owner ($1.4M over 90 days)
- **Procurement:** 2 overdue purchase-order lines ($153K)

### P-102 Lakeview Medical Office Building

- **Schedule:** final milestone forecast 40 days late
- **Procurement:** 2 overdue purchase-order lines ($227K)
- **Procurement:** Crescent Steel Supply deliveries average 22 days late across 6 lines

### P-105 Bayou Road Bridge Replacement

- **Billing:** over-billed by $4.3M
- **Schedule:** final milestone forecast 38 days late

## Portfolio watch items

- **Supplier:** Pelican Metal Works delivered on time on 20% of 70 lines; 6 open lines are overdue.
- **Plant inventory below reorder point:** Welded wire mesh (266 sheet on hand vs 666; 15 days of cover vs 30-day lead time); Embed plates (408 ea on hand vs 658; 29 days of cover vs 40-day lead time); Rebar #4 / #5 (21 ton on hand vs 38; 19 days of cover vs 28-day lead time)
- **Disputed subcontractor pay:** Magnolia Mechanical Inc. on P-103, 3 applications, $1.1M gross.
- **Three-way match:** 7 deliveries older than 30 days with no invoice ($515K), 4 invoices with nothing received, 32 invoices more than 5% above value received.

## How a job gets flagged

| Rule | Threshold |
|---|---|
| Margin fade versus bid (points) | 2.0 |
| Unapproved change orders, share of contract | 10% |
| ...or oldest pending change order (days) | 90 |
| Over- or under-billing, share of contract | 5% |
| Owner receivables past due ($) | 500,000 |
| RFIs past response date (count) | 3 |
| Final milestone forecast slip (days) | 30 |
| Overdue open purchase-order lines (count) | 2 |
| Supplier on-time delivery below | 50% |

Every number comes from a view in the `metrics` schema (`sql/05_metrics.sql`). Definitions: `docs/metric_definitions.md`.
