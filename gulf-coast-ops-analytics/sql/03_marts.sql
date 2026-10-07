-- =============================================================================
-- 03_marts.sql   LAYER: MART (star schema)
-- SYNTHETIC DATA: Gulf Coast Builders is a fictional company.
--
-- Dimensions get integer surrogate keys; facts carry only keys, degenerate IDs
-- and additive measures. Only STAGED rows reach this layer.
-- CONFIDENTIAL columns (employees.hourly_rate, employees.email) are deliberately
-- NOT copied into the mart.
--
-- SNOWFLAKE: ROW_NUMBER() surrogate keys can be replaced with IDENTITY/AUTOINCREMENT
--   or sequences; generate_series -> TABLE(GENERATOR(ROWCOUNT => n)); strftime -> TO_CHAR;
--   dayofweek -> DAYOFWEEKISO or DAYOFWEEK (check WEEK_START parameter); last_day is portable.
-- =============================================================================

-- ---- dim_date ---------------------------------------------------------------
CREATE OR REPLACE TABLE mart.dim_date AS
WITH days AS (
    SELECT CAST(d AS DATE) AS dt
    FROM generate_series(DATE '2024-10-01', DATE '2028-12-31', INTERVAL 1 DAY) AS t(d)
)
SELECT CAST(strftime(dt, '%Y%m%d') AS INTEGER)        AS date_key,
       dt                                             AS date,
       YEAR(dt)                                       AS year,
       QUARTER(dt)                                    AS quarter,
       MONTH(dt)                                      AS month,
       MONTHNAME(dt)                                  AS month_name,
       strftime(dt, '%Y-%m')                          AS year_month,
       dt + CAST(6 - DAYOFWEEK(dt) AS INTEGER)        AS week_ending,            -- Saturday week end (DuckDB: Sunday = 0)
       dt = LAST_DAY(dt)                              AS is_month_end,
       dt <= (SELECT as_of_date FROM ops.etl_params)  AS is_past_as_of
FROM days;

-- ---- dim_employee (no pay rate, no email) ------------------------------------------
CREATE OR REPLACE TABLE mart.dim_employee AS
SELECT ROW_NUMBER() OVER (ORDER BY employee_id) AS employee_key,
       employee_id, full_name, role, business_unit, is_field, hire_date
FROM stg.employees;

-- ---- dim_account -------------------------------------------------------------------
CREATE OR REPLACE TABLE mart.dim_account AS
SELECT ROW_NUMBER() OVER (ORDER BY account_id) AS account_key,
       account_id, account_name, segment, region
FROM stg.accounts;

-- ---- dim_cost_code -----------------------------------------------------------------
CREATE OR REPLACE TABLE mart.dim_cost_code AS
SELECT ROW_NUMBER() OVER (ORDER BY cost_code) AS cost_code_key,
       cost_code, cost_code_name, category, division
FROM stg.cost_codes;

-- ---- dim_project -------------------------------------------------------------------
-- original_budget_cost = bid cost; original_margin_pct = bid margin every other metric is measured against.
CREATE OR REPLACE TABLE mart.dim_project AS
WITH bid_cost AS (
    SELECT project_id, SUM(original_budget) AS original_budget_cost
    FROM stg.budget_lines GROUP BY project_id
)
SELECT ROW_NUMBER() OVER (ORDER BY p.project_id)                               AS project_key,
       p.project_id, p.project_name, p.business_unit,
       a.account_key, e.employee_key AS pm_employee_key,
       p.start_date, p.planned_end_date, p.status, p.original_contract_value,
       b.original_budget_cost,
       ROUND((p.original_contract_value - b.original_budget_cost) / p.original_contract_value, 4) AS original_margin_pct,
       p.opportunity_id
FROM stg.projects p
LEFT JOIN bid_cost          b ON b.project_id  = p.project_id
LEFT JOIN mart.dim_account  a ON a.account_id  = p.account_id
LEFT JOIN mart.dim_employee e ON e.employee_id = p.pm_employee_id;

-- ---- fact_cost : one row per cleaned cost posting -----------------------------------
CREATE OR REPLACE TABLE mart.fact_cost AS
SELECT dp.project_key, dc.cost_code_key, dd.date_key,
       c.cost_id, c.amount AS actual_cost, c.vendor_std, c.source_system, c.is_credit_memo
FROM stg.actual_costs c
JOIN mart.dim_project   dp ON dp.project_id = c.project_id
JOIN mart.dim_cost_code dc ON dc.cost_code  = c.cost_code
JOIN mart.dim_date      dd ON dd.date       = c.period;

-- ---- fact_budget : project x cost code ----------------------------------------------
CREATE OR REPLACE TABLE mart.fact_budget AS
SELECT dp.project_key, dc.cost_code_key,
       b.original_budget, b.approved_co_budget, b.revised_budget, b.estimate_to_complete
FROM stg.budget_lines b
JOIN mart.dim_project   dp ON dp.project_id = b.project_id
JOIN mart.dim_cost_code dc ON dc.cost_code  = b.cost_code;

-- ---- fact_billing : one row per pay application -----------------------------------------
-- due_date_key / paid_date_key feed AR aging (paid_date_key is NULL while the invoice is unpaid).
CREATE OR REPLACE TABLE mart.fact_billing AS
SELECT dp.project_key, dd.date_key, b.billing_id, b.invoice_no, b.pay_app_no,
       b.gross_billed, b.retainage_held, b.gross_billed - b.retainage_held AS net_billed, b.status,
       b.submitted_date, b.due_date, b.paid_date
FROM stg.billings b
JOIN mart.dim_project dp ON dp.project_id = b.project_id
JOIN mart.dim_date    dd ON dd.date       = b.period_end;

-- ---- fact_change_order --------------------------------------------------------------------
-- age_days: days a change order has waited for a decision (pending only).
-- cycle_days: days from submission to decision (decided only) - "approval takes days or weeks".
CREATE OR REPLACE TABLE mart.fact_change_order AS
SELECT dp.project_key, ds.date_key AS submitted_date_key, dx.date_key AS decision_date_key,
       c.change_order_id, c.co_number, c.status, c.amount, c.estimated_cost, c.reason, c.description,
       CASE WHEN c.status = 'Pending'
            THEN DATE_DIFF('day', c.submitted_date, (SELECT as_of_date FROM ops.etl_params)) END AS age_days,
       CASE WHEN c.decision_date IS NOT NULL
            THEN DATE_DIFF('day', c.submitted_date, c.decision_date) END                        AS cycle_days
FROM stg.change_orders c
JOIN mart.dim_project dp ON dp.project_id = c.project_id
JOIN mart.dim_date    ds ON ds.date       = c.submitted_date
LEFT JOIN mart.dim_date dx ON dx.date     = c.decision_date;

-- ---- fact_pipeline : one row per CRM opportunity -------------------------------------------
-- A won opportunity with no ERP project is "awarded, not started" and counts toward backlog.
CREATE OR REPLACE TABLE mart.fact_pipeline AS
WITH latest_bid AS (
    SELECT opportunity_id, bid_amount, bid_margin_pct
    FROM (SELECT b.*, ROW_NUMBER() OVER (PARTITION BY opportunity_id ORDER BY bid_date DESC, bid_id DESC) AS rn
          FROM stg.bids b) x
    WHERE rn = 1
)
SELECT da.account_key, dp.project_key,
       dc.date_key AS created_date_key, de.date_key AS expected_close_date_key, dx.date_key AS closed_date_key,
       o.opportunity_id, o.opportunity_name, o.business_unit, o.stage, o.amount, o.probability,
       o.amount * o.probability                                   AS weighted_amount,
       o.stage IN ('Lead', 'Qualified', 'Proposal', 'Negotiation') AS is_open,
       o.stage = 'Won'                                            AS is_won,
       o.stage = 'Lost'                                           AS is_lost,
       (o.stage = 'Won' AND dp.project_key IS NULL)               AS is_awarded_unstarted,
       lb.bid_amount, lb.bid_margin_pct, o."owner", o.lead_source
FROM stg.opportunities o
JOIN mart.dim_account da ON da.account_id = o.account_id
LEFT JOIN mart.dim_project dp ON dp.opportunity_id = o.opportunity_id
LEFT JOIN mart.dim_date dc ON dc.date = o.created_date
LEFT JOIN mart.dim_date de ON de.date = o.expected_close_date
LEFT JOIN mart.dim_date dx ON dx.date = o.closed_date
LEFT JOIN latest_bid lb ON lb.opportunity_id = o.opportunity_id;

-- ---- fact_safety --------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart.fact_safety AS
SELECT dp.project_key, dd.date_key, de.employee_key,
       s.incident_id, s.incident_type, s.cause_category, s.severity, s.recordable_flag, s.days_away, s.description
FROM stg.safety_incidents s
JOIN mart.dim_project dp ON dp.project_id = s.project_id
JOIN mart.dim_date    dd ON dd.date       = s.incident_date
LEFT JOIN mart.dim_employee de ON de.employee_id = s.employee_id;

-- ---- fact_hours : project x week (denominator for incident rates) -----------------------------
CREATE OR REPLACE TABLE mart.fact_hours AS
SELECT dp.project_key, dd.date_key,
       SUM(t.regular_hours + t.overtime_hours) AS hours,
       COUNT(DISTINCT t.employee_id)           AS worker_count
FROM stg.timecards t
JOIN mart.dim_project dp ON dp.project_id = t.project_id
JOIN mart.dim_date    dd ON dd.date       = t.week_ending
GROUP BY dp.project_key, dd.date_key;


-- =============================================================================
-- ERP expansion: procurement, subcontract pay, equipment, inventory, RFIs, schedule
-- =============================================================================
CREATE OR REPLACE TABLE mart.dim_vendor AS
SELECT ROW_NUMBER() OVER (ORDER BY vendor_name) AS vendor_key, vendor_id, vendor_name, vendor_type, trade, payment_terms_days
FROM stg.vendors;

CREATE OR REPLACE TABLE mart.dim_equipment AS
SELECT ROW_NUMBER() OVER (ORDER BY equipment_id) AS equipment_key, equipment_id, equipment_name, category, ownership, daily_rate
FROM stg.equipment;

-- fact_commitment : one row per subcontract / PO commitment, with billing and payment rolled up from pay applications
CREATE OR REPLACE TABLE mart.fact_commitment AS
WITH pay AS (
    SELECT commitment_id,
           SUM(gross_billed)                                         AS billed_to_date,
           SUM(paid_amount)                                          AS paid_to_date,
           SUM(retainage_held)                                       AS retainage_held,
           SUM(retainage_released)                                   AS retainage_released,
           SUM(gross_billed) FILTER (WHERE status = 'Disputed')      AS disputed_amount
    FROM stg.subcontract_pay_apps GROUP BY commitment_id
)
SELECT dp.project_key, dc.cost_code_key, dv.vendor_key, c.commitment_id, c.commitment_type, c.status,
       c.original_amount, c.approved_changes, c.original_amount + c.approved_changes AS committed_total,
       COALESCE(p.billed_to_date, 0) AS billed_to_date, COALESCE(p.paid_to_date, 0) AS paid_to_date,
       COALESCE(p.retainage_held, 0) AS retainage_held, COALESCE(p.retainage_released, 0) AS retainage_released,
       COALESCE(p.disputed_amount, 0) AS disputed_amount, c.executed_date
FROM stg.commitments c
JOIN mart.dim_project   dp ON dp.project_id = c.project_id
JOIN mart.dim_cost_code dc ON dc.cost_code  = c.cost_code
JOIN mart.dim_vendor    dv ON dv.vendor_name = c.vendor_std
LEFT JOIN pay p ON p.commitment_id = c.commitment_id;

-- fact_sub_pay_app : one row per subcontractor pay application
CREATE OR REPLACE TABLE mart.fact_sub_pay_app AS
SELECT dp.project_key, dv.vendor_key, dd.date_key AS period_end_date_key, s.sub_pay_app_id, s.commitment_id,
       s.gross_billed, s.retainage_held, s.gross_billed - s.retainage_held AS net_due, s.paid_amount, s.status,
       s.invoice_date, s.due_date, s.paid_date, s.retainage_released
FROM stg.subcontract_pay_apps s
JOIN mart.dim_project dp ON dp.project_id = s.project_id
JOIN mart.dim_vendor  dv ON dv.vendor_name = s.vendor_std
JOIN mart.dim_date    dd ON dd.date = s.period_end;

-- fact_purchase_order : one row per PO line
CREATE OR REPLACE TABLE mart.fact_purchase_order AS
SELECT dp.project_key, dc.cost_code_key, dv.vendor_key,
       po.po_line_id, po.po_number, po.commitment_id, po.item_description, po.uom, po.quantity, po.unit_price, po.ordered_amount,
       po.order_date, po.promised_date, po.ship_date, po.received_date, po.status, po.is_long_lead
FROM stg.purchase_orders po
JOIN mart.dim_project   dp ON dp.project_id = po.project_id
JOIN mart.dim_cost_code dc ON dc.cost_code  = po.cost_code
JOIN mart.dim_vendor    dv ON dv.vendor_name = po.vendor_std;

-- fact_receipt : one row per delivery receipt (a PO line can have several partial receipts)
CREATE OR REPLACE TABLE mart.fact_receipt AS
SELECT r.receipt_id, r.po_line_id, dd.date_key AS receipt_date_key, r.received_qty, r.received_amount, r."condition"
FROM stg.po_receipts r
JOIN mart.dim_date dd ON dd.date = r.receipt_date;

-- fact_ap_invoice : one row per vendor invoice against a PO line
CREATE OR REPLACE TABLE mart.fact_ap_invoice AS
SELECT dp.project_key, dv.vendor_key, a.invoice_id, a.invoice_no, a.po_line_id, a.invoice_date, a.due_date, a.paid_date,
       a.amount, a.status
FROM stg.ap_invoices a
JOIN mart.dim_project dp ON dp.project_id = a.project_id
JOIN mart.dim_vendor  dv ON dv.vendor_name = a.vendor_std;

-- fact_equipment_usage : one row per equipment unit x project x month
CREATE OR REPLACE TABLE mart.fact_equipment_usage AS
SELECT de.equipment_key, dp.project_key, dd.date_key AS month_end_date_key, u.usage_id, u.days_used, u.standby_days, u.usage_cost
FROM stg.equipment_usage u
JOIN mart.dim_equipment de ON de.equipment_id = u.equipment_id
JOIN mart.dim_project   dp ON dp.project_id = u.project_id
JOIN mart.dim_date      dd ON dd.date = u.month_end;

-- fact_inventory : stock snapshot (manufacturing)
CREATE OR REPLACE TABLE mart.fact_inventory AS
SELECT i.item_id, i.item_name, i.uom, i.on_hand_qty, i.reorder_point, i.reorder_qty, i.unit_cost, i.avg_daily_usage, i.lead_time_days,
       dv.vendor_key AS preferred_vendor_key, i.last_receipt_date, i.snapshot_date
FROM stg.inventory_items i
LEFT JOIN mart.dim_vendor dv ON dv.vendor_name = i.preferred_vendor_std;

-- fact_rfi / fact_submittal / fact_milestone
CREATE OR REPLACE TABLE mart.fact_rfi AS
SELECT dp.project_key, r.rfi_id, r.rfi_number, r.subject, r.discipline, r.submitted_date, r.due_date, r.response_date, r.status,
       r.has_cost_impact, r.schedule_impact_days, r.ball_in_court
FROM stg.rfis r JOIN mart.dim_project dp ON dp.project_id = r.project_id;

CREATE OR REPLACE TABLE mart.fact_submittal AS
SELECT dp.project_key, s.submittal_id, s.spec_section, s.description, s.required_by_date, s.submitted_date, s.returned_date, s.status, s.cycle_count
FROM stg.submittals s JOIN mart.dim_project dp ON dp.project_id = s.project_id;

CREATE OR REPLACE TABLE mart.fact_milestone AS
SELECT dp.project_key, m.milestone_id, m.milestone_name, m.planned_date, m.forecast_date, m.actual_date, m.status
FROM stg.schedule_milestones m JOIN mart.dim_project dp ON dp.project_id = m.project_id;
