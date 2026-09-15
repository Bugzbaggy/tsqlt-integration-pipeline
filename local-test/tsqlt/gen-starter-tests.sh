#!/usr/bin/env bash
# =============================================================================
# gen-starter-tests.sh — generate a ready-to-finish tSQLt STARTER test for each object,
# by introspecting the LIVE database (not guessing). For every object it emits a test that
# already compiles and runs:
#   * tSQLt.FakeTable for each base table the object actually references (sys dependencies),
#   * the correct call shape (EXEC for a proc, SELECT for a scalar/table function) with the
#     object's real parameters,
#   * a smoke assertion (runs without throwing on faked/empty dependencies),
#   * clearly marked SEED / ASSERT TODOs for the human to add the real expectation.
#
# The point: a genuine curated test needs a human to say what the object *should* return —
# that can't be auto-generated (it is exactly why the UnitAutogen coverage is report-only and
# best-effort). But the mechanical 80% — which tables to fake, the call signature — is
# deterministic from the schema, so this turns "write a curated test" into a 2-minute fill-in
# instead of a blank page. Output goes to tests/generated/ (git-ignored); complete one and
# move it to tests/curated/<schema>/.
#
#   gen-starter-tests.sh <DB> <schema.object> [<schema.object> ...]
#   DB defaults to MSG_DB (AppDb_Dev). Uses SERVER/PORT/SA_PASSWORD/SQLCMD_ENC like coverage.sh.
# =============================================================================
set -uo pipefail

SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
OUT_ROOT="${OUT_ROOT:-tests/generated}"

DB="${1:?usage: gen-starter-tests.sh <DB> <schema.object> ...}"; shift
[ "$#" -gt 0 ] || { echo "gen-starter-tests: no objects given" >&2; exit 2; }

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "gen-starter-tests: sqlcmd not found" >&2; exit 2; }
q1() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -h -1 -y 8000 -d "$DB" -Q "SET NOCOUNT ON; $1" 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d'; }

# type decl string for a parameter (so an OUTPUT var can be declared and passed).
TYPEDECL="CASE WHEN ty.name IN ('varchar','char','varbinary','binary') THEN ty.name+'('+IIF(p.max_length=-1,'max',CAST(p.max_length AS varchar(10)))+')'
               WHEN ty.name IN ('nvarchar','nchar') THEN ty.name+'('+IIF(p.max_length=-1,'max',CAST(p.max_length/2 AS varchar(10)))+')'
               WHEN ty.name IN ('decimal','numeric') THEN ty.name+'('+CAST(p.precision AS varchar(10))+','+CAST(p.scale AS varchar(10))+')'
               ELSE ty.name END"

gen_one() { # $1=schema.object
    local so="$1" sch="${1%%.*}" obj="${1#*.}"
    local otype params deps argl decls call outdir outfile
    otype="$(q1 "SELECT type FROM sys.objects WHERE object_id=OBJECT_ID('$(printf %s "$so" | sed "s/'/''/g")')")"
    [ -n "$otype" ] || { echo "  ! $so not found in $DB — skipped"; return; }
    otype="$(printf '%s' "$otype" | tr -d '[:space:]')"

    # base-table dependencies (same DB), one FakeTable line each
    deps="$(q1 "SELECT DISTINCT 'EXEC tSQLt.FakeTable '''+ISNULL(d.referenced_schema_name,'dbo')+'.'+d.referenced_entity_name+''';'
                FROM sys.sql_expression_dependencies d JOIN sys.objects ro ON ro.object_id=d.referenced_id AND ro.type='U'
                WHERE d.referencing_id=OBJECT_ID('$(printf %s "$so" | sed "s/'/''/g")')
                  AND d.referenced_database_name IS NULL ORDER BY 1")"
    # parameter list: '@name = NULL' for inputs; declare+pass OUTPUT for output params.
    argl="$(q1 "SELECT ISNULL(STRING_AGG(CASE WHEN p.is_output=1 THEN p.name+' = @o'+CAST(p.parameter_id AS varchar(4))+' OUTPUT' ELSE p.name+' = NULL' END, ', ') WITHIN GROUP (ORDER BY p.parameter_id), '')
                FROM sys.parameters p WHERE p.object_id=OBJECT_ID('$(printf %s "$so" | sed "s/'/''/g")') AND p.parameter_id>0")"
    decls="$(q1 "SELECT ISNULL(STRING_AGG('    DECLARE @o'+CAST(p.parameter_id AS varchar(4))+' '+$TYPEDECL+';', CHAR(10)), '')
                FROM sys.parameters p JOIN sys.types ty ON ty.user_type_id=p.user_type_id
                WHERE p.object_id=OBJECT_ID('$(printf %s "$so" | sed "s/'/''/g")') AND p.parameter_id>0 AND p.is_output=1")"

    case "$otype" in
        P)      call="EXEC $sch.$obj${argl:+ $argl};" ;;
        FN)     call="DECLARE @r sql_variant = $sch.$obj(${argl//= NULL/}); SET @r = @r;" ;;   # scalar fn: just evaluate
        IF|TF)  call="SELECT TOP 0 * INTO #smoke FROM $sch.$obj(${argl//= NULL/}); DROP TABLE #smoke;" ;;   # TVF: materialize shape
        *)      call="/* unsupported object type '$otype' */ EXEC tSQLt.Fail 'unsupported object type';" ;;
    esac
    # scalar/TVF: strip param NAMES (functions are positional) -> keep NULLs only
    if [ "$otype" = "FN" ] || [ "$otype" = "IF" ] || [ "$otype" = "TF" ]; then
        local nargs; nargs="$(q1 "SELECT ISNULL(STRING_AGG('NULL', ', '),'') FROM sys.parameters p WHERE p.object_id=OBJECT_ID('$(printf %s "$so" | sed "s/'/''/g")') AND p.parameter_id>0")"
        call="${call/(*)/($nargs)}"
    fi

    outdir="$OUT_ROOT/$sch"; mkdir -p "$outdir"; outfile="$outdir/test_${sch}_${obj}.sql"
    {
      echo "-- STARTER (auto-generated from the live $DB schema) - DO NOT SHIP AS-IS."
      echo "-- Target : $sch.$obj  (${otype})"
      echo "-- Finish the SEED + ASSERT below, then move this file to tests/curated/$sch/ and delete the smoke fallback."
      echo "-- ============================================================================="
      echo "IF SCHEMA_ID('test_${sch}_${obj}') IS NOT NULL EXEC tSQLt.DropClass 'test_${sch}_${obj}';"
      echo "GO"
      echo "EXEC tSQLt.NewTestClass 'test_${sch}_${obj}';"
      echo "GO"
      echo "CREATE PROCEDURE test_${sch}_${obj}.[test ${obj} - TODO name the case]"
      echo "AS"
      echo "BEGIN"
      echo "    -- Dependencies (real, from the live schema) faked so the object runs in isolation:"
      if [ -n "$deps" ]; then printf '%s
' "$deps" | while IFS= read -r ln; do echo "    $ln"; done; else echo "    -- (no base-table dependencies detected)"; fi
      echo ""
      echo "    -- SEED: insert only the synthetic rows your case needs (no production data):"
      echo "    --   INSERT <faked table> (...) VALUES (...);"
      echo ""
      [ -n "$decls" ] && { echo "$decls"; echo ""; }
      echo "    -- ASSERT: replace this smoke check with a real expectation (tSQLt.AssertEquals / AssertEqualsTable):"
      echo "    BEGIN TRY"
      echo "        $call"
      echo "    END TRY BEGIN CATCH"
      echo "        DECLARE @em nvarchar(4000) = ERROR_MESSAGE();"   # EXEC args can't be function calls
      echo "        EXEC tSQLt.Fail 'ran but threw on faked/empty dependencies: ', @em;"
      echo "    END CATCH"
      echo "END"
      echo "GO"
    } > "$outfile"
    echo "  + $so (${otype}) -> $outfile"
}

echo "==> Generating starter tests from [$DB] into $OUT_ROOT/ ..."
for so in "$@"; do gen_one "$so"; done
echo "Done."
