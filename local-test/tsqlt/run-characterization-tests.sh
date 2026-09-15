#!/usr/bin/env bash
# =============================================================================
# run-characterization-tests.sh — run the AUTO-GENERATED Tier 2 characterization tests
# (behavioural: output for a fixed representative input) for ONE database. No hand-written
# assertions: each test embeds a baseline captured from the object and re-derives the live
# value, so it fails iff the object's OUTPUT changed vs the committed baseline. Regenerate with
# gen-characterization-tests.sh to accept an intended behaviour change (a reviewable git diff).
#
# Report-only in the pipeline (like the contract/curated runners). Runs in the tools/mssql
# image (needs sqlcmd).
#
# Env:
#   SERVER (localhost) PORT (1433) SA_PASSWORD (required) SQLCMD_ENC (-C)
#   DB          database to test        (default AppDb_Dev)
#   CHAR_DIR    generated tests for DB  (default tests/characterization/AppDb_MSG)
#   OBJECTS     optional scope: whitespace-separated schema.object list (a PR's changed
#               functions). Empty => run every characterization test in CHAR_DIR.
#   TSQLT_DIR   dir with PrepareServer.sql + tSQLt.class.sql (from fetch-deps.sh)
#   ARTIFACTS_DIR (default artifacts)   LABEL (report prefix, default = DB)
# =============================================================================
set -uo pipefail

SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
DB="${DB:-AppDb_Dev}"
CHAR_DIR="${CHAR_DIR:-tests/characterization/AppDb_MSG}"
OBJECTS="${OBJECTS:-}"
TSQLT_DIR="${TSQLT_DIR:-/tmp/tsqlt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
LABEL="${LABEL:-$DB}"

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "ERROR: sqlcmd not found — cannot run characterization tests." >&2; exit 2; }
sqlq() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b "$@"; }
mkdir -p "$ARTIFACTS_DIR"

echo "==> [$LABEL] Waiting for SQL Server at $SERVER,$PORT ..."
ready=0
for i in $(seq 1 60); do sqlq -l 5 -Q "SELECT 1" >/dev/null 2>&1 && { ready=1; break; }; sleep 3; done
[ "$ready" = "1" ] || { echo "ERROR: SQL not ready — cannot run characterization tests." >&2; exit 2; }

# One file per SCHEMA ($CHAR_DIR/<schema>.sql): load the whole file (defines its classes) but
# RUN only the changed objects' classes. Full mode (empty OBJECTS) loads all + RunAll.
declare -A SCHEMA_FILES=()
declare -a RUN_CLASSES=()
scoped=1
if [ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ]; then
    for so in $OBJECTS; do
        sch="${so%%.*}"; obj="${so#*.}"
        f="$CHAR_DIR/$sch.sql"
        if [ -f "$f" ]; then SCHEMA_FILES["$f"]=1; RUN_CLASSES+=("test_char_${sch}_${obj}")
        else echo "    (no characterization test for changed object $so — not a deterministic scalar fn, or new)"; fi
    done
    echo "==> [$LABEL] scoped to ${#RUN_CLASSES[@]} changed object(s) across ${#SCHEMA_FILES[@]} schema file(s)."
else
    scoped=0
    while IFS= read -r f; do SCHEMA_FILES["$f"]=1; done < <(find "$CHAR_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
    echo "==> [$LABEL] full suite: ${#SCHEMA_FILES[@]} schema file(s)."
fi
if [ "${#SCHEMA_FILES[@]}" -eq 0 ]; then
    echo "==> [$LABEL] no characterization tests to run — nothing to check."
    exit 0
fi

if ! sqlq -d "$DB" -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID('tSQLt.RunAll') IS NULL THROW 50000,'no',1;" >/dev/null 2>&1; then
    echo "==> [$LABEL] Installing tSQLt into $DB ..."
    [ -f "$TSQLT_DIR/PrepareServer.sql" ] || { echo "ERROR: $TSQLT_DIR/PrepareServer.sql missing (run fetch-deps.sh first)." >&2; exit 2; }
    sqlq -i "$TSQLT_DIR/PrepareServer.sql" || { echo "ERROR: tSQLt PrepareServer failed." >&2; exit 2; }
    sqlq -d "$DB" -i "$TSQLT_DIR/tSQLt.class.sql" || { echo "ERROR: tSQLt install failed." >&2; exit 2; }
fi

load_failed=0
for f in "${!SCHEMA_FILES[@]}"; do
    sqlq -d "$DB" -i "$f" >/dev/null || { echo "ERROR: failed to load $f" >&2; load_failed=1; }
done
[ "$load_failed" = "0" ] || { echo "ERROR: [$LABEL] one or more characterization test files failed to load." >&2; exit 1; }

echo "==> [$LABEL] Running characterization suite ..."
if [ "$scoped" = "1" ]; then
    # Same defect as run-contract-tests.sh: tSQLt.Run TRUNCATES tSQLt.TestResult on every call,
    # so one-class-per-invocation left only the LAST class's rows — under-reporting the count and
    # silently discarding a real behaviour change on any earlier object. Run every class in ONE
    # batch, accumulate after each Run, then restore the union. Name is computed, Id is identity.
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
    | sed -n '/^[[:space:]]*</,$p' > "$ARTIFACTS_DIR/characterization-junit-${LABEL}.xml"

read -r TOTAL FAILED < <(sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(10)) + ' '
         + CAST(SUM(CASE WHEN Result <> 'Success' THEN 1 ELSE 0 END) AS varchar(10))
    FROM tSQLt.TestResult;" 2>/dev/null | tr -d '\r')
TOTAL="${TOTAL:-0}"; FAILED="${FAILED:-0}"
echo "==> [$LABEL] characterization gate: $TOTAL run, $FAILED changed/failed."
if [ "$FAILED" != "0" ]; then
    sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON;
        SELECT '  BEHAVIOUR CHANGED: ' + Class + '.' + TestCase + ' — ' + ISNULL(Msg,'')
        FROM tSQLt.TestResult WHERE Result <> 'Success';" 2>/dev/null
    echo "ci: [$LABEL] characterization found behaviour changes (regenerate baselines if intended)." >&2
    exit 1
fi
echo "ci: [$LABEL] characterization check passed (no behaviour changes)."
exit 0
