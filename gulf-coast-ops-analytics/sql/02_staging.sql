-- =============================================================================
-- 02_staging.sql   LAYER: STAGING
-- SYNTHETIC DATA: Gulf Coast Builders is a fictional company.
--
-- Cleans and types every raw table. Principles:
--   1. FIX what can be fixed without changing meaning (formats, spelling).
--   2. DEDUPLICATE explicitly (keep the earliest key) and record what was removed.
--   3. QUARANTINE what cannot be trusted into stg.rejects with a reason code and
--      the full raw row as JSON. Nothing is silently dropped, so
--          raw rows = staged rows + rejected rows            (checked in 04)
--   4. One reject reason per row (first matching rule wins; order is documented below).
--
-- Portability notes (DuckDB -> Snowflake):
--   * CREATE MACRO            -> SQL UDF (CREATE FUNCTION ... RETURNS ... AS $$ ... $$)
--   * TRY_STRPTIME(s, fmt)    -> TRY_TO_DATE(s, 'YYYY-MM-DD') / TRY_TO_DATE(s, 'MM/DD/YYYY')
--   * regexp_replace(.., 'g') -> REGEXP_REPLACE(..) (global by default)
--   * to_json(raw_row)        -> OBJECT_CONSTRUCT(r.*)
--   * CREATE TEMP TABLE       -> CREATE TEMPORARY TABLE
-- =============================================================================

-- ---- Cleaning helpers -------------------------------------------------------
CREATE OR REPLACE MACRO stg.parse_date(s) AS
    COALESCE(TRY_STRPTIME(TRIM(s), '%Y-%m-%d'), TRY_STRPTIME(TRIM(s), '%m/%d/%Y'))::DATE;

-- '$1,234.50' -> 1234.50 ; NULL on anything non-numeric
CREATE OR REPLACE MACRO stg.parse_amount(s) AS
    TRY_CAST(REPLACE(REPLACE(TRIM(s), '$', ''), ',', '') AS DECIMAL(18,2));

-- ' 03-300 ', '03300', '03.300' -> '03-300' ; NULL unless exactly 5 digits remain
CREATE OR REPLACE MACRO stg.norm_cost_code(s) AS
    CASE WHEN LENGTH(REGEXP_REPLACE(COALESCE(s, ''), '[^0-9]', '', 'g')) = 5
         THEN SUBSTR(REGEXP_REPLACE(s, '[^0-9]', '', 'g'), 1, 2) || '-' || SUBSTR(REGEXP_REPLACE(s, '[^0-9]', '', 'g'), 3, 3)
    END;

-- Vendor matching key: lower-case, "&" -> "and", punctuation -> space, trailing legal suffix removed.
--   'Gulf Ready-Mix LLC', 'GULF READY-MIX LLC', 'Gulf Ready Mix' -> 'gulf ready mix'
CREATE OR REPLACE MACRO stg.vendor_key(s) AS
    REGEXP_REPLACE(
        TRIM(REGEXP_REPLACE(LOWER(REPLACE(TRIM(s), '&', ' and ')), '[^a-z0-9]+', ' ', 'g')),
        ' (inc|llc|co|company|corp)$', '');

-- ---- Quarantine table ---------------------------------------------------------
CREATE OR REPLACE TABLE stg.rejects (
    source_table  VARCHAR,
    source_key    VARCHAR,
    reject_reason VARCHAR,
    raw_row_json  VARCHAR,
    rejected_at   TIMESTAMP
);

-- =============================================================================
-- Reference tables (typed copies; validated by checks in 04)
-- =============================================================================
CREATE OR REPLACE TABLE stg.cost_codes AS
SELECT TRIM(cost_code) AS cost_code, TRIM(cost_code_name) AS cost_code_name, TRIM(category) AS category, TRIM(division) AS division
FROM raw.cost_codes;

CREATE OR REPLACE TABLE stg.employees AS
SELECT TRIM(employee_id) AS employee_id, TRIM(full_name) AS full_name, TRIM(role) AS role, TRIM(business_unit) AS business_unit,
       CAST(is_field AS INTEGER) = 1 AS is_field, stg.parse_date(hire_date) AS hire_date,
       stg.parse_amount(hourly_rate) AS hourly_rate,      -- CONFIDENTIAL: stays in staging, never copied to the mart
       TRIM(email) AS email                                -- CONFIDENTIAL
FROM raw.employees;

CREATE OR REPLACE TABLE stg.accounts AS
SELECT TRIM(account_id) AS account_id, TRIM(account_name) AS account_name, TRIM(segment) AS segment,
       TRIM(region) AS region, stg.parse_date(created_date) AS created_date
FROM raw.accounts;

CREATE OR REPLACE TABLE stg.projects AS
SELECT TRIM(project_id) AS project_id, TRIM(project_name) AS project_name, TRIM(business_unit) AS business_unit,
       TRIM(account_id) AS account_id, TRIM(pm_employee_id) AS pm_employee_id,
       stg.parse_date(start_date) AS start_date, stg.parse_date(planned_end_date) AS planned_end_date,
       stg.parse_amount(original_contract_value) AS original_contract_value,
       TRIM(status) AS status, NULLIF(TRIM(opportunity_id), '') AS opportunity_id
FROM raw.projects;

-- =============================================================================
-- Vendor standardisation map
-- Canonical spelling = the most common raw spelling inside each matching key
-- (ties broken alphabetically). Built from every vendor-bearing table: AP postings, commitments,
-- purchase orders, AP invoices and subcontract pay applications.
-- SNOWFLAKE: ROW_NUMBER pattern below can be written with QUALIFY.
-- =============================================================================
CREATE OR REPLACE TABLE stg.vendor_map AS
WITH names AS (
    SELECT TRIM(vendor_name) AS raw_name FROM raw.actual_costs WHERE NULLIF(TRIM(vendor_name), '') IS NOT NULL
    UNION ALL
    SELECT TRIM(vendor_name) FROM raw.commitments            WHERE NULLIF(TRIM(vendor_name), '') IS NOT NULL
    UNION ALL
    SELECT TRIM(vendor_name) FROM raw.purchase_orders        WHERE NULLIF(TRIM(vendor_name), '') IS NOT NULL
    UNION ALL
    SELECT TRIM(vendor_name) FROM raw.ap_invoices            WHERE NULLIF(TRIM(vendor_name), '') IS NOT NULL
    UNION ALL
    SELECT TRIM(vendor_name) FROM raw.subcontract_pay_apps   WHERE NULLIF(TRIM(vendor_name), '') IS NOT NULL
),
counted AS (
    SELECT raw_name, stg.vendor_key(raw_name) AS vendor_key, COUNT(*) AS raw_occurrences
    FROM names GROUP BY raw_name
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY vendor_key ORDER BY raw_occurrences DESC, raw_name) AS rn
    FROM counted
)
SELECT c.raw_name, c.vendor_key, r.raw_name AS vendor_std, c.raw_occurrences
FROM counted c
JOIN ranked r ON r.vendor_key = c.vendor_key AND r.rn = 1;

-- =============================================================================
-- CRM: opportunities, bids
--   opportunities reject order: orphan_account_fk, invalid_stage, unparseable_value
-- =============================================================================
CREATE TEMP TABLE _opp_flag AS
SELECT r AS raw_row, TRIM(r.opportunity_id) AS opportunity_id, TRIM(r.account_id) AS account_id,
       TRIM(r.opportunity_name) AS opportunity_name, TRIM(r.business_unit) AS business_unit,
       CASE WHEN LOWER(TRIM(r.stage)) LIKE 'lead%'  THEN 'Lead'
            WHEN LOWER(TRIM(r.stage)) LIKE 'qual%'  THEN 'Qualified'
            WHEN LOWER(TRIM(r.stage)) LIKE 'prop%'  THEN 'Proposal'
            WHEN LOWER(TRIM(r.stage)) LIKE 'neg%'   THEN 'Negotiation'
            WHEN LOWER(TRIM(r.stage)) LIKE 'won%'   THEN 'Won'
            WHEN LOWER(TRIM(r.stage)) LIKE 'lost%'  THEN 'Lost' END AS stage,
       stg.parse_amount(r.amount) AS amount, TRY_CAST(r.probability AS DECIMAL(5,2)) AS probability,
       stg.parse_date(r.created_date) AS created_date, stg.parse_date(r.expected_close_date) AS expected_close_date,
       stg.parse_date(r.closed_date) AS closed_date, TRIM(r."owner") AS "owner", TRIM(r.lead_source) AS lead_source,
       CASE WHEN a.account_id IS NULL THEN 'orphan_account_fk'
            WHEN LOWER(TRIM(r.stage)) NOT SIMILAR TO '(lead|qual|prop|neg|won|lost).*' THEN 'invalid_stage'
            WHEN stg.parse_amount(r.amount) IS NULL OR TRY_CAST(r.probability AS DECIMAL(5,2)) IS NULL THEN 'unparseable_value'
       END AS reject_reason
FROM raw.opportunities r
LEFT JOIN stg.accounts a ON a.account_id = TRIM(r.account_id);

CREATE OR REPLACE TABLE stg.opportunities AS
SELECT opportunity_id, account_id, opportunity_name, business_unit, stage, amount, probability,
       created_date, expected_close_date, closed_date, "owner", lead_source
FROM _opp_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'opportunities', opportunity_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _opp_flag WHERE reject_reason IS NOT NULL;

CREATE TEMP TABLE _bid_flag AS
SELECT r AS raw_row, TRIM(r.bid_id) AS bid_id, TRIM(r.opportunity_id) AS opportunity_id, stg.parse_date(r.bid_date) AS bid_date,
       stg.parse_amount(r.bid_amount) AS bid_amount, stg.parse_amount(r.estimated_cost) AS estimated_cost,
       TRY_CAST(r.bid_margin_pct AS DECIMAL(8,4)) AS bid_margin_pct, TRY_CAST(r.competitor_count AS INTEGER) AS competitor_count,
       TRIM(r.result) AS result, NULLIF(TRIM(r.loss_reason), '') AS loss_reason,
       CASE WHEN o.opportunity_id IS NULL THEN 'orphan_opportunity_fk'
            WHEN stg.parse_amount(r.bid_amount) IS NULL THEN 'unparseable_value' END AS reject_reason
FROM raw.bids r
LEFT JOIN stg.opportunities o ON o.opportunity_id = TRIM(r.opportunity_id);

CREATE OR REPLACE TABLE stg.bids AS
SELECT bid_id, opportunity_id, bid_date, bid_amount, estimated_cost, bid_margin_pct, competitor_count, result, loss_reason
FROM _bid_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'bids', bid_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _bid_flag WHERE reject_reason IS NOT NULL;

-- =============================================================================
-- ERP: budget lines, commitments
-- =============================================================================
CREATE OR REPLACE TABLE stg.budget_lines AS
SELECT TRIM(budget_line_id) AS budget_line_id, TRIM(project_id) AS project_id, stg.norm_cost_code(cost_code) AS cost_code,
       stg.parse_amount(original_budget) AS original_budget, stg.parse_amount(approved_co_budget) AS approved_co_budget,
       stg.parse_amount(revised_budget) AS revised_budget, stg.parse_amount(estimate_to_complete) AS estimate_to_complete,
       stg.parse_date(etc_updated_date) AS etc_updated_date
FROM raw.budget_lines;

CREATE OR REPLACE TABLE stg.commitments AS
SELECT TRIM(c.commitment_id) AS commitment_id, TRIM(c.project_id) AS project_id, stg.norm_cost_code(c.cost_code) AS cost_code,
       COALESCE(vm.vendor_std, TRIM(c.vendor_name)) AS vendor_std, TRIM(c.vendor_name) AS vendor_raw,
       TRIM(c.commitment_type) AS commitment_type, stg.parse_amount(c.original_amount) AS original_amount,
       stg.parse_amount(c.approved_changes) AS approved_changes, TRIM(c.status) AS status, stg.parse_date(c.executed_date) AS executed_date
FROM raw.commitments c
LEFT JOIN stg.vendor_map vm ON vm.raw_name = TRIM(c.vendor_name);

-- =============================================================================
-- ERP: actual costs
--   reject order: missing_cost_code, invalid_cost_code_format, unparseable_period_or_amount, orphan_project_fk,
--                 orphan_cost_code_fk, future_period, negative_amount_without_credit_memo
--   A negative amount is legitimate only when the description says "credit memo".
-- =============================================================================
CREATE TEMP TABLE _cost_flag AS
SELECT r AS raw_row, TRIM(r.cost_id) AS cost_id, TRIM(r.project_id) AS project_id,
       NULLIF(TRIM(r.cost_code), '') AS cost_code_raw, stg.norm_cost_code(r.cost_code) AS cost_code,
       stg.parse_date(r.period) AS period, stg.parse_amount(r.amount) AS amount,
       NULLIF(TRIM(r.vendor_name), '') AS vendor_raw, TRIM(r.source_system) AS source_system, TRIM(r.description) AS description
FROM raw.actual_costs r;

CREATE TEMP TABLE _cost_cls AS
SELECT c.*,
       CASE WHEN c.cost_code_raw IS NULL                                   THEN 'missing_cost_code'
            WHEN c.cost_code IS NULL                                       THEN 'invalid_cost_code_format'
            WHEN c.period IS NULL OR c.amount IS NULL                      THEN 'unparseable_period_or_amount'
            WHEN p.project_id IS NULL                                      THEN 'orphan_project_fk'
            WHEN cc.cost_code IS NULL                                      THEN 'orphan_cost_code_fk'
            WHEN c.period > (SELECT as_of_date FROM ops.etl_params)        THEN 'future_period'
            WHEN c.amount < 0 AND c.description NOT ILIKE '%credit memo%'  THEN 'negative_amount_without_credit_memo'
       END AS reject_reason
FROM _cost_flag c
LEFT JOIN stg.projects   p  ON p.project_id = c.project_id
LEFT JOIN stg.cost_codes cc ON cc.cost_code = c.cost_code;

CREATE OR REPLACE TABLE stg.actual_costs AS
SELECT c.cost_id, c.project_id, c.cost_code, c.period, c.amount,
       COALESCE(vm.vendor_std, c.vendor_raw) AS vendor_std, c.vendor_raw, c.source_system, c.description,
       c.description ILIKE '%credit memo%' AS is_credit_memo
FROM _cost_cls c
LEFT JOIN stg.vendor_map vm ON vm.raw_name = c.vendor_raw
WHERE c.reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'actual_costs', cost_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _cost_cls WHERE reject_reason IS NOT NULL;

-- =============================================================================
-- ERP: change orders
-- =============================================================================
-- SNOWFLAKE: status standardisation can use INITCAP(TRIM(r.status))
CREATE TEMP TABLE _co_flag AS
SELECT r AS raw_row, TRIM(r.change_order_id) AS change_order_id, TRIM(r.project_id) AS project_id,
       TRY_CAST(r.co_number AS INTEGER) AS co_number, TRIM(r.description) AS description, TRIM(r.reason) AS reason,
       stg.parse_date(r.submitted_date) AS submitted_date, stg.parse_date(r.decision_date) AS decision_date,
       UPPER(SUBSTR(TRIM(r.status), 1, 1)) || LOWER(SUBSTR(TRIM(r.status), 2)) AS status, stg.parse_amount(r.amount) AS amount, stg.parse_amount(r.estimated_cost) AS estimated_cost,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk'
            WHEN stg.parse_amount(r.amount) IS NULL OR stg.parse_date(r.submitted_date) IS NULL THEN 'unparseable_value' END AS reject_reason
FROM raw.change_orders r
LEFT JOIN stg.projects p ON p.project_id = TRIM(r.project_id);

CREATE OR REPLACE TABLE stg.change_orders AS
SELECT change_order_id, project_id, co_number, description, reason, submitted_date, decision_date, status, amount, estimated_cost
FROM _co_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'change_orders', change_order_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _co_flag WHERE reject_reason IS NOT NULL;

-- =============================================================================
-- ERP: billings (pay applications)
--   reject order: orphan_project_fk, unparseable_value, negative_amount_without_credit_memo, duplicate_invoice
--   Duplicate rule: one row per (project_id, invoice_no); keep the lowest billing_id.
--   Exact copies AND re-keyed copies (same invoice, new id) are both caught.
-- =============================================================================
CREATE TEMP TABLE _bill_base AS
SELECT r AS raw_row, TRIM(r.billing_id) AS billing_id, TRIM(r.project_id) AS project_id,
       TRY_CAST(r.pay_app_no AS INTEGER) AS pay_app_no, stg.parse_date(r.period_end) AS period_end, TRIM(r.invoice_no) AS invoice_no,
       stg.parse_amount(r.gross_billed) AS gross_billed, stg.parse_amount(r.retainage_held) AS retainage_held,
       TRIM(r.status) AS status, stg.parse_date(r.submitted_date) AS submitted_date,
       stg.parse_date(r.due_date) AS due_date, stg.parse_date(r.paid_date) AS paid_date,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk'
            WHEN stg.parse_amount(r.gross_billed) IS NULL OR stg.parse_date(r.period_end) IS NULL THEN 'unparseable_value'
            WHEN stg.parse_amount(r.gross_billed) < 0 AND LOWER(TRIM(r.status)) <> 'credit' THEN 'negative_amount_without_credit_memo'
       END AS reason1
FROM raw.billings r
LEFT JOIN stg.projects p ON p.project_id = TRIM(r.project_id);

CREATE TEMP TABLE _bill_cls AS
SELECT b.*,
       COALESCE(b.reason1,
                CASE WHEN ROW_NUMBER() OVER (PARTITION BY b.project_id, b.invoice_no, (b.reason1 IS NULL)
                                             ORDER BY b.billing_id) > 1 THEN 'duplicate_invoice' END) AS reject_reason
FROM _bill_base b;

CREATE OR REPLACE TABLE stg.billings AS
SELECT billing_id, project_id, pay_app_no, period_end, invoice_no, gross_billed, retainage_held, status, submitted_date, due_date, paid_date
FROM _bill_cls WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'billings', billing_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _bill_cls WHERE reject_reason IS NOT NULL;

-- =============================================================================
-- ERP: timecards   reject order: orphan_employee_fk, orphan_project_fk, hours_out_of_range
-- =============================================================================
CREATE TEMP TABLE _tc_flag AS
SELECT r AS raw_row, TRIM(r.timecard_id) AS timecard_id, TRIM(r.employee_id) AS employee_id, TRIM(r.project_id) AS project_id,
       stg.parse_date(r.week_ending) AS week_ending,
       TRY_CAST(r.regular_hours AS DECIMAL(6,1)) AS regular_hours, TRY_CAST(r.overtime_hours AS DECIMAL(6,1)) AS overtime_hours,
       CASE WHEN e.employee_id IS NULL THEN 'orphan_employee_fk'
            WHEN p.project_id  IS NULL THEN 'orphan_project_fk'
            WHEN TRY_CAST(r.regular_hours AS DECIMAL(6,1)) IS NULL OR TRY_CAST(r.regular_hours AS DECIMAL(6,1)) NOT BETWEEN 0 AND 80
              OR TRY_CAST(r.overtime_hours AS DECIMAL(6,1)) IS NULL OR TRY_CAST(r.overtime_hours AS DECIMAL(6,1)) NOT BETWEEN 0 AND 40
                 THEN 'hours_out_of_range' END AS reject_reason
FROM raw.timecards r
LEFT JOIN stg.employees e ON e.employee_id = TRIM(r.employee_id)
LEFT JOIN stg.projects  p ON p.project_id  = TRIM(r.project_id);

CREATE OR REPLACE TABLE stg.timecards AS
SELECT timecard_id, employee_id, project_id, week_ending, regular_hours, overtime_hours
FROM _tc_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'timecards', timecard_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _tc_flag WHERE reject_reason IS NOT NULL;

-- =============================================================================
-- ERP: safety incidents   reject order: orphan_project_fk, orphan_employee_fk, future_incident_date
-- =============================================================================
CREATE TEMP TABLE _si_flag AS
SELECT r AS raw_row, TRIM(r.incident_id) AS incident_id, TRIM(r.project_id) AS project_id, stg.parse_date(r.incident_date) AS incident_date,
       TRIM(r.incident_type) AS incident_type, TRIM(r.cause_category) AS cause_category, NULLIF(TRIM(r.employee_id), '') AS employee_id,
       UPPER(TRIM(r.recordable_flag)) AS recordable_flag, TRY_CAST(r.days_away AS INTEGER) AS days_away,
       TRY_CAST(r.severity AS INTEGER) AS severity, TRIM(r.description) AS description,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk'
            WHEN NULLIF(TRIM(r.employee_id), '') IS NOT NULL AND e.employee_id IS NULL THEN 'orphan_employee_fk'
            WHEN stg.parse_date(r.incident_date) > (SELECT as_of_date FROM ops.etl_params) THEN 'future_incident_date' END AS reject_reason
FROM raw.safety_incidents r
LEFT JOIN stg.projects  p ON p.project_id  = TRIM(r.project_id)
LEFT JOIN stg.employees e ON e.employee_id = NULLIF(TRIM(r.employee_id), '');

CREATE OR REPLACE TABLE stg.safety_incidents AS
SELECT incident_id, project_id, incident_date, incident_type, cause_category, employee_id, recordable_flag, days_away, severity, description
FROM _si_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'safety_incidents', incident_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _si_flag WHERE reject_reason IS NOT NULL;

-- =============================================================================
-- ERP expansion: vendors, equipment, procurement, subcontract pay, field operations
-- =============================================================================
CREATE OR REPLACE TABLE stg.vendors AS
SELECT TRIM(vendor_id) AS vendor_id, TRIM(vendor_name) AS vendor_name, TRIM(vendor_type) AS vendor_type, TRIM(trade) AS trade,
       TRY_CAST(payment_terms_days AS INTEGER) AS payment_terms_days
FROM raw.vendors;

CREATE OR REPLACE TABLE stg.equipment AS
SELECT TRIM(equipment_id) AS equipment_id, TRIM(equipment_name) AS equipment_name, TRIM(category) AS category,
       TRIM(ownership) AS ownership, stg.parse_amount(daily_rate) AS daily_rate,
       COALESCE(vm.vendor_std, NULLIF(TRIM(e.vendor_name), '')) AS vendor_std
FROM raw.equipment e
LEFT JOIN stg.vendor_map vm ON vm.raw_name = TRIM(e.vendor_name);

-- ---- purchase order lines   reject order: orphan_project_fk, invalid_quantity, unparseable_value, received_before_order,
--                                           duplicate_po_line (keep one row per po_line_id)
CREATE TEMP TABLE _po_typed AS
SELECT r AS raw_row, TRIM(r.po_line_id) AS po_line_id, TRIM(r.po_number) AS po_number, TRIM(r.commitment_id) AS commitment_id,
       TRIM(r.project_id) AS project_id, stg.norm_cost_code(r.cost_code) AS cost_code,
       COALESCE(vm.vendor_std, TRIM(r.vendor_name)) AS vendor_std, TRIM(r.vendor_name) AS vendor_raw,
       TRIM(r.item_description) AS item_description, TRY_CAST(r.quantity AS DECIMAL(18,2)) AS quantity, TRIM(r.uom) AS uom,
       stg.parse_amount(r.unit_price) AS unit_price, stg.parse_amount(r.ordered_amount) AS ordered_amount,
       stg.parse_date(r.order_date) AS order_date, stg.parse_date(r.promised_date) AS promised_date,
       stg.parse_date(r.ship_date) AS ship_date, stg.parse_date(r.received_date) AS received_date,
       TRIM(r.status) AS status, TRIM(r.is_long_lead) = 'Y' AS is_long_lead
FROM raw.purchase_orders r
LEFT JOIN stg.vendor_map vm ON vm.raw_name = TRIM(r.vendor_name);

CREATE TEMP TABLE _po_base AS
SELECT t.*,
       CASE WHEN p.project_id IS NULL                                  THEN 'orphan_project_fk'
            WHEN t.quantity IS NULL OR t.quantity <= 0                 THEN 'invalid_quantity'
            WHEN t.order_date IS NULL OR t.ordered_amount IS NULL      THEN 'unparseable_value'
            WHEN t.received_date IS NOT NULL AND t.received_date < t.order_date THEN 'received_before_order'
       END AS reason1
FROM _po_typed t LEFT JOIN stg.projects p ON p.project_id = t.project_id;

CREATE TEMP TABLE _po_cls AS
SELECT b.*, COALESCE(b.reason1, CASE WHEN ROW_NUMBER() OVER (PARTITION BY b.po_line_id, (b.reason1 IS NULL) ORDER BY b.po_line_id) > 1
                                     THEN 'duplicate_po_line' END) AS reject_reason
FROM _po_base b;

CREATE OR REPLACE TABLE stg.purchase_orders AS
SELECT po_line_id, po_number, commitment_id, project_id, cost_code, vendor_std, vendor_raw, item_description, quantity, uom, unit_price,
       ordered_amount, order_date, promised_date, ship_date, received_date, status, is_long_lead
FROM _po_cls WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'purchase_orders', po_line_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _po_cls WHERE reject_reason IS NOT NULL;

-- ---- receipts   reject order: orphan_po_fk, invalid_quantity, duplicate_receipt
CREATE TEMP TABLE _rc_base AS
SELECT r AS raw_row, TRIM(r.receipt_id) AS receipt_id, TRIM(r.po_line_id) AS po_line_id, stg.parse_date(r.receipt_date) AS receipt_date,
       TRY_CAST(r.received_qty AS DECIMAL(18,2)) AS received_qty, stg.parse_amount(r.received_amount) AS received_amount,
       TRIM(r."condition") AS "condition",
       CASE WHEN po.po_line_id IS NULL THEN 'orphan_po_fk'
            WHEN TRY_CAST(r.received_qty AS DECIMAL(18,2)) IS NULL OR TRY_CAST(r.received_qty AS DECIMAL(18,2)) <= 0 THEN 'invalid_quantity' END AS reason1
FROM raw.po_receipts r
LEFT JOIN stg.purchase_orders po ON po.po_line_id = TRIM(r.po_line_id);

CREATE TEMP TABLE _rc_cls AS
SELECT b.*, COALESCE(b.reason1, CASE WHEN ROW_NUMBER() OVER (PARTITION BY b.receipt_id, (b.reason1 IS NULL) ORDER BY b.receipt_id) > 1
                                     THEN 'duplicate_receipt' END) AS reject_reason
FROM _rc_base b;

CREATE OR REPLACE TABLE stg.po_receipts AS
SELECT receipt_id, po_line_id, receipt_date, received_qty, received_amount, "condition"
FROM _rc_cls WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'po_receipts', receipt_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _rc_cls WHERE reject_reason IS NOT NULL;

-- ---- AP invoices   reject order: orphan_po_fk, unparseable_value, future_invoice_date, duplicate_vendor_invoice
--      Duplicate rule: one row per (standardised vendor, vendor invoice number); keep the lowest invoice_id.
CREATE TEMP TABLE _ap_base AS
SELECT r AS raw_row, TRIM(r.invoice_id) AS invoice_id, TRIM(r.invoice_no) AS invoice_no, TRIM(r.po_line_id) AS po_line_id,
       TRIM(r.project_id) AS project_id, stg.norm_cost_code(r.cost_code) AS cost_code,
       COALESCE(vm.vendor_std, TRIM(r.vendor_name)) AS vendor_std,
       stg.parse_date(r.invoice_date) AS invoice_date, stg.parse_date(r.due_date) AS due_date,
       stg.parse_amount(r.amount) AS amount, stg.parse_date(r.paid_date) AS paid_date, TRIM(r.status) AS status,
       CASE WHEN po.po_line_id IS NULL THEN 'orphan_po_fk'
            WHEN stg.parse_amount(r.amount) IS NULL OR stg.parse_date(r.invoice_date) IS NULL THEN 'unparseable_value'
            WHEN stg.parse_date(r.invoice_date) > (SELECT as_of_date FROM ops.etl_params) THEN 'future_invoice_date' END AS reason1
FROM raw.ap_invoices r
LEFT JOIN stg.vendor_map vm ON vm.raw_name = TRIM(r.vendor_name)
LEFT JOIN stg.purchase_orders po ON po.po_line_id = TRIM(r.po_line_id);

CREATE TEMP TABLE _ap_cls AS
SELECT b.*, COALESCE(b.reason1, CASE WHEN ROW_NUMBER() OVER (PARTITION BY b.vendor_std, b.invoice_no, (b.reason1 IS NULL) ORDER BY b.invoice_id) > 1
                                     THEN 'duplicate_vendor_invoice' END) AS reject_reason
FROM _ap_base b;

CREATE OR REPLACE TABLE stg.ap_invoices AS
SELECT invoice_id, invoice_no, po_line_id, project_id, cost_code, vendor_std, invoice_date, due_date, amount, paid_date, status
FROM _ap_cls WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'ap_invoices', invoice_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _ap_cls WHERE reject_reason IS NOT NULL;

-- ---- subcontract pay applications   reject order: orphan_project_fk, orphan_commitment_fk, unparseable_value, negative_gross_billed
CREATE TEMP TABLE _sp_flag AS
SELECT r AS raw_row, TRIM(r.sub_pay_app_id) AS sub_pay_app_id, TRIM(r.commitment_id) AS commitment_id, TRIM(r.project_id) AS project_id,
       stg.norm_cost_code(r.cost_code) AS cost_code, COALESCE(vm.vendor_std, TRIM(r.vendor_name)) AS vendor_std,
       stg.parse_date(r.period_end) AS period_end, stg.parse_amount(r.gross_billed) AS gross_billed,
       stg.parse_amount(r.retainage_held) AS retainage_held, stg.parse_date(r.invoice_date) AS invoice_date,
       stg.parse_date(r.due_date) AS due_date, stg.parse_amount(r.paid_amount) AS paid_amount, stg.parse_date(r.paid_date) AS paid_date,
       TRIM(r.status) AS status, stg.parse_amount(r.retainage_released) AS retainage_released,
       stg.parse_date(r.retainage_release_date) AS retainage_release_date,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk'
            WHEN c.commitment_id IS NULL THEN 'orphan_commitment_fk'
            WHEN stg.parse_amount(r.gross_billed) IS NULL OR stg.parse_date(r.period_end) IS NULL THEN 'unparseable_value'
            WHEN stg.parse_amount(r.gross_billed) < 0 THEN 'negative_gross_billed' END AS reject_reason
FROM raw.subcontract_pay_apps r
LEFT JOIN stg.vendor_map  vm ON vm.raw_name = TRIM(r.vendor_name)
LEFT JOIN stg.projects     p ON p.project_id = TRIM(r.project_id)
LEFT JOIN stg.commitments  c ON c.commitment_id = TRIM(r.commitment_id);

CREATE OR REPLACE TABLE stg.subcontract_pay_apps AS
SELECT sub_pay_app_id, commitment_id, project_id, cost_code, vendor_std, period_end, gross_billed, retainage_held, invoice_date,
       due_date, paid_amount, paid_date, status, retainage_released, retainage_release_date
FROM _sp_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'subcontract_pay_apps', sub_pay_app_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _sp_flag WHERE reject_reason IS NOT NULL;

-- ---- equipment usage   reject order: orphan_equipment_fk, orphan_project_fk, days_out_of_range (0-31)
CREATE TEMP TABLE _eu_flag AS
SELECT r AS raw_row, TRIM(r.usage_id) AS usage_id, TRIM(r.equipment_id) AS equipment_id, TRIM(r.project_id) AS project_id,
       stg.parse_date(r.month_end) AS month_end, TRY_CAST(r.days_used AS INTEGER) AS days_used,
       TRY_CAST(r.standby_days AS INTEGER) AS standby_days, stg.parse_amount(r.usage_cost) AS usage_cost,
       CASE WHEN e.equipment_id IS NULL THEN 'orphan_equipment_fk'
            WHEN p.project_id IS NULL THEN 'orphan_project_fk'
            WHEN TRY_CAST(r.days_used AS INTEGER) IS NULL OR TRY_CAST(r.days_used AS INTEGER) NOT BETWEEN 0 AND 31
              OR TRY_CAST(r.standby_days AS INTEGER) IS NULL OR TRY_CAST(r.standby_days AS INTEGER) NOT BETWEEN 0 AND 31 THEN 'days_out_of_range' END AS reject_reason
FROM raw.equipment_usage r
LEFT JOIN stg.equipment e ON e.equipment_id = TRIM(r.equipment_id)
LEFT JOIN stg.projects  p ON p.project_id = TRIM(r.project_id);

CREATE OR REPLACE TABLE stg.equipment_usage AS
SELECT usage_id, equipment_id, project_id, month_end, days_used, standby_days, usage_cost FROM _eu_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'equipment_usage', usage_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _eu_flag WHERE reject_reason IS NOT NULL;

-- ---- inventory snapshot   reject: negative_on_hand / unparseable
CREATE TEMP TABLE _iv_flag AS
SELECT r AS raw_row, TRIM(r.item_id) AS item_id, TRIM(r.item_name) AS item_name, TRIM(r.uom) AS uom,
       TRY_CAST(r.on_hand_qty AS DECIMAL(18,2)) AS on_hand_qty, TRY_CAST(r.reorder_point AS DECIMAL(18,2)) AS reorder_point,
       TRY_CAST(r.reorder_qty AS DECIMAL(18,2)) AS reorder_qty, stg.parse_amount(r.unit_cost) AS unit_cost,
       TRY_CAST(r.avg_daily_usage AS DECIMAL(18,3)) AS avg_daily_usage, TRY_CAST(r.lead_time_days AS INTEGER) AS lead_time_days,
       COALESCE(vm.vendor_std, TRIM(r.preferred_vendor_name)) AS preferred_vendor_std,
       stg.parse_date(r.last_receipt_date) AS last_receipt_date, stg.parse_date(r.as_of_date) AS snapshot_date,
       CASE WHEN TRY_CAST(r.on_hand_qty AS DECIMAL(18,2)) IS NULL THEN 'unparseable_value'
            WHEN TRY_CAST(r.on_hand_qty AS DECIMAL(18,2)) < 0 THEN 'negative_on_hand' END AS reject_reason
FROM raw.inventory_items r
LEFT JOIN stg.vendor_map vm ON vm.raw_name = TRIM(r.preferred_vendor_name);

CREATE OR REPLACE TABLE stg.inventory_items AS
SELECT item_id, item_name, uom, on_hand_qty, reorder_point, reorder_qty, unit_cost, avg_daily_usage, lead_time_days,
       preferred_vendor_std, last_receipt_date, snapshot_date
FROM _iv_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'inventory_items', item_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _iv_flag WHERE reject_reason IS NOT NULL;

-- ---- RFIs   reject order: orphan_project_fk, response_before_submission
CREATE TEMP TABLE _rfi_flag AS
SELECT r AS raw_row, TRIM(r.rfi_id) AS rfi_id, TRIM(r.project_id) AS project_id, TRY_CAST(r.rfi_number AS INTEGER) AS rfi_number,
       TRIM(r.subject) AS subject, TRIM(r.discipline) AS discipline, stg.parse_date(r.submitted_date) AS submitted_date,
       stg.parse_date(r.due_date) AS due_date, stg.parse_date(r.response_date) AS response_date, TRIM(r.status) AS status,
       TRIM(r.cost_impact_flag) = 'Y' AS has_cost_impact, TRY_CAST(r.schedule_impact_days AS INTEGER) AS schedule_impact_days,
       TRIM(r.ball_in_court) AS ball_in_court,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk'
            WHEN stg.parse_date(r.response_date) IS NOT NULL AND stg.parse_date(r.response_date) < stg.parse_date(r.submitted_date) THEN 'response_before_submission' END AS reject_reason
FROM raw.rfis r LEFT JOIN stg.projects p ON p.project_id = TRIM(r.project_id);

CREATE OR REPLACE TABLE stg.rfis AS
SELECT rfi_id, project_id, rfi_number, subject, discipline, submitted_date, due_date, response_date, status, has_cost_impact,
       schedule_impact_days, ball_in_court
FROM _rfi_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'rfis', rfi_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _rfi_flag WHERE reject_reason IS NOT NULL;

-- ---- submittals   reject: orphan_project_fk
CREATE TEMP TABLE _sb_flag AS
SELECT r AS raw_row, TRIM(r.submittal_id) AS submittal_id, TRIM(r.project_id) AS project_id, TRIM(r.spec_section) AS spec_section,
       TRIM(r.description) AS description, stg.parse_date(r.required_by_date) AS required_by_date,
       stg.parse_date(r.submitted_date) AS submitted_date, stg.parse_date(r.returned_date) AS returned_date, TRIM(r.status) AS status,
       TRY_CAST(r.cycle_count AS INTEGER) AS cycle_count,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk' END AS reject_reason
FROM raw.submittals r LEFT JOIN stg.projects p ON p.project_id = TRIM(r.project_id);

CREATE OR REPLACE TABLE stg.submittals AS
SELECT submittal_id, project_id, spec_section, description, required_by_date, submitted_date, returned_date, status, cycle_count
FROM _sb_flag WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'submittals', submittal_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _sb_flag WHERE reject_reason IS NOT NULL;

-- ---- schedule milestones   reject: orphan_project_fk, duplicate_milestone
CREATE TEMP TABLE _ms_base AS
SELECT r AS raw_row, TRIM(r.milestone_id) AS milestone_id, TRIM(r.project_id) AS project_id, TRIM(r.milestone_name) AS milestone_name,
       stg.parse_date(r.planned_date) AS planned_date, stg.parse_date(r.forecast_date) AS forecast_date,
       stg.parse_date(r.actual_date) AS actual_date, TRIM(r.status) AS status,
       CASE WHEN p.project_id IS NULL THEN 'orphan_project_fk' END AS reason1
FROM raw.schedule_milestones r LEFT JOIN stg.projects p ON p.project_id = TRIM(r.project_id);

CREATE TEMP TABLE _ms_cls AS
SELECT b.*, COALESCE(b.reason1, CASE WHEN ROW_NUMBER() OVER (PARTITION BY b.milestone_id, (b.reason1 IS NULL) ORDER BY b.milestone_id) > 1
                                     THEN 'duplicate_milestone' END) AS reject_reason
FROM _ms_base b;

CREATE OR REPLACE TABLE stg.schedule_milestones AS
SELECT milestone_id, project_id, milestone_name, planned_date, forecast_date, actual_date, status
FROM _ms_cls WHERE reject_reason IS NULL;

INSERT INTO stg.rejects
SELECT 'schedule_milestones', milestone_id, reject_reason, CAST(to_json(raw_row) AS VARCHAR), current_timestamp::TIMESTAMP
FROM _ms_cls WHERE reject_reason IS NOT NULL;

-- Row-level audit of what staging did to each raw table (feeds the runbook and the DQ page).
CREATE OR REPLACE VIEW ops.staging_audit AS
SELECT t.table_name, t.raw_rows, t.staged_rows, COALESCE(r.rejected_rows, 0) AS rejected_rows
FROM (
    SELECT 'actual_costs' AS table_name, (SELECT COUNT(*) FROM raw.actual_costs) AS raw_rows, (SELECT COUNT(*) FROM stg.actual_costs) AS staged_rows UNION ALL
    SELECT 'billings',          (SELECT COUNT(*) FROM raw.billings),          (SELECT COUNT(*) FROM stg.billings)          UNION ALL
    SELECT 'change_orders',     (SELECT COUNT(*) FROM raw.change_orders),     (SELECT COUNT(*) FROM stg.change_orders)     UNION ALL
    SELECT 'timecards',         (SELECT COUNT(*) FROM raw.timecards),         (SELECT COUNT(*) FROM stg.timecards)         UNION ALL
    SELECT 'safety_incidents',  (SELECT COUNT(*) FROM raw.safety_incidents),  (SELECT COUNT(*) FROM stg.safety_incidents)  UNION ALL
    SELECT 'opportunities',     (SELECT COUNT(*) FROM raw.opportunities),     (SELECT COUNT(*) FROM stg.opportunities)     UNION ALL
    SELECT 'purchase_orders', (SELECT COUNT(*) FROM raw.purchase_orders), (SELECT COUNT(*) FROM stg.purchase_orders)  UNION ALL
    SELECT 'po_receipts', (SELECT COUNT(*) FROM raw.po_receipts), (SELECT COUNT(*) FROM stg.po_receipts)  UNION ALL
    SELECT 'ap_invoices', (SELECT COUNT(*) FROM raw.ap_invoices), (SELECT COUNT(*) FROM stg.ap_invoices)  UNION ALL
    SELECT 'subcontract_pay_apps', (SELECT COUNT(*) FROM raw.subcontract_pay_apps), (SELECT COUNT(*) FROM stg.subcontract_pay_apps)  UNION ALL
    SELECT 'equipment_usage', (SELECT COUNT(*) FROM raw.equipment_usage), (SELECT COUNT(*) FROM stg.equipment_usage)  UNION ALL
    SELECT 'inventory_items', (SELECT COUNT(*) FROM raw.inventory_items), (SELECT COUNT(*) FROM stg.inventory_items)  UNION ALL
    SELECT 'rfis', (SELECT COUNT(*) FROM raw.rfis), (SELECT COUNT(*) FROM stg.rfis)  UNION ALL
    SELECT 'submittals', (SELECT COUNT(*) FROM raw.submittals), (SELECT COUNT(*) FROM stg.submittals)  UNION ALL
    SELECT 'schedule_milestones', (SELECT COUNT(*) FROM raw.schedule_milestones), (SELECT COUNT(*) FROM stg.schedule_milestones)  UNION ALL
    SELECT 'bids',              (SELECT COUNT(*) FROM raw.bids),              (SELECT COUNT(*) FROM stg.bids)
) t
LEFT JOIN (SELECT source_table, COUNT(*) AS rejected_rows FROM stg.rejects GROUP BY source_table) r ON r.source_table = t.table_name;
