"""
Export the metric views to one JSON document that the dashboard embeds.

Every number on the dashboard comes from a SQL view in schema `metrics` (plus the data-quality
results in `ops`). Row-level tables are exported so the page can re-aggregate for each role's
scope; nothing here is computed outside SQL except filtering in the browser.

Run:  python src/export_dashboard_data.py      -> data/dashboard_data.json
SYNTHETIC DATA ONLY.
"""
import json
import re
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "warehouse.duckdb"
OUT = ROOT / "data" / "dashboard_data.json"

# name in JSON -> SQL (all read from the metric layer)
TABLES = {
    "projects": "SELECT * FROM metrics.v_project_summary ORDER BY project_id",
    "cost_curve": "SELECT project_id, month_end, budget_cum, actual_cum, forecast_cum, eac FROM metrics.v_project_cost_curve ORDER BY 1, 2",
    "billing_curve": "SELECT project_id, month_end, cost_cum, billed_cum, earned_cum FROM metrics.v_project_billing_curve ORDER BY 1, 2",
    "cost_by_code": "SELECT * FROM metrics.v_project_cost_by_code ORDER BY 1, 2",
    "change_orders": "SELECT * FROM metrics.v_change_order_detail ORDER BY project_id, submitted_date, change_order_id",
    "safety_by_project": "SELECT * EXCLUDE (project_key) FROM metrics.v_safety_by_project ORDER BY project_id",
    "safety_detail": "SELECT * FROM metrics.v_safety_detail ORDER BY incident_date, incident_id",
    "backlog": "SELECT * FROM metrics.v_backlog ORDER BY backlog_amount DESC",
    "pipeline_by_stage": "SELECT * FROM metrics.v_pipeline_by_stage ORDER BY business_unit, stage_order",
    "pipeline_by_bu": "SELECT * FROM metrics.v_pipeline_by_bu ORDER BY business_unit",
    "po_lines": """SELECT project_id, po_line_id, po_number, vendor_name, vendor_type, cost_code, item_description, is_long_lead, status, ordered_amount,
                   order_date, promised_date, ship_date, received_date, received_amount, invoiced_amount, on_hold_amount, is_open, days_late_delivered,
                   is_overdue_open, days_overdue, received_not_invoiced, invoiced_not_received, price_variance_pct
                   FROM metrics.v_po_line_status ORDER BY po_line_id""",
    "long_lead": "SELECT * FROM metrics.v_long_lead_watch ORDER BY promised_date",
    "three_way": "SELECT * FROM metrics.v_three_way_match_exceptions ORDER BY exception_amount DESC",
    "subcontracts": "SELECT * FROM metrics.v_subcontract_position ORDER BY project_id, vendor_name",
    "commit_vs_budget": "SELECT * FROM metrics.v_commitment_vs_budget ORDER BY project_id, cost_code",
    "ap_open": "SELECT * FROM metrics.v_ap_open_items ORDER BY days_past_due DESC, reference_id",
    "ar_open": "SELECT * FROM metrics.v_ar_open_items ORDER BY days_past_due DESC, billing_id",
    "equipment": "SELECT * FROM metrics.v_equipment_usage_detail ORDER BY project_id, equipment_id",
    "inventory": "SELECT * FROM metrics.v_inventory_status ORDER BY days_of_cover",
    "rfi_open": "SELECT * FROM metrics.v_rfi_open_detail ORDER BY days_past_due DESC",
    "milestones": "SELECT * FROM metrics.v_milestone_detail ORDER BY project_id, planned_date",
    "dq_results": "SELECT check_id, check_name, layer, check_type, severity, status, rows_affected, description FROM ops.dq_results WHERE run_id = (SELECT run_id FROM ops.dq_results ORDER BY run_ts DESC LIMIT 1) ORDER BY check_id",
    "staging_audit": "SELECT * FROM ops.staging_audit ORDER BY rejected_rows DESC, table_name",
    "reject_reasons": "SELECT source_table, reject_reason, COUNT(*) AS rows FROM stg.rejects GROUP BY 1, 2 ORDER BY 3 DESC, 1, 2",
}


def clean(v):
    if isinstance(v, Decimal):
        return round(float(v), 4)
    if isinstance(v, (datetime, date)):
        return v.strftime("%Y-%m-%d")
    if isinstance(v, float):
        return None if v != v else round(v, 6)
    return v


def rows(con, sql):
    cur = con.execute(sql)
    cols = [d[0] for d in cur.description]
    return [{c: clean(v) for c, v in zip(cols, r)} for r in cur.fetchall()]


def view_sql():
    """Text of each metric view, for the dashboard's 'Show the SQL' panels."""
    text = (ROOT / "sql" / "05_metrics.sql").read_text()
    out = {}
    for m in re.finditer(r"(CREATE OR REPLACE VIEW metrics\.(\w+) AS.*?;)\s*(?=\n--|\nCREATE|\Z)", text, flags=re.S):
        out[m.group(2)] = m.group(1)
    return out


def main():
    con = duckdb.connect(str(DB), read_only=True)
    data = {k: rows(con, q) for k, q in TABLES.items()}
    data["kpis"] = rows(con, "SELECT * FROM metrics.v_portfolio_kpis")[0]
    data["people"] = rows(con, "SELECT DISTINCT business_unit, project_manager FROM metrics.v_project_summary ORDER BY 1, 2")
    data["bu_leads"] = rows(con, "SELECT business_unit, full_name FROM mart.dim_employee WHERE role = 'Business Unit Lead' ORDER BY 1")
    data["sql"] = view_sql()
    data["meta"] = {"as_of": data["kpis"]["as_of_date"], "company": "Gulf Coast Builders (fictional)", "synthetic": True,
                    "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M")}
    OUT.write_text(json.dumps(data, separators=(",", ":")))
    print(f"wrote {OUT.relative_to(ROOT)}  {OUT.stat().st_size/1e6:.2f} MB, {len(data)} keys, {len(data['sql'])} views captured")


if __name__ == "__main__":
    main()
