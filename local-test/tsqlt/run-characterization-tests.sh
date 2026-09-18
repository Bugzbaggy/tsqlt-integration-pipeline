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
HERE="$(cd "$(dirname "$0")" && pwd)"

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

# Characterization baselines exist ONLY for objects the generator can cover: deterministic scalar
# functions. The predicate is char-eligible.where.sql - the SAME file gen-characterization-tests.sh
# selects with, so the two can't drift. A stored procedure will never have a test_char_ class, so
# reporting one as "no baseline yet - run gen-characterization-tests.sh" is a warning no command
# can ever clear; ask the DB what is eligible before deciding anything is missing.
ELIGIBLE=""
if [ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ]; then
    ELIG_WHERE="$(cat "$HERE/char-eligible.where.sql" 2>/dev/null || true)"
    [ -n "$ELIG_WHERE" ] || { echo "ERROR: char-eligible.where.sql missing next to this script." >&2; exit 2; }
    # Via an input FILE, not -Q: sqlcmd mangles a multi-line -Q string that carries SQL comments
    # (proved live against the local DB - the same query returns the 8 eligible functions with -i
    # and "Incorrect syntax near '('" with -Q). A file has no command-line length limit either.
    elig_q="$ARTIFACTS_DIR/characterization-eligible-query-${LABEL}.sql"
    cat > "$elig_q" <<SQL
SET NOCOUNT ON;
SELECT (s.name COLLATE DATABASE_DEFAULT)+'.'+(o.name COLLATE DATABASE_DEFAULT)
FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
CROSS APPLY (SELECT def = OBJECT_DEFINITION(o.object_id)) d2
WHERE (
$ELIG_WHERE
);
SQL
    ELIGIBLE="$(sqlq -d "$DB" -h -1 -W -i "$elig_q")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: [$LABEL] could not list characterization-eligible functions (sqlcmd exit $rc) -" >&2
        echo "       refusing to guess which changed objects should have a baseline." >&2
        exit 2
    fi
    ELIGIBLE="$(printf '%s' "$ELIGIBLE" | sed -e 's/[[:space:]]*$//')"
fi
is_eligible() { printf '%s\n' "$ELIGIBLE" | grep -qx -- "$1"; }

# One file per SCHEMA ($CHAR_DIR/<schema>.sql): load the whole file (defines its classes) but
# RUN only the changed objects' classes. Full mode (empty OBJECTS) loads all + RunAll.
declare -A SCHEMA_FILES=()
declare -a RUN_CLASSES=()
declare -a RUN_OBJECTS=()
declare -a NOFILE_OBJECTS=()
scoped=1
if [ -n "$(printf '%s' "$OBJECTS" | tr -d '[:space:]')" ]; then
    for so in $OBJECTS; do
        sch="${so%%.*}"; obj="${so#*.}"
        if ! is_eligible "$so"; then
            echo "    ($so is not a deterministic scalar function - characterization does not cover it)"
            continue
        fi
        f="$CHAR_DIR/$sch.sql"
        if [ -f "$f" ]; then SCHEMA_FILES["$f"]=1; RUN_CLASSES+=("test_char_${sch}_${obj}"); RUN_OBJECTS+=("$so")
        else
            echo "    (no characterization baseline file for schema $sch - $so has no baseline yet; run gen-characterization-tests.sh)"
            NOFILE_OBJECTS+=("$so")
        fi
    done
    echo "==> [$LABEL] scoped to ${#RUN_CLASSES[@]} changed object(s) across ${#SCHEMA_FILES[@]} schema file(s)."
else
    scoped=0
    while IFS= read -r f; do SCHEMA_FILES["$f"]=1; done < <(find "$CHAR_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
    echo "==> [$LABEL] full suite: ${#SCHEMA_FILES[@]} schema file(s)."
fi

# Written on EVERY scoped run, including the early exit below: an unwritten file reads as
# "nothing was missing", which is how a real gap got reported as "nothing changed".
MISSING_OBJECTS=""
for o in ${NOFILE_OBJECTS[@]+"${NOFILE_OBJECTS[@]}"}; do MISSING_OBJECTS="$MISSING_OBJECTS $o"; done
write_missing() {
    [ "$scoped" = "1" ] || return 0
    printf '%s' "${MISSING_OBJECTS# }" > "$ARTIFACTS_DIR/characterization-missing-${LABEL}.txt"
}

if [ "${#SCHEMA_FILES[@]}" -eq 0 ]; then
    write_missing
    if [ -n "$MISSING_OBJECTS" ]; then
        echo "==> [$LABEL] no characterization baseline exists for the changed function(s) - nothing could be checked."
    else
        echo "==> [$LABEL] no characterization tests to run - nothing to check."
    fi
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

# The scoping above only proves the SCHEMA FILE exists, so an eligible function with no generated
# class was added to the run list, produced nothing, and the PR comment then said "not run - your
# PR changed no stored procedure or function". Verify each class really exists.
declare -a RUN_OK=()
if [ "$scoped" = "1" ] && [ "${#RUN_CLASSES[@]}" -gt 0 ]; then
    present="$(sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.schemas WHERE name LIKE 'test[_]char[_]%';")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: [$LABEL] could not list test classes (sqlcmd exit $rc) - refusing to report" >&2
        echo "       functions as missing a baseline when the query never answered." >&2
        exit 2
    fi
    present="$(printf '%s' "$present" | sed -e 's/[[:space:]]*$//')"
    i=0
    for c in ${RUN_CLASSES[@]+"${RUN_CLASSES[@]}"}; do
        if printf '%s\n' "$present" | grep -qx -- "$c"; then
            RUN_OK+=("$c")
        else
            echo "    (no characterization test for changed object ${RUN_OBJECTS[$i]} - no baseline yet; run gen-characterization-tests.sh)"
            MISSING_OBJECTS="$MISSING_OBJECTS ${RUN_OBJECTS[$i]}"
        fi
        i=$((i+1))
    done
    RUN_CLASSES=(${RUN_OK[@]+"${RUN_OK[@]}"})
    echo "==> [$LABEL] ${#RUN_CLASSES[@]} of ${#RUN_OBJECTS[@]} changed function(s) have a baseline to check."
fi
write_missing

echo "==> [$LABEL] Running characterization suite ..."
if [ "$scoped" = "1" ]; then
    # Same defect as run-contract-tests.sh: tSQLt.Run TRUNCATES tSQLt.TestResult on every call,
    # so one-class-per-invocation left only the LAST class's rows — under-reporting the count and
    # silently discarding a real behaviour change on any earlier object. Run every class in ONE
    # batch, accumulate after each Run, then restore the union. Name is computed, Id is identity.
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
    | sed -n '/^[[:space:]]*</,$p' > "$ARTIFACTS_DIR/characterization-junit-${LABEL}.xml"

read -r TOTAL FAILED < <(sqlq -d "$DB" -h -1 -W -Q "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(10)) + ' '
         + CAST(ISNULL(SUM(CASE WHEN Result <> 'Success' THEN 1 ELSE 0 END),0) AS varchar(10))
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
