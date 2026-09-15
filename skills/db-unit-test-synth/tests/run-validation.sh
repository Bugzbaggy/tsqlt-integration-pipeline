#!/usr/bin/env bash
# Validation suite for db-unit-test-synth. Run against a throwaway DB (local-test container or
# the CI pod) — NEVER production. Exits non-zero if any check fails.
#
#   # from the repo root, inside the tools container (SERVER/PORT/SA_PASSWORD/MSG_DB/DATA_DB set):
#   bash .claude/skills/db-unit-test-synth/tests/run-validation.sh
#
#   # or from the host via compose:
#   cd local-test && docker compose -f docker-compose.yml -f docker-compose.ci.yml run --rm \
#     tools bash .claude/skills/db-unit-test-synth/tests/run-validation.sh
#
# Covers: object-type coverage, large definitions (multi-chunk base64), zero-dependency objects,
# synonym references, idempotency, error paths, injection refusal, and a read-only proof.
cd "$(dirname "$0")/../../../.." || exit 2   # repo root
SKILL=.claude/skills/db-unit-test-synth/scripts/introspect.sh
SAMPLER=.claude/skills/db-unit-test-synth/scripts/sample-domains.sql
OUT=artifacts/validation
SQLCMD="$(command -v sqlcmd || echo /opt/mssql-tools18/bin/sqlcmd)"
SERVER="${SERVER:-localhost}"; PORT="${PORT:-1433}"
MSG_DB="${MSG_DB:-AppDb_Dev}"; DATA_DB="${DATA_DB:-AppDb_MSG_Data_Dev}"
: "${SA_PASSWORD:?SA_PASSWORD must be set}"
rm -rf "$OUT"; mkdir -p "$OUT"
PASSES=0; FAILS=0
pass(){ echo "PASS  $1"; PASSES=$((PASSES+1)); }
fail(){ echo "FAIL  $1  -> $2"; FAILS=$((FAILS+1)); }
q(){ "$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" -C -I -h -1 -W -d "$1" -Q "SET NOCOUNT ON; $2" 2>&1 | tr -d '\r'; }

# ---------- 1. object-type coverage ----------
run_one(){ # label db object
  if DB="$2" bash "$SKILL" "$3" > "$OUT/$1.json" 2>"$OUT/$1.err"
  then pass "introspect [$1] $3"; else fail "introspect [$1] $3" "$(head -3 "$OUT/$1.err" | tr '\n' ' ')"; fi
}
run_one scalar_fn   "$MSG_DB"  cls.fnClassificationTemplateError
run_one inline_tvf  "$MSG_DB"  dbo.SplitStrings_XML
run_one proc        "$MSG_DB"  map.RoutingManager_SupplierList
run_one multi_tvf   "$MSG_DB"  cp.fnSubAccount_GetByFilter
run_one trigger     "$MSG_DB"  cls.Category_DataChanged
run_one table       "$MSG_DB"  ms.Survey
run_one view        "$MSG_DB"  rt.vwRoutingTier
run_one big_defn    "$MSG_DB"  map.PricingPlanFutureStaging_Validate   # ~28k chars: multi-chunk base64
run_one no_deps     "$MSG_DB"  cp.CmGroup_ContactDelete                # zero dependency tables
run_one synonym_ref "$MSG_DB"  cp.Report_SmsTraffic_GetOperators       # dm_sql_referenced_entities can throw
run_one data_db     "$DATA_DB" cp.AccountWallet_Change_InRegion        # per-DB routing

# ---------- 2. idempotency ----------
DB="$MSG_DB" bash "$SKILL" rt.fnSubAccountRoutingGroup > "$OUT/idem1.json" 2>/dev/null
DB="$MSG_DB" bash "$SKILL" rt.fnSubAccountRoutingGroup > "$OUT/idem2.json" 2>/dev/null
cmp -s "$OUT/idem1.json" "$OUT/idem2.json" && pass "idempotent: two runs byte-identical" \
                                           || fail "idempotent" "outputs differ"

# ---------- 3. error paths ----------
if DB="$MSG_DB" bash "$SKILL" nope.NotAThing >/dev/null 2>"$OUT/e1.err"; then
  fail "missing object exits non-zero" "exited 0"
else grep -qi 'not found' "$OUT/e1.err" && pass "missing object -> actionable message" \
                                        || fail "missing object message" "$(head -1 "$OUT/e1.err")"; fi
DB=NoSuchDb_Zzz bash "$SKILL" rt.fnSubAccountRoutingGroup >/dev/null 2>&1 \
  && fail "bad DB exits non-zero" "exited 0" || pass "bad DB -> non-zero exit"
DB="$MSG_DB" SA_PASSWORD="WrongPwd!!" timeout 60 bash "$SKILL" rt.fnSubAccountRoutingGroup >/dev/null 2>&1 \
  && fail "bad password exits non-zero" "exited 0" || pass "bad password -> non-zero exit, no hang"

# ---------- 4. injection refusal (name is interpolated into the T-SQL) ----------
INJ_OK=1
for BAD in "rt.x' ; SELECT 1 AS pwned; --" "rt.x; DROP TABLE y" "rt.x OR 1=1" "../../etc/passwd" "rt"; do
  OUT_TXT="$(DB="$MSG_DB" bash "$SKILL" "$BAD" 2>&1)"
  if [ $? -eq 0 ] || ! echo "$OUT_TXT" | grep -q 'refusing unsafe'; then
    fail "injection refused: [$BAD]" "not refused"; INJ_OK=0
  fi
done
[ $INJ_OK -eq 1 ] && pass "injection: all unsafe object names refused before any SQL runs"
DB="AppDb_Dev; DROP DATABASE x" bash "$SKILL" rt.fnSubAccountRoutingGroup 2>&1 | grep -q 'refusing unsafe database' \
  && pass "injection: unsafe database name refused" || fail "injection: db name" "not refused"

# ---------- 5. production guard on the sampler ----------
if q "$MSG_DB" "" >/dev/null 2>&1; then :; fi
GUARD="$("$SQLCMD" -S "$SERVER,$PORT" -U sa -P "$SA_PASSWORD" -C -I -h -1 -W -d "$MSG_DB" -i "$SAMPLER" 2>&1)"
echo "$GUARD" | grep -qi 'REFUSED' \
  && pass "sample-domains.sql REFUSES on a READ_WRITE database" \
  || fail "sample-domains.sql guard" "did not refuse: $(echo "$GUARD" | head -1)"

# ---------- 6. read-only proof (USER objects only; Query Store writes to internal tables) ----------
USER_ROWS="SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats ps JOIN sys.objects o ON o.object_id=ps.object_id WHERE ps.index_id IN (0,1) AND o.is_ms_shipped=0;"
OBJ_CNT="SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped=0;"
DDL_MAX="SELECT ISNULL(CONVERT(varchar(30), MAX(modify_date), 126),'none') FROM sys.objects WHERE is_ms_shipped=0;"
for DBN in "$MSG_DB" "$DATA_DB"; do
  B1=$(q "$DBN" "$USER_ROWS" | tr -dc 0-9); B2=$(q "$DBN" "$OBJ_CNT" | tr -dc 0-9); B3=$(q "$DBN" "$DDL_MAX" | tr -d ' ')
  for o in rt.fnSubAccountRoutingGroup ms.Survey cp.CmGroup_ContactDelete; do DB="$DBN" bash "$SKILL" "$o" >/dev/null 2>&1; done
  A1=$(q "$DBN" "$USER_ROWS" | tr -dc 0-9); A2=$(q "$DBN" "$OBJ_CNT" | tr -dc 0-9); A3=$(q "$DBN" "$DDL_MAX" | tr -d ' ')
  [ "$B1" = "$A1" ] && [ "$B2" = "$A2" ] && [ "$B3" = "$A3" ] \
    && pass "read-only [$DBN]: user rows/objects/DDL-date all unchanged" \
    || fail "read-only [$DBN]" "rows $B1->$A1 objs $B2->$A2 ddl $B3->$A3"
done

# ---------- 7. static safety ----------
NONTEMP=$(grep -nEi '(^|[^_[:alnum:]])(INSERT|UPDATE|DELETE|DROP|TRUNCATE|ALTER|MERGE)[[:space:]]+' "$SKILL" \
          | grep -vE '(INSERT|UPDATE|DELETE|DROP|TRUNCATE|ALTER|MERGE)[[:space:]]+#' | grep -E '[A-Za-z]')
[ -z "$NONTEMP" ] && pass "static: every write targets a # temp table (tempdb), no user objects" \
                  || fail "static: non-temp write" "$(echo "$NONTEMP" | head -1)"
grep -qEi 'sp_executesql|EXEC[[:space:]]*\(' "$SKILL" \
  && fail "static: no dynamic SQL" "found EXEC/sp_executesql" \
  || pass "static: no dynamic SQL (object name is a bound sysname variable)"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
