#!/usr/bin/env python3
"""
ERP expansion for the synthetic "Gulf Coast Builders" dataset (called by generate_data.py).

*** ALL DATA IS SYNTHETIC. Gulf Coast Builders is a fictional company. ***

Adds the operational ERP areas a construction back office tracks beyond the GL:

  procurement   vendors, purchase_orders (line grain), po_receipts, ap_invoices
  subcontracts  subcontract_pay_apps (committed / billed / paid / retainage)
  field         equipment, equipment_usage, rfis, submittals, schedule_milestones
  inventory     inventory_items (manufacturing stock snapshot)
  cash          billings gain due_date / paid_date (AR aging)

It uses its OWN random stream, so the core tables (costs, change orders, billings
amounts, safety, CRM) and the headline answer key are unchanged by this module.
It also regenerates commitments so each commitment covers its vendor's actual
spend plus the forecast remainder (a subcontract cannot be billed beyond what it
was committed for).

Planted stories (all recorded in docs/planted_findings.md):
  * Pelican Metal Works delivers steel late on most of its lines (chronic late vendor)
  * P-102 structural steel arrives 5-8 weeks late -> structure milestone slips -> shop-drawing resubmittals
  * P-110 steel / fabrication invoices come in 6-14% above PO price (price shock) -> invoices on hold
  * 7 receipts older than 50 days never invoiced; 4 invoices paid for goods not yet received
  * P-103 MEP subcontractor pay applications disputed and unpaid 90+ days
  * Slow-paying owners on P-104 and P-109; P-108 has disputed unpaid pay applications
  * P-104 / P-109 owner RFIs answered slowly and overdue
  * Manufacturing: rebar, embed plates and wire mesh below reorder point
  * P-105 crane sits idle through weather months
"""
from datetime import date, timedelta

import numpy as np
import pandas as pd

VENDOR_INFO = {  # name: (type, trade, payment terms days)
    "Delta Earthworks Inc.": ("Subcontractor", "Earthwork", 30),
    "Cypress Excavating LLC": ("Subcontractor", "Earthwork", 30),
    "Bayou Concrete Co.": ("Subcontractor", "Concrete", 45),
    "Gulf Ready-Mix LLC": ("Subcontractor", "Concrete", 30),
    "Crescent Steel Supply": ("Supplier", "Steel", 30),
    "Pelican Metal Works": ("Supplier", "Steel", 30),
    "Magnolia Mechanical Inc.": ("Subcontractor", "Mechanical", 45),
    "Southern Electric Contractors": ("Subcontractor", "Electrical", 45),
    "Riverside Plumbing Co.": ("Subcontractor", "Plumbing", 45),
    "Heritage Interiors LLC": ("Subcontractor", "Finishes", 30),
    "Coastal Drywall & Paint": ("Subcontractor", "Finishes", 30),
    "Gulf Equipment Rental": ("Supplier", "Equipment", 30),
    "Gulf Aggregates Inc.": ("Supplier", "Aggregates", 30),
    "Cypress Lumber & Supply": ("Supplier", "Lumber", 30),
    "Delta Paving & Utilities": ("Subcontractor", "Paving", 45),
    "Bayou Surety & Insurance": ("Other", "Insurance", 30),
}

# code -> (description, uom, unit price, typical lead days)
ITEMS = {
    "04-400": [("Structural steel W-shapes", "ton", 1850, 95), ("Reinforcing steel #5 rebar", "ton", 1050, 28),
               ("Metal deck 20ga", "sq ft", 4.2, 35), ("Anchor bolts and embeds", "ea", 38, 30),
               ("Steel joists", "ton", 1700, 80), ("Miscellaneous metals", "lot", 4200, 25)],
    "10-100": [("Crushed aggregate base", "ton", 28, 7), ("Lumber and sheathing", "mbf", 640, 14),
               ("Conduit and fittings", "ft", 6.5, 21), ("Geotextile fabric", "sq yd", 2.4, 18),
               ("Drainage pipe", "ft", 31, 28), ("Sand and select fill", "ton", 19, 5)],
    "08-800": [("Excavator rental", "wk", 3200, 4), ("Crane rental", "wk", 11200, 10), ("Light tower rental", "wk", 420, 3),
               ("Fuel delivery", "gal", 4.1, 3), ("Compaction equipment rental", "wk", 1650, 5)],
    "13-100": [("Portland cement", "ton", 168, 12), ("Rebar cage assemblies", "ea", 640, 35), ("Embed plates", "ea", 85, 40),
               ("Lifting inserts", "ea", 21, 30), ("Mold steel plate", "ton", 1500, 45), ("Insulation board", "sheet", 36, 18)],
}

EQUIPMENT = [  # name, category, ownership, daily rate, BU group
    ("Excavator 320", "Earthmoving", "Owned", 950, "HC"), ("Excavator 336", "Earthmoving", "Rented", 1450, "HC"),
    ("Crawler Crane 90T", "Lifting", "Rented", 3200, "ANY"), ("Wheel Loader", "Earthmoving", "Owned", 620, "HC"),
    ("Dozer D6", "Earthmoving", "Owned", 880, "HC"), ("Asphalt Paver", "Paving", "Owned", 1800, "HC"),
    ("Vibratory Roller", "Paving", "Owned", 540, "HC"), ("Telehandler", "Lifting", "Owned", 260, "ANY"),
    ("Scissor Lift A", "Access", "Rented", 180, "BLD"), ("Scissor Lift B", "Access", "Rented", 180, "BLD"),
    ("Generator 100kW", "Power", "Owned", 120, "ANY"), ("Dump Truck 1", "Haul", "Owned", 520, "HC"),
    ("Dump Truck 2", "Haul", "Owned", 520, "HC"), ("Tower Crane", "Lifting", "Rented", 5500, "BLD"),
    ("Pile Driver", "Foundation", "Rented", 2900, "HC"), ("Concrete Pump", "Concrete", "Rented", 1200, "BLD"),
    ("Skid Steer", "Earthmoving", "Owned", 340, "ANY"), ("Overhead Bridge Crane", "Lifting", "Owned", 310, "MFG"),
]

INVENTORY = [  # item, uom, unit cost, avg daily use, lead days, reorder point (units), vendor, stock factor (x reorder point)
    ("Portland cement", "ton", 168, 6.0, 12, None, "Gulf Aggregates Inc.", 2.6),
    ("Aggregate 3/4 in", "ton", 28, 14.0, 7, None, "Gulf Aggregates Inc.", 3.1),
    ("Sand", "ton", 19, 10.0, 6, None, "Gulf Aggregates Inc.", 2.4),
    ("Rebar #4 / #5", "ton", 1050, 1.1, 28, None, "Pelican Metal Works", 0.55),
    ("Welded wire mesh", "sheet", 46, 18.0, 30, None, "Crescent Steel Supply", 0.40),
    ("Embed plates", "ea", 85, 14.0, 40, None, "Pelican Metal Works", 0.62),
    ("Lifting inserts", "ea", 21, 22.0, 30, None, "Crescent Steel Supply", 1.9),
    ("Form release agent", "gal", 14, 3.5, 10, None, "Cypress Lumber & Supply", 3.0),
    ("Insulation board", "sheet", 36, 5.0, 18, None, "Cypress Lumber & Supply", 2.2),
    ("Plywood form liner", "sheet", 58, 2.5, 14, None, "Cypress Lumber & Supply", 2.8),
    ("Prestress strand", "ft", 2.1, 260.0, 35, None, "Crescent Steel Supply", 1.45),
    ("Coil rod", "ft", 3.4, 120.0, 25, None, "Pelican Metal Works", 1.7),
    ("Concrete admixture", "gal", 9.5, 7.0, 9, None, "Gulf Aggregates Inc.", 2.9),
    ("Mold steel plate", "ton", 1500, 0.15, 45, None, "Crescent Steel Supply", 3.5),
]

RFI_SUBJECTS = {
    "Structural": ["Clarify beam connection detail", "Slab edge at column line conflicts with drawings", "Rebar congestion at transfer girder",
                   "Anchor bolt layout discrepancy", "Footing depth at unsuitable soil"],
    "MEP": ["Duct routing conflicts with beam", "Panel location versus architectural plan", "Sleeve penetrations through rated wall",
            "Lighting fixture substitution request", "Sprinkler head coordination at ceiling"],
    "Civil": ["Utility conflict at station", "Drainage structure invert elevation", "Base course thickness at ramp",
              "Guardrail terminal detail", "Environmental permit condition clarification"],
    "Architectural": ["Door hardware set mismatch", "Wall type at corridor not shown", "Finish schedule versus elevations",
                      "Storefront system substitution", "Waterproofing detail at parapet"],
}

SUBMITTAL_SPECS = {
    "Building": [("03 30 00", "Cast-in-place concrete mix design"), ("05 12 00", "Structural steel shop drawings"),
                 ("07 54 00", "Roofing membrane product data"), ("08 11 00", "Hollow metal doors and frames"),
                 ("09 29 00", "Gypsum board and finishes"), ("23 05 00", "HVAC equipment data"),
                 ("26 24 00", "Switchboards and panelboards"), ("21 13 00", "Fire sprinkler shop drawings")],
    "Heavy Civil": [("03 30 00", "Concrete mix design"), ("31 23 00", "Excavation and fill materials"), ("32 12 00", "Asphalt mix design"),
                    ("33 41 00", "Storm drainage pipe and structures"), ("34 71 00", "Guardrail and barrier system"),
                    ("05 12 00", "Bridge girder shop drawings")],
    "Manufacturing": [("03 41 00", "Precast panel shop drawings"), ("03 21 00", "Reinforcement certificates"),
                      ("03 15 00", "Embed and insert product data"), ("07 21 00", "Insulation product data")],
}


def generate_extension(T, rng):
    """Add ERP expansion tables to T (clean) and return an extra answer-key dict."""
    from generate_data import AS_OF, CODE_INFO, PROJECTS, WEATHER_MONTHS, month_end, month_idx, month_start, r2

    projects = T["projects"].set_index("project_id")
    pm = {p[0]: p for p in PROJECTS}
    costs = T["actual_costs_clean"]
    bud = T["budget_lines"]
    cos = T["change_orders_clean"]
    key = {}

    # ------------------------------------------------------------------ vendors
    vendors = pd.DataFrame([dict(vendor_id=f"V{i + 1:03d}", vendor_name=n, vendor_type=v[0], trade=v[1], payment_terms_days=v[2])
                            for i, (n, v) in enumerate(VENDOR_INFO.items())])
    T["vendors"] = vendors
    terms = {n: v[2] for n, v in VENDOR_INFO.items()}

    # ------------------------------------------------------------------ commitments: regenerate to cover actual + forecast
    cm = T["commitments_clean"].copy()
    A = costs.groupby(["project_id", "cost_code", "vendor_name"]).amount.sum()
    line_actual = costs.groupby(["project_id", "cost_code"]).amount.sum()
    etc = bud.set_index(["project_id", "cost_code"]).estimate_to_complete
    origb = bud.set_index(["project_id", "cost_code"]).original_budget
    n_line = cm.groupby(["project_id", "cost_code"]).size()
    for i, row in cm.iterrows():
        k = (row.project_id, row.cost_code)
        a_v = float(A.get((row.project_id, row.cost_code, row.vendor_name), 0.0))
        total = (a_v + float(etc[k]) / int(n_line[k])) * float(rng.uniform(1.00, 1.04))
        ratio = (float(line_actual.get(k, 0.0)) + float(etc[k])) / float(origb[k])
        co_ratio = float(np.clip(ratio - 1, 0, 0.5)) * 0.8 + float(rng.uniform(0.0, 0.03))
        approved = total * co_ratio
        cm.at[i, "approved_changes"] = r2(approved)
        cm.at[i, "original_amount"] = r2(total - approved)
    cm["committed_total"] = (cm.original_amount + cm.approved_changes).round(2)
    T["commitments_clean"] = cm.drop(columns=["committed_total"])
    cm_idx = cm.set_index("commitment_id")

    # ------------------------------------------------------------------ purchase orders + receipts + AP invoices
    po_rows, rc_rows, inv_rows = [], [], []
    po_n = 0
    rc_n = 0
    inv_n = 0
    po_cm = cm[cm.commitment_type == "Purchase Order"]
    for _, c in po_cm.iterrows():
        pid, code, vendor = c.project_id, c.cost_code, c.vendor_name
        meta = pm[pid]
        start = month_start(month_idx(*meta[5]))
        end = month_end(month_idx(*meta[6]))
        completed = meta[9] == "Completed"
        total = float(c.committed_total)
        n_lines = int(rng.integers(7, 15))
        wts = rng.lognormal(0, 0.5, size=n_lines)
        amts = wts / wts.sum() * total
        cat = ITEMS[code]
        po_number = f"PO-{pid[2:]}-{(po_n % 90) + 10:02d}{code[:2]}"
        window_lo = start + timedelta(days=10)
        window_hi = end - timedelta(days=45)
        span = max((window_hi - window_lo).days, 30)
        odays = np.sort(rng.integers(0, span, size=n_lines))
        for j in range(n_lines):
            desc, uom, price, lead_mid = cat[int(rng.integers(0, len(cat)))]
            order = window_lo + timedelta(days=int(odays[j]))
            if not completed and rng.random() < 0.35:
                order = AS_OF - timedelta(days=int(rng.integers(0, 120)))      # current buying window
            if order > AS_OF:
                continue                                  # not yet released: uncalled balance of the commitment
            unit_price = round(price * float(rng.uniform(0.95, 1.08)), 2)
            qty = max(1, int(round(amts[j] / unit_price)))
            lead = int(lead_mid * float(rng.uniform(0.8, 1.25)))
            # delivery delay model
            if vendor == "Pelican Metal Works" and rng.random() < 0.7:
                delay = int(rng.integers(10, 41))
            else:
                delay = int(np.clip(round(rng.normal(-3, 2.5)), -8, 12))
            if pid == "P-102" and code == "04-400" and vendor == "Crescent Steel Supply" and date(2025, 8, 1) <= order <= date(2026, 7, 31):
                delay = int(rng.integers(35, 56))
                if "ton" == uom and desc != "Structural steel W-shapes" and rng.random() < 0.5:
                    desc, uom, unit_price, lead = "Structural steel W-shapes", "ton", 1890.0, 95
            promised = order + timedelta(days=lead)
            transit = 1 if code == "08-800" else int(rng.integers(2, 6))
            ship = max(order, promised + timedelta(days=delay - transit))
            recv_final = ship + timedelta(days=transit)
            po_n += 1
            line_id = f"POL{po_n:05d}"
            amount = round(qty * unit_price, 2)
            status, ship_s, recv_s, receipts = "Ordered", None, None, []
            if ship <= AS_OF:
                ship_s = ship
                status = "Shipped"
                if recv_final <= AS_OF:
                    if rng.random() < 0.08 and qty >= 4:
                        q1 = int(qty * 0.6)
                        r2d = recv_final + timedelta(days=int(rng.integers(7, 26)))
                        receipts.append((recv_final, q1))
                        if r2d <= AS_OF:
                            receipts.append((r2d, qty - q1))
                            status, recv_s = "Received", r2d
                        else:
                            status = "Partially Received"
                    else:
                        receipts.append((recv_final, qty))
                        status, recv_s = "Received", recv_final
            elif rng.random() < 0.02:
                status = "Cancelled"
            po_rows.append(dict(po_line_id=line_id, po_number=po_number, commitment_id=c.commitment_id, project_id=pid, cost_code=code,
                                vendor_name=vendor, item_description=desc, quantity=qty, uom=uom, unit_price=unit_price,
                                ordered_amount=amount, order_date=order, promised_date=promised, ship_date=ship_s,
                                received_date=recv_s, status=status, is_long_lead="Y" if lead >= 60 else "N"))
            for rd_, rq in receipts:
                rc_n += 1
                cond = "OK" if rng.random() < 0.95 else str(rng.choice(["Damaged", "Short"]))
                rc_rows.append(dict(receipt_id=f"RC{rc_n:05d}", po_line_id=line_id, receipt_date=rd_, received_qty=rq,
                                    received_amount=r2(rq * unit_price), condition=cond))
    pos = pd.DataFrame(po_rows)
    rcs = pd.DataFrame(rc_rows)

    # AP invoices from receipts (with planted price variance, holds, exceptions)
    pol = pos.set_index("po_line_id")
    shock_lines = pol[(pol.project_id == "P-110") & pol.cost_code.isin(["04-400", "13-100"])].index
    skip_inv = set()
    old_rcs = rcs[(pd.to_datetime(rcs.receipt_date) <= pd.Timestamp(AS_OF - timedelta(days=50)))]
    old_rcs = old_rcs[~old_rcs.po_line_id.isin(shock_lines)]
    for rid in old_rcs.sample(7, random_state=5).receipt_id:
        skip_inv.add(rid)
    held = 0
    for _, r in rcs.iterrows():
        if r.receipt_id in skip_inv:
            continue
        pl = pol.loc[r.po_line_id]
        inv_date = r.receipt_date + timedelta(days=int(rng.integers(2, 13)))
        if inv_date > AS_OF:
            continue
        shock = r.po_line_id in shock_lines
        pv = float(rng.uniform(0.06, 0.14)) if shock else float(rng.normal(0.004, 0.01))
        amount = r2(r.received_amount * (1 + pv))
        due = inv_date + timedelta(days=terms[pl.vendor_name])
        status, paid = "Open", None
        if shock and pv > 0.08 and held < 6:
            status, held = "On Hold", held + 1
        else:
            pd_ = due + timedelta(days=int(np.clip(round(rng.normal(1, 5)), -5, 15)))
            if pd_ <= AS_OF:
                status, paid = "Paid", pd_
        inv_n += 1
        inv_rows.append(dict(invoice_id=f"AP{inv_n:05d}", invoice_no=f"{pl.vendor_name[:3].upper()}-{4000 + inv_n}", po_line_id=r.po_line_id,
                             project_id=pl.project_id, cost_code=pl.cost_code, vendor_name=pl.vendor_name, invoice_date=inv_date,
                             due_date=due, amount=amount, paid_date=paid, status=status))
    # planted: 4 invoices for goods NOT yet received (vendor pre-billing, paid anyway)
    pre = pos[(pos.status.isin(["Ordered", "Shipped"])) & (pd.to_datetime(pos.order_date) <= pd.Timestamp(AS_OF - timedelta(days=45)))]
    pre_ids = []
    for _, pl in pre.sample(min(4, len(pre)), random_state=9).iterrows():
        inv_n += 1
        d = pl.order_date + timedelta(days=int(rng.integers(14, 30)))
        due = d + timedelta(days=terms[pl.vendor_name])
        paid = due if due <= AS_OF else None
        inv_rows.append(dict(invoice_id=f"AP{inv_n:05d}", invoice_no=f"{pl.vendor_name[:3].upper()}-{4000 + inv_n}", po_line_id=pl.po_line_id,
                             project_id=pl.project_id, cost_code=pl.cost_code, vendor_name=pl.vendor_name, invoice_date=d, due_date=due,
                             amount=r2(pl.ordered_amount * 0.5), paid_date=paid, status="Paid" if paid else "Open"))
        pre_ids.append(pl.po_line_id)
    invs = pd.DataFrame(inv_rows)
    T["purchase_orders_clean"], T["po_receipts_clean"], T["ap_invoices_clean"] = pos, rcs, invs

    # ------------------------------------------------------------------ subcontract pay applications (from cost postings)
    sub_cm = cm[cm.commitment_type == "Subcontract"].set_index(["project_id", "cost_code", "vendor_name"]).commitment_id
    sp_rows = []
    sp_n = 0
    magnolia_p103 = []
    post = costs[(costs.vendor_name.notna()) & (costs.amount > 0)]
    for _, r in post.iterrows():
        k = (r.project_id, r.cost_code, r.vendor_name)
        if k not in sub_cm.index:
            continue
        sp_n += 1
        per = r.period
        inv_date = per + timedelta(days=int(rng.integers(3, 11)))
        due = inv_date + timedelta(days=terms[r.vendor_name])
        gross = float(r.amount)
        ret = round(gross * 0.10, 2)
        status, paid, paid_amt = "Approved", None, 0.0
        pd_ = due + timedelta(days=int(np.clip(round(rng.normal(2, 7)), -4, 20)))
        if inv_date > AS_OF:
            status = "Pending Approval"
        elif pd_ <= AS_OF:
            status, paid, paid_amt = "Paid", pd_, round(gross - ret, 2)
        row = dict(sub_pay_app_id=f"SP{sp_n:05d}", commitment_id=sub_cm[k], project_id=r.project_id, cost_code=r.cost_code,
                   vendor_name=r.vendor_name, period_end=per, gross_billed=r2(gross), retainage_held=ret, invoice_date=inv_date,
                   due_date=due, paid_amount=paid_amt, paid_date=paid, status=status, retainage_released=0.0, retainage_release_date=None)
        sp_rows.append(row)
    sp = pd.DataFrame(sp_rows)
    # planted: P-103 Magnolia Mechanical applications disputed and unpaid (90+ days old)
    mask = (sp.project_id == "P-103") & (sp.vendor_name == "Magnolia Mechanical Inc.") & \
           (pd.to_datetime(sp.period_end).between(pd.Timestamp("2025-12-01"), pd.Timestamp("2026-07-31")))
    sp.loc[mask, ["status", "paid_amount", "paid_date"]] = ["Disputed", 0.0, None]
    # retainage released on completed jobs
    for pid in ["P-111", "P-112"]:
        end = month_end(month_idx(*pm[pid][6]))
        rel = end + timedelta(days=60)
        m = sp.project_id == pid
        if rel <= AS_OF:
            sp.loc[m, "retainage_released"] = sp.loc[m, "retainage_held"]
            sp.loc[m, "retainage_release_date"] = rel
    T["subcontract_pay_apps_clean"] = sp
    key["disputed_sub_pay_apps"] = dict(project="P-103", vendor="Magnolia Mechanical Inc.", count=int(mask.sum()),
                                        gross=r2(sp.loc[mask, "gross_billed"].sum()))

    # ------------------------------------------------------------------ AR: billings due / paid dates
    b = T["billings_clean"].copy()
    slow = {"P-104": (55, 95), "P-109": (50, 90)}
    due_l, paid_l, stat_l = [], [], []
    for _, r in b.iterrows():
        sub = r.submitted_date
        due = sub + timedelta(days=30)
        lo, hi = slow.get(r.project_id, (None, None))
        days = int(rng.integers(lo, hi)) if lo else int(np.clip(round(rng.normal(33, 8)), 15, 60))
        paid = sub + timedelta(days=days)
        status = "Paid"
        if r.project_id == "P-108" and date(2026, 3, 1) <= r.period_end <= date(2026, 6, 30):
            paid, status = None, "Disputed"
        elif paid > AS_OF:
            paid = None
            status = "Submitted" if sub <= AS_OF else "Draft"
        due_l.append(due)
        paid_l.append(paid)
        stat_l.append(status)
    b["due_date"], b["paid_date"], b["status"] = due_l, paid_l, stat_l
    T["billings_clean"] = b

    # ------------------------------------------------------------------ equipment + usage
    eq = pd.DataFrame([dict(equipment_id=f"EQ{i + 1:02d}", equipment_name=e[0], category=e[1], ownership=e[2],
                            daily_rate=e[3], vendor_name="Gulf Equipment Rental" if e[2] == "Rented" else None, group=e[4])
                       for i, e in enumerate(EQUIPMENT)])
    eq_cost = costs[costs.cost_code == "08-800"].groupby(["project_id", "period"]).amount.sum()
    use_rows = []
    u_n = 0
    for (pid, per), a in eq_cost.items():
        if a <= 0:
            continue
        bu = pm[pid][2]
        grp = {"Building": "BLD", "Heavy Civil": "HC", "Manufacturing": "MFG"}[bu]
        pool = eq[eq.group.isin([grp, "ANY"])] if grp != "MFG" else eq[eq.group.isin(["MFG", "ANY"])]
        pool = pool.reset_index(drop=True)
        if pid == "P-101":
            fixed = ["EQ14"]
        elif pid == "P-105":
            fixed = ["EQ15", "EQ03"]
        else:
            fixed = []
        sel = list(fixed)
        extra_n = int(rng.integers(1, 3))
        for e in rng.choice(pool.equipment_id.tolist(), size=min(extra_n, len(pool)), replace=False):
            if e not in sel:
                sel.append(str(e))
        m_idx = month_idx(per.year, per.month)
        weather = m_idx in WEATHER_MONTHS.get(pid, [])
        rows = []
        for e in sel:
            rate = float(eq.loc[eq.equipment_id == e, "daily_rate"].iloc[0])
            days = int(rng.integers(6, 15) if weather else rng.integers(12, 23))
            standby = int(rng.integers(0, 4))
            if pid == "P-105" and e == "EQ03" and weather:
                days, standby = int(rng.integers(2, 6)), int(rng.integers(12, 18))      # planted: crane idle through weather
            rows.append([e, rate, days, standby])
        tot_w = sum(r_[1] * (r_[2] + r_[3] * 0.6) for r_ in rows)
        for e, rate, days, standby in rows:
            u_n += 1
            cost = round(a * 0.85 * (rate * (days + standby * 0.6)) / tot_w, 2)
            use_rows.append(dict(usage_id=f"EU{u_n:05d}", equipment_id=e, project_id=pid, month_end=per, days_used=days,
                                 standby_days=standby, usage_cost=cost))
    T["equipment_clean"] = eq.drop(columns=["group"])
    T["equipment_usage_clean"] = pd.DataFrame(use_rows)

    # ------------------------------------------------------------------ inventory snapshot (manufacturing)
    inv_items = []
    for i, (name, uom, ucost, use, lead, _rp, vend, factor) in enumerate(INVENTORY):
        rp = round(use * (lead + 7), 1)                         # reorder point = demand over lead time + 7-day safety
        onhand = round(rp * factor, 1)
        inv_items.append(dict(item_id=f"INV{i + 1:02d}", item_name=name, uom=uom, on_hand_qty=onhand, reorder_point=rp,
                              reorder_qty=round(rp * 1.5, 1), unit_cost=ucost, avg_daily_usage=use, lead_time_days=lead,
                              preferred_vendor_name=vend,
                              last_receipt_date=AS_OF - timedelta(days=int(rng.integers(3, 40))), as_of_date=AS_OF))
    T["inventory_items_clean"] = pd.DataFrame(inv_items)

    # ------------------------------------------------------------------ RFIs and submittals
    rfi_rows, sub_rows = [], []
    rn = sn = 0
    for pid, meta in pm.items():
        bu = meta[2]
        s0 = month_start(month_idx(*meta[5]))
        active_end = min(month_end(month_idx(*meta[6])), AS_OF)
        span = (active_end - s0).days
        contract = meta[7]
        n_rfi = int(np.clip(contract / 1.6e6 + rng.integers(-3, 4), 3, 40))
        slow_owner = pid in ("P-104", "P-109")
        for j in range(n_rfi):
            rn += 1
            disc = str(rng.choice(["Civil", "Structural", "MEP"] if bu == "Heavy Civil" else
                                  (["Structural", "Architectural"] if bu == "Manufacturing" else ["Structural", "MEP", "Architectural"])))
            subm = s0 + timedelta(days=int(rng.integers(5, max(10, span - 5))))
            due = subm + timedelta(days=14)
            resp_days = int(rng.integers(35, 80)) if slow_owner and rng.random() < 0.8 else int(np.clip(round(rng.normal(9, 5)), 2, 30))
            resp = subm + timedelta(days=resp_days)
            if rng.random() < (0.5 if slow_owner else 0.04) and subm >= AS_OF - timedelta(days=200):
                resp = None
            if resp is not None and resp > AS_OF:
                resp = None
            sched = int(rng.integers(3, 21)) if rng.random() < 0.15 else 0
            rfi_rows.append(dict(rfi_id=f"RFI{rn:05d}", project_id=pid, rfi_number=j + 1,
                                 subject=str(rng.choice(RFI_SUBJECTS[disc])), discipline=disc, submitted_date=subm, due_date=due,
                                 response_date=resp, status="Closed" if resp else "Open",
                                 cost_impact_flag="Y" if rng.random() < 0.18 else "N", schedule_impact_days=sched,
                                 ball_in_court="Owner" if slow_owner and rng.random() < 0.6 else str(rng.choice(["Architect", "Engineer", "Owner"]))))
        n_sub = int(np.clip(contract / 1.1e6 + rng.integers(-2, 5), 4, 55))
        specs = SUBMITTAL_SPECS[bu]
        for j in range(n_sub):
            sn += 1
            spec, desc = specs[int(rng.integers(0, len(specs)))]
            req = s0 + timedelta(days=int(rng.integers(20, max(40, span))))
            subm = req - timedelta(days=int(rng.integers(20, 60)))
            subm = max(subm, s0)
            cycles = 1 if rng.random() < 0.7 else int(rng.integers(2, 4))
            ret = subm + timedelta(days=int(rng.integers(10, 28)) * cycles)
            status = str(rng.choice(["Approved", "Approved as Noted"], p=[0.6, 0.4])) if cycles == 1 else "Approved"
            if ret > AS_OF:
                ret, status = None, "Pending"
            if pid == "P-102" and spec == "05 12 00":
                cycles, ret = 3, subm + timedelta(days=int(rng.integers(70, 95)))
                status = "Approved" if ret <= AS_OF else "Pending"
                if ret > AS_OF:
                    ret = None
            if pid == "P-109" and rng.random() < 0.3 and subm >= AS_OF - timedelta(days=120):
                ret, status = None, "Pending"
            sub_rows.append(dict(submittal_id=f"SB{sn:05d}", project_id=pid, spec_section=spec, description=desc, required_by_date=req,
                                 submitted_date=subm, returned_date=ret, status=status, cycle_count=cycles))
    T["rfis_clean"] = pd.DataFrame(rfi_rows)
    T["submittals_clean"] = pd.DataFrame(sub_rows)

    # ------------------------------------------------------------------ schedule milestones
    names = {"Building": ["Mobilization", "Foundations Complete", "Structure Complete", "Dried-In", "MEP Rough-In Complete", "Substantial Completion"],
             "Heavy Civil": ["Mobilization", "Clearing and Earthwork Complete", "Subgrade / Foundations Complete", "Base Course / Structure Complete",
                             "Utilities and Drainage Complete", "Substantial Completion"],
             "Manufacturing": ["Mold Setup", "First Article Approved", "25% Panels Cast", "50% Panels Cast", "All Panels Cast", "Final Delivery"]}
    fracs = [0.02, 0.20, 0.45, 0.65, 0.85, 1.0]
    slip_by_proj = {"P-102": 42, "P-105": 38, "P-107": 62, "P-106": 24, "P-108": 28, "P-109": 33, "P-103": 18, "P-104": 14, "P-101": 6, "P-110": 20}
    ms_rows = []
    mn = 0
    for pid, meta in pm.items():
        s0 = month_start(month_idx(*meta[5]))
        e0 = month_end(month_idx(*meta[6]))
        total_slip = slip_by_proj.get(pid, 0) + int(rng.integers(-3, 6))
        completed = meta[9] == "Completed"
        for i, (nm, f) in enumerate(zip(names[meta[2]], fracs)):
            planned = s0 + timedelta(days=int((e0 - s0).days * f))
            slip = int(total_slip * (0.25 + 0.75 * f) + rng.integers(-2, 3)) if not completed else int(rng.integers(-3, 9))
            forecast = planned + timedelta(days=max(slip, -3))
            actual = None
            if completed or forecast <= AS_OF:
                actual = forecast
                forecast = forecast
            mn += 1
            delay = (forecast - planned).days
            status = "Complete" if actual else ("On Track" if delay <= 7 else ("At Risk" if delay <= 30 else "Late"))
            ms_rows.append(dict(milestone_id=f"MS{mn:04d}", project_id=pid, milestone_name=nm, planned_date=planned,
                                forecast_date=forecast, actual_date=actual, status=status))
    T["schedule_milestones_clean"] = pd.DataFrame(ms_rows)

    # ------------------------------------------------------------------ answer-key additions (from CLEAN data)
    pos2 = pos.copy()
    for c_ in ["order_date", "promised_date", "ship_date", "received_date"]:
        pos2[c_] = pd.to_datetime(pos2[c_])
    full = pos2[pos2.status == "Received"]
    full = full.assign(days_late=(full.received_date - full.promised_date).dt.days)
    by_vendor = full.groupby("vendor_name").agg(lines=("po_line_id", "count"), on_time=("days_late", lambda s: float((s <= 0).mean())),
                                                avg_days_late=("days_late", "mean"))
    open_ = pos2[pos2.status.isin(["Ordered", "Shipped", "Partially Received"])]
    overdue = open_[open_.promised_date < pd.Timestamp(AS_OF)]
    key["procurement"] = dict(
        po_lines=int(len(pos)), open_lines=int(len(open_)), overdue_open_lines=int(len(overdue)),
        overdue_open_amount=r2(overdue.ordered_amount.sum()),
        on_time_rate_by_vendor={k: round(float(v), 4) for k, v in by_vendor.on_time.items()},
        worst_vendor=by_vendor.on_time.idxmin(),
        received_not_invoiced=sorted(rcs[rcs.receipt_id.isin(skip_inv)].po_line_id.unique().tolist()),
        invoiced_not_received=sorted(pre_ids),
        total_po_ordered=r2(pos.ordered_amount.sum()))
    ar = b[(b.paid_date.isna()) & (pd.to_datetime(b.submitted_date) <= pd.Timestamp(AS_OF))]
    ar_days = (pd.Timestamp(AS_OF) - pd.to_datetime(ar.due_date)).dt.days
    key["ar"] = dict(unpaid_total=r2(ar.gross_billed.sum()), overdue_90_plus=r2(ar[ar_days > 90].gross_billed.sum()),
                     overdue_by_project=ar.assign(d=ar_days)[ar.assign(d=ar_days).d > 0].groupby("project_id").gross_billed.sum().round(2).to_dict())
    inv_df = pd.DataFrame(inv_items)
    key["inventory_below_reorder"] = sorted(inv_df[inv_df.on_hand_qty < inv_df.reorder_point].item_name.tolist())
    rf = pd.DataFrame(rfi_rows)
    rf_open = rf[rf.status == "Open"]
    rf_open = rf_open.assign(overdue=(pd.Timestamp(AS_OF) - pd.to_datetime(rf_open.due_date)).dt.days)
    key["rfi_open_overdue_by_project"] = rf_open[rf_open.overdue > 0].groupby("project_id").size().to_dict()
    ms = pd.DataFrame(ms_rows)
    key["milestone_final_slip_days"] = {r.project_id: int((pd.Timestamp(r.forecast_date) - pd.Timestamp(r.planned_date)).days)
                                        for r in ms[ms.milestone_name.isin(["Substantial Completion", "Final Delivery"])].itertuples()}
    return key


# ----------------------------------------------------------------------------
# RAW layer for the expansion tables (with planted, logged defects)
# ----------------------------------------------------------------------------
def _s(df, date_cols=(), money_cols=(), num_cols=()):
    """Stringify like a CSV export: ISO dates, 2-dp money, blanks for nulls."""
    df = df.copy()
    for c in date_cols:
        df[c] = df[c].map(lambda x: "" if x is None or x is pd.NaT or (isinstance(x, float) and np.isnan(x)) else str(x)[:10])
    for c in money_cols:
        df[c] = df[c].map(lambda x: "" if x is None or (isinstance(x, float) and np.isnan(x)) else f"{float(x):.2f}")
    for c in num_cols:
        df[c] = df[c].map(lambda x: "" if x is None or (isinstance(x, float) and np.isnan(x)) else str(x))
    return df


def build_raw_extension(T, rng):
    from generate_data import fmt_mdy, variants
    log = []

    def L(table, key, dtype, action, note):
        log.append(dict(table=table, key=str(key), defect_type=dtype, expected_action=action, note=note))

    def vend_variants(df, table, key_col, frac):
        idx = df.index[df.vendor_name.notna() & (df.vendor_name != "")].tolist()
        for i in rng.choice(idx, int(len(idx) * frac), replace=False):
            vs = variants(df.at[i, "vendor_name"])
            df.at[i, "vendor_name"] = vs[int(rng.integers(0, len(vs)))]
            L(table, df.at[i, key_col], "vendor_spelling", "fixed", "vendor name variant; standardize to canonical")

    raw = {}
    raw["vendors"] = T["vendors"].astype(str)
    raw["equipment"] = T["equipment_clean"].copy().pipe(_s, money_cols=["daily_rate"])
    raw["equipment"]["vendor_name"] = raw["equipment"]["vendor_name"].fillna("")

    # --- purchase_orders
    po = _s(T["purchase_orders_clean"], date_cols=["order_date", "promised_date", "ship_date", "received_date"],
            money_cols=["unit_price", "ordered_amount"], num_cols=["quantity"])
    vend_variants(po, "purchase_orders", "po_line_id", 0.15)
    for i in rng.choice(len(po), 6, replace=False):
        po.at[i, "order_date"] = fmt_mdy(po.at[i, "order_date"])
        L("purchase_orders", po.at[i, "po_line_id"], "mixed_date_format", "fixed", "order_date given as MM/DD/YYYY")
    ex = []
    for k, (_, r) in enumerate(po.sample(3, random_state=31).iterrows()):
        ex.append(r.to_dict())
        L("purchase_orders", r.po_line_id, "duplicate_po_line_exact", "deduplicated", f"exact duplicate of {r.po_line_id}")
    for k in range(2):
        r = po.iloc[10 + k].to_dict()
        r.update(po_line_id=f"POL9{k:04d}", project_id="P-199")
        ex.append(r)
        L("purchase_orders", r["po_line_id"], "orphan_project_fk", "rejected", "project_id P-199 not in projects")
    for k in range(2):
        r = po.iloc[20 + k].to_dict()
        r.update(po_line_id=f"POL9{10 + k:04d}", quantity="-12")
        ex.append(r)
        L("purchase_orders", r["po_line_id"], "negative_quantity", "rejected", "quantity below zero")
    for k in range(2):
        r = po.iloc[30 + k].to_dict()
        r.update(po_line_id=f"POL9{20 + k:04d}", received_date="2020-01-15", status="Received")
        ex.append(r)
        L("purchase_orders", r["po_line_id"], "received_before_order", "rejected", "received_date earlier than order_date")
    raw["purchase_orders"] = pd.concat([po, pd.DataFrame(ex)], ignore_index=True).sample(frac=1, random_state=41).reset_index(drop=True)

    # --- po_receipts
    rc = _s(T["po_receipts_clean"], date_cols=["receipt_date"], money_cols=["received_amount"], num_cols=["received_qty"])
    ex = []
    for _, r in rc.sample(2, random_state=33).iterrows():
        ex.append(r.to_dict())
        L("po_receipts", r.receipt_id, "duplicate_receipt_exact", "deduplicated", f"exact duplicate of {r.receipt_id}")
    for k in range(3):
        r = rc.iloc[5 + k].to_dict()
        r.update(receipt_id=f"RC9{k:04d}", po_line_id=f"POL8{k:04d}")
        ex.append(r)
        L("po_receipts", r["receipt_id"], "orphan_po_fk", "rejected", f"po_line_id {r['po_line_id']} not in purchase_orders")
    raw["po_receipts"] = pd.concat([rc, pd.DataFrame(ex)], ignore_index=True).sample(frac=1, random_state=42).reset_index(drop=True)

    # --- ap_invoices
    ap = _s(T["ap_invoices_clean"], date_cols=["invoice_date", "due_date", "paid_date"], money_cols=["amount"])
    vend_variants(ap, "ap_invoices", "invoice_id", 0.15)
    for i in rng.choice(len(ap), 5, replace=False):
        v = float(ap.at[i, "amount"])
        ap.at[i, "amount"] = f"${v:,.2f}"
        L("ap_invoices", ap.at[i, "invoice_id"], "currency_string", "fixed", "amount stored as '$1,234.56' text")
    ex = []
    for k, (_, r) in enumerate(ap.sample(4, random_state=35).iterrows()):
        d = r.to_dict()
        d.update(invoice_id=f"AP9{k:04d}")                          # same vendor + invoice_no, new id
        ex.append(d)
        L("ap_invoices", d["invoice_id"], "duplicate_invoice_rekeyed", "deduplicated", f"same vendor invoice_no {r.invoice_no} as {r.invoice_id}")
    for k in range(2):
        d = ap.iloc[40 + k].to_dict()
        d.update(invoice_id=f"AP9{10 + k:04d}", invoice_no=f"ZZZ-{9000 + k}", po_line_id=f"POL8{k:04d}")
        ex.append(d)
        L("ap_invoices", d["invoice_id"], "orphan_po_fk", "rejected", f"po_line_id {d['po_line_id']} not in purchase_orders")
    for k in range(2):
        d = ap.iloc[50 + k].to_dict()
        d.update(invoice_id=f"AP9{20 + k:04d}", invoice_no=f"ZZZ-{9100 + k}", invoice_date="2027-02-15", due_date="2027-03-17", paid_date="", status="Open")
        ex.append(d)
        L("ap_invoices", d["invoice_id"], "future_invoice_date", "rejected", "invoice_date after the as-of date")
    raw["ap_invoices"] = pd.concat([ap, pd.DataFrame(ex)], ignore_index=True).sample(frac=1, random_state=43).reset_index(drop=True)

    # --- subcontract_pay_apps
    sp = _s(T["subcontract_pay_apps_clean"], date_cols=["period_end", "invoice_date", "due_date", "paid_date", "retainage_release_date"],
            money_cols=["gross_billed", "retainage_held", "paid_amount", "retainage_released"])
    vend_variants(sp, "subcontract_pay_apps", "sub_pay_app_id", 0.12)
    ex = []
    for k in range(2):
        d = sp.iloc[3 + k].to_dict()
        d.update(sub_pay_app_id=f"SP9{k:04d}", commitment_id=f"CM9{k:04d}")
        ex.append(d)
        L("subcontract_pay_apps", d["sub_pay_app_id"], "orphan_commitment_fk", "rejected", f"commitment_id {d['commitment_id']} not in commitments")
    d = sp.iloc[7].to_dict()
    d.update(sub_pay_app_id="SP9100", gross_billed="-22400.00", retainage_held="-2240.00")
    ex.append(d)
    L("subcontract_pay_apps", "SP9100", "negative_amount_sign_error", "rejected", "negative gross billing, not a credit")
    raw["subcontract_pay_apps"] = pd.concat([sp, pd.DataFrame(ex)], ignore_index=True)

    # --- equipment_usage
    eu = _s(T["equipment_usage_clean"], date_cols=["month_end"], money_cols=["usage_cost"], num_cols=["days_used", "standby_days"])
    ex = []
    for k in range(3):
        d = eu.iloc[2 + k].to_dict()
        d.update(usage_id=f"EU9{k:04d}", days_used="48")
        ex.append(d)
        L("equipment_usage", d["usage_id"], "days_out_of_range", "rejected", "days_used above 31 in a month")
    for k in range(2):
        d = eu.iloc[8 + k].to_dict()
        d.update(usage_id=f"EU9{10 + k:04d}", equipment_id="EQ99")
        ex.append(d)
        L("equipment_usage", d["usage_id"], "orphan_equipment_fk", "rejected", "equipment_id EQ99 not in equipment")
    raw["equipment_usage"] = pd.concat([eu, pd.DataFrame(ex)], ignore_index=True)

    # --- inventory_items
    iv = _s(T["inventory_items_clean"], date_cols=["last_receipt_date", "as_of_date"], money_cols=["unit_cost"],
            num_cols=["on_hand_qty", "reorder_point", "reorder_qty", "avg_daily_usage", "lead_time_days"])
    ex = []
    for k in range(2):
        d = iv.iloc[k].to_dict()
        d.update(item_id=f"INV9{k}", on_hand_qty="-35.0")
        ex.append(d)
        L("inventory_items", d["item_id"], "negative_on_hand", "rejected", "on_hand_qty below zero")
    raw["inventory_items"] = pd.concat([iv, pd.DataFrame(ex)], ignore_index=True)

    # --- rfis / submittals / milestones
    rf = _s(T["rfis_clean"], date_cols=["submitted_date", "due_date", "response_date"], num_cols=["rfi_number", "schedule_impact_days"])
    ex = []
    for k in range(2):
        d = rf.iloc[15 + k].to_dict()
        d.update(rfi_id=f"RFI9{k:04d}", response_date="2019-01-01", status="Closed")
        ex.append(d)
        L("rfis", d["rfi_id"], "response_before_submission", "rejected", "response_date earlier than submitted_date")
    raw["rfis"] = pd.concat([rf, pd.DataFrame(ex)], ignore_index=True)

    sb = _s(T["submittals_clean"], date_cols=["required_by_date", "submitted_date", "returned_date"], num_cols=["cycle_count"])
    d = sb.iloc[5].to_dict()
    d.update(submittal_id="SB99999", project_id="P-199")
    sb = pd.concat([sb, pd.DataFrame([d])], ignore_index=True)
    L("submittals", "SB99999", "orphan_project_fk", "rejected", "project_id P-199 not in projects")
    raw["submittals"] = sb

    ms = _s(T["schedule_milestones_clean"], date_cols=["planned_date", "forecast_date", "actual_date"])
    dupe = ms.iloc[4].to_dict()
    ms = pd.concat([ms, pd.DataFrame([dupe])], ignore_index=True)
    L("schedule_milestones", dupe["milestone_id"], "duplicate_milestone_exact", "deduplicated", f"exact duplicate of {dupe['milestone_id']}")
    raw["schedule_milestones"] = ms

    raw = {k: v.astype(object).where(pd.notna(v), "") for k, v in raw.items()}
    return raw, log
