# Limitations and honest caveats

> **Synthetic data.** Gulf Coast Builders is fictional. This list is part of the deliverable: knowing what a model does not do is as important as what it does.

## About the data

- **It is synthetic and stylised.** Real data is messier in ways nobody planned for; here the defects are the ones the generator plants (about 590 rows across the tables), so "every defect was caught" proves the checks match the planted list, not that they would catch every real-world problem.
- **The stories are written in.** Margin fade on three jobs, slow owners, a late supplier and so on were put there on purpose. The value of the exercise is that the pipeline finds them, ranks them first, and reconciles to the cent, not that the findings are discoveries.
- **One snapshot.** Everything is as of 30 Sep 2026. There is no week-over-week history, so the alert report cannot say what changed since last week, and inventory is a single stock count.
- **Small volume** (about 14,000 timecards and 1,500 cost postings). Nothing here has been load-tested.

## About the metrics

- **Percent complete is cost-to-cost and trusts the project manager's estimate to complete.** An optimistic estimate overstates percent complete and earned revenue.
- **The plan curve is an assumed S-curve.** The ERP export has no baseline schedule, so "plan" is the revised budget spread over the planned duration. It is labelled as an assumption on the page.
- **Schedule variance is a spend-based proxy,** not a critical-path schedule. Milestone slip comes from forecast dates in the export.
- **The billing curve restates earlier months at the current cost forecast,** so it shows direction, not the WIP report as it stood each month.
- **Stage probabilities are generic** CRM defaults, not calibrated to history, so weighted pipeline is indicative.
- **TRIR on small hour bases is volatile;** counts are shown next to rates.
- **Equipment utilization assumes 22 working days a month** and counts rented standby cost only.
- **AP aging excludes items dated after the as-of date** (for example, pay applications received just after month-end). AR is shown net of retainage, with retainage tracked separately.
- **Three-way match is simplified:** one invoice per receipt, a 30-day uninvoiced threshold and a 5% price tolerance.
- **No** revenue-recognition adjustments beyond over/under billing, no joint ventures, multiple entities, currencies, taxes, payroll accuracy or certified-payroll reporting, and no cash-flow forecast.

## About access control

- **The role selector is a demonstration, not security.** All data for every role is inside `docs/index.html`; anyone can read it with browser developer tools or by opening the file in an editor. Real enforcement belongs in the database or semantic model (`access_matrix.md` shows how for Power BI and Snowflake).
- The tests prove the page *removes* restricted rows, pages and fields for each role, not that a determined user cannot find them.

## About the platform

- **DuckDB is a single-file, single-writer database.** It suits this project; a shared warehouse would use Snowflake or similar. The Snowflake equivalents are marked in comments but **were not executed**.
- **The GitHub Actions workflow has not been run on GitHub** by the author of this repository (it was authored and the equivalent steps were run locally). Expect to adjust versions the first time.
- **Tested on two library sets** (Python 3.13 with DuckDB 1.5 / pandas 3.0, and DuckDB 1.1.3 / pandas 2.2.3 in a clean checkout, see `verification_report.md`), both on Linux. Windows, macOS and other Python versions are untested.
- **The dashboard embeds all of its data (about 0.7 MB of JSON).** That is fine here; a production dashboard would query live views.
- **Accessibility** was checked with an automated rules engine and by keyboard and screen-size review, not with a full assistive-technology audit.
