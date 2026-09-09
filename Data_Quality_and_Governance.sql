USE ROLE ROLE_TEAM_ROCKSTARS;
USE WAREHOUSE ANIMAL_TASK_WH;
USE DATABASE DB_TEAM_ROCKSTARS;

-- ============ 1. DATA QUALITY MONITORING ============
CREATE OR REPLACE SCHEMA DB_TEAM_ROCKSTARS.MONITORING;

CREATE OR REPLACE TABLE MONITORING.DQ_RESULTS (
    run_ts        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    check_name    STRING,
    layer         STRING,
    metric_value  FLOAT,
    threshold     FLOAT,
    status        STRING
);

CREATE OR REPLACE PROCEDURE MONITORING.SP_RUN_DQ_CHECKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    DELETE FROM MONITORING.DQ_RESULTS WHERE run_ts::DATE = CURRENT_DATE();

    -- Reconciliation: Bronze row count vs Silver fact row count
    INSERT INTO MONITORING.DQ_RESULTS (check_name, layer, metric_value, threshold, status)
    SELECT 'bronze_to_silver_reconciliation', 'SILVER',
           ABS(b.cnt - f.cnt), 0,
           IFF(ABS(b.cnt - f.cnt) = 0, 'PASS', 'FAIL')
    FROM (SELECT COUNT(*) cnt FROM BRONZE.WINEMAG_BRONZE_RAW) b,
         (SELECT COUNT(*) cnt FROM SILVER.FACT_WINE_REVIEW) f;

    -- Completeness: null rate on price
    INSERT INTO MONITORING.DQ_RESULTS (check_name, layer, metric_value, threshold, status)
    SELECT 'fact_price_null_rate', 'SILVER',
           COUNT_IF(price IS NULL) / NULLIF(COUNT(*), 0), 0.10,
           IFF(COUNT_IF(price IS NULL) / NULLIF(COUNT(*), 0) <= 0.10, 'PASS', 'FAIL')
    FROM SILVER.FACT_WINE_REVIEW;

    -- Uniqueness: duplicate review keys
    INSERT INTO MONITORING.DQ_RESULTS (check_name, layer, metric_value, threshold, status)
    SELECT 'fact_review_key_uniqueness', 'SILVER',
           COUNT(*) - COUNT(DISTINCT review_key), 0,
           IFF(COUNT(*) = COUNT(DISTINCT review_key), 'PASS', 'FAIL')
    FROM SILVER.FACT_WINE_REVIEW;

    -- Referential integrity: orphan foreign keys
    INSERT INTO MONITORING.DQ_RESULTS (check_name, layer, metric_value, threshold, status)
    SELECT 'fact_orphan_wine_keys', 'SILVER',
           COUNT(*), 0,
           IFF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM SILVER.FACT_WINE_REVIEW f
    LEFT JOIN SILVER.DIM_WINE w ON f.wine_key = w.wine_key
    WHERE f.wine_key IS NOT NULL AND w.wine_key IS NULL;

    -- Validity: points outside the 80-100 scale
    INSERT INTO MONITORING.DQ_RESULTS (check_name, layer, metric_value, threshold, status)
    SELECT 'fact_points_out_of_range', 'SILVER',
           COUNT_IF(points < 80 OR points > 100), 0,
           IFF(COUNT_IF(points < 80 OR points > 100) = 0, 'PASS', 'FAIL')
    FROM SILVER.FACT_WINE_REVIEW;

    -- Freshness: hours since last Bronze load
    INSERT INTO MONITORING.DQ_RESULTS (check_name, layer, metric_value, threshold, status)
    SELECT 'bronze_freshness_hours', 'BRONZE',
           DATEDIFF('hour', MAX(last_altered), CURRENT_TIMESTAMP()), 24,
           IFF(DATEDIFF('hour', MAX(last_altered), CURRENT_TIMESTAMP()) <= 24, 'PASS', 'FAIL')
    FROM INFORMATION_SCHEMA.TABLES
    WHERE table_schema = 'BRONZE' AND table_name = 'WINEMAG_BRONZE_RAW';

    RETURN 'DQ checks complete';
END;
$$;

CALL MONITORING.SP_RUN_DQ_CHECKS();
SELECT * FROM MONITORING.DQ_RESULTS ORDER BY run_ts DESC;

-- ============ 2. ACCESS GOVERNANCE ============
-- Reviewer identity is PII: mask it for anyone outside the owning role
CREATE OR REPLACE MASKING POLICY SILVER.MASK_TASTER_IDENTITY
AS (val STRING) RETURNS STRING ->
    CASE WHEN CURRENT_ROLE() = 'ROLE_TEAM_ROCKSTARS' THEN val
         ELSE '***RESTRICTED***' END;

ALTER TABLE SILVER.DIM_TASTER
    MODIFY COLUMN taster_name SET MASKING POLICY SILVER.MASK_TASTER_IDENTITY;
ALTER TABLE SILVER.DIM_TASTER
    MODIFY COLUMN taster_twitter SET MASKING POLICY SILVER.MASK_TASTER_IDENTITY;

-- ============ 3. TABLE-LEVEL METADATA ============
COMMENT ON TABLE SILVER.FACT_WINE_REVIEW IS
  'Review-grain fact. One row per wine review. Grain chosen to preserve atomic price and points measurements for aggregation by country, variety, or price band.';
COMMENT ON TABLE SILVER.DIM_TASTER IS
  'Reviewer dimension. Contains PII (name, social handle) — masked outside the owning role.';
COMMENT ON SCHEMA GOLD IS
  'Business-ready aggregates. Consumers read here; Bronze and Silver are restricted.';
