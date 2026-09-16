#!/usr/bin/env bash
# =============================================================================
# ci-publish.sh — bootstrap -> publish -> seed -> verify against an ALREADY-RUNNING
# SQL Server 2022, for CI / Kubernetes. Extracted from db-up.sh so a "tools"
# container (with sqlcmd + sqlpackage) can call it directly — e.g. a sidecar in the
# same pod as the mssql container, reaching it over localhost.
#
# This script does NOT start/stop SQL or build dacpacs; the pod/pipeline owns that.
# Prereqs in the tools container: sqlcmd (mssql-tools18) and sqlpackage on PATH,
# the repo checked out (so the local-test assets + built dacpacs are readable).
#
# Config via environment (all have sensible in-pod defaults):
#   SERVER        SQL host              (default: localhost — shared with the mssql sidecar)
#   PORT          SQL port              (default: 1433)
#   SA_PASSWORD   sa password           (REQUIRED — inject from a K8s Secret)
#   MSG_DB        main DB name          (default: AppDb_Dev)
#   DATA_DB       data-layer DB name    (default: AppDb_MSG_Data_Dev)
#   STUB_DB       non-existent stub DB  (default: AppDb_XDB_Stub) for undeployed cross-region synonyms
#   MSG_DACPAC    AppDb_MSG dacpac path    (default: <repo>/AppDb_MSG/bin/Release/AppDb_MSG.dacpac)
#   DATA_DACPAC   AppDb_MSG_data dacpac    (default: <repo>/AppDb_MSG_data/bin/Release/AppDb_MSG_data.dacpac)
#
# Exit code: non-zero on any failure (verify.sql THROWs -> build fails). Prints VERIFY OK on success.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

SERVER="${SERVER:-localhost}"
PORT="${PORT:-1433}"
SA_PASSWORD="${SA_PASSWORD:?SA_PASSWORD must be set (inject from the mssql-sa Secret)}"
MSG_DB="${MSG_DB:-AppDb_Dev}"
DATA_DB="${DATA_DB:-AppDb_MSG_Data_Dev}"
STUB_DB="${STUB_DB:-AppDb_XDB_Stub}"
MSG_DACPAC="${MSG_DACPAC:-$REPO/AppDb_MSG/bin/Release/AppDb_MSG.dacpac}"
DATA_DACPAC="${DATA_DACPAC:-$REPO/AppDb_MSG_data/bin/Release/AppDb_MSG_data.dacpac}"
# Server principals are excluded on the sqlpackage CLI — it ignores ExcludeObjectTypes
# when set inside a .publish.xml profile, so it MUST be passed here.
EXCLUDE='Logins;Users;RoleMembership;Permissions;Credentials;ServerRoleMembership;DatabaseScopedCredentials'

# Locate sqlcmd (PATH, then the usual mssql-tools locations).
SQLCMD="$(command -v sqlcmd || true)"
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools18/bin/sqlcmd ] && SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -z "$SQLCMD" ] && [ -x /opt/mssql-tools/bin/sqlcmd ]   && SQLCMD=/opt/mssql-tools/bin/sqlcmd
[ -n "$SQLCMD" ] || { echo "ERROR: sqlcmd not found on PATH or in /opt/mssql-tools*." >&2; exit 1; }
command -v sqlpackage >/dev/null || { echo "ERROR: sqlpackage not found on PATH (dotnet tool install -g microsoft.sqlpackage)." >&2; exit 1; }

sqlq() { "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" -C -b "$@"; }

for d in "$MSG_DACPAC" "$DATA_DACPAC"; do
    [ -f "$d" ] || { echo "ERROR: dacpac not found: $d (build stage must produce it)." >&2; exit 1; }
done

# 1. Wait for SQL to accept connections (readiness).
echo "==> Waiting for SQL Server at $SERVER,$PORT ..."
ready=0
for i in $(seq 1 60); do
    if sqlq -l 5 -Q "SELECT 1" >/dev/null 2>&1; then ready=1; echo "    ready"; break; fi
    echo "    [$i] not ready yet"; sleep 3
done
[ "$ready" = "1" ] || { echo "ERROR: SQL Server did not become ready in time." >&2; exit 1; }

publish_db() { # $1=dacpac  $2=targetDb  $3=bootstrap-file ; remaining args = /v: variables
    local dacpac="$1" db="$2" boot="$3"; shift 3
    echo "==> Bootstrapping $db (DB + filegroup files + DMK) ..."
    sqlq -v "DbName=$db" -i "$HERE/$boot"
    echo "==> Publishing $db ..."
    sqlpackage /Action:Publish "/SourceFile:$dacpac" \
        "/Profile:$HERE/AppDb_MSG.local.publish.xml" \
        "/TargetServerName:$SERVER,$PORT" "/TargetDatabaseName:$db" \
        /TargetUser:sa "/TargetPassword:$SA_PASSWORD" /TargetTrustServerCertificate:True \
        "/p:ExcludeObjectTypes=$EXCLUDE" "$@"
}

# AppDb_MSG_Data -> the real data DB (resolve those synonyms). Undeployed cross-region
# targets -> a non-existent stub DB so their synonyms resolve to nothing and procs
# create via deferred name resolution (pointing them at $MSG_DB causes Msg 207).
MSG_VARS=("/v:AppDb_MSG_Data=$DATA_DB")
for v in AppDb_Analytics AppDb_Connect AppDb_Routing AppDb_Support ZenSphere AppDb_Voice LkSrv_MSG_ID LkSrv_MSG_UK; do
    MSG_VARS+=("/v:$v=$STUB_DB")
done

# Order matters: main DB before data DB — AppDb_MSG_data views validate their synonym
# target (e.g. core.Account) at CREATE time (Msg 5313), so AppDb_Dev must exist first.
publish_db "$MSG_DACPAC"  "$MSG_DB"  "bootstrap.sql"      "${MSG_VARS[@]}"
publish_db "$DATA_DACPAC" "$DATA_DB" "bootstrap.data.sql" "/v:AppDb_MSG=$MSG_DB"

echo "==> Seeding $MSG_DB (FK-ordered) ..."
for f in $(ls "$HERE"/seed/*.sql | sort); do
    echo "    seed: $(basename "$f")"
    sqlq -d "$MSG_DB" -i "$f"
done

echo "==> Verifying $MSG_DB ..."
sqlq -d "$MSG_DB" -i "$HERE/verify.sql"

echo ""
echo "ci-publish: done — $MSG_DB + $DATA_DB provisioned and VERIFY OK."
