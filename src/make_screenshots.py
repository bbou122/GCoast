"""
Take the screenshots used in the README and verification report (optional; needs Playwright + Chromium).
Run:  python src/make_screenshots.py          -> docs/screenshots/
SYNTHETIC DATA ONLY.
"""
from pathlib import Path
from urllib.parse import quote

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshots"
URL = (ROOT / "docs" / "index.html").as_uri()
PAGES = ["exec", "projects", "proc", "cash", "field", "pipeline", "quality"]


def shot(ctx, name, page, role="exec", theme="light"):
    pg = ctx.new_page()
    pg.goto(f"{URL}?page={page}&theme={theme}&role={quote(role)}")
    pg.wait_for_timeout(500)
    pg.screenshot(path=str(OUT / f"{name}.png"), full_page=True)
    pg.close()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*.png"):
        f.unlink()
    with sync_playwright() as p:
        b = p.chromium.launch()
        desk = b.new_context(viewport={"width": 1366, "height": 900})
        phone = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True)
        for pg in PAGES:
            shot(desk, f"desktop_{pg}_light", pg)
            shot(phone, f"phone_{pg}_light", pg)
        for pg in ["exec", "cash", "quality"]:
            shot(desk, f"desktop_{pg}_dark", pg, theme="dark")
        shot(phone, "phone_exec_dark", "exec", theme="dark")
        shot(desk, "role_finance_field", "field", role="fin")
        shot(desk, "role_pm_joshua_garcia_exec", "exec", role="pm|Joshua Garcia")
        shot(desk, "role_bu_manufacturing_proc", "proc", role="bu|Manufacturing")
        b.close()
    files = sorted(OUT.glob("*.png"))
    print(f"wrote {len(files)} screenshots, {sum(f.stat().st_size for f in files)/1e6:.1f} MB")


if __name__ == "__main__":
    main()
