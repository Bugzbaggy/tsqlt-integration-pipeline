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

mkdir -p "$ARTIFACTS_DIR"

# Armed here, before the readiness wait below - not after the scoping loop. The sqlcmd-not-found
# and SQL-not-ready exits happen first, and with no missing-list, no reason and no JUnit the PR
# comment fell through to "your PR changed no stored procedure or function", the very message this
# exists to stop. scoped is decided from OBJECTS alone, so it is knowable this early.
scoped=1
[ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ] || scoped=0
MISSING_OBJECTS=""
ERR_REASON=""
write_missing() {
    [ "$scoped" = "1" ] && printf '%s\n' "${MISSING_OBJECTS# }" > "$ARTIFACTS_DIR/contract-missing-${LABEL}.txt"
    if [ -n "$ERR_REASON" ]; then
        printf '%s\n' "$ERR_REASON" > "$ARTIFACTS_DIR/contract-error-${LABEL}.txt"
    fi
    return 0
}
trap write_missing EXIT

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "ERROR: sqlcmd not found — cannot run contract tests." >&2;
    ERR_REASON="sqlcmd is not available in this container, so nothing could be checked"; exit 2; }
sqlq() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b "$@"; }

echo "==> [$LABEL] Waiting for SQL Server at $SERVER,$PORT ..."
ready=0
for i in $(seq 1 60); do sqlq -l 5 -Q "SELECT 1" >/dev/null 2>&1 && { ready=1; break; }; sleep 3; done
[ "$ready" = "1" ] || { echo "ERROR: SQL not ready — cannot run contract tests." >&2;
    ERR_REASON="SQL Server never became ready, so no contract test could run"; exit 2; }

# What still EXISTS in the published schema. A DELETED object arrives in OBJECTS all the same -
# affected-objects.sh lists changed FILES - and a deleted object has no baseline to find, so it was
# reported as "no baseline yet", the autogen stage tried to generate one, the generator emitted
# nothing because the object is gone, and the comment ended up asking for a hand-written test for
# something the PR had removed. The published schema is the authority on what exists now.
LIVE_OBJECTS=""
if [ "$scoped" = "1" ]; then
    LIVE_OBJECTS="$(sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON; SELECT (s.name COLLATE DATABASE_DEFAULT)+'.'+(o.name COLLATE DATABASE_DEFAULT) FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE o.type IN ('P','FN','IF','TF') AND o.is_ms_shipped=0;")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: [$LABEL] could not list the published objects (sqlcmd exit $rc) - refusing to" >&2
        echo "       decide what is missing without knowing what exists." >&2
        ERR_REASON="could not list the published objects (sqlcmd exit $rc)"
        exit 2
    fi
    LIVE_OBJECTS="$(printf '%s' "$LIVE_OBJECTS" | sed -e 's/[[:space:]]*$//')"
fi
# -i for the same path-vs-catalog casing reason as everywhere else in these scripts.
# A here-string, NOT a pipe: `grep -q` exits on the first match and closes the pipe, `printf` then
# dies of SIGPIPE, and `set -o pipefail` reports 141 for the whole pipeline - so a MATCH read as
# "not found". Only bites once the input exceeds the 64 KiB pipe buffer, which the object list of
# a large database does, and its class list will. Caught by testing; the same shape is fixed below.
object_exists() { grep -qixF -- "$1" <<< "$LIVE_OBJECTS"; }

# Tests are stored one file per SCHEMA ($CONTRACT_DIR/<schema>.sql, all that schema's classes).
# Load the whole schema file (defines every class) but RUN only the changed objects' classes,
# so a PR still checks exactly what it changed. Full mode (empty OBJECTS) loads all + RunAll.
declare -A SCHEMA_FILES=()   # unique schema files to load
declare -a RUN_CLASSES=()
declare -a RUN_OBJECTS=()    # specific classes to run (scoped mode)
declare -a NOFILE_OBJECTS=() # changed objects whose SCHEMA has no baseline file at all
if [ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ]; then
    for so in $OBJECTS; do
        sch="${so%%.*}"; obj="${so#*.}"
        f="$CONTRACT_DIR/$sch.sql"
        if ! object_exists "$so"; then
            echo "    ($so is not in the published schema - deleted by this PR, so there is nothing to check)"
            continue
        fi
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
    while IFS= read -r f; do SCHEMA_FILES["$f"]=1; done < <(find "$CONTRACT_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
    echo "==> [$LABEL] full suite: ${#SCHEMA_FILES[@]} schema file(s)."
fi

# Recomputed once the scope is known; write_missing (armed above) writes whatever is current.
MISSING_OBJECTS=""
for o in ${NOFILE_OBJECTS[@]+"${NOFILE_OBJECTS[@]}"}; do MISSING_OBJECTS="$MISSING_OBJECTS $o"; done

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
    [ -f "$TSQLT_DIR/PrepareServer.sql" ] || { echo "ERROR: $TSQLT_DIR/PrepareServer.sql missing (run fetch-deps.sh first)." >&2;
        ERR_REASON="tSQLt is not available (fetch-deps.sh did not run or failed), so nothing could be checked"; exit 2; }
    sqlq -i "$TSQLT_DIR/PrepareServer.sql" || { echo "ERROR: tSQLt PrepareServer failed." >&2; ERR_REASON="tSQLt PrepareServer failed"; exit 2; }
    sqlq -d "$DB" -i "$TSQLT_DIR/tSQLt.class.sql" || { echo "ERROR: tSQLt install failed." >&2; ERR_REASON="tSQLt could not be installed"; exit 2; }
fi

# Load the schema files (defines their classes). A load failure is a real failure (a test that
# won't compile against the published schema must not be silently skipped).
load_failed=0
for f in "${!SCHEMA_FILES[@]}"; do
    sqlq -d "$DB" -i "$f" >/dev/null || { echo "ERROR: failed to load $f" >&2; load_failed=1; }
done
[ "$load_failed" = "0" ] || { echo "ERROR: [$LABEL] one or more contract test files failed to load." >&2;
     ERR_REASON="a test file failed to load against the published schema"; exit 1; }

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
        ERR_REASON="could not list the test classes (sqlcmd exit $rc)"
        exit 2
    fi
    present="$(printf '%s' "$present" | sed -e 's/[[:space:]]*$//')"
    # -i: these names are built from REPO FILE PATHS while the catalog spells them as the
    # object was created, and SQL Server does not care about case. The two can differ (a file
    # svc.AuthAPI_GetAll.sql for the object svc.AuthApi_GetAll), and a case-sensitive match
    # reports such an object as having no baseline when it has one.
    i=0
    for c in ${RUN_CLASSES[@]+"${RUN_CLASSES[@]}"}; do
        if grep -qixF -- "$c" <<< "$present"; then
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

# Start from an EMPTY tSQLt.TestResult. Everything below reads that table, and tSQLt only
# truncates it when a Run actually executes - so if the run batch never executes, rows left by an
# EARLIER run in this database are read as this run's results. The pipeline runs the curated
# suite (tSQLt.RunAll) in the same database just before this stage, so a batch that did not run
# reported the curated passes as the contract result, and with at least as many tests as classes
# it satisfied the floor check below as well. Cleared first, "nothing ran" reads as 0 and the
# floor refuses it. A separate short call, not part of the run batch: a batch that does not
# execute would not have cleared anything. sqlq carries -b, so a failed DELETE cannot pass.
if ! sqlq -d "$DB" -Q "SET NOCOUNT ON; DELETE FROM tSQLt.TestResult;" >/dev/null 2>&1; then
    echo "ERROR: [$LABEL] could not clear tSQLt.TestResult - refusing to report results that may be stale." >&2
    ERR_REASON="could not clear tSQLt.TestResult before the run, so its results could not be trusted"
    exit 2
fi

echo "==> [$LABEL] Running contract suite ..."
if [ "$scoped" = "1" ]; then
    # tSQLt.Run TRUNCATES tSQLt.TestResult on every call, so running one class per sqlcmd
    # invocation left only the LAST class's rows behind — the totals, the JUnit report and the
    # failure list were all computed from that single class. A PR touching N objects reported
    # "1 run", and a genuine contract change on any earlier object was SILENTLY DISCARDED
    # (observed: an 18-object scope reported "0 changed/failed" while etl.CurrencyRate_Get
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
    # Through a FILE, not -Q. sqlcmd 13.1 (the legacy mcr.microsoft.com/mssql-tools build, which
    # these scripts still accept via PATH or /opt/mssql-tools; the kit's tools.Dockerfile ships
    # mssql-tools18 / sqlcmd 18) SILENTLY drops a -Q batch past ~1 KB: the accumulator restore
    # never runs, so a multi-object scope reports "1 run" and every earlier class's result is
    # discarded - the exact defect the accumulator was added to fix. Proved with a 4,298-byte batch: 13.1
    # returns nothing via -Q and the right answer via -i; 18.6 (the CI sidecar) is fine either
    # way. A file is correct on both.
    run_q="$ARTIFACTS_DIR/contract-run-${LABEL}.sql"
    printf '%s\n' "$run_sql" > "$run_q"
    sqlq -d "$DB" -i "$run_q" >/dev/null 2>&1 || true
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
# The run above is `|| true`, so a batch that never executed leaves TestResult empty and the
# two reads below default to 0 - which prints "0 run, 0 changed/failed" and then "check passed",
# exiting 0. That is the same silent-green failure this script's -i change exists to stop, so
# assert the floor: every class that runs records at least one test, so fewer tests than classes
# means the batch did not run. RUN_CLASSES is the FILTERED set by this point (reassigned from
# RUN_OK above), so objects with no baseline are already excluded and cannot trip this.
# An unscoped run (RunAll) and a non-numeric TOTAL both skip the check rather than error.
if [ "$scoped" = "1" ] && [ "${#RUN_CLASSES[@]}" -gt 0 ] \
   && [ "${TOTAL//[0-9]/}" = "" ] && [ "$TOTAL" -lt "${#RUN_CLASSES[@]}" ]; then
    echo "ERROR: [$LABEL] only $TOTAL test(s) recorded for ${#RUN_CLASSES[@]} class(es) - the run batch did not execute." >&2
    ERR_REASON="the run batch recorded $TOTAL test(s) for ${#RUN_CLASSES[@]} class(es), so it did not execute"
    exit 2
fi
if [ "$FAILED" != "0" ]; then
    # -y 8000, not -W: Msg is nvarchar(max), and sqlcmd cuts a MAX column at 256 characters by
    # default, so every failure message stopped mid-word - right after "Expected: <...>", before
    # the "but was" that says what the value actually is. sqlcmd refuses -y together with -W, so
    # the padding -y adds is trimmed with sed instead. 8000 is sqlcmd's maximum here.
    sqlq -d "$DB" -h -1 -y 8000 -Q "SET NOCOUNT ON;
        SELECT '  CONTRACT CHANGED: ' + Class + '.' + TestCase + ' — ' + ISNULL(Msg,'')
        FROM tSQLt.TestResult WHERE Result <> 'Success';" 2>/dev/null | sed -e 's/[[:space:]]*$//'
    echo "ci: [$LABEL] contract check found interface changes (regenerate baselines if intended)." >&2
    exit 1
fi
echo "ci: [$LABEL] contract check passed (no interface changes)."
exit 0
