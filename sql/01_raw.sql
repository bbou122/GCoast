-- =============================================================================
-- 01_raw.sql   LAYER: RAW
-- SYNTHETIC DATA: Gulf Coast Builders is a fictional company.
--
-- Loads the simulated ERP / CRM exports exactly as delivered. Every column is
-- VARCHAR (all_varchar = true): typing, cleaning and validation happen in
-- staging, so a bad value can never make the load itself fail.
--
-- Placeholders substituted by src/build_warehouse.py:
--   {{RAW_DIR}}  folder holding the CSV exports
--   {{AS_OF}}    reporting as-of date (YYYY-MM-DD)
--
-- SNOWFLAKE: replace read_csv(...) with  COPY INTO raw.<table> FROM @raw_stage
--   FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"')
--   into tables created with VARCHAR columns. Everything below the loads is portable.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS raw;       -- source exports, untouched
CREATE SCHEMA IF NOT EXISTS stg;       -- cleaned and typed
CREATE SCHEMA IF NOT EXISTS mart;      -- star schema
CREATE SCHEMA IF NOT EXISTS metrics;   -- one view per business metric
CREATE SCHEMA IF NOT EXISTS ops;       -- run parameters, audit, data-quality results

-- One place for run-level parameters. Every view reads the as-of date from here
-- so results are reproducible (a live warehouse would use CURRENT_DATE instead).
CREATE OR REPLACE TABLE ops.etl_params AS
SELECT CAST('{{AS_OF}}' AS DATE) AS as_of_date,
       0.02                      AS billing_balance_threshold,   -- |over/under| below 2% of contract = "Balanced"
       5                         AS safety_cluster_min_incidents, -- incidents inside any 90-day window to flag a cluster
       90                        AS safety_cluster_window_days;

-- ERP ------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw.projects         AS SELECT * FROM read_csv('{{RAW_DIR}}/projects.csv',         header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.cost_codes       AS SELECT * FROM read_csv('{{RAW_DIR}}/cost_codes.csv',       header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.budget_lines     AS SELECT * FROM read_csv('{{RAW_DIR}}/budget_lines.csv',     header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.commitments      AS SELECT * FROM read_csv('{{RAW_DIR}}/commitments.csv',      header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.actual_costs     AS SELECT * FROM read_csv('{{RAW_DIR}}/actual_costs.csv',     header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.change_orders    AS SELECT * FROM read_csv('{{RAW_DIR}}/change_orders.csv',    header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.billings         AS SELECT * FROM read_csv('{{RAW_DIR}}/billings.csv',         header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.timecards        AS SELECT * FROM read_csv('{{RAW_DIR}}/timecards.csv',        header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.employees        AS SELECT * FROM read_csv('{{RAW_DIR}}/employees.csv',        header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.safety_incidents AS SELECT * FROM read_csv('{{RAW_DIR}}/safety_incidents.csv', header = true, all_varchar = true);

-- CRM ------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw.accounts         AS SELECT * FROM read_csv('{{RAW_DIR}}/accounts.csv',         header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.opportunities    AS SELECT * FROM read_csv('{{RAW_DIR}}/opportunities.csv',    header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.bids             AS SELECT * FROM read_csv('{{RAW_DIR}}/bids.csv',             header = true, all_varchar = true);

-- ERP expansion: procurement, subcontract pay, field operations ------------------
CREATE OR REPLACE TABLE raw.vendors               AS SELECT * FROM read_csv('{{RAW_DIR}}/vendors.csv',               header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.purchase_orders       AS SELECT * FROM read_csv('{{RAW_DIR}}/purchase_orders.csv',       header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.po_receipts           AS SELECT * FROM read_csv('{{RAW_DIR}}/po_receipts.csv',           header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.ap_invoices           AS SELECT * FROM read_csv('{{RAW_DIR}}/ap_invoices.csv',           header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.subcontract_pay_apps  AS SELECT * FROM read_csv('{{RAW_DIR}}/subcontract_pay_apps.csv',  header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.equipment             AS SELECT * FROM read_csv('{{RAW_DIR}}/equipment.csv',             header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.equipment_usage       AS SELECT * FROM read_csv('{{RAW_DIR}}/equipment_usage.csv',       header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.inventory_items       AS SELECT * FROM read_csv('{{RAW_DIR}}/inventory_items.csv',       header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.rfis                  AS SELECT * FROM read_csv('{{RAW_DIR}}/rfis.csv',                  header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.submittals            AS SELECT * FROM read_csv('{{RAW_DIR}}/submittals.csv',            header = true, all_varchar = true);
CREATE OR REPLACE TABLE raw.schedule_milestones   AS SELECT * FROM read_csv('{{RAW_DIR}}/schedule_milestones.csv',   header = true, all_varchar = true);

-- Load audit: what arrived, so a short or empty extract is visible immediately.
CREATE OR REPLACE TABLE ops.load_audit AS
SELECT table_name, row_count, current_timestamp::TIMESTAMP AS loaded_at
FROM (
    SELECT 'projects'         AS table_name, COUNT(*) AS row_count FROM raw.projects         UNION ALL
    SELECT 'cost_codes',                     COUNT(*)              FROM raw.cost_codes       UNION ALL
    SELECT 'budget_lines',                   COUNT(*)              FROM raw.budget_lines     UNION ALL
    SELECT 'commitments',                    COUNT(*)              FROM raw.commitments      UNION ALL
    SELECT 'actual_costs',                   COUNT(*)              FROM raw.actual_costs     UNION ALL
    SELECT 'change_orders',                  COUNT(*)              FROM raw.change_orders    UNION ALL
    SELECT 'billings',                       COUNT(*)              FROM raw.billings         UNION ALL
    SELECT 'timecards',                      COUNT(*)              FROM raw.timecards        UNION ALL
    SELECT 'employees',                      COUNT(*)              FROM raw.employees        UNION ALL
    SELECT 'safety_incidents',               COUNT(*)              FROM raw.safety_incidents UNION ALL
    SELECT 'accounts',                       COUNT(*)              FROM raw.accounts         UNION ALL
    SELECT 'opportunities',                  COUNT(*)              FROM raw.opportunities    UNION ALL
    SELECT 'vendors', COUNT(*) FROM raw.vendors UNION ALL
    SELECT 'purchase_orders', COUNT(*) FROM raw.purchase_orders UNION ALL
    SELECT 'po_receipts', COUNT(*) FROM raw.po_receipts UNION ALL
    SELECT 'ap_invoices', COUNT(*) FROM raw.ap_invoices UNION ALL
    SELECT 'subcontract_pay_apps', COUNT(*) FROM raw.subcontract_pay_apps UNION ALL
    SELECT 'equipment', COUNT(*) FROM raw.equipment UNION ALL
    SELECT 'equipment_usage', COUNT(*) FROM raw.equipment_usage UNION ALL
    SELECT 'inventory_items', COUNT(*) FROM raw.inventory_items UNION ALL
    SELECT 'rfis', COUNT(*) FROM raw.rfis UNION ALL
    SELECT 'submittals', COUNT(*) FROM raw.submittals UNION ALL
    SELECT 'schedule_milestones', COUNT(*) FROM raw.schedule_milestones UNION ALL
    SELECT 'bids',                           COUNT(*)              FROM raw.bids
) t;
