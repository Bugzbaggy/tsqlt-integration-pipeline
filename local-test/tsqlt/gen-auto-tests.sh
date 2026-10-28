#!/usr/bin/env bash
# =============================================================================
# gen-auto-tests.sh — auto-generate tSQLt CONTRACT tests for EVERY procedure/function
# in a database, with NO human-written assertions. Two tiers, both derived purely from
# catalog metadata (no execution of the target object, no data touched):
#
#   Tier 0  Signature contract  — asserts the parameter list (id:name:type:direction)
#                                  is unchanged vs the committed baseline. 100% of objects.
#   Tier 1  Result-set contract — asserts the first result set's columns (ordinal:name:
#                                  type:nullability) are unchanged. ~half of procs expose one
#                                  statically (sys.dm_exec_describe_first_result_set_for_object).
#
# The baseline is EMBEDDED as a literal in each generated test; the test recomputes the live
# value with the SAME SQL expression and AssertEqualsString's them. "Update the baseline" is
# therefore a visible git diff in the test file, reviewed on the PR — characterization/golden-
# master style, zero hand-written assertions.
#
# One set-based query per DB emits every object's baseline at once (not one round-trip each),
# so even a large database is introspected in seconds.
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
#
# Each aggregated item is CAST to nvarchar(max) before STRING_AGG. STRING_AGG returns a non-MAX
# type unless its input is MAX, and a non-MAX result is limited to 8,000 bytes (4,000 nvarchar
# characters): past that it raises Msg 9829, which fails the ONE set-based query below and with
# it the whole database, not just the object. Short of that limit, the non-MAX pieces also made
# the introspection row itself non-MAX, so a row longer than 4,000 characters was silently cut by
# the concatenation - an embedded baseline that was wrong from the start. The value of every
# string is unchanged; only its type is.
SIG_EXPR="(SELECT ISNULL(STRING_AGG(CAST(
    CAST(p.parameter_id AS varchar(6))+':'+(p.name COLLATE DATABASE_DEFAULT)+':'+
    (CASE WHEN ty.name IN ('varchar','char','varbinary','binary') THEN (ty.name COLLATE DATABASE_DEFAULT)+'('+IIF(p.max_length=-1,'max',CAST(p.max_length AS varchar(10)))+')'
          WHEN ty.name IN ('nvarchar','nchar') THEN (ty.name COLLATE DATABASE_DEFAULT)+'('+IIF(p.max_length=-1,'max',CAST(p.max_length/2 AS varchar(10)))+')'
          WHEN ty.name IN ('decimal','numeric') THEN (ty.name COLLATE DATABASE_DEFAULT)+'('+CAST(p.precision AS varchar(10))+','+CAST(p.scale AS varchar(10))+')'
          ELSE (ty.name COLLATE DATABASE_DEFAULT) END)+':'+CAST(p.is_output AS char(1)) AS nvarchar(max)),
    '|') WITHIN GROUP (ORDER BY p.parameter_id), '')
  FROM sys.parameters p JOIN sys.types ty ON ty.user_type_id=p.user_type_id
  WHERE p.object_id=%OID% AND p.parameter_id>=0)"

RS_EXPR="(SELECT ISNULL(STRING_AGG(CAST(
    CAST(r.column_ordinal AS varchar(6))+':'+ISNULL(r.name COLLATE DATABASE_DEFAULT,'(noname)')+':'+(r.system_type_name COLLATE DATABASE_DEFAULT)+':'+CAST(r.is_nullable AS char(1)) AS nvarchar(max)),
    '|') WITHIN GROUP (ORDER BY r.column_ordinal), '')
  FROM sys.dm_exec_describe_first_result_set_for_object(%OID%, 0) r
  WHERE r.error_number IS NULL AND ISNULL(r.is_hidden,0)=0)"

sig_bulk="${SIG_EXPR//%OID%/o.object_id}"
rs_bulk="${RS_EXPR//%OID%/o.object_id}"

# See gen-characterization-tests.sh: the </dev/null stops sqlcmd rewinding an enclosing
# while-read loop stdin into an infinite loop.
#
# TWO flags here are load-bearing, and the script was shipped without either. Both were
# measured against a live server, not reasoned about:
#
#   -i (a FILE, not -Q)  The introspection query below is several KB once SIG_EXPR and RS_EXPR
#     are substituted, and sqlcmd 13.1 (the legacy mcr.microsoft.com/mssql-tools build, which
#     these scripts still accept via PATH or /opt/mssql-tools; the kit's tools.Dockerfile
#     ships mssql-tools18 / sqlcmd 18) SILENTLY TRUNCATES a -Q batch past ~1 KB. The severed
#     UTF-16 tail comes back as "Msg 102 Incorrect syntax near '<mojibake>'". A file works on
#     every version. gen-characterization-tests.sh already reads its eligibility query from a
#     file for exactly this reason.
#
#   -b  Without it sqlcmd exits 0 on a STATEMENT-level error and prints the message to STDOUT,
#     so it lands in "$rows" and the loop below parses "Msg 208, Level 16, State 1, Server x,
#     Line 1" as a data row - naming a schema file after it. Msg 208 (invalid object), Msg 468
#     (collation conflict - the one this script's own header documents) and Msg 916
#     (permission) all exit 0 without -b, and 1 with it.
#
# Together they were a silent, total failure on sqlcmd 13.1: the run wrote two garbage files,
# reported "Done: 2 objects in 2 schema file(s)" and exited 0, where the right answer was one
# <schema>.sql holding every object in the schema. autogen-missing-baselines.sh then found no <schema>.sql and
# filed those objects under "no baseline is possible", dropping them from the missing list on a
# GREEN build.
sqlf() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b -h -1 -y 8000 -d "$DB" -i "$1" 2>/dev/null </dev/null; }

schema_pred=""
[ -n "$SCHEMA_FILTER" ] && schema_pred="AND s.name = '$(printf %s "$SCHEMA_FILTER" | sed "s/'/''/g")'"

echo "==> Introspecting [$DB] ${SCHEMA_FILTER:+schema=$SCHEMA_FILTER }for contract baselines ..."
# One row per object:  sch ~|~ obj ~|~ type_desc ~|~ signature ~|~ resultset
introspect_q="$(mktemp)" || { echo "gen-auto-tests: mktemp failed - cannot stage the introspection query." >&2; exit 2; }
[ -n "$introspect_q" ] || { echo "gen-auto-tests: mktemp returned an empty path." >&2; exit 2; }
trap 'rm -f "$introspect_q"' EXIT
printf '%s\n' "SET NOCOUNT ON;
SELECT (s.name COLLATE DATABASE_DEFAULT)+'~|~'+(o.name COLLATE DATABASE_DEFAULT)+'~|~'+(o.type_desc COLLATE DATABASE_DEFAULT)+'~|~'+ $sig_bulk +'~|~'+ $rs_bulk
FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
WHERE o.type IN ('P','FN','IF','TF') AND o.is_ms_shipped=0
  -- exclude tSQLt itself and any tSQLt test class (schemas: tSQLt, test_*; and our own
  -- generated contract classes test_contract_*), so we never generate tests-of-tests.
  AND s.name <> 'tSQLt' AND s.name NOT LIKE 'test[_]%' AND s.name NOT LIKE 'tSQLt[_]%'
  AND o.name NOT LIKE 'test[_]%' $schema_pred
ORDER BY s.name, o.name;" > "$introspect_q"
rows="$(sqlf "$introspect_q")" || {
  # sqlcmd writes the error to STDOUT, so it is sitting in $rows rather than on the terminal
  # (and sqlf() discards stderr). Surface it, then stop: a caller must be able to tell
  # "the query failed" apart from "this schema has no objects".
  echo "gen-auto-tests: introspection query FAILED for [$DB]${SCHEMA_FILTER:+ schema=$SCHEMA_FILTER}:" >&2
  printf '%s\n' "$rows" >&2
  exit 1
}

[ -n "$rows" ] || { echo "  no objects found (schema filter? empty DB?)"; exit 1; }

emitted=0; sig_only=0; with_rs=0; trunc=0; schemas=0; prev_sch=""; junk=0
while IFS= read -r line <&9; do
  [ -z "$line" ] && continue
  # Belt and braces behind -b: a real row always carries the ~|~ separators. Anything else is
  # sqlcmd diagnostic text, and "${line%%~|~*}" would otherwise hand it straight to
  # "$OUT_ROOT/${sch}.sql" as a file name. Never let that happen silently.
  case "$line" in
    *'~|~'*) ;;
    *) echo "gen-auto-tests: ignoring non-row output from sqlcmd: $line" >&2; junk=$((junk+1)); continue ;;
  esac
  # -y 8000 caps the whole returned ROW, not each field, so check the row before splitting it.
  # The per-field test further down compares sig and rs against 7999 individually, which cannot
  # independently reach the cap - a row of 8,300 made of two 4,150-char fields passes both field
  # checks while sqlcmd has already cut the tail off rs, embedding a truncated baseline that is
  # then permanently red. Rarely reachable in practice (on the schemas this was measured against
  # the longest row was about a quarter of the 8000 cap), but this is the check that actually
  # corresponds to -y. The cap cannot simply be raised: sqlcmd rejects -y above 8000, and its
  # unlimited form (-y 0) is refused together with -h -1, which this parser needs. Such an object
  # is skipped and counted; the rest of the database still generates.
  full="${line%"${line##*[![:space:]]}"}"
  if [ "${#full}" -ge 7999 ]; then
    cap_obj="${line#*~|~}"; cap_obj="${line%%~|~*}.${cap_obj%%~|~*}"
    echo "  ! $cap_obj: row near sqlcmd's 8000-char cap - skipped (needs a hand-written test)" >&2
    trunc=$((trunc+1)); continue
  fi
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
done 9<<< "$rows"

echo "Done: $emitted objects in $schemas schema file(s) -> $OUT_ROOT/  (with result-set contract: $with_rs, signature-only: $sig_only, skipped-truncated: $trunc)"

# Exit non-zero if anything unparseable came back. Reporting "Done" and exiting 0 on a
# partially-garbled result set is what let a failed generation be read as "no baseline is
# possible" - the caller must see this as a failure, not a clean empty run.
[ "$junk" -eq 0 ] || { echo "gen-auto-tests: $junk unparseable line(s) from sqlcmd - treating this run as FAILED." >&2; exit 1; }
