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
declare -a RUN_CLASSES=()
declare -a RUN_OBJECTS=()    # specific classes to run (scoped mode)
declare -a NOFILE_OBJECTS=() # changed objects whose SCHEMA has no baseline file at all
scoped=1
if [ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ]; then
    for so in $OBJECTS; do
        sch="${so%%.*}"; obj="${so#*.}"
        f="$CONTRACT_DIR/$sch.sql"
        if [ -f "$f" ]; then SCHEMA_FILES["$f"]=1; RUN_CLASSES+=("test_contract_${sch}_${obj}"); RUN_OBJECTS+=("$so")
        else
            # A whole schema with no baseline file is the SAME gap as a missing class, and it used
            # to be dropped right here: nothing was recorded, so the PR comment fell back to "your
            # PR changed no stored procedure or function" - the exact symptom observed live the
            # first time a brand-new object with no baseline yet reached this script.
            echo "    (no contract baseline file for schema $sch - $so has no baseline yet; run gen-auto-tests.sh)"
            NOFILE_OBJECTS+=("$so")
        fi
    done
    echo "==> [$LABEL] scoped to ${#RUN_CLASSES[@]} changed object(s) across ${#SCHEMA_FILES[@]} schema file(s)."
else
    scoped=0
    while IFS= read -r f; do SCHEMA_FILES["$f"]=1; done < <(find "$CONTRACT_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
    echo "==> [$LABEL] full suite: ${#SCHEMA_FILES[@]} schema file(s)."
fi

# Objects with no baseline, for the PR comment and for autogen-missing-baselines.sh. Written on
# EVERY scoped run, including the early exit below: a file that was never written reads as
# "nothing was missing", which is how a real gap got reported as "nothing changed".
MISSING_OBJECTS=""
for o in ${NOFILE_OBJECTS[@]+"${NOFILE_OBJECTS[@]}"}; do MISSING_OBJECTS="$MISSING_OBJECTS $o"; done
write_missing() {
    [ "$scoped" = "1" ] || return 0
    printf '%s' "${MISSING_OBJECTS# }" > "$ARTIFACTS_DIR/contract-missing-${LABEL}.txt"
}

if [ "${#SCHEMA_FILES[@]}" -eq 0 ]; then
    write_missing
    if [ -n "$MISSING_OBJECTS" ]; then
        echo "==> [$LABEL] no contract baseline exists for the changed object(s) - nothing could be checked."
    else
        echo "==> [$LABEL] no contract tests to run - nothing to check."
    fi
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

# A changed object can have NO test class at all - typically a brand-new object whose baseline was
# never generated. The scoping above only proves the SCHEMA FILE exists, so such an object was
# added to the run list, produced nothing, and the PR comment then said "not run - your PR changed
# no stored procedure or function" (observed live on PRs whose changed objects genuinely had no
# baseline). Verify each class really exists, name the ones that do not, and record them.
declare -a RUN_OK=()
if [ "$scoped" = "1" ] && [ "${#RUN_CLASSES[@]}" -gt 0 ]; then
    # List every contract class the DB has and match locally. An IN (...) of one class per changed
    # object grows with the PR and would eventually exceed what sqlcmd accepts; this query is a
    # fixed size no matter how much the PR touches.
    present="$(sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.schemas WHERE name LIKE 'test[_]contract[_]%';")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # Reading silence as "absent" marks EVERY class missing, runs nothing, and tells the author
        # there is no baseline for objects whose baselines are committed and fine. Fail loudly.
        echo "ERROR: [$LABEL] could not list test classes (sqlcmd exit $rc) - refusing to report" >&2
        echo "       objects as missing a baseline when the query never answered." >&2
        exit 2
    fi
    present="$(printf '%s' "$present" | sed -e 's/[[:space:]]*$//')"
    i=0
    for c in ${RUN_CLASSES[@]+"${RUN_CLASSES[@]}"}; do
        if printf '%s\n' "$present" | grep -qx -- "$c"; then
            RUN_OK+=("$c")
        else
            echo "    (no contract test for changed object ${RUN_OBJECTS[$i]} - no baseline yet; run gen-auto-tests.sh)"
            MISSING_OBJECTS="$MISSING_OBJECTS ${RUN_OBJECTS[$i]}"
        fi
        i=$((i+1))
    done
    RUN_CLASSES=(${RUN_OK[@]+"${RUN_OK[@]}"})
    echo "==> [$LABEL] ${#RUN_CLASSES[@]} of ${#RUN_OBJECTS[@]} changed object(s) have a baseline to check."
fi
write_missing

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
    for c in ${RUN_CLASSES[@]+"${RUN_CLASSES[@]}"}; do
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
         + CAST(ISNULL(SUM(CASE WHEN Result <> 'Success' THEN 1 ELSE 0 END),0) AS varchar(10))
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
