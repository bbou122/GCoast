# Runbook

> **Synthetic data.** Gulf Coast Builders is fictional. This runbook describes how the pipeline would be operated.

## Everyday commands

| Task | Command |
|---|---|
| Full rebuild (data exists) with all tests | `python run_all.py` |
| Fast rebuild, no tests | `python run_all.py --skip-tests` |
| Regenerate the synthetic data too | `python run_all.py --regen` |
| Only rebuild the warehouse | `python src/build_warehouse.py` |
| Only run data-quality checks | `python src/run_checks.py` (exit 0 pass, 1 critical failure, 2 could not run) |
| Run one test file | `python tests/test_planted_defects.py` |
| Look at the warehouse | `python -c "import duckdb; duckdb.connect('data/warehouse.duckdb', read_only=True).sql('select * from metrics.v_portfolio_kpis').show()"` |

The order matters and `run_all.py` enforces it: generate, build, **checks**, tests, export, dashboard, alerts, dictionary. The dashboard is only rebuilt after the checks pass.

## What a refresh does

1. Raw CSVs are loaded as text into `raw` (a bad value can never break the load).
2. Staging types and cleans them, standardises vendor names, removes duplicates, and moves unusable rows to `stg.rejects` with one reason each.
3. Marts build the star schema; metric views compute every number.
4. `sql/04_quality_checks.sql` writes one row per check to `ops.dq_results`.
5. If any **critical** check fails, `run_checks.py` prints a banner and exits 1; `run_all.py` stops, and the previous dashboard stays in place. Do not publish a refresh that failed.

## When a check fails

| Check family | Meaning | First action |
|---|---|---|
| `RAW-001` | A source table arrived empty | Check the extract job; do not rebuild until the source is fixed |
| `STG-0xx` keys, references, ranges | Bad rows got through staging | Query `stg.rejects` and the offending table; add or fix a rule in `02_staging.sql` |
| `STG-06x` reconciliation | Rows or dollars disappeared between raw and staging | Compare `ops.staging_audit` (raw = kept + rejected); a gap means a rule is dropping rows silently |
| `MRT-0xx` | A mart join lost or duplicated rows, or a confidential column appeared | Check the join keys in `03_marts.sql`; for `MRT-006` remove the column |
| `MET-0xx` | A metric no longer reconciles to its source | Compare the view to the staging total named in the check; look for join fan-out |
| `BIZ-0xx` (INFO) | Business exceptions (overdue orders, uninvoiced receipts ...) | Not build failures; these feed the alert report |

To investigate: `select * from ops.dq_results where status <> 'PASS' order by check_id;` The `description` column says what the check asserts and `rows_affected` how many records violate it.

## Common problems

| Symptom | Cause and fix |
|---|---|
| `BUILD FAILED in 0x_*.sql: ...` | The message names the file and SQL error; fix and rerun `build_warehouse.py` |
| Checks cannot run, "table ops.dq_results does not exist" | The build deletes the database each time; run the build, then the checks, then the export |
| `IOException ... database is locked` | Another process has `warehouse.duckdb` open (a notebook or shell); close it |
| Browser tests skipped | Install Playwright: `pip install -r requirements-dev.txt && python -m playwright install chromium` |
| Dashboard looks stale | Re-run `python run_all.py`; the page shows its generation time in the header |
| Numbers differ from earlier runs | Only if the seed or generator changed; the default seed `20260930` is deterministic |

## Changing things safely

- **Add a metric:** create a view in `sql/05_metrics.sql` with its formula in the comment above it, add a reconciliation check in `04_quality_checks.sql`, document it in `docs/metric_definitions.md`, and add an answer-key or recompute test.
- **Add a source table:** raw load in `01_raw.sql`, cleaning and a reject rule in `02_staging.sql` (also add it to `ops.staging_audit`), mart table in `03_marts.sql`, checks, then the generator if you want a planted defect for it.
- **Change a threshold** (overdue days, billing balance, cluster size): parameters live in `ops.etl_params` and at the top of `src/weekly_alerts.py`. Update `docs/metric_definitions.md` in the same change.
- **After any change:** `python run_all.py`. All three test suites and the dashboard tests must pass.

## Weekly automation

`.github/workflows/weekly-refresh.yml` runs on Mondays at 12:00 UTC (and on demand and on pull requests): it rebuilds from scratch, runs everything, uploads the dashboard and alert report as a build artifact, and, on schedule or manual runs, commits the refreshed `docs/index.html`, `docs/data_dictionary.md`, `docs/planted_defects.md` and `alerts/weekly_flagged_jobs.md`. A failed critical check fails the job and nothing is committed. Use the Actions tab to rerun or to download the artifact.

## Publishing

See "Publish on GitHub Pages" in the README. Roll back by reverting the commit that changed `docs/index.html`.

## Ownership (fictional example)

| Item | Owner |
|---|---|
| Source extracts | ERP / CRM administrators |
| Staging rules and checks | Analytics engineering |
| Metric definitions | Finance and operations leads sign off |
| Dashboard and alerts | Analytics |
| Access matrix | Data owner with IT security |
