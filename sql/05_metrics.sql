-- =============================================================================
-- 05_metrics.sql   METRIC LAYER (one definition per metric, in one place)
-- SYNTHETIC DATA: Gulf Coast Builders is a fictional company.
--
-- Every number on the dashboard comes from one of these views, and each metric
-- is defined exactly once. The plain-English formula sits next to the SQL; the
-- same definitions are written up in docs/metric_definitions.md and map 1:1 to
-- DAX measures in a Power BI semantic model.
--
-- Build order is deliberate: base facts -> small single-purpose views ->
-- v_project_summary / v_portfolio_kpis, which only JOIN the earlier views.
--
-- Conventions: money = USD; margins are ratios (0.095 = 9.5%); "pts" = percentage points;
-- the as-of date comes from ops.etl_params; "active" = project status 'Active'.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- M1. Cost progress: percent complete (cost-to-cost), estimated cost at completion,
--     cost to complete
--   Cost to complete (CTC)               = sum of the PM's estimate_to_complete on every cost-code line
--   Estimated cost at completion (EAC)   = actual cost to date + cost to complete
--   Percent complete (cost-to-cost)      = actual cost to date / EAC          (capped at 100%)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_project_cost_progress AS
WITH actual AS (
    SELECT project_key, SUM(actual_cost) AS actual_cost_to_date
    FROM mart.fact_cost GROUP BY project_key
),
budget AS (
    SELECT project_key,
           SUM(original_budget)      AS original_budget_cost,
           SUM(approved_co_budget)   AS approved_co_budget,
           SUM(revised_budget)       AS revised_budget_cost,
           SUM(estimate_to_complete) AS cost_to_complete
    FROM mart.fact_budget GROUP BY project_key
)
SELECT p.project_key, p.project_id, p.project_name, p.business_unit, p.status,
       b.original_budget_cost, b.approved_co_budget, b.revised_budget_cost,
       COALESCE(a.actual_cost_to_date, 0)                                              AS actual_cost_to_date,
       b.cost_to_complete,
       COALESCE(a.actual_cost_to_date, 0) + b.cost_to_complete                          AS estimated_cost_at_completion,
       CASE WHEN COALESCE(a.actual_cost_to_date, 0) + b.cost_to_complete > 0
            THEN LEAST(1.0, COALESCE(a.actual_cost_to_date, 0) / (COALESCE(a.actual_cost_to_date, 0) + b.cost_to_complete))
       END                                                                              AS pct_complete
FROM mart.dim_project p
JOIN budget b ON b.project_key = p.project_key
LEFT JOIN actual a ON a.project_key = p.project_key;

-- -----------------------------------------------------------------------------
-- M2. Contract value, projected margin and margin fade
--   Revised contract value = original contract + approved change-order revenue
--   Projected profit       = revised contract - EAC
--   Projected margin       = projected profit / revised contract
--   Bid margin             = (original contract - original budget cost) / original contract
--   Margin fade (pts)      = (bid margin - projected margin) x 100        positive = losing margin
--   Margin fade ($)        = (bid margin - projected margin) x revised contract   (profit lost versus the bid)
--   Share of fade          = job's margin-fade $ / total margin-fade $ of jobs with positive fade   (active jobs)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_project_margin AS
WITH approved_co AS (
    SELECT project_key, SUM(amount) AS approved_co_revenue
    FROM mart.fact_change_order WHERE status = 'Approved' GROUP BY project_key
),
base AS (
    SELECT cp.project_key, cp.project_id, cp.project_name, cp.business_unit, cp.status,
           dp.original_contract_value,
           COALESCE(ac.approved_co_revenue, 0)                                     AS approved_co_revenue,
           dp.original_contract_value + COALESCE(ac.approved_co_revenue, 0)        AS revised_contract_value,
           cp.estimated_cost_at_completion,
           dp.original_margin_pct                                                  AS bid_margin_pct
    FROM metrics.v_project_cost_progress cp
    JOIN mart.dim_project dp ON dp.project_key = cp.project_key
    LEFT JOIN approved_co ac ON ac.project_key = cp.project_key
),
calc AS (
    SELECT *,
           revised_contract_value - estimated_cost_at_completion                              AS projected_profit,
           (revised_contract_value - estimated_cost_at_completion) / revised_contract_value   AS projected_margin_pct
    FROM base
),
fade AS (
    SELECT *,
           ROUND((bid_margin_pct - projected_margin_pct) * 100, 2)             AS margin_fade_pts,
           (bid_margin_pct - projected_margin_pct) * revised_contract_value    AS margin_fade_dollars
    FROM calc
)
SELECT f.*,
       CASE WHEN f.status = 'Active' AND f.margin_fade_dollars > 0
            THEN f.margin_fade_dollars / NULLIF(SUM(CASE WHEN f.status = 'Active' AND f.margin_fade_dollars > 0
                                                         THEN f.margin_fade_dollars END) OVER (), 0) END AS share_of_fade,
       CASE WHEN f.status = 'Active'
            THEN RANK() OVER (PARTITION BY (f.status = 'Active') ORDER BY f.margin_fade_dollars DESC) END AS fade_rank
FROM fade f;

-- -----------------------------------------------------------------------------
-- M3. Over / under billing (WIP)
--   Earned revenue          = percent complete x revised contract value
--   Billed to date          = sum of gross pay applications
--   Over / (under) billing  = billed to date - earned revenue      positive = over-billed (cash ahead of work)
--                                                                     negative = under-billed (we are financing the owner)
--   Billing position        = 'Over-billed' / 'Under-billed' when |over/under| > threshold x revised contract, else 'Balanced'
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_project_wip AS
WITH billed AS (
    SELECT project_key, SUM(gross_billed) AS billed_to_date, SUM(retainage_held) AS retainage_held
    FROM mart.fact_billing GROUP BY project_key
)
SELECT m.project_key, m.project_id, m.status, m.revised_contract_value,
       cp.pct_complete,
       cp.pct_complete * m.revised_contract_value                                      AS earned_revenue,
       COALESCE(b.billed_to_date, 0)                                                   AS billed_to_date,
       COALESCE(b.retainage_held, 0)                                                   AS retainage_held,
       COALESCE(b.billed_to_date, 0) - cp.pct_complete * m.revised_contract_value      AS over_under_billing,
       (COALESCE(b.billed_to_date, 0) - cp.pct_complete * m.revised_contract_value) / m.revised_contract_value AS over_under_pct_of_contract,
       CASE WHEN m.status <> 'Active' THEN 'Closed'
            WHEN (COALESCE(b.billed_to_date, 0) - cp.pct_complete * m.revised_contract_value) / m.revised_contract_value >  (SELECT billing_balance_threshold FROM ops.etl_params) THEN 'Over-billed'
            WHEN (COALESCE(b.billed_to_date, 0) - cp.pct_complete * m.revised_contract_value) / m.revised_contract_value < -(SELECT billing_balance_threshold FROM ops.etl_params) THEN 'Under-billed'
            ELSE 'Balanced' END                                                        AS billing_position
FROM metrics.v_project_margin m
JOIN metrics.v_project_cost_progress cp ON cp.project_key = m.project_key
LEFT JOIN billed b ON b.project_key = m.project_key;

-- -----------------------------------------------------------------------------
-- M4. Pending change-order exposure
--   Pending CO revenue      = sum of amount on change orders with status 'Pending' (work asked for, not yet approved)
--   Pending CO cost at risk = sum of estimated_cost on the same change orders (cost we carry if the owner never approves)
--   Oldest pending age      = days since the earliest pending submission
--   Exposure % of contract  = pending revenue / revised contract value
--   Approval cycle (days)   = average days from submission to decision on decided change orders
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_change_order_exposure AS
SELECT m.project_key, m.project_id, m.status,
       COUNT(*) FILTER (WHERE co.status = 'Pending')                                  AS pending_co_count,
       COALESCE(SUM(co.amount)         FILTER (WHERE co.status = 'Pending'), 0)       AS pending_co_revenue,
       COALESCE(SUM(co.estimated_cost) FILTER (WHERE co.status = 'Pending'), 0)       AS pending_co_cost_at_risk,
       MAX(co.age_days)                FILTER (WHERE co.status = 'Pending')           AS oldest_pending_age_days,
       ROUND(AVG(co.age_days)          FILTER (WHERE co.status = 'Pending'), 0)       AS avg_pending_age_days,
       COALESCE(SUM(co.amount)         FILTER (WHERE co.status = 'Pending'), 0) / m.revised_contract_value AS pending_pct_of_contract,
       COUNT(*) FILTER (WHERE co.status = 'Approved')                                 AS approved_co_count,
       COALESCE(SUM(co.amount)         FILTER (WHERE co.status = 'Approved'), 0)      AS approved_co_revenue,
       COUNT(*) FILTER (WHERE co.status = 'Rejected')                                 AS rejected_co_count,
       ROUND(AVG(co.cycle_days)        FILTER (WHERE co.cycle_days IS NOT NULL), 1)   AS avg_approval_cycle_days
FROM metrics.v_project_margin m
LEFT JOIN mart.fact_change_order co ON co.project_key = m.project_key
GROUP BY m.project_key, m.project_id, m.status, m.revised_contract_value;

-- -----------------------------------------------------------------------------
-- M5. Backlog
--   Backlog (active jobs)   = revised contract value - earned revenue, for active projects (contracted work not yet performed)
--   Backlog (awarded)       = amount of won opportunities that have no ERP project yet
--   Total backlog           = active backlog + awarded-not-started. Unsigned pipeline is NOT backlog.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_backlog AS
SELECT 'Active project' AS backlog_source, w.project_id AS reference_id, p.project_name AS reference_name,
       p.business_unit, GREATEST(w.revised_contract_value - w.earned_revenue, 0) AS backlog_amount
FROM metrics.v_project_wip w
JOIN mart.dim_project p ON p.project_key = w.project_key
WHERE w.status = 'Active'
UNION ALL
SELECT 'Awarded, not started', f.opportunity_id, f.opportunity_name, f.business_unit, f.amount
FROM mart.fact_pipeline f
WHERE f.is_awarded_unstarted;

-- -----------------------------------------------------------------------------
-- M6. Pipeline: weighted pipeline, win rate
--   Weighted value  = amount x probability, for OPEN opportunities (Lead, Qualified, Proposal, Negotiation)
--   Win rate        = won / (won + lost), by count   (value-weighted version: won $ / (won $ + lost $))
--   Pipeline coverage = weighted pipeline / total backlog
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_pipeline_by_stage AS
SELECT business_unit, stage,
       CASE stage WHEN 'Lead' THEN 1 WHEN 'Qualified' THEN 2 WHEN 'Proposal' THEN 3 WHEN 'Negotiation' THEN 4
                  WHEN 'Won' THEN 5 WHEN 'Lost' THEN 6 END AS stage_order,
       COUNT(*) AS opportunity_count, SUM(amount) AS total_amount, SUM(weighted_amount) AS weighted_amount
FROM mart.fact_pipeline
GROUP BY business_unit, stage;

CREATE OR REPLACE VIEW metrics.v_pipeline_by_bu AS
SELECT business_unit,
       COUNT(*) FILTER (WHERE is_open)                                   AS open_count,
       COALESCE(SUM(amount)          FILTER (WHERE is_open), 0)          AS open_amount,
       COALESCE(SUM(weighted_amount) FILTER (WHERE is_open), 0)          AS weighted_pipeline,
       COUNT(*) FILTER (WHERE is_won)                                    AS won_count,
       COUNT(*) FILTER (WHERE is_lost)                                   AS lost_count,
       COUNT(*) FILTER (WHERE is_won) * 1.0 / NULLIF(COUNT(*) FILTER (WHERE is_won OR is_lost), 0) AS win_rate,
       SUM(amount) FILTER (WHERE is_won) / NULLIF(SUM(amount) FILTER (WHERE is_won OR is_lost), 0) AS win_rate_by_value
FROM mart.fact_pipeline
GROUP BY business_unit;

-- -----------------------------------------------------------------------------
-- M7. Safety
--   Recordable incident rate (TRIR) = recordable incidents x 200,000 / hours worked      (200,000 = 100 workers x 2,000 hrs, OSHA convention)
--     recordable = incident_type 'Recordable' or 'Lost Time'
--   Rates are given for all history in the data (24 months) and for the trailing 12 months.
--   Cluster flag = at least N incidents (any type) on one project inside any window of W days (N and W live in ops.etl_params).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_safety_by_project AS
WITH hrs AS (
    SELECT h.project_key, SUM(h.hours) AS hours_all,
           SUM(h.hours) FILTER (WHERE d.date >  (SELECT as_of_date FROM ops.etl_params) - INTERVAL 365 DAY) AS hours_12m
    FROM mart.fact_hours h JOIN mart.dim_date d ON d.date_key = h.date_key GROUP BY h.project_key
),
inc AS (
    SELECT s.project_key,
           COUNT(*)                                                     AS incidents_all,
           COUNT(*) FILTER (WHERE s.recordable_flag = 'Y')              AS recordables_all,
           COUNT(*) FILTER (WHERE d.date >  (SELECT as_of_date FROM ops.etl_params) - INTERVAL 365 DAY)                              AS incidents_12m,
           COUNT(*) FILTER (WHERE s.recordable_flag = 'Y' AND d.date > (SELECT as_of_date FROM ops.etl_params) - INTERVAL 365 DAY)   AS recordables_12m
    FROM mart.fact_safety s JOIN mart.dim_date d ON d.date_key = s.date_key GROUP BY s.project_key
),
windows AS (   -- for each incident: how many incidents on the same project fall in the next W days
    SELECT a.project_key, da.date AS window_start,
           COUNT(*) AS incidents_in_window
    FROM mart.fact_safety a
    JOIN mart.dim_date da ON da.date_key = a.date_key
    JOIN mart.fact_safety b ON b.project_key = a.project_key
    JOIN mart.dim_date db ON db.date_key = b.date_key
                         AND db.date >= da.date
                         AND db.date <  da.date + CAST((SELECT safety_cluster_window_days FROM ops.etl_params) AS INTEGER)
    GROUP BY a.project_key, a.incident_id, da.date
),
peak AS (
    SELECT project_key, incidents_in_window AS peak_incidents_in_window, window_start AS peak_window_start
    FROM (SELECT w.*, ROW_NUMBER() OVER (PARTITION BY project_key ORDER BY incidents_in_window DESC, window_start) AS rn FROM windows w) x
    WHERE rn = 1
)
SELECT p.project_key, p.project_id, p.project_name, p.business_unit, p.status,
       COALESCE(h.hours_all, 0)       AS hours_all,
       COALESCE(i.incidents_all, 0)   AS incidents_all,
       COALESCE(i.recordables_all, 0) AS recordables_all,
       CASE WHEN h.hours_all > 0 THEN COALESCE(i.recordables_all, 0) * 200000.0 / h.hours_all END AS trir_all,
       COALESCE(h.hours_12m, 0)       AS hours_12m,
       COALESCE(i.incidents_12m, 0)   AS incidents_12m,
       COALESCE(i.recordables_12m, 0) AS recordables_12m,
       CASE WHEN h.hours_12m > 0 THEN COALESCE(i.recordables_12m, 0) * 200000.0 / h.hours_12m END AS trir_12m,
       pk.peak_incidents_in_window,
       pk.peak_window_start,
       COALESCE(pk.peak_incidents_in_window, 0) >= (SELECT safety_cluster_min_incidents FROM ops.etl_params) AS is_cluster
FROM mart.dim_project p
LEFT JOIN hrs  h  ON h.project_key  = p.project_key
LEFT JOIN inc  i  ON i.project_key  = p.project_key
LEFT JOIN peak pk ON pk.project_key = p.project_key;

CREATE OR REPLACE VIEW metrics.v_safety_by_bu AS
SELECT business_unit,
       SUM(hours_all) AS hours_all, SUM(incidents_all) AS incidents_all, SUM(recordables_all) AS recordables_all,
       SUM(recordables_all) * 200000.0 / NULLIF(SUM(hours_all), 0) AS trir_all,
       SUM(hours_12m) AS hours_12m, SUM(incidents_12m) AS incidents_12m, SUM(recordables_12m) AS recordables_12m,
       SUM(recordables_12m) * 200000.0 / NULLIF(SUM(hours_12m), 0) AS trir_12m
FROM metrics.v_safety_by_project
GROUP BY business_unit;

-- Incidents by cause and type (where are they clustering?)
CREATE OR REPLACE VIEW metrics.v_safety_by_cause AS
SELECT p.business_unit, p.project_id, s.cause_category, s.incident_type, COUNT(*) AS incidents
FROM mart.fact_safety s JOIN mart.dim_project p ON p.project_key = s.project_key
GROUP BY p.business_unit, p.project_id, s.cause_category, s.incident_type;

-- -----------------------------------------------------------------------------
-- M8. Project time series for the drill-down page (Q7)
--   Budget (plan) curve     = revised budget spread across the planned schedule on a standard S-curve
--                             cum(u) = 3u^2 - 2u^3, u = months elapsed / planned months. The ERP export has no baseline
--                             schedule, so the plan curve is an assumption and is labelled as such on the dashboard.
--   Actual curve            = cumulative posted cost through each month-end up to the as-of date
--   Forecast curve          = actual to date, then cost to complete spread over the remaining planned months with the
--                             same S-curve shape; ends at EAC. Completed jobs forecast = actual.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_project_cost_curve AS
WITH proj AS (
    SELECT cp.project_key, cp.project_id, cp.status, cp.revised_budget_cost, cp.actual_cost_to_date,
           cp.cost_to_complete, cp.estimated_cost_at_completion,
           LAST_DAY(dp.start_date) AS first_me, LAST_DAY(dp.planned_end_date) AS last_me,
           DATE_DIFF('month', LAST_DAY(dp.start_date), LAST_DAY(dp.planned_end_date)) + 1 AS n_months
    FROM metrics.v_project_cost_progress cp JOIN mart.dim_project dp ON dp.project_key = cp.project_key
),
months AS (
    SELECT p.*, d.date AS month_end,
           ROW_NUMBER() OVER (PARTITION BY p.project_key ORDER BY d.date) AS k
    FROM proj p
    JOIN mart.dim_date d ON d.is_month_end AND d.date BETWEEN p.first_me AND p.last_me
),
monthly_cost AS (
    SELECT c.project_key, d.date AS month_end, SUM(c.actual_cost) AS month_cost
    FROM mart.fact_cost c JOIN mart.dim_date d ON d.date_key = c.date_key GROUP BY c.project_key, d.date
),
joined AS (
    SELECT m.*, COALESCE(mc.month_cost, 0) AS month_cost,
           m.month_end <= (SELECT as_of_date FROM ops.etl_params) AS is_actual_month
    FROM months m LEFT JOIN monthly_cost mc ON mc.project_key = m.project_key AND mc.month_end = m.month_end
),
cum AS (
    SELECT j.*,
           SUM(CASE WHEN is_actual_month THEN month_cost ELSE 0 END)
               OVER (PARTITION BY project_key ORDER BY month_end)                          AS actual_cum,
           SUM(CASE WHEN is_actual_month THEN 1 ELSE 0 END) OVER (PARTITION BY project_key) AS k_asof,
           (k * 1.0 / n_months)                                                            AS u,
           3 * POWER(k * 1.0 / n_months, 2) - 2 * POWER(k * 1.0 / n_months, 3)             AS s_cur
    FROM joined j
)
SELECT project_key, project_id, month_end, k AS month_number,
       ROUND(revised_budget_cost * s_cur, 2)                                                AS budget_cum,
       CASE WHEN is_actual_month THEN ROUND(actual_cum, 2) END                              AS actual_cum,
       CASE WHEN is_actual_month THEN ROUND(actual_cum, 2)
            WHEN status = 'Completed' THEN ROUND(actual_cost_to_date, 2)
            ELSE ROUND(actual_cost_to_date + cost_to_complete *
                       (s_cur - (3 * POWER(k_asof * 1.0 / n_months, 2) - 2 * POWER(k_asof * 1.0 / n_months, 3))) /
                       NULLIF(1 - (3 * POWER(k_asof * 1.0 / n_months, 2) - 2 * POWER(k_asof * 1.0 / n_months, 3)), 0), 2)
       END                                                                                  AS forecast_cum,
       ROUND(estimated_cost_at_completion, 2)                                               AS eac
FROM cum;

-- Cumulative billing vs. cost per month (billing position over time).
--   Earned revenue is shown at the CURRENT percent-complete basis (cumulative cost / current EAC), so past months are a
--   restatement, not what the WIP report said at the time.
CREATE OR REPLACE VIEW metrics.v_project_billing_curve AS
WITH monthly AS (
    SELECT c.project_key, d.date AS month_end, SUM(c.actual_cost) AS month_cost
    FROM mart.fact_cost c JOIN mart.dim_date d ON d.date_key = c.date_key GROUP BY c.project_key, d.date
),
bill AS (
    SELECT b.project_key, d.date AS month_end, SUM(b.gross_billed) AS month_billed
    FROM mart.fact_billing b JOIN mart.dim_date d ON d.date_key = b.date_key GROUP BY b.project_key, d.date
),
grid AS (
    SELECT cp.project_key, cp.project_id, cp.estimated_cost_at_completion, w.revised_contract_value, d.date AS month_end
    FROM metrics.v_project_cost_progress cp
    JOIN metrics.v_project_wip w ON w.project_key = cp.project_key
    JOIN mart.dim_project dp ON dp.project_key = cp.project_key
    JOIN mart.dim_date d ON d.is_month_end
                        AND d.date BETWEEN LAST_DAY(dp.start_date) AND LEAST(LAST_DAY(dp.planned_end_date), (SELECT as_of_date FROM ops.etl_params))
)
SELECT g.project_key, g.project_id, g.month_end,
       ROUND(SUM(COALESCE(m.month_cost, 0))   OVER (PARTITION BY g.project_key ORDER BY g.month_end), 2) AS cost_cum,
       ROUND(SUM(COALESCE(b.month_billed, 0)) OVER (PARTITION BY g.project_key ORDER BY g.month_end), 2) AS billed_cum,
       ROUND(LEAST(1.0, SUM(COALESCE(m.month_cost, 0)) OVER (PARTITION BY g.project_key ORDER BY g.month_end)
                        / g.estimated_cost_at_completion) * g.revised_contract_value, 2)                 AS earned_cum
FROM grid g
LEFT JOIN monthly m ON m.project_key = g.project_key AND m.month_end = g.month_end
LEFT JOIN bill    b ON b.project_key = g.project_key AND b.month_end = g.month_end;

-- -----------------------------------------------------------------------------
-- Detail views feeding the drill-down tables
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_change_order_detail AS
SELECT p.project_id, co.change_order_id, co.co_number, co.description, co.reason, co.status, co.amount, co.estimated_cost,
       ds.date AS submitted_date, dx.date AS decision_date, co.age_days, co.cycle_days
FROM mart.fact_change_order co
JOIN mart.dim_project p ON p.project_key = co.project_key
JOIN mart.dim_date ds ON ds.date_key = co.submitted_date_key
LEFT JOIN mart.dim_date dx ON dx.date_key = co.decision_date_key;

CREATE OR REPLACE VIEW metrics.v_safety_detail AS
SELECT p.project_id, s.incident_id, d.date AS incident_date, s.incident_type, s.cause_category, s.severity, s.recordable_flag, s.days_away
FROM mart.fact_safety s
JOIN mart.dim_project p ON p.project_key = s.project_key
JOIN mart.dim_date d ON d.date_key = s.date_key;

-- Cost by category (where did the money go / where is the overrun?) - actual vs revised budget vs EAC
CREATE OR REPLACE VIEW metrics.v_project_cost_by_code AS
WITH a AS (
    SELECT c.project_key, c.cost_code_key, SUM(c.actual_cost) AS actual_cost
    FROM mart.fact_cost c GROUP BY c.project_key, c.cost_code_key
)
SELECT p.project_id, cc.cost_code, cc.cost_code_name, cc.category,
       b.original_budget, b.revised_budget, COALESCE(a.actual_cost, 0) AS actual_cost, b.estimate_to_complete,
       COALESCE(a.actual_cost, 0) + b.estimate_to_complete AS estimated_cost_at_completion,
       COALESCE(a.actual_cost, 0) + b.estimate_to_complete - b.revised_budget AS forecast_variance   -- positive = forecast over budget
FROM mart.fact_budget b
JOIN mart.dim_project p ON p.project_key = b.project_key
JOIN mart.dim_cost_code cc ON cc.cost_code_key = b.cost_code_key
LEFT JOIN a ON a.project_key = b.project_key AND a.cost_code_key = b.cost_code_key;


-- =============================================================================
-- ERP EXPANSION METRICS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- M9. Procurement: purchase-order line status, delivery performance, three-way match
--   On-time delivery   = received on or before the promised date, over fully received lines
--   Days late          = received date - promised date (delivered lines); as-of - promised date (open lines past promise)
--   Open order         = line with status Ordered, Shipped or Partially Received
--   Overdue open order = open line whose promised date is before the as-of date
--   Long-lead item     = typical lead time of 60+ days (flag set by the ERP)
--   Received, not invoiced = more receipts than vendor invoices (one invoice per receipt) and the last receipt is over 30 days old
--   Invoiced, not received = vendor invoice exists but nothing has been received on the line (excl. cancelled)
--   Price variance %   = (invoiced - received value) / received value, only where every receipt has been invoiced
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_po_line_status AS
WITH rc AS (
    SELECT r.po_line_id, COUNT(*) AS receipt_count, SUM(r.received_qty) AS received_qty, SUM(r.received_amount) AS received_amount,
           MAX(d.date) AS last_receipt_date
    FROM mart.fact_receipt r JOIN mart.dim_date d ON d.date_key = r.receipt_date_key
    GROUP BY r.po_line_id
),
inv AS (
    SELECT po_line_id, COUNT(*) AS invoice_count, SUM(amount) AS invoiced_amount,
           SUM(amount) FILTER (WHERE status = 'On Hold') AS on_hold_amount
    FROM mart.fact_ap_invoice GROUP BY po_line_id
),
base AS (
    SELECT p.project_id, dv.vendor_name, dv.vendor_type, dc.cost_code, dc.cost_code_name,
           po.po_line_id, po.po_number, po.item_description, po.uom, po.is_long_lead, po.status, po.ordered_amount, po.quantity,
           po.order_date, po.promised_date, po.ship_date, po.received_date,
           COALESCE(rc.received_qty, 0) AS received_qty, COALESCE(rc.received_amount, 0) AS received_amount, rc.last_receipt_date,
           COALESCE(inv.invoiced_amount, 0) AS invoiced_amount, COALESCE(inv.on_hold_amount, 0) AS on_hold_amount,
           COALESCE(rc.receipt_count, 0) AS receipt_count, COALESCE(inv.invoice_count, 0) AS invoice_count,
           (SELECT as_of_date FROM ops.etl_params) AS as_of
    FROM mart.fact_purchase_order po
    JOIN mart.dim_project   p  ON p.project_key = po.project_key
    JOIN mart.dim_vendor    dv ON dv.vendor_key = po.vendor_key
    JOIN mart.dim_cost_code dc ON dc.cost_code_key = po.cost_code_key
    LEFT JOIN rc  ON rc.po_line_id  = po.po_line_id
    LEFT JOIN inv ON inv.po_line_id = po.po_line_id
)
SELECT b.* EXCLUDE (as_of),
       b.status IN ('Ordered', 'Shipped', 'Partially Received')                                         AS is_open,
       CASE WHEN b.status = 'Received' THEN DATE_DIFF('day', b.promised_date, b.received_date) END      AS days_late_delivered,
       (b.status IN ('Ordered', 'Shipped', 'Partially Received') AND b.promised_date < b.as_of)         AS is_overdue_open,
       CASE WHEN b.status IN ('Ordered', 'Shipped', 'Partially Received') AND b.promised_date < b.as_of
            THEN DATE_DIFF('day', b.promised_date, b.as_of) END                                         AS days_overdue,
       (b.receipt_count > b.invoice_count AND b.receipt_count > 0 AND DATE_DIFF('day', b.last_receipt_date, b.as_of) > 30) AS received_not_invoiced,
       (b.invoice_count > 0 AND b.receipt_count = 0 AND b.status <> 'Cancelled')                        AS invoiced_not_received,
       CASE WHEN b.receipt_count > 0 AND b.invoice_count = b.receipt_count AND b.received_amount > 0
            THEN (b.invoiced_amount - b.received_amount) / b.received_amount END                        AS price_variance_pct
FROM base b;

-- Vendor scorecard (suppliers that have purchase orders)
CREATE OR REPLACE VIEW metrics.v_vendor_scorecard AS
SELECT vendor_name, vendor_type,
       COUNT(*) FILTER (WHERE status <> 'Cancelled')                                       AS po_lines,
       COALESCE(SUM(ordered_amount) FILTER (WHERE status <> 'Cancelled'), 0)               AS ordered_amount,
       COUNT(*) FILTER (WHERE status = 'Received')                                         AS delivered_lines,
       COUNT(*) FILTER (WHERE status = 'Received' AND days_late_delivered <= 0) * 1.0
           / NULLIF(COUNT(*) FILTER (WHERE status = 'Received'), 0)                        AS on_time_rate,
       ROUND(AVG(days_late_delivered) FILTER (WHERE status = 'Received'), 1)               AS avg_days_late,
       COUNT(*) FILTER (WHERE is_overdue_open)                                             AS overdue_open_lines,
       COALESCE(SUM(ordered_amount) FILTER (WHERE is_overdue_open), 0)                     AS overdue_open_amount,
       AVG(price_variance_pct)                                                             AS avg_price_variance_pct,
       COALESCE(SUM(on_hold_amount), 0)                                                    AS on_hold_amount
FROM metrics.v_po_line_status
GROUP BY vendor_name, vendor_type;

-- Open long-lead items and how much trouble they are in
CREATE OR REPLACE VIEW metrics.v_long_lead_watch AS
SELECT project_id, po_line_id, po_number, vendor_name, item_description, ordered_amount, status, order_date, promised_date, ship_date,
       days_overdue,
       CASE WHEN is_overdue_open THEN 'Overdue'
            WHEN promised_date <= (SELECT as_of_date FROM ops.etl_params) + INTERVAL 30 DAY THEN 'Due within 30 days'
            ELSE 'On order' END AS risk
FROM metrics.v_po_line_status
WHERE is_long_lead AND is_open;

-- Three-way-match exceptions: received/invoiced/priced differently from the order
CREATE OR REPLACE VIEW metrics.v_three_way_match_exceptions AS
SELECT 'Received, not invoiced' AS exception_type, project_id, vendor_name, po_line_id, item_description,
       GREATEST(received_amount - invoiced_amount, 0) AS exception_amount, DATE_DIFF('day', last_receipt_date, (SELECT as_of_date FROM ops.etl_params)) AS age_days
FROM metrics.v_po_line_status WHERE received_not_invoiced
UNION ALL
SELECT 'Invoiced, not received', project_id, vendor_name, po_line_id, item_description, invoiced_amount, NULL
FROM metrics.v_po_line_status WHERE invoiced_not_received
UNION ALL
SELECT 'Invoice above received value (>5%)', project_id, vendor_name, po_line_id, item_description,
       invoiced_amount - received_amount, NULL
FROM metrics.v_po_line_status WHERE price_variance_pct > 0.05;

-- -----------------------------------------------------------------------------
-- M10. Commitments and subcontract position
--   Committed            = original commitment + approved changes
--   Billed / paid        = sum of subcontractor pay applications (gross) / cash paid (net of retainage)
--   Retainage held       = 10% held back from each application, until released
--   Balance to bill      = committed - billed
--   Percent billed       = billed / committed
--   Net payable          = billed - retainage held + retainage released - paid
--   Over-committed (cost code) = committed on the line exceeds the line's revised budget by more than 5%
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_subcontract_position AS
WITH unpaid AS (
    SELECT commitment_id,
           MIN(due_date) FILTER (WHERE status IN ('Approved', 'Disputed') AND invoice_date <= (SELECT as_of_date FROM ops.etl_params)) AS oldest_unpaid_due
    FROM mart.fact_sub_pay_app GROUP BY commitment_id
)
SELECT p.project_id, p.project_name, dv.vendor_name, dc.cost_code, dc.cost_code_name, c.commitment_id, c.commitment_type, c.status,
       c.original_amount, c.approved_changes, c.committed_total, c.billed_to_date, c.paid_to_date,
       c.retainage_held, c.retainage_released, c.disputed_amount,
       c.committed_total - c.billed_to_date AS balance_to_bill,
       c.billed_to_date / NULLIF(c.committed_total, 0) AS pct_billed,
       c.billed_to_date - c.retainage_held + c.retainage_released - c.paid_to_date AS net_payable,
       (c.billed_to_date > c.committed_total + 0.01) AS is_overbilled,
       DATE_DIFF('day', u.oldest_unpaid_due, (SELECT as_of_date FROM ops.etl_params)) AS oldest_unpaid_days_past_due
FROM mart.fact_commitment c
JOIN mart.dim_project   p  ON p.project_key = c.project_key
JOIN mart.dim_vendor    dv ON dv.vendor_key = c.vendor_key
JOIN mart.dim_cost_code dc ON dc.cost_code_key = c.cost_code_key
LEFT JOIN unpaid u ON u.commitment_id = c.commitment_id
WHERE c.commitment_type = 'Subcontract';

CREATE OR REPLACE VIEW metrics.v_commitment_vs_budget AS
WITH com AS (
    SELECT project_key, cost_code_key, SUM(committed_total) AS committed_total
    FROM mart.fact_commitment GROUP BY project_key, cost_code_key
),
act AS (
    SELECT project_key, cost_code_key, SUM(actual_cost) AS actual_cost FROM mart.fact_cost GROUP BY project_key, cost_code_key
)
SELECT p.project_id, dc.cost_code, dc.cost_code_name, dc.category,
       b.revised_budget, com.committed_total, COALESCE(a.actual_cost, 0) AS actual_cost,
       COALESCE(a.actual_cost, 0) + b.estimate_to_complete AS estimated_cost_at_completion,
       com.committed_total - b.revised_budget AS committed_over_budget,
       (com.committed_total > b.revised_budget * 1.05) AS is_over_committed
FROM mart.fact_budget b
JOIN com ON com.project_key = b.project_key AND com.cost_code_key = b.cost_code_key
JOIN mart.dim_project   p  ON p.project_key = b.project_key
JOIN mart.dim_cost_code dc ON dc.cost_code_key = b.cost_code_key
LEFT JOIN act a ON a.project_key = b.project_key AND a.cost_code_key = b.cost_code_key;

-- Project procurement roll-up
CREATE OR REPLACE VIEW metrics.v_project_procurement AS
WITH com AS (
    SELECT project_key, SUM(committed_total) AS committed_total,
           SUM(committed_total) FILTER (WHERE commitment_type = 'Subcontract')     AS committed_subcontract,
           SUM(committed_total) FILTER (WHERE commitment_type = 'Purchase Order')  AS committed_po
    FROM mart.fact_commitment GROUP BY project_key
),
po AS (
    SELECT project_id,
           SUM(ordered_amount) FILTER (WHERE status <> 'Cancelled')                          AS po_ordered_to_date,
           SUM(received_amount)                                                              AS po_received_value,
           SUM(invoiced_amount)                                                              AS po_invoiced_value,
           SUM(ordered_amount) FILTER (WHERE is_open)                                        AS open_order_value,
           COUNT(*) FILTER (WHERE is_open)                                                   AS open_lines,
           COUNT(*) FILTER (WHERE is_overdue_open)                                           AS overdue_open_lines,
           COALESCE(SUM(ordered_amount) FILTER (WHERE is_overdue_open), 0)                   AS overdue_open_amount,
           COUNT(*) FILTER (WHERE is_long_lead AND is_open)                                  AS long_lead_open_lines,
           COUNT(*) FILTER (WHERE status = 'Received' AND days_late_delivered <= 0) * 1.0
               / NULLIF(COUNT(*) FILTER (WHERE status = 'Received'), 0)                      AS on_time_rate
    FROM metrics.v_po_line_status GROUP BY project_id
)
SELECT dp.project_id, c.committed_total, c.committed_subcontract, c.committed_po,
       COALESCE(po.po_ordered_to_date, 0) AS po_ordered_to_date,
       COALESCE(po.po_ordered_to_date, 0) / NULLIF(c.committed_po, 0) AS po_released_pct,
       COALESCE(po.po_received_value, 0) AS po_received_value, COALESCE(po.po_invoiced_value, 0) AS po_invoiced_value,
       COALESCE(po.open_order_value, 0) AS open_order_value, COALESCE(po.open_lines, 0) AS open_lines,
       COALESCE(po.overdue_open_lines, 0) AS overdue_open_lines, COALESCE(po.overdue_open_amount, 0) AS overdue_open_amount,
       COALESCE(po.long_lead_open_lines, 0) AS long_lead_open_lines, po.on_time_rate
FROM mart.dim_project dp
LEFT JOIN com c ON c.project_key = dp.project_key
LEFT JOIN po ON po.project_id = dp.project_id;

-- -----------------------------------------------------------------------------
-- M11. Cash: AP and AR aging
--   Days past due   = as-of date - due date (negative = not yet due)
--   Buckets         = Current (not yet due), 1-30, 31-60, 61-90, 90+ days past due
--   AP open item    = unpaid vendor invoice (full amount) or unpaid subcontractor pay application (gross less retainage)
--   AR open item    = submitted pay application not yet paid (gross less retainage; retainage is tracked separately)
--   Retainage receivable = retainage held on our billings to owners (active jobs); retainage payable = held back from subs, not yet released
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_ap_open_items AS
WITH u AS (
    SELECT 'Vendor invoice' AS source, a.invoice_id AS reference_id, p.project_id, dv.vendor_name, a.invoice_date, a.due_date,
           a.amount AS amount_open, a.status, (a.status = 'On Hold') AS is_held
    FROM mart.fact_ap_invoice a
    JOIN mart.dim_project p ON p.project_key = a.project_key
    JOIN mart.dim_vendor dv ON dv.vendor_key = a.vendor_key
    WHERE a.paid_date IS NULL AND a.invoice_date <= (SELECT as_of_date FROM ops.etl_params)
    UNION ALL
    SELECT 'Subcontractor pay application', s.sub_pay_app_id, p.project_id, dv.vendor_name, s.invoice_date, s.due_date,
           s.net_due - s.paid_amount, s.status, (s.status = 'Disputed')
    FROM mart.fact_sub_pay_app s
    JOIN mart.dim_project p ON p.project_key = s.project_key
    JOIN mart.dim_vendor dv ON dv.vendor_key = s.vendor_key
    WHERE s.paid_date IS NULL AND s.invoice_date <= (SELECT as_of_date FROM ops.etl_params)
)
SELECT u.*, DATE_DIFF('day', u.due_date, (SELECT as_of_date FROM ops.etl_params)) AS days_past_due,
       CASE WHEN DATE_DIFF('day', u.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 0  THEN '1 Current'
            WHEN DATE_DIFF('day', u.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 30 THEN '2 1-30'
            WHEN DATE_DIFF('day', u.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 60 THEN '3 31-60'
            WHEN DATE_DIFF('day', u.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 90 THEN '4 61-90'
            ELSE '5 90+' END AS aging_bucket
FROM u;

CREATE OR REPLACE VIEW metrics.v_ar_open_items AS
SELECT p.project_id, a.account_name, b.billing_id, b.invoice_no, b.pay_app_no, b.submitted_date, b.due_date,
       b.gross_billed - b.retainage_held AS amount_open, b.retainage_held, b.status,
       DATE_DIFF('day', b.due_date, (SELECT as_of_date FROM ops.etl_params)) AS days_past_due,
       CASE WHEN DATE_DIFF('day', b.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 0  THEN '1 Current'
            WHEN DATE_DIFF('day', b.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 30 THEN '2 1-30'
            WHEN DATE_DIFF('day', b.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 60 THEN '3 31-60'
            WHEN DATE_DIFF('day', b.due_date, (SELECT as_of_date FROM ops.etl_params)) <= 90 THEN '4 61-90'
            ELSE '5 90+' END AS aging_bucket
FROM mart.fact_billing b
JOIN mart.dim_project p ON p.project_key = b.project_key
LEFT JOIN mart.dim_account a ON a.account_key = p.account_key
WHERE b.paid_date IS NULL AND b.submitted_date <= (SELECT as_of_date FROM ops.etl_params);

CREATE OR REPLACE VIEW metrics.v_aging_summary AS
SELECT 'AP' AS ledger, aging_bucket, COUNT(*) AS items, SUM(amount_open) AS amount_open FROM metrics.v_ap_open_items GROUP BY aging_bucket
UNION ALL
SELECT 'AR', aging_bucket, COUNT(*), SUM(amount_open) FROM metrics.v_ar_open_items GROUP BY aging_bucket;

CREATE OR REPLACE VIEW metrics.v_retainage_position AS
SELECT p.project_id, p.status,
       COALESCE((SELECT SUM(b.retainage_held) FROM mart.fact_billing b WHERE b.project_key = p.project_key), 0) AS retainage_receivable_from_owner,
       COALESCE((SELECT SUM(s.retainage_held - s.retainage_released) FROM mart.fact_sub_pay_app s WHERE s.project_key = p.project_key), 0) AS retainage_payable_to_subs
FROM mart.dim_project p;

-- -----------------------------------------------------------------------------
-- M12. Equipment utilisation
--   Utilisation      = days used / 22 working days per month, averaged over unit-months on a project
--   Standby (idle) days = days on site but not working
--   Idle cost        = standby days x daily rate, shown for RENTED units (we pay rent whether or not the iron works)
--   Usage cost       = cost charged to the job (about 85% of the job's equipment cost code; fuel and misc excluded)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_equipment_by_unit AS
SELECT e.equipment_id, e.equipment_name, e.category, e.ownership, e.daily_rate,
       COUNT(*)                         AS unit_months,
       SUM(u.days_used)                 AS days_used,
       SUM(u.standby_days)              AS standby_days,
       SUM(u.days_used) * 1.0 / (22 * COUNT(*))                       AS utilization,
       SUM(u.usage_cost)                AS usage_cost,
       SUM(u.standby_days * e.daily_rate) FILTER (WHERE e.ownership = 'Rented') AS rented_idle_cost
FROM mart.fact_equipment_usage u JOIN mart.dim_equipment e ON e.equipment_key = u.equipment_key
GROUP BY e.equipment_id, e.equipment_name, e.category, e.ownership, e.daily_rate;

CREATE OR REPLACE VIEW metrics.v_equipment_by_project AS
SELECT p.project_id, COUNT(DISTINCT e.equipment_id) AS units_used, SUM(u.usage_cost) AS usage_cost,
       SUM(u.days_used) * 1.0 / (22 * COUNT(*)) AS utilization,
       SUM(u.standby_days) AS standby_days,
       COALESCE(SUM(u.standby_days * e.daily_rate) FILTER (WHERE e.ownership = 'Rented'), 0) AS rented_idle_cost,
       COALESCE(SUM(u.usage_cost) FILTER (WHERE e.ownership = 'Rented'), 0) AS rented_cost,
       COALESCE(SUM(u.usage_cost) FILTER (WHERE e.ownership = 'Owned'), 0) AS owned_cost
FROM mart.fact_equipment_usage u
JOIN mart.dim_equipment e ON e.equipment_key = u.equipment_key
JOIN mart.dim_project   p ON p.project_key = u.project_key
GROUP BY p.project_id;

-- -----------------------------------------------------------------------------
-- M13. Manufacturing inventory
--   Days of cover   = on hand / average daily usage
--   Reorder status  = 'Below reorder point' (on hand < reorder point); 'Low' (< 1.25 x reorder point); else 'OK'
--   Stock-out risk  = days of cover is less than the supplier lead time (a new order cannot arrive in time)
--   Stock value     = on hand x unit cost
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_inventory_status AS
SELECT i.item_id, i.item_name, i.uom, i.on_hand_qty, i.reorder_point, i.reorder_qty, i.unit_cost, i.avg_daily_usage, i.lead_time_days,
       dv.vendor_name AS preferred_vendor, i.last_receipt_date,
       i.on_hand_qty * i.unit_cost AS stock_value,
       ROUND(i.on_hand_qty / NULLIF(i.avg_daily_usage, 0), 1) AS days_of_cover,
       CASE WHEN i.on_hand_qty < i.reorder_point THEN 'Below reorder point'
            WHEN i.on_hand_qty < i.reorder_point * 1.25 THEN 'Low' ELSE 'OK' END AS reorder_status,
       (i.on_hand_qty / NULLIF(i.avg_daily_usage, 0) < i.lead_time_days) AS stockout_risk,
       GREATEST(i.reorder_point - i.on_hand_qty, 0) AS shortfall_to_reorder_point,
       CASE WHEN i.on_hand_qty < i.reorder_point THEN i.reorder_qty * i.unit_cost END AS suggested_order_value
FROM mart.fact_inventory i
LEFT JOIN mart.dim_vendor dv ON dv.vendor_key = i.preferred_vendor_key;

-- -----------------------------------------------------------------------------
-- M14. RFIs and submittals
--   Open RFI        = no response yet.  Overdue RFI = open and past its response-due date (14 days after submission).
--   Days open       = as-of - submitted date (open RFIs).   Response time = response - submitted (answered RFIs).
--   Pending submittal = not yet returned.  Late submittal = pending and past its required-by date.
--   Resubmittals    = submittals that needed more than one review cycle.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_rfi_by_project AS
SELECT p.project_id,
       COUNT(*)                                                                    AS rfis_total,
       COUNT(*) FILTER (WHERE r.status = 'Open')                                   AS rfis_open,
       COUNT(*) FILTER (WHERE r.status = 'Open' AND r.due_date < (SELECT as_of_date FROM ops.etl_params)) AS rfis_overdue,
       ROUND(AVG(DATE_DIFF('day', r.submitted_date, (SELECT as_of_date FROM ops.etl_params))) FILTER (WHERE r.status = 'Open'), 0) AS avg_days_open,
       ROUND(AVG(DATE_DIFF('day', r.submitted_date, r.response_date)) FILTER (WHERE r.status = 'Closed'), 1) AS avg_response_days,
       COUNT(*) FILTER (WHERE r.status = 'Open' AND r.has_cost_impact)             AS open_with_cost_impact,
       COALESCE(SUM(r.schedule_impact_days) FILTER (WHERE r.status = 'Open'), 0)   AS open_schedule_impact_days
FROM mart.fact_rfi r JOIN mart.dim_project p ON p.project_key = r.project_key
GROUP BY p.project_id;

CREATE OR REPLACE VIEW metrics.v_rfi_open_detail AS
SELECT p.project_id, r.rfi_id, r.rfi_number, r.subject, r.discipline, r.ball_in_court, r.submitted_date, r.due_date,
       DATE_DIFF('day', r.due_date, (SELECT as_of_date FROM ops.etl_params)) AS days_past_due, r.has_cost_impact, r.schedule_impact_days
FROM mart.fact_rfi r JOIN mart.dim_project p ON p.project_key = r.project_key
WHERE r.status = 'Open';

CREATE OR REPLACE VIEW metrics.v_submittal_by_project AS
SELECT p.project_id,
       COUNT(*)                                                                    AS submittals_total,
       COUNT(*) FILTER (WHERE s.status = 'Pending')                                AS submittals_pending,
       COUNT(*) FILTER (WHERE s.status = 'Pending' AND s.required_by_date < (SELECT as_of_date FROM ops.etl_params)) AS submittals_late,
       COUNT(*) FILTER (WHERE s.cycle_count > 1)                                   AS resubmittals,
       ROUND(AVG(DATE_DIFF('day', s.submitted_date, s.returned_date)) FILTER (WHERE s.returned_date IS NOT NULL), 1) AS avg_review_days
FROM mart.fact_submittal s JOIN mart.dim_project p ON p.project_key = s.project_key
GROUP BY p.project_id;

-- -----------------------------------------------------------------------------
-- M15. Schedule
--   Milestone slip (days) = forecast (or actual) date - planned date
--   Schedule status       = 'Late' if the final milestone is forecast more than 30 days late, 'At risk' if more than 7, else 'On track'
--   Planned % complete    = baseline S-curve share of budget planned to be spent by the as-of month (see M8)
--   Schedule variance (pts) = (cost-to-cost percent complete - planned percent complete) x 100;  negative = behind plan
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_schedule_by_project AS
WITH m AS (
    SELECT p.project_id, f.milestone_name, f.planned_date, f.forecast_date, f.actual_date, f.status,
           ROW_NUMBER() OVER (PARTITION BY p.project_id ORDER BY f.planned_date DESC) AS rn_last,
           ROW_NUMBER() OVER (PARTITION BY p.project_id ORDER BY CASE WHEN f.actual_date IS NULL THEN f.planned_date END NULLS LAST) AS rn_next
    FROM mart.fact_milestone f JOIN mart.dim_project p ON p.project_key = f.project_key
),
agg AS (
    SELECT project_id, COUNT(*) AS milestones_total, COUNT(*) FILTER (WHERE actual_date IS NOT NULL) AS milestones_complete,
           MAX(DATE_DIFF('day', planned_date, forecast_date)) AS worst_slip_days
    FROM m GROUP BY project_id
),
plan AS (
    SELECT project_id, MAX(budget_cum) / NULLIF(MAX(eac), 0) AS planned_pct_raw, MAX(month_end) AS m_end
    FROM metrics.v_project_cost_curve
    WHERE month_end = (SELECT MAX(month_end) FROM metrics.v_project_cost_curve c2 WHERE c2.project_id = metrics.v_project_cost_curve.project_id
                                                              AND c2.month_end <= (SELECT as_of_date FROM ops.etl_params))
    GROUP BY project_id
)
SELECT a.project_id, a.milestones_total, a.milestones_complete,
       fin.milestone_name AS final_milestone, fin.planned_date AS final_planned_date, fin.forecast_date AS final_forecast_date,
       DATE_DIFF('day', fin.planned_date, fin.forecast_date) AS final_slip_days,
       a.worst_slip_days,
       nxt.milestone_name AS next_milestone, nxt.planned_date AS next_planned_date, nxt.forecast_date AS next_forecast_date,
       CASE WHEN DATE_DIFF('day', fin.planned_date, fin.forecast_date) > 30 THEN 'Late'
            WHEN DATE_DIFF('day', fin.planned_date, fin.forecast_date) > 7  THEN 'At risk' ELSE 'On track' END AS schedule_status
FROM agg a
JOIN m fin ON fin.project_id = a.project_id AND fin.rn_last = 1
LEFT JOIN m nxt ON nxt.project_id = a.project_id AND nxt.rn_next = 1 AND nxt.actual_date IS NULL;

CREATE OR REPLACE VIEW metrics.v_project_schedule_variance AS
WITH run_params AS (SELECT as_of_date FROM ops.etl_params),
plan AS (
    SELECT c.project_id, c.budget_cum / NULLIF(cp.revised_budget_cost, 0) AS planned_pct
    FROM metrics.v_project_cost_curve c
    JOIN metrics.v_project_cost_progress cp ON cp.project_id = c.project_id
    WHERE c.month_end = (SELECT MAX(c2.month_end) FROM metrics.v_project_cost_curve c2
                         WHERE c2.project_id = c.project_id AND c2.month_end <= (SELECT as_of_date FROM run_params))
)
SELECT cp.project_id, cp.status, pl.planned_pct AS planned_pct_complete, cp.pct_complete,
       ROUND((cp.pct_complete - LEAST(pl.planned_pct, 1)) * 100, 1) AS schedule_variance_pts
FROM metrics.v_project_cost_progress cp
LEFT JOIN plan pl ON pl.project_id = cp.project_id;

CREATE OR REPLACE VIEW metrics.v_milestone_detail AS
SELECT p.project_id, f.milestone_id, f.milestone_name, f.planned_date, f.forecast_date, f.actual_date, f.status,
       DATE_DIFF('day', f.planned_date, f.forecast_date) AS slip_days
FROM mart.fact_milestone f JOIN mart.dim_project p ON p.project_key = f.project_key;

-- -----------------------------------------------------------------------------
-- One row per project: the dashboard's project table. Only JOINs earlier views.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_project_summary AS
WITH ap AS (
    SELECT project_id, SUM(amount_open) AS ap_open, SUM(amount_open) FILTER (WHERE days_past_due > 0) AS ap_overdue,
           SUM(amount_open) FILTER (WHERE is_held) AS ap_held
    FROM metrics.v_ap_open_items GROUP BY project_id
),
ar AS (
    SELECT project_id, SUM(amount_open) AS ar_open, SUM(amount_open) FILTER (WHERE days_past_due > 0) AS ar_overdue,
           SUM(amount_open) FILTER (WHERE days_past_due > 90) AS ar_over_90
    FROM metrics.v_ar_open_items GROUP BY project_id
)
SELECT m.project_id, m.project_name, m.business_unit, m.status,
       a.account_name, pm.full_name AS project_manager, dp.start_date, dp.planned_end_date,
       m.original_contract_value, m.approved_co_revenue, m.revised_contract_value,
       cp.original_budget_cost, cp.revised_budget_cost,
       cp.actual_cost_to_date, cp.cost_to_complete, cp.estimated_cost_at_completion, cp.pct_complete,
       m.bid_margin_pct, m.projected_profit, m.projected_margin_pct,
       m.margin_fade_pts, m.margin_fade_dollars, m.share_of_fade, m.fade_rank,
       w.earned_revenue, w.billed_to_date, w.retainage_held, w.over_under_billing, w.over_under_pct_of_contract, w.billing_position,
       e.pending_co_count, e.pending_co_revenue, e.pending_co_cost_at_risk, e.oldest_pending_age_days,
       e.pending_pct_of_contract, e.approved_co_count, e.rejected_co_count, e.avg_approval_cycle_days,
       CASE WHEN m.status = 'Active' THEN GREATEST(w.revised_contract_value - w.earned_revenue, 0) ELSE 0 END AS backlog_remaining,
       s.incidents_all, s.recordables_all, s.trir_12m, s.peak_incidents_in_window, s.peak_window_start, s.is_cluster AS safety_cluster,
       -- procurement and subcontracts
       pr.committed_total, pr.committed_po, pr.po_ordered_to_date, pr.open_order_value, pr.open_lines AS po_open_lines,
       pr.overdue_open_lines AS po_overdue_lines, pr.overdue_open_amount AS po_overdue_amount, pr.long_lead_open_lines, pr.on_time_rate AS delivery_on_time_rate,
       -- cash
       COALESCE(ap.ap_open, 0) AS ap_open, COALESCE(ap.ap_overdue, 0) AS ap_overdue, COALESCE(ap.ap_held, 0) AS ap_held,
       COALESCE(ar.ar_open, 0) AS ar_open, COALESCE(ar.ar_overdue, 0) AS ar_overdue, COALESCE(ar.ar_over_90, 0) AS ar_over_90,
       rt.retainage_receivable_from_owner, rt.retainage_payable_to_subs,
       -- field
       COALESCE(rf.rfis_open, 0) AS rfis_open, COALESCE(rf.rfis_overdue, 0) AS rfis_overdue, rf.avg_response_days AS rfi_avg_response_days,
       COALESCE(sb.submittals_pending, 0) AS submittals_pending, COALESCE(sb.submittals_late, 0) AS submittals_late, COALESCE(sb.resubmittals, 0) AS resubmittals,
       sc.final_slip_days, sc.schedule_status, sc.next_milestone, sc.next_forecast_date,
       sv.planned_pct_complete, sv.schedule_variance_pts,
       COALESCE(eq.usage_cost, 0) AS equipment_cost, eq.utilization AS equipment_utilization, COALESCE(eq.rented_idle_cost, 0) AS equipment_idle_cost
FROM metrics.v_project_margin m
JOIN mart.dim_project dp ON dp.project_id = m.project_id
LEFT JOIN mart.dim_account a   ON a.account_key = dp.account_key
LEFT JOIN mart.dim_employee pm ON pm.employee_key = dp.pm_employee_key
JOIN metrics.v_project_cost_progress cp ON cp.project_id = m.project_id
JOIN metrics.v_project_wip w            ON w.project_id  = m.project_id
JOIN metrics.v_change_order_exposure e  ON e.project_id  = m.project_id
JOIN metrics.v_safety_by_project s      ON s.project_id  = m.project_id
JOIN metrics.v_project_procurement pr   ON pr.project_id = m.project_id
JOIN metrics.v_retainage_position rt    ON rt.project_id = m.project_id
LEFT JOIN ap ON ap.project_id = m.project_id
LEFT JOIN ar ON ar.project_id = m.project_id
LEFT JOIN metrics.v_rfi_by_project rf          ON rf.project_id = m.project_id
LEFT JOIN metrics.v_submittal_by_project sb    ON sb.project_id = m.project_id
LEFT JOIN metrics.v_schedule_by_project sc     ON sc.project_id = m.project_id
LEFT JOIN metrics.v_project_schedule_variance sv ON sv.project_id = m.project_id
LEFT JOIN metrics.v_equipment_by_project eq    ON eq.project_id = m.project_id;

-- -----------------------------------------------------------------------------
-- Portfolio KPIs (single row) for the executive cards.
--   Portfolio projected margin = sum(projected profit) / sum(revised contract value), active jobs
--   Pipeline coverage          = weighted pipeline / total backlog
--   On-time delivery           = share of fully received PO lines delivered on or before the promised date
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_portfolio_kpis AS
WITH act AS (
    SELECT SUM(revised_contract_value) AS active_contract_value, SUM(projected_profit) AS projected_profit,
           SUM(original_contract_value * bid_margin_pct) AS bid_profit_on_original,
           SUM(original_contract_value) AS original_contract_total,
           SUM(pending_co_revenue) AS pending_co_revenue, SUM(pending_co_cost_at_risk) AS pending_co_cost_at_risk,
           SUM(pending_co_count) AS pending_co_count,
           SUM(CASE WHEN margin_fade_pts > 0 THEN 1 ELSE 0 END) AS jobs_with_fade,
           SUM(over_under_billing) FILTER (WHERE over_under_billing > 0) AS gross_overbilling,
           SUM(over_under_billing) FILTER (WHERE over_under_billing < 0) AS gross_underbilling,
           SUM(over_under_billing) AS net_over_under_billing,
           COUNT(*) AS active_jobs,
           COUNT(*) FILTER (WHERE schedule_status = 'Late') AS jobs_late,
           COUNT(*) FILTER (WHERE schedule_status = 'At risk') AS jobs_at_risk,
           SUM(rfis_overdue) AS rfis_overdue, SUM(submittals_late) AS submittals_late,
           SUM(retainage_receivable_from_owner) AS retainage_receivable, SUM(retainage_payable_to_subs) AS retainage_payable
    FROM metrics.v_project_summary WHERE status = 'Active'
),
bl AS (
    SELECT SUM(backlog_amount) AS total_backlog,
           SUM(backlog_amount) FILTER (WHERE backlog_source = 'Active project')        AS backlog_active,
           SUM(backlog_amount) FILTER (WHERE backlog_source = 'Awarded, not started')  AS backlog_awarded
    FROM metrics.v_backlog
),
pl AS (
    SELECT SUM(weighted_pipeline) AS weighted_pipeline, SUM(open_amount) AS open_pipeline, SUM(open_count) AS open_opportunities,
           SUM(won_count) AS won_count, SUM(lost_count) AS lost_count,
           SUM(won_count) * 1.0 / NULLIF(SUM(won_count) + SUM(lost_count), 0) AS win_rate
    FROM metrics.v_pipeline_by_bu
),
sf AS (
    SELECT SUM(recordables_all) * 200000.0 / NULLIF(SUM(hours_all), 0) AS trir_all,
           SUM(recordables_12m) * 200000.0 / NULLIF(SUM(hours_12m), 0) AS trir_12m,
           SUM(incidents_all) AS incidents_all, SUM(recordables_all) AS recordables_all
    FROM metrics.v_safety_by_project
),
fd AS (
    SELECT SUM(share_of_fade) FILTER (WHERE fade_rank <= 3) AS top3_share_of_fade
    FROM metrics.v_project_margin WHERE status = 'Active'
),
pr AS (
    SELECT SUM(ordered_amount) FILTER (WHERE is_open) AS open_po_value, COUNT(*) FILTER (WHERE is_open) AS open_po_lines,
           COUNT(*) FILTER (WHERE is_overdue_open) AS overdue_po_lines,
           COALESCE(SUM(ordered_amount) FILTER (WHERE is_overdue_open), 0) AS overdue_po_amount,
           COUNT(*) FILTER (WHERE status = 'Received' AND days_late_delivered <= 0) * 1.0 / NULLIF(COUNT(*) FILTER (WHERE status = 'Received'), 0) AS on_time_delivery_rate,
           COUNT(*) FILTER (WHERE is_long_lead AND is_overdue_open) AS long_lead_overdue
    FROM metrics.v_po_line_status
),
tw AS (
    SELECT COUNT(*) FILTER (WHERE exception_type = 'Received, not invoiced') AS received_not_invoiced_count,
           COALESCE(SUM(exception_amount) FILTER (WHERE exception_type = 'Received, not invoiced'), 0) AS received_not_invoiced_amount,
           COUNT(*) FILTER (WHERE exception_type = 'Invoiced, not received') AS invoiced_not_received_count,
           COALESCE(SUM(exception_amount) FILTER (WHERE exception_type = 'Invoiced, not received'), 0) AS invoiced_not_received_amount,
           COUNT(*) FILTER (WHERE exception_type LIKE 'Invoice above%') AS price_exception_count
    FROM metrics.v_three_way_match_exceptions
),
apx AS (
    SELECT SUM(amount_open) AS ap_open, COALESCE(SUM(amount_open) FILTER (WHERE days_past_due > 0), 0) AS ap_overdue,
           COALESCE(SUM(amount_open) FILTER (WHERE days_past_due > 90), 0) AS ap_over_90,
           COALESCE(SUM(amount_open) FILTER (WHERE is_held), 0) AS ap_held
    FROM metrics.v_ap_open_items
),
arx AS (
    SELECT SUM(amount_open) AS ar_open, COALESCE(SUM(amount_open) FILTER (WHERE days_past_due > 0), 0) AS ar_overdue,
           COALESCE(SUM(amount_open) FILTER (WHERE days_past_due > 90), 0) AS ar_over_90
    FROM metrics.v_ar_open_items
),
inv AS (
    SELECT COUNT(*) FILTER (WHERE reorder_status = 'Below reorder point') AS items_below_reorder,
           COUNT(*) FILTER (WHERE stockout_risk) AS items_stockout_risk, SUM(stock_value) AS inventory_value
    FROM metrics.v_inventory_status
),
eqx AS (
    SELECT SUM(days_used) * 1.0 / (22 * SUM(unit_months)) AS equipment_utilization, COALESCE(SUM(rented_idle_cost), 0) AS rented_idle_cost
    FROM metrics.v_equipment_by_unit
)
SELECT (SELECT as_of_date FROM ops.etl_params) AS as_of_date,
       act.active_jobs, act.active_contract_value,
       act.projected_profit / act.active_contract_value AS portfolio_projected_margin,
       act.bid_profit_on_original / act.original_contract_total AS portfolio_bid_margin,
       act.pending_co_revenue, act.pending_co_cost_at_risk, act.pending_co_count,
       act.jobs_with_fade, fd.top3_share_of_fade,
       act.gross_overbilling, act.gross_underbilling, act.net_over_under_billing,
       bl.total_backlog, bl.backlog_active, bl.backlog_awarded,
       pl.weighted_pipeline, pl.open_pipeline, pl.open_opportunities, pl.won_count, pl.lost_count, pl.win_rate,
       pl.weighted_pipeline / NULLIF(bl.total_backlog, 0) AS pipeline_coverage,
       sf.trir_all, sf.trir_12m, sf.incidents_all, sf.recordables_all,
       pr.open_po_value, pr.open_po_lines, pr.overdue_po_lines, pr.overdue_po_amount, pr.on_time_delivery_rate, pr.long_lead_overdue,
       tw.received_not_invoiced_count, tw.received_not_invoiced_amount, tw.invoiced_not_received_count, tw.invoiced_not_received_amount,
       tw.price_exception_count,
       apx.ap_open, apx.ap_overdue, apx.ap_over_90, apx.ap_held,
       arx.ar_open, arx.ar_overdue, arx.ar_over_90,
       act.retainage_receivable, act.retainage_payable,
       act.jobs_late, act.jobs_at_risk, act.rfis_overdue, act.submittals_late,
       inv.items_below_reorder, inv.items_stockout_risk, inv.inventory_value,
       eqx.equipment_utilization, eqx.rented_idle_cost
FROM act, bl, pl, sf, fd, pr, tw, apx, arx, inv, eqx;

-- -----------------------------------------------------------------------------
-- Equipment by unit x project (lets the dashboard re-aggregate for any role's project scope)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.v_equipment_usage_detail AS
SELECT p.project_id, e.equipment_id, e.equipment_name, e.category, e.ownership, e.daily_rate,
       COUNT(*) AS unit_months, SUM(u.days_used) AS days_used, SUM(u.standby_days) AS standby_days, SUM(u.usage_cost) AS usage_cost,
       CASE WHEN e.ownership = 'Rented' THEN SUM(u.standby_days) * e.daily_rate ELSE 0 END AS rented_idle_cost
FROM mart.fact_equipment_usage u
JOIN mart.dim_equipment e ON e.equipment_key = u.equipment_key
JOIN mart.dim_project   p ON p.project_key = u.project_key
GROUP BY p.project_id, e.equipment_id, e.equipment_name, e.category, e.ownership, e.daily_rate;
