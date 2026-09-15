#!/usr/bin/env bash
# introspect.sh — capture the structural fixture for one object as a single JSON document.
# STRUCTURE ONLY: signature, dependency tables, columns, FK closure, CHECK constraints, definition.
# Runs against ANY DB that has the schema (CI throwaway DB or a local db-up container) — it never
# needs production. Claude fills the empty "branches" array by reading "definition".
#
# Usage:  SERVER=localhost PORT=1433 SA_PASSWORD=... DB=AppDb_Dev \
#           bash introspect.sh rt.fnSubAccountRoutingGroup > fixture.json
#
# Env matches the other generators: SERVER PORT SA_PASSWORD SQLCMD_ENC DB.
set -euo pipefail

OBJ="${1:?usage: introspect.sh schema.object}"
SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
DB="${DB:?DB must be set (e.g. AppDb_Dev or AppDb_MSG_Data_Dev)}"

# The object and database names are interpolated into the T-SQL below, so constrain them to
# plain identifiers. Without this, a name containing a single quote breaks out of the N'...'
# literal and the injected statement EXECUTES (verified). UA_OBJECTS is derived from changed
# file paths, and this script is also documented for use against a read-only PRODUCTION
# secondary, so make injection impossible rather than merely unlikely.
printf '%s' "$OBJ" | grep -qE '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$' || {
  echo "introspect.sh: refusing unsafe object name '$OBJ' — expected plain schema.object" >&2; exit 2; }
printf '%s' "$DB" | grep -qE '^[A-Za-z0-9_]+$' || {
  echo "introspect.sh: refusing unsafe database name '$DB' — expected a plain identifier" >&2; exit 2; }

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "introspect.sh: sqlcmd not found" >&2; exit 2; }

read -r -d '' SQL <<SQLEOF || true
SET NOCOUNT ON;
DECLARE @obj sysname = N'${OBJ}';
DECLARE @oid int = OBJECT_ID(@obj);
DECLARE @db  sysname = DB_NAME();
IF @oid IS NULL BEGIN RAISERROR('object %s not found in %s', 16, 1, @obj, @db); RETURN; END;

-- Base tables this object reads/writes (what to FakeTable). Wrapped: unresolved refs can throw.
CREATE TABLE #refs (ref_id int PRIMARY KEY);
BEGIN TRY
    INSERT #refs (ref_id)
    SELECT DISTINCT referenced_id
    FROM sys.dm_sql_referenced_entities(@obj, 'OBJECT')
    WHERE referenced_minor_id = 0 AND referenced_id IS NOT NULL
      AND referenced_id IN (SELECT object_id FROM sys.objects WHERE type = 'U');
END TRY BEGIN CATCH END CATCH;

DECLARE @json nvarchar(max) = (
SELECT
    [object]     = @obj,
    [db]         = @db,
    [type]       = (SELECT type_desc FROM sys.objects WHERE object_id = @oid),
    [signature]  = (SELECT p.name,
                           [type]      = TYPE_NAME(p.user_type_id),
                           p.max_length, p.precision, p.scale,
                           [is_output] = p.is_output
                    FROM sys.parameters p WHERE p.object_id = @oid AND p.parameter_id > 0
                    ORDER BY p.parameter_id FOR JSON PATH),
    [fake]       = (SELECT OBJECT_SCHEMA_NAME(r.ref_id) AS [schema], OBJECT_NAME(r.ref_id) AS [table]
                    FROM #refs r FOR JSON PATH),
    [tables]     = (SELECT
                        [schema]  = OBJECT_SCHEMA_NAME(r.ref_id),
                        [table]   = OBJECT_NAME(r.ref_id),
                        [columns] = (SELECT c.name,
                                            [type]        = TYPE_NAME(c.user_type_id),
                                            c.max_length, c.precision, c.scale,
                                            [is_nullable] = c.is_nullable,
                                            [is_identity] = c.is_identity,
                                            [is_computed] = c.is_computed,
                                            [default_def] = dc.definition
                                     FROM sys.columns c
                                     LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
                                     WHERE c.object_id = r.ref_id
                                     ORDER BY c.column_id FOR JSON PATH)
                    FROM #refs r FOR JSON PATH),
    [fk_closure] = (SELECT fk.name,
                           [child_schema]  = OBJECT_SCHEMA_NAME(fk.parent_object_id),
                           [child]         = OBJECT_NAME(fk.parent_object_id),
                           [parent_schema] = OBJECT_SCHEMA_NAME(fk.referenced_object_id),
                           [parent]        = OBJECT_NAME(fk.referenced_object_id)
                    FROM sys.foreign_keys fk
                    WHERE fk.parent_object_id IN (SELECT ref_id FROM #refs) FOR JSON PATH),
    [checks]     = (SELECT cc.name,
                           [tbl_schema] = OBJECT_SCHEMA_NAME(cc.parent_object_id),
                           [tbl]        = OBJECT_NAME(cc.parent_object_id),
                           cc.definition
                    FROM sys.check_constraints cc
                    WHERE cc.parent_object_id IN (SELECT ref_id FROM #refs) FOR JSON PATH),
    [definition] = OBJECT_DEFINITION(@oid),
    [branches]   = JSON_QUERY('[]')
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
-- base64 the UTF-16LE bytes, then hand it out in FIXED 2000-char rows (a multiple of 4) so the
-- fragments stay byte-aligned when concatenated. (Raw FOR JSON chunks at 2033 chars mid-token and
-- its fragments contain real spaces; base64 in 4-aligned rows reconstructs losslessly.)
DECLARE @bin varbinary(max) = CAST(@json AS varbinary(max));
DECLARE @b64 varchar(max) = CAST('' AS xml).value('xs:base64Binary(sql:variable("@bin"))', 'varchar(max)');
WITH n AS (
    SELECT 1 AS i
    UNION ALL SELECT i + 1 FROM n WHERE i < (LEN(@b64) / 2000) + 1
)
SELECT SUBSTRING(@b64, (i - 1) * 2000 + 1, 2000) AS chunk
FROM n ORDER BY i OPTION (MAXRECURSION 0);
SQLEOF

# Run once, keeping the raw output so a SQL error can be reported as itself. Without this the
# RAISERROR text ("object X not found in Y") would be fed to base64, and the only thing reaching
# the caller's log would be the useless "base64: invalid input".
raw="$("$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -h -1 -y 2100 -d "$DB" -Q "$SQL" 2>&1)"
if printf '%s\n' "$raw" | grep -qE '^(Msg [0-9]+,|Sqlcmd:|HResult )'; then
  # Surface the server's own message (the "Msg NNNNN, Level..." line plus the text under it).
  printf 'introspect.sh: %s in %s failed:\n%s\n' "$OBJ" "$DB" \
    "$(printf '%s\n' "$raw" | grep -vE '^\s*$' | head -4 | sed 's/^/  /')" >&2
  exit 3
fi

# Reconstruct: strip ALL whitespace (base64 is whitespace-insensitive), decode base64 -> UTF-16LE
# bytes -> UTF-8 JSON. Prefer iconv; fall back to node if iconv is absent.
b64="$(printf '%s' "$raw" | tr -d ' \t\r\n')"
[ -n "$b64" ] || { echo "introspect.sh: $OBJ in $DB returned no rows (object not found or no permission)" >&2; exit 3; }
if command -v iconv >/dev/null 2>&1; then
  printf '%s' "$b64" | base64 -d | iconv -f UTF-16LE -t UTF-8
else
  printf '%s' "$b64" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(Buffer.from(s.trim(),"base64").toString("utf16le")))'
fi
echo
