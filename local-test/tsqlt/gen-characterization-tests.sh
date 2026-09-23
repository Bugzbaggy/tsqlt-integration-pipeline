#!/usr/bin/env bash
# =============================================================================
# gen-characterization-tests.sh — Tier 2 (behavioural) auto-tests, slice 2a:
# DETERMINISTIC SCALAR FUNCTIONS. For each such function it calls the function with a fixed,
# representative input tuple, captures the output, and embeds it as a baseline in a tSQLt test
# that re-calls the function and asserts the same output. NO hand-written assertions.
#
# Gate: OBJECTPROPERTY(id,'IsDeterministic')=1. A deterministic scalar function's output is,
# by SQL Server's own definition, a pure function of its inputs (no table reads, no GETDATE/
# NEWID/RAND) — exactly what makes a golden-master baseline stable. Non-deterministic and
# table-reading functions are skipped here (slice 2b, seeded, comes later).
#
# Characterization catches a BEHAVIOUR change (the output for a fixed input differs) the way
# Tier 1 catches an INTERFACE change. An intended change -> RED -> regenerate the baseline.
#
#   gen-characterization-tests.sh <DB> [--schema <name>] [--out <dir>]
#   Env: SERVER PORT SA_PASSWORD SQLCMD_ENC   (as gen-auto-tests.sh)
#
# REQUIRES tSQLt installed in <DB> before running: slice 2b captures a table-reading
# function's output inside a rolled-back transaction using tSQLt.FakeTable, so tSQLt must be
# present (run local-test/unitautogen/fetch-deps.sh + load PrepareServer.sql + tSQLt.class.sql).
# =============================================================================
set -uo pipefail

SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
OUT_ROOT="${OUT_ROOT:-tests/characterization}"

DB="${1:?usage: gen-characterization-tests.sh <DB> [--schema <name>] [--out <dir>]}"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
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
[ -n "$SQLCMD" ] || { echo "gen-characterization-tests: sqlcmd not found" >&2; exit 2; }
# NOTE the </dev/null: sqlcmd inherits this shell stdin, and when the caller is a
# `while read ... done <<< "$list"` loop (a seekable temp file), it REWINDS that file - the loop
# then restarts at line 1 forever, appending the same test to the output file until the build
# times out. Observed live. The outer loops also read on FD 9 for the same reason.
q() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -h -1 -y 8000 -d "$DB" -Q "SET NOCOUNT ON; $1" 2>/dev/null </dev/null | sed -e 's/[[:space:]]*$//'; }

# A fixed, type-appropriate literal per parameter (positional, ordered) — the representative
# input tuple. Same expression is used to build the call at gen time and inside the test, so
# they are identical by construction.
INPUT_EXPR="(SELECT STRING_AGG(CASE
     WHEN t.name IN ('bigint','int','smallint','tinyint') THEN '1'
     WHEN t.name='bit' THEN '0'
     WHEN t.name IN ('decimal','numeric','money','smallmoney') THEN '1'
     WHEN t.name IN ('float','real') THEN '1'
     WHEN t.name IN ('char','varchar','nchar','nvarchar') THEN '''A'''
     WHEN t.name='date' THEN '''2020-01-15'''
     WHEN t.name IN ('datetime','datetime2','smalldatetime') THEN '''2020-01-15T10:30:00'''
     WHEN t.name='datetimeoffset' THEN '''2020-01-15T10:30:00+00:00'''
     WHEN t.name='time' THEN '''10:30:00'''
     WHEN t.name='uniqueidentifier' THEN '''00000000-0000-0000-0000-000000000001'''
     WHEN t.name IN ('binary','varbinary') THEN '0x01'
     ELSE 'NULL' END, ', ') WITHIN GROUP (ORDER BY p.parameter_id)
   FROM sys.parameters p JOIN sys.types t ON t.user_type_id=p.user_type_id
   WHERE p.object_id=OBJECT_ID(@FQ) AND p.parameter_id>0)"

# Slice 2b: type-matched column value for seeding a faked dependency table - the SAME type->value
# map as INPUT_EXPR, so a `WHERE col = @param` filter matches (proven on core.fnGetAccountUid). Bit
# seeds 0 to satisfy the common `Deleted = 0` soft-delete filter.
COLVAL="CASE WHEN t.name IN ('bigint','int','smallint','tinyint') THEN '1'
     WHEN t.name='bit' THEN '0'
     WHEN t.name IN ('decimal','numeric','money','smallmoney') THEN '1'
     WHEN t.name IN ('float','real') THEN '1'
     WHEN t.name IN ('char','varchar','nchar','nvarchar') THEN '''A'''
     WHEN t.name='date' THEN '''2020-01-15'''
     WHEN t.name IN ('datetime','datetime2','smalldatetime') THEN '''2020-01-15T10:30:00'''
     WHEN t.name='datetimeoffset' THEN '''2020-01-15T10:30:00+00:00'''
     WHEN t.name='time' THEN '''10:30:00'''
     WHEN t.name='uniqueidentifier' THEN '''00000000-0000-0000-0000-000000000001'''
     WHEN t.name IN ('binary','varbinary') THEN '0x01'
     ELSE 'NULL' END"

schema_pred=""
[ -n "$SCHEMA_FILTER" ] && schema_pred="AND s.name = '$(printf %s "$SCHEMA_FILTER" | sed "s/'/''/g")'"

# Determinism gate: a scalar function whose output is a pure function of its inputs - no
# table/view reads (data could change) and no non-deterministic built-ins. The predicate itself
# lives in char-eligible.where.sql because run-characterization-tests.sh has to ask the SAME
# question (is this object eligible for a baseline at all?) before it may report an object as
# "no baseline yet" - two copies of it would drift and turn every changed stored procedure into
# a permanent warning.
ELIG_WHERE="$(cat "$HERE/char-eligible.where.sql")"
[ -n "$ELIG_WHERE" ] || { echo "ERROR: char-eligible.where.sql missing or empty next to this script." >&2; exit 2; }
echo "==> [$DB] finding deterministic scalar functions ${SCHEMA_FILTER:+(schema=$SCHEMA_FILTER) }..."
# Through a FILE, not -Q. sqlcmd mis-parses a multi-line -Q batch that carries SQL comments, and
# q() swallows stderr, so the failure would surface as the far more plausible-looking "no
# deterministic scalar functions found" rather than as an error.
elig_q="$(mktemp)"
cat > "$elig_q" <<SQL
SET NOCOUNT ON;
SELECT (s.name COLLATE DATABASE_DEFAULT)+'~|~'+(o.name COLLATE DATABASE_DEFAULT)
FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
CROSS APPLY (SELECT def = OBJECT_DEFINITION(o.object_id)) d2
WHERE (
$ELIG_WHERE
) $schema_pred
ORDER BY s.name, o.name;
SQL
fns="$("$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b -h -1 -y 8000 -d "$DB" -i "$elig_q" | sed -e 's/[[:space:]]*$//')"
gen_rc=$?   # pipefail is on (see set -o above), so this is sqlcmd, not sed
rm -f "$elig_q"
[ "$gen_rc" -eq 0 ] || { echo "ERROR: [$DB] eligibility query failed (sqlcmd exit $gen_rc)." >&2; exit 2; }

[ -n "$fns" ] || { echo "  no deterministic scalar functions found."; exit 0; }

emitted=0; skipped=0; seeded=0; schemas=0; prev_sch=""
while IFS= read -r line <&9; do
  [ -z "$line" ] && continue
  sch="${line%%~|~*}"; obj="${line##*~|~}"
  fqlit="'$sch.$obj'"
  inputs="$(q "SELECT ${INPUT_EXPR//@FQ/$fqlit};")"
  inputs="${inputs%"${inputs##*[![:space:]]}"}"
  # A 0-parameter function -> STRING_AGG returns SQL NULL (printed 'NULL') -> call it with no
  # args: fn(), not fn(NULL).
  [ "$inputs" = "NULL" ] && inputs=""

  # Dependency tables to fake + seed (slice 2b). Empty => pure function (slice 2a).
  deps="$(q "SELECT STRING_AGG((ISNULL(d.referenced_schema_name,'dbo')+'.'+d.referenced_entity_name) COLLATE DATABASE_DEFAULT, '~')
             FROM sys.sql_expression_dependencies d JOIN sys.objects ro ON ro.object_id=d.referenced_id AND ro.type='U'
             WHERE d.referencing_id=OBJECT_ID($fqlit)")"
  deps="${deps%"${deps##*[![:space:]]}"}"
  # STRING_AGG over no rows returns SQL NULL, which sqlcmd prints as the literal 'NULL' — that
  # means a pure function (no table deps = slice 2a), NOT a dependency named NULL.
  [ "$deps" = "NULL" ] && deps=""

  fake=""; seed=""
  if [ -n "$deps" ]; then
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      fake+="    EXEC tSQLt.FakeTable '$dep';"$'\n'
      # Bracket the table name (QUOTENAME/PARSENAME) so a reserved-word table like cfg.[User] is
      # valid in the INSERT; columns are already bracketed via QUOTENAME(c.name).
      ins="$(q "SELECT 'INSERT '+QUOTENAME(PARSENAME('$dep',2))+'.'+QUOTENAME(PARSENAME('$dep',1))+' ('+STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT),', ')+') VALUES ('+STRING_AGG($COLVAL,', ')+');'
                FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
                WHERE c.object_id=OBJECT_ID('$dep') AND c.is_computed=0 AND t.name<>'timestamp'")"
      ins="${ins%"${ins##*[![:space:]]}"}"
      seed+="    $ins"$'\n'
    done <<< "${deps//\~/$'\n'}"
  fi

  # Capture the output for the representative input. For a seeded (2b) fn, do it inside a
  # rolled-back transaction with the fakes+seed in place.
  if [ -n "$deps" ]; then
    captured="$(q "BEGIN TRAN;
BEGIN TRY
${fake}${seed}SELECT ISNULL(CONVERT(nvarchar(max), $sch.$obj($inputs)), '<<NULL>>');
END TRY BEGIN CATCH SELECT '<<ERR>>'; END CATCH;
ROLLBACK;")"
  else
    captured="$(q "BEGIN TRY SELECT ISNULL(CONVERT(nvarchar(max), $sch.$obj($inputs)), '<<NULL>>'); END TRY BEGIN CATCH SELECT '<<ERR>>'; END CATCH")"
  fi
  captured="${captured%"${captured##*[![:space:]]}"}"

  # Grade honestly: skip errors always; for a SEEDED fn also skip a NULL result (the generic
  # seed did not reach a meaningful branch -> needs a tailored/curated seed).
  if [ "$captured" = "<<ERR>>" ] || [ -z "$captured" ]; then
    echo "  ~ $sch.$obj: did not evaluate - skipped (needs a tailored input/seed; curated)"; skipped=$((skipped+1)); continue
  fi
  if [ -n "$deps" ] && [ "$captured" = "<<NULL>>" ]; then
    echo "  ~ $sch.$obj: seeded call returned NULL - skipped (generic seed missed; curated)"; skipped=$((skipped+1)); continue
  fi
  # A BATCH-level error (a compile error - e.g. a generated seed that does not compile) is not
  # caught by the TRY/CATCH above: sqlcmd prints the message on stdout, so it would be embedded
  # as the golden value and the test would pass for ever while the function is unreachable.
  # Observed live on msg.fnMessageSegments. Refuse it the same way as <<ERR>>.
  case "$captured" in
    "Msg "[0-9]*", Level "*|*"Incorrect syntax near"*)
      echo "  ~ $sch.$obj: call raised a batch error - skipped (would have pinned the error text as the baseline)"
      skipped=$((skipped+1)); continue ;;
  esac
  esc="${captured//\'/\'\'}"
  cls="test_char_${sch}_${obj}"
  # One file per SCHEMA (fns are ORDER BY schema): fresh header on schema change, then append.
  if [ "$sch" != "$prev_sch" ]; then
    mkdir -p "$OUT_ROOT"; outfile="$OUT_ROOT/${sch}.sql"
    {
      echo "-- AUTO-GENERATED characterization tests (Tier 2) for schema '$sch' ($DB). DO NOT EDIT BY HAND."
      echo "-- One tSQLt class per deterministic scalar function; output baselines embedded (2b tests"
      echo "-- fake + seed the dependency tables). Regenerate with local-test/tsqlt/gen-characterization-tests.sh."
      echo "-- ============================================================================="
    } > "$outfile"
    prev_sch="$sch"; schemas=$((schemas+1))
  fi
  {
    echo ""
    if [ -n "$deps" ]; then echo "-- $sch.$obj  (2b: fakes+seeds ${deps//\~/, })  input: ($inputs)"; else echo "-- $sch.$obj  input: ($inputs)"; fi
    echo "IF SCHEMA_ID('$cls') IS NOT NULL EXEC tSQLt.DropClass '$cls';"
    echo "GO"
    echo "EXEC tSQLt.NewTestClass '$cls';"
    echo "GO"
    echo "CREATE PROCEDURE $cls.[test output unchanged for representative input] AS"
    echo "BEGIN"
    [ -n "$fake" ] && printf '%s' "$fake"
    [ -n "$seed" ] && printf '%s' "$seed"
    echo "    DECLARE @expected nvarchar(max) = N'$esc';"
    echo "    DECLARE @actual   nvarchar(max) = ISNULL(CONVERT(nvarchar(max), $sch.$obj($inputs)), '<<NULL>>');"
    echo "    EXEC tSQLt.AssertEqualsString @Expected=@expected, @Actual=@actual,"
    echo "        @Message='Output of $sch.$obj for the representative input changed vs the committed baseline. If intended, regenerate the baseline.';"
    echo "END"
    echo "GO"
  } >> "$outfile"
  if [ -n "$deps" ]; then echo "  + $sch.$obj (2b, seeded) = $captured"; seeded=$((seeded+1)); else echo "  + $sch.$obj = $captured"; fi
  emitted=$((emitted+1))
done 9<<< "$fns"

echo "Done: $emitted characterization test(s) in $schemas schema file(s) -> $OUT_ROOT/  ($seeded seeded/2b, skipped $skipped)"
