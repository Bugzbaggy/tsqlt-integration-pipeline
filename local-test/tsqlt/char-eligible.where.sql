-- =============================================================================
-- char-eligible.where.sql - the ONE definition of "can this object have a characterization
-- baseline at all?". A boolean predicate, meant to be inlined by the caller as:
--
--     FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
--     CROSS APPLY (SELECT def = OBJECT_DEFINITION(o.object_id)) d2
--     WHERE (
--       <this file>
--     )
--
-- Callers must provide exactly those aliases: o (sys.objects), s (sys.schemas), d2.def
-- (the object definition). Add a schema filter AFTER the closing paren, not inside.
--
-- Shared by gen-characterization-tests.sh (which objects to GENERATE for) and
-- run-characterization-tests.sh (which objects it is fair to report as "no baseline yet").
-- They must not drift: if the runner treats more objects as eligible than the generator can
-- emit for, every changed stored procedure gets flagged as missing a baseline that no command
-- can produce - a permanent warning on nearly every PR.
--
-- NOTE: deliberately NOT OBJECTPROPERTY(id, IsDeterministic) - SQL Server only sets that for
-- WITH SCHEMABINDING functions, so it wrongly excludes the many pure-but-not-schemabound
-- utility functions this suite is for. No apostrophes in these comments on purpose: sqlcmd
-- has been seen to mis-parse a multi-line batch that carries them.
-- =============================================================================
o.type='FN' AND o.is_ms_shipped=0
AND s.name NOT LIKE 'test[_]%' AND s.name<>'tSQLt'
-- Every dependency must be a same-DB TABLE (type U) so tSQLt.FakeTable can isolate the
-- function completely. 0 U-deps => pure function (slice 2a); >=1 U-dep => seeded (slice 2b).
-- A dependency on a view/proc/other-function or a cross-DB object is out of scope (its reads
-- can't be faked deterministically) and excludes the function.
AND NOT EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d
                LEFT JOIN sys.objects ro ON ro.object_id=d.referenced_id
                WHERE d.referencing_id=o.object_id
                  AND (d.referenced_database_name IS NOT NULL OR ro.object_id IS NULL OR ro.type<>'U'))
-- no non-deterministic built-ins
AND d2.def NOT LIKE '%GETDATE%'      AND d2.def NOT LIKE '%NEWID%'
AND d2.def NOT LIKE '%RAND(%'        AND d2.def NOT LIKE '%SYSDATETIME%'
AND d2.def NOT LIKE '%SYSUTCDATETIME%' AND d2.def NOT LIKE '%GETUTCDATE%'
AND d2.def NOT LIKE '%CURRENT_TIMESTAMP%' AND d2.def NOT LIKE '%NEWSEQUENTIALID%'
