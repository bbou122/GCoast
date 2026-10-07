"""
Weekly flagged-jobs report -> alerts/weekly_flagged_jobs.md

Reads only the SQL metric layer. Thresholds are listed in RULES so a reader can see (and change) what "flagged" means.

Run:  python src/weekly_alerts.py
SYNTHETIC DATA ONLY: Gulf Coast Builders is fictional.
"""
from datetime import date
from pathlib import Path

import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "warehouse.duckdb"
OUT = ROOT / "alerts" / "weekly_flagged_jobs.md"

RULES = {
    "fade_pts": 2.0,            # projected margin at least this many points below bid margin
    "pending_co_pct": 0.10,     # unapproved change orders at least 10% of contract
    "pending_co_age": 90,       # ... or the oldest pending change order is older than this many days
    "billing_pct": 0.05,        # over- or under-billed by at least 5% of contract
    "ar_overdue": 500_000,      # owner receivables past due
    "rfis_overdue": 3,          # RFIs past their response date
    "schedule_slip": 30,        # final milestone forecast this many days late
    "po_overdue_lines": 2,      # overdue open purchase-order lines
    "vendor_on_time": 0.50,     # supplier on-time delivery below this (at least 10 deliveries)
}
SEVERITY = {"Margin": 3, "Safety": 3, "Schedule": 2, "Change orders": 2, "Billing": 2, "Receivables": 2, "RFIs": 1, "Procurement": 1}


def nz(x, d=0):
    return d if pd.isna(x) else x


def money(n):
    a = abs(n)
    s = "-" if n < 0 else ""
    return f"{s}${a/1e6:.1f}M" if a >= 1e6 else f"{s}${a/1e3:.0f}K" if a >= 1e3 else f"{s}${a:.0f}"


def main():
    con = duckdb.connect(str(DB), read_only=True)
    q = lambda s: con.sql(s).df()
    k = q("select * from metrics.v_portfolio_kpis").iloc[0]
    p = q("select * from metrics.v_project_summary where status = 'Active' order by project_id")
    flags = {r.project_id: [] for r in p.itertuples()}

    for r in p.itertuples():
        add = lambda area, text: flags[r.project_id].append((area, text))
        if r.margin_fade_pts >= RULES["fade_pts"]:
            add("Margin", f"projected margin {r.projected_margin_pct:.1%} vs {r.bid_margin_pct:.1%} bid ({-r.margin_fade_pts:+.1f} pts, {money(r.margin_fade_dollars)} of profit)")
        if r.pending_pct_of_contract >= RULES["pending_co_pct"] or nz(r.oldest_pending_age_days) > RULES["pending_co_age"]:
            add("Change orders", f"{int(r.pending_co_count)} unapproved, {money(r.pending_co_revenue)} ({r.pending_pct_of_contract:.0%} of contract), oldest {int(nz(r.oldest_pending_age_days))} days")
        if abs(r.over_under_pct_of_contract) >= RULES["billing_pct"]:
            add("Billing", f"{'over' if r.over_under_billing > 0 else 'under'}-billed by {money(abs(r.over_under_billing))}")
        if r.safety_cluster:
            add("Safety", f"{int(r.peak_incidents_in_window)} incidents inside 90 days (from {r.peak_window_start:%b %d, %Y})")
        if r.ar_overdue >= RULES["ar_overdue"]:
            add("Receivables", f"{money(r.ar_overdue)} past due from the owner" + (f" ({money(r.ar_over_90)} over 90 days)" if r.ar_over_90 > 0 else ""))
        if nz(r.final_slip_days) > RULES["schedule_slip"]:
            add("Schedule", f"final milestone forecast {int(r.final_slip_days)} days late")
        if r.rfis_overdue >= RULES["rfis_overdue"]:
            add("RFIs", f"{int(r.rfis_overdue)} RFIs past their response date")
        if r.po_overdue_lines >= RULES["po_overdue_lines"]:
            add("Procurement", f"{int(r.po_overdue_lines)} overdue purchase-order lines ({money(r.po_overdue_amount)})")

    CHRONIC = set(q("""select vendor_name from metrics.v_vendor_scorecard where delivered_lines >= 10 and on_time_rate < 0.5""").vendor_name)
    vp = q("""select project_id, vendor_name, count(*) n, avg(days_late_delivered) late from metrics.v_po_line_status
              where status = 'Received' group by 1, 2 having count(*) >= 4 and avg(days_late_delivered) >= 15""")
    for r in vp.itertuples():
        if r.project_id in flags and r.vendor_name not in CHRONIC:
            flags[r.project_id].append(("Procurement", f"{r.vendor_name} deliveries average {r.late:.0f} days late across {int(r.n)} lines"))

    ranked = sorted(((pid, f) for pid, f in flags.items() if f), key=lambda x: (-max(SEVERITY[a] for a, _ in x[1]), -sum(SEVERITY[a] for a, _ in x[1]), x[0]))
    names = p.set_index("project_id")

    vend = q("""select vendor_name, count(*) filter (where status='Received') n,
                       count(*) filter (where status='Received' and days_late_delivered <= 0) * 1.0 / nullif(count(*) filter (where status='Received'),0) rate,
                       count(*) filter (where is_overdue_open) overdue
                from metrics.v_po_line_status group by 1 having count(*) filter (where status='Received') >= 10 order by rate""")
    bad_v = vend[vend.rate < RULES["vendor_on_time"]]
    inv = q("select item_name, on_hand_qty, reorder_point, days_of_cover, lead_time_days, uom from metrics.v_inventory_status where reorder_status = 'Below reorder point'")
    disp = q("""select p.project_id, v.vendor_name, count(*) n, sum(s.gross_billed) g from mart.fact_sub_pay_app s
                join mart.dim_project p using (project_key) join mart.dim_vendor v using (vendor_key) where s.status = 'Disputed' group by 1, 2""")
    dq = q("select status, count(*) n from ops.dq_results where run_id = (select run_id from ops.dq_results order by run_ts desc limit 1) group by 1").set_index("status").n.to_dict()

    L = []
    L.append("# Weekly flagged jobs\n")
    L.append("> **Synthetic data.** Gulf Coast Builders is a fictional company; nothing below describes a real business.\n")
    L.append(f"**Data as of {k.as_of_date:%A, %B %d, %Y}** | report generated {date.today():%Y-%m-%d} | "
             f"data-quality checks: {dq.get('PASS', 0)} passed, {dq.get('FAIL', 0)} failed, {dq.get('WARN', 0)} warnings\n")
    L.append("## Summary\n")
    L.append(f"{len(ranked)} of {len(p)} active jobs are flagged. Portfolio projected margin is **{k.portfolio_projected_margin:.1%}** against a **{k.portfolio_bid_margin:.1%}** bid margin; "
             f"the three largest margin losses account for **{k.top3_share_of_fade:.0%}** of all fade dollars. "
             f"Backlog is **{money(k.total_backlog)}** with **{money(k.weighted_pipeline)}** weighted pipeline behind it. "
             f"Owners owe **{money(k.ar_overdue)}** past due ({money(k.ar_over_90)} over 90 days) and **{k.overdue_po_lines}** purchase-order lines are overdue.\n")
    L.append("## Flagged jobs, most urgent first\n")
    L.append("| Job | Unit | Manager | Flags |\n|---|---|---|---|")
    for pid, f in ranked:
        r = names.loc[pid]
        L.append(f"| **{pid}** {r.project_name} | {r.business_unit} | {r.project_manager} | {', '.join(sorted({a for a, _ in f}))} |")
    L.append("")
    for pid, f in ranked:
        L.append(f"### {pid} {names.loc[pid].project_name}\n")
        for area, text in sorted(f, key=lambda x: -SEVERITY[x[0]]):
            L.append(f"- **{area}:** {text}")
        L.append("")
    L.append("## Portfolio watch items\n")
    for r in bad_v.itertuples():
        L.append(f"- **Supplier:** {r.vendor_name} delivered on time on {r.rate:.0%} of {int(r.n)} lines; {int(r.overdue)} open lines are overdue.")
    if len(inv):
        L.append("- **Plant inventory below reorder point:** " + "; ".join(f"{r.item_name} ({r.on_hand_qty:,.0f} {r.uom} on hand vs {r.reorder_point:,.0f}; {r.days_of_cover:.0f} days of cover vs {int(r.lead_time_days)}-day lead time)" for r in inv.itertuples()))
    for r in disp.itertuples():
        L.append(f"- **Disputed subcontractor pay:** {r.vendor_name} on {r.project_id}, {int(r.n)} applications, {money(r.g)} gross.")
    L.append(f"- **Three-way match:** {int(k.received_not_invoiced_count)} deliveries older than 30 days with no invoice ({money(k.received_not_invoiced_amount)}), "
             f"{int(k.invoiced_not_received_count)} invoices with nothing received, {int(k.price_exception_count)} invoices more than 5% above value received.")
    L.append("")
    L.append("## How a job gets flagged\n")
    L.append("| Rule | Threshold |\n|---|---|")
    for key, label in [("fade_pts", "Margin fade versus bid (points)"), ("pending_co_pct", "Unapproved change orders, share of contract"), ("pending_co_age", "...or oldest pending change order (days)"),
                       ("billing_pct", "Over- or under-billing, share of contract"), ("ar_overdue", "Owner receivables past due ($)"), ("rfis_overdue", "RFIs past response date (count)"),
                       ("schedule_slip", "Final milestone forecast slip (days)"), ("po_overdue_lines", "Overdue open purchase-order lines (count)"), ("vendor_on_time", "Supplier on-time delivery below")]:
        v = RULES[key]
        L.append(f"| {label} | {v:,.0%} |" if isinstance(v, float) and v < 1 else f"| {label} | {v:,} |")
    L.append("\nEvery number comes from a view in the `metrics` schema (`sql/05_metrics.sql`). Definitions: `docs/metric_definitions.md`.")
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}  ({len(ranked)} jobs flagged)")


if __name__ == "__main__":
    main()
