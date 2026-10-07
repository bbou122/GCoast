# Access matrix: who sees what

> **Synthetic data.** Gulf Coast Builders is fictional. This document describes the access design for the project and how it would be enforced in a real BI stack.
>
> **Important:** the "View as" selector on `docs/index.html` is a **front-end demonstration only. It is not security.** The dashboard is one static file; the data for every role is physically inside the page, and anyone who opens the file can read it in the browser tools. Real enforcement happens in the database or semantic model (sections 4 and 5), never in a button.

## 1. Roles

| Role | Who | Scope of rows | Scope of pages |
|---|---|---|---|
| **Executive** | Leadership team | All projects, all business units | All seven pages |
| **Finance** | Controller, AP/AR, cost accounting | All projects, all business units | All pages **except safety**: no incident list, cause breakdown or injury rates |
| **Business Unit Lead** | One lead per business unit (Building, Heavy Civil, Manufacturing) | Only projects, pipeline and backlog in their own unit | All pages, filtered to their unit |
| **Project Manager** | One manager per project group | Only projects they manage (vendors, POs, invoices, RFIs and equipment follow the project) | All pages **except pipeline** (company-wide sales data) |

## 2. Data classification (tables)

| Classification | Meaning | Tables and views |
|---|---|---|
| **Public** (to everyone signed in) | Reference data with no commercial sensitivity | `dim_date`, `dim_cost_code`, `dim_project` (names, status, dates), metric definitions |
| **Internal** | Needed to run jobs; scoped by project | Costs, budgets, change orders, billings, purchase orders, receipts, vendor invoices, subcontract pay applications, equipment usage, RFIs, submittals, milestones, inventory |
| **Confidential** | Commercially or personally sensitive | CRM pipeline and bids (win probability, bid margin), vendor payment terms, **safety incident records**, employee identity |
| **Excluded from the warehouse entirely** | Never loaded, so it cannot leak | Employee pay rate and email (`hourly_rate`, `email` are dropped in staging; check `MRT-006` fails the build if they ever appear in a mart) |

## 3. Role by data matrix

`Y` = sees all rows, `Own` = only rows for their projects or business unit, `-` = no access.

| Data / page | Executive | Finance | BU Lead | Project Manager |
|---|---|---|---|---|
| Executive portfolio: margin, fade, backlog | Y | Y | Own unit | Own projects |
| Project drill-down (cost, billing, change orders, schedule) | Y | Y | Own unit | Own projects |
| Procurement: POs, deliveries, vendor scorecard, three-way match | Y | Y | Own unit | Own projects |
| Plant inventory | Y | Y | Manufacturing lead only | Manufacturing projects only |
| Subcontracts, AP and AR aging, retainage | Y | Y | Own unit | Own projects |
| Field operations: equipment, RFIs, submittals, schedule | Y | Y | Own unit | Own projects |
| **Safety** incidents, causes, TRIR | Y | **-** | Own unit | Own projects |
| Pipeline and bids | Y | Y | Own unit | **-** |
| Data quality results and metric definitions | Y | Y | Y | Y |

## 4. How the demo works (and why it is not security)

When a role is chosen, the page removes the rows and pages that role may not see **before it draws anything**, and every chart, table and total is computed from the reduced data. Hidden pages disappear from the navigation. This shows the *design intent* and is what a reviewer would click through. It is honest to say, in an interview, that a real deployment replaces this with the controls below.

## 5. How it would be enforced for real

### Power BI: row-level security (RLS) and object-level security

Create roles in the semantic model, each with a DAX filter, and assign users or Entra ID groups to them in the service.

```dax
-- Role: Project Manager.  Table: dim_project
[pm_email] = USERPRINCIPALNAME()

-- Role: Business Unit Lead.  Table: dim_project
[business_unit] =
    LOOKUPVALUE ( dim_employee[business_unit], dim_employee[email], USERPRINCIPALNAME () )

-- Role: Executive / Finance: no filter on dim_project
```

Filters on `dim_project` flow through relationships to every fact table (cost, billing, purchase orders, RFIs and so on) because they all carry `project_key`. For the pipeline fact, filter `business_unit` the same way, and give the Project Manager role an always-false filter (`FALSE()`) on `fact_pipeline`. To hide the safety tables from Finance use **object-level security** (set the table's permission to *None* for that role in Tabular Editor). Test with *View as role* before publishing; remember that workspace Admins, Members and Contributors bypass RLS, so report consumers should be Viewers.

### Snowflake: roles, grants, secure views, policies

```sql
-- 1. One role per persona; users inherit through grants
CREATE ROLE gcb_executive;  CREATE ROLE gcb_finance;
CREATE ROLE gcb_bu_lead;    CREATE ROLE gcb_project_manager;

-- 2. Table-level grants: BI roles read only the metrics schema, never raw or staging
GRANT USAGE ON SCHEMA gcb.metrics TO ROLE gcb_executive;   -- repeat per role
GRANT SELECT ON ALL VIEWS IN SCHEMA gcb.metrics TO ROLE gcb_executive;
GRANT SELECT ON ALL VIEWS IN SCHEMA gcb.metrics TO ROLE gcb_finance;
REVOKE SELECT ON VIEW gcb.metrics.v_safety_detail FROM ROLE gcb_finance;       -- Finance: no safety detail

-- 3. Row access policy: project managers see their projects, BU leads their unit
CREATE ROW ACCESS POLICY gcb.governance.project_scope AS (project_id STRING, business_unit STRING) RETURNS BOOLEAN ->
    CURRENT_ROLE() IN ('GCB_EXECUTIVE', 'GCB_FINANCE')
    OR (CURRENT_ROLE() = 'GCB_BU_LEAD' AND business_unit IN
         (SELECT business_unit FROM gcb.governance.user_scope WHERE user_name = CURRENT_USER()))
    OR (CURRENT_ROLE() = 'GCB_PROJECT_MANAGER' AND project_id IN
         (SELECT project_id FROM gcb.governance.user_scope WHERE user_name = CURRENT_USER()));
ALTER TABLE gcb.mart.dim_project ADD ROW ACCESS POLICY gcb.governance.project_scope ON (project_id, business_unit);

-- 4. Masking policy for a sensitive column (example: vendor payment terms)
CREATE MASKING POLICY gcb.governance.hide_terms AS (v NUMBER) RETURNS NUMBER ->
    CASE WHEN CURRENT_ROLE() IN ('GCB_EXECUTIVE', 'GCB_FINANCE') THEN v ELSE NULL END;

-- 5. Secure views stop consumers from inferring hidden rows through the query plan
CREATE SECURE VIEW gcb.metrics.v_project_summary_secure AS SELECT * FROM gcb.metrics.v_project_summary;
```

The key difference from the demo: in Snowflake and Power BI the **server** applies the filter using the signed-in identity, so restricted rows never leave the platform.

## 6. Checks that back this up

- `MRT-006` fails the build if a pay-rate or email column appears in any mart table.
- `tests/test_dashboard.py` opens the dashboard in a headless browser as each role and confirms that restricted pages and rows are removed from what is rendered.
- Row counts per role are listed in `docs/verification_report.md`.
