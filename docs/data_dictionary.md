# Data dictionary

> **Synthetic data.** Gulf Coast Builders is fictional. This file is **generated** from the live warehouse by `src/make_data_dictionary.py` (run by `run_all.py`), so it matches the schema exactly. Column descriptions come from naming conventions plus overrides for columns that need explaining; table-level meaning is in `docs/data_model.md`.

Money is US dollars (`DECIMAL(18,2)`); ratios are decimals (0.095 = 9.5%); dates are `DATE`. As-of date: see `ops.etl_params`.

## Layers at a glance

| Schema | Purpose | Objects |
|---|---|---|
| `raw` | Source exports as delivered (all text) | 24 |
| `stg` | Typed, cleaned, de-duplicated; rejects quarantined | 26 |
| `mart` | Star schema for analysis | 24 |
| `metrics` | One SQL view per business metric | 38 |
| `ops` | Run parameters, audit, data-quality results | 4 |

## Raw layer (`raw`)

| Table | Rows | Columns |
|---|---:|---|
| `accounts` | 28 | account_id, account_name, segment, region, created_date |
| `actual_costs` | 1,495 | cost_id, project_id, cost_code, period, amount, vendor_name, source_system, description |
| `ap_invoices` | 489 | invoice_id, invoice_no, po_line_id, project_id, cost_code, vendor_name, invoice_date, due_date, amount, paid_date, status |
| `bids` | 59 | bid_id, opportunity_id, bid_date, bid_amount, estimated_cost, competitor_count, result, loss_reason, bid_margin_pct |
| `billings` | 209 | billing_id, project_id, pay_app_no, period_end, invoice_no, gross_billed, retainage_held, status, submitted_date, due_date, paid_date |
| `budget_lines` | 114 | budget_line_id, project_id, cost_code, original_budget, approved_co_budget, revised_budget, estimate_to_complete, etc_updated_date |
| `change_orders` | 91 | change_order_id, project_id, co_number, description, reason, submitted_date, decision_date, status, amount, estimated_cost |
| `commitments` | 134 | commitment_id, project_id, cost_code, vendor_name, commitment_type, original_amount, approved_changes, status, executed_date |
| `cost_codes` | 14 | cost_code, cost_code_name, category, division |
| `employees` | 173 | employee_id, full_name, role, business_unit, is_field, hire_date, hourly_rate, email |
| `equipment` | 18 | equipment_id, equipment_name, category, ownership, daily_rate, vendor_name |
| `equipment_usage` | 362 | usage_id, equipment_id, project_id, month_end, days_used, standby_days, usage_cost |
| `inventory_items` | 16 | item_id, item_name, uom, on_hand_qty, reorder_point, reorder_qty, unit_cost, avg_daily_usage, lead_time_days, preferred_vendor_name, last_receipt_date, as_of_date |
| `opportunities` | 78 | opportunity_id, account_id, opportunity_name, business_unit, stage, amount, probability, created_date, expected_close_date, closed_date, owner, lead_source |
| `po_receipts` | 499 | receipt_id, po_line_id, receipt_date, received_qty, received_amount, condition |
| `projects` | 12 | project_id, project_name, business_unit, account_id, pm_employee_id, start_date, planned_end_date, original_contract_value, status, opportunity_id |
| `purchase_orders` | 514 | po_line_id, po_number, commitment_id, project_id, cost_code, vendor_name, item_description, quantity, uom, unit_price, ordered_amount, order_date, promised_date, ship_date, received_date, status, is_long_lead |
| `rfis` | 208 | rfi_id, project_id, rfi_number, subject, discipline, submitted_date, due_date, response_date, status, cost_impact_flag, schedule_impact_days, ball_in_court |
| `safety_incidents` | 33 | incident_id, project_id, incident_date, incident_type, cause_category, employee_id, recordable_flag, days_away, severity, description |
| `schedule_milestones` | 73 | milestone_id, project_id, milestone_name, planned_date, forecast_date, actual_date, status |
| `subcontract_pay_apps` | 370 | sub_pay_app_id, commitment_id, project_id, cost_code, vendor_name, period_end, gross_billed, retainage_held, invoice_date, due_date, paid_amount, paid_date, status, retainage_released, retainage_release_date |
| `submittals` | 295 | submittal_id, project_id, spec_section, description, required_by_date, submitted_date, returned_date, status, cycle_count |
| `timecards` | 14,313 | timecard_id, employee_id, project_id, week_ending, regular_hours, overtime_hours |
| `vendors` | 16 | vendor_id, vendor_name, vendor_type, trade, payment_terms_days |

## Staging layer (`stg`)

| Table | Rows | Columns |
|---|---:|---|
| `accounts` | 28 | account_id, account_name, segment, region, created_date |
| `actual_costs` | 1,459 | cost_id, project_id, cost_code, period, amount, vendor_std, vendor_raw, source_system, description, is_credit_memo |
| `ap_invoices` | 481 | invoice_id, invoice_no, po_line_id, project_id, cost_code, vendor_std, invoice_date, due_date, amount, paid_date, status |
| `bids` | 57 | bid_id, opportunity_id, bid_date, bid_amount, estimated_cost, bid_margin_pct, competitor_count, result, loss_reason |
| `billings` | 202 | billing_id, project_id, pay_app_no, period_end, invoice_no, gross_billed, retainage_held, status, submitted_date, due_date, paid_date |
| `budget_lines` | 114 | budget_line_id, project_id, cost_code, original_budget, approved_co_budget, revised_budget, estimate_to_complete, etc_updated_date |
| `change_orders` | 89 | change_order_id, project_id, co_number, description, reason, submitted_date, decision_date, status, amount, estimated_cost |
| `commitments` | 134 | commitment_id, project_id, cost_code, vendor_std, vendor_raw, commitment_type, original_amount, approved_changes, status, executed_date |
| `cost_codes` | 14 | cost_code, cost_code_name, category, division |
| `employees` | 173 | employee_id, full_name, role, business_unit, is_field, hire_date, hourly_rate, email |
| `equipment` | 18 | equipment_id, equipment_name, category, ownership, daily_rate, vendor_std |
| `equipment_usage` | 357 | usage_id, equipment_id, project_id, month_end, days_used, standby_days, usage_cost |
| `inventory_items` | 14 | item_id, item_name, uom, on_hand_qty, reorder_point, reorder_qty, unit_cost, avg_daily_usage, lead_time_days, preferred_vendor_std, last_receipt_date, snapshot_date |
| `opportunities` | 77 | opportunity_id, account_id, opportunity_name, business_unit, stage, amount, probability, created_date, expected_close_date, closed_date, owner, lead_source |
| `po_receipts` | 494 | receipt_id, po_line_id, receipt_date, received_qty, received_amount, condition |
| `projects` | 12 | project_id, project_name, business_unit, account_id, pm_employee_id, start_date, planned_end_date, original_contract_value, status, opportunity_id |
| `purchase_orders` | 505 | po_line_id, po_number, commitment_id, project_id, cost_code, vendor_std, vendor_raw, item_description, quantity, uom, unit_price, ordered_amount, order_date, promised_date, ship_date, received_date, status, is_long_lead |
| `rejects` | 92 | source_table, source_key, reject_reason, raw_row_json, rejected_at |
| `rfis` | 206 | rfi_id, project_id, rfi_number, subject, discipline, submitted_date, due_date, response_date, status, has_cost_impact, schedule_impact_days, ball_in_court |
| `safety_incidents` | 32 | incident_id, project_id, incident_date, incident_type, cause_category, employee_id, recordable_flag, days_away, severity, description |
| `schedule_milestones` | 72 | milestone_id, project_id, milestone_name, planned_date, forecast_date, actual_date, status |
| `subcontract_pay_apps` | 367 | sub_pay_app_id, commitment_id, project_id, cost_code, vendor_std, period_end, gross_billed, retainage_held, invoice_date, due_date, paid_amount, paid_date, status, retainage_released, retainage_release_date |
| `submittals` | 294 | submittal_id, project_id, spec_section, description, required_by_date, submitted_date, returned_date, status, cycle_count |
| `timecards` | 14,306 | timecard_id, employee_id, project_id, week_ending, regular_hours, overtime_hours |
| `vendor_map` | 49 | raw_name, vendor_key, vendor_std, raw_occurrences |
| `vendors` | 16 | vendor_id, vendor_name, vendor_type, trade, payment_terms_days |

## Mart layer (`mart`)

### `mart.dim_account`  (28 rows)

Customers (owners): public agencies and private developers.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `account_key` | BIGINT | yes | Surrogate key. |
| `account_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `account_name` | VARCHAR | yes | Name. |
| `segment` | VARCHAR | yes |  |
| `region` | VARCHAR | yes |  |

### `mart.dim_cost_code`  (14 rows)

Chart of cost codes (NN-NNN) with category (Subcontract, Material, Labor, Equipment, Indirect).

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `cost_code_key` | BIGINT | yes | Surrogate key. |
| `cost_code` | VARCHAR | yes | Cost code in NN-NNN form. |
| `cost_code_name` | VARCHAR | yes | US dollars. |
| `category` | VARCHAR | yes |  |
| `division` | VARCHAR | yes |  |

### `mart.dim_date`  (1,553 rows)

One row per calendar day, 2024-10-01 to 2028-12-31. Weeks end Saturday.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `date_key` | INTEGER | yes | Surrogate key. |
| `date` | DATE | yes |  |
| `year` | BIGINT | yes |  |
| `quarter` | BIGINT | yes |  |
| `month` | BIGINT | yes |  |
| `month_name` | VARCHAR | yes | Name. |
| `year_month` | VARCHAR | yes |  |
| `week_ending` | DATE | yes |  |
| `is_month_end` | BOOLEAN | yes | True/false flag. |
| `is_past_as_of` | BOOLEAN | yes | True/false flag. |

### `mart.dim_employee`  (173 rows)

People. Pay rate and email are deliberately NOT carried into the mart.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `employee_key` | BIGINT | yes | Surrogate key. |
| `employee_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `full_name` | VARCHAR | yes | Name. |
| `role` | VARCHAR | yes |  |
| `business_unit` | VARCHAR | yes |  |
| `is_field` | BOOLEAN | yes | True/false flag. |
| `hire_date` | DATE | yes | Calendar date. |

### `mart.dim_equipment`  (18 rows)

Owned and rented equipment units with daily rate.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `equipment_key` | BIGINT | yes | Surrogate key. |
| `equipment_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `equipment_name` | VARCHAR | yes | Name. |
| `category` | VARCHAR | yes |  |
| `ownership` | VARCHAR | yes |  |
| `daily_rate` | DECIMAL(18,2) | yes | Ratio, stored as a decimal (0.095 = 9.5%). |

### `mart.dim_project`  (12 rows)

One row per project: owner, manager, dates, contract value, bid margin, status.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `project_id` | VARCHAR | yes | Project number, e.g. P-101 (natural key). |
| `project_name` | VARCHAR | yes | Name. |
| `business_unit` | VARCHAR | yes |  |
| `account_key` | BIGINT | yes | Surrogate key. |
| `pm_employee_key` | BIGINT | yes | Surrogate key. |
| `start_date` | DATE | yes | Calendar date. |
| `planned_end_date` | DATE | yes | Calendar date. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `original_contract_value` | DECIMAL(18,2) | yes | US dollars. |
| `original_budget_cost` | DECIMAL(38,2) | yes | US dollars. |
| `original_margin_pct` | DOUBLE | yes | Ratio, stored as a decimal (0.095 = 9.5%). |
| `opportunity_id` | VARCHAR | yes | Identifier (natural key or foreign key). |

### `mart.dim_vendor`  (16 rows)

Suppliers and subcontractors (master list used to standardise vendor spellings).

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `vendor_key` | BIGINT | yes | Surrogate key. |
| `vendor_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `vendor_name` | VARCHAR | yes | Standardised vendor name. |
| `vendor_type` | VARCHAR | yes |  |
| `trade` | VARCHAR | yes |  |
| `payment_terms_days` | INTEGER | yes | Days. |

### `mart.fact_ap_invoice`  (481 rows)

Vendor invoices against PO lines.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `vendor_key` | BIGINT | yes | Surrogate key. |
| `invoice_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `invoice_no` | VARCHAR | yes |  |
| `po_line_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `invoice_date` | DATE | yes | Calendar date. |
| `due_date` | DATE | yes | Calendar date. |
| `paid_date` | DATE | yes | Calendar date. |
| `amount` | DECIMAL(18,2) | yes | US dollars. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |

### `mart.fact_billing`  (202 rows)

Owner pay applications: gross billed, retainage, submit, due and paid dates.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `date_key` | INTEGER | yes | Surrogate key. |
| `billing_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `invoice_no` | VARCHAR | yes |  |
| `pay_app_no` | INTEGER | yes |  |
| `gross_billed` | DECIMAL(18,2) | yes | US dollars. |
| `retainage_held` | DECIMAL(18,2) | yes | Amount withheld from the payment (10%). |
| `net_billed` | DECIMAL(18,2) | yes | US dollars. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `submitted_date` | DATE | yes | Calendar date. |
| `due_date` | DATE | yes | Calendar date. |
| `paid_date` | DATE | yes | Calendar date. |

### `mart.fact_budget`  (114 rows)

Budget by project and cost code: original, revised, estimate to complete.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `cost_code_key` | BIGINT | yes | Surrogate key. |
| `original_budget` | DECIMAL(18,2) | yes | US dollars. |
| `approved_co_budget` | DECIMAL(18,2) | yes | US dollars. |
| `revised_budget` | DECIMAL(18,2) | yes | US dollars. |
| `estimate_to_complete` | DECIMAL(18,2) | yes |  |

### `mart.fact_change_order`  (89 rows)

Change orders with status, amount, estimated cost and age.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `submitted_date_key` | INTEGER | yes | Surrogate key. |
| `decision_date_key` | INTEGER | yes | Surrogate key. |
| `change_order_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `co_number` | INTEGER | yes |  |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `amount` | DECIMAL(18,2) | yes | US dollars. |
| `estimated_cost` | DECIMAL(18,2) | yes | US dollars. |
| `reason` | VARCHAR | yes |  |
| `description` | VARCHAR | yes |  |
| `age_days` | BIGINT | yes | Days. |
| `cycle_days` | BIGINT | yes | Days. |

### `mart.fact_commitment`  (134 rows)

Subcontracts and PO commitments with billed, paid and retainage rolled up.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `cost_code_key` | BIGINT | yes | Surrogate key. |
| `vendor_key` | BIGINT | yes | Surrogate key. |
| `commitment_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `commitment_type` | VARCHAR | yes |  |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `original_amount` | DECIMAL(18,2) | yes | US dollars. |
| `approved_changes` | DECIMAL(18,2) | yes |  |
| `committed_total` | DECIMAL(18,2) | yes |  |
| `billed_to_date` | DECIMAL(38,2) | yes | Calendar date. |
| `paid_to_date` | DECIMAL(38,2) | yes | Calendar date. |
| `retainage_held` | DECIMAL(38,2) | yes | Amount withheld from the payment (10%). |
| `retainage_released` | DECIMAL(38,2) | yes | US dollars. |
| `disputed_amount` | DECIMAL(38,2) | yes | US dollars. |
| `executed_date` | DATE | yes | Calendar date. |

### `mart.fact_cost`  (1,459 rows)

Actual cost postings by project, cost code and month (AP, payroll, equipment).

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `cost_code_key` | BIGINT | yes | Surrogate key. |
| `date_key` | INTEGER | yes | Surrogate key. |
| `cost_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `actual_cost` | DECIMAL(18,2) | yes | US dollars. |
| `vendor_std` | VARCHAR | yes |  |
| `source_system` | VARCHAR | yes |  |
| `is_credit_memo` | BOOLEAN | yes | True/false flag. |

### `mart.fact_equipment_usage`  (357 rows)

Equipment days used, standby days and cost by unit, project and month.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `equipment_key` | BIGINT | yes | Surrogate key. |
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `month_end_date_key` | INTEGER | yes | Surrogate key. |
| `usage_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `days_used` | INTEGER | yes | Days. |
| `standby_days` | INTEGER | yes | Days. |
| `usage_cost` | DECIMAL(18,2) | yes | US dollars. |

### `mart.fact_hours`  (841 rows)

Field hours by project and week ending (denominator for safety rates).

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `date_key` | INTEGER | yes | Surrogate key. |
| `hours` | DECIMAL(38,1) | yes | Hours worked. |
| `worker_count` | BIGINT | yes | Count. |

### `mart.fact_inventory`  (14 rows)

Manufacturing stock snapshot: on hand, reorder point, usage, lead time.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `item_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `item_name` | VARCHAR | yes | Name. |
| `uom` | VARCHAR | yes |  |
| `on_hand_qty` | DECIMAL(18,2) | yes | Quantity in the item's unit of measure. |
| `reorder_point` | DECIMAL(18,2) | yes |  |
| `reorder_qty` | DECIMAL(18,2) | yes | Quantity in the item's unit of measure. |
| `unit_cost` | DECIMAL(18,2) | yes | US dollars. |
| `avg_daily_usage` | DECIMAL(18,3) | yes |  |
| `lead_time_days` | INTEGER | yes | Days. |
| `preferred_vendor_key` | BIGINT | yes | Surrogate key. |
| `last_receipt_date` | DATE | yes | Calendar date. |
| `snapshot_date` | DATE | yes | Calendar date. |

### `mart.fact_milestone`  (72 rows)

Schedule milestones: planned, forecast and actual dates.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `milestone_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `milestone_name` | VARCHAR | yes | Name. |
| `planned_date` | DATE | yes | Calendar date. |
| `forecast_date` | DATE | yes | Calendar date. |
| `actual_date` | DATE | yes | Calendar date. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |

### `mart.fact_pipeline`  (77 rows)

CRM opportunities with stage, amount, probability and linked bid margin.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `account_key` | BIGINT | yes | Surrogate key. |
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `created_date_key` | INTEGER | yes | Surrogate key. |
| `expected_close_date_key` | INTEGER | yes | Surrogate key. |
| `closed_date_key` | INTEGER | yes | Surrogate key. |
| `opportunity_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `opportunity_name` | VARCHAR | yes | Name. |
| `business_unit` | VARCHAR | yes |  |
| `stage` | VARCHAR | yes |  |
| `amount` | DECIMAL(18,2) | yes | US dollars. |
| `probability` | DECIMAL(5,2) | yes | Ratio, stored as a decimal (0.095 = 9.5%). |
| `weighted_amount` | DECIMAL(18,4) | yes | US dollars. |
| `is_open` | BOOLEAN | yes | True/false flag. |
| `is_won` | BOOLEAN | yes | True/false flag. |
| `is_lost` | BOOLEAN | yes | True/false flag. |
| `is_awarded_unstarted` | BOOLEAN | yes | True/false flag. |
| `bid_amount` | DECIMAL(18,2) | yes | US dollars. |
| `bid_margin_pct` | DECIMAL(8,4) | yes | Ratio, stored as a decimal (0.095 = 9.5%). |
| `owner` | VARCHAR | yes |  |
| `lead_source` | VARCHAR | yes |  |

### `mart.fact_purchase_order`  (505 rows)

Purchase-order lines: item, quantity, price, promised/ship/receive dates, status.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `cost_code_key` | BIGINT | yes | Surrogate key. |
| `vendor_key` | BIGINT | yes | Surrogate key. |
| `po_line_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `po_number` | VARCHAR | yes |  |
| `commitment_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `item_description` | VARCHAR | yes |  |
| `uom` | VARCHAR | yes |  |
| `quantity` | DECIMAL(18,2) | yes | Quantity in the item's unit of measure. |
| `unit_price` | DECIMAL(18,2) | yes | US dollars. |
| `ordered_amount` | DECIMAL(18,2) | yes | US dollars. |
| `order_date` | DATE | yes | Calendar date. |
| `promised_date` | DATE | yes | Calendar date. |
| `ship_date` | DATE | yes | Calendar date. |
| `received_date` | DATE | yes | Calendar date. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `is_long_lead` | BOOLEAN | yes | True/false flag. |

### `mart.fact_receipt`  (494 rows)

Delivery receipts against PO lines.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `receipt_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `po_line_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `receipt_date_key` | INTEGER | yes | Surrogate key. |
| `received_qty` | DECIMAL(18,2) | yes | Quantity in the item's unit of measure. |
| `received_amount` | DECIMAL(18,2) | yes | US dollars. |
| `condition` | VARCHAR | yes |  |

### `mart.fact_rfi`  (206 rows)

Requests for information: submitted, due, response, cost and schedule impact.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `rfi_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `rfi_number` | INTEGER | yes |  |
| `subject` | VARCHAR | yes |  |
| `discipline` | VARCHAR | yes |  |
| `submitted_date` | DATE | yes | Calendar date. |
| `due_date` | DATE | yes | Calendar date. |
| `response_date` | DATE | yes | Calendar date. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `has_cost_impact` | BOOLEAN | yes | US dollars. |
| `schedule_impact_days` | INTEGER | yes | Days. |
| `ball_in_court` | VARCHAR | yes |  |

### `mart.fact_safety`  (32 rows)

Safety incidents (confidential).

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `date_key` | INTEGER | yes | Surrogate key. |
| `employee_key` | BIGINT | yes | Surrogate key. |
| `incident_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `incident_type` | VARCHAR | yes |  |
| `cause_category` | VARCHAR | yes |  |
| `severity` | INTEGER | yes |  |
| `recordable_flag` | VARCHAR | yes | Y for recordable and lost-time incidents. |
| `days_away` | INTEGER | yes | Days. |
| `description` | VARCHAR | yes |  |

### `mart.fact_sub_pay_app`  (367 rows)

Subcontractor pay applications (gross, retainage, net due, paid).

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `vendor_key` | BIGINT | yes | Surrogate key. |
| `period_end_date_key` | INTEGER | yes | Surrogate key. |
| `sub_pay_app_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `commitment_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `gross_billed` | DECIMAL(18,2) | yes | US dollars. |
| `retainage_held` | DECIMAL(18,2) | yes | Amount withheld from the payment (10%). |
| `net_due` | DECIMAL(18,2) | yes |  |
| `paid_amount` | DECIMAL(18,2) | yes | US dollars. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `invoice_date` | DATE | yes | Calendar date. |
| `due_date` | DATE | yes | Calendar date. |
| `paid_date` | DATE | yes | Calendar date. |
| `retainage_released` | DECIMAL(18,2) | yes | US dollars. |

### `mart.fact_submittal`  (294 rows)

Submittals: required-by, submitted, returned, review cycles.

| Column | Type | Null? | Meaning |
|---|---|---|---|
| `project_key` | BIGINT | yes | Surrogate key to dim_project. |
| `submittal_id` | VARCHAR | yes | Identifier (natural key or foreign key). |
| `spec_section` | VARCHAR | yes |  |
| `description` | VARCHAR | yes |  |
| `required_by_date` | DATE | yes | Calendar date. |
| `submitted_date` | DATE | yes | Calendar date. |
| `returned_date` | DATE | yes | Calendar date. |
| `status` | VARCHAR | yes | Current status (domain varies by table). |
| `cycle_count` | INTEGER | yes | Count. |

## Metric views (`metrics`)

Each view's logic and plain-English definition is in `sql/05_metrics.sql` and `docs/metric_definitions.md`.

### `metrics.v_aging_summary`  (9 rows)

| Column | Type | Meaning |
|---|---|---|
| `ledger` | VARCHAR |  |
| `aging_bucket` | VARCHAR | Days-past-due bucket: 1 Current, 2 1-30, 3 31-60, 4 61-90, 5 90+. |
| `items` | BIGINT | Count. |
| `amount_open` | DECIMAL(38,2) | Unpaid amount (AR is net of retainage). |

### `metrics.v_ap_open_items`  (92 rows)

| Column | Type | Meaning |
|---|---|---|
| `source` | VARCHAR |  |
| `reference_id` | VARCHAR | Identifier (natural key or foreign key). |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `vendor_name` | VARCHAR | Standardised vendor name. |
| `invoice_date` | DATE | Calendar date. |
| `due_date` | DATE | Calendar date. |
| `amount_open` | DECIMAL(18,2) | Unpaid amount (AR is net of retainage). |
| `status` | VARCHAR | Current status (domain varies by table). |
| `is_held` | BOOLEAN | True/false flag. |
| `days_past_due` | BIGINT | As-of date minus due date. |
| `aging_bucket` | VARCHAR | Days-past-due bucket: 1 Current, 2 1-30, 3 31-60, 4 61-90, 5 90+. |

### `metrics.v_ar_open_items`  (16 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `account_name` | VARCHAR | Name. |
| `billing_id` | VARCHAR | Identifier (natural key or foreign key). |
| `invoice_no` | VARCHAR |  |
| `pay_app_no` | INTEGER |  |
| `submitted_date` | DATE | Calendar date. |
| `due_date` | DATE | Calendar date. |
| `amount_open` | DECIMAL(18,2) | Unpaid amount (AR is net of retainage). |
| `retainage_held` | DECIMAL(18,2) | Amount withheld from the payment (10%). |
| `status` | VARCHAR | Current status (domain varies by table). |
| `days_past_due` | BIGINT | As-of date minus due date. |
| `aging_bucket` | VARCHAR | Days-past-due bucket: 1 Current, 2 1-30, 3 31-60, 4 61-90, 5 90+. |

### `metrics.v_backlog`  (13 rows)

| Column | Type | Meaning |
|---|---|---|
| `backlog_source` | VARCHAR |  |
| `reference_id` | VARCHAR | Identifier (natural key or foreign key). |
| `reference_name` | VARCHAR | Name. |
| `business_unit` | VARCHAR |  |
| `backlog_amount` | DOUBLE | Contracted work not yet performed (or awarded, not started). |

### `metrics.v_change_order_detail`  (89 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `change_order_id` | VARCHAR | Identifier (natural key or foreign key). |
| `co_number` | INTEGER |  |
| `description` | VARCHAR |  |
| `reason` | VARCHAR |  |
| `status` | VARCHAR | Current status (domain varies by table). |
| `amount` | DECIMAL(18,2) | US dollars. |
| `estimated_cost` | DECIMAL(18,2) | US dollars. |
| `submitted_date` | DATE | Calendar date. |
| `decision_date` | DATE | Calendar date. |
| `age_days` | BIGINT | Days. |
| `cycle_days` | BIGINT | Days. |

### `metrics.v_change_order_exposure`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `status` | VARCHAR | Current status (domain varies by table). |
| `pending_co_count` | BIGINT | Count. |
| `pending_co_revenue` | DECIMAL(38,2) | US dollars. |
| `pending_co_cost_at_risk` | DECIMAL(38,2) | US dollars. |
| `oldest_pending_age_days` | BIGINT | Days. |
| `avg_pending_age_days` | DOUBLE | Days. |
| `pending_pct_of_contract` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `approved_co_count` | BIGINT | Count. |
| `approved_co_revenue` | DECIMAL(38,2) | US dollars. |
| `rejected_co_count` | BIGINT | Count. |
| `avg_approval_cycle_days` | DOUBLE | Days. |

### `metrics.v_commitment_vs_budget`  (72 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `cost_code` | VARCHAR | Cost code in NN-NNN form. |
| `cost_code_name` | VARCHAR | US dollars. |
| `category` | VARCHAR |  |
| `revised_budget` | DECIMAL(18,2) | US dollars. |
| `committed_total` | DECIMAL(38,2) |  |
| `actual_cost` | DECIMAL(38,2) | US dollars. |
| `estimated_cost_at_completion` | DECIMAL(38,2) | US dollars. |
| `committed_over_budget` | DECIMAL(38,2) | US dollars. |
| `is_over_committed` | BOOLEAN | True/false flag. |

### `metrics.v_equipment_by_project`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `units_used` | BIGINT |  |
| `usage_cost` | DECIMAL(38,2) | US dollars. |
| `utilization` | DOUBLE | Days used / (22 x unit-months). |
| `standby_days` | HUGEINT | Days. |
| `rented_idle_cost` | DECIMAL(38,2) | Standby days x daily rate, rented units only. |
| `rented_cost` | DECIMAL(38,2) | US dollars. |
| `owned_cost` | DECIMAL(38,2) | US dollars. |

### `metrics.v_equipment_by_unit`  (18 rows)

| Column | Type | Meaning |
|---|---|---|
| `equipment_id` | VARCHAR | Identifier (natural key or foreign key). |
| `equipment_name` | VARCHAR | Name. |
| `category` | VARCHAR |  |
| `ownership` | VARCHAR |  |
| `daily_rate` | DECIMAL(18,2) | Ratio, stored as a decimal (0.095 = 9.5%). |
| `unit_months` | BIGINT |  |
| `days_used` | HUGEINT | Days. |
| `standby_days` | HUGEINT | Days. |
| `utilization` | DOUBLE | Days used / (22 x unit-months). |
| `usage_cost` | DECIMAL(38,2) | US dollars. |
| `rented_idle_cost` | DECIMAL(38,2) | Standby days x daily rate, rented units only. |

### `metrics.v_equipment_usage_detail`  (103 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `equipment_id` | VARCHAR | Identifier (natural key or foreign key). |
| `equipment_name` | VARCHAR | Name. |
| `category` | VARCHAR |  |
| `ownership` | VARCHAR |  |
| `daily_rate` | DECIMAL(18,2) | Ratio, stored as a decimal (0.095 = 9.5%). |
| `unit_months` | BIGINT |  |
| `days_used` | HUGEINT | Days. |
| `standby_days` | HUGEINT | Days. |
| `usage_cost` | DECIMAL(38,2) | US dollars. |
| `rented_idle_cost` | DECIMAL(38,2) | Standby days x daily rate, rented units only. |

### `metrics.v_inventory_status`  (14 rows)

| Column | Type | Meaning |
|---|---|---|
| `item_id` | VARCHAR | Identifier (natural key or foreign key). |
| `item_name` | VARCHAR | Name. |
| `uom` | VARCHAR |  |
| `on_hand_qty` | DECIMAL(18,2) | Quantity in the item's unit of measure. |
| `reorder_point` | DECIMAL(18,2) |  |
| `reorder_qty` | DECIMAL(18,2) | Quantity in the item's unit of measure. |
| `unit_cost` | DECIMAL(18,2) | US dollars. |
| `avg_daily_usage` | DECIMAL(18,3) |  |
| `lead_time_days` | INTEGER | Days. |
| `preferred_vendor` | VARCHAR |  |
| `last_receipt_date` | DATE | Calendar date. |
| `stock_value` | DECIMAL(18,4) | US dollars. |
| `days_of_cover` | DOUBLE | On hand / average daily usage. |
| `reorder_status` | VARCHAR | Below reorder point, Low or OK. |
| `stockout_risk` | BOOLEAN | Days of cover shorter than supplier lead time. |
| `shortfall_to_reorder_point` | DECIMAL(18,2) |  |
| `suggested_order_value` | DECIMAL(18,4) | US dollars. |

### `metrics.v_long_lead_watch`  (19 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `po_line_id` | VARCHAR | Identifier (natural key or foreign key). |
| `po_number` | VARCHAR |  |
| `vendor_name` | VARCHAR | Standardised vendor name. |
| `item_description` | VARCHAR |  |
| `ordered_amount` | DECIMAL(18,2) | US dollars. |
| `status` | VARCHAR | Current status (domain varies by table). |
| `order_date` | DATE | Calendar date. |
| `promised_date` | DATE | Calendar date. |
| `ship_date` | DATE | Calendar date. |
| `days_overdue` | BIGINT | Days. |
| `risk` | VARCHAR |  |

### `metrics.v_milestone_detail`  (72 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `milestone_id` | VARCHAR | Identifier (natural key or foreign key). |
| `milestone_name` | VARCHAR | Name. |
| `planned_date` | DATE | Calendar date. |
| `forecast_date` | DATE | Calendar date. |
| `actual_date` | DATE | Calendar date. |
| `status` | VARCHAR | Current status (domain varies by table). |
| `slip_days` | BIGINT | Days. |

### `metrics.v_pipeline_by_bu`  (3 rows)

| Column | Type | Meaning |
|---|---|---|
| `business_unit` | VARCHAR |  |
| `open_count` | BIGINT | Count. |
| `open_amount` | DECIMAL(38,2) | US dollars. |
| `weighted_pipeline` | DECIMAL(38,4) | Sum of amount x stage probability, open deals. |
| `won_count` | BIGINT | Count. |
| `lost_count` | BIGINT | Count. |
| `win_rate` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `win_rate_by_value` | DOUBLE | US dollars. |

### `metrics.v_pipeline_by_stage`  (18 rows)

| Column | Type | Meaning |
|---|---|---|
| `business_unit` | VARCHAR |  |
| `stage` | VARCHAR |  |
| `stage_order` | INTEGER |  |
| `opportunity_count` | BIGINT | Count. |
| `total_amount` | DECIMAL(38,2) | US dollars. |
| `weighted_amount` | DECIMAL(38,4) | US dollars. |

### `metrics.v_po_line_status`  (505 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `vendor_name` | VARCHAR | Standardised vendor name. |
| `vendor_type` | VARCHAR |  |
| `cost_code` | VARCHAR | Cost code in NN-NNN form. |
| `cost_code_name` | VARCHAR | US dollars. |
| `po_line_id` | VARCHAR | Identifier (natural key or foreign key). |
| `po_number` | VARCHAR |  |
| `item_description` | VARCHAR |  |
| `uom` | VARCHAR |  |
| `is_long_lead` | BOOLEAN | True/false flag. |
| `status` | VARCHAR | Current status (domain varies by table). |
| `ordered_amount` | DECIMAL(18,2) | US dollars. |
| `quantity` | DECIMAL(18,2) | Quantity in the item's unit of measure. |
| `order_date` | DATE | Calendar date. |
| `promised_date` | DATE | Calendar date. |
| `ship_date` | DATE | Calendar date. |
| `received_date` | DATE | Calendar date. |
| `received_qty` | DECIMAL(38,2) | Quantity in the item's unit of measure. |
| `received_amount` | DECIMAL(38,2) | US dollars. |
| `last_receipt_date` | DATE | Calendar date. |
| `invoiced_amount` | DECIMAL(38,2) | US dollars. |
| `on_hold_amount` | DECIMAL(38,2) | US dollars. |
| `receipt_count` | BIGINT | Count. |
| `invoice_count` | BIGINT | Count. |
| `is_open` | BOOLEAN | True/false flag. |
| `days_late_delivered` | BIGINT | Received date minus promised date (negative = early). |
| `is_overdue_open` | BOOLEAN | Open PO line past its promised date. |
| `days_overdue` | BIGINT | Days. |
| `received_not_invoiced` | BOOLEAN |  |
| `invoiced_not_received` | BOOLEAN |  |
| `price_variance_pct` | DOUBLE | (Invoiced - received value) / received value. |

### `metrics.v_portfolio_kpis`  (1 rows)

| Column | Type | Meaning |
|---|---|---|
| `as_of_date` | DATE | Reporting date for the run (ops.etl_params). |
| `active_jobs` | BIGINT |  |
| `active_contract_value` | DECIMAL(38,2) | US dollars. |
| `portfolio_projected_margin` | DOUBLE |  |
| `portfolio_bid_margin` | DOUBLE |  |
| `pending_co_revenue` | DECIMAL(38,2) | US dollars. |
| `pending_co_cost_at_risk` | DECIMAL(38,2) | US dollars. |
| `pending_co_count` | HUGEINT | Count. |
| `jobs_with_fade` | HUGEINT |  |
| `top3_share_of_fade` | DOUBLE |  |
| `gross_overbilling` | DOUBLE |  |
| `gross_underbilling` | DOUBLE |  |
| `net_over_under_billing` | DOUBLE |  |
| `total_backlog` | DOUBLE |  |
| `backlog_active` | DOUBLE |  |
| `backlog_awarded` | DOUBLE |  |
| `weighted_pipeline` | DECIMAL(38,4) | Sum of amount x stage probability, open deals. |
| `open_pipeline` | DECIMAL(38,2) |  |
| `open_opportunities` | HUGEINT |  |
| `won_count` | HUGEINT | Count. |
| `lost_count` | HUGEINT | Count. |
| `win_rate` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `pipeline_coverage` | DOUBLE |  |
| `trir_all` | DOUBLE |  |
| `trir_12m` | DOUBLE | Recordable incidents x 200,000 / hours, last 12 months. |
| `incidents_all` | HUGEINT |  |
| `recordables_all` | HUGEINT |  |
| `open_po_value` | DECIMAL(38,2) | US dollars. |
| `open_po_lines` | BIGINT | Count. |
| `overdue_po_lines` | BIGINT | Count. |
| `overdue_po_amount` | DECIMAL(38,2) | US dollars. |
| `on_time_delivery_rate` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `long_lead_overdue` | BIGINT |  |
| `received_not_invoiced_count` | BIGINT | Count. |
| `received_not_invoiced_amount` | DECIMAL(38,2) | US dollars. |
| `invoiced_not_received_count` | BIGINT | Count. |
| `invoiced_not_received_amount` | DECIMAL(38,2) | US dollars. |
| `price_exception_count` | BIGINT | US dollars. |
| `ap_open` | DECIMAL(38,2) |  |
| `ap_overdue` | DECIMAL(38,2) |  |
| `ap_over_90` | DECIMAL(38,2) |  |
| `ap_held` | DECIMAL(38,2) |  |
| `ar_open` | DECIMAL(38,2) |  |
| `ar_overdue` | DECIMAL(38,2) |  |
| `ar_over_90` | DECIMAL(38,2) |  |
| `retainage_receivable` | DECIMAL(38,2) | US dollars. |
| `retainage_payable` | DECIMAL(38,2) | US dollars. |
| `jobs_late` | BIGINT |  |
| `jobs_at_risk` | BIGINT |  |
| `rfis_overdue` | HUGEINT |  |
| `submittals_late` | HUGEINT |  |
| `items_below_reorder` | BIGINT |  |
| `items_stockout_risk` | BIGINT |  |
| `inventory_value` | DECIMAL(38,4) | US dollars. |
| `equipment_utilization` | DOUBLE |  |
| `rented_idle_cost` | DECIMAL(38,2) | Standby days x daily rate, rented units only. |

### `metrics.v_project_billing_curve`  (202 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `month_end` | DATE |  |
| `cost_cum` | DECIMAL(38,2) | US dollars. |
| `billed_cum` | DECIMAL(38,2) | US dollars. |
| `earned_cum` | DOUBLE |  |

### `metrics.v_project_cost_by_code`  (114 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `cost_code` | VARCHAR | Cost code in NN-NNN form. |
| `cost_code_name` | VARCHAR | US dollars. |
| `category` | VARCHAR |  |
| `original_budget` | DECIMAL(18,2) | US dollars. |
| `revised_budget` | DECIMAL(18,2) | US dollars. |
| `actual_cost` | DECIMAL(38,2) | US dollars. |
| `estimate_to_complete` | DECIMAL(18,2) |  |
| `estimated_cost_at_completion` | DECIMAL(38,2) | US dollars. |
| `forecast_variance` | DECIMAL(38,2) |  |

### `metrics.v_project_cost_curve`  (322 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `month_end` | DATE |  |
| `month_number` | BIGINT |  |
| `budget_cum` | DOUBLE | US dollars. |
| `actual_cum` | DECIMAL(38,2) |  |
| `forecast_cum` | DOUBLE |  |
| `eac` | DECIMAL(38,2) |  |

### `metrics.v_project_cost_progress`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `project_name` | VARCHAR | Name. |
| `business_unit` | VARCHAR |  |
| `status` | VARCHAR | Current status (domain varies by table). |
| `original_budget_cost` | DECIMAL(38,2) | US dollars. |
| `approved_co_budget` | DECIMAL(38,2) | US dollars. |
| `revised_budget_cost` | DECIMAL(38,2) | US dollars. |
| `actual_cost_to_date` | DECIMAL(38,2) | Calendar date. |
| `cost_to_complete` | DECIMAL(38,2) | US dollars. |
| `estimated_cost_at_completion` | DECIMAL(38,2) | US dollars. |
| `pct_complete` | DOUBLE | Cost-to-cost percent complete: actual / (actual + estimate to complete), 0-1. |

### `metrics.v_project_margin`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `project_name` | VARCHAR | Name. |
| `business_unit` | VARCHAR |  |
| `status` | VARCHAR | Current status (domain varies by table). |
| `original_contract_value` | DECIMAL(18,2) | US dollars. |
| `approved_co_revenue` | DECIMAL(38,2) | US dollars. |
| `revised_contract_value` | DECIMAL(38,2) | US dollars. |
| `estimated_cost_at_completion` | DECIMAL(38,2) | US dollars. |
| `bid_margin_pct` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `projected_profit` | DECIMAL(38,2) | US dollars. |
| `projected_margin_pct` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `margin_fade_pts` | DOUBLE | Bid margin minus projected margin, percentage points. |
| `margin_fade_dollars` | DOUBLE | Fade x revised contract value. |
| `share_of_fade` | DOUBLE |  |
| `fade_rank` | BIGINT |  |

### `metrics.v_project_procurement`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `committed_total` | DECIMAL(38,2) |  |
| `committed_subcontract` | DECIMAL(38,2) |  |
| `committed_po` | DECIMAL(38,2) |  |
| `po_ordered_to_date` | DECIMAL(38,2) | Calendar date. |
| `po_released_pct` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `po_received_value` | DECIMAL(38,2) | US dollars. |
| `po_invoiced_value` | DECIMAL(38,2) | US dollars. |
| `open_order_value` | DECIMAL(38,2) | US dollars. |
| `open_lines` | BIGINT | Count. |
| `overdue_open_lines` | BIGINT | Count. |
| `overdue_open_amount` | DECIMAL(38,2) | US dollars. |
| `long_lead_open_lines` | BIGINT | Count. |
| `on_time_rate` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |

### `metrics.v_project_schedule_variance`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `status` | VARCHAR | Current status (domain varies by table). |
| `planned_pct_complete` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `pct_complete` | DOUBLE | Cost-to-cost percent complete: actual / (actual + estimate to complete), 0-1. |
| `schedule_variance_pts` | DOUBLE |  |

### `metrics.v_project_summary`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `project_name` | VARCHAR | Name. |
| `business_unit` | VARCHAR |  |
| `status` | VARCHAR | Current status (domain varies by table). |
| `account_name` | VARCHAR | Name. |
| `project_manager` | VARCHAR |  |
| `start_date` | DATE | Calendar date. |
| `planned_end_date` | DATE | Calendar date. |
| `original_contract_value` | DECIMAL(18,2) | US dollars. |
| `approved_co_revenue` | DECIMAL(38,2) | US dollars. |
| `revised_contract_value` | DECIMAL(38,2) | US dollars. |
| `original_budget_cost` | DECIMAL(38,2) | US dollars. |
| `revised_budget_cost` | DECIMAL(38,2) | US dollars. |
| `actual_cost_to_date` | DECIMAL(38,2) | Calendar date. |
| `cost_to_complete` | DECIMAL(38,2) | US dollars. |
| `estimated_cost_at_completion` | DECIMAL(38,2) | US dollars. |
| `pct_complete` | DOUBLE | Cost-to-cost percent complete: actual / (actual + estimate to complete), 0-1. |
| `bid_margin_pct` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `projected_profit` | DECIMAL(38,2) | US dollars. |
| `projected_margin_pct` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `margin_fade_pts` | DOUBLE | Bid margin minus projected margin, percentage points. |
| `margin_fade_dollars` | DOUBLE | Fade x revised contract value. |
| `share_of_fade` | DOUBLE |  |
| `fade_rank` | BIGINT |  |
| `earned_revenue` | DOUBLE | US dollars. |
| `billed_to_date` | DECIMAL(38,2) | Calendar date. |
| `retainage_held` | DECIMAL(38,2) | Amount withheld from the payment (10%). |
| `over_under_billing` | DOUBLE | Billed to date minus earned revenue; positive = over-billed. |
| `over_under_pct_of_contract` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `billing_position` | VARCHAR |  |
| `pending_co_count` | BIGINT | Count. |
| `pending_co_revenue` | DECIMAL(38,2) | US dollars. |
| `pending_co_cost_at_risk` | DECIMAL(38,2) | US dollars. |
| `oldest_pending_age_days` | BIGINT | Days. |
| `pending_pct_of_contract` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `approved_co_count` | BIGINT | Count. |
| `rejected_co_count` | BIGINT | Count. |
| `avg_approval_cycle_days` | DOUBLE | Days. |
| `backlog_remaining` | DOUBLE |  |
| `incidents_all` | BIGINT |  |
| `recordables_all` | BIGINT |  |
| `trir_12m` | DOUBLE | Recordable incidents x 200,000 / hours, last 12 months. |
| `peak_incidents_in_window` | BIGINT |  |
| `peak_window_start` | DATE |  |
| `safety_cluster` | BOOLEAN | 5+ incidents inside any 90 days. |
| `committed_total` | DECIMAL(38,2) |  |
| `committed_po` | DECIMAL(38,2) |  |
| `po_ordered_to_date` | DECIMAL(38,2) | Calendar date. |
| `open_order_value` | DECIMAL(38,2) | US dollars. |
| `po_open_lines` | BIGINT | Count. |
| `po_overdue_lines` | BIGINT | Count. |
| `po_overdue_amount` | DECIMAL(38,2) | US dollars. |
| `long_lead_open_lines` | BIGINT | Count. |
| `delivery_on_time_rate` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `ap_open` | DECIMAL(38,2) |  |
| `ap_overdue` | DECIMAL(38,2) |  |
| `ap_held` | DECIMAL(38,2) |  |
| `ar_open` | DECIMAL(38,2) |  |
| `ar_overdue` | DECIMAL(38,2) |  |
| `ar_over_90` | DECIMAL(38,2) |  |
| `retainage_receivable_from_owner` | DECIMAL(38,2) | US dollars. |
| `retainage_payable_to_subs` | DECIMAL(38,2) | US dollars. |
| `rfis_open` | BIGINT |  |
| `rfis_overdue` | BIGINT |  |
| `rfi_avg_response_days` | DOUBLE | Days. |
| `submittals_pending` | BIGINT |  |
| `submittals_late` | BIGINT |  |
| `resubmittals` | BIGINT |  |
| `final_slip_days` | BIGINT | Final milestone forecast minus planned date. |
| `schedule_status` | VARCHAR | Late (>30 days), At risk (>7), On track. |
| `next_milestone` | VARCHAR |  |
| `next_forecast_date` | DATE | Calendar date. |
| `planned_pct_complete` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `schedule_variance_pts` | DOUBLE |  |
| `equipment_cost` | DECIMAL(38,2) | US dollars. |
| `equipment_utilization` | DOUBLE |  |
| `equipment_idle_cost` | DECIMAL(38,2) | US dollars. |

### `metrics.v_project_wip`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `status` | VARCHAR | Current status (domain varies by table). |
| `revised_contract_value` | DECIMAL(38,2) | US dollars. |
| `pct_complete` | DOUBLE | Cost-to-cost percent complete: actual / (actual + estimate to complete), 0-1. |
| `earned_revenue` | DOUBLE | US dollars. |
| `billed_to_date` | DECIMAL(38,2) | Calendar date. |
| `retainage_held` | DECIMAL(38,2) | Amount withheld from the payment (10%). |
| `over_under_billing` | DOUBLE | Billed to date minus earned revenue; positive = over-billed. |
| `over_under_pct_of_contract` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `billing_position` | VARCHAR |  |

### `metrics.v_retainage_position`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `status` | VARCHAR | Current status (domain varies by table). |
| `retainage_receivable_from_owner` | DECIMAL(38,2) | US dollars. |
| `retainage_payable_to_subs` | DECIMAL(38,2) | US dollars. |

### `metrics.v_rfi_by_project`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `rfis_total` | BIGINT |  |
| `rfis_open` | BIGINT |  |
| `rfis_overdue` | BIGINT |  |
| `avg_days_open` | DOUBLE | Days. |
| `avg_response_days` | DOUBLE | Days. |
| `open_with_cost_impact` | BIGINT | US dollars. |
| `open_schedule_impact_days` | HUGEINT | Days. |

### `metrics.v_rfi_open_detail`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `rfi_id` | VARCHAR | Identifier (natural key or foreign key). |
| `rfi_number` | INTEGER |  |
| `subject` | VARCHAR |  |
| `discipline` | VARCHAR |  |
| `ball_in_court` | VARCHAR |  |
| `submitted_date` | DATE | Calendar date. |
| `due_date` | DATE | Calendar date. |
| `days_past_due` | BIGINT | As-of date minus due date. |
| `has_cost_impact` | BOOLEAN | US dollars. |
| `schedule_impact_days` | INTEGER | Days. |

### `metrics.v_safety_by_bu`  (3 rows)

| Column | Type | Meaning |
|---|---|---|
| `business_unit` | VARCHAR |  |
| `hours_all` | DECIMAL(38,1) | Hours worked. |
| `incidents_all` | HUGEINT |  |
| `recordables_all` | HUGEINT |  |
| `trir_all` | DOUBLE |  |
| `hours_12m` | DECIMAL(38,1) | Hours worked. |
| `incidents_12m` | HUGEINT |  |
| `recordables_12m` | HUGEINT |  |
| `trir_12m` | DOUBLE | Recordable incidents x 200,000 / hours, last 12 months. |

### `metrics.v_safety_by_cause`  (28 rows)

| Column | Type | Meaning |
|---|---|---|
| `business_unit` | VARCHAR |  |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `cause_category` | VARCHAR |  |
| `incident_type` | VARCHAR |  |
| `incidents` | BIGINT |  |

### `metrics.v_safety_by_project`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_key` | BIGINT | Surrogate key to dim_project. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `project_name` | VARCHAR | Name. |
| `business_unit` | VARCHAR |  |
| `status` | VARCHAR | Current status (domain varies by table). |
| `hours_all` | DECIMAL(38,1) | Hours worked. |
| `incidents_all` | BIGINT |  |
| `recordables_all` | BIGINT |  |
| `trir_all` | DOUBLE |  |
| `hours_12m` | DECIMAL(38,1) | Hours worked. |
| `incidents_12m` | BIGINT |  |
| `recordables_12m` | BIGINT |  |
| `trir_12m` | DOUBLE | Recordable incidents x 200,000 / hours, last 12 months. |
| `peak_incidents_in_window` | BIGINT |  |
| `peak_window_start` | DATE |  |
| `is_cluster` | BOOLEAN | 5+ incidents inside any 90 days. |

### `metrics.v_safety_detail`  (32 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `incident_id` | VARCHAR | Identifier (natural key or foreign key). |
| `incident_date` | DATE | Calendar date. |
| `incident_type` | VARCHAR |  |
| `cause_category` | VARCHAR |  |
| `severity` | INTEGER |  |
| `recordable_flag` | VARCHAR | Y for recordable and lost-time incidents. |
| `days_away` | INTEGER | Days. |

### `metrics.v_schedule_by_project`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `milestones_total` | BIGINT |  |
| `milestones_complete` | BIGINT |  |
| `final_milestone` | VARCHAR |  |
| `final_planned_date` | DATE | Calendar date. |
| `final_forecast_date` | DATE | Calendar date. |
| `final_slip_days` | BIGINT | Final milestone forecast minus planned date. |
| `worst_slip_days` | BIGINT | Days. |
| `next_milestone` | VARCHAR |  |
| `next_planned_date` | DATE | Calendar date. |
| `next_forecast_date` | DATE | Calendar date. |
| `schedule_status` | VARCHAR | Late (>30 days), At risk (>7), On track. |

### `metrics.v_subcontract_position`  (74 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `project_name` | VARCHAR | Name. |
| `vendor_name` | VARCHAR | Standardised vendor name. |
| `cost_code` | VARCHAR | Cost code in NN-NNN form. |
| `cost_code_name` | VARCHAR | US dollars. |
| `commitment_id` | VARCHAR | Identifier (natural key or foreign key). |
| `commitment_type` | VARCHAR |  |
| `status` | VARCHAR | Current status (domain varies by table). |
| `original_amount` | DECIMAL(18,2) | US dollars. |
| `approved_changes` | DECIMAL(18,2) |  |
| `committed_total` | DECIMAL(18,2) |  |
| `billed_to_date` | DECIMAL(38,2) | Calendar date. |
| `paid_to_date` | DECIMAL(38,2) | Calendar date. |
| `retainage_held` | DECIMAL(38,2) | Amount withheld from the payment (10%). |
| `retainage_released` | DECIMAL(38,2) | US dollars. |
| `disputed_amount` | DECIMAL(38,2) | US dollars. |
| `balance_to_bill` | DECIMAL(38,2) |  |
| `pct_billed` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `net_payable` | DECIMAL(38,2) | US dollars. |
| `is_overbilled` | BOOLEAN | US dollars. |
| `oldest_unpaid_days_past_due` | BIGINT | US dollars. |

### `metrics.v_submittal_by_project`  (12 rows)

| Column | Type | Meaning |
|---|---|---|
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `submittals_total` | BIGINT |  |
| `submittals_pending` | BIGINT |  |
| `submittals_late` | BIGINT |  |
| `resubmittals` | BIGINT |  |
| `avg_review_days` | DOUBLE | Days. |

### `metrics.v_three_way_match_exceptions`  (43 rows)

| Column | Type | Meaning |
|---|---|---|
| `exception_type` | VARCHAR | Three-way-match exception category. |
| `project_id` | VARCHAR | Project number, e.g. P-101 (natural key). |
| `vendor_name` | VARCHAR | Standardised vendor name. |
| `po_line_id` | VARCHAR | Identifier (natural key or foreign key). |
| `item_description` | VARCHAR |  |
| `exception_amount` | DECIMAL(38,2) | US dollars. |
| `age_days` | BIGINT | Days. |

### `metrics.v_vendor_scorecard`  (5 rows)

| Column | Type | Meaning |
|---|---|---|
| `vendor_name` | VARCHAR | Standardised vendor name. |
| `vendor_type` | VARCHAR |  |
| `po_lines` | BIGINT | Count. |
| `ordered_amount` | DECIMAL(38,2) | US dollars. |
| `delivered_lines` | BIGINT | Count. |
| `on_time_rate` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `avg_days_late` | DOUBLE | Days. |
| `overdue_open_lines` | BIGINT | Count. |
| `overdue_open_amount` | DECIMAL(38,2) | US dollars. |
| `avg_price_variance_pct` | DOUBLE | Ratio, stored as a decimal (0.095 = 9.5%). |
| `on_hold_amount` | DECIMAL(38,2) | US dollars. |

## Operations (`ops`)

### `ops.dq_results`

| Column | Type |
|---|---|
| `run_id` | VARCHAR |
| `run_ts` | TIMESTAMP |
| `check_id` | VARCHAR |
| `check_name` | VARCHAR |
| `layer` | VARCHAR |
| `check_type` | VARCHAR |
| `severity` | VARCHAR |
| `status` | VARCHAR |
| `rows_affected` | BIGINT |
| `description` | VARCHAR |
| `detail` | VARCHAR |

### `ops.etl_params`

| Column | Type |
|---|---|
| `as_of_date` | DATE |
| `billing_balance_threshold` | DECIMAL(3,2) |
| `safety_cluster_min_incidents` | INTEGER |
| `safety_cluster_window_days` | INTEGER |

### `ops.load_audit`

| Column | Type |
|---|---|
| `table_name` | VARCHAR |
| `row_count` | BIGINT |
| `loaded_at` | TIMESTAMP |

### `ops.staging_audit`

| Column | Type |
|---|---|
| `table_name` | VARCHAR |
| `raw_rows` | BIGINT |
| `staged_rows` | BIGINT |
| `rejected_rows` | BIGINT |

