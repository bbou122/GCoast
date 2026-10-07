"""
Generate docs/data_dictionary.md from the live warehouse schema (so it cannot drift from the code).

Column descriptions come from (1) a small override table for the columns that need explaining and (2) naming conventions
(_id, _date, _amount ...). Table descriptions are written below. Run after build_warehouse.py.
SYNTHETIC DATA ONLY.
"""
import re
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
con = duckdb.connect(str(ROOT / "data" / "warehouse.duckdb"), read_only=True)

TABLE_DESC = {
    "dim_date": "One row per calendar day, 2024-10-01 to 2028-12-31. Weeks end Saturday.",
    "dim_employee": "People. Pay rate and email are deliberately NOT carried into the mart.",
    "dim_account": "Customers (owners): public agencies and private developers.",
    "dim_cost_code": "Chart of cost codes (NN-NNN) with category (Subcontract, Material, Labor, Equipment, Indirect).",
    "dim_project": "One row per project: owner, manager, dates, contract value, bid margin, status.",
    "dim_vendor": "Suppliers and subcontractors (master list used to standardise vendor spellings).",
    "dim_equipment": "Owned and rented equipment units with daily rate.",
    "fact_cost": "Actual cost postings by project, cost code and month (AP, payroll, equipment).",
    "fact_budget": "Budget by project and cost code: original, revised, estimate to complete.",
    "fact_billing": "Owner pay applications: gross billed, retainage, submit, due and paid dates.",
    "fact_change_order": "Change orders with status, amount, estimated cost and age.",
    "fact_pipeline": "CRM opportunities with stage, amount, probability and linked bid margin.",
    "fact_safety": "Safety incidents (confidential).",
    "fact_hours": "Field hours by project and week ending (denominator for safety rates).",
    "fact_commitment": "Subcontracts and PO commitments with billed, paid and retainage rolled up.",
    "fact_sub_pay_app": "Subcontractor pay applications (gross, retainage, net due, paid).",
    "fact_purchase_order": "Purchase-order lines: item, quantity, price, promised/ship/receive dates, status.",
    "fact_receipt": "Delivery receipts against PO lines.",
    "fact_ap_invoice": "Vendor invoices against PO lines.",
    "fact_equipment_usage": "Equipment days used, standby days and cost by unit, project and month.",
    "fact_inventory": "Manufacturing stock snapshot: on hand, reorder point, usage, lead time.",
    "fact_rfi": "Requests for information: submitted, due, response, cost and schedule impact.",
    "fact_submittal": "Submittals: required-by, submitted, returned, review cycles.",
    "fact_milestone": "Schedule milestones: planned, forecast and actual dates.",
}
COL = {
    "project_id": "Project number, e.g. P-101 (natural key).", "project_key": "Surrogate key to dim_project.", "vendor_name": "Standardised vendor name.",
    "cost_code": "Cost code in NN-NNN form.", "status": "Current status (domain varies by table).", "as_of_date": "Reporting date for the run (ops.etl_params).",
    "pct_complete": "Cost-to-cost percent complete: actual / (actual + estimate to complete), 0-1.", "margin_fade_pts": "Bid margin minus projected margin, percentage points.",
    "margin_fade_dollars": "Fade x revised contract value.", "over_under_billing": "Billed to date minus earned revenue; positive = over-billed.",
    "retainage_held": "Amount withheld from the payment (10%).", "is_overdue_open": "Open PO line past its promised date.",
    "days_late_delivered": "Received date minus promised date (negative = early).", "aging_bucket": "Days-past-due bucket: 1 Current, 2 1-30, 3 31-60, 4 61-90, 5 90+.",
    "days_past_due": "As-of date minus due date.", "amount_open": "Unpaid amount (AR is net of retainage).", "trir_12m": "Recordable incidents x 200,000 / hours, last 12 months.",
    "is_cluster": "5+ incidents inside any 90 days.", "safety_cluster": "5+ incidents inside any 90 days.", "weighted_pipeline": "Sum of amount x stage probability, open deals.",
    "backlog_amount": "Contracted work not yet performed (or awarded, not started).", "days_of_cover": "On hand / average daily usage.", "reorder_status": "Below reorder point, Low or OK.",
    "stockout_risk": "Days of cover shorter than supplier lead time.", "schedule_status": "Late (>30 days), At risk (>7), On track.", "final_slip_days": "Final milestone forecast minus planned date.",
    "utilization": "Days used / (22 x unit-months).", "rented_idle_cost": "Standby days x daily rate, rented units only.", "price_variance_pct": "(Invoiced - received value) / received value.",
    "exception_type": "Three-way-match exception category.", "recordable_flag": "Y for recordable and lost-time incidents.",
}


def describe(name, typ):
    if name in COL:
        return COL[name]
    n = name.lower()
    rules = [(r"_key$", "Surrogate key."), (r"_id$", "Identifier (natural key or foreign key)."), (r"_date$|_date_key$", "Calendar date."),
             (r"pct|_rate$|probability", "Ratio, stored as a decimal (0.095 = 9.5%)."), (r"amount|cost|value|budget|revenue|billed|paid|profit|price|retainage|payable|exposure", "US dollars."),
             (r"^is_|^has_", "True/false flag."), (r"_count$|^count|^number|lines$|items$", "Count."), (r"days", "Days."), (r"qty|quantity", "Quantity in the item's unit of measure."),
             (r"name$", "Name."), (r"hours", "Hours worked.")]
    for pat, d in rules:
        if re.search(pat, n):
            return d
    return ""


def cols(schema, table):
    return con.execute("select column_name, data_type, is_nullable from information_schema.columns where table_schema=? and table_name=? order by ordinal_position", [schema, table]).fetchall()


def tables(schema, kind):
    return [r[0] for r in con.execute("select table_name from information_schema.tables where table_schema=? and table_type=? order by 1", [schema, kind]).fetchall()]


def count(schema, t):
    return con.execute(f'select count(*) from {schema}."{t}"').fetchone()[0]


def main():
    L = ["# Data dictionary\n",
         "> **Synthetic data.** Gulf Coast Builders is fictional. This file is **generated** from the live warehouse by `src/make_data_dictionary.py` (run by `run_all.py`), so it matches the schema exactly. Column descriptions come from naming conventions plus overrides for columns that need explaining; table-level meaning is in `docs/data_model.md`.\n",
         "Money is US dollars (`DECIMAL(18,2)`); ratios are decimals (0.095 = 9.5%); dates are `DATE`. As-of date: see `ops.etl_params`.\n"]
    L.append("## Layers at a glance\n\n| Schema | Purpose | Objects |\n|---|---|---|")
    for sc, purpose in [("raw", "Source exports as delivered (all text)"), ("stg", "Typed, cleaned, de-duplicated; rejects quarantined"), ("mart", "Star schema for analysis"),
                        ("metrics", "One SQL view per business metric"), ("ops", "Run parameters, audit, data-quality results")]:
        n = len(tables(sc, "BASE TABLE")) + len(tables(sc, "VIEW"))
        L.append(f"| `{sc}` | {purpose} | {n} |")
    L.append("")
    for sc, title in [("raw", "Raw layer"), ("stg", "Staging layer")]:
        L.append(f"## {title} (`{sc}`)\n\n| Table | Rows | Columns |\n|---|---:|---|")
        for t in tables(sc, "BASE TABLE"):
            L.append(f"| `{t}` | {count(sc, t):,} | {', '.join(c[0] for c in cols(sc, t))} |")
        L.append("")
    L.append("## Mart layer (`mart`)\n")
    for t in tables("mart", "BASE TABLE"):
        L.append(f"### `mart.{t}`  ({count('mart', t):,} rows)\n")
        if t in TABLE_DESC:
            L.append(TABLE_DESC[t] + "\n")
        L.append("| Column | Type | Null? | Meaning |\n|---|---|---|---|")
        for n, ty, nl in cols("mart", t):
            L.append(f"| `{n}` | {ty} | {'yes' if nl == 'YES' else 'no'} | {describe(n, ty)} |")
        L.append("")
    L.append("## Metric views (`metrics`)\n\nEach view's logic and plain-English definition is in `sql/05_metrics.sql` and `docs/metric_definitions.md`.\n")
    for t in tables("metrics", "VIEW"):
        L.append(f"### `metrics.{t}`  ({count('metrics', t):,} rows)\n")
        L.append("| Column | Type | Meaning |\n|---|---|---|")
        for n, ty, nl in cols("metrics", t):
            L.append(f"| `{n}` | {ty} | {describe(n, ty)} |")
        L.append("")
    L.append("## Operations (`ops`)\n")
    for t in tables("ops", "BASE TABLE") + tables("ops", "VIEW"):
        L.append(f"### `ops.{t}`\n\n| Column | Type |\n|---|---|")
        for n, ty, nl in cols("ops", t):
            L.append(f"| `{n}` | {ty} |")
        L.append("")
    (ROOT / "docs" / "data_dictionary.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"wrote docs/data_dictionary.md ({len(L)} lines)")


if __name__ == "__main__":
    main()
