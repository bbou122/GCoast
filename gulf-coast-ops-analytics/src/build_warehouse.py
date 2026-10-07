#!/usr/bin/env python3
"""
Build the DuckDB warehouse: raw -> staging -> marts -> metric views.

SYNTHETIC DATA ONLY (Gulf Coast Builders is fictional).

Executes, in order:  sql/01_raw.sql, 02_staging.sql, 03_marts.sql, 05_metrics.sql
(04_quality_checks.sql is run afterwards by src/run_checks.py because it also
reconciles the metric views.)

Usage:  python src/build_warehouse.py [--raw data/raw] [--db data/warehouse.duckdb] [--as-of 2026-09-30]
"""
import argparse
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
BUILD_ORDER = ["01_raw.sql", "02_staging.sql", "03_marts.sql", "05_metrics.sql"]


def render(sql_text: str, params: dict) -> str:
    for k, v in params.items():
        sql_text = sql_text.replace("{{" + k + "}}", str(v))
    return sql_text


def run_file(con, path: Path, params: dict):
    sql = render(path.read_text(), params)
    try:
        con.execute(sql)
    except Exception as exc:                                    # fail loudly, name the file
        print(f"\nBUILD FAILED in {path.name}: {exc}", file=sys.stderr)
        raise SystemExit(2)


def build(raw_dir: Path, db_path: Path, as_of: str) -> duckdb.DuckDBPyConnection:
    if db_path.exists():
        db_path.unlink()
    wal = Path(str(db_path) + ".wal")
    if wal.exists():
        wal.unlink()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(db_path))
    params = {"RAW_DIR": raw_dir.resolve().as_posix(), "AS_OF": as_of}
    for name in BUILD_ORDER:
        p = ROOT / "sql" / name
        if not p.exists():
            print(f"skipping missing {name}")
            continue
        run_file(con, p, params)
        print(f"  ran {name}")
    return con


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=str(ROOT / "data" / "raw"))
    ap.add_argument("--db", default=str(ROOT / "data" / "warehouse.duckdb"))
    ap.add_argument("--as-of", default="2026-09-30")
    a = ap.parse_args()
    con = build(Path(a.raw), Path(a.db), a.as_of)
    for t in ["stg.rejects", "mart.fact_cost"]:
        try:
            print(f"  {t}: {con.execute(f'select count(*) from {t}').fetchone()[0]} rows")
        except Exception:
            pass
    con.close()
    print("warehouse built:", a.db)


if __name__ == "__main__":
    main()
