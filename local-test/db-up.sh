#!/usr/bin/env bash
# Ephemeral SQL Server 2022 container: provision the AppDb_MSG baseline databases from
# the current branch, seed, verify. Linux/CI parity of db-up.ps1 (PROJ-000 / PROJ-000).
#
#   ./db-up.sh                    # pull dev's dacpac from Jenkins, then stand up (default)
#   ./db-up.sh --branch PROJ-000  # pull that branch's dacpac from Jenkins
#   ./db-up.sh --build            # compile both dacpacs INSIDE Docker, then stand up
# Tear down:  docker compose -f local-test/docker-compose.yml down -v
#
# Docker is the ONLY host dependency. The dacpac build and the publish run inside the
# "tools" container (the same image CI uses: .NET 8 SDK + sqlpackage + sqlcmd), so no
# .NET SDK or sqlpackage is needed on the host, and one command works on every OS.
# (--build needs nothing but Docker; the default pull path also uses curl to fetch the
# prebuilt artifact.) Provisioning logic lives once, in ci-publish.sh, shared by CI and
# local — a local pass means the pipeline passes the same way.
#
# NOTE: AppDb_SIT is a separate US-DB database not yet in this repo, so it is not
# provisioned here — source its schema (extract from US, or add an SSDT project) first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$HERE"

SA_PASSWORD="${SA_PASSWORD:-Local_Test_P@ssw0rd1}"
PORT="${PORT:-14330}"
MSG_DB="${MSG_DB:-AppDb_Dev}"
DATA_DB="${DATA_DB:-AppDb_MSG_Data_Dev}"
BUILD=0
BRANCH="${BRANCH:-dev}"   # pull this branch's dacpac from Jenkins DB_Build (ignored with --build)
JENKINS_DB_BUILD="${JENKINS_DB_BUILD:-https://jenkins1.int.appdb.io/job/DB/job/AppDb_MSG_DB/job/DB_Build}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)    BUILD=1 ;;
        --branch)   shift; BRANCH="${1:?--branch needs a name}" ;;
        --branch=*) BRANCH="${1#*=}" ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v docker >/dev/null || { echo "docker not found — Docker is the only host dependency for this script." >&2; exit 1; }

COMPOSE=(docker compose -f docker-compose.yml)
CI_COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.ci.yml)

MSG_DACPAC="$REPO/AppDb_MSG/bin/Release/AppDb_MSG.dacpac"
DATA_DACPAC="$REPO/AppDb_MSG_data/bin/Release/AppDb_MSG_data.dacpac"

# Download a per-branch dacpac artifact from the Jenkins DB_Build multibranch job. Auth via
# JENKINS_USER/JENKINS_TOKEN if set (needed on the internal Jenkins over VPN).
fetch_dacpac() { # $1=artifact-path-under-workspace  $2=dest
    local enc="${BRANCH//\//%2F}"   # url-encode '/' for feature/x branches
    local url="$JENKINS_DB_BUILD/job/$enc/lastSuccessfulBuild/artifact/$1"
    mkdir -p "$(dirname "$2")"
    local auth=(); [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_TOKEN:-}" ]] && auth=(-u "$JENKINS_USER:$JENKINS_TOKEN")
    echo "    fetch: $url"
    curl -fSL "${auth[@]}" -o "$2" "$url" \
        || { echo "Failed to download dacpac for branch '$BRANCH' from $url — check the branch's DB_Build job succeeded, VPN, and JENKINS_USER/JENKINS_TOKEN." >&2; exit 1; }
}

# Both compose files read these via ${VAR:-default}; exporting lets this script's flags drive
# the sqlserver service AND the tools container in lock-step (same password/port/DB names).
export SA_PASSWORD MSG_DB DATA_DB
export HOST_PORT="$PORT"

# Default (pull) path fetches the prebuilt dacpac on the host (curl only). --build needs no
# host toolchain — the tools container compiles from source.
if [[ "$BUILD" != "1" ]]; then
    echo "==> Pulling dacpacs from Jenkins DB_Build/$BRANCH ..."
    command -v curl >/dev/null || { echo "curl not found (needed only for the pull path — use --build to compile inside Docker instead)" >&2; exit 1; }
    fetch_dacpac "AppDb_MSG/bin/Release/AppDb_MSG.dacpac"           "$MSG_DACPAC"
    fetch_dacpac "AppDb_MSG_data/bin/Release/AppDb_MSG_data.dacpac" "$DATA_DACPAC"
    for d in "$MSG_DACPAC" "$DATA_DACPAC"; do
        [[ -f "$d" ]] || { echo "Dacpac not found after fetch: $d" >&2; exit 1; }
    done
fi

echo "==> Starting a fresh SQL Server 2022 container..."
"${COMPOSE[@]}" up -d --force-recreate sqlserver
cid="$("${COMPOSE[@]}" ps -q sqlserver)"
health=starting
for _ in $(seq 1 60); do
    health="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
    echo "    health: $health"; [[ "$health" == "healthy" ]] && break; sleep 3
done
[[ "$health" == "healthy" ]] || { echo "SQL Server did not become healthy" >&2; exit 1; }

# Build (only with --build) + bootstrap + publish + seed + verify — ALL inside the tools
# container. `run --rm --build tools` with no command uses the compose default (dotnet build
# AppDb_MSG.sln && ci-publish.sh); overriding the command with just ci-publish.sh skips the
# build and publishes the already-fetched dacpacs.
if [[ "$BUILD" == "1" ]]; then
    echo "==> Building dacpacs + publishing in the tools container (Docker-only)..."
    "${CI_COMPOSE[@]}" run --rm --build tools
else
    echo "==> Publishing the prebuilt dacpacs in the tools container (Docker-only)..."
    "${CI_COMPOSE[@]}" run --rm --build tools bash local-test/ci-publish.sh
fi

echo ""
echo "AppDb_MSG test databases ready: $MSG_DB, $DATA_DB."
echo "  Connection: Server=localhost,$PORT;Database=$MSG_DB;User Id=sa;Password=$SA_PASSWORD;TrustServerCertificate=True"
echo "  Tear down:  docker compose -f local-test/docker-compose.yml down -v"
