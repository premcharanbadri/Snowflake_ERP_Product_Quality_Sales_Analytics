

//Dataset to use : <Approved by instructor for your project>
//Snowflake Account to use: <Assigned by instructor to your section>
//Database to use: DB_Team_<team_name>
//Role to use: ROLE_Team_<team_name>
//Warehouse to use: Animal_Task_WH

DROP PIPE DB_TEAM_ROCKSTARS.BRONZE.winemag_pipe;
DROP STREAM DB_TEAM_ROCKSTARS.BRONZE.winemag_bronze_Stream;

USE ROLE ROLE_TEAM_ROCKSTARS;
USE WAREHOUSE ANIMAL_TASK_WH;
USE DATABASE DB_Team_ROCKSTARS;

-------------------Schema Creation---------------------
CREATE or replace SCHEMA DB_TEAM_ROCKSTARS.BRONZE;
CREATE or replace SCHEMA DB_TEAM_ROCKSTARS.SILVER;
CREATE or replace SCHEMA DB_TEAM_ROCKSTARS.GOLD;


-----------------Load Data / Bronze Objects----------------
CREATE OR REPLACE FILE FORMAT DB_TEAM_ROCKSTARS.BRONZE.CSV_FORMAT
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('NULL', 'null')
    EMPTY_FIELD_AS_NULL = TRUE
    COMPRESSION = AUTO;

CREATE OR REPLACE STAGE DB_TEAM_ROCKSTARS.BRONZE.CSV_STAGE FILE_FORMAT = DB_TEAM_ROCKSTARS.BRONZE.CSV_FORMAT;

SHOW FILE FORMATS LIKE 'CSV_FORMAT' IN SCHEMA DB_TEAM_ROCKSTARS.BRONZE;
SHOW STAGES LIKE 'CSV_STAGE' IN SCHEMA DB_TEAM_ROCKSTARS.BRONZE;

LIST @DB_TEAM_ROCKSTARS.BRONZE.CSV_STAGE;

//Create Bronze Table
CREATE OR REPLACE TABLE DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW (
    ID                     Integer,
    country                STRING,
    description            STRING,
    designation            STRING,
    points                 INTEGER,
    price                  INTEGER,
    province               STRING,
    region_1               STRING,
    region_2               STRING,
    taster_name            STRING,
    taster_twitter_handle  STRING,
    title                  STRING,
    variety                STRING,
    winery                 STRING
);

//Populate Bronze
COPY INTO DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW
FROM @DB_TEAM_ROCKSTARS.BRONZE.CSV_STAGE
FILE_FORMAT = (FORMAT_NAME = 'DB_TEAM_ROCKSTARS.BRONZE.CSV_FORMAT')
ON_ERROR = 'CONTINUE';

SELECT * 
FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW
LIMIT 10;



----------------------Silver Objects------------------------

USE SCHEMA SILVER;
//Dim Country
CREATE OR REPLACE TABLE DIM_COUNTRY (
    country_key   NUMBER AUTOINCREMENT PRIMARY KEY,
    country_name  STRING
);

//Dim Region
CREATE OR REPLACE TABLE DIM_REGION (
    region_key   NUMBER AUTOINCREMENT PRIMARY KEY,
    country_key  NUMBER,
    province     STRING,
    region_1     STRING,
    region_2     STRING,
    CONSTRAINT fk_region_country
        FOREIGN KEY (country_key)
        REFERENCES SILVER.DIM_COUNTRY(country_key)
);

// Dim Taster
CREATE OR REPLACE TABLE DIM_TASTER (
    taster_key      NUMBER AUTOINCREMENT PRIMARY KEY,
    taster_name     STRING,
    taster_twitter  STRING
);

//Dim Wine
CREATE OR REPLACE TABLE DIM_WINE (
    wine_key     NUMBER AUTOINCREMENT PRIMARY KEY,
    variety      STRING,
    winery       STRING,
    designation  STRING
);



//Fact Wine Review
CREATE OR REPLACE TABLE FACT_WINE_REVIEW (
    review_key   NUMBER AUTOINCREMENT PRIMARY KEY,
    wine_key     NUMBER,
    taster_key   NUMBER,
    region_key   NUMBER,
    price        FLOAT,
    points       INTEGER,
    description  STRING,
    review_title STRING,

    CONSTRAINT fk_fact_wine
        FOREIGN KEY (wine_key)
        REFERENCES SILVER.DIM_WINE(wine_key),

    CONSTRAINT fk_fact_taster
        FOREIGN KEY (taster_key)
        REFERENCES SILVER.DIM_TASTER(taster_key),

    CONSTRAINT fk_fact_region
        FOREIGN KEY (region_key)
        REFERENCES SILVER.DIM_REGION(region_key)
);


----------------Populate Silver--------------------

//Populate Dim Country
TRUNCATE TABLE DIM_COUNTRY;

INSERT INTO DIM_COUNTRY (country_name)
SELECT DISTINCT
    country
FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW
WHERE country IS NOT NULL;

Select * from DIM_COUNTRY;

//Populate Dim Region
TRUNCATE TABLE DIM_REGION;

INSERT INTO DIM_REGION (country_key, province, region_1, region_2)
SELECT DISTINCT
    c.country_key,
    b.province,
    b.region_1,
    b.region_2
FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW b
LEFT JOIN SILVER.DIM_COUNTRY c
    ON b.country = c.country_name;

Select * from Dim_region;

//Populate Dim Taster
TRUNCATE TABLE DIM_TASTER;

INSERT INTO DIM_TASTER (taster_name, taster_twitter)
SELECT DISTINCT
    taster_name,
    taster_twitter_handle
FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW
WHERE taster_name IS NOT NULL 
   OR taster_twitter_handle IS NOT NULL;

Select * from dim_taster;


//Populate Dim Wine
TRUNCATE TABLE DIM_WINE;

INSERT INTO DIM_WINE (variety, winery, designation)
SELECT DISTINCT
    variety,
    winery,
    designation
FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW;

Select * from Dim_Wine;

//Populate Dim Fact
TRUNCATE TABLE FACT_WINE_REVIEW;

INSERT INTO FACT_WINE_REVIEW (
    wine_key,
    taster_key,
    region_key,
    price,
    points,
    description,
    review_title
)
SELECT
    w.wine_key,
    t.taster_key,
    r.region_key,
    b.price,
    b.points,
    b.description,
    b.title
FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW b

-- Join to DIM_WINE (by wine attributes)
LEFT JOIN SILVER.DIM_WINE w
    ON  NVL(b.variety,  '') = NVL(w.variety,  '')
    AND NVL(b.winery,   '') = NVL(w.winery,   '')
    AND NVL(b.designation, '') = NVL(w.designation, '')

-- Join to DIM_TASTER
LEFT JOIN SILVER.DIM_TASTER t
    ON  NVL(b.taster_name,           '') = NVL(t.taster_name, '')
    AND NVL(b.taster_twitter_handle, '') = NVL(t.taster_twitter, '')

-- Join to DIM_REGION (via country → region)
LEFT JOIN SILVER.DIM_COUNTRY c
    ON NVL(b.country, '') = NVL(c.country_name, '')
LEFT JOIN SILVER.DIM_REGION r
    ON  r.country_key = c.country_key
    AND NVL(r.province, '') = NVL(b.province, '')
    AND NVL(r.region_1, '') = NVL(b.region_1, '')
    AND NVL(r.region_2, '') = NVL(b.region_2, '');

SELECT * FROM FACT_WINE_REVIEW LIMIT 10;


--------------------Use Cases for Business Reporting---------------

USE SCHEMA GOLD;
//“Which wineries consistently produce the highest-rated wines, and at what price points?”
CREATE OR REPLACE TABLE WINERY_METRICS AS
WITH base AS (
    SELECT
        w.winery,
        c.country_name AS country,
        r.province,

        COUNT(*)                          AS review_count,
        COUNT(DISTINCT f.wine_key)        AS distinct_wines,
        AVG(f.points)                     AS avg_points,
        AVG(f.price)                      AS avg_price,
        MIN(f.points)                     AS min_points,
        MAX(f.points)                     AS max_points
    FROM DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW f
    JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_WINE w
        ON f.wine_key = w.wine_key
    LEFT JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_REGION r
        ON f.region_key = r.region_key
    LEFT JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY c
        ON r.country_key = c.country_key
    GROUP BY
        w.winery,
        c.country_name,
        r.province
)
SELECT
    *,
    RANK() OVER (
        PARTITION BY country
        ORDER BY avg_points DESC, review_count DESC
    ) AS rank_in_country_by_points
FROM base;

SELECT *
FROM GOLD.WINERY_METRICS
ORDER BY country, rank_in_country_by_points;




//“How do different price tiers perform in terms of quality and volume? Is premium over- or under-represented?”


CREATE OR REPLACE TABLE PRICE_BAND_METRICS AS
WITH fact_enriched AS (
    SELECT
        f.review_key,
        f.wine_key,
        f.price,
        f.points,
        c.country_name AS country,

        CASE
            WHEN f.price IS NULL THEN 'Unknown'
            WHEN f.price < 15 THEN 'Budget (<15)'
            WHEN f.price < 30 THEN 'Mid (15-30)'
            WHEN f.price < 75 THEN 'Premium (30-75)'
            ELSE 'Luxury (>75)'
        END AS price_band
    FROM DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW f
    LEFT JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_REGION r
        ON f.region_key = r.region_key
    LEFT JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY c
        ON r.country_key = c.country_key
)
SELECT
    price_band,
    country,

    COUNT(*)                   AS review_count,
    COUNT(DISTINCT wine_key)   AS distinct_wines,
    AVG(points)                AS avg_points,
    AVG(price)                 AS avg_price
FROM fact_enriched
GROUP BY
    price_band,
    country;

SELECT *
FROM GOLD.PRICE_BAND_METRICS
ORDER BY price_band, country;



//“Give me a ready-to-use table of ‘Top Wines’ by country / variety / price band for marketing, emails, banners.”


CREATE OR REPLACE TABLE TOP_WINES AS
WITH fact_enriched AS (
    SELECT
        f.review_key,
        f.wine_key,
        f.points,
        f.price,
        f.review_title,
        f.description,

        w.winery,
        w.variety,
        w.designation,

        c.country_name AS country,
        r.province,

        CASE
            WHEN f.price IS NULL THEN 'Unknown'
            WHEN f.price < 15 THEN 'Budget (<15)'
            WHEN f.price < 30 THEN 'Mid (15-30)'
            WHEN f.price < 75 THEN 'Premium (30-75)'
            ELSE 'Luxury (>75)'
        END AS price_band
    FROM DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW f
    JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_WINE w
        ON f.wine_key = w.wine_key
    LEFT JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_REGION r
        ON f.region_key = r.region_key
    LEFT JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY c
        ON r.country_key = c.country_key
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY country, variety, price_band
            ORDER BY points DESC, price ASC
        ) AS rank_within_bucket
    FROM fact_enriched
    WHERE points IS NOT NULL
      AND price IS NOT NULL
      AND points >= 90   -- you can change this cutoff
)
SELECT
    review_key,
    wine_key,
    review_title,
    description,
    winery,
    variety,
    designation,
    country,
    province,
    price,
    points,
    price_band,
    rank_within_bucket
FROM ranked
WHERE rank_within_bucket <= 10;   -- top 10 per (country, variety, price_band)

-- Top 10 French Pinot Noir wines in each price band
SELECT *
FROM GOLD.TOP_WINES
WHERE country = 'France'
  AND variety ILIKE '%Pinot Noir%'
ORDER BY price_band, rank_within_bucket;




// Use at least 2 AI SQL functions on the descriptive column in the bronze layer table and store the output as additional outputs on bronze layer table. There is no need to move these new columns to silver and gold layer
USE ROLE ROLE_TEAM_ROCKSTARS;
USE WAREHOUSE ANIMAL_TASK_WH;
USE DATABASE DB_TEAM_ROCKSTARS;
USE SCHEMA BRONZE;
ALTER TABLE WINEMAG_BRONZE_RAW
  ADD (
      description_summary   STRING,
      description_sentiment FLOAT
  );

UPDATE WINEMAG_BRONZE_RAW
SET
  description_summary   = SNOWFLAKE.CORTEX.SUMMARIZE(description),
  description_sentiment = SNOWFLAKE.CORTEX.SENTIMENT(description);

// Check whether columns description_summary and description_sentiment are populated
SELECT
  ID,
  description,
  description_summary,
  description_sentiment
FROM WINEMAG_BRONZE_RAW
LIMIT 10;


// Build a Cortex Search service to search on the descriptive column in the bronze layer and try few searches
USE ROLE ROLE_TEAM_ROCKSTARS;
USE WAREHOUSE ANIMAL_TASK_WH;
USE DATABASE DB_TEAM_ROCKSTARS;
USE SCHEMA BRONZE;

CREATE OR REPLACE CORTEX SEARCH SERVICE WINEMAG_DESCRIPTION_SEARCH
  ON DESCRIPTION                            -- main text column to search
  ATTRIBUTES COUNTRY, PROVINCE, VARIETY, WINERY, POINTS, PRICE
  WAREHOUSE = ANIMAL_TASK_WH
  TARGET_LAG = '10 minutes'
AS
  SELECT
      ID,
      DESCRIPTION,
      COUNTRY,
      PROVINCE,
      REGION_1,
      REGION_2,
      VARIETY,
      WINERY,
      POINTS,
      PRICE
  FROM WINEMAG_BRONZE_RAW;

// Optional check for Cortex Search Service
SHOW CORTEX SEARCH SERVICES IN SCHEMA BRONZE;


// Example 1 – Find fruity red wines
SELECT
  PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
      'WINEMAG_DESCRIPTION_SEARCH',
      '{
         "query":  "fruity red wine with cherry notes",
         "columns": ["ID", "DESCRIPTION", "COUNTRY", "VARIETY", "PRICE", "POINTS"],
         "limit": 5
       }'
    )
  )['results'] AS results;

// Example 2 – Filter to French wines under $30
SELECT
  PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
      'WINEMAG_DESCRIPTION_SEARCH',
      '{
         "query":  "full-bodied red wine with dark fruit flavors",
         "columns": ["ID", "DESCRIPTION", "COUNTRY", "VARIETY", "PRICE", "POINTS"],
         "filter": {
           "@and": [
             { "@eq":  { "COUNTRY": "France" } },
             { "@lte": { "PRICE": 30 } }
           ]
         },
         "limit": 5
       }'
    )
  )['results'] AS results;

// Example 3 – High-scoring Pinot Noir anywhere
SELECT
  PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
      'WINEMAG_DESCRIPTION_SEARCH',
      '{
         "query":  "elegant pinot noir with silky tannins",
         "columns": ["ID", "DESCRIPTION", "COUNTRY", "VARIETY", "PRICE", "POINTS"],
         "filter": {
           "@gte": { "POINTS": 92 }
         },
         "limit": 5
       }'
    )
  )['results'] AS results;


// -------------------- Cortex Analyst --------------------
// Build a semantic view on top of your Silver tables
USE ROLE ROLE_TEAM_ROCKSTARS;
USE WAREHOUSE ANIMAL_TASK_WH;
USE DATABASE DB_TEAM_ROCKSTARS;
USE SCHEMA SILVER;

CREATE OR REPLACE SEMANTIC VIEW WINE_ANALYTICS_SV
  TABLES (
    FACT AS FACT_WINE_REVIEW
      PRIMARY KEY (REVIEW_KEY),

    WINE AS DIM_WINE
      PRIMARY KEY (WINE_KEY),

    TASTER AS DIM_TASTER
      PRIMARY KEY (TASTER_KEY),

    REGION AS DIM_REGION
      PRIMARY KEY (REGION_KEY),

    COUNTRY AS DIM_COUNTRY
      PRIMARY KEY (COUNTRY_KEY)
  )

  RELATIONSHIPS (
    FACT_TO_WINE     AS FACT(WINE_KEY)     REFERENCES WINE(WINE_KEY),
    FACT_TO_TASTER   AS FACT(TASTER_KEY)   REFERENCES TASTER(TASTER_KEY),
    FACT_TO_REGION   AS FACT(REGION_KEY)   REFERENCES REGION(REGION_KEY),
    REGION_TO_COUNTRY AS REGION(COUNTRY_KEY) REFERENCES COUNTRY(COUNTRY_KEY)
  )

  FACTS (
    FACT.PRICE   AS PRICE
      COMMENT = 'Bottle price in USD',
    FACT.POINTS  AS POINTS
      COMMENT = 'Wine rating points from the reviewer'
  )

  DIMENSIONS (
    WINE.VARIETY     AS VARIETY
      COMMENT = 'Grape variety of the wine',
    WINE.WINERY      AS WINERY
      COMMENT = 'Winery / producer',
    WINE.DESIGNATION AS DESIGNATION
      COMMENT = 'Special designation / cuvée name',

    COUNTRY.COUNTRY_NAME AS COUNTRY_NAME
      COMMENT = 'Country where the wine is produced',
    REGION.PROVINCE  AS PROVINCE
      COMMENT = 'Province / state of production',
    REGION.REGION_1  AS REGION_1,
    REGION.REGION_2  AS REGION_2
  )

METRICS (
  FACT.AVG_POINTS AS AVG(FACT.POINTS)
    COMMENT = 'Average reviewer score',

  FACT.AVG_PRICE  AS AVG(FACT.PRICE)
    COMMENT = 'Average bottle price',

  FACT.REVIEW_COUNT AS COUNT(*)
    COMMENT = 'Number of reviews'
);

SHOW SEMANTIC VIEWS IN SCHEMA SILVER;
DESCRIBE SEMANTIC VIEW WINE_ANALYTICS_SV;


------------------Add a stream to Bronze table----------------


CREATE OR REPLACE STREAM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_STREAM ON TABLE DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW;



-------------Stored procedure to update Silver with new data-------------------
CREATE OR REPLACE PROCEDURE DB_TEAM_ROCKSTARS.BRONZE.SP_LOAD_SILVER_TABLES()
RETURNS STRING
LANGUAGE JAVASCRIPT
AS
$$
    var sql_commands = [];

    // 0) Take a snapshot of the stream into a temp table (this consumes the stream ONCE)
    sql_commands.push(`
        CREATE OR REPLACE TEMP TABLE TMP_WINEMAG_STREAM AS
        SELECT *
        FROM DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_STREAM
        WHERE METADATA$ACTION = 'INSERT';
    `);

    // Load DIM_COUNTRY
    sql_commands.push(`
        MERGE INTO DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY t
        USING (
            SELECT DISTINCT
                HASH(COUNTRY) as COUNTRY_KEY,
                COUNTRY as COUNTRY_NAME
            FROM TMP_WINEMAG_STREAM
        ) s
        ON t.COUNTRY_KEY = s.COUNTRY_KEY
        WHEN NOT MATCHED THEN INSERT (COUNTRY_KEY, COUNTRY_NAME)
        VALUES (s.COUNTRY_KEY, s.COUNTRY_NAME);
    `);

    // Load DIM_REGION
    sql_commands.push(`
        MERGE INTO DB_TEAM_ROCKSTARS.SILVER.DIM_REGION t
        USING (
            SELECT DISTINCT
                HASH(PROVINCE || COALESCE(REGION_1,'') || COALESCE(REGION_2,'')) as REGION_KEY,
                HASH(COUNTRY) as COUNTRY_KEY,
                PROVINCE,
                REGION_1,
                REGION_2
            FROM TMP_WINEMAG_STREAM
        ) s
        ON t.REGION_KEY = s.REGION_KEY
        WHEN NOT MATCHED THEN INSERT (REGION_KEY, COUNTRY_KEY, PROVINCE, REGION_1, REGION_2)
        VALUES (s.REGION_KEY, s.COUNTRY_KEY, s.PROVINCE, s.REGION_1, s.REGION_2);
    `);

    // Load DIM_TASTER
    sql_commands.push(`
        MERGE INTO DB_TEAM_ROCKSTARS.SILVER.DIM_TASTER t
        USING (
            SELECT DISTINCT
                HASH(TASTER_NAME) as TASTER_KEY,
                TASTER_NAME,
                TASTER_TWITTER_HANDLE as TASTER_TWITTER
            FROM TMP_WINEMAG_STREAM
            WHERE TASTER_NAME IS NOT NULL
        ) s
        ON t.TASTER_KEY = s.TASTER_KEY
        WHEN NOT MATCHED THEN INSERT (TASTER_KEY, TASTER_NAME, TASTER_TWITTER)
        VALUES (s.TASTER_KEY, s.TASTER_NAME, s.TASTER_TWITTER);
    `);

    // Load DIM_WINE
    sql_commands.push(`
        MERGE INTO DB_TEAM_ROCKSTARS.SILVER.DIM_WINE t
        USING (
            SELECT DISTINCT
                HASH(WINERY || VARIETY || COALESCE(DESIGNATION,'')) as WINE_KEY,
                DESIGNATION,
                VARIETY,
                WINERY
            FROM TMP_WINEMAG_STREAM
        ) s
        ON t.WINE_KEY = s.WINE_KEY
        WHEN NOT MATCHED THEN INSERT (WINE_KEY, DESIGNATION, VARIETY, WINERY)
        VALUES (s.WINE_KEY, s.DESIGNATION, s.VARIETY, s.WINERY);
    `);

    // Load FACT_WINE_REVIEW
    sql_commands.push(`
        INSERT INTO DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW (
            REVIEW_KEY,
            WINE_KEY,
            TASTER_KEY,
            REGION_KEY,
            POINTS,
            PRICE,
            DESCRIPTION,
            REVIEW_TITLE
        )
        SELECT
            HASH(ID) as REVIEW_KEY,  -- if your bronze table uses ROW_ID instead of ID, change this
            HASH(WINERY || VARIETY || COALESCE(DESIGNATION,'')) as WINE_KEY,
            HASH(TASTER_NAME) as TASTER_KEY,
            HASH(PROVINCE || COALESCE(REGION_1,'') || COALESCE(REGION_2,'')) as REGION_KEY,
            POINTS,
            PRICE,
            DESCRIPTION,
            TITLE as REVIEW_TITLE
        FROM TMP_WINEMAG_STREAM;
    `);

    // (Optional) Check how many rows we processed from the stream
    sql_commands.push(`
        SELECT COUNT(*) AS ROWS_PROCESSED FROM TMP_WINEMAG_STREAM;
    `);

    // Execute all commands
    var last_result = '';
    for (var i = 0; i < sql_commands.length; i++) {
        try {
            var stmt = snowflake.createStatement({ sqlText: sql_commands[i] });
            var res = stmt.execute();
            // Capture row count from the last SELECT, if you want
            if (i === sql_commands.length - 1 && res.next()) {
                last_result = res.getColumnValue(1);
            }
        } catch (err) {
            return "Failed on statement " + i + ": " + err;
        }
    }
    
    return "Successfully processed stream data. Rows from stream snapshot: " + last_result;
$$;




//Rebuild Gold tables with new silver data

CREATE OR REPLACE PROCEDURE DB_TEAM_ROCKSTARS.SILVER.SP_LOAD_GOLD_TABLES()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    --------------------------------------------------------------------
    -- 1) PRICE_BAND_METRICS
    --------------------------------------------------------------------
    CREATE OR REPLACE TABLE DB_TEAM_ROCKSTARS.GOLD.PRICE_BAND_METRICS AS
    SELECT 
        c.COUNTRY_NAME as COUNTRY,
        CASE 
            WHEN f.PRICE <= 10 THEN '0-10'
            WHEN f.PRICE <= 20 THEN '11-20'
            WHEN f.PRICE <= 50 THEN '21-50'
            ELSE '50+'
        END as PRICE_BAND,
        AVG(f.POINTS)                    as AVG_POINTS,
        AVG(f.PRICE)                     as AVG_PRICE,
        COUNT(DISTINCT f.WINE_KEY)       as DISTINCT_WINES,
        COUNT(*)                         as REVIEW_COUNT
    FROM DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW f
    JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_REGION r
      ON f.REGION_KEY = r.REGION_KEY
    JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY c
      ON r.COUNTRY_KEY = c.COUNTRY_KEY
    GROUP BY
        c.COUNTRY_NAME,
        CASE 
            WHEN f.PRICE <= 10 THEN '0-10'
            WHEN f.PRICE <= 20 THEN '11-20'
            WHEN f.PRICE <= 50 THEN '21-50'
            ELSE '50+'
        END
    ;

    --------------------------------------------------------------------
    -- 2) WINERY_METRICS
    --------------------------------------------------------------------
    CREATE OR REPLACE TABLE DB_TEAM_ROCKSTARS.GOLD.WINERY_METRICS AS
    WITH base AS (
        SELECT 
            w.WINERY,
            c.COUNTRY_NAME as COUNTRY,
            r.PROVINCE,
            AVG(f.POINTS)                    as AVG_POINTS,
            AVG(f.PRICE)                     as AVG_PRICE,
            COUNT(DISTINCT f.WINE_KEY)       as DISTINCT_WINES,
            COUNT(*)                         as REVIEW_COUNT,
            MIN(f.POINTS)                    as MIN_POINTS,
            MAX(f.POINTS)                    as MAX_POINTS
        FROM DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW f
        JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_WINE w
          ON f.WINE_KEY = w.WINE_KEY
        JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_REGION r
          ON f.REGION_KEY = r.REGION_KEY
        JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY c
          ON r.COUNTRY_KEY = c.COUNTRY_KEY
        GROUP BY
            w.WINERY,
            c.COUNTRY_NAME,
            r.PROVINCE
    )
    SELECT
        *,
        RANK() OVER (
            PARTITION BY COUNTRY
            ORDER BY AVG_POINTS DESC, REVIEW_COUNT DESC
        ) AS RANK_IN_COUNTRY_BY_POINTS
    FROM base
    ;

    --------------------------------------------------------------------
    -- 3) TOP_WINES
    --------------------------------------------------------------------
    CREATE OR REPLACE TABLE DB_TEAM_ROCKSTARS.GOLD.TOP_WINES AS
    WITH fact_enriched AS (
        SELECT
            f.REVIEW_KEY,
            f.WINE_KEY,
            f.POINTS,
            f.PRICE,
            f.REVIEW_TITLE,
            f.DESCRIPTION,
            w.WINERY,
            w.VARIETY,
            w.DESIGNATION,
            c.COUNTRY_NAME AS COUNTRY,
            r.PROVINCE,
            CASE 
                WHEN f.PRICE <= 10 THEN '0-10'
                WHEN f.PRICE <= 20 THEN '11-20'
                WHEN f.PRICE <= 50 THEN '21-50'
                ELSE '50+'
            END AS PRICE_BAND
        FROM DB_TEAM_ROCKSTARS.SILVER.FACT_WINE_REVIEW f
        JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_WINE w
          ON f.WINE_KEY = w.WINE_KEY
        JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_REGION r
          ON f.REGION_KEY = r.REGION_KEY
        JOIN DB_TEAM_ROCKSTARS.SILVER.DIM_COUNTRY c
          ON r.COUNTRY_KEY = c.COUNTRY_KEY
    ),
    ranked AS (
        SELECT
            *,
            ROW_NUMBER() OVER (
                PARTITION BY COUNTRY, VARIETY, PRICE_BAND
                ORDER BY POINTS DESC, PRICE ASC
            ) AS RANK_WITHIN_BUCKET
        FROM fact_enriched
        WHERE POINTS IS NOT NULL
          AND PRICE IS NOT NULL
          AND POINTS >= 90
    )
    SELECT
        REVIEW_KEY,
        WINE_KEY,
        REVIEW_TITLE,
        DESCRIPTION,
        WINERY,
        VARIETY,
        DESIGNATION,
        COUNTRY,
        PROVINCE,
        PRICE,
        POINTS,
        PRICE_BAND,
        RANK_WITHIN_BUCKET
    FROM ranked
    WHERE RANK_WITHIN_BUCKET <= 10
    ;

    RETURN 'Gold tables rebuilt successfully';
END;
$$;


-------------Create Auto Ingest Pipe-----------------
USE SCHEMA BRONZE;

CREATE OR REPLACE PIPE DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_PIPE
AUTO_INGEST = TRUE
AS
COPY INTO DB_TEAM_ROCKSTARS.BRONZE.WINEMAG_BRONZE_RAW
FROM @DB_TEAM_ROCKSTARS.BRONZE.CSV_STAGE
FILE_FORMAT = DB_TEAM_ROCKSTARS.BRONZE.CSV_FORMAT;

---------------Run stored procedures to populate Silver/Gold tables------------------
CALL DB_TEAM_ROCKSTARS.BRONZE.SP_LOAD_SILVER_TABLES();
CALL DB_TEAM_ROCKSTARS.SILVER.SP_LOAD_GOLD_TABLES();





