"""
Negative tests: prove the data-quality suite really catches broken data and that
run_checks returns exit code 1 (the build must stop). We corrupt COPIES of the
warehouse in specific ways and assert the expected critical checks FAIL.

Run:  python tests/test_checks_fail_loudly.py      (or: pytest tests)
SYNTHETIC DATA ONLY.
"""
import shutil
import sys
import tempfile
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from run_checks import run_checks  # noqa: E402

DB = ROOT / "data" / "warehouse.duckdb"

CASES = {
    "duplicate invoice survives staging": (
        "INSERT INTO stg.billings SELECT * FROM stg.billings LIMIT 1", {"STG-002", "STG-003"}),
    "orphan project reaches staging": (
        "INSERT INTO stg.actual_costs SELECT * REPLACE ('P-999' AS project_id, 'ACX' AS cost_id) FROM stg.actual_costs LIMIT 1", {"STG-020"}),
    "cost row lost between staging and mart": (
        "DELETE FROM mart.fact_cost WHERE cost_id = (SELECT MIN(cost_id) FROM mart.fact_cost)", {"MRT-010", "MRT-011", "MRT-012"}),
    "bad domain value": (
        "UPDATE stg.projects SET status = 'Done' WHERE project_id = 'P-101'", {"STG-046"}),
    "unexplained negative cost": (
        "UPDATE stg.actual_costs SET amount = -amount WHERE cost_id = (SELECT MIN(cost_id) FROM stg.actual_costs WHERE amount > 0)", {"STG-040"}),
    "rejected row silently dropped": (
        "DELETE FROM stg.rejects WHERE source_table = 'actual_costs' AND reject_reason = 'future_period'", {"STG-060", "STG-062", "STG-064", "MRT-012"}),
    "confidential column leaks into mart": (
        "ALTER TABLE mart.dim_employee ADD COLUMN hourly_rate DECIMAL(10,2)", {"MRT-006"}),
    "receipt for a PO line that does not exist": (
        "INSERT INTO mart.fact_receipt SELECT * REPLACE ('POL99999' AS po_line_id, 'RCX' AS receipt_id) FROM mart.fact_receipt LIMIT 1", {"MRT-051"}),
    "duplicate PO line survives": (
        "INSERT INTO mart.fact_purchase_order SELECT * FROM mart.fact_purchase_order LIMIT 1", {"MRT-050"}),
    "unknown vendor spelling reaches staging": (
        "UPDATE stg.purchase_orders SET vendor_std = 'Pelican Metalworks' WHERE po_line_id = (SELECT MIN(po_line_id) FROM stg.purchase_orders)", {"STG-070"}),
    "negative stock on hand": (
        "UPDATE stg.inventory_items SET on_hand_qty = -5 WHERE item_id = (SELECT MIN(item_id) FROM stg.inventory_items)", {"STG-071"}),
    "pay application lost from the mart": (
        "DELETE FROM mart.fact_sub_pay_app WHERE sub_pay_app_id = (SELECT MIN(sub_pay_app_id) FROM mart.fact_sub_pay_app)", {"MET-023"}),
    "metric fan-out": (
        "INSERT INTO mart.fact_budget SELECT * FROM mart.fact_budget LIMIT 1", {"MRT-002", "MRT-010", "MRT-015"}),
}


def test_clean_warehouse_passes():
    assert run_checks(DB, quiet=True) == 0


def test_corruptions_are_caught():
    for name, (sql, expected) in CASES.items():
        with tempfile.TemporaryDirectory() as td:
            cp = Path(td) / "w.duckdb"
            shutil.copy(DB, cp)
            con = duckdb.connect(str(cp))
            con.execute(sql)
            con.close()
            rc = run_checks(cp, quiet=True)
            con = duckdb.connect(str(cp), read_only=True)
            failed = {r[0] for r in con.execute("select check_id from ops.dq_results where status='FAIL'").fetchall()}
            con.close()
            assert rc == 1, f"{name}: run_checks should return 1, got {rc}"
            assert expected <= failed, f"{name}: expected {expected} to fail, failed={failed}"
            print(f"CAUGHT  {name:45s} -> {sorted(failed)}")


if __name__ == "__main__":
    test_clean_warehouse_passes()
    test_corruptions_are_caught()
    print("\nAll negative tests passed")
