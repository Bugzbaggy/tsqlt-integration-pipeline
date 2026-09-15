#!/usr/bin/env bash
# =============================================================================
# run-contract-tests.sh — run the AUTO-GENERATED contract tests (parameter signature +
# result-set) for ONE database. No hand-written assertions: each test embeds a baseline and
# re-derives the live value from catalog metadata (sys.parameters /
# sys.dm_exec_describe_first_result_set_for_object), so it fails iff an object's interface
# changed vs the committed baseline. Regenerate the baseline with gen-auto-tests.sh to accept
# an intended change (a reviewable git diff).
#
# Report-only in the pipeline (like run-curated-tests.sh): non-zero exit is a real signal, but
# the Jenkinsfile wraps it in catchError. Runs in the tools/mssql image (needs sqlcmd).
#
# Env:
#   SERVER (localhost) PORT (1433) SA_PASSWORD (required) SQLCMD_ENC (-C)
#   DB            database to test        (default AppDb_Dev)
#   CONTRACT_DIR  generated tests for DB  (default tests/contract/AppDb_MSG)
#   OBJECTS       optional scope: whitespace-separated schema.object list (a PR's changed
#                 procs/functions). Empty => run every contract test in CONTRACT_DIR.
#   TSQLT_DIR     dir with PrepareServer.sql + tSQLt.class.sql (from fetch-deps.sh)
#   ARTIFACTS_DIR (default artifacts)     LABEL (report prefix, default = DB)
# =============================================================================
set -uo pipefail

SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
DB="${DB:-AppDb_Dev}"
CONTRACT_DIR="${CONTRACT_DIR:-tests/contract/AppDb_MSG}"
OBJECTS="${OBJECTS:-}"
TSQLT_DIR="${TSQLT_DIR:-/tmp/tsqlt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
LABEL="${LABEL:-$DB}"

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "ERROR: sqlcmd not found — cannot run contract tests." >&2; exit 2; }
sqlq() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b "$@"; }
mkdir -p "$ARTIFACTS_DIR"

echo "==> [$LABEL] Waiting for SQL Server at $SERVER,$PORT ..."
ready=0
for i in $(seq 1 60); do sqlq -l 5 -Q "SELECT 1" >/dev/null 2>&1 && { ready=1; break; }; sleep 3; done
[ "$ready" = "1" ] || { echo "ERROR: SQL not ready — cannot run contract tests." >&2; exit 2; }

# Tests are stored one file per SCHEMA ($CONTRACT_DIR/<schema>.sql, all that schema's classes).
# Load the whole schema file (defines every class) but RUN only the changed objects' classes,
# so a PR still checks exactly what it changed. Full mode (empty OBJECTS) loads all + RunAll.
declare -A SCHEMA_FILES=()   # unique schema files to load
declare -a RUN_CLASSES=()    # specific classes to run (scoped mode)
scoped=1
if [ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ]; then
    for so in $OBJECTS; do
        sch="${so%%.*}"; obj="${so#*.}"
        f="$CONTRACT_DIR/$sch.sql"
        if [ -f "$f" ]; then SCHEMA_FILES["$f"]=1; RUN_CLASSES+=("test_contract_${sch}_${obj}")
        else echo "    (no contract test for changed object $so — new object? run gen-auto-tests.sh)"; fi
    done
    echo "==> [$LABEL] scoped to ${#RUN_CLASSES[@]} changed object(s) across ${#SCHEMA_FILES[@]} schema file(s)."
else
    scoped=0
    while IFS= read -r f; do SCHEMA_FILES["$f"]=1; done < <(find "$CONTRACT_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
    echo "==> [$LABEL] full suite: ${#SCHEMA_FILES[@]} schema file(s)."
fi
if [ "${#SCHEMA_FILES[@]}" -eq 0 ]; then
    echo "==> [$LABEL] no contract tests to run — nothing to check."
    exit 0
fi

# Install tSQLt if absent (idempotent; coverage.sh/run-curated may have installed it already).
if ! sqlq -d "$DB" -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID('tSQLt.RunAll') IS NULL THROW 50000,'no',1;" >/dev/null 2>&1; then
    echo "==> [$LABEL] Installing tSQLt into $DB ..."
    [ -f "$TSQLT_DIR/PrepareServer.sql" ] || { echo "ERROR: $TSQLT_DIR/PrepareServer.sql missing (run fetch-deps.sh first)." >&2; exit 2; }
    sqlq -i "$TSQLT_DIR/PrepareServer.sql" || { echo "ERROR: tSQLt PrepareServer failed." >&2; exit 2; }
    sqlq -d "$DB" -i "$TSQLT_DIR/tSQLt.class.sql" || { echo "ERROR: tSQLt install failed." >&2; exit 2; }
fi

# Load the schema files (defines their classes). A load failure is a real failure (a test that
# won't compile against the published schema must not be silently skipped).
load_failed=0
for f in "${!SCHEMA_FILES[@]}"; do
    sqlq -d "$DB" -i "$f" >/dev/null || { echo "ERROR: failed to load $f" >&2; load_failed=1; }
done
[ "$load_failed" = "0" ] || { echo "ERROR: [$LABEL] one or more contract test files failed to load." >&2; exit 1; }

echo "==> [$LABEL] Running contract suite ..."
if [ "$scoped" = "1" ]; then
    # tSQLt.Run TRUNCATES tSQLt.TestResult on every call, so running one class per sqlcmd
    # invocation left only the LAST class's rows behind — the totals, the JUnit report and the
    # failure list were all computed from that single class. A PR touching N objects reported
    # "1 run", and a genuine contract change on any earlier object was SILENTLY DISCARDED
    # (observed: an 18-object scope reported "0 changed/failed" while mage_ai.CurrencyRate_Get
    # was really failing). Run every class in ONE batch instead, copying TestResult into an
    # accumulator after each Run, then restore the union so everything downstream is complete.
    # Name is a computed column and Id is an identity, so neither is carried across.
    run_sql="SET NOCOUNT ON;
CREATE TABLE #acc (Class nvarchar(max), TestCase nvarchar(max), TranName nvarchar(max),
                   Result nvarchar(max), Msg nvarchar(max), TestStartTime datetime2, TestEndTime datetime2);"
    for c in "${RUN_CLASSES[@]}"; do
        esc=${c//\'/\'\'}
        run_sql="$run_sql
BEGIN TRY EXEC tSQLt.Run '$esc'; END TRY BEGIN CATCH END CATCH;
INSERT #acc (Class,TestCase,TranName,Result,Msg,TestStartTime,TestEndTime)
  SELECT Class,TestCase,TranName,Result,Msg,TestStartTime,TestEndTime FROM tSQLt.TestResult;"
    done
    run_sql="$run_sql
DELETE FROM tSQLt.TestResult;
INSERT INTO tSQLt.TestResult (Class,TestCase,TranName,Result,Msg,TestStartTime,TestEndTime)
  SELECT Class,TestCase,TranName,Result,Msg,TestStartTime,TestEndTime FROM #acc ORDER BY TestStartTime;"
    sqlq -d "$DB" -Q "$run_sql" >/dev/null 2>&1 || true
else
    sqlq -d "$DB" -Q "SET NOCOUNT ON; EXEC tSQLt.RunAll;" >/dev/null 2>&1 || true
fi
"$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -y 0 \
    -d "$DB" -Q "SET NOCOUNT ON; EXEC tSQLt.XmlResultFormatter;" 2>/dev/null \
    | sed -n '/^[[:space:]]*</,$p' > "$ARTIFACTS_DIR/contract-junit-${LABEL}.xml"

read -r TOTAL FAILED < <(sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(10)) + ' '
         + CAST(SUM(CASE WHEN Result <> 'Success' THEN 1 ELSE 0 END) AS varchar(10))
    FROM tSQLt.TestResult;" 2>/dev/null | tr -d '\r')
TOTAL="${TOTAL:-0}"; FAILED="${FAILED:-0}"
echo "==> [$LABEL] contract gate: $TOTAL run, $FAILED changed/failed."
if [ "$FAILED" != "0" ]; then
    sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON;
        SELECT '  CONTRACT CHANGED: ' + Class + '.' + TestCase + ' — ' + ISNULL(Msg,'')
        FROM tSQLt.TestResult WHERE Result <> 'Success';" 2>/dev/null
    echo "ci: [$LABEL] contract check found interface changes (regenerate baselines if intended)." >&2
    exit 1
fi
echo "ci: [$LABEL] contract check passed (no interface changes)."
exit 0
