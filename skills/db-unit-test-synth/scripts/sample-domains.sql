-- sample-domains.sql — return the DISTINCT domain of low-cardinality, NON-sensitive columns
-- for one table, so generated seeds use REAL enum/status/category values.
--
-- SAFE BY CONSTRUCTION:
--   * Self-guards: does nothing unless the current DB is READ_ONLY (a secondary replica).
--     In the primary region that is region1-node1. Pointed at a primary it RAISERRORs and returns no rows.
--   * READ UNCOMMITTED + LOCK_TIMEOUT 3000  -> never blocks production.
--   * Only columns whose name passes config/sensitive.deny AND COUNT(DISTINCT) <= @MaxCardinality.
--   * Returns DISTINCT VALUE LISTS only — never a full/joined row, so no record is reconstructed.
--
-- Run via MCP:  mcp__appdb-sql__execute_query  instance_name="region1-node1"
--   Replace @Schema/@Table before running; @NameDeny is the regex from config/sensitive.deny,
--   applied here as a LIKE-lowered guard on obviously-sensitive tokens (belt-and-braces; the
--   skill also filters column names against the full regex before it ever calls this).
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 3000;

DECLARE @Schema sysname = N'route';
DECLARE @Table  sysname = N'PlanCoverage';
DECLARE @MaxCardinality int = 50;
DECLARE @Top int = 50;

-- HARD GUARD: refuse on anything that is not a read-only replica.
IF DATABASEPROPERTYEX(DB_NAME(), 'Updateability') <> N'READ_ONLY'
BEGIN
    RAISERROR('REFUSED: %s is not READ_ONLY — point this at a read-only secondary (e.g. region1-node1).', 16, 1, @@SERVERNAME);
    RETURN;
END;

DECLARE @oid int = OBJECT_ID(QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table));
IF @oid IS NULL BEGIN RAISERROR('table not found', 16, 1); RETURN; END;

-- Candidate columns: discrete types, name not obviously sensitive (coarse token guard; the skill
-- pre-filters with the full regex). Free-text (max/xml), identity, computed, and long strings excluded.
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = STRING_AGG(CAST(
        N'SELECT ' + QUOTENAME(c.name, '''') + N' AS column_name, CAST(x AS nvarchar(100)) AS value, COUNT(*) AS freq FROM (' +
        N'SELECT TOP (' + CAST(@Top AS nvarchar(10)) + N') ' + QUOTENAME(c.name) + N' AS x, COUNT(*) AS c ' +
        N'FROM ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table) + N' WITH (READUNCOMMITTED) ' +
        N'GROUP BY ' + QUOTENAME(c.name) + N' HAVING COUNT(DISTINCT ' + QUOTENAME(c.name) + N') OVER () <= ' + CAST(@MaxCardinality AS nvarchar(10)) +
        N') q CROSS APPLY (SELECT c AS freq) f' AS nvarchar(max)), N' UNION ALL ')
FROM sys.columns c
JOIN sys.types  t ON t.user_type_id = c.user_type_id
WHERE c.object_id = @oid
  AND c.is_computed = 0 AND c.is_identity = 0
  AND t.name IN ('tinyint','smallint','int','bigint','bit','char','nchar','varchar','nvarchar','date','smalldatetime')
  AND (c.max_length BETWEEN 1 AND 64 OR t.name IN ('tinyint','smallint','int','bigint','bit','date','smalldatetime'))
  -- coarse sensitive-token guard (the skill applies the full config/sensitive.deny regex upstream)
  AND LOWER(c.name) NOT LIKE '%msg%'     AND LOWER(c.name) NOT LIKE '%body%'
  AND LOWER(c.name) NOT LIKE '%content%' AND LOWER(c.name) NOT LIKE '%text%'
  AND LOWER(c.name) NOT LIKE '%phone%'   AND LOWER(c.name) NOT LIKE '%mobile%'
  AND LOWER(c.name) NOT LIKE '%msisdn%'  AND LOWER(c.name) NOT LIKE '%email%'
  AND LOWER(c.name) NOT LIKE '%name%'    AND LOWER(c.name) NOT LIKE '%addr%'
  AND LOWER(c.name) NOT LIKE '%token%'   AND LOWER(c.name) NOT LIKE '%secret%'
  AND LOWER(c.name) NOT LIKE '%key%'     AND LOWER(c.name) NOT LIKE '%pwd%'
  AND LOWER(c.name) NOT LIKE '%password%';

IF @sql IS NULL OR @sql = N''
BEGIN
    SELECT CAST(NULL AS nvarchar(100)) AS column_name, CAST(NULL AS nvarchar(100)) AS value, CAST(NULL AS int) AS freq
    WHERE 1 = 0;   -- no eligible columns
    RETURN;
END;

EXEC sys.sp_executesql @sql;
