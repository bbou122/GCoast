-- =============================================================================
-- 04_quality_checks.sql   AUTOMATED DATA-QUALITY CHECKS  ->  ops.dq_results
-- SYNTHETIC DATA: Gulf Coast Builders is a fictional company.
--
-- Run by src/run_checks.py AFTER 01-03 and 05 are built (this file also
-- reconciles the metric views, which is why it is executed last even though it
-- is numbered 04).
--
-- Each check returns rows_affected = number of violations (0 = clean).
--   status = PASS   rows_affected = 0
--          = FAIL   rows_affected > 0 and severity = 'critical'  -> the build stops
--          = WARN   rows_affected > 0 and severity = 'warn'      -> reported, build continues
--          = INFO   rows_affected > 0 and severity = 'info'      -> RAW-layer profile: source problems that
--                   staging is DESIGNED to fix or quarantine. They are expected, and the numbers are the evidence.
--
-- Placeholders: {{RUN_ID}}
-- SNOWFLAKE: regexp_matches -> REGEXP_LIKE ; json_extract_string(j,'$.k') -> PARSE_JSON(j):k::STRING ;
--            information_schema.columns works unchanged.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ops.dq_results (
    run_id        VARCHAR,
    run_ts        TIMESTAMP,
    check_id      VARCHAR,
    check_name    VARCHAR,
    layer         VARCHAR,
    check_type    VARCHAR,
    severity      VARCHAR,
    status        VARCHAR,
    rows_affected BIGINT,
    description   VARCHAR,
    detail        VARCHAR
);

INSERT INTO ops.dq_results
SELECT '{{RUN_ID}}', current_timestamp::TIMESTAMP, c.check_id, c.check_name, c.layer, c.check_type, c.severity,
       CASE WHEN c.rows_affected = 0 THEN 'PASS'
            WHEN c.severity = 'critical' THEN 'FAIL'
            WHEN c.severity = 'warn' THEN 'WARN'
            ELSE 'INFO' END,
       c.rows_affected, c.description, c.detail
FROM (

-- ============================ RAW: completeness + source-problem profile ============================
SELECT 'RAW-001' AS check_id, 'raw_tables_loaded' AS check_name, 'raw' AS layer, 'row_count' AS check_type, 'critical' AS severity,
       (SELECT COUNT(*) FROM ops.load_audit WHERE row_count = 0) AS rows_affected,
       'Every raw table received at least one row' AS description, NULL AS detail
UNION ALL SELECT 'RAW-002', 'raw_missing_cost_code', 'raw', 'null_check', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs WHERE NULLIF(TRIM(cost_code), '') IS NULL),
       'AP postings with no cost code (quarantined in staging)', NULL
UNION ALL SELECT 'RAW-003', 'raw_cost_code_format', 'raw', 'format', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs WHERE NULLIF(TRIM(cost_code), '') IS NOT NULL AND NOT regexp_matches(cost_code, '^[0-9]{2}-[0-9]{3}$')),
       'Cost codes not in NN-NNN form (normalised in staging)', NULL
UNION ALL SELECT 'RAW-004', 'raw_currency_text_amounts', 'raw', 'format', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs WHERE amount LIKE '$%' OR amount LIKE '%,%'),
       'Amounts stored as text with $ or commas (parsed in staging)', NULL
UNION ALL SELECT 'RAW-005', 'raw_mixed_date_formats', 'raw', 'format', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs WHERE NOT regexp_matches(period, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'))
     + (SELECT COUNT(*) FROM raw.billings     WHERE NOT regexp_matches(period_end, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')),
       'Dates not in ISO form, e.g. MM/DD/YYYY (parsed in staging)', NULL
UNION ALL SELECT 'RAW-006', 'raw_vendor_spelling_variants', 'raw', 'consistency', 'info',
       (SELECT COALESCE(SUM(raw_occurrences), 0) FROM stg.vendor_map WHERE raw_name <> vendor_std),
       'Postings whose vendor spelling differs from the canonical spelling (standardised in staging)', NULL
UNION ALL SELECT 'RAW-007', 'raw_duplicate_invoices', 'raw', 'uniqueness', 'info',
       (SELECT COUNT(*) - COUNT(DISTINCT project_id || '|' || invoice_no) FROM raw.billings),
       'Pay-application rows repeating an existing project + invoice number (deduplicated in staging)', NULL
UNION ALL SELECT 'RAW-008', 'raw_negative_amounts', 'raw', 'range', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs WHERE stg.parse_amount(amount) < 0)
     + (SELECT COUNT(*) FROM raw.billings     WHERE stg.parse_amount(gross_billed) < 0),
       'Negative cost or billing amounts (legitimate credit memos kept; sign errors quarantined)', NULL
UNION ALL SELECT 'RAW-009', 'raw_orphan_foreign_keys', 'raw', 'referential', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs    a WHERE NOT EXISTS (SELECT 1 FROM raw.projects     p WHERE p.project_id  = TRIM(a.project_id)))
     + (SELECT COUNT(*) FROM raw.change_orders   a WHERE NOT EXISTS (SELECT 1 FROM raw.projects     p WHERE p.project_id  = TRIM(a.project_id)))
     + (SELECT COUNT(*) FROM raw.safety_incidents a WHERE NOT EXISTS (SELECT 1 FROM raw.projects    p WHERE p.project_id  = TRIM(a.project_id)))
     + (SELECT COUNT(*) FROM raw.timecards       a WHERE NOT EXISTS (SELECT 1 FROM raw.employees    e WHERE e.employee_id = TRIM(a.employee_id)))
     + (SELECT COUNT(*) FROM raw.opportunities   a WHERE NOT EXISTS (SELECT 1 FROM raw.accounts     k WHERE k.account_id  = TRIM(a.account_id)))
     + (SELECT COUNT(*) FROM raw.bids            a WHERE NOT EXISTS (SELECT 1 FROM raw.opportunities o WHERE o.opportunity_id = TRIM(a.opportunity_id))),
       'Rows pointing at a project / employee / account / opportunity that does not exist (quarantined in staging)', NULL
UNION ALL SELECT 'RAW-010', 'raw_future_periods', 'raw', 'range', 'info',
       (SELECT COUNT(*) FROM raw.actual_costs WHERE stg.parse_date(period) > (SELECT as_of_date FROM ops.etl_params)),
       'Cost postings dated after the as-of date (quarantined in staging)', NULL
UNION ALL SELECT 'RAW-011', 'raw_hours_out_of_range', 'raw', 'range', 'info',
       (SELECT COUNT(*) FROM raw.timecards WHERE TRY_CAST(regular_hours AS DOUBLE) NOT BETWEEN 0 AND 80),
       'Weekly regular hours outside 0-80 (quarantined in staging)', NULL
UNION ALL SELECT 'RAW-012', 'raw_stage_label_variants', 'raw', 'consistency', 'info',
       (SELECT COUNT(*) FROM raw.opportunities WHERE stage NOT IN ('Lead','Qualified','Proposal','Negotiation','Won','Lost')),
       'CRM stage labels not in the standard list (standardised in staging)', NULL

-- ============================ STAGING: uniqueness ============================
UNION ALL SELECT 'STG-001', 'stg_pk_actual_costs', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT cost_id) FROM stg.actual_costs), 'actual_costs.cost_id is unique', NULL
UNION ALL SELECT 'STG-002', 'stg_pk_billings_id', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT billing_id) FROM stg.billings), 'billings.billing_id is unique', NULL
UNION ALL SELECT 'STG-003', 'stg_pk_billings_invoice', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT project_id || '|' || invoice_no) FROM stg.billings), 'One row per project + invoice number (no duplicate invoices survive staging)', NULL
UNION ALL SELECT 'STG-004', 'stg_pk_change_orders', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT change_order_id) FROM stg.change_orders), 'change_orders.change_order_id is unique', NULL
UNION ALL SELECT 'STG-005', 'stg_pk_timecards', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT timecard_id) FROM stg.timecards), 'timecards.timecard_id is unique', NULL
UNION ALL SELECT 'STG-006', 'stg_pk_safety_incidents', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT incident_id) FROM stg.safety_incidents), 'safety_incidents.incident_id is unique', NULL
UNION ALL SELECT 'STG-007', 'stg_pk_opportunities', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT opportunity_id) FROM stg.opportunities), 'opportunities.opportunity_id is unique', NULL
UNION ALL SELECT 'STG-008', 'stg_pk_bids', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT bid_id) FROM stg.bids), 'bids.bid_id is unique', NULL
UNION ALL SELECT 'STG-009', 'stg_pk_projects', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT project_id) FROM stg.projects), 'projects.project_id is unique', NULL
UNION ALL SELECT 'STG-010', 'stg_pk_employees', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT employee_id) FROM stg.employees), 'employees.employee_id is unique', NULL
UNION ALL SELECT 'STG-011', 'stg_pk_budget_lines', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT project_id || '|' || cost_code) FROM stg.budget_lines), 'One budget line per project + cost code', NULL
UNION ALL SELECT 'STG-012', 'stg_pk_accounts_costcodes', 'staging', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT account_id) FROM stg.accounts) + (SELECT COUNT(*) - COUNT(DISTINCT cost_code) FROM stg.cost_codes),
       'accounts.account_id and cost_codes.cost_code are unique', NULL
UNION ALL SELECT 'STG-013', 'stg_vendor_map_one_canonical', 'staging', 'consistency', 'critical',
       (SELECT COUNT(*) FROM (SELECT vendor_key FROM stg.vendor_map GROUP BY vendor_key HAVING COUNT(DISTINCT vendor_std) > 1) x),
       'Each vendor matching key maps to exactly one canonical vendor name', NULL

-- ============================ STAGING: foreign keys ============================
UNION ALL SELECT 'STG-020', 'stg_fk_actual_costs_project', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.actual_costs a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id)), 'actual_costs -> projects', NULL
UNION ALL SELECT 'STG-021', 'stg_fk_actual_costs_cost_code', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.actual_costs a WHERE NOT EXISTS (SELECT 1 FROM stg.cost_codes c WHERE c.cost_code = a.cost_code)), 'actual_costs -> cost_codes', NULL
UNION ALL SELECT 'STG-022', 'stg_fk_billings_project', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.billings a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id)), 'billings -> projects', NULL
UNION ALL SELECT 'STG-023', 'stg_fk_change_orders_project', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.change_orders a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id)), 'change_orders -> projects', NULL
UNION ALL SELECT 'STG-024', 'stg_fk_timecards', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.timecards a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id))
     + (SELECT COUNT(*) FROM stg.timecards a WHERE NOT EXISTS (SELECT 1 FROM stg.employees e WHERE e.employee_id = a.employee_id)), 'timecards -> projects, employees', NULL
UNION ALL SELECT 'STG-025', 'stg_fk_safety', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.safety_incidents a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id))
     + (SELECT COUNT(*) FROM stg.safety_incidents a WHERE a.employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stg.employees e WHERE e.employee_id = a.employee_id)), 'safety_incidents -> projects, employees', NULL
UNION ALL SELECT 'STG-026', 'stg_fk_crm', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.opportunities a WHERE NOT EXISTS (SELECT 1 FROM stg.accounts k WHERE k.account_id = a.account_id))
     + (SELECT COUNT(*) FROM stg.bids a WHERE NOT EXISTS (SELECT 1 FROM stg.opportunities o WHERE o.opportunity_id = a.opportunity_id)), 'opportunities -> accounts; bids -> opportunities', NULL
UNION ALL SELECT 'STG-027', 'stg_fk_budget_commitments', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.budget_lines a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id) OR NOT EXISTS (SELECT 1 FROM stg.cost_codes c WHERE c.cost_code = a.cost_code))
     + (SELECT COUNT(*) FROM stg.commitments a WHERE NOT EXISTS (SELECT 1 FROM stg.projects p WHERE p.project_id = a.project_id) OR NOT EXISTS (SELECT 1 FROM stg.cost_codes c WHERE c.cost_code = a.cost_code)), 'budget_lines, commitments -> projects, cost_codes', NULL
UNION ALL SELECT 'STG-028', 'stg_fk_projects', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.projects a WHERE NOT EXISTS (SELECT 1 FROM stg.accounts k WHERE k.account_id = a.account_id))
     + (SELECT COUNT(*) FROM stg.projects a WHERE NOT EXISTS (SELECT 1 FROM stg.employees e WHERE e.employee_id = a.pm_employee_id))
     + (SELECT COUNT(*) FROM stg.projects a WHERE a.opportunity_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stg.opportunities o WHERE o.opportunity_id = a.opportunity_id)), 'projects -> accounts, employees (PM), opportunities', NULL

-- ============================ STAGING: required fields ============================
UNION ALL SELECT 'STG-030', 'stg_required_actual_costs', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.actual_costs WHERE project_id IS NULL OR cost_code IS NULL OR period IS NULL OR amount IS NULL), 'actual_costs: project, cost code, period, amount are required', NULL
UNION ALL SELECT 'STG-031', 'stg_required_billings', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.billings WHERE project_id IS NULL OR invoice_no IS NULL OR period_end IS NULL OR gross_billed IS NULL), 'billings: project, invoice, period, amount are required', NULL
UNION ALL SELECT 'STG-032', 'stg_required_projects', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.projects WHERE project_name IS NULL OR business_unit IS NULL OR start_date IS NULL OR planned_end_date IS NULL OR original_contract_value IS NULL OR status IS NULL), 'projects: name, BU, dates, contract value, status are required', NULL
UNION ALL SELECT 'STG-033', 'stg_required_budget_lines', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.budget_lines WHERE original_budget IS NULL OR revised_budget IS NULL OR estimate_to_complete IS NULL), 'budget_lines: budget and estimate-to-complete are required', NULL
UNION ALL SELECT 'STG-034', 'stg_required_change_orders', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.change_orders WHERE amount IS NULL OR submitted_date IS NULL OR status IS NULL), 'change_orders: amount, submitted date, status are required', NULL
UNION ALL SELECT 'STG-035', 'stg_required_crm', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.opportunities WHERE stage IS NULL OR amount IS NULL OR probability IS NULL OR business_unit IS NULL), 'opportunities: stage, amount, probability, BU are required', NULL
UNION ALL SELECT 'STG-036', 'stg_required_safety_timecards', 'staging', 'null_check', 'critical',
       (SELECT COUNT(*) FROM stg.safety_incidents WHERE incident_date IS NULL OR incident_type IS NULL OR recordable_flag IS NULL)
     + (SELECT COUNT(*) FROM stg.timecards WHERE week_ending IS NULL OR regular_hours IS NULL), 'safety_incidents and timecards: date, type/flag, hours are required', NULL

-- ============================ STAGING: ranges and business rules ============================
UNION ALL SELECT 'STG-040', 'stg_negative_costs_are_credits', 'staging', 'range', 'critical',
       (SELECT COUNT(*) FROM stg.actual_costs WHERE amount < 0 AND NOT is_credit_memo), 'Negative cost rows must be credit memos', NULL
UNION ALL SELECT 'STG-041', 'stg_cost_period_not_future', 'staging', 'range', 'critical',
       (SELECT COUNT(*) FROM stg.actual_costs WHERE period > (SELECT as_of_date FROM ops.etl_params)), 'No cost posted after the as-of date', NULL
UNION ALL SELECT 'STG-042', 'stg_cost_after_project_start', 'staging', 'range', 'warn',
       (SELECT COUNT(*) FROM stg.actual_costs a JOIN stg.projects p ON p.project_id = a.project_id WHERE a.period < LAST_DAY(p.start_date)), 'Cost posted before the project start month', NULL
UNION ALL SELECT 'STG-043', 'stg_billing_amounts', 'staging', 'range', 'critical',
       (SELECT COUNT(*) FROM stg.billings WHERE gross_billed < 0 OR retainage_held < 0 OR retainage_held > gross_billed), 'Billings >= 0 and retainage between 0 and gross', NULL
UNION ALL SELECT 'STG-044', 'stg_hours_range', 'staging', 'range', 'critical',
       (SELECT COUNT(*) FROM stg.timecards WHERE regular_hours NOT BETWEEN 0 AND 80 OR overtime_hours NOT BETWEEN 0 AND 40), 'Weekly hours within 0-80 regular and 0-40 overtime', NULL
UNION ALL SELECT 'STG-045', 'stg_probability_range', 'staging', 'range', 'critical',
       (SELECT COUNT(*) FROM stg.opportunities WHERE probability < 0 OR probability > 1)
     + (SELECT COUNT(*) FROM stg.opportunities WHERE (stage = 'Won' AND probability <> 1) OR (stage = 'Lost' AND probability <> 0)), 'Probability within 0-1; Won = 1, Lost = 0', NULL
UNION ALL SELECT 'STG-046', 'stg_domain_values', 'staging', 'consistency', 'critical',
       (SELECT COUNT(*) FROM stg.projects WHERE business_unit NOT IN ('Building','Heavy Civil','Manufacturing') OR status NOT IN ('Active','Completed'))
     + (SELECT COUNT(*) FROM stg.opportunities WHERE business_unit NOT IN ('Building','Heavy Civil','Manufacturing') OR stage NOT IN ('Lead','Qualified','Proposal','Negotiation','Won','Lost'))
     + (SELECT COUNT(*) FROM stg.change_orders WHERE status NOT IN ('Approved','Pending','Rejected'))
     + (SELECT COUNT(*) FROM stg.safety_incidents WHERE incident_type NOT IN ('Near Miss','First Aid','Recordable','Lost Time') OR recordable_flag NOT IN ('Y','N')),
       'Business unit, project status, stage, CO status, incident type take only allowed values', NULL
UNION ALL SELECT 'STG-047', 'stg_change_order_dates', 'staging', 'consistency', 'critical',
       (SELECT COUNT(*) FROM stg.change_orders WHERE decision_date < submitted_date)
     + (SELECT COUNT(*) FROM stg.change_orders WHERE (status = 'Pending' AND decision_date IS NOT NULL) OR (status <> 'Pending' AND decision_date IS NULL)),
       'Decision date follows submission; pending COs have no decision date, decided ones do', NULL
UNION ALL SELECT 'STG-048', 'stg_budget_arithmetic', 'staging', 'consistency', 'critical',
       (SELECT COUNT(*) FROM stg.budget_lines WHERE ABS(original_budget + approved_co_budget - revised_budget) > 0.01), 'revised_budget = original + approved CO budget', NULL
UNION ALL SELECT 'STG-049', 'stg_project_dates', 'staging', 'consistency', 'critical',
       (SELECT COUNT(*) FROM stg.projects WHERE planned_end_date <= start_date), 'Planned end after start', NULL

-- ============================ STAGING: reconciliation (nothing silently dropped) ============================
UNION ALL SELECT 'STG-060', 'stg_recon_rowcount_actual_costs', 'staging', 'reconciliation', 'critical',
       (SELECT CASE WHEN (SELECT COUNT(*) FROM raw.actual_costs) = (SELECT COUNT(*) FROM stg.actual_costs) + (SELECT COUNT(*) FROM stg.rejects WHERE source_table = 'actual_costs') THEN 0 ELSE 1 END),
       'raw rows = staged rows + rejected rows (actual_costs)',
       (SELECT 'raw ' || (SELECT COUNT(*) FROM raw.actual_costs) || ' = stg ' || (SELECT COUNT(*) FROM stg.actual_costs) || ' + rejects ' || (SELECT COUNT(*) FROM stg.rejects WHERE source_table = 'actual_costs'))
UNION ALL SELECT 'STG-061', 'stg_recon_rowcount_billings', 'staging', 'reconciliation', 'critical',
       (SELECT CASE WHEN (SELECT COUNT(*) FROM raw.billings) = (SELECT COUNT(*) FROM stg.billings) + (SELECT COUNT(*) FROM stg.rejects WHERE source_table = 'billings') THEN 0 ELSE 1 END),
       'raw rows = staged rows + rejected rows (billings)',
       (SELECT 'raw ' || (SELECT COUNT(*) FROM raw.billings) || ' = stg ' || (SELECT COUNT(*) FROM stg.billings) || ' + rejects ' || (SELECT COUNT(*) FROM stg.rejects WHERE source_table = 'billings'))
UNION ALL SELECT 'STG-062', 'stg_recon_rowcount_other', 'staging', 'reconciliation', 'critical',
       (SELECT COUNT(*) FROM ops.staging_audit WHERE raw_rows <> staged_rows + rejected_rows),
       'raw rows = staged rows + rejected rows (all tables that have reject rules)', NULL
UNION ALL SELECT 'STG-063', 'stg_recon_passthrough_tables', 'staging', 'reconciliation', 'critical',
       (SELECT COUNT(*) FROM (
            SELECT 1 FROM raw.projects       HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.projects)
            UNION ALL SELECT 1 FROM raw.cost_codes   HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.cost_codes)
            UNION ALL SELECT 1 FROM raw.budget_lines HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.budget_lines)
            UNION ALL SELECT 1 FROM raw.commitments  HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.commitments)
            UNION ALL SELECT 1 FROM raw.employees    HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.employees)
            UNION ALL SELECT 1 FROM raw.accounts     HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.accounts)) x),
       'Tables without reject rules pass through row-for-row', NULL
UNION ALL SELECT 'STG-064', 'stg_recon_amount_actual_costs', 'staging', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS(
            (SELECT SUM(stg.parse_amount(amount)) FROM raw.actual_costs)
          - (SELECT SUM(stg.parse_amount(json_extract_string(raw_row_json, '$.amount'))) FROM stg.rejects WHERE source_table = 'actual_costs')
          - (SELECT SUM(amount) FROM stg.actual_costs)) < 0.01 THEN 0 ELSE 1 END),
       'Sum of raw amounts - rejected amounts = staged amounts (actual_costs)',
       (SELECT 'raw ' || ROUND((SELECT SUM(stg.parse_amount(amount)) FROM raw.actual_costs), 2) || ' - rejects ' || ROUND((SELECT SUM(stg.parse_amount(json_extract_string(raw_row_json, '$.amount'))) FROM stg.rejects WHERE source_table = 'actual_costs'), 2) || ' = stg ' || ROUND((SELECT SUM(amount) FROM stg.actual_costs), 2))
UNION ALL SELECT 'STG-065', 'stg_recon_amount_billings', 'staging', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS(
            (SELECT SUM(stg.parse_amount(gross_billed)) FROM raw.billings)
          - (SELECT SUM(stg.parse_amount(json_extract_string(raw_row_json, '$.gross_billed'))) FROM stg.rejects WHERE source_table = 'billings')
          - (SELECT SUM(gross_billed) FROM stg.billings)) < 0.01 THEN 0 ELSE 1 END),
       'Sum of raw billings - rejected billings = staged billings', NULL
UNION ALL SELECT 'STG-066', 'stg_rejects_have_reasons', 'staging', 'completeness', 'critical',
       (SELECT COUNT(*) FROM stg.rejects WHERE reject_reason IS NULL OR source_key IS NULL OR raw_row_json IS NULL),
       'Every quarantined row carries a reason, a source key and the raw row', NULL

-- ============================ MART: keys and integrity ============================
UNION ALL SELECT 'MRT-001', 'mart_pk_dimensions', 'mart', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT project_key) FROM mart.dim_project)
     + (SELECT COUNT(*) - COUNT(DISTINCT date_key) FROM mart.dim_date)
     + (SELECT COUNT(*) - COUNT(DISTINCT cost_code_key) FROM mart.dim_cost_code)
     + (SELECT COUNT(*) - COUNT(DISTINCT employee_key) FROM mart.dim_employee)
     + (SELECT COUNT(*) - COUNT(DISTINCT account_key) FROM mart.dim_account), 'Surrogate keys unique in every dimension', NULL
UNION ALL SELECT 'MRT-002', 'mart_pk_facts', 'mart', 'uniqueness', 'critical',
       (SELECT COUNT(*) - COUNT(DISTINCT cost_id) FROM mart.fact_cost)
     + (SELECT COUNT(*) - COUNT(DISTINCT billing_id) FROM mart.fact_billing)
     + (SELECT COUNT(*) - COUNT(DISTINCT change_order_id) FROM mart.fact_change_order)
     + (SELECT COUNT(*) - COUNT(DISTINCT opportunity_id) FROM mart.fact_pipeline)
     + (SELECT COUNT(*) - COUNT(DISTINCT incident_id) FROM mart.fact_safety)
     + (SELECT COUNT(*) - COUNT(DISTINCT project_key || '|' || date_key) FROM mart.fact_hours)
     + (SELECT COUNT(*) - COUNT(DISTINCT project_key || '|' || cost_code_key) FROM mart.fact_budget), 'Fact grain holds: one row per natural key', NULL
UNION ALL SELECT 'MRT-003', 'mart_fk_facts_to_dimensions', 'mart', 'referential', 'critical',
       (SELECT COUNT(*) FROM mart.fact_cost f WHERE f.project_key IS NULL OR f.cost_code_key IS NULL OR f.date_key IS NULL
            OR NOT EXISTS (SELECT 1 FROM mart.dim_project d WHERE d.project_key = f.project_key)
            OR NOT EXISTS (SELECT 1 FROM mart.dim_cost_code d WHERE d.cost_code_key = f.cost_code_key)
            OR NOT EXISTS (SELECT 1 FROM mart.dim_date d WHERE d.date_key = f.date_key))
     + (SELECT COUNT(*) FROM mart.fact_billing f WHERE f.project_key IS NULL OR f.date_key IS NULL
            OR NOT EXISTS (SELECT 1 FROM mart.dim_project d WHERE d.project_key = f.project_key)
            OR NOT EXISTS (SELECT 1 FROM mart.dim_date d WHERE d.date_key = f.date_key))
     + (SELECT COUNT(*) FROM mart.fact_budget f WHERE f.project_key IS NULL OR f.cost_code_key IS NULL
            OR NOT EXISTS (SELECT 1 FROM mart.dim_project d WHERE d.project_key = f.project_key)
            OR NOT EXISTS (SELECT 1 FROM mart.dim_cost_code d WHERE d.cost_code_key = f.cost_code_key))
     + (SELECT COUNT(*) FROM mart.fact_change_order f WHERE f.project_key IS NULL OR f.submitted_date_key IS NULL
            OR NOT EXISTS (SELECT 1 FROM mart.dim_project d WHERE d.project_key = f.project_key))
     + (SELECT COUNT(*) FROM mart.fact_safety f WHERE f.project_key IS NULL OR f.date_key IS NULL
            OR NOT EXISTS (SELECT 1 FROM mart.dim_project d WHERE d.project_key = f.project_key))
     + (SELECT COUNT(*) FROM mart.fact_hours f WHERE f.project_key IS NULL OR f.date_key IS NULL
            OR NOT EXISTS (SELECT 1 FROM mart.dim_project d WHERE d.project_key = f.project_key)
            OR NOT EXISTS (SELECT 1 FROM mart.dim_date d WHERE d.date_key = f.date_key))
     + (SELECT COUNT(*) FROM mart.fact_pipeline f WHERE f.account_key IS NULL OR NOT EXISTS (SELECT 1 FROM mart.dim_account d WHERE d.account_key = f.account_key)),
       'Every fact row finds its dimension rows (no null or dangling keys)', NULL
UNION ALL SELECT 'MRT-004', 'mart_dim_project_complete', 'mart', 'null_check', 'critical',
       (SELECT COUNT(*) FROM mart.dim_project WHERE account_key IS NULL OR pm_employee_key IS NULL OR original_budget_cost IS NULL OR original_margin_pct IS NULL),
       'dim_project has an account, a PM, a bid cost and a bid margin for every project', NULL
UNION ALL SELECT 'MRT-005', 'mart_dim_date_contiguous', 'mart', 'completeness', 'critical',
       (SELECT CASE WHEN COUNT(*) = DATE_DIFF('day', MIN(date), MAX(date)) + 1 THEN 0 ELSE 1 END FROM mart.dim_date),
       'dim_date has one row for every calendar day with no gaps', NULL
UNION ALL SELECT 'MRT-006', 'mart_no_confidential_columns', 'mart', 'governance', 'critical',
       (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'mart' AND column_name IN ('hourly_rate', 'email')),
       'Confidential columns (pay rate, email) are not exposed in the mart', NULL

-- ============================ MART: reconciliation to staging and to raw ============================
UNION ALL SELECT 'MRT-010', 'mart_recon_rowcounts', 'mart', 'reconciliation', 'critical',
       (SELECT COUNT(*) FROM (
            SELECT 1 FROM mart.fact_cost          HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.actual_costs)
            UNION ALL SELECT 1 FROM mart.fact_billing      HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.billings)
            UNION ALL SELECT 1 FROM mart.fact_change_order HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.change_orders)
            UNION ALL SELECT 1 FROM mart.fact_pipeline     HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.opportunities)
            UNION ALL SELECT 1 FROM mart.fact_safety       HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.safety_incidents)
            UNION ALL SELECT 1 FROM mart.fact_budget       HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.budget_lines)
            UNION ALL SELECT 1 FROM mart.dim_project       HAVING COUNT(*) <> (SELECT COUNT(*) FROM stg.projects)) x),
       'Mart row counts equal staging row counts (nothing lost or fanned out in joins)', NULL
UNION ALL SELECT 'MRT-011', 'mart_recon_total_cost_to_staging', 'mart', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(actual_cost) FROM mart.fact_cost) - (SELECT SUM(amount) FROM stg.actual_costs)) < 0.01 THEN 0 ELSE 1 END),
       'Total actual cost in the mart = total in staging',
       (SELECT 'mart ' || ROUND((SELECT SUM(actual_cost) FROM mart.fact_cost), 2) || ' vs staging ' || ROUND((SELECT SUM(amount) FROM stg.actual_costs), 2))
UNION ALL SELECT 'MRT-012', 'mart_recon_total_cost_to_raw', 'mart', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS(
            (SELECT SUM(stg.parse_amount(amount)) FROM raw.actual_costs)
          - (SELECT SUM(stg.parse_amount(json_extract_string(raw_row_json, '$.amount'))) FROM stg.rejects WHERE source_table = 'actual_costs')
          - (SELECT SUM(actual_cost) FROM mart.fact_cost)) < 0.01 THEN 0 ELSE 1 END),
       'Total actual cost in the mart = raw total minus rejected rows (end-to-end)',
       (SELECT 'raw ' || ROUND((SELECT SUM(stg.parse_amount(amount)) FROM raw.actual_costs), 2) || ' - rejected ' || ROUND((SELECT SUM(stg.parse_amount(json_extract_string(raw_row_json, '$.amount'))) FROM stg.rejects WHERE source_table = 'actual_costs'), 2) || ' = mart ' || ROUND((SELECT SUM(actual_cost) FROM mart.fact_cost), 2))
UNION ALL SELECT 'MRT-013', 'mart_recon_total_billing', 'mart', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(gross_billed) FROM mart.fact_billing) - (SELECT SUM(gross_billed) FROM stg.billings)) < 0.01 THEN 0 ELSE 1 END),
       'Total billed in the mart = total in staging', NULL
UNION ALL SELECT 'MRT-014', 'mart_recon_hours', 'mart', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(hours) FROM mart.fact_hours) - (SELECT SUM(regular_hours + overtime_hours) FROM stg.timecards)) < 0.01 THEN 0 ELSE 1 END),
       'Total hours in the mart = total hours in staging', NULL
UNION ALL SELECT 'MRT-015', 'mart_recon_budget', 'mart', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(revised_budget) FROM mart.fact_budget) - (SELECT SUM(revised_budget) FROM stg.budget_lines)) < 0.01 THEN 0 ELSE 1 END),
       'Total revised budget in the mart = total in staging', NULL
UNION ALL SELECT 'MRT-016', 'mart_data_freshness', 'mart', 'freshness', 'warn',
       (SELECT CASE WHEN DATE_DIFF('day', (SELECT MAX(d.date) FROM mart.fact_cost f JOIN mart.dim_date d ON d.date_key = f.date_key),
                                          (SELECT as_of_date FROM ops.etl_params)) <= 35 THEN 0 ELSE 1 END),
       'Latest cost posting is within 35 days of the as-of date', NULL

-- ============================ METRICS: logic and reconciliation ============================
UNION ALL SELECT 'MET-001', 'metric_pct_complete_range', 'metrics', 'range', 'critical',
       (SELECT COUNT(*) FROM metrics.v_project_cost_progress WHERE pct_complete IS NULL OR pct_complete < 0 OR pct_complete > 1 OR estimated_cost_at_completion <= 0),
       'Percent complete is between 0 and 100% and EAC is positive for every project', NULL
UNION ALL SELECT 'MET-002', 'metric_summary_no_fanout', 'metrics', 'row_count', 'critical',
       (SELECT CASE WHEN (SELECT COUNT(*) FROM metrics.v_project_summary) = (SELECT COUNT(*) FROM mart.dim_project)
                     AND (SELECT COUNT(*) FROM metrics.v_project_summary) = (SELECT COUNT(DISTINCT project_id) FROM metrics.v_project_summary) THEN 0 ELSE 1 END),
       'v_project_summary has exactly one row per project (no join fan-out)', NULL
UNION ALL SELECT 'MET-003', 'metric_backlog_reconciles', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT total_backlog FROM metrics.v_portfolio_kpis)
                           - (SELECT SUM(backlog_remaining) FROM metrics.v_project_summary)
                           - (SELECT SUM(amount) FROM mart.fact_pipeline WHERE is_awarded_unstarted)) < 0.01 THEN 0 ELSE 1 END),
       'Portfolio backlog = sum of project backlog + awarded-not-started', NULL
UNION ALL SELECT 'MET-004', 'metric_pipeline_reconciles', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT weighted_pipeline FROM metrics.v_portfolio_kpis)
                           - (SELECT SUM(amount * probability) FROM stg.opportunities WHERE stage IN ('Lead','Qualified','Proposal','Negotiation'))) < 0.01 THEN 0 ELSE 1 END),
       'Weighted pipeline = sum(amount x probability) over open opportunities in staging', NULL
UNION ALL SELECT 'MET-005', 'metric_change_orders_reconcile', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT pending_co_revenue FROM metrics.v_portfolio_kpis)
                           - (SELECT SUM(amount) FROM stg.change_orders WHERE status = 'Pending'
                                AND project_id IN (SELECT project_id FROM stg.projects WHERE status = 'Active'))) < 0.01 THEN 0 ELSE 1 END),
       'Portfolio pending change-order revenue = pending change orders on active jobs in staging', NULL
UNION ALL SELECT 'MET-006', 'metric_billing_reconciles', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(billed_to_date) FROM metrics.v_project_wip) - (SELECT SUM(gross_billed) FROM stg.billings)) < 0.01 THEN 0 ELSE 1 END),
       'Billed to date across projects = total in staging', NULL
UNION ALL SELECT 'MET-007', 'metric_fade_share_sums_to_one', 'metrics', 'logic', 'critical',
       (SELECT CASE WHEN ABS(COALESCE(SUM(share_of_fade), 0) - 1) < 0.0001 THEN 0 ELSE 1 END FROM metrics.v_project_margin WHERE status = 'Active'),
       'Share of margin fade across jobs with positive fade sums to 100%', NULL
UNION ALL SELECT 'MET-008', 'metric_safety_hours_reconcile', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(hours_all) FROM metrics.v_safety_by_project) - (SELECT SUM(hours) FROM mart.fact_hours)) < 0.01
                     AND (SELECT SUM(incidents_all) FROM metrics.v_safety_by_project) = (SELECT COUNT(*) FROM mart.fact_safety) THEN 0 ELSE 1 END),
       'Safety rates use all hours and all incidents in the mart', NULL
UNION ALL SELECT 'MET-009', 'metric_completed_jobs_at_100pct', 'metrics', 'logic', 'warn',
       (SELECT COUNT(*) FROM metrics.v_project_cost_progress WHERE status = 'Completed' AND pct_complete < 0.9999),
       'Completed jobs show 100% complete', NULL

-- ============================ ERP EXPANSION: keys, references, ranges ============================
UNION ALL SELECT 'MRT-050', 'mart_erp_primary_keys_unique', 'mart', 'uniqueness', 'critical',
       (SELECT COUNT(*) FROM (SELECT po_line_id FROM mart.fact_purchase_order GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT receipt_id FROM mart.fact_receipt GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT invoice_id FROM mart.fact_ap_invoice GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT sub_pay_app_id FROM mart.fact_sub_pay_app GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT commitment_id FROM mart.fact_commitment GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT usage_id FROM mart.fact_equipment_usage GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT rfi_id FROM mart.fact_rfi GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT submittal_id FROM mart.fact_submittal GROUP BY 1 HAVING COUNT(*) > 1))
     + (SELECT COUNT(*) FROM (SELECT milestone_id FROM mart.fact_milestone GROUP BY 1 HAVING COUNT(*) > 1)),
       'No duplicate keys in procurement, payables, equipment, RFI, submittal or milestone facts', NULL
UNION ALL SELECT 'MRT-051', 'mart_po_receipts_reference_po', 'mart', 'referential', 'critical',
       (SELECT COUNT(*) FROM mart.fact_receipt r WHERE NOT EXISTS (SELECT 1 FROM mart.fact_purchase_order p WHERE p.po_line_id = r.po_line_id)),
       'Every receipt points at a purchase-order line', NULL
UNION ALL SELECT 'MRT-052', 'mart_ap_invoices_reference_po', 'mart', 'referential', 'critical',
       (SELECT COUNT(*) FROM mart.fact_ap_invoice a WHERE NOT EXISTS (SELECT 1 FROM mart.fact_purchase_order p WHERE p.po_line_id = a.po_line_id)),
       'Every vendor invoice points at a purchase-order line', NULL
UNION ALL SELECT 'MRT-053', 'mart_sub_pay_apps_reference_commitment', 'mart', 'referential', 'critical',
       (SELECT COUNT(*) FROM mart.fact_sub_pay_app s WHERE NOT EXISTS (SELECT 1 FROM mart.fact_commitment c WHERE c.commitment_id = s.commitment_id)),
       'Every subcontractor pay application points at a commitment', NULL
UNION ALL SELECT 'MRT-054', 'mart_erp_facts_have_dimension_keys', 'mart', 'referential', 'critical',
       (SELECT COUNT(*) FROM mart.fact_purchase_order WHERE project_key IS NULL OR vendor_key IS NULL OR cost_code_key IS NULL)
     + (SELECT COUNT(*) FROM mart.fact_commitment WHERE project_key IS NULL OR vendor_key IS NULL)
     + (SELECT COUNT(*) FROM mart.fact_equipment_usage WHERE project_key IS NULL OR equipment_key IS NULL)
     + (SELECT COUNT(*) FROM mart.fact_rfi WHERE project_key IS NULL)
     + (SELECT COUNT(*) FROM mart.fact_milestone WHERE project_key IS NULL),
       'Facts resolve to project, vendor, cost code and equipment dimensions', NULL
UNION ALL SELECT 'STG-070', 'stg_vendor_names_in_master', 'staging', 'referential', 'critical',
       (SELECT COUNT(*) FROM stg.purchase_orders po WHERE NOT EXISTS (SELECT 1 FROM stg.vendors v WHERE v.vendor_name = po.vendor_std))
     + (SELECT COUNT(*) FROM stg.ap_invoices a WHERE NOT EXISTS (SELECT 1 FROM stg.vendors v WHERE v.vendor_name = a.vendor_std)),
       'Standardised vendor names on POs and invoices all exist in the vendor master', NULL
UNION ALL SELECT 'STG-071', 'stg_erp_ranges', 'staging', 'range', 'critical',
       (SELECT COUNT(*) FROM stg.purchase_orders WHERE quantity <= 0 OR unit_price < 0)
     + (SELECT COUNT(*) FROM stg.po_receipts WHERE received_qty <= 0)
     + (SELECT COUNT(*) FROM stg.equipment_usage WHERE days_used < 0 OR days_used > 31 OR standby_days < 0)
     + (SELECT COUNT(*) FROM stg.inventory_items WHERE on_hand_qty < 0)
     + (SELECT COUNT(*) FROM stg.subcontract_pay_apps WHERE gross_billed < 0),
       'No negative quantities or prices, equipment days within 0-31, no negative stock or pay applications', NULL
UNION ALL SELECT 'STG-072', 'stg_erp_date_order', 'staging', 'logic', 'critical',
       (SELECT COUNT(*) FROM stg.purchase_orders WHERE promised_date < order_date OR (received_date IS NOT NULL AND received_date < order_date))
     + (SELECT COUNT(*) FROM stg.rfis WHERE response_date IS NOT NULL AND response_date < submitted_date)
     + (SELECT COUNT(*) FROM stg.ap_invoices WHERE invoice_date > (SELECT as_of_date FROM ops.etl_params)),
       'Delivery, response and invoice dates are in a possible order and not in the future', NULL

-- ============================ ERP EXPANSION: reconciliations ============================
UNION ALL SELECT 'MET-020', 'metric_open_po_reconciles', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT open_po_value FROM metrics.v_portfolio_kpis)
                           - (SELECT COALESCE(SUM(ordered_amount), 0) FROM mart.fact_purchase_order WHERE status IN ('Ordered','Shipped','Partially Received'))) < 0.01
                     AND (SELECT COUNT(*) FROM metrics.v_po_line_status) = (SELECT COUNT(*) FROM mart.fact_purchase_order) THEN 0 ELSE 1 END),
       'Open order value and line count agree with the mart (no join fan-out in the PO view)', NULL
UNION ALL SELECT 'MET-021', 'metric_received_value_reconciles', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(received_amount) FROM metrics.v_po_line_status) - (SELECT SUM(received_amount) FROM mart.fact_receipt)) < 0.01
                     AND ABS((SELECT SUM(invoiced_amount) FROM metrics.v_po_line_status) - (SELECT SUM(amount) FROM mart.fact_ap_invoice)) < 0.01 THEN 0 ELSE 1 END),
       'Received and invoiced value on PO lines equal the receipt and invoice totals', NULL
UNION ALL SELECT 'MET-022', 'metric_aging_buckets_reconcile', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(amount_open) FROM metrics.v_aging_summary WHERE ledger = 'AP') - (SELECT ap_open FROM metrics.v_portfolio_kpis)) < 0.01
                     AND ABS((SELECT SUM(amount_open) FROM metrics.v_aging_summary WHERE ledger = 'AR') - (SELECT ar_open FROM metrics.v_portfolio_kpis)) < 0.01
                     AND ABS((SELECT SUM(ap_open) FROM metrics.v_project_summary) - (SELECT ap_open FROM metrics.v_portfolio_kpis)) < 0.01 THEN 0 ELSE 1 END),
       'AP and AR aging buckets sum to the portfolio totals and to the project roll-up', NULL
UNION ALL SELECT 'MET-023', 'metric_subcontract_billing_reconciles', 'metrics', 'reconciliation', 'critical',
       (SELECT CASE WHEN ABS((SELECT SUM(billed_to_date) FROM mart.fact_commitment WHERE commitment_type = 'Subcontract')
                           - (SELECT SUM(gross_billed) FROM mart.fact_sub_pay_app)) < 0.01 THEN 0 ELSE 1 END),
       'Commitment billed-to-date equals the sum of subcontractor pay applications', NULL
UNION ALL SELECT 'MET-024', 'metric_project_summary_one_row', 'metrics', 'logic', 'critical',
       (SELECT CASE WHEN (SELECT COUNT(*) FROM metrics.v_project_summary) = (SELECT COUNT(*) FROM mart.dim_project) THEN 0 ELSE 1 END),
       'Project summary still has exactly one row per project after the ERP joins', NULL

-- ============================ ERP EXPANSION: business exceptions (reported, not build-breaking) ============================
UNION ALL SELECT 'BIZ-001', 'biz_overdue_open_purchase_orders', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_po_line_status WHERE is_overdue_open),
       'Open purchase-order lines past their promised date', NULL
UNION ALL SELECT 'BIZ-002', 'biz_received_not_invoiced', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_po_line_status WHERE received_not_invoiced),
       'Receipts older than 30 days with no vendor invoice (unrecorded liability)', NULL
UNION ALL SELECT 'BIZ-003', 'biz_invoiced_not_received', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_po_line_status WHERE invoiced_not_received),
       'Vendor invoices with nothing received on the PO line (billed ahead of delivery)', NULL
UNION ALL SELECT 'BIZ-004', 'biz_invoice_price_variance', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_po_line_status WHERE price_variance_pct > 0.05),
       'Invoices more than 5% above the value received (three-way-match price exception)', NULL
UNION ALL SELECT 'BIZ-005', 'biz_overdue_rfis', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_rfi_open_detail WHERE days_past_due > 0),
       'Open RFIs past their response-due date', NULL
UNION ALL SELECT 'BIZ-006', 'biz_inventory_below_reorder', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_inventory_status WHERE reorder_status = 'Below reorder point'),
       'Inventory items below their reorder point', NULL
UNION ALL SELECT 'BIZ-007', 'biz_ar_over_90_days', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM metrics.v_ar_open_items WHERE days_past_due > 90),
       'Owner billings more than 90 days past due', NULL
UNION ALL SELECT 'BIZ-008', 'biz_disputed_sub_pay_apps', 'metrics', 'business_exception', 'info',
       (SELECT COUNT(*) FROM mart.fact_sub_pay_app WHERE status = 'Disputed'),
       'Subcontractor pay applications in dispute', NULL
) c;
