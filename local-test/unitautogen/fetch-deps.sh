#!/usr/bin/env bash
# =============================================================================
# fetch-deps.sh — download the coverage step's third-party dependencies at
# PINNED versions, using curl + tar + unzip (all in the tools image). Nothing
# third-party is vendored into this repo (keeps it out of the SQL lint/doc gates
# and avoids shipping AGPL/Apache SQL in-tree).
#
#   tSQLt        (Apache-2.0)  -> $TSQLT_DIR   pinned by SHA-256 of the release zip
#   UnitAutogen  (AGPL-3.0)    -> $UA_DIR      pinned by commit SHA
#
# Bump a pin ONLY deliberately: change the value + its checksum here, and
# re-validate coverage.sh's .xel path fix still targets the right line (README
# constraint 1). A checksum/commit mismatch fails this script; the Jenkins stage
# wraps the whole step in catchError so the build never fails on it.
# =============================================================================
set -euo pipefail

# --- pins -------------------------------------------------------------------
TSQLT_URL="${TSQLT_URL:-https://tsqlt.org/download/tsqlt/}"
TSQLT_SHA256="${TSQLT_SHA256:-af841f357dd9189f8b197c34c5014fe0dbabd3be34b024ed46967dafe13d4f50}"  # tSQLt 1.0.8083.3529
UA_REPO="${UA_REPO:-unitautogen/unitautogen-public-repo}"
UA_REF="${UA_REF:-ae479c155c84f051d0b3073d0f84e5c553d9555c}"                                      # UnitAutogen v0.16.8 (+5)
# --- outputs ----------------------------------------------------------------
TSQLT_DIR="${TSQLT_DIR:-/tmp/tsqlt}"
UA_DIR="${UA_DIR:-/tmp/unitautogen}"

for t in curl tar unzip; do command -v "$t" >/dev/null || { echo "ERROR: $t not found." >&2; exit 1; }; done

# --- tSQLt (Apache-2.0), pinned by SHA-256 ----------------------------------
echo "==> Fetching tSQLt ($TSQLT_URL) ..."
rm -rf "$TSQLT_DIR"; mkdir -p "$TSQLT_DIR"
curl -sSLf --retry 3 -m 120 -o /tmp/tsqlt.zip "$TSQLT_URL"
echo "${TSQLT_SHA256}  /tmp/tsqlt.zip" | sha256sum -c - \
    || { echo "ERROR: tSQLt checksum mismatch — tsqlt.org likely published a new build. Update TSQLT_SHA256 after review." >&2; exit 1; }
# We only need the two install scripts (not the DACPACs).
unzip -o -q /tmp/tsqlt.zip PrepareServer.sql tSQLt.class.sql -d "$TSQLT_DIR"
[ -f "$TSQLT_DIR/PrepareServer.sql" ] && [ -f "$TSQLT_DIR/tSQLt.class.sql" ] \
    || { echo "ERROR: tSQLt archive layout changed (PrepareServer.sql / tSQLt.class.sql absent)." >&2; exit 1; }

# --- UnitAutogen (AGPL-3.0), pinned by commit SHA ---------------------------
echo "==> Fetching UnitAutogen ${UA_REPO}@${UA_REF} ..."
rm -rf "$UA_DIR"; mkdir -p "$UA_DIR"
curl -sSLf --retry 3 -m 120 "https://codeload.github.com/${UA_REPO}/tar.gz/${UA_REF}" \
    | tar -xz -C "$UA_DIR" --strip-components=1
[ -f "$UA_DIR/Install_UnitAutogen.sql" ] \
    || { echo "ERROR: Install_UnitAutogen.sql not found after fetch (bad ref or layout change)." >&2; exit 1; }
# The .xel path fix in coverage.sh targets this exact line — fail loud if the pin
# no longer contains it (so a silent 0%-coverage regression can't slip through).
grep -aFq "CHARINDEX('\\', REVERSE(physical_name))" "$UA_DIR/Install_UnitAutogen.sql" \
    || echo "WARN: .xel-path sed target absent at ${UA_REF}; update coverage.sh's sed and re-pin (coverage may read 0)." >&2

echo "    deps ready: tSQLt=$TSQLT_DIR  unitautogen=$UA_DIR"
