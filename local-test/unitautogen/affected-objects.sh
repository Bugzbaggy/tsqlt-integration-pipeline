#!/usr/bin/env bash
# =============================================================================
# affected-objects.sh — print the DB objects this branch/PR changes, restricted to
# the UnitAutogen-testable object types (stored procedures + functions), one per line
# as "<schema>.<object>".
#
#   affected-objects.sh              # both projects (AppDb_MSG + AppDb_MSG_data)
#   affected-objects.sh AppDb_MSG       # only AppDb_MSG project objects   (-> AppDb_Dev)
#   affected-objects.sh AppDb_MSG_data  # only AppDb_MSG_data objects       (-> AppDb_MSG_Data_Dev)
#
# The optional project filter lets the pipeline route each object to the DB it actually
# lives in: coverage.sh takes AppDb_MSG objects (UA_OBJECTS) against MSG_DB and AppDb_MSG_data
# objects (UA_DATA_OBJECTS) against DATA_DB — both are provisioned by ci-publish.sh.
#
# Companion to affected-schemas.sh. That one scopes the coverage sweep to a whole
# SCHEMA; this one lets coverage.sh scope generation+report down to exactly the objects a
# PR touched (per-object generation), so the PR comment shows coverage of the change
# instead of the entire schema — see UA_OBJECTS / UA_DATA_OBJECTS in coverage.sh.
#
# Only files under a "Stored Procedures/" or "Functions/" folder are emitted: tables,
# views, types, security and storage objects are not generated or tested by UnitAutogen,
# so a PR that changes only those produces no output here (coverage is then skipped).
#
# Object name = the .sql file stem. This repo's convention is one object per file with a
# matching name (see CLAUDE.md); if a file's CREATE name ever differs from its filename,
# that object is simply not matched in the report filter (under-reported, never wrong).
#
# Base-ref precedence and committed-diff semantics are identical to affected-schemas.sh:
#   $UA_BASE_REF -> $CHANGE_TARGET (Jenkins PR builds) -> 'dev', diffed three-dot
#   ("$base"...HEAD) against the merge-base so a bind-mounted Windows checkout's CRLF/mode
#   noise doesn't flag every file. Commit local changes before relying on the scope.
#
# Exit 0 = computed OK (stdout may be EMPTY = no testable object changed -> cover nothing).
# Exit 3 = not usable here (no git / not a work tree)  -> caller should skip or set UA_OBJECTS.
# Exit 4 = base ref or merge-base could not be resolved.
# =============================================================================
set -uo pipefail

PROJECT_FILTER="${1:-}"   # '', 'AppDb_MSG', or 'AppDb_MSG_data'
case "$PROJECT_FILTER" in ''|AppDb_MSG|AppDb_MSG_data) ;; *)
    echo "affected-objects: project filter must be AppDb_MSG or AppDb_MSG_data (got '$PROJECT_FILTER')" >&2; exit 3 ;;
esac
BASE_REF="${UA_BASE_REF:-${CHANGE_TARGET:-dev}}"
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

command -v git >/dev/null 2>&1 || { echo "affected-objects: git not found" >&2; exit 3; }
cd "$REPO" 2>/dev/null || { echo "affected-objects: repo dir not found: $REPO" >&2; exit 3; }
git config --global --add safe.directory "$REPO" >/dev/null 2>&1 || true
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "affected-objects: not a git work tree ($REPO)" >&2; exit 3; }

base="$(git rev-parse --verify -q "origin/${BASE_REF}^{commit}" || git rev-parse --verify -q "${BASE_REF}^{commit}" || true)"
[ -n "$base" ] || { echo "affected-objects: base ref '${BASE_REF}' not found (tried origin/${BASE_REF} and ${BASE_REF})" >&2; exit 4; }
git merge-base "$base" HEAD >/dev/null 2>&1 || { echo "affected-objects: no merge-base between HEAD and ${BASE_REF}" >&2; exit 4; }

# COMMITTED changed *.sql under a testable type folder -> "<schema>.<object>".
#   $2 = schema (2nd path segment), $3 = type folder, $NF = file. NF>=4 so an object
#   directly under the schema (no type folder) is skipped. The type folder carries a
#   space ("Stored Procedures"), which awk -F/ preserves as a single field.
#   $1 = project (AppDb_MSG | AppDb_MSG_data), only kept when it matches PROJECT_FILTER (if set).
git diff --name-only "$base"...HEAD -- AppDb_MSG AppDb_MSG_data \
    | awk -F/ -v pf="$PROJECT_FILTER" '
        /\.sql$/ && NF>=4 && $2 !~ /^(bin|obj|Scripts|Security|Storage)$/ {
            if ((pf == "" || $1 == pf) && ($3 == "Stored Procedures" || $3 == "Functions")) {
                obj = $NF; sub(/\.sql$/, "", obj)
                print $2 "." obj
            }
        }' \
    | sort -u
