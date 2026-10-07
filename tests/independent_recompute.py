"""
Independent recomputation of headline numbers in pandas, straight from the RAW CSVs,
with its OWN cleaning logic (does not import or reuse any SQL). The warehouse
numbers must match. This is the cross-validation technique "calculate the same
metric two different ways".

Run:  python tests/independent_recompute.py
SYNTHETIC DATA ONLY.
"""
import re
import sys
from pathlib import Path

import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
AS_OF = pd.Timestamp("2026-09-30")


def rd(name):
    return pd.read_csv(RAW / f"{name}.csv", dtype=str, keep_default_na=False)


def money(s):
    return pd.to_numeric(s.str.replace(r"[$,]", "", regex=True).str.strip(), errors="coerce")


def dt(s):
    a = pd.to_datetime(s, format="%Y-%m-%d", errors="coerce")
    b = pd.to_datetime(s, format="%m/%d/%Y", errors="coerce")
    return a.fillna(b)


def erp_recompute(c):
    """ERP expansion: procurement, cash and field metrics rebuilt from the raw CSVs with separate pandas logic."""
    projects = rd("projects")
    po = rd("purchase_orders").drop_duplicates()          # exact duplicate rows
    for col in ["order_date", "promised_date", "received_date"]:
        po[col] = dt(po[col])
    po["q"] = pd.to_numeric(po.quantity)
    po["amt"] = money(po.ordered_amount)
    bad = (po.q <= 0) | ~po.project_id.isin(projects.project_id) | (po.received_date.notna() & (po.received_date < po.order_date))
    po = po[~bad].drop_duplicates("po_line_id")
    open_ = po[po.status.isin(["Ordered", "Shipped", "Partially Received"])]
    overdue = open_[open_.promised_date < AS_OF]
    rec = po[po.status == "Received"]
    mine = {"open_po_lines": len(open_), "open_po_value": open_.amt.sum(), "overdue_po_lines": len(overdue),
            "overdue_po_amount": overdue.amt.sum(), "on_time_delivery_rate": (rec.received_date <= rec.promised_date).mean()}
    # AR: submitted, unpaid pay applications; amount open is gross less retainage
    bl = rd("billings")
    bl = bl[bl.project_id.isin(projects.project_id)]
    bl["g"], bl["r"] = money(bl.gross_billed), money(bl.retainage_held)
    bl = bl[(bl.g >= 0)].sort_values("billing_id").drop_duplicates(["project_id", "invoice_no"])
    bl["due"], bl["subm"] = dt(bl.due_date), dt(bl.submitted_date)
    arx = bl[(bl.paid_date.str.strip() == "") & (bl.subm <= AS_OF)]
    arx = arx.assign(open=arx.g - arx.r, late=(AS_OF - arx.due).dt.days)
    mine.update(ar_open=arx.open.sum(), ar_overdue=arx[arx.late > 0].open.sum(), ar_over_90=arx[arx.late > 90].open.sum())
    # AP: unpaid vendor invoices + unpaid subcontractor pay applications
    ap = rd("ap_invoices")
    ap["amt"] = money(ap.amount)
    ap["inv"] = dt(ap.invoice_date)
    ap["vk"] = ap.vendor_name.str.lower().str.replace(r"[^a-z]", "", regex=True).str[:6]
    ap = ap[ap.po_line_id.isin(po.po_line_id) & (ap.inv <= AS_OF)]
    ap = ap.sort_values("invoice_id").drop_duplicates(["vk", "invoice_no"])      # re-keyed duplicates share vendor + invoice no
    apu = ap[ap.paid_date.str.strip() == ""]
    ap_total = apu.amt.sum()
    cm = rd("commitments")
    sp = rd("subcontract_pay_apps")
    sp["g"], sp["r"], sp["paid"] = money(sp.gross_billed), money(sp.retainage_held), money(sp.paid_amount)
    sp = sp[sp.commitment_id.isin(cm.commitment_id) & (sp.g >= 0)]
    spu = sp[(sp.paid_date.str.strip() == "") & (dt(sp.invoice_date) <= AS_OF)]      # not-yet-received applications are excluded
    mine["ap_open"] = ap_total + (spu.g - spu.r - spu.paid).sum()
    # RFIs, inventory
    rf = rd("rfis")
    rf = rf[rf.project_id.isin(projects.project_id)]
    rfo = rf[rf.status == "Open"]
    mine["rfis_overdue"] = int((dt(rfo.due_date) < AS_OF).sum())
    inv = rd("inventory_items")
    inv["oh"], inv["rp"] = pd.to_numeric(inv.on_hand_qty), pd.to_numeric(inv.reorder_point)
    mine["items_below_reorder"] = int(((inv.oh >= 0) & (inv.oh < inv.rp)).sum())
    k = c.sql("select * from metrics.v_portfolio_kpis").df().iloc[0]
    bad = 0
    print(f"\n{'ERP metric':32} {'pandas (independent)':>24} {'SQL warehouse':>24}  match")
    for key, a in mine.items():
        b = float(k[key])
        m = abs(float(a) - b) <= max(0.01, 1e-6 * abs(float(a)))
        bad += (not m)
        print(f"{key:32} {float(a):>24,.4f} {b:>24,.4f}  {'OK' if m else 'MISMATCH'}")
    return bad


def main():
    projects, codes, emps = rd("projects"), rd("cost_codes"), rd("employees")
    # ---- actual costs: clean independently
    ac = rd("actual_costs")
    ac["amt"] = money(ac.amount)
    ac["per"] = dt(ac.period)
    digits = ac.cost_code.str.replace(r"\D", "", regex=True)
    ac["code"] = digits.where(digits.str.len() == 5).map(lambda d: f"{d[:2]}-{d[2:]}" if isinstance(d, str) else None)
    ok = (ac.cost_code.str.strip() != "") & ac.code.notna() & ac.code.isin(codes.cost_code) & ac.project_id.isin(projects.project_id) \
        & (ac.per <= AS_OF) & ~((ac.amt < 0) & ~ac.description.str.contains("credit memo", case=False))
    ac = ac[ok]
    # ---- billings: dedupe on project + invoice, drop negatives and orphans
    bl = rd("billings")
    bl["g"] = money(bl.gross_billed)
    bl = bl[bl.project_id.isin(projects.project_id) & (bl.g >= 0)].sort_values("billing_id").drop_duplicates(["project_id", "invoice_no"])
    # ---- budget / ETC
    bud = rd("budget_lines")
    for c in ["original_budget", "estimate_to_complete"]:
        bud[c] = money(bud[c])
    # ---- change orders
    co = rd("change_orders")
    co["amount"] = money(co.amount)
    co = co[co.project_id.isin(projects.project_id)]

    p = projects.set_index("project_id")
    p["contract"] = money(p.original_contract_value)
    actual = ac.groupby("project_id").amt.sum()
    etc = bud.groupby("project_id").estimate_to_complete.sum()
    orig_cost = bud.groupby("project_id").original_budget.sum()
    appr = co[co.status == "Approved"].groupby("project_id").amount.sum()
    pend = co[co.status == "Pending"].groupby("project_id").amount.sum()
    billed = bl.groupby("project_id").g.sum()
    df = pd.DataFrame({"contract": p.contract, "status": p.status, "actual": actual, "etc": etc, "orig_cost": orig_cost,
                       "appr": appr, "pend": pend, "billed": billed}).fillna(0.0)
    df["rev"] = df.contract + df.appr
    df["eac"] = df.actual + df.etc
    df["pct"] = (df.actual / df.eac).clip(upper=1)
    df["bid_m"] = (df.contract - df.orig_cost) / df.contract
    df["proj_m"] = (df.rev - df.eac) / df.rev
    df["fade_pts"] = (df.bid_m - df.proj_m) * 100
    df["fade_usd"] = (df.bid_m - df.proj_m) * df.rev
    df["earned"] = df.pct * df.rev
    df["overunder"] = df.billed - df.earned
    act = df[df.status == "Active"]
    backlog_active = (act.rev - act.earned).clip(lower=0).sum()

    opp = rd("opportunities")
    opp = opp[opp.account_id.isin(rd("accounts").account_id)]
    opp["stage_n"] = opp.stage.str.strip().str.lower().str[:3].map({"lea": "Lead", "qua": "Qualified", "pro": "Proposal", "neg": "Negotiation", "won": "Won", "los": "Lost"})
    opp["amt"] = money(opp.amount)
    opp["prob"] = pd.to_numeric(opp.probability)
    openp = opp[opp.stage_n.isin(["Lead", "Qualified", "Proposal", "Negotiation"])]
    weighted = (openp.amt * openp.prob).sum()
    won, lost = (opp.stage_n == "Won").sum(), (opp.stage_n == "Lost").sum()
    unstarted = opp[(opp.stage_n == "Won") & ~opp.opportunity_id.isin(projects.opportunity_id)].amt.sum()

    si = rd("safety_incidents")
    si = si[si.project_id.isin(projects.project_id)]
    tc = rd("timecards")
    tc = tc[tc.employee_id.isin(emps.employee_id) & tc.project_id.isin(projects.project_id)]
    tc["h"] = pd.to_numeric(tc.regular_hours) + pd.to_numeric(tc.overtime_hours)
    tc = tc[pd.to_numeric(tc.regular_hours).between(0, 80)]
    rec = si.recordable_flag.str.upper().eq("Y").sum()
    trir = rec * 200000 / tc.h.sum()

    mine = {
        "total_actual_cost": ac.amt.sum(), "total_billed": bl.g.sum(),
        "backlog_total": backlog_active + unstarted, "weighted_pipeline": weighted, "win_rate": won / (won + lost),
        "pending_co_revenue": act.pend.sum(), "trir_all": trir,
        "portfolio_projected_margin": act.rev.sum() * 0 + (act.rev - act.eac).sum() / act.rev.sum(),
        "top3_fade_jobs": ",".join(sorted(act.sort_values("fade_usd", ascending=False).head(3).index)),
        "top3_share_of_fade": act.sort_values("fade_usd", ascending=False).head(3).fade_usd.sum() / act[act.fade_usd > 0].fade_usd.sum(),
    }
    c = duckdb.connect(str(ROOT / "data/warehouse.duckdb"), read_only=True)
    k = c.sql("select * from metrics.v_portfolio_kpis").df().iloc[0]
    sql = {"total_actual_cost": c.sql("select sum(actual_cost) from mart.fact_cost").fetchone()[0],
           "total_billed": c.sql("select sum(gross_billed) from mart.fact_billing").fetchone()[0],
           "backlog_total": k.total_backlog, "weighted_pipeline": k.weighted_pipeline, "win_rate": k.win_rate,
           "pending_co_revenue": k.pending_co_revenue, "trir_all": k.trir_all, "portfolio_projected_margin": k.portfolio_projected_margin,
           "top3_fade_jobs": ",".join(sorted(c.sql("select project_id from metrics.v_project_margin where status='Active' and fade_rank<=3").df().project_id)),
           "top3_share_of_fade": k.top3_share_of_fade}
    bad = 0
    print(f"{'metric':32} {'pandas (independent)':>24} {'SQL warehouse':>24}  match")
    for key in mine:
        a, b = mine[key], sql[key]
        if isinstance(a, str):
            m = a == b
        else:
            m = abs(float(a) - float(b)) <= max(0.01, 1e-6 * abs(float(a)))
        bad += (not m)
        fa = f"{a:,.4f}" if not isinstance(a, str) else a
        fb = f"{float(b):,.4f}" if not isinstance(b, str) else b
        print(f"{key:32} {fa:>24} {fb:>24}  {'OK' if m else 'MISMATCH'}")
    # per-project
    s = c.sql("select project_id, estimated_cost_at_completion eac, margin_fade_pts, over_under_billing from metrics.v_project_summary").df().set_index("project_id")
    for pid in df.index:
        assert abs(s.loc[pid, "eac"] - df.loc[pid, "eac"]) < 0.02, pid
        assert abs(s.loc[pid, "margin_fade_pts"] - df.loc[pid, "fade_pts"]) < 0.011, pid
        assert abs(s.loc[pid, "over_under_billing"] - df.loc[pid, "overunder"]) < 0.05, pid
    print(f"per-project EAC, margin fade and over/under billing match for all {len(df)} projects")
    bad += erp_recompute(c)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
