#!/usr/bin/env bash
# =============================================================================
# affected-schemas.sh — print the DB schemas this branch/PR changes (one per line),
# so the report-only coverage sweep can be scoped to just what a PR touches instead
# of the whole DB (which times out at ~20 min — see unitautogen/README.md).
#
# Reusable by both pipelines and local dev. coverage.sh calls it automatically when
# UA_SCHEMAS is unset; a Jenkins K8s stage (no git in the mssql sidecar) can call it in
# a git-capable container and pass the result as UA_SCHEMAS.
#
# Base ref precedence:  $UA_BASE_REF  ->  $CHANGE_TARGET (Jenkins PR builds)  ->  'dev'.
# Diff is COMMITTED changes vs the merge-base ("$base"...HEAD), NOT the working tree: a
# working-tree diff over a bind-mounted Windows checkout inside a Linux container flags every
# file as changed (CRLF/mode mismatch) and is slow. CI runs against a committed branch, so this
# is correct there — commit local changes before relying on the scope.
#
# Exit 0 = computed OK (stdout may be EMPTY, meaning no .sql changed -> cover nothing).
# Exit 3 = not usable here (no git binary / not a work tree)  -> caller should skip or set UA_SCHEMAS.
# Exit 4 = base ref or merge-base could not be resolved.
# =============================================================================
set -uo pipefail

BASE_REF="${UA_BASE_REF:-${CHANGE_TARGET:-dev}}"
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

command -v git >/dev/null 2>&1 || { echo "affected-schemas: git not found" >&2; exit 3; }
cd "$REPO" 2>/dev/null || { echo "affected-schemas: repo dir not found: $REPO" >&2; exit 3; }
# Bind-mounted/CI checkouts are often flagged 'dubious ownership'; trust this path.
git config --global --add safe.directory "$REPO" >/dev/null 2>&1 || true
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "affected-schemas: not a git work tree ($REPO)" >&2; exit 3; }

# Resolve the base commit (origin/<ref>, then <ref>). Fetching it is the caller's job.
base="$(git rev-parse --verify -q "origin/${BASE_REF}^{commit}" || git rev-parse --verify -q "${BASE_REF}^{commit}" || true)"
[ -n "$base" ] || { echo "affected-schemas: base ref '${BASE_REF}' not found (tried origin/${BASE_REF} and ${BASE_REF})" >&2; exit 4; }
git merge-base "$base" HEAD >/dev/null 2>&1 || { echo "affected-schemas: no merge-base between HEAD and ${BASE_REF}" >&2; exit 4; }

# COMMITTED changed *.sql (three-dot = vs merge-base of base and HEAD) -> their schema folder
# (2nd path segment), excluding build/infra dirs that are not schemas. The .sql filter is in awk
# (not a piped grep) so "no changes" is an empty result with exit 0, not a grep exit-1.
git diff --name-only "$base"...HEAD -- AppDb_MSG AppDb_MSG_data \
    | awk -F/ '/\.sql$/ && NF>=3 && $2 !~ /^(bin|obj|Scripts|Security|Storage)$/ { print $2 }' \
    | sort -u
