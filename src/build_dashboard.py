"""
Assemble docs/index.html: one self-contained file (Chart.js inlined, data embedded as JSON).

Run:  python src/build_dashboard.py     (after build_warehouse, run_checks and export_dashboard_data)
SYNTHETIC DATA ONLY.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
tpl = (ROOT / "src" / "dashboard_template.html").read_text(encoding="utf-8")
chart = (ROOT / "vendor" / "chart.umd.js").read_text(encoding="utf-8")
data = (ROOT / "data" / "dashboard_data.json").read_text(encoding="utf-8")

# a literal "</script" or "<!--" inside embedded text would end the script block early
safe = lambda s: s.replace("</", "<\\/").replace("<!--", "<\\!--")
html = tpl.replace("<script>/*__CHARTJS__*/</script>", "<script>" + safe(chart) + "</script>")
html = html.replace("const D = /*__DATA__*/;", "const D = " + safe(data) + ";")
assert "__CHARTJS__" not in html and "__DATA__" not in html
out = ROOT / "docs" / "index.html"
out.write_text(html, encoding="utf-8")
print(f"wrote {out.relative_to(ROOT)}  {out.stat().st_size/1e6:.2f} MB (self-contained, no external requests)")
assert not re.search(r'(src|href)="https?://', html), "dashboard must not load external resources"
