#!/usr/bin/env python3
"""
Seeded synthetic data generator for the "Gulf Coast Builders" analytics project.

*** ALL DATA IS SYNTHETIC. Gulf Coast Builders is a fictional company. ***
Nothing here comes from, or represents, any real company's data or systems.

What it does
  1. Builds a CLEAN in-memory dataset (ERP-style + CRM-style tables).
  2. Computes an ANSWER KEY from the clean data (data/truth/answer_key.json).
  3. Injects known, logged defects to produce the RAW layer (data/raw/*.csv).
     Defects are either
       - representation problems on existing rows (vendor spelling, date and
         currency formats, cost-code formatting)  -> staging can FIX them, or
       - extra bad rows appended (duplicates, orphans, missing codes, sign
         errors, out-of-range values)              -> staging must QUARANTINE them.
     Because bad rows are appended (not substituted), a correct pipeline must
     reconcile exactly to the clean answer key.
  4. Writes the defect log (data/truth/planted_defects.json, docs/planted_defects.md).

Run:  python src/generate_data.py [--seed 20260930] [--out data/raw]
"""
import argparse
import calendar
import json
import re
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

SEED = 20260930
AS_OF = date(2026, 9, 30)
FIRST_MONTH = (2024, 10)          # month index 0 = Oct 2024 ; index 23 = Sep 2026
N_MONTHS = 24


# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
def month_start(i):
    y = FIRST_MONTH[0] + (FIRST_MONTH[1] - 1 + i) // 12
    m = (FIRST_MONTH[1] - 1 + i) % 12 + 1
    return date(y, m, 1)


def month_end(i):
    d = month_start(i)
    return date(d.year, d.month, calendar.monthrange(d.year, d.month)[1])


def month_idx(y, m):
    return (y - FIRST_MONTH[0]) * 12 + (m - FIRST_MONTH[1])


def smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def r2(x):
    return float(np.round(x, 2))


# ----------------------------------------------------------------------------
# Reference data
# ----------------------------------------------------------------------------
# code, name, category, division, schedule window (start frac, end frac of project)
CODES = [
    ("01-100", "General Conditions", "Indirect", "01 General Requirements", (0.00, 1.00)),
    ("02-200", "Sitework & Earthwork", "Subcontract", "02 Sitework", (0.00, 0.45)),
    ("03-300", "Concrete", "Subcontract", "03 Concrete", (0.08, 0.60)),
    ("04-400", "Structural Steel & Metals", "Material", "04 Metals", (0.15, 0.70)),
    ("05-500", "Framing & Carpentry Labor", "Labor", "05 Carpentry", (0.30, 0.85)),
    ("06-600", "Mechanical, Electrical, Plumbing", "Subcontract", "06 MEP", (0.30, 0.95)),
    ("07-700", "Interior Finishes", "Subcontract", "07 Finishes", (0.55, 1.00)),
    ("08-800", "Equipment & Fuel", "Equipment", "08 Equipment", (0.00, 0.92)),
    ("09-900", "Self-Perform Labor", "Labor", "09 Self-Perform", (0.05, 0.95)),
    ("10-100", "Materials & Aggregates", "Material", "10 Materials", (0.05, 0.80)),
    ("11-100", "Paving & Utilities", "Subcontract", "11 Paving", (0.40, 0.95)),
    ("12-100", "Insurance, Bonds & Permits", "Indirect", "12 Risk & Permits", (0.00, 0.25)),
    ("13-100", "Fabrication Materials", "Material", "13 Manufacturing", (0.00, 0.90)),
    ("14-100", "Plant Labor", "Labor", "14 Manufacturing", (0.00, 1.00)),
]
CODE_INFO = {c[0]: c for c in CODES}

COST_SHARES = {
    "Building": {"01-100": .08, "02-200": .06, "03-300": .14, "04-400": .10, "05-500": .08,
                 "06-600": .22, "07-700": .13, "08-800": .04, "09-900": .06, "12-100": .05, "10-100": .04},
    "Heavy Civil": {"01-100": .06, "02-200": .18, "03-300": .12, "04-400": .06, "08-800": .12,
                    "09-900": .12, "10-100": .14, "11-100": .14, "12-100": .06},
    "Manufacturing": {"01-100": .05, "08-800": .05, "12-100": .03, "13-100": .52, "14-100": .28, "04-400": .07},
}

VENDORS = {  # canonical vendor names by cost code
    "02-200": ["Delta Earthworks Inc.", "Cypress Excavating LLC"],
    "03-300": ["Bayou Concrete Co.", "Gulf Ready-Mix LLC"],
    "04-400": ["Crescent Steel Supply", "Pelican Metal Works"],
    "06-600": ["Magnolia Mechanical Inc.", "Southern Electric Contractors", "Riverside Plumbing Co."],
    "07-700": ["Heritage Interiors LLC", "Coastal Drywall & Paint"],
    "08-800": ["Gulf Equipment Rental"],
    "10-100": ["Gulf Aggregates Inc.", "Cypress Lumber & Supply"],
    "11-100": ["Delta Paving & Utilities"],
    "13-100": ["Crescent Steel Supply", "Gulf Aggregates Inc."],
    "12-100": ["Bayou Surety & Insurance"],
}

# story knobs ---------------------------------------------------------------
# (actual-to-date multiplier f, estimate-to-complete multiplier g) on specific cost codes
FADE = {
    "P-103": {"06-600": (1.17, 1.20), "07-700": (1.15, 1.18), "03-300": (1.09, 1.12)},
    "P-107": {"02-200": (1.14, 1.19), "10-100": (1.12, 1.16), "11-100": (1.10, 1.13)},
    "P-110": {"13-100": (1.10, 1.13), "04-400": (1.17, 1.20)},
}
WEATHER_MONTHS = {  # month indexes where spend dips (storms / freeze / heat)
    "P-101": [10], "P-105": [10, 11, 20], "P-106": [10, 11, 15], "P-107": [10, 11, 15, 20],
    "P-108": [11, 20], "P-104": [11],
}
HEAVY_PENDING = {"P-104": 0.14, "P-109": 0.13}      # pending CO revenue as share of contract
OVER_BILLED = "P-105"
UNDER_BILLED = "P-108"
SAFETY_CLUSTER = "P-106"

PROJECTS = [
    # id, name, bu, account, pm key, start (y,m), planned end (y,m), contract, bid margin, status
    ("P-101", "Canal Street Mixed-Use Tower", "Building", "Crescent City Development Group", "PM1", (2024, 10), (2028, 3), 48_000_000, .095, "Active"),
    ("P-102", "Lakeview Medical Office Building", "Building", "Magnolia Health Partners", "PM2", (2025, 5), (2027, 9), 22_500_000, .100, "Active"),
    ("P-103", "Riverbend Hotel Renovation", "Building", "Riverbend Hospitality Group", "PM1", (2025, 1), (2027, 12), 31_000_000, .110, "Active"),
    ("P-104", "Cypress Parish School Addition", "Building", "Cypress Parish School Board", "PM2", (2025, 6), (2027, 8), 18_500_000, .085, "Active"),
    ("P-105", "Bayou Road Bridge Replacement", "Heavy Civil", "Bayou Parish Public Works", "PM3", (2025, 3), (2027, 9), 36_000_000, .120, "Active"),
    ("P-106", "I-10 Interchange Widening", "Heavy Civil", "State Transportation Authority", "PM3", (2024, 11), (2027, 8), 61_000_000, .080, "Active"),
    ("P-107", "Lakeshore Levee Segment 4", "Heavy Civil", "Lakeshore Levee Authority", "PM4", (2025, 4), (2027, 12), 44_000_000, .105, "Active"),
    ("P-108", "Industrial Blvd Drainage Upgrade", "Heavy Civil", "Delta Regional Port Authority", "PM4", (2025, 8), (2027, 4), 15_000_000, .110, "Active"),
    ("P-109", "Eastbank Community Center", "Building", "Eastbank Community Foundation", "PM2", (2026, 1), (2027, 9), 12_800_000, .090, "Active"),
    ("P-110", "Precast Wall Panel Supply - Gulf Terminal", "Manufacturing", "Delta Regional Port Authority", "PM5", (2025, 7), (2027, 4), 9_200_000, .170, "Active"),
    ("P-111", "Modular Restroom Units - Parks Dept", "Manufacturing", "Magnolia City Parks Department", "PM5", (2024, 10), (2025, 9), 4_100_000, .180, "Completed"),
    ("P-112", "Elmwood Retail Shell", "Building", "Elmwood Retail Partners", "PM1", (2024, 10), (2025, 11), 14_600_000, .095, "Completed"),
]

CO_DESCRIPTIONS = {
    "Building": ["Added electrical outlets per owner request", "Revised door hardware schedule", "Unforeseen subsurface conditions at footing",
                 "Owner-directed finish upgrade", "HVAC relocation due to design conflict", "Fire alarm scope addition",
                 "Accelerated drywall schedule", "Roofing substrate replacement", "Additional site lighting", "Elevator pit waterproofing"],
    "Heavy Civil": ["Unsuitable soil removal and replacement", "Utility conflict relocation", "Added traffic control phases",
                    "Revised pile lengths", "Night-work premium per agency", "Additional drainage structures",
                    "Storm damage repair to temporary works", "Quantity overrun - aggregate base", "Environmental permit condition"],
    "Manufacturing": ["Revised panel dimensions per drawings", "Added embed plates", "Expedited delivery premium",
                      "Finish upgrade - sandblast", "Additional mockup panels"],
}
CO_REASONS = ["Owner Change", "Unforeseen Conditions", "Design Error", "Weather", "Schedule Acceleration"]

FIRST = ["James", "Maria", "Robert", "Linda", "Michael", "Patricia", "William", "Jennifer", "David", "Elizabeth", "Joseph", "Susan",
         "Thomas", "Karen", "Charles", "Nancy", "Daniel", "Lisa", "Matthew", "Betty", "Anthony", "Sandra", "Mark", "Ashley",
         "Steven", "Kimberly", "Paul", "Donna", "Andrew", "Emily", "Kenneth", "Carol", "Joshua", "Michelle", "Kevin", "Amanda",
         "Brian", "Melissa", "George", "Deborah", "Ray", "Camille", "Remy", "Etienne", "Dana", "Jordan", "Terrence", "Latoya"]
LAST = ["Boudreaux", "Thibodeaux", "Landry", "Broussard", "Guidry", "Hebert", "Fontenot", "Robichaux", "Johnson", "Williams",
        "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson",
        "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez",
        "Clark", "Ramirez", "Lewis", "Robinson", "Walker", "Young", "Allen", "King", "Wright", "Scott", "Torres", "Nguyen",
        "Hill", "Flores", "Green", "Adams", "Nelson"]

NAME_PARTS_A = ["Crescent", "Magnolia", "Pelican", "Delta", "Bayou", "Cypress", "Lakeshore", "Gulf", "Heritage", "Riverside", "Southern", "Coastal"]
NAME_PARTS_B = ["Health Systems", "Development Partners", "Port Commission", "School District", "Hospitality Group", "Realty Trust",
                "Industrial Holdings", "Parish Council", "Housing Authority", "Energy Services", "Logistics", "Retail Holdings",
                "University Foundation", "Water Board", "Properties LLC", "Capital Group"]


def pick_name(rng):
    return f"{rng.choice(FIRST)} {rng.choice(LAST)}"


# ----------------------------------------------------------------------------
# Generation
# ----------------------------------------------------------------------------
def generate_clean(rng):
    T = {}   # clean tables (pandas)
    truth = {}

    # ---------------- employees ----------------
    emp_rows = []
    used_names = set()

    def add_emp(role, bu, field, rate_lo, rate_hi):
        while True:
            n = pick_name(rng)
            if n not in used_names:
                used_names.add(n)
                break
        eid = f"E{len(emp_rows) + 1:04d}"
        hire = date(2015, 1, 1) + timedelta(days=int(rng.integers(0, 3500)))
        emp_rows.append(dict(employee_id=eid, full_name=n, role=role, business_unit=bu,
                             is_field=int(field), hire_date=hire.isoformat(),
                             hourly_rate=r2(rng.uniform(rate_lo, rate_hi)),
                             email=n.lower().replace(" ", ".") + "@example.invalid"))
        return eid

    bu_lead = {bu: add_emp("Business Unit Lead", bu, False, 95, 120) for bu in ["Building", "Heavy Civil", "Manufacturing"]}
    pm_ids = {}
    pm_bu = {"PM1": "Building", "PM2": "Building", "PM3": "Heavy Civil", "PM4": "Heavy Civil", "PM5": "Manufacturing"}
    for k, bu in pm_bu.items():
        pm_ids[k] = add_emp("Project Manager", bu, False, 70, 95)
    for bu, n in [("Building", 3), ("Heavy Civil", 3), ("Manufacturing", 1)]:
        for _ in range(n):
            add_emp("Superintendent", bu, True, 55, 75)
    for bu in ["Building", "Heavy Civil", "Manufacturing"]:
        add_emp("Estimator", bu, False, 60, 85)
    for _ in range(2):
        add_emp("Safety Manager", "Corporate", False, 55, 75)
    for _ in range(3):
        add_emp("Finance Analyst", "Corporate", False, 45, 65)
    field_roles = ["Carpenter", "Laborer", "Equipment Operator", "Ironworker", "Electrician Helper", "Fabricator", "Foreman"]
    for bu, n in [("Building", 55), ("Heavy Civil", 70), ("Manufacturing", 25)]:
        for _ in range(n):
            role = rng.choice(field_roles if bu != "Manufacturing" else ["Fabricator", "Laborer", "Foreman", "Equipment Operator"])
            add_emp(str(role), bu, True, 24, 46)
    employees = pd.DataFrame(emp_rows)
    T["employees"] = employees

    # ---------------- accounts (CRM) ----------------
    acct_names = []
    for p in PROJECTS:
        if p[3] not in acct_names:
            acct_names.append(p[3])
    while len(acct_names) < 28:
        n = f"{rng.choice(NAME_PARTS_A)} {rng.choice(NAME_PARTS_B)}"
        if n not in acct_names:
            acct_names.append(n)
    seg_map = {"Public": ["Authority", "Parish", "Port", "Board", "Department", "District", "Water", "Housing"],
               "Healthcare": ["Health"], "Education": ["School", "University"], "Hospitality": ["Hospitality"],
               "Retail": ["Retail"], "Industrial": ["Industrial", "Energy", "Logistics"]}

    def segment(n):
        for seg, keys in seg_map.items():
            if any(k in n for k in keys):
                return seg
        return "Private Developer"

    regions = ["Metro", "Northshore", "Westbank", "Bayou Region", "Acadiana"]
    accounts = pd.DataFrame([dict(account_id=f"A{i + 1:03d}", account_name=n, segment=segment(n),
                                  region=str(rng.choice(regions)),
                                  created_date=(date(2019, 1, 1) + timedelta(days=int(rng.integers(0, 2000)))).isoformat())
                             for i, n in enumerate(acct_names)])
    T["accounts"] = accounts
    acct_id = dict(zip(accounts.account_name, accounts.account_id))

    # ---------------- projects, change orders, budgets, costs ----------------
    projects, budget_rows, co_rows, commit_rows, cost_rows = [], [], [], [], []
    bid_cost_total = {}
    proj_meta = {}

    for (pid, name, bu, acct, pmk, (sy, sm), (ey, em), contract, margin, status) in PROJECTS:
        s, e = month_idx(sy, sm), month_idx(ey, em)
        dur = e - s + 1
        orig_cost = round(contract * (1 - margin), 2)
        bid_cost_total[pid] = orig_cost
        proj_meta[pid] = dict(s=s, e=e, dur=dur, bu=bu, contract=contract, margin=margin, status=status, pm=pm_ids[pmk])
        projects.append(dict(project_id=pid, project_name=name, business_unit=bu,
                             account_id=acct_id[acct], pm_employee_id=pm_ids[pmk],
                             start_date=month_start(s).isoformat(), planned_end_date=month_end(e).isoformat(),
                             original_contract_value=contract, status=status, opportunity_id=None))
    projects = pd.DataFrame(projects)

    # --- change orders
    last_month = N_MONTHS - 1
    for pid, meta in proj_meta.items():
        s, e = meta["s"], meta["e"]
        active_end = min(e, last_month)
        contract = meta["contract"]
        sub = []
        n_clusters = int(rng.integers(1, 4))
        centers = sorted(rng.integers(s + 1, max(s + 2, active_end), size=n_clusters).tolist())
        for c in centers:
            for _ in range(int(rng.integers(2, 6))):
                sub_d = month_start(int(c)) + timedelta(days=int(rng.integers(0, 28)))
                if sub_d >= AS_OF - timedelta(days=5) or sub_d < month_start(s):
                    continue
                sub.append(sub_d)
        sub = sorted(sub)
        # average approved CO load 3-6 % of contract
        target = contract * rng.uniform(0.03, 0.06)
        weights = rng.lognormal(0, 0.6, size=max(len(sub), 1))
        amounts = weights / weights.sum() * target
        for d, amt in zip(sub, amounts):
            days = int(min(150, rng.lognormal(np.log(18), 0.7)))
            dec = d + timedelta(days=days)
            if meta["status"] == "Completed" and dec > month_end(e):
                dec = month_end(e) - timedelta(days=int(rng.integers(0, 20)))
            if dec > AS_OF:
                status, dec_d = "Pending", None
            else:
                status = "Approved" if rng.random() < 0.87 else "Rejected"
                dec_d = dec
            co_rows.append(dict(project_id=pid, description=str(rng.choice(CO_DESCRIPTIONS[meta["bu"]])),
                                reason=str(rng.choice(CO_REASONS)), submitted_date=d, decision_date=dec_d,
                                status=status, amount=r2(amt),
                                estimated_cost=r2(amt * (1 - rng.normal(0.08, 0.03)))))
    # --- planted: heavy pending change orders
    for pid, share in HEAVY_PENDING.items():
        meta = proj_meta[pid]
        n_big = 7
        total = meta["contract"] * share
        w = rng.lognormal(0, 0.5, size=n_big)
        amts = w / w.sum() * total
        for amt in amts:
            age = int(rng.integers(45, 240))
            sd = AS_OF - timedelta(days=age)
            if sd < month_start(meta["s"]):
                sd = month_start(meta["s"]) + timedelta(days=int(rng.integers(20, 60)))
            co_rows.append(dict(project_id=pid, description=str(rng.choice(CO_DESCRIPTIONS[meta["bu"]])),
                                reason=str(rng.choice(CO_REASONS[:3])), submitted_date=sd, decision_date=None,
                                status="Pending", amount=r2(amt), estimated_cost=r2(amt * 0.92)))
    cos = pd.DataFrame(co_rows).sort_values(["project_id", "submitted_date"]).reset_index(drop=True)
    cos["co_number"] = cos.groupby("project_id").cumcount() + 1
    cos["change_order_id"] = [f"CO-{p[2:]}-{n:03d}" for p, n in zip(cos.project_id, cos.co_number)]
    T["change_orders_clean"] = cos

    # --- budget lines (original + approved CO cost spread over sub/material lines)
    approved = cos[cos.status == "Approved"]
    line_budget = {}   # (pid, code) -> dict(orig, co)
    for pid, meta in proj_meta.items():
        shares = COST_SHARES[meta["bu"]]
        orig = bid_cost_total[pid]
        raw_sh = np.array(list(shares.values()))
        jitter = rng.normal(1, 0.06, size=len(raw_sh))
        sh = raw_sh * jitter
        sh = sh / sh.sum()
        amts = np.round(orig * sh, 2)
        amts[0] = round(orig - amts[1:].sum(), 2)    # make lines tie exactly to bid cost
        for code, a in zip(shares.keys(), amts):
            line_budget[(pid, code)] = dict(orig=float(a), co=0.0)
        co_cost = approved[approved.project_id == pid].estimated_cost.sum()
        cands = [c for c in shares if CODE_INFO[c][2] in ("Subcontract", "Material")]
        picks = rng.choice(cands, size=min(3, len(cands)), replace=False)
        for c in picks:
            line_budget[(pid, c)]["co"] = r2(co_cost / len(picks))

    # --- actual costs, ETC
    etc_rows = {}
    for pid, meta in proj_meta.items():
        s, e, dur = meta["s"], meta["e"], meta["dur"]
        completed = meta["status"] == "Completed"
        last_m = e if completed else min(e, last_month)
        for code in COST_SHARES[meta["bu"]]:
            lb = line_budget[(pid, code)]
            B = lb["orig"] + lb["co"]
            a0, b0 = CODE_INFO[code][4]
            a = float(np.clip(a0 + rng.normal(0, 0.04), 0, 0.8))
            b = float(np.clip(b0 + rng.normal(0, 0.04), a + 0.2, 1.0))
            if pid in FADE and code in FADE[pid]:
                f, g = FADE[pid][code]
            else:
                f = float(np.clip(1 + rng.normal(0, 0.015), 0.97, 1.04))
                g = 1 + (f - 1) * 0.7 + rng.normal(0, 0.008)
            prev_cum = 0.0
            spent = 0.0
            vend = VENDORS.get(code)
            for m in range(s, last_m + 1):
                u = (m + 1 - s) / dur
                cum = B * float(smooth((u - a) / (b - a)))
                inc = cum - prev_cum
                prev_cum = cum
                w = 1.0
                if m in WEATHER_MONTHS.get(pid, []):
                    w = float(rng.uniform(0.45, 0.65))
                amt = inc * f * float(rng.lognormal(0, 0.08)) * w
                if completed and m == last_m:
                    amt = B * f - spent          # land the closed job exactly on f * budget
                amt = round(amt, 2)
                spent += amt
                if abs(amt) < 1:
                    continue
                cat = CODE_INFO[code][2]
                vendor = None
                if vend and cat != "Labor":
                    vendor = vend[(m + s) % len(vend)]
                desc = f"{CODE_INFO[code][1]} - {month_start(m):%b %Y}"
                if amt < 0:                       # closeout true-ups that reduce cost are booked as credit memos
                    desc = f"Vendor credit memo - closeout true-up ({CODE_INFO[code][1]})"
                cost_rows.append(dict(project_id=pid, cost_code=code, period=month_end(m), amount=amt,
                                      vendor_name=vendor,
                                      source_system="Payroll" if cat == "Labor" else ("Equipment" if cat == "Equipment" else "AP"),
                                      description=desc))
            etc = 0.0 if completed else max(0.0, g * (B - spent / f))
            etc_rows[(pid, code)] = round(etc, 2)

    costs = pd.DataFrame(cost_rows)
    # a few legitimate vendor credits (kept in the clean data -> kept after staging)
    cand = costs[costs.vendor_name.notna() & (costs.amount > 50000)].sample(3, random_state=7)
    cr = []
    for _, row in cand.iterrows():
        cr.append(dict(project_id=row.project_id, cost_code=row.cost_code, period=row.period,
                       amount=-round(row.amount * rng.uniform(0.02, 0.05), 2), vendor_name=row.vendor_name,
                       source_system="AP", description="Vendor credit memo - returned material"))
    costs = pd.concat([costs, pd.DataFrame(cr)], ignore_index=True)
    costs = costs.sort_values(["project_id", "period", "cost_code"]).reset_index(drop=True)
    costs.insert(0, "cost_id", [f"AC{i + 1:06d}" for i in range(len(costs))])
    T["actual_costs_clean"] = costs

    for (pid, code), lb in line_budget.items():
        budget_rows.append(dict(project_id=pid, cost_code=code, original_budget=round(lb["orig"], 2),
                                approved_co_budget=round(lb["co"], 2),
                                revised_budget=round(lb["orig"] + lb["co"], 2),
                                estimate_to_complete=etc_rows[(pid, code)],
                                etc_updated_date=AS_OF.isoformat()))
    budget = pd.DataFrame(budget_rows).sort_values(["project_id", "cost_code"]).reset_index(drop=True)
    budget.insert(0, "budget_line_id", [f"BL{i + 1:05d}" for i in range(len(budget))])
    T["budget_lines"] = budget

    # --- commitments (subcontracts and POs)
    cid = 0
    for pid, meta in proj_meta.items():
        for code in COST_SHARES[meta["bu"]]:
            cat = CODE_INFO[code][2]
            if cat not in ("Subcontract", "Material", "Equipment") or code not in VENDORS:
                continue
            lb = line_budget[(pid, code)]
            vend = VENDORS[code]
            coverage = rng.uniform(0.75, 0.95)
            vlist = list(dict.fromkeys(vend))
            per = lb["orig"] * coverage / len(vlist)
            for v in vlist:
                cid += 1
                commit_rows.append(dict(commitment_id=f"CM{cid:05d}", project_id=pid, cost_code=code, vendor_name=v,
                                        commitment_type="Subcontract" if cat == "Subcontract" else "Purchase Order",
                                        original_amount=r2(per), approved_changes=r2(lb["co"] / len(vlist)),
                                        status="Closed" if meta["status"] == "Completed" else "Open",
                                        executed_date=(month_start(meta["s"]) + timedelta(days=int(rng.integers(0, 75)))).isoformat()))
    T["commitments_clean"] = pd.DataFrame(commit_rows)

    # --- per-project EAC / pct complete (as-of) used by billing and the answer key
    cost_by_proj = costs.groupby("project_id").amount.sum()
    etc_by_proj = budget.groupby("project_id").estimate_to_complete.sum()
    eac = (cost_by_proj + etc_by_proj).to_dict()

    # --- billings (pay applications)
    bill_rows = []
    for pid, meta in proj_meta.items():
        s, e = meta["s"], meta["e"]
        completed = meta["status"] == "Completed"
        last_m = e if completed else min(e, last_month)
        pc = costs[costs.project_id == pid].groupby("period").amount.sum()
        cum_cost = 0.0
        billed_prev = 0.0
        u_state = 0.0
        ap_no = 0
        ap_cos = approved[approved.project_id == pid]
        for m in range(s, last_m + 1):
            pe = month_end(m)
            cum_cost += float(pc.get(pe, 0.0))
            pct = min(1.0, cum_cost / eac[pid])
            rev_m = meta["contract"] + float(ap_cos[ap_cos.decision_date <= pe].amount.sum())
            earned = pct * rev_m
            # billing position (u): over/under relative to earned
            if pid == OVER_BILLED:
                u = float(np.clip((m - (s + 2)) / 8, 0, 1)) * 0.16 + rng.normal(0, 0.004)
            elif pid == UNDER_BILLED:
                u = -float(np.clip((m - (s + 3)) / 8, 0, 1)) * 0.15 + rng.normal(0, 0.004)
            else:
                u_state = float(np.clip(0.7 * u_state + rng.normal(0, 0.01), -0.03, 0.03))
                u = u_state
            target = earned * (1 + u)
            if completed and m == last_m:
                target = rev_m
            target = max(target, billed_prev)           # cumulative billing never goes down
            amt = round(target - billed_prev, 2)
            billed_prev += amt
            if amt <= 0:
                continue
            ap_no += 1
            age = (AS_OF - pe).days
            st = "Paid" if age > 45 else ("Submitted" if age > 5 else "Draft")
            bill_rows.append(dict(project_id=pid, pay_app_no=ap_no, period_end=pe, invoice_no=f"INV-{pid[2:]}-{ap_no:03d}",
                                  gross_billed=amt, retainage_held=round(amt * 0.10, 2), status=st,
                                  submitted_date=pe + timedelta(days=int(rng.integers(2, 9)))))
    billings = pd.DataFrame(bill_rows)
    billings.insert(0, "billing_id", [f"BL{i + 1:05d}" for i in range(len(billings))])
    billings["billing_id"] = ["PB" + x[2:] for x in billings.billing_id]      # PB = pay bill (avoid clash w/ BL budget ids)
    T["billings_clean"] = billings

    # --- timecards (weekly, field staff)
    weeks = []
    d = date(2024, 10, 5)               # Saturdays
    while d <= AS_OF:
        weeks.append(d)
        d += timedelta(days=7)
    proj_active_weeks = {}
    for pid, meta in proj_meta.items():
        st = month_start(meta["s"])
        en = month_end(min(meta["e"], last_month))
        proj_active_weeks[pid] = (st, en)
    field = employees[employees.is_field == 1]
    tc = []
    for _, emp in field.iterrows():
        bu = emp.business_unit
        bu_projects = [p for p, mt in proj_meta.items() if mt["bu"] == bu]
        assign = None
        cur_q = None
        for wk in weeks:
            q = (wk.year, (wk.month - 1) // 3)
            if q != cur_q:
                cur_q = q
                avail = [p for p in bu_projects if proj_active_weeks[p][0] <= wk <= proj_active_weeks[p][1]]
                if avail:
                    wts = np.array([proj_meta[p]["contract"] for p in avail], dtype=float)
                    assign = str(rng.choice(avail, p=wts / wts.sum()))
                else:
                    assign = None
            if assign is None or not (proj_active_weeks[assign][0] <= wk <= proj_active_weeks[assign][1]):
                continue
            if rng.random() > 0.93:
                continue
            reg = float(rng.choice([32, 36, 40, 40, 40, 40]))
            if month_idx(wk.year, wk.month) in WEATHER_MONTHS.get(assign, []):
                reg = float(rng.choice([16, 24, 32]))
            ot = float(rng.choice([0, 0, 0, 2, 4, 6, 8])) if reg >= 40 else 0.0
            tc.append(dict(employee_id=emp.employee_id, project_id=assign, week_ending=wk,
                           regular_hours=reg, overtime_hours=ot))
    timecards = pd.DataFrame(tc)
    timecards.insert(0, "timecard_id", [f"TC{i + 1:06d}" for i in range(len(timecards))])
    T["timecards_clean"] = timecards

    # --- safety incidents
    hours = timecards.assign(h=timecards.regular_hours + timecards.overtime_hours)
    inc_rows = []
    rates = {"Building": (5, 3, 0.5, 0.12), "Heavy Civil": (6, 4, 0.8, 0.2), "Manufacturing": (4, 5, 0.55, 0.1)}
    types = ["Near Miss", "First Aid", "Recordable", "Lost Time"]
    causes = ["Fall", "Struck-by", "Caught-in", "Strain/Overexertion", "Electrical", "Vehicle/Equipment", "Slip/Trip"]
    for pid, meta in proj_meta.items():
        h = hours[hours.project_id == pid]
        if h.empty:
            continue
        by_week = h.groupby("week_ending").h.sum()
        total = by_week.sum()
        pw = (by_week / total).values
        for t, rate in zip(types, rates[meta["bu"]]):
            n = int(rng.poisson(total / 200000 * rate))
            for _ in range(n):
                wk = by_week.index[int(rng.choice(len(by_week), p=pw))]
                dte = wk - timedelta(days=int(rng.integers(0, 6)))
                emps = h[h.week_ending == wk].employee_id.tolist()
                inc_rows.append(dict(project_id=pid, incident_date=dte, incident_type=t,
                                     cause_category=str(rng.choice(causes)),
                                     employee_id=str(rng.choice(emps)) if emps else None))
    # planted: safety cluster on P-106 (night paving / traffic work Mar-May 2026)
    h106 = hours[hours.project_id == SAFETY_CLUSTER]
    for i, (dte, t, cause) in enumerate([
            (date(2026, 3, 9), "Near Miss", "Struck-by"), (date(2026, 3, 24), "First Aid", "Struck-by"),
            (date(2026, 4, 6), "Recordable", "Struck-by"), (date(2026, 4, 15), "Near Miss", "Vehicle/Equipment"),
            (date(2026, 4, 28), "Lost Time", "Vehicle/Equipment"), (date(2026, 5, 11), "Recordable", "Caught-in"),
            (date(2026, 5, 19), "Recordable", "Struck-by")]):
        wk = dte + timedelta(days=(5 - dte.weekday()) % 7)
        emps = h106[h106.week_ending == wk].employee_id.tolist() or h106.employee_id.tolist()
        inc_rows.append(dict(project_id=SAFETY_CLUSTER, incident_date=dte, incident_type=t, cause_category=cause,
                             employee_id=str(rng.choice(emps))))
    inc = pd.DataFrame(inc_rows).sort_values(["incident_date", "project_id"]).reset_index(drop=True)
    inc["recordable_flag"] = np.where(inc.incident_type.isin(["Recordable", "Lost Time"]), "Y", "N")
    inc["days_away"] = np.where(inc.incident_type == "Lost Time", rng.integers(3, 21, size=len(inc)), 0)
    inc["severity"] = inc.incident_type.map({"Near Miss": 1, "First Aid": 2, "Recordable": 3, "Lost Time": 4})
    inc["description"] = inc.incident_type + " - " + inc.cause_category
    inc.insert(0, "incident_id", [f"SI{i + 1:04d}" for i in range(len(inc))])
    T["safety_incidents_clean"] = inc

    # ---------------- CRM: opportunities and bids ----------------
    stage_prob = {"Lead": .10, "Qualified": .25, "Proposal": .50, "Negotiation": .75, "Won": 1.0, "Lost": 0.0}
    owners = [pick_name(rng) for _ in range(5)]
    opp_rows, bid_rows = [], []
    oid = 0

    def new_opp(name, acct, bu, stage, amount, created, expected, closed, source):
        nonlocal oid
        oid += 1
        return dict(opportunity_id=f"OP{oid:04d}", account_id=acct, opportunity_name=name, business_unit=bu, stage=stage,
                    amount=r2(amount), probability=stage_prob[stage], created_date=created, expected_close_date=expected,
                    closed_date=closed, owner=str(rng.choice(owners)), lead_source=source)

    sources = ["Repeat Client", "Public Bid Notice", "Referral", "Design-Build RFQ", "Trade Show"]
    opp_of_project = {}
    for (pid, name, bu, acct, pmk, (sy, sm), _e, contract, margin, status) in PROJECTS:
        start = date(sy, sm, 1)
        closed = start - timedelta(days=int(rng.integers(30, 75)))
        created = closed - timedelta(days=int(rng.integers(120, 330)))
        o = new_opp(name, acct_id[acct], bu, "Won", contract, created, closed, closed, str(rng.choice(sources)))
        opp_rows.append(o)
        opp_of_project[pid] = o["opportunity_id"]
        bid_rows.append(dict(opportunity_id=o["opportunity_id"], bid_date=closed - timedelta(days=int(rng.integers(14, 45))),
                             bid_amount=contract, estimated_cost=bid_cost_total[pid], competitor_count=int(rng.integers(2, 7)),
                             result="Won", loss_reason=None))
    projects["opportunity_id"] = projects.project_id.map(opp_of_project)
    T["projects"] = projects

    all_acct = accounts.account_id.tolist()
    bus = ["Building", "Heavy Civil", "Manufacturing"]
    bu_w = [0.5, 0.35, 0.15]
    amt_rng = {"Building": (3e6, 18e6), "Heavy Civil": (5e6, 30e6), "Manufacturing": (1e6, 6e6)}
    # awarded but not started (count toward backlog)
    for bu, amt, dd in [("Building", 16.5e6, date(2026, 8, 12)), ("Heavy Civil", 24.0e6, date(2026, 9, 3)), ("Building", 8.2e6, date(2026, 9, 21))]:
        o = new_opp(f"{rng.choice(NAME_PARTS_A)} {bu} Award", str(rng.choice(all_acct)), bu, "Won", amt,
                    dd - timedelta(days=200), dd, dd, str(rng.choice(sources)))
        opp_rows.append(o)
        bid_rows.append(dict(opportunity_id=o["opportunity_id"], bid_date=dd - timedelta(days=25), bid_amount=r2(amt),
                             estimated_cost=r2(amt * 0.9), competitor_count=int(rng.integers(2, 6)), result="Won", loss_reason=None))
    # lost
    loss_reasons = ["Price", "Schedule", "Relationship", "Capacity", "Scope"]
    for _ in range(20):
        bu = str(rng.choice(bus, p=bu_w))
        lo, hi = amt_rng[bu]
        amt = rng.uniform(lo, hi)
        closed = AS_OF - timedelta(days=int(rng.integers(10, 700)))
        o = new_opp(f"{rng.choice(NAME_PARTS_A)} {rng.choice(['Tower', 'Bridge', 'Plant', 'Complex', 'Terminal', 'Hall'])}",
                    str(rng.choice(all_acct)), bu, "Lost", amt, closed - timedelta(days=int(rng.integers(90, 300))), closed, closed,
                    str(rng.choice(sources)))
        opp_rows.append(o)
        bid_rows.append(dict(opportunity_id=o["opportunity_id"], bid_date=closed - timedelta(days=int(rng.integers(10, 40))),
                             bid_amount=r2(amt), estimated_cost=r2(amt * 0.9), competitor_count=int(rng.integers(3, 9)),
                             result="Lost", loss_reason=str(rng.choice(loss_reasons, p=[.5, .1, .15, .1, .15]))))
    # open pipeline
    for stage, n in [("Lead", 10), ("Qualified", 10), ("Proposal", 14), ("Negotiation", 8)]:
        for _ in range(n):
            bu = str(rng.choice(bus, p=bu_w))
            lo, hi = amt_rng[bu]
            amt = rng.uniform(lo, hi)
            created = AS_OF - timedelta(days=int(rng.integers(10, 330)))
            exp = AS_OF + timedelta(days=int(rng.integers(20, 280)))
            o = new_opp(f"{rng.choice(NAME_PARTS_A)} {rng.choice(['Medical Center', 'Roadway', 'Warehouse', 'Campus', 'Levee', 'Panel Supply', 'Hotel'])}",
                        str(rng.choice(all_acct)), bu, stage, amt, created, exp, None, str(rng.choice(sources)))
            o["probability"] = round(float(np.clip(stage_prob[stage] + rng.normal(0, 0.05), 0.05, 0.95)), 2)
            opp_rows.append(o)
            if stage in ("Proposal", "Negotiation"):
                bid_rows.append(dict(opportunity_id=o["opportunity_id"], bid_date=created + timedelta(days=int(rng.integers(30, 120))),
                                     bid_amount=r2(amt), estimated_cost=r2(amt * 0.9), competitor_count=int(rng.integers(2, 7)),
                                     result="Pending", loss_reason=None))
    opps = pd.DataFrame(opp_rows)
    T["opportunities_clean"] = opps
    bids = pd.DataFrame(bid_rows)
    bids.insert(0, "bid_id", [f"BD{i + 1:04d}" for i in range(len(bids))])
    bids["bid_margin_pct"] = ((bids.bid_amount - bids.estimated_cost) / bids.bid_amount).round(4)
    T["bids_clean"] = bids

    T["cost_codes"] = pd.DataFrame([dict(cost_code=c[0], cost_code_name=c[1], category=c[2], division=c[3]) for c in CODES])

    # ---------------- ANSWER KEY (computed from CLEAN data) ----------------
    key = {"as_of": AS_OF.isoformat(), "projects": {}, "portfolio": {}}
    open_stages = ["Lead", "Qualified", "Proposal", "Negotiation"]
    for pid, meta in proj_meta.items():
        pc_ = cos[cos.project_id == pid]
        ap = pc_[pc_.status == "Approved"]
        pend = pc_[pc_.status == "Pending"]
        rev = meta["contract"] + ap.amount.sum()
        actual = float(cost_by_proj[pid])
        e_ = eac[pid]
        pct = min(1.0, actual / e_)
        billed = float(billings[billings.project_id == pid].gross_billed.sum())
        earned = pct * rev
        key["projects"][pid] = dict(
            business_unit=meta["bu"], status=meta["status"],
            original_contract=meta["contract"], approved_co_revenue=r2(ap.amount.sum()), revised_contract=r2(rev),
            original_budget_cost=r2(bid_cost_total[pid]), original_margin=round(meta["margin"], 4),
            actual_cost_to_date=r2(actual), estimate_to_complete=r2(etc_by_proj[pid]), eac=r2(e_),
            pct_complete=round(pct, 4), projected_margin=round((rev - e_) / rev, 4),
            margin_fade_pts=round((meta["margin"] - (rev - e_) / rev) * 100, 2),
            pending_co_revenue=r2(pend.amount.sum()), pending_co_cost=r2(pend.estimated_cost.sum()), pending_co_count=int(len(pend)),
            billed_to_date=r2(billed), earned_revenue=r2(earned), over_under_billing=r2(billed - earned),
            remaining_backlog=r2(max(0.0, rev - earned)) if meta["status"] == "Active" else 0.0)
    act = {k: v for k, v in key["projects"].items() if v["status"] == "Active"}
    opps_open = opps[opps.stage.isin(open_stages)]
    unstarted = opps[(opps.stage == "Won") & (~opps.opportunity_id.isin(projects.opportunity_id))]
    won = int((opps.stage == "Won").sum())
    lost = int((opps.stage == "Lost").sum())
    key["portfolio"] = dict(
        total_actual_cost=r2(costs.amount.sum()),
        total_billed=r2(billings.gross_billed.sum()),
        active_backlog_remaining=r2(sum(v["remaining_backlog"] for v in act.values())),
        awarded_unstarted=r2(unstarted.amount.sum()),
        backlog_total=r2(sum(v["remaining_backlog"] for v in act.values()) + unstarted.amount.sum()),
        weighted_pipeline=r2((opps_open.amount * opps_open.probability).sum()),
        open_pipeline_unweighted=r2(opps_open.amount.sum()),
        win_rate=round(won / (won + lost), 4), won=won, lost=lost,
        pending_co_revenue=r2(sum(v["pending_co_revenue"] for v in key["projects"].values())),
        total_recordables=int((inc.recordable_flag == "Y").sum()),
        total_incidents=int(len(inc)),
        total_hours=r2((timecards.regular_hours + timecards.overtime_hours).sum()),
        fade_top3=sorted(act, key=lambda k: -act[k]["margin_fade_pts"])[:3])
    truth["answer_key"] = key
    return T, truth


# ----------------------------------------------------------------------------
# Defect injection -> RAW layer
# ----------------------------------------------------------------------------
def variants(name):
    """Plausible misspellings / formatting variants of a vendor name."""
    base = name
    v = {base.upper(), re.sub(r"[.,]", "", base), base.replace("&", "and")}
    v.add(re.sub(r"\s+(Inc\.?|LLC|Co\.?)$", "", base))
    v.add(base + " ")
    v.add(re.sub(r"\bCo\.$", "Company", base))
    v.discard(base)
    return sorted(v)


def fmt_mdy(d):
    d = pd.Timestamp(d)
    return f"{d.month:02d}/{d.day:02d}/{d.year}"


def build_raw(T, rng):
    """Return (raw tables dict of DataFrames with str columns, defect log list)."""
    log = []

    def L(table, key, dtype, action, note):
        log.append(dict(table=table, key=str(key), defect_type=dtype, expected_action=action, note=note))

    # ---- actual_costs ----------------------------------------------------
    ac = T["actual_costs_clean"].copy()
    ac["period"] = ac["period"].astype(str)
    ac["amount"] = ac["amount"].astype(object)
    ac["amount"] = ac["amount"].map(lambda x: f"{x:.2f}")
    # fixable: mixed date format
    for i in rng.choice(len(ac), 10, replace=False):
        ac.at[i, "period"] = fmt_mdy(ac.at[i, "period"])
        L("actual_costs", ac.at[i, "cost_id"], "mixed_date_format", "fixed", "period given as MM/DD/YYYY")
    # fixable: currency-formatted amounts
    for i in rng.choice(len(ac), 12, replace=False):
        val = float(ac.at[i, "amount"])
        ac.at[i, "amount"] = f"${val:,.2f}"
        L("actual_costs", ac.at[i, "cost_id"], "currency_string", "fixed", "amount stored as '$1,234.56' text")
    # fixable: cost-code formatting
    for i in rng.choice(len(ac), 15, replace=False):
        code = ac.at[i, "cost_code"]
        ac.at[i, "cost_code"] = [f" {code} ", code.replace("-", ""), code.replace("-", ".")][int(rng.integers(0, 3))]
        L("actual_costs", ac.at[i, "cost_id"], "cost_code_format", "fixed", "cost code has stray spaces / separator")
    # fixable: vendor spelling variants
    vrows = ac.index[ac.vendor_name.notna()].tolist()
    for i in rng.choice(vrows, int(len(vrows) * 0.22), replace=False):
        vs = variants(ac.at[i, "vendor_name"])
        ac.at[i, "vendor_name"] = vs[int(rng.integers(0, len(vs)))]
        L("actual_costs", ac.at[i, "cost_id"], "vendor_spelling", "fixed", "vendor name variant; standardize to canonical")
    # appended bad rows
    extra = []
    nid = len(ac)

    def bad_row(project, code, period, amount, desc, vendor=None):
        nonlocal nid
        nid += 1
        return dict(cost_id=f"AC{nid:06d}", project_id=project, cost_code=code, period=period, amount=f"{amount:.2f}",
                    vendor_name=vendor, source_system="AP", description=desc)

    real_proj = sorted(T["projects"].project_id)
    codes_all = [c[0] for c in CODES]
    for _ in range(22):
        r = bad_row(str(rng.choice(real_proj)), "", month_end(int(rng.integers(0, 22))).isoformat(), rng.uniform(2000, 60000), "Misc invoice - code not entered")
        extra.append(r)
        L("actual_costs", r["cost_id"], "missing_cost_code", "rejected", "blank cost_code; cannot be assigned")
    for _ in range(4):
        r = bad_row(str(rng.choice(real_proj)), str(rng.choice(codes_all)), month_end(int(rng.integers(0, 22))).isoformat(),
                    -rng.uniform(1500, 40000), "Invoice posting", vendor="Gulf Aggregates Inc.")
        extra.append(r)
        L("actual_costs", r["cost_id"], "negative_amount_sign_error", "rejected", "negative amount with no credit-memo reference")
    for pid in ["P-199", "P-199", "P-150", "P-150", "P-199", "P-088", "P-088", "P-150"]:
        r = bad_row(pid, str(rng.choice(codes_all)), month_end(int(rng.integers(0, 22))).isoformat(), rng.uniform(3000, 50000), "Posted to retired job number")
        extra.append(r)
        L("actual_costs", r["cost_id"], "orphan_project_fk", "rejected", f"project_id {pid} not in projects")
    for _ in range(2):
        r = bad_row(str(rng.choice(real_proj)), str(rng.choice(codes_all)), "2027-03-31", rng.uniform(5000, 30000), "Pre-posted accrual")
        extra.append(r)
        L("actual_costs", r["cost_id"], "future_period", "rejected", "period after as-of date 2026-09-30")
    ac = pd.concat([ac, pd.DataFrame(extra)], ignore_index=True).sample(frac=1, random_state=11).reset_index(drop=True)

    # ---- billings ----------------------------------------------------------
    bl = T["billings_clean"].copy()
    for c in ["period_end", "submitted_date", "due_date", "paid_date"]:
        bl[c] = bl[c].map(lambda x: "" if x is None or x is pd.NaT or (isinstance(x, float) and np.isnan(x)) else str(x))
    bl["gross_billed"] = bl["gross_billed"].map(lambda x: f"{x:.2f}")
    bl["retainage_held"] = bl["retainage_held"].map(lambda x: f"{x:.2f}")
    for i in rng.choice(len(bl), 4, replace=False):
        bl.at[i, "period_end"] = fmt_mdy(bl.at[i, "period_end"])
        L("billings", bl.at[i, "billing_id"], "mixed_date_format", "fixed", "period_end given as MM/DD/YYYY")
    dups = bl.sample(6, random_state=21).copy()
    ex = []
    for k, (_, row) in enumerate(dups.iterrows()):
        r = row.to_dict()
        if k >= 3:
            r["billing_id"] = "PB" + f"{9000 + k}"          # re-keyed duplicate: same invoice_no, different id
            L("billings", r["billing_id"], "duplicate_invoice_rekeyed", "deduplicated", f"same invoice_no {r['invoice_no']} as {row.billing_id}")
        else:
            L("billings", r["billing_id"], "duplicate_invoice_exact", "deduplicated", f"exact duplicate of {row.billing_id}")
        ex.append(r)
    r = bl.iloc[0].to_dict()
    r.update(billing_id="PB9100", pay_app_no="99", invoice_no="INV-101-099", gross_billed="-18250.00", retainage_held="-1825.00")
    ex.append(r)
    L("billings", "PB9100", "negative_amount_sign_error", "rejected", "negative gross billing with no credit-memo status")
    bl = pd.concat([bl, pd.DataFrame(ex)], ignore_index=True).sample(frac=1, random_state=12).reset_index(drop=True)

    # ---- change orders -----------------------------------------------------
    co = T["change_orders_clean"].copy()
    co = co[["change_order_id", "project_id", "co_number", "description", "reason", "submitted_date", "decision_date",
             "status", "amount", "estimated_cost"]]
    for c in ["submitted_date", "decision_date"]:
        co[c] = co[c].astype(object).map(lambda x: "" if (x is None or (isinstance(x, float) and np.isnan(x)) or x is pd.NaT) else str(x))
    co["amount"] = co["amount"].map(lambda x: f"{x:.2f}")
    co["estimated_cost"] = co["estimated_cost"].map(lambda x: f"{x:.2f}")
    ex = []
    for k in range(2):
        r = co.iloc[k].to_dict()
        r.update(change_order_id=f"CO-199-{k + 1:03d}", project_id="P-199", co_number=str(k + 1))
        ex.append(r)
        L("change_orders", r["change_order_id"], "orphan_project_fk", "rejected", "project_id P-199 not in projects")
    co = pd.concat([co, pd.DataFrame(ex)], ignore_index=True)

    # ---- commitments: vendor spelling ---------------------------------------
    cm = T["commitments_clean"].copy()
    for i in rng.choice(len(cm), int(len(cm) * 0.25), replace=False):
        vs = variants(cm.at[i, "vendor_name"])
        cm.at[i, "vendor_name"] = vs[int(rng.integers(0, len(vs)))]
        L("commitments", cm.at[i, "commitment_id"], "vendor_spelling", "fixed", "vendor name variant; standardize to canonical")
    for c in ["original_amount", "approved_changes"]:
        cm[c] = cm[c].map(lambda x: f"{x:.2f}")

    # ---- timecards -----------------------------------------------------------
    tc = T["timecards_clean"].copy()
    tc["week_ending"] = tc["week_ending"].astype(str)
    tc["regular_hours"] = tc["regular_hours"].map(lambda x: f"{x:.1f}")
    tc["overtime_hours"] = tc["overtime_hours"].map(lambda x: f"{x:.1f}")
    ex = []
    for k in range(4):
        r = tc.iloc[100 + k].to_dict()
        r.update(timecard_id=f"TC9{k:05d}", employee_id=f"E9{k + 1:03d}")
        ex.append(r)
        L("timecards", r["timecard_id"], "orphan_employee_fk", "rejected", f"employee_id {r['employee_id']} not in employees")
    for k in range(3):
        r = tc.iloc[200 + k].to_dict()
        r.update(timecard_id=f"TC9{10 + k:05d}", regular_hours=str([400.0, 140.0, 96.0][k]))
        ex.append(r)
        L("timecards", r["timecard_id"], "hours_out_of_range", "rejected", "regular_hours above 80 per week")
    tc = pd.concat([tc, pd.DataFrame(ex)], ignore_index=True)

    # ---- safety incidents ------------------------------------------------------
    si = T["safety_incidents_clean"].copy()
    si["incident_date"] = si["incident_date"].astype(str)
    si["employee_id"] = si["employee_id"].fillna("")
    r = si.iloc[0].to_dict()
    r.update(incident_id="SI9001", project_id="P-199")
    si = pd.concat([si, pd.DataFrame([r])], ignore_index=True)
    L("safety_incidents", "SI9001", "orphan_project_fk", "rejected", "project_id P-199 not in projects")

    # ---- opportunities / bids --------------------------------------------------
    op = T["opportunities_clean"].copy()
    for c in ["created_date", "expected_close_date", "closed_date"]:
        op[c] = op[c].astype(object).map(lambda x: "" if x is None or x is pd.NaT or (isinstance(x, float) and np.isnan(x)) else str(x))
    neg = op.index[op.stage == "Negotiation"].tolist()
    for i in neg[:4]:
        op.at[i, "stage"] = ["negotiation", "Neg.", "NEGOTIATION", "Negotiation "][neg.index(i) % 4]
        L("opportunities", op.at[i, "opportunity_id"], "stage_spelling", "fixed", "stage label variant; standardize")
    r = op.iloc[-1].to_dict()
    r.update(opportunity_id="OP9001", account_id="A999")
    op = pd.concat([op, pd.DataFrame([r])], ignore_index=True)
    L("opportunities", "OP9001", "orphan_account_fk", "rejected", "account_id A999 not in accounts")

    bd = T["bids_clean"].copy()
    bd["bid_date"] = bd["bid_date"].astype(str)
    ex = []
    for k in range(2):
        r = bd.iloc[k].to_dict()
        r.update(bid_id=f"BD9{k:03d}", opportunity_id=f"OP99{k:02d}")
        ex.append(r)
        L("bids", r["bid_id"], "orphan_opportunity_fk", "rejected", f"opportunity_id {r['opportunity_id']} not in opportunities")
    bd = pd.concat([bd, pd.DataFrame(ex)], ignore_index=True)

    # ---- plain tables ------------------------------------------------------------
    projects = T["projects"].copy()
    employees = T["employees"].copy()
    accounts = T["accounts"].copy()
    budget = T["budget_lines"].copy()
    for c in ["original_budget", "approved_co_budget", "revised_budget", "estimate_to_complete"]:
        budget[c] = budget[c].map(lambda x: f"{x:.2f}")
    cost_codes = T["cost_codes"].copy()

    raw = {
        "projects": projects, "cost_codes": cost_codes, "budget_lines": budget, "commitments": cm,
        "actual_costs": ac, "change_orders": co, "billings": bl, "timecards": tc, "employees": employees,
        "safety_incidents": si, "accounts": accounts, "opportunities": op, "bids": bd,
    }
    raw = {k: v.astype(object).where(pd.notna(v), "") for k, v in raw.items()}
    return raw, log


def write_defect_docs(log, out_md):
    df = pd.DataFrame(log)
    summary = df.groupby(["table", "defect_type", "expected_action"]).size().reset_index(name="rows")
    lines = ["# Planted data-quality defects (answer key for the DQ checks)", "",
             "> **Synthetic data.** Generated by `src/generate_data.py`; do not edit by hand (this file is overwritten on every run).", "",
             "Each defect below is deliberately injected into the **raw** layer. Defects marked *fixed* are representation problems "
             "that staging repairs without changing the underlying value. Defects marked *rejected* or *deduplicated* are extra rows "
             "that staging must remove or quarantine into the `rejects` table. Because bad rows are appended rather than substituted, "
             "the cleaned marts must reconcile **exactly** to the clean answer key in `data/truth/answer_key.json`.", "",
             f"Total planted defect rows: **{len(df)}**", "",
             "| Table | Defect type | Expected staging action | Rows |", "|---|---|---|---:|"]
    for _, r in summary.iterrows():
        lines.append(f"| {r.table} | {r.defect_type} | {r.expected_action} | {r.rows} |")
    lines += ["", "## Staging rules these defects exercise", "",
              "- **Fixed:** parse `MM/DD/YYYY` dates; strip `$` and commas from amounts; normalise cost codes to `NN-NNN`; standardise vendor names "
              "(case, punctuation, `&`/`and`, legal suffix) to the most common spelling; standardise opportunity stage labels.",
              "- **Deduplicated:** keep the first row per (`project_id`, `invoice_no`) in billings.",
              "- **Rejected (quarantined, never silently dropped):** blank cost code, negative amount with no credit-memo marker, "
              "orphaned foreign keys, period after the as-of date, weekly hours above 80.",
              "- **Kept on purpose:** negative cost rows described as *Vendor credit memo* (three vendor credits plus closeout true-ups on completed jobs) are legitimate and must survive staging.",
              "", "Row-level detail: `data/truth/planted_defects.json`.", ""]
    Path(out_md).write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--out", default="data/raw")
    ap.add_argument("--truth", default="data/truth")
    ap.add_argument("--docs", default="docs")
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    T, truth = generate_clean(rng)
    from generate_erp_extension import build_raw_extension, generate_extension
    truth["answer_key"]["erp"] = generate_extension(T, np.random.default_rng(a.seed + 2))   # own RNG stream: core data unchanged
    raw, log = build_raw(T, np.random.default_rng(a.seed + 1))
    raw_x, log_x = build_raw_extension(T, np.random.default_rng(a.seed + 3))
    raw.update(raw_x)
    log.extend(log_x)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, df in raw.items():
        df.to_csv(out / f"{name}.csv", index=False)
    tdir = Path(a.truth)
    tdir.mkdir(parents=True, exist_ok=True)
    (tdir / "answer_key.json").write_text(json.dumps(truth["answer_key"], indent=2, default=str))
    (tdir / "planted_defects.json").write_text(json.dumps(log, indent=2))
    Path(a.docs).mkdir(parents=True, exist_ok=True)
    write_defect_docs(log, Path(a.docs) / "planted_defects.md")
    print(f"seed={a.seed}  tables={len(raw)}  rows=" + ", ".join(f"{k}:{len(v)}" for k, v in raw.items()))
    print(f"planted defect rows: {len(log)}")


if __name__ == "__main__":
    main()
