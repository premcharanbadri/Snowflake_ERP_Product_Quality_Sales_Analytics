# Snowflake Project: ERP Supplier & Product Quality Analysis

---

### [Executive Report](https://drive.google.com/file/d/1D4iKgPak5PjN5o1552m2s3fMV2Z20Rl0/view?usp=sharing)

---

## Background and Overview

Procurement and merchandising teams in a distribution business carry a recurring problem: supplier quality data is collected, but it lives in a form nobody can act on. Records mix structured attributes — unit price, quality score, supplier, sourcing country and region, product category, assessor — with unstructured assessment notes written in free text. The structured half gets averaged into a monthly report; the free-text half is never read at scale at all.

Three questions go unanswered as a result: whether the premium price tier actually delivers the quality it charges for, which suppliers consistently perform well once volume is accounted for, and which specific SKUs a category manager should be pushing this quarter without waiting on an analyst to build the list.

This project builds an end-to-end analytics platform in Snowflake against a product quality dataset. The goal was not only to answer those questions once, but to build the pipeline that keeps answering them as new files land — and to expose the results to non-technical business users through natural-language search and a self-serve dashboard.

The build covers five areas:

* **Medallion Architecture:** A three-schema design (`BRONZE` / `SILVER` / `GOLD`) inside `DB_TEAM_ROCKSTARS`, separating raw immutable records from conformed dimensional data and from aggregated, business-ready tables.

* **Automated Ingestion Pipeline:** Snowpipe auto-ingest into Bronze, a Snowflake Stream to track new inserts, and stored procedures to propagate changes into Silver and Gold.

* **AI and Semantic Services:** Snowflake Cortex AI SQL functions to enrich raw assessment text, Cortex Search for semantic retrieval over those notes, and Cortex Analyst for natural-language querying of the Silver layer.

* **Data Quality and Governance:** An automated checks procedure writing results to a monitoring table, plus column-level masking on assessor PII and documented business definitions in the semantic layer.

* **Consumption Layer:** A Streamlit app served from within Snowflake, giving procurement and category managers filtered access to the Gold tables without writing SQL.

The three business questions the Gold layer was designed to answer:

1. How do different price tiers perform in terms of quality and volume? Is the premium tier over- or under-represented?
2. Which suppliers consistently deliver the highest-quality products, and at what price points?
3. Can we produce a ready-to-use "top products" table by sourcing country / category / price band for procurement and marketing?

---

## Data Structure Overview

Database objects retain the naming from the source dataset. The business mapping used throughout this README:

| Object / Column | Business meaning |
|---|---|
| `FACT_WINE_REVIEW` | Product quality assessment fact |
| `DIM_WINE` (`variety`, `winery`, `designation`) | Product dimension (category, supplier, product line) |
| `DIM_COUNTRY`, `DIM_REGION` | Sourcing country and sourcing region |
| `DIM_TASTER` | Assessor dimension |
| `price` | Unit price |
| `points` | Quality score |
| `description` | Free-text assessment notes |

The Silver layer is modeled as a **star schema** — one fact table surrounded by four conformed dimensions, each keyed by a surrogate key generated with Snowflake's `AUTOINCREMENT`.

| Table | Type | Key Columns |
|---|---|---|
| `FACT_WINE_REVIEW` | Fact | `review_key` (PK, AUTO), `wine_key` (FK), `taster_key` (FK), `region_key` (FK), `country_key` (FK), `price`, `points`, `description`, `review_title` |
| `DIM_WINE` | Dimension | `wine_key` (PK), `variety`, `winery`, `designation` |
| `DIM_REGION` | Dimension | `region_key` (PK), `province`, `region_1`, `region_2` |
| `DIM_COUNTRY` | Dimension | `country_key` (PK), `country_name` |
| `DIM_TASTER` | Dimension | `taster_key` (PK), `taster_name`, `taster_twitter_handle` |

**Layer responsibilities:**

- **BRONZE** — `WINEMAG_BRONZE_RAW` holds every row loaded from `CSV_STAGE` exactly as received. Nothing is deleted or corrected here; the layer is treated as the replayable source of truth. Two AI-derived columns (`description_summary`, `description_sentiment`) are appended to this table as enrichment rather than transformation.
- **SILVER** — Data is cleansed, de-duplicated, and dimensionalized on the way in. Dimensions are populated first (e.g. `INSERT INTO DIM_COUNTRY (country_name) SELECT DISTINCT country FROM ... WHERE country IS NOT NULL`), then the fact table is populated by joining Bronze back against the newly built dimensions to resolve foreign keys. This ordering is what guarantees referential integrity — the fact table can only reference keys that already exist.
- **GOLD** — Three business-ready aggregate tables (`TOP_BAND_METRICS`, `WINERY_METRICS`, `TOP_WINES`), each mapped to one of the three business questions above.

**Price banding logic** (applied consistently across all Gold tables via a `CASE` statement on `price`):

| Band | Range |
|---|---|
| Unknown | price IS NULL |
| Budget | < $15 |
| Mid | $15 – $30 |
| Premium | $30 – $75 |
| Luxury | > $75 |

---

## Executive Summary

The project delivers a fully automated, three-layer Snowflake pipeline that takes a raw 130K-row file from stage to dashboard without manual intervention at the ingestion step. New files dropped into the stage are picked up by a Snowpipe with `AUTO_INGEST = TRUE` and copied into `WINEMAG_BRONZE_RAW`; a Snowflake Stream (`WINEMAG_BRONZE_STREAM`) captures those inserts, and two stored procedures (`SP_LOAD_SILVER_TABLES`, `SP_LOAD_GOLD_TABLES`) consume the stream to refresh the dimensional model and recalculate the Gold aggregates.

On top of that pipeline, three Gold tables answer the procurement questions directly:

- **`TOP_BAND_METRICS`** aggregates record volume, average quality score, average unit price, and min/max score by price band and sourcing country — making it possible to see at a glance whether a sourcing market's premium tier is over- or under-represented relative to the quality it returns.
- **`WINERY_METRICS`** aggregates by supplier, country, and province, then applies `RANK() OVER (PARTITION BY country ORDER BY avg_points DESC, review_count DESC)` to produce a within-country supplier leaderboard rather than a global one — so a strong supplier in a smaller sourcing market is not buried beneath the sheer volume of the largest ones.
- **`TOP_WINES`** uses `ROW_NUMBER() OVER (PARTITION BY country, variety, price_band ORDER BY points DESC, price ASC)` filtered to `points >= 90` and `rank_within_bucket <= 10`, producing a procurement-ready top-10 list for every country / category / price-band combination.

**Data quality is monitored rather than assumed.** A checks procedure (`MONITORING.SP_RUN_DQ_CHECKS`) writes pass/fail results with measured values and thresholds to `MONITORING.DQ_RESULTS`, covering Bronze-to-Silver row reconciliation, null rate on price, uniqueness of the review key, orphan foreign keys against the wine dimension, quality scores outside the valid 80–100 range, and Bronze freshness against a 24-hour threshold. Assessor identity columns in `DIM_TASTER` are protected by a Snowflake masking policy, so PII is restricted for any role other than the owning role.

Three Snowflake-native services extend this beyond SQL access. **AI SQL** (`SNOWFLAKE.CORTEX.SENTIMENT()`, `SNOWFLAKE.CORTEX.SUMMARIZE()`) converts free-text assessment notes into a sentiment score and a short summary stored alongside the raw row. **Cortex Search** (`WINEMAG_DESCRIPTION_SEARCH`) makes the `description` column semantically searchable, so a category manager can query for a product characteristic in plain language and combine it with structured filters such as `COUNTRY = 'France' AND PRICE <= 30`. **Cortex Analyst**, initialized over a semantic view (`WINE_ANALYTICS_SV`) that maps the fact and dimension primary keys and documents every fact, dimension, and metric with a business definition, translates plain-English questions into SQL against the Silver layer — for example, "In France, which suppliers have the highest average quality score, with at least 30 records?" returns Louis Roederer (93.27 average across 45 records), Domaine Weinbach (92.58 / 31), and Domaine Zind-Humbrecht (92.52 / 101) at the top.

The **Streamlit app** ("Wine Insights & Business Metrics Dashboard") delivers all three Gold tables through a single navigation pane with country, price-band, category, and minimum-record-count filters.

---

## Data Quality and Governance

Three of the four data management concerns are addressed structurally by the architecture; the fourth is handled by an explicit checks layer.

**Lineage** is the medallion itself. Every Gold column traces back through a named stored procedure to a Silver table, and every Silver row traces back to `WINEMAG_BRONZE_RAW`. Because Bronze is never corrected in place, any downstream value can be reproduced by replaying the transformations.

**Business definitions** live in the semantic view. `WINE_ANALYTICS_SV` carries a `COMMENT` on every fact, dimension, and metric — *"Bottle price in USD," "Wine rating points from the reviewer," "Average reviewer score"* — so Cortex Analyst and any human reader work from the same definitions rather than inferring them from column names.

**Referential integrity** is enforced in the DDL. `FACT_WINE_REVIEW` declares foreign keys to `DIM_WINE`, `DIM_TASTER`, and `DIM_REGION`; `DIM_REGION` declares one to `DIM_COUNTRY`. Populating dimensions before the fact table is what makes those constraints satisfiable.

**Quality monitoring** is the part the architecture does not give you for free. `MONITORING.SP_RUN_DQ_CHECKS` runs six checks and records each with its measured value, threshold, and status:

| Check | Layer | Threshold | Catches |
|---|---|---|---|
| `bronze_to_silver_reconciliation` | Silver | 0 row difference | Partial or failed loads |
| `fact_price_null_rate` | Silver | ≤ 10% | Upstream completeness degradation |
| `fact_review_key_uniqueness` | Silver | 0 duplicates | Double-processed stream batches |
| `fact_orphan_wine_keys` | Silver | 0 orphans | Broken dimension joins |
| `fact_points_out_of_range` | Silver | 0 rows outside 80–100 | Source schema drift |
| `bronze_freshness_hours` | Bronze | ≤ 24 hours | Stalled Snowpipe ingestion |

The reconciliation check is the one most likely to surface a real difference: Bronze rows with a null country are filtered on the way into Silver, so a non-zero variance is expected and its magnitude should be documented rather than suppressed. A check that always passes is not monitoring anything.

**Access governance** is handled with a column-level masking policy. `taster_name` and `taster_twitter_handle` are personal data, so `SILVER.MASK_TASTER_IDENTITY` returns the value only for the owning role and `***RESTRICTED***` for everyone else. Analysts can still aggregate by `taster_key` — assessor effects remain analyzable without exposing assessor identity.

---

## Summary of Insights

### Architecture and Pipeline Design

- Separating Bronze from Silver meant the AI enrichment step (sentiment and summarization) could run against raw assessment text without contaminating the dimensional model — the enriched columns live on the Bronze table and remain available to any downstream layer that wants them.
- Populating dimensions before the fact table, and resolving foreign keys through joins back to those dimensions, is the mechanism that keeps the star schema consistent. Surrogate keys generated by `AUTOINCREMENT` decouple the model from source-system identifiers, so a change in how a supplier or sourcing region is spelled upstream does not break existing fact rows.
- Stream-based propagation means Silver and Gold reflect only what has changed since the last run, rather than requiring a full rebuild on every file arrival. The trade-off is that the stored procedures are currently invoked manually or on a schedule, which leaves a window where Bronze is ahead of Silver and Gold — which is why the freshness check exists.

### Price Tier and Quality Findings

- Volume is heavily concentrated in the **Mid ($15–30)** and **Premium ($30–75)** bands, which together account for the large majority of records. Budget, Luxury, and Unknown-price products each represent a much smaller slice.
- Average quality scores, by contrast, are far flatter across bands than volume is. Every band clusters in a relatively narrow scoring range, which means unit price is a weak predictor of quality score. The commercially interesting signal is in the outliers, not the band averages.
- This gap between volume distribution and score distribution is the core of business question 1: the Premium band is over-represented in spend and coverage relative to the quality advantage it delivers, and the Budget and Mid bands contain products scoring competitively with far more expensive alternatives.

### Supplier Performance Findings

- Ranking within sourcing country rather than globally surfaces suppliers a global leaderboard would hide. In the South Africa view, Hartenberg leads on average quality score (89.48 across 21 records, avg unit price $56.29) but sits at rank 106 globally, while Simonsig delivers a comparable 89.10 average across 31 records at less than half the price (avg $25.61).
- The minimum-record-count filter is doing meaningful work. Without it, suppliers with two or three exceptional records dominate any average-score ranking. Requiring a floor on record count trades some coverage for rankings that are actually reproducible.
- Pairing average quality with average unit price in the same table is what makes the output actionable — Robertson Winery (86.69 avg score, $14.23 avg price) and Beau Joubert (86.70, $13.85) are value sourcing options, while Hartenberg is a premium option, and the ranking alone would not distinguish them.

### AI and Semantic Layer Findings

- Cortex Search unlocks a use case the structured model cannot serve at all: the `description` field contains detail that appears nowhere in the numeric columns. Semantic search over those notes lets category managers assemble sourcing shortlists around product characteristics rather than only around price and score.
- Combining semantic search with structured JSON filters is more useful than either alone — a characteristic-based query constrained to France under $30 is a sourcing brief, not just a query.
- Cortex Analyst shifts the access model. Once the semantic view maps the fact and dimension keys, a business user asking a question in English gets a correct join path they would otherwise need an analyst to write. Verified queries saved back into the semantic view compound this over time by teaching the service the organization's preferred phrasings.

---

## Recommendations

**Data Engineering — Close the propagation gap**
- Convert the manual `CALL SP_LOAD_SILVER_TABLES()` / `CALL SP_LOAD_GOLD_TABLES()` invocations into a Snowflake Task chain triggered on stream data availability, so Silver and Gold stay in sync with Bronze without a scheduled-lag window.
- Wire `SP_RUN_DQ_CHECKS` into that task chain so the checks run automatically after every load, and alert on any `FAIL` status rather than requiring someone to query `DQ_RESULTS`.

**Procurement — Exploit the price/quality gap**
- Use `TOP_BAND_METRICS` to identify Budget and Mid band products scoring at or above the Premium band average, and build substitution proposals from them. This is the clearest margin opportunity the data exposes.
- Renegotiate or re-tier suppliers whose average unit price sits in the Premium band while their average quality score does not clear the Mid band average — the current data makes those cases directly visible.

**Category Management — Use the Gold layer directly**
- Pull from the `TOP_WINES` table for assortment and promotional planning rather than requesting ad-hoc extracts; it is already partitioned by country, category, and price band, which matches how assortment decisions are usually segmented.

**Analytics — Extend the semantic and AI layers**
- Fold `description_sentiment` and `description_summary` into the Silver and Gold layers so sentiment can be aggregated by supplier and price band, not just inspected row by row. Sentiment alongside quality score would test whether numeric scores and written commentary actually agree.
- Continue saving verified queries into `WINE_ANALYTICS_SV` as business users interact with Cortex Analyst, and periodically review which questions the service answers poorly — those gaps usually indicate a missing relationship in the semantic view.

**Governance — Extend the checks and the access model**
- The `fact_price_null_rate` check makes missing-price volume visible, but the decision of whether to exclude, impute, or report those rows separately still needs to be made once and applied consistently across all three Gold tables.
- Extend masking beyond `DIM_TASTER` if the model grows to include supplier contact or contract data, and split the single owning role into separate analyst and admin roles so least privilege is enforced by grant rather than by convention.

---

## Appendix

### Assumptions and Caveats

- The dataset is a static snapshot, not a live ERP feed. It does not reflect current contract pricing or current supplier status.
- Price band cutoffs (Budget <15, Mid 15–30, Premium 30–75, Luxury >75) and the quality threshold for `TOP_WINES` (`points >= 90`) are analyst-defined and hard-coded in the Gold layer SQL. They are reasonable but arbitrary, and changing them changes every downstream conclusion about tier performance.
- Products with a null price are bucketed as `Unknown` rather than excluded. Any statement about band averages should be read as excluding that group.
- Quality scores are assessor-assigned and therefore subjective. `DIM_TASTER` exists in the model but assessor effects were not controlled for in the supplier or price-band aggregates, so a supplier heavily assessed by a lenient assessor may rank higher than one assessed by a stricter assessor.
- Supplier rankings are sensitive to the minimum-record-count filter applied at query time in the Streamlit app. Rankings quoted without stating that filter are not comparable to each other.
- The dataset reflects products that were submitted for assessment, not the full universe of products sourced. Coverage skews toward suppliers who actively participate, which is a selection effect rather than a market share signal.
- AI-generated sentiment scores and summaries are model outputs and were not validated against human labels. They are suitable for exploration and filtering, not as a system of record.
- Cortex Analyst translates natural language to SQL probabilistically. Results returned through the natural-language interface should be spot-checked against the underlying Silver tables before being used in reporting.
- Data quality thresholds (10% null rate on price, 24-hour freshness) are set from expected behaviour of this dataset and this ingestion cadence. They would need recalibrating against production traffic before being treated as alerting thresholds.
- **Source data:** the pipeline was built and validated against a public 130K-record product review dataset, framed here as an ERP supplier-quality domain. Database object names retain the source dataset's naming; the architecture, transformations, and services are unchanged.

### Tech Stack

| Component | Technology |
|---|---|
| Warehouse | Snowflake (`ANIMAL_TASK_WH`, Small) |
| Database | `DB_TEAM_ROCKSTARS` |
| Ingestion | Snowpipe (`WINEMAG_PIPE`, `AUTO_INGEST = TRUE`), stage `CSV_STAGE` |
| Change Capture | Snowflake Stream (`WINEMAG_BRONZE_STREAM`) |
| Orchestration | Stored Procedures (`SP_LOAD_SILVER_TABLES`, `SP_LOAD_GOLD_TABLES`) |
| Modeling | Star schema (SQL, surrogate keys via `AUTOINCREMENT`) |
| Data Quality | `MONITORING.SP_RUN_DQ_CHECKS`, results logged to `MONITORING.DQ_RESULTS` |
| Access Governance | Column-level masking policy (`SILVER.MASK_TASTER_IDENTITY`) |
| AI Enrichment | `SNOWFLAKE.CORTEX.SENTIMENT()`, `SNOWFLAKE.CORTEX.SUMMARIZE()` |
| Semantic Search | Cortex Search (`WINEMAG_DESCRIPTION_SEARCH`), `SNOWFLAKE.CORTEX.SEARCH_PREVIEW` |
| NL Querying | Cortex Analyst over Semantic View `WINE_ANALYTICS_SV` |
| Front End | Streamlit in Snowflake — "Wine Insights & Business Metrics Dashboard" |

### Repository Contents

| File | Purpose |
|---|---|
| `Project_Team_RockStars.sql` | Schema creation, Bronze load, Silver dimensional model, Gold aggregates |
| `AI_SQL.sql` | AI SQL enrichment and Cortex Search service definition |
| `04_data_quality_and_governance.sql` | Data quality checks procedure, masking policy, table-level metadata |
| `HW1.sql` | Supporting exploratory queries |
| `Prediction.sql` | Modeling and prediction scratch work |
| `Database_design_ppt.pdf` | Final presentation deck |
Three Snowflake-native services extend this beyond SQL access. **AI SQL** (`SNOWFLAKE.ML.SENTIMENT()`, `SNOWFLAKE.ML.SUMMARIZE()`) converts free-text assessment notes into a sentiment score and a short summary stored alongside the raw row. **Cortex Search** (`WINEMAG_DESCRIPTION_SEARCH`) makes the `description` column semantically searchable, so a category manager can query for a product characteristic in plain language and combine it with structured filters such as `COUNTRY = 'France' AND PRICE <= 30`. **Cortex Analyst**, initialized over a semantic view (`WINE_ANALYTICS_SV`) that maps the fact and dimension primary keys, translates plain-English questions into SQL against the Silver layer — for example, "In France, which suppliers have the highest average quality score, with at least 30 records?" returns Louis Roederer (93.27 average across 45 records), Domaine Weinbach (92.58 / 31), and Domaine Zind-Humbrecht (92.52 / 101) at the top.

The **Streamlit app** ("Wine Insights & Business Metrics Dashboard") delivers all three Gold tables through a single navigation pane with country, price-band, category, and minimum-record-count filters.

---

## Summary of Insights

### Architecture and Pipeline Design

- Separating Bronze from Silver meant the AI enrichment step (sentiment and summarization) could run against raw assessment text without contaminating the dimensional model — the enriched columns live on the Bronze table and remain available to any downstream layer that wants them.
- Populating dimensions before the fact table, and resolving foreign keys through joins back to those dimensions, is the mechanism that keeps the star schema consistent. Surrogate keys generated by `AUTOINCREMENT` decouple the model from source-system identifiers, so a change in how a supplier or sourcing region is spelled upstream does not break existing fact rows.
- Stream-based propagation means Silver and Gold reflect only what has changed since the last run, rather than requiring a full rebuild on every file arrival. The trade-off is that the stored procedures are currently invoked manually or on a schedule, which leaves a window where Bronze is ahead of Silver and Gold.

### Price Tier and Quality Findings

- Volume is heavily concentrated in the **Mid ($15–30)** and **Premium ($30–75)** bands, which together account for the large majority of records. Budget, Luxury, and Unknown-price products each represent a much smaller slice.
- Average quality scores, by contrast, are far flatter across bands than volume is. Every band clusters in a relatively narrow scoring range, which means unit price is a weak predictor of quality score. The commercially interesting signal is in the outliers, not the band averages.
- This gap between volume distribution and score distribution is the core of business question 1: the Premium band is over-represented in spend and coverage relative to the quality advantage it delivers, and the Budget and Mid bands contain products scoring competitively with far more expensive alternatives.

### Supplier Performance Findings

- Ranking within sourcing country rather than globally surfaces suppliers a global leaderboard would hide. In the South Africa view, Hartenberg leads on average quality score (89.48 across 21 records, avg unit price $56.29) but sits at rank 106 globally, while Simonsig delivers a comparable 89.10 average across 31 records at less than half the price (avg $25.61).
- The minimum-record-count filter is doing meaningful work. Without it, suppliers with two or three exceptional records dominate any average-score ranking. Requiring a floor on record count trades some coverage for rankings that are actually reproducible.
- Pairing average quality with average unit price in the same table is what makes the output actionable — Robertson Winery (86.69 avg score, $14.23 avg price) and Beau Joubert (86.70, $13.85) are value sourcing options, while Hartenberg is a premium option, and the ranking alone would not distinguish them.

### AI and Semantic Layer Findings

- Cortex Search unlocks a use case the structured model cannot serve at all: the `description` field contains detail that appears nowhere in the numeric columns. Semantic search over those notes lets category managers assemble sourcing shortlists around product characteristics rather than only around price and score.
- Combining semantic search with structured JSON filters is more useful than either alone — a characteristic-based query constrained to France under $30 is a sourcing brief, not just a query.
- Cortex Analyst shifts the access model. Once the semantic view maps the fact and dimension keys, a business user asking a question in English gets a correct join path they would otherwise need an analyst to write. Verified queries saved back into the semantic view compound this over time by teaching the service the organization's preferred phrasings.

---

## Recommendations

**Data Engineering — Close the propagation gap**
- Convert the manual `CALL SP_LOAD_SILVER_TABLES()` / `CALL SP_LOAD_GOLD_TABLES()` invocations into a Snowflake Task chain triggered on stream data availability, so Silver and Gold stay in sync with Bronze without a scheduled-lag window.
- Add row-count and null-key assertions inside the stored procedures rather than verifying counts manually after the fact, so a partial load fails loudly instead of silently producing incomplete Gold tables.

**Procurement — Exploit the price/quality gap**
- Use `TOP_BAND_METRICS` to identify Budget and Mid band products scoring at or above the Premium band average, and build substitution proposals from them. This is the clearest margin opportunity the data exposes.
- Renegotiate or re-tier suppliers whose average unit price sits in the Premium band while their average quality score does not clear the Mid band average — the current data makes those cases directly visible.

**Category Management — Use the Gold layer directly**
- Pull from the `TOP_WINES` table for assortment and promotional planning rather than requesting ad-hoc extracts; it is already partitioned by country, category, and price band, which matches how assortment decisions are usually segmented.

**Analytics — Extend the semantic and AI layers**
- Fold `description_sentiment` and `description_summary` into the Silver and Gold layers so sentiment can be aggregated by supplier and price band, not just inspected row by row. Sentiment alongside quality score would test whether numeric scores and written commentary actually agree.
- Continue saving verified queries into `WINE_ANALYTICS_SV` as business users interact with Cortex Analyst, and periodically review which questions the service answers poorly — those gaps usually indicate a missing relationship in the semantic view.

**Governance — Handle price completeness**
- The Unknown price band is large enough to distort any price-based aggregate if it is silently dropped. Decide explicitly whether missing-price rows are excluded, imputed, or reported separately, and apply that decision consistently across all three Gold tables.

---

## Appendix

### Assumptions and Caveats

- The dataset is a static snapshot, not a live ERP feed. It does not reflect current contract pricing or current supplier status.
- Price band cutoffs (Budget <15, Mid 15–30, Premium 30–75, Luxury >75) and the quality threshold for `TOP_WINES` (`points >= 90`) are analyst-defined and hard-coded in the Gold layer SQL. They are reasonable but arbitrary, and changing them changes every downstream conclusion about tier performance.
- Products with a null price are bucketed as `Unknown` rather than excluded. Any statement about band averages should be read as excluding that group.
- Quality scores are assessor-assigned and therefore subjective. `DIM_TASTER` exists in the model but assessor effects were not controlled for in the supplier or price-band aggregates, so a supplier heavily assessed by a lenient assessor may rank higher than one assessed by a stricter assessor.
- Supplier rankings are sensitive to the minimum-record-count filter applied at query time in the Streamlit app. Rankings quoted without stating that filter are not comparable to each other.
- The dataset reflects products that were submitted for assessment, not the full universe of products sourced. Coverage skews toward suppliers who actively participate, which is a selection effect rather than a market share signal.
- AI-generated sentiment scores and summaries are model outputs and were not validated against human labels. They are suitable for exploration and filtering, not as a system of record.
- Cortex Analyst translates natural language to SQL probabilistically. Results returned through the natural-language interface should be spot-checked against the underlying Silver tables before being used in reporting.
- **Source data:** the pipeline was built and validated against a public 130K-record product review dataset, framed here as an ERP supplier-quality domain. Database object names retain the source dataset's naming; the architecture, transformations, and services are unchanged.

### Tech Stack

| Component | Technology |
|---|---|
| Warehouse | Snowflake (`ANIMAL_TASK_WH`, Small) |
| Database | `DB_TEAM_ROCKSTARS` |
| Ingestion | Snowpipe (`WINEMAG_PIPE`, `AUTO_INGEST = TRUE`), stage `CSV_STAGE` |
| Change Capture | Snowflake Stream (`WINEMAG_BRONZE_STREAM`) |
| Orchestration | Stored Procedures (`SP_LOAD_SILVER_TABLES`, `SP_LOAD_GOLD_TABLES`) |
| Modeling | Star schema (SQL, surrogate keys via `AUTOINCREMENT`) |
| AI Enrichment | `SNOWFLAKE.ML.SENTIMENT()`, `SNOWFLAKE.ML.SUMMARIZE()` |
| Semantic Search | Cortex Search (`WINEMAG_DESCRIPTION_SEARCH`), `SNOWFLAKE.CORTEX.SEARCH_PREVIEW` |
| NL Querying | Cortex Analyst over Semantic View `WINE_ANALYTICS_SV` |
| Front End | Streamlit in Snowflake — "Wine Insights & Business Metrics Dashboard" |

### Repository Contents

| File | Purpose |
|---|---|
| `Project_Team_RockStars.sql` | Schema creation, Bronze load, Silver dimensional model, Gold aggregates |
| `AI_SQL.sql` | AI SQL enrichment and Cortex Search service definition |
| `HW1.sql` | Supporting exploratory queries |
| `Prediction.sql` | Modeling and prediction scratch work |
| `Database_design_ppt.pdf` | Final presentation deck |
