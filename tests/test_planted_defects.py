"""
Answer-key tests: every planted defect is handled as logged, and the cleaned
warehouse reconciles to the clean answer key produced by the generator.

Run:  python tests/test_planted_defects.py      (or: pytest tests)
Requires a built warehouse:  python src/build_warehouse.py
SYNTHETIC DATA ONLY.
"""
import json
import re
from pathlib import Path

import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "warehouse.duckdb"
LOG = pd.DataFrame(json.load(open(ROOT / "data/truth/planted_defects.json")))
KEY = json.load(open(ROOT / "data/truth/answer_key.json"))


def con():
    return duckdb.connect(str(DB), read_only=True)


def test_every_rejected_or_deduplicated_defect_is_quarantined():
    c = con()
    rej = c.sql("select source_table, source_key, reject_reason from stg.rejects").df()
    want = LOG[LOG.expected_action.isin(["rejected", "deduplicated"])]
    merged = want.merge(rej, left_on=["table", "key"], right_on=["source_table", "source_key"], how="left")
    missing = merged[merged.reject_reason.isna()]
    assert missing.empty, f"planted defects NOT quarantined:\n{missing[['table','key','defect_type']]}"


def test_nothing_else_is_rejected():
    """No over-rejection: rejects == planted rejected/deduplicated rows, exactly."""
    c = con()
    n = c.sql("select count(*) from stg.rejects").fetchone()[0]
    expected = int(LOG.expected_action.isin(["rejected", "deduplicated"]).sum())
    assert n == expected, f"rejects={n}, planted={expected}"


def test_reject_reasons_match_defect_types():
    c = con()
    rej = c.sql("select source_table, source_key, reject_reason from stg.rejects").df()
    expect = {"missing_cost_code": "missing_cost_code", "negative_amount_sign_error": {"negative_amount_without_credit_memo", "negative_gross_billed"},
              "orphan_project_fk": "orphan_project_fk", "orphan_employee_fk": "orphan_employee_fk",
              "orphan_account_fk": "orphan_account_fk", "orphan_opportunity_fk": "orphan_opportunity_fk",
              "future_period": "future_period", "hours_out_of_range": "hours_out_of_range",
              "duplicate_invoice_exact": "duplicate_invoice", "duplicate_invoice_rekeyed": {"duplicate_invoice", "duplicate_vendor_invoice"}}
    for _, d in LOG[LOG.defect_type.isin(expect)].iterrows():
        got = rej[(rej.source_table == d["table"]) & (rej.source_key == d["key"])].reject_reason.tolist()
        want = expect[d.defect_type]
        want = want if isinstance(want, set) else {want}
        assert want & set(got), f"{d['table']} {d['key']} {d.defect_type}: got {got}"


def test_fixable_defects_are_fixed_not_rejected():
    c = con()
    rej_keys = set(map(tuple, c.sql("select source_table, source_key from stg.rejects").fetchall()))
    fixed = LOG[LOG.expected_action == "fixed"]
    assert not any((r["table"], r["key"]) in rej_keys for _, r in fixed.iterrows()), "a fixable row was quarantined"
    canon = {r[0] for r in c.sql("select distinct vendor_std from stg.vendor_map").fetchall()}
    assert len(canon) == 16
    bad_vendor = c.sql("select count(*) from stg.actual_costs where vendor_std is not null and vendor_std not in (select distinct vendor_std from stg.vendor_map)").fetchone()[0]
    assert bad_vendor == 0
    assert c.sql("select count(*) from stg.actual_costs where not regexp_matches(cost_code, '^[0-9]{2}-[0-9]{3}$')").fetchone()[0] == 0
    assert c.sql("select count(*) from stg.opportunities where stage not in ('Lead','Qualified','Proposal','Negotiation','Won','Lost')").fetchone()[0] == 0
    # the staged copy of each fixable actual_costs row exists with typed values
    ids = tuple(fixed[fixed.table == "actual_costs"].key.unique())
    n = c.sql(f"select count(*) from stg.actual_costs where cost_id in {ids}").fetchone()[0]
    assert n == len(ids)


def test_legitimate_credit_memos_survive():
    c = con()
    n = c.sql("select count(*) from stg.actual_costs where amount < 0 and is_credit_memo").fetchone()[0]
    assert n >= 3, "credit memos were wrongly rejected"


def test_totals_reconcile_to_clean_answer_key():
    c = con()
    cost = float(c.sql("select sum(actual_cost) from mart.fact_cost").fetchone()[0])
    bill = float(c.sql("select sum(gross_billed) from mart.fact_billing").fetchone()[0])
    assert abs(cost - KEY["portfolio"]["total_actual_cost"]) < 0.01, (cost, KEY["portfolio"]["total_actual_cost"])
    assert abs(bill - KEY["portfolio"]["total_billed"]) < 0.01


def test_project_metrics_match_answer_key():
    c = con()
    df = c.sql("select * from metrics.v_project_summary").df().set_index("project_id")
    for pid, t in KEY["projects"].items():
        r = df.loc[pid]
        assert abs(r.revised_contract_value - t["revised_contract"]) < 1, pid
        assert abs(r.estimated_cost_at_completion - t["eac"]) < 1, pid
        assert abs(r.pct_complete - t["pct_complete"]) < 1e-4, pid
        assert abs(r.margin_fade_pts - t["margin_fade_pts"]) < 0.011, pid
        assert abs(r.over_under_billing - t["over_under_billing"]) < 2, pid
        assert abs(r.pending_co_revenue - t["pending_co_revenue"]) < 1, pid
        assert abs(r.backlog_remaining - t["remaining_backlog"]) < 2, pid


def test_portfolio_metrics_match_answer_key():
    c = con()
    k = c.sql("select * from metrics.v_portfolio_kpis").df().iloc[0]
    p = KEY["portfolio"]
    assert abs(k.total_backlog - p["backlog_total"]) < 2
    assert abs(k.weighted_pipeline - p["weighted_pipeline"]) < 1
    assert abs(k.win_rate - p["win_rate"]) < 1e-3
    assert abs(k.pending_co_revenue - p["pending_co_revenue"]) < 1
    assert int(k.recordables_all) == p["total_recordables"]


def test_planted_stories_are_top_findings():
    c = con()
    df = c.sql("select * from metrics.v_project_summary where status='Active'").df().set_index("project_id")
    assert set(df.sort_values("margin_fade_pts", ascending=False).head(3).index) == {"P-103", "P-107", "P-110"}
    assert set(df.sort_values("pending_co_revenue", ascending=False).head(2).index) == {"P-104", "P-109"}
    assert df.over_under_billing.idxmax() == "P-105" and df.over_under_billing.idxmin() == "P-108"
    sc = df[df.safety_cluster].index.tolist()
    assert sc == ["P-106"], sc


def test_erp_procurement_matches_answer_key():
    c = con()
    e = KEY["erp"]["procurement"]
    k = c.sql("select * from metrics.v_portfolio_kpis").df().iloc[0]
    assert int(k.open_po_lines) == e["open_lines"]
    assert int(k.overdue_po_lines) == e["overdue_open_lines"]
    assert abs(k.overdue_po_amount - e["overdue_open_amount"]) < 0.01
    assert c.sql("select count(*) from mart.fact_purchase_order").fetchone()[0] == e["po_lines"]
    ordered = float(c.sql("select sum(ordered_amount) from mart.fact_purchase_order").fetchone()[0])
    assert abs(ordered - e["total_po_ordered"]) < 0.01, (ordered, e["total_po_ordered"])
    vs = c.sql("select vendor_name, on_time_rate from metrics.v_vendor_scorecard").df().set_index("vendor_name").on_time_rate
    for v, rate in e["on_time_rate_by_vendor"].items():
        assert abs(vs[v] - rate) < 1e-3, v
    assert vs.idxmin() == e["worst_vendor"]
    rni = set(c.sql("select po_line_id from metrics.v_po_line_status where received_not_invoiced").df().po_line_id)
    assert rni == set(e["received_not_invoiced"])
    inr = set(c.sql("select po_line_id from metrics.v_po_line_status where invoiced_not_received").df().po_line_id)
    assert inr == set(e["invoiced_not_received"])


def test_erp_cash_field_and_inventory_match_answer_key():
    c = con()
    ar = KEY["erp"]["ar"]
    # the answer key is gross; the metric is net of 10% retainage held back on each pay application
    got = c.sql("select project_id, sum(amount_open) a from metrics.v_ar_open_items where days_past_due > 0 group by 1").df().set_index("project_id").a
    for pid, gross in ar["overdue_by_project"].items():
        assert abs(got[pid] - gross * 0.9) < 0.05, pid
    assert set(got.index) == set(ar["overdue_by_project"])
    over90 = float(c.sql("select sum(amount_open) from metrics.v_ar_open_items where days_past_due > 90").fetchone()[0])
    assert abs(over90 - ar["overdue_90_plus"] * 0.9) < 0.05
    inv = set(c.sql("select item_name from metrics.v_inventory_status where reorder_status = 'Below reorder point'").df().item_name)
    assert inv == set(KEY["erp"]["inventory_below_reorder"])
    rfi = c.sql("select project_id, rfis_overdue from metrics.v_rfi_by_project where rfis_overdue > 0").df().set_index("project_id").rfis_overdue.to_dict()
    assert rfi == KEY["erp"]["rfi_open_overdue_by_project"], rfi
    sl = c.sql("select project_id, final_slip_days from metrics.v_schedule_by_project").df().set_index("project_id").final_slip_days.to_dict()
    assert sl == KEY["erp"]["milestone_final_slip_days"], sl
    d = KEY["erp"]["disputed_sub_pay_apps"]
    row = c.sql("select p.project_id, count(*) n, sum(s.gross_billed) g from mart.fact_sub_pay_app s join mart.dim_project p using(project_key) where s.status='Disputed' group by 1").df()
    assert len(row) == 1 and row.project_id[0] == d["project"] and row.n[0] == d["count"] and abs(row.g[0] - d["gross"]) < 0.01


def test_erp_planted_stories_are_top_findings():
    c = con()
    ps = c.sql("select * from metrics.v_project_summary where status='Active'").df().set_index("project_id")
    assert set(ps.sort_values("ar_overdue", ascending=False).head(3).index) == {"P-108", "P-104", "P-109"}
    assert ps.sort_values("final_slip_days", ascending=False).index[0] == "P-107"
    # Crescent steel is chronically late on P-102 only; Pelican Metal Works owns most overdue open lines
    cr = c.sql("select project_id, avg(days_late_delivered) l from metrics.v_po_line_status where status='Received' and vendor_name='Crescent Steel Supply' group by 1").df().set_index("project_id").l
    assert cr.idxmax() == "P-102" and cr["P-102"] > 15 and cr.drop("P-102").max() < 5
    vs = c.sql("select vendor_name, overdue_open_lines from metrics.v_vendor_scorecard").df().set_index("vendor_name").overdue_open_lines
    assert vs.idxmax() == "Pelican Metal Works" and vs.max() >= 5


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for f in fns:
        f()
        print("PASS", f.__name__)
    print(f"\n{len(fns)} tests passed")
