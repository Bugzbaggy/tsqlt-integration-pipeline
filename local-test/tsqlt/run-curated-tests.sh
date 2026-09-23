#!/usr/bin/env bash
# =============================================================================
# run-curated-tests.sh — run the curated tSQLt regression tests.
#
# Installs tSQLt (if not already present) into the already-published CI database, loads
# every curated tSQLt class under tests/curated/, runs them, writes a JUnit report, and
# EXITS NON-ZERO if any test fails or errors. These are hand-verified assertions that catch
# regressions UnitAutogen can't. Tests FakeTable their dependencies and seed synthetic rows,
# so they run in milliseconds against the fresh schema and touch no production data.
#
# The non-zero exit is a real signal (use it as a hard gate locally / in pre-merge if you
# want). In the Jenkins pipeline it is currently wired REPORT-ONLY (catchError): a failure
# surfaces in the PR comment and marks the stage unstable but does not fail the build. Flip
# it to blocking by removing that catchError in pipeline/Jenkinsfile.
#
# Runs in the tools/mssql image (needs sqlcmd) against the same-pod sidecar over localhost.
# Config via environment (same names as ci-publish.sh / coverage.sh):
#   SERVER (localhost) PORT (1433) SA_PASSWORD (required) MSG_DB (AppDb_Dev)
#   SQLCMD_ENC ('-C' trust cert, default; '-No' encrypt optional)
#   TSQLT_DIR  (dir with PrepareServer.sql + tSQLt.class.sql — from fetch-deps.sh)
#   TESTS_DIR  (default tests/curated) ARTIFACTS_DIR (default artifacts)
# =============================================================================
set -uo pipefail

SERVER="${SERVER:-localhost}"
PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
MSG_DB="${MSG_DB:-AppDb_Dev}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
TSQLT_DIR="${TSQLT_DIR:-/tmp/tsqlt}"
TESTS_DIR="${TESTS_DIR:-tests/curated}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"

SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
# No sqlcmd => cannot run the gate. Fail loud (this gate must not silently pass).
[ -n "$SQLCMD" ] || { echo "ERROR: sqlcmd not found — cannot run the tSQLt gate." >&2; exit 2; }

# -b so a T-SQL error sets a non-zero exit; -I QUOTED_IDENTIFIER ON (tSQLt requirement).
sqlq() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b "$@"; }
mkdir -p "$ARTIFACTS_DIR"

echo "==> Waiting for SQL Server at $SERVER,$PORT ..."
ready=0
for i in $(seq 1 60); do
    if sqlq -l 5 -Q "SELECT 1" >/dev/null 2>&1; then ready=1; echo "    ready"; break; fi
    sleep 3
done
[ "$ready" = "1" ] || { echo "ERROR: SQL not ready — cannot run the tSQLt gate." >&2; exit 2; }

# No curated tests yet? That's a clean pass (nothing to gate) — but say so, don't hide it.
shopt -s nullglob globstar 2>/dev/null || true
mapfile -t TEST_FILES < <(find "$TESTS_DIR" -type f -name '*.sql' 2>/dev/null | sort)
if [ "${#TEST_FILES[@]}" -eq 0 ]; then
    echo "==> No curated tSQLt tests under $TESTS_DIR — gate passes (nothing to run)."
    exit 0
fi
echo "==> ${#TEST_FILES[@]} curated test file(s) under $TESTS_DIR."

# 1. Install tSQLt if absent (idempotent; coverage.sh may already have installed it).
if sqlq -d "$MSG_DB" -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID('tSQLt.RunAll') IS NULL THROW 50000,'no',1;" >/dev/null 2>&1; then
    echo "==> tSQLt already present in $MSG_DB."
else
    echo "==> Installing tSQLt into $MSG_DB ..."
    [ -f "$TSQLT_DIR/PrepareServer.sql" ] || { echo "ERROR: $TSQLT_DIR/PrepareServer.sql missing (run fetch-deps.sh first)." >&2; exit 2; }
    sqlq -i "$TSQLT_DIR/PrepareServer.sql" || { echo "ERROR: tSQLt PrepareServer failed." >&2; exit 2; }
    sqlq -d "$MSG_DB" -i "$TSQLT_DIR/tSQLt.class.sql" || { echo "ERROR: tSQLt install failed." >&2; exit 2; }
fi

# 2. Load every curated class into the DB. A load failure is a gate failure (a test that
#    references a dropped table/column must not be silently skipped).
load_failed=0
for f in "${TEST_FILES[@]}"; do
    echo "    load: $f"
    sqlq -d "$MSG_DB" -i "$f" || { echo "ERROR: failed to load $f" >&2; load_failed=1; }
done
[ "$load_failed" = "0" ] || { echo "ERROR: one or more curated tests failed to load." >&2; exit 1; }

# 3. Run everything, then export JUnit for Jenkins trends.
echo "==> Running curated tSQLt suite ..."
sqlq -d "$MSG_DB" -Q "SET NOCOUNT ON; EXEC tSQLt.RunAll;" || true   # RunAll RAISERRORs on failure; verdict computed below
# -y 0 (unlimited width) WITHOUT -h -1 (they are mutually exclusive in sqlcmd); the sed
# drops sqlcmd's header/separator by emitting from the first '<'. Same trick as coverage.sh.
"$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -y 0 \
    -d "$MSG_DB" -Q "SET NOCOUNT ON; EXEC tSQLt.XmlResultFormatter;" 2>/dev/null \
    | sed -n '/^[[:space:]]*</,$p' > "$ARTIFACTS_DIR/tsqlt-junit.xml"

# 4. Verdict straight from tSQLt.TestResult (source of truth) → exit code = the gate.
read -r TOTAL FAILED < <(sqlq -d "$MSG_DB" -h -1 -W -Q "SET NOCOUNT ON;
    SELECT CAST(COUNT(*) AS varchar(10)) + ' '
         + CAST(SUM(CASE WHEN Result <> 'Success' THEN 1 ELSE 0 END) AS varchar(10))
    FROM tSQLt.TestResult;" 2>/dev/null | tr -d '\r')
TOTAL="${TOTAL:-0}"; FAILED="${FAILED:-0}"
echo "==> tSQLt gate: $TOTAL run, $FAILED failed/errored."
if [ "$FAILED" != "0" ]; then
    sqlq -d "$MSG_DB" -h -1 -W -Q "SET NOCOUNT ON;
        SELECT '  FAIL: ' + Class + '.' + TestCase + ' — ' + ISNULL(Msg,'')
        FROM tSQLt.TestResult WHERE Result <> 'Success';" 2>/dev/null
    echo "ci: curated tSQLt gate FAILED." >&2
    exit 1
fi
echo "ci: curated tSQLt gate passed."
exit 0
