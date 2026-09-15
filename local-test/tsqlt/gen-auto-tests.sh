#!/usr/bin/env bash
# =============================================================================
# gen-auto-tests.sh — auto-generate tSQLt CONTRACT tests for EVERY procedure/function
# in a database, with NO human-written assertions. Two tiers, both derived purely from
# catalog metadata (no execution of the target object, no data touched):
#
#   Tier 0  Signature contract  — asserts the parameter list (id:name:type:direction)
#                                  is unchanged vs the committed baseline. 100% of objects.
#   Tier 1  Result-set contract — asserts the first result set's columns (ordinal:name:
#                                  type:nullability) are unchanged. ~3/4 of procs expose one
#                                  statically (sys.dm_exec_describe_first_result_set_for_object).
#
# The baseline is EMBEDDED as a literal in each generated test; the test recomputes the live
# value with the SAME SQL expression and AssertEqualsString's them. "Update the baseline" is
# therefore a visible git diff in the test file, reviewed on the PR — characterization/golden-
# master style, zero hand-written assertions.
#
# One set-based query per DB emits every object's baseline at once (not one round-trip each),
# so this runs over ~1400 objects in seconds.
#
#   gen-auto-tests.sh <DB> [--schema <name>] [--out <dir>]
#     DB       database to introspect (e.g. AppDb_Dev / AppDb_MSG_Data_Dev)
#     --schema limit to one schema (validation); default = all user schemas
#     --out    output root (default tests/contract)
#   Env: SERVER PORT SA_PASSWORD SQLCMD_ENC (as coverage.sh / gen-starter-tests.sh)
# =============================================================================
set -uo pipefail

SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
OUT_ROOT="${OUT_ROOT:-tests/contract}"

DB="${1:?usage: gen-auto-tests.sh <DB> [--schema <name>] [--out <dir>]}"; shift
SCHEMA_FILTER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --schema) shift; SCHEMA_FILTER="${1:?--schema needs a name}" ;;
    --out)    shift; OUT_ROOT="${1:?--out needs a dir}" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "gen-auto-tests: sqlcmd not found" >&2; exit 2; }

# --- canonical baseline expressions -----------------------------------------------------
# %OID% is replaced with the object-id reference: `o.object_id` in the bulk gen query,
# `OBJECT_ID('sch.obj')` inside the generated test. Both must yield an identical string.
# COLLATE DATABASE_DEFAULT on every sysname/catalog string: catalog columns are
# Latin1_General_CI_AS_KS_WS, the DB default is SQL_Latin1_General_CP1_CI_AS, and concatenating
# them without coercion raises "Cannot resolve collation conflict".
SIG_EXPR="(SELECT ISNULL(STRING_AGG(
    CAST(p.parameter_id AS varchar(6))+':'+(p.name COLLATE DATABASE_DEFAULT)+':'+
    (CASE WHEN ty.name IN ('varchar','char','varbinary','binary') THEN (ty.name COLLATE DATABASE_DEFAULT)+'('+IIF(p.max_length=-1,'max',CAST(p.max_length AS varchar(10)))+')'
          WHEN ty.name IN ('nvarchar','nchar') THEN (ty.name COLLATE DATABASE_DEFAULT)+'('+IIF(p.max_length=-1,'max',CAST(p.max_length/2 AS varchar(10)))+')'
          WHEN ty.name IN ('decimal','numeric') THEN (ty.name COLLATE DATABASE_DEFAULT)+'('+CAST(p.precision AS varchar(10))+','+CAST(p.scale AS varchar(10))+')'
          ELSE (ty.name COLLATE DATABASE_DEFAULT) END)+':'+CAST(p.is_output AS char(1)),
    '|') WITHIN GROUP (ORDER BY p.parameter_id), '')
  FROM sys.parameters p JOIN sys.types ty ON ty.user_type_id=p.user_type_id
  WHERE p.object_id=%OID% AND p.parameter_id>=0)"

RS_EXPR="(SELECT ISNULL(STRING_AGG(
    CAST(r.column_ordinal AS varchar(6))+':'+ISNULL(r.name COLLATE DATABASE_DEFAULT,'(noname)')+':'+(r.system_type_name COLLATE DATABASE_DEFAULT)+':'+CAST(r.is_nullable AS char(1)),
    '|') WITHIN GROUP (ORDER BY r.column_ordinal), '')
  FROM sys.dm_exec_describe_first_result_set_for_object(%OID%, 0) r
  WHERE r.error_number IS NULL AND ISNULL(r.is_hidden,0)=0)"

sig_bulk="${SIG_EXPR//%OID%/o.object_id}"
rs_bulk="${RS_EXPR//%OID%/o.object_id}"

sql() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -h -1 -y 8000 -d "$DB" -Q "SET NOCOUNT ON; $1" 2>/dev/null; }

schema_pred=""
[ -n "$SCHEMA_FILTER" ] && schema_pred="AND s.name = '$(printf %s "$SCHEMA_FILTER" | sed "s/'/''/g")'"

echo "==> Introspecting [$DB] ${SCHEMA_FILTER:+schema=$SCHEMA_FILTER }for contract baselines ..."
# One row per object:  sch ~|~ obj ~|~ type_desc ~|~ signature ~|~ resultset
rows="$(sql "
SELECT (s.name COLLATE DATABASE_DEFAULT)+'~|~'+(o.name COLLATE DATABASE_DEFAULT)+'~|~'+(o.type_desc COLLATE DATABASE_DEFAULT)+'~|~'+ $sig_bulk +'~|~'+ $rs_bulk
FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
WHERE o.type IN ('P','FN','IF','TF') AND o.is_ms_shipped=0
  -- exclude tSQLt itself and any tSQLt test class (schemas: tSQLt, test_*; and our own
  -- generated contract classes test_contract_*), so we never generate tests-of-tests.
  AND s.name <> 'tSQLt' AND s.name NOT LIKE 'test[_]%' AND s.name NOT LIKE 'tSQLt[_]%'
  AND o.name NOT LIKE 'test[_]%' $schema_pred
ORDER BY s.name, o.name;")"

[ -n "$rows" ] || { echo "  no objects found (schema filter? empty DB?)"; exit 1; }

emitted=0; sig_only=0; with_rs=0; trunc=0; schemas=0; prev_sch=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  sch="${line%%~|~*}";        rest="${line#*~|~}"
  obj="${rest%%~|~*}";        rest="${rest#*~|~}"
  tdesc="${rest%%~|~*}";      rest="${rest#*~|~}"
  sig="${rest%%~|~*}";        rs="${rest#*~|~}"
  # trim trailing sqlcmd padding
  sig="${sig%"${sig##*[![:space:]]}"}"; rs="${rs%"${rs##*[![:space:]]}"}"
  # truncation guard (sqlcmd -y 8000)
  if [ "${#sig}" -ge 7999 ] || [ "${#rs}" -ge 7999 ]; then
    echo "  ! $sch.$obj: baseline near 8000-char cap — skipped (raise -y / split)"; trunc=$((trunc+1)); continue
  fi
  esc_sig="${sig//\'/\'\'}"; esc_rs="${rs//\'/\'\'}"
  sig_test="${SIG_EXPR//%OID%/OBJECT_ID(\'$sch.$obj\')}"
  rs_test="${RS_EXPR//%OID%/OBJECT_ID(\'$sch.$obj\')}"
  cls="test_contract_${sch}_${obj}"
  # One file per SCHEMA (rows are ORDER BY schema, so a schema's objects are contiguous):
  # start a fresh file with a header when the schema changes, then append each object's class.
  if [ "$sch" != "$prev_sch" ]; then
    mkdir -p "$OUT_ROOT"; outfile="$OUT_ROOT/${sch}.sql"
    {
      echo "-- AUTO-GENERATED contract tests for schema '$sch' ($DB). DO NOT EDIT BY HAND."
      echo "-- One tSQLt class per object; baselines embedded. Regenerate with"
      echo "-- local-test/tsqlt/gen-auto-tests.sh (an intended change is a reviewable diff)."
      echo "-- ============================================================================="
    } > "$outfile"
    prev_sch="$sch"; schemas=$((schemas+1))
  fi
  {
    echo ""
    echo "-- $sch.$obj ($tdesc)"
    echo "IF SCHEMA_ID('$cls') IS NOT NULL EXEC tSQLt.DropClass '$cls';"
    echo "GO"
    echo "EXEC tSQLt.NewTestClass '$cls';"
    echo "GO"
    echo "CREATE PROCEDURE $cls.[test parameter signature unchanged] AS"
    echo "BEGIN"
    echo "    DECLARE @expected nvarchar(max) = N'$esc_sig';"
    echo "    DECLARE @actual   nvarchar(max) = $sig_test;"
    echo "    EXEC tSQLt.AssertEqualsString @Expected=@expected, @Actual=@actual,"
    echo "        @Message='Parameter signature of $sch.$obj changed vs the committed baseline (id:name:type:isOutput). If intended, regenerate the baseline.';"
    echo "END"
    echo "GO"
    if [ -n "$rs" ]; then
      echo "CREATE PROCEDURE $cls.[test result-set contract unchanged] AS"
      echo "BEGIN"
      echo "    DECLARE @expected nvarchar(max) = N'$esc_rs';"
      echo "    DECLARE @actual   nvarchar(max) = $rs_test;"
      echo "    EXEC tSQLt.AssertEqualsString @Expected=@expected, @Actual=@actual,"
      echo "        @Message='First result-set of $sch.$obj changed vs the committed baseline (ordinal:name:type:nullable). If intended, regenerate the baseline.';"
      echo "END"
      echo "GO"
      with_rs=$((with_rs+1))
    else
      sig_only=$((sig_only+1))
    fi
  } >> "$outfile"
  emitted=$((emitted+1))
done <<< "$rows"

echo "Done: $emitted objects in $schemas schema file(s) -> $OUT_ROOT/  (with result-set contract: $with_rs, signature-only: $sig_only, skipped-truncated: $trunc)"
