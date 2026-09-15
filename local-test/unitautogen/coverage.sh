#!/usr/bin/env bash
# =============================================================================
# coverage.sh — run UnitAutogen (auto-generated tSQLt tests + line coverage)
# against the ALREADY-PROVISIONED AppDb_MSG test databases, and emit Cobertura +
# JUnit + a compact per-object summary. Runs inside the "tools"/mssql image (has
# sqlcmd); reaches sqlservr over localhost. Wired in as the integration
# pipeline's coverage stage (see pipelines/integration-test/Jenkinsfile).
#
# REPORT-ONLY BY DESIGN: this script always exits 0. It publishes coverage/test
# artifacts as an informational signal; it never fails the build.
#
# Real constraints found live on SQL Server 2022 for Linux — see README.md:
#   1. UnitAutogen's .xel path derivation is Windows-only (splits on '\'). On
#      Linux it yields a bogus path -> 0 coverage. We patch it (sed, below).
#   2. UnitAutogen rolls back the WHOLE batch if any one proc leaves an open
#      transaction (Msg 266/3998), and a connection-recovery from one proc can
#      cascade and silently drop the *rest*. So in object-scoped mode we generate
#      EACH object in its OWN GenerateAndCoverDatabase call (its own batch), then
#      consolidate the batches and BACKFILL a placeholder for any object that
#      produced no row — so a bad proc only loses itself and every changed object
#      always appears. (An include-filter into the enumeration, keyed on the
#      session temp table #UA_Only, restricts each call to one object.)
#   3. The UNSAFE CLR predicate parser cannot load on Linux (SAFE-only) -> branch
#      seeding is degraded. LINE coverage + test pass/fail are the trustworthy
#      signals; branch coverage is best-effort.
#
# Deps (fetched at PINNED versions by fetch-deps.sh — nothing vendored):
#   UA_DIR     dir with UnitAutogen (Install_UnitAutogen.sql), AGPL, pinned commit.
#   TSQLT_DIR  dir with tSQLt PrepareServer.sql + tSQLt.class.sql, Apache-2.0.
#   ARTIFACTS_DIR  writable dir for the emitted reports.
#
# Config via environment (K8s mssql-2022 pod defaults — sqlservr on localhost):
#   SERVER (localhost)  PORT (1433)  SA_PASSWORD (required)
#   MSG_DB (AppDb_Dev)        main DB (AppDb_MSG project objects)
#   DATA_DB (AppDb_MSG_Data_Dev)  data-layer DB (AppDb_MSG_data project objects)
#   SQLCMD_ENC   sqlcmd TLS flag: '-C' (trust cert, default) or '-No'
#   UA_OBJECTS       space-separated "schema.object" list in the MAIN DB (AppDb_MSG).
#   UA_DATA_OBJECTS  space-separated "schema.object" list in the DATA DB (AppDb_MSG_data).
#                    Either set => OBJECT-SCOPED: per-object generation, routed to the
#                    right DB (AppDb_MSG -> MSG_DB, AppDb_MSG_data -> DATA_DB). See affected-objects.sh.
#   UA_SCHEMAS   optional whole-schema list (legacy/manual); 'ALL' = every user schema.
#                Only used when UA_OBJECTS/UA_DATA_OBJECTS are both empty; runs against MSG_DB.
# =============================================================================
set -uo pipefail   # NOT -e: a per-object/-schema fault must not abort the whole sweep

SERVER="${SERVER:-localhost}"
PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set}"
MSG_DB="${MSG_DB:-AppDb_Dev}"
DATA_DB="${DATA_DB:-AppDb_MSG_Data_Dev}"
SQLCMD_ENC="${SQLCMD_ENC:--C}"
UA_DIR="${UA_DIR:-/tmp/unitautogen}"
TSQLT_DIR="${TSQLT_DIR:-/tmp/tsqlt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
UA_SCHEMAS="${UA_SCHEMAS:-}"
UA_OBJECTS="${UA_OBJECTS:-}"
UA_DATA_OBJECTS="${UA_DATA_OBJECTS:-}"

# Locate sqlcmd (PATH, then the usual mssql-tools locations) — same as ci-publish.sh.
SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "ERROR: sqlcmd not found." >&2; exit 0; }

# -I = QUOTED_IDENTIFIER ON (required: UnitAutogen's coverage reader uses XML .value()).
sqlq() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -b "$@"; }

mkdir -p "$ARTIFACTS_DIR"

# Dump an XML result to a file, stripping sqlcmd's header/dashes by emitting from the first
# '<' (-y 0 = unlimited width; -y 0 and -h -1 are mutually exclusive, so no -h -1 here).
dump() { # $1=db $2=query $3=outfile
    "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -y 0 \
        -d "$1" -Q "SET NOCOUNT ON; $2" 2>&1 | sed -n '/^[[:space:]]*</,$p' > "$3"
}

# --- object-list helpers (operate on a "schema.object ..." list) ------------
schemas_of()  { printf '%s\n' $1 | sed 's/\..*$//' | sort -u | tr '\n' ' '; }        # $1=objlist -> distinct schemas
objects_of()  { local tok; for tok in $1; do case "$tok" in "$2".*) printf '%s ' "${tok#*.}";; esac; done; }  # $1=objlist $2=schema
# ('sch','obj'),... for every object in the list (sanitized) — for the backfill VALUES.
values_all()  { local tok sch obj out=""; for tok in $1; do
                  sch="$(printf '%s' "${tok%%.*}" | tr -cd 'A-Za-z0-9_')"
                  obj="$(printf '%s' "${tok#*.}"  | tr -cd 'A-Za-z0-9_')"
                  [ -n "$sch" ] && [ -n "$obj" ] && out="$out,('$sch','$obj')"
                done; printf '%s' "${out#,}"; }

# Compact per-object status file for (DB $1, schema $2), straight from CoverageResult joined
# to sys.objects for the type. The PR-summary step buckets on these columns (real assertion
# failures vs objects the generator couldn't run). '~|~'-joined; one row per object:
#   schema ~|~ object ~|~ type ~|~ gen(0|1) ~|~ testability ~|~ pass ~|~ fail ~|~ err ~|~ skip ~|~ covLines ~|~ totLines ~|~ reason
# Filename is namespaced by DB so the two DBs' same-named schemas (e.g. sms) don't collide.
dump_summary() { # $1=DB $2=schema
    local DB="$1" s="$2"
    # -h -1 (no header) + -y 1024 (avoid truncating the concatenated row). NOT -W (mutually
    # exclusive with -y); trailing spaces trimmed in the pipe. COLLATE DATABASE_DEFAULT on the
    # sysname columns avoids a catalog-vs-DB collation conflict that yields an empty summary.
    "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" $SQLCMD_ENC -I -h -1 -y 1024 \
        -d "$DB" -Q "SET NOCOUNT ON;
        SELECT (cr.SchemaName COLLATE DATABASE_DEFAULT) + '~|~' + (cr.ProcName COLLATE DATABASE_DEFAULT) + '~|~'
             + CASE o.type WHEN 'P'  THEN 'procedure'
                           WHEN 'FN' THEN 'scalar function'
                           WHEN 'IF' THEN 'table-valued function'
                           WHEN 'TF' THEN 'table-valued function'
                           -- Unresolved (a backfilled object whose failed instrumentation left it
                           -- only as its '_orig' shadow, or otherwise not found): affected-objects
                           -- only ever emits procs/functions, so label it as such — never 'object'.
                           ELSE 'procedure/function' END + '~|~'
             + CAST(cr.GenSucceeded AS varchar(1)) + '~|~'
             + ISNULL(cr.Testability,'TESTABLE') + '~|~'
             + CAST(cr.TestsPassed  AS varchar(10)) + '~|~'
             + CAST(cr.TestsFailed  AS varchar(10)) + '~|~'
             + CAST(cr.TestsErrored AS varchar(10)) + '~|~'
             + CAST(cr.TestsSkipped AS varchar(10)) + '~|~'
             + CAST(ISNULL(cr.CoveredLines,0) AS varchar(10)) + '~|~'
             + CAST(ISNULL(cr.TotalLines,0)   AS varchar(10)) + '~|~'
             + LEFT(REPLACE(REPLACE(REPLACE(ISNULL(NULLIF(cr.NotTestableReason,''), ISNULL(cr.ErrorText,'')),
                    CHAR(13),' '), CHAR(10),' '), '~|~', '/'), 160)
        FROM   TestGen.CoverageResult cr
        -- Resolve the object type from its real name OR its '_orig' shadow (UnitAutogen renames
        -- the original to <name>_orig while instrumenting; a failed in-isolation run can leave it
        -- there, so a straight name join misses and the type reads 'object'). Prefer the exact
        -- name; restrict to testable types so a same-named non-proc can't win.
        OUTER  APPLY (SELECT TOP 1 x.type
                      FROM   sys.objects x
                      WHERE  SCHEMA_NAME(x.schema_id) = cr.SchemaName
                        AND  x.name IN (cr.ProcName, cr.ProcName + N'_orig')
                        AND  x.type IN ('P','FN','IF','TF')
                      ORDER  BY CASE WHEN x.name = cr.ProcName THEN 0 ELSE 1 END) o
        WHERE  cr.BatchId    = (SELECT MAX(BatchId) FROM TestGen.CoverageResult)
          AND  cr.SchemaName = N'$s'
        ORDER  BY cr.ProcName;" 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' > "$ARTIFACTS_DIR/summary.$DB.$s.txt"
}

# --- framework install (idempotent, per DB) ---------------------------------
UA_PATCHED=0
install_framework() { # $1=DB ; 0 ok, 1 fail
    local DB="$1"
    if ! sqlq -d "$DB" -h -1 -Q "SET NOCOUNT ON; IF SCHEMA_ID('tSQLt') IS NULL THROW 50000,'no',1;" >/dev/null 2>&1; then
        echo "==> Installing tSQLt into $DB ..."
        [ -f "$TSQLT_DIR/PrepareServer.sql" ] || { echo "WARN: $TSQLT_DIR/PrepareServer.sql missing."; return 1; }
        sqlq -i "$TSQLT_DIR/PrepareServer.sql" || { echo "WARN: PrepareServer failed."; return 1; }
        sqlq -d "$DB" -i "$TSQLT_DIR/tSQLt.class.sql" || { echo "WARN: tSQLt install failed for $DB."; return 1; }
    fi
    if ! sqlq -d "$DB" -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID('TestGen.GenerateAndCoverDatabase') IS NULL THROW 50000,'no',1;" >/dev/null 2>&1; then
        echo "==> Installing UnitAutogen into $DB (Linux .xel fix + object-scope filter) ..."
        [ -f "$UA_DIR/Install_UnitAutogen.sql" ] || { echo "WARN: $UA_DIR/Install_UnitAutogen.sql missing."; return 1; }
        if [ "$UA_PATCHED" = 0 ]; then
            cp "$UA_DIR/Install_UnitAutogen.sql" /tmp/ua_install.sql
            # (1) .xel directory split: match on '/' (Linux) or '\' (Windows). CHAR(92)='\'.
            sed -i "s|CHARINDEX('[\\]', REVERSE(physical_name))|CHARINDEX(CASE WHEN CHARINDEX('/',physical_name)>0 THEN '/' ELSE CHAR(92) END, REVERSE(physical_name))|g" /tmp/ua_install.sql
            grep -aFq "CASE WHEN CHARINDEX('/',physical_name)>0" /tmp/ua_install.sql \
                || echo "WARN: .xel path fix did not apply — coverage may read 0 on Linux."
            # (2) object-scope filter: restrict the enumeration to a caller-supplied #UA_Only
            #     (empty => no-op). Lets us generate one object at a time for fault isolation.
            sed -i "s|AND  (@SchemaFilter   IS NULL OR SCHEMA_NAME(o.schema_id) = @SchemaFilter)|&\n      AND  (NOT EXISTS (SELECT 1 FROM #UA_Only) OR o.name IN (SELECT name FROM #UA_Only))|g" /tmp/ua_install.sql
            grep -aFq "NOT EXISTS (SELECT 1 FROM #UA_Only)" /tmp/ua_install.sql \
                || echo "WARN: object-scope filter did not apply — falling back to whole-schema generation."
            UA_PATCHED=1
        fi
        sqlq -d "$DB" -i /tmp/ua_install.sql || { echo "WARN: UnitAutogen install failed for $DB."; return 1; }
    fi
    return 0
}

# Best-effort capture sanity check (utility.Log_ProcedureCall exists in the main DB).
smoke_check() { # $1=DB
    local DB="$1" SMOKE
    SMOKE="$(sqlq -d "$DB" -h -1 -Q "SET NOCOUNT ON;
        EXEC TestGen.GenerateAndRunCoverage @SchemaName=N'utility', @ProcName=N'Log_ProcedureCall', @OutputMode='TEXT';" 2>&1 | grep -i 'hits recorded' | tr -dc '0-9')"
    echo "    smoke [$DB]: coverage hits recorded = ${SMOKE:-0}"
    [ "${SMOKE:-0}" -gt 0 ] 2>/dev/null || echo "    WARN: 0 hits — coverage capture may not work here (see README)."
}

# --- object-scoped coverage for one DB (per-object generation) --------------
cover_db_objects() { # $1=DB $2=objlist(schema.object ...)
    local DB="$1" objlist="$2" sch obj safe schemas vals
    schemas="$(schemas_of "$objlist")"
    echo "    -- [$DB] object-scoped; schemas: $schemas"
    # Generate each object in its own batch so a self-transaction/Ops proc that aborts only
    # loses ITSELF (not its neighbours). #UA_Only (one name) drives the patched enumeration.
    for sch in $schemas; do
        for obj in $(objects_of "$objlist" "$sch"); do
            safe="$(printf '%s' "$obj" | tr -cd 'A-Za-z0-9_')"; [ -n "$safe" ] || continue
            sqlq -d "$DB" -Q "SET NOCOUNT ON;
                CREATE TABLE #UA_Only (name sysname PRIMARY KEY);
                INSERT INTO #UA_Only (name) VALUES ('$safe');
                EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter=N'$sch', @OutputMode='COBERTURA';" \
                >/dev/null 2>&1 || echo "       [$DB] $sch.$safe: generation call failed (will backfill)"
        done
    done
    # Consolidate the per-object batches into one (this DB's CoverageResult holds only this
    # run's rows), then BACKFILL a placeholder for any requested object that produced no row —
    # so nothing the PR changed is silently missing. All in one call so @b is a single value.
    vals="$(values_all "$objlist")"
    sqlq -d "$DB" -Q "SET NOCOUNT ON;
        DECLARE @b DATETIME2(3) = COALESCE((SELECT MAX(BatchId) FROM TestGen.CoverageResult), SYSUTCDATETIME());
        UPDATE TestGen.CoverageResult SET BatchId=@b WHERE BatchId <> @b;
        ${vals:+INSERT TestGen.CoverageResult
            (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,TestsErrored,TestsSkipped,ErrorText,RunAt,Testability,NotTestableReason)
         SELECT @b, r.sch, r.obj, 0,NULL,NULL,NULL,NULL,NULL,NULL,0,0,0,0,1,NULL,SYSUTCDATETIME(),'NOT_TESTABLE',
                N'no coverage produced - the generator could not run this object in isolation (often a self-transaction/Ops proc on SQL-for-Linux)'
         FROM (VALUES $vals) r(sch,obj)
         WHERE NOT EXISTS (SELECT 1 FROM TestGen.CoverageResult cr WHERE cr.SchemaName=r.sch AND cr.ProcName=r.obj);}" \
        >/dev/null 2>&1 || echo "       [$DB] consolidate/backfill warning"
    for sch in $schemas; do
        dump "$DB" "EXEC TestGen.GetCoverageCoberturaXml @SchemaFilter=N'$sch';" "$ARTIFACTS_DIR/coverage.$DB.$sch.xml"
        dump "$DB" "EXEC TestGen.GetTestResultsJunitXml  @SchemaFilter=N'$sch';" "$ARTIFACTS_DIR/junit.$DB.$sch.xml"
        dump_summary "$DB" "$sch"
    done
}

# --- whole-schema coverage for one DB (legacy UA_SCHEMAS / ALL) --------------
cover_db_schemas() { # $1=DB $2=schema-list
    local DB="$1" sch
    for sch in $2; do
        [ -n "$sch" ] || continue
        echo "    -- [$DB] whole schema: $sch"
        sqlq -d "$DB" -Q "SET NOCOUNT ON;
            CREATE TABLE #UA_Only (name sysname PRIMARY KEY);   -- empty => no filter
            EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter=N'$sch', @OutputMode='COBERTURA';" \
            >/dev/null 2>&1 || echo "       (schema $sch aborted mid-run — its coverage may be partial)"
        dump "$DB" "EXEC TestGen.GetCoverageCoberturaXml @SchemaFilter=N'$sch';" "$ARTIFACTS_DIR/coverage.$DB.$sch.xml"
        dump "$DB" "EXEC TestGen.GetTestResultsJunitXml  @SchemaFilter=N'$sch';" "$ARTIFACTS_DIR/junit.$DB.$sch.xml"
        dump_summary "$DB" "$sch"
    done
}

enumerate_all_schemas() { # $1=DB
    sqlq -d "$1" -h -1 -W -Q "SET NOCOUNT ON;
        SELECT DISTINCT SCHEMA_NAME(schema_id) FROM sys.procedures
        WHERE is_ms_shipped=0 AND SCHEMA_NAME(schema_id) NOT IN ('tSQLt','TestGen')
          AND SCHEMA_NAME(schema_id) NOT LIKE 'test[_]%';" 2>/dev/null | tr -d '\r'
}

# ===========================================================================
# main
# ===========================================================================
echo "==> Waiting for SQL Server at $SERVER,$PORT ..."
ready=0
for i in $(seq 1 60); do
    if sqlq -l 5 -Q "SELECT 1" >/dev/null 2>&1; then ready=1; echo "    ready"; break; fi
    sleep 3
done
[ "$ready" = "1" ] || { echo "WARN: SQL not ready; skipping coverage (report-only)."; exit 0; }

if [ -n "${UA_OBJECTS// /}" ] || [ -n "${UA_DATA_OBJECTS// /}" ]; then
    # Object-scoped, routed to the right DB. AppDb_MSG objects -> MSG_DB; AppDb_MSG_data -> DATA_DB.
    if [ -n "${UA_OBJECTS// /}" ]; then
        echo "==> Object-scoped coverage in main DB [$MSG_DB]. Objects: $UA_OBJECTS"
        if install_framework "$MSG_DB"; then
            smoke_check "$MSG_DB"
            cover_db_objects "$MSG_DB" "$UA_OBJECTS"
        fi
    fi
    if [ -n "${UA_DATA_OBJECTS// /}" ]; then
        echo "==> Object-scoped coverage in data DB [$DATA_DB]. Objects: $UA_DATA_OBJECTS"
        if install_framework "$DATA_DB"; then
            cover_db_objects "$DATA_DB" "$UA_DATA_OBJECTS"
        fi
    fi
else
    # Legacy whole-schema mode (manual), main DB only.
    if [ "$(printf '%s' "$UA_SCHEMAS" | tr '[:lower:]' '[:upper:]')" = "ALL" ]; then
        echo "==> UA_SCHEMAS=ALL — every user schema in $MSG_DB (slow, whole-DB sweep)."
        install_framework "$MSG_DB" || { echo "skipping (report-only)."; exit 0; }
        smoke_check "$MSG_DB"
        cover_db_schemas "$MSG_DB" "$(enumerate_all_schemas "$MSG_DB")"
    elif [ -n "${UA_SCHEMAS// /}" ]; then
        echo "==> UA_SCHEMAS override — covering in $MSG_DB: $UA_SCHEMAS"
        install_framework "$MSG_DB" || { echo "skipping (report-only)."; exit 0; }
        smoke_check "$MSG_DB"
        cover_db_schemas "$MSG_DB" "$UA_SCHEMAS"
    else
        echo "==> No UA_OBJECTS / UA_DATA_OBJECTS / UA_SCHEMAS provided — nothing to cover (report-only)."
        echo "    Pass UA_OBJECTS (+ UA_DATA_OBJECTS) from affected-objects.sh, or UA_SCHEMAS=ALL."
        exit 0
    fi
fi

echo "==> Done. Artifacts in $ARTIFACTS_DIR:"
ls -la "$ARTIFACTS_DIR" 2>/dev/null || true
echo "ci: UnitAutogen coverage complete (report-only)."
exit 0
