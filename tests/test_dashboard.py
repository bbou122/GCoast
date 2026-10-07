"""
Dashboard tests (headless Chromium via Playwright).

 1. No JavaScript errors for any role x page.
 2. The numbers the page computes for the Executive role equal the SQL metric layer (v_portfolio_kpis).
 3. Each role's restrictions really remove data from what the page holds and renders.
 4. Phone width: no horizontal page scroll; synthetic-data banner present on every page.
 5. The file is self-contained (no external requests).

Run:  python tests/test_dashboard.py        (needs: pip install playwright; python -m playwright install chromium)
SYNTHETIC DATA ONLY.
"""
import json
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
HTML = ROOT / "docs" / "index.html"
URL = HTML.as_uri()
ROLES = ["exec", "fin", "bu|Building", "bu|Heavy Civil", "bu|Manufacturing", "pm|Joshua Garcia", "pm|Michelle Walker",
         "pm|Brian Robichaux", "pm|Terrence Martin", "pm|Elizabeth Jones"]
PAGES = ["exec", "projects", "proc", "cash", "field", "pipeline", "quality"]


def setrole(pg, role, page="exec"):
    pg.evaluate(f"()=>{{const s=document.getElementById('role'); s.value={json.dumps(role)}; s.onchange(); window.__GCB.go({json.dumps(page)});}}")


def main():
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("SKIP: playwright not installed")
        return 0
    from collections import defaultdict
    errors, results = [], defaultdict(dict)
    con = duckdb.connect(str(ROOT / "data/warehouse.duckdb"), read_only=True)
    k = con.sql("select * from metrics.v_portfolio_kpis").df().iloc[0]
    D = json.load(open(ROOT / "data/dashboard_data.json"))
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1366, "height": 900})
        pg.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        pg.on("pageerror", lambda e: errors.append(str(e)))
        reqs = []
        pg.on("request", lambda r: reqs.append(r.url) if not r.url.startswith(("file:", "data:")) else None)
        pg.goto(URL)
        # 1 + 4 (banner): every role x page renders without errors
        for r in ROLES:
            for page in PAGES:
                setrole(pg, r, page)
                assert pg.inner_text(".banner").startswith("SYNTHETIC DATA"), "banner missing"
                assert pg.evaluate("document.getElementById('main').innerText.length") > 150, (r, page)
        assert not errors, errors[:5]
        assert not reqs, f"external requests: {reqs}"
        print(f"PASS  no JS errors, banner present, no external requests ({len(ROLES) * len(PAGES)} role x page renders)")

        # 2 page numbers == SQL
        setrole(pg, "exec")
        kk = pg.evaluate("window.__GCB.kpis")
        checks = [("contract", k.active_contract_value), ("margin", k.portfolio_projected_margin), ("bidMargin", k.portfolio_bid_margin),
                  ("backlog", k.total_backlog), ("weighted", k.weighted_pipeline), ("winRate", k.win_rate), ("coverage", k.pipeline_coverage),
                  ("pendingCo", k.pending_co_revenue), ("top3Share", k.top3_share_of_fade), ("trir12", k.trir_12m),
                  ("openPoValue", k.open_po_value), ("overduePoAmt", k.overdue_po_amount), ("onTime", k.on_time_delivery_rate),
                  ("rniAmt", k.received_not_invoiced_amount), ("apOpen", k.ap_open), ("apOverdue", k.ap_overdue),
                  ("arOpen", k.ar_open), ("arOverdue", k.ar_overdue), ("ar90", k.ar_over_90), ("retRecv", k.retainage_receivable),
                  ("retPay", k.retainage_payable), ("util", k.equipment_utilization), ("idle", k.rented_idle_cost)]
        bad = []
        for key, want in checks:
            got = kk[key]
            if abs(got - float(want)) > max(0.01, 1e-6 * abs(float(want))):
                bad.append((key, got, float(want)))
        assert not bad, f"page differs from SQL: {bad}"
        for key, want in [("late", k.jobs_late), ("atRisk", k.jobs_at_risk), ("rfiOverdue", k.rfis_overdue), ("overduePoLines", k.overdue_po_lines)]:
            assert kk[key] == want, (key, kk[key], want)
        txt = pg.text_content("#main")
        for must in ["margin", "P-107", "P-103", "P-110", "P-106", "P-104", "P-109", "P-105", "P-108", "Pelican Metal Works", "Crescent Steel Supply deliveries to P-102"]:
            assert must.lower() in txt.lower(), f"planted story missing from Executive 'Needs attention': {must}"
        print(f"PASS  {len(checks) + 4} Executive numbers computed in the browser equal the SQL metric layer; planted stories appear in 'Needs attention'")

        # 3 role restrictions
        all_pids = {r["project_id"] for r in D["projects"]}
        for r in ROLES:
            setrole(pg, r, "field")
            sc = pg.evaluate("({ids:[...window.__GCB.scope.ids], safety:window.__GCB.scope.safety, sd:window.__GCB.scope.safety_detail.length, "
                             "pl:window.__GCB.scope.pipeline_by_bu.length, bl:window.__GCB.scope.backlog.length, "
                             "pages:window.__GCB.scope.pages, proj:window.__GCB.scope.projects.map(p=>p.business_unit+'|'+p.project_manager), "
                             "po:[...new Set(window.__GCB.scope.po_lines.map(x=>x.project_id))], "
                             "fields:Object.keys(window.__GCB.scope.projects[0]||{}), inv:window.__GCB.scope.inventory.length})")
            text = pg.inner_text("#main")
            results[r] = sc
            kind = r.split("|")[0]
            if kind == "exec":
                assert set(sc["ids"]) == all_pids and sc["safety"] and sc["pl"] == 3
            if kind == "fin":
                assert set(sc["ids"]) == all_pids and sc["sd"] == 0 and not sc["safety"]
                assert "trir_12m" not in sc["fields"] and "incidents_all" not in sc["fields"]
                assert "Recent incidents" not in text and "Struck-by" not in text and "Injury rate by job" not in text
                assert "not available to the Finance role" in text
            if kind == "bu":
                bu = r.split("|")[1]
                assert sc["ids"] and all(x.split("|")[0] == bu for x in sc["proj"]), r
                assert sc["pl"] == 1 and set(sc["po"]) <= set(sc["ids"])
                other = {x["project_id"] for x in D["projects"] if x["business_unit"] != bu}
                assert not (set(sc["ids"]) & other)
                assert (sc["inv"] > 0) == (bu == "Manufacturing"), (r, sc["inv"])
            if kind == "pm":
                pm = r.split("|")[1]
                assert sc["ids"] and all(x.split("|")[1] == pm for x in sc["proj"]), r
                assert "pipeline" not in sc["pages"] and sc["pl"] == 0
                assert set(sc["po"]) <= set(sc["ids"])
                setrole(pg, r, "pipeline")  # a hidden page cannot be reached
                assert pg.evaluate("window.__GCB.state.page") == "exec"
                assert not pg.query_selector("button[data-p=pipeline]")
        # sub-ledgers are scoped too: vendor and AR data for a PM contain only that PM's projects
        setrole(pg, "pm|Joshua Garcia")
        s = pg.evaluate("({ids:[...window.__GCB.scope.ids], ar:window.__GCB.scope.ar_open.map(x=>x.project_id), ap:window.__GCB.scope.ap_open.map(x=>x.project_id), eq:window.__GCB.scope.equipment.map(x=>x.project_id)})")
        assert set(s["ar"] + s["ap"] + s["eq"]) <= set(s["ids"])
        # the project drill-down selector lists only projects in scope
        setrole(pg, "pm|Elizabeth Jones", "projects")
        opts = pg.eval_on_selector_all("#pp option", "o=>o.map(x=>x.value)")
        assert set(opts) == set(results["pm|Elizabeth Jones"]["ids"]), opts
        # BU lead of Building must not see the Manufacturing plant stock page content
        setrole(pg, "bu|Building", "proc")
        assert "Plant items below reorder" not in pg.inner_text("#main")
        print(f"PASS  role restrictions: {len(ROLES)} roles checked (rows, pages, fields and rendered text)")

        # 4 phone: no horizontal scroll
        ph = b.new_page(viewport={"width": 390, "height": 844})
        ph.goto(URL)
        wide = []
        for r in ["exec", "pm|Joshua Garcia"]:
            for page in PAGES:
                setrole(ph, r, page)
                ph.wait_for_timeout(50)
                sw = ph.evaluate("document.documentElement.scrollWidth")
                if sw > 392:
                    wide.append((r, page, sw))
        assert not wide, f"horizontal overflow at phone width: {wide}"
        print("PASS  no horizontal page scroll at 390 px width")
        b.close()
    json.dump(results, open(ROOT / "data" / "role_scope_summary.json", "w"), indent=1)
    print("\nAll dashboard tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
