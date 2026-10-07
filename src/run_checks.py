#!/usr/bin/env python3
"""
Run the data-quality checks (sql/04_quality_checks.sql) against the warehouse and
FAIL LOUDLY if any critical check fails.

SYNTHETIC DATA ONLY (Gulf Coast Builders is fictional).

Exit codes:  0 = no critical failures    1 = at least one critical check FAILED    2 = could not run checks

Usage:  python src/run_checks.py [--db data/warehouse.duckdb] [--quiet]
"""
import argparse
import sys
import uuid
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent


def run_checks(db_path: Path, quiet: bool = False) -> int:
    con = duckdb.connect(str(db_path))
    run_id = uuid.uuid4().hex[:12]
    sql = (ROOT / "sql" / "04_quality_checks.sql").read_text().replace("{{RUN_ID}}", run_id)
    try:
        con.execute(sql)
    except Exception as exc:
        print(f"\nCHECKS COULD NOT RUN: {exc}", file=sys.stderr)
        return 2

    rows = con.execute(
        """SELECT check_id, layer, check_name, severity, status, rows_affected, description, detail
           FROM ops.dq_results WHERE run_id = ? ORDER BY check_id""", [run_id]).fetchall()
    counts = {}
    for r in rows:
        counts[r[4]] = counts.get(r[4], 0) + 1

    if not quiet:
        print(f"\nData-quality run {run_id}   ({len(rows)} checks)")
        print(f"{'ID':8} {'LAYER':8} {'STATUS':5} {'ROWS':>6}  CHECK")
        for cid, layer, name, sev, status, n, desc, detail in rows:
            if status in ("PASS",) and quiet:
                continue
            print(f"{cid:8} {layer:8} {status:5} {n:>6}  {name}" + (f"   [{detail}]" if detail and status != "PASS" else ""))
    summary = "  ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"\nSummary: {summary}")

    failed = [r for r in rows if r[4] == "FAIL"]
    if failed:
        bar = "!" * 78
        print(f"\n{bar}\nBUILD FAILED: {len(failed)} critical data-quality check(s) failed. Do NOT publish this refresh.\n{bar}", file=sys.stderr)
        for cid, layer, name, sev, status, n, desc, detail in failed:
            print(f"  {cid} {name}: {n} violation(s) - {desc}" + (f" [{detail}]" if detail else ""), file=sys.stderr)
        con.close()
        return 1
    con.close()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=str(ROOT / "data" / "warehouse.duckdb"))
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    sys.exit(run_checks(Path(a.db), a.quiet))


if __name__ == "__main__":
    main()
