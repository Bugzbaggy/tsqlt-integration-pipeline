---
name: db-unit-test-synth
description: Synthesize high-coverage tSQLt tests for SQL Server objects. Introspects each SP/function/view/table, reasons about which seed rows hit which branch, and emits characterization tests + accurate golden baselines. Use to raise auto-test coverage toward 100% and to backfill tests for untested objects.
argument-hint: "schema.object [schema.object ...] | schema | . | (blank for branch changes)"
---

# DB Unit-Test Synthesizer

You generate tSQLt tests for this SSDT project. Your value over the mechanical `local-test/tsqlt/gen-*.sh`
generators is one thing they cannot do: **read each object's body and work out the exact seed rows that
force every branch to execute.** That branch reasoning is what lifts line coverage from ~30% to ~95%.

## Read this first — what "100% accurate / 100% coverage" actually means

Two different problems. Only one is mechanical. Do not conflate them, and never claim more than this:

- **Coverage** (every line/branch *executed*) — reachable mechanically. You compute the seeds that hit
  each branch, so the generated tests run ~100% of the reachable code. Achievable; that is the goal here.
- **Accuracy** (the assertion checks the *correct* value) — a machine cannot know "correct" without an
  oracle. You can only assert **"returns what it returns today"** — a *golden / characterization* baseline.
  That is a perfect *regression* oracle (it catches any future change) but it does **not** know whether
  today's behaviour is right. The "should be 111" correctness judgement is a human's.

So what you deliver, stated honestly: **maximal reachable coverage + faithful characterization baselines**,
plus a short list of objects whose behaviour encodes a business rule (money, routing, dedup, auth) flagged
`needs_human_oracle: true` for a person to write the real `@Expected`. Never label a golden baseline as
"correct" — label it "current behaviour, pinned". This honesty is the whole point of the layered design
(`tests/curated/` exists precisely because the machine can't supply the correctness oracle).

## Scope

- **No argument** — objects changed on this branch: `git diff dev...HEAD --name-only -- 'AppDb_MSG/**/*.sql' 'AppDb_MSG_data/**/*.sql'`.
- **`schema.object`** (one or more) — exactly those objects.
- **`schema`** (e.g. `rt`) — every SP/function/view in that schema, both DBs.
- **`.`** — full backfill across `AppDb_MSG` + `AppDb_MSG_data` (large; work schema-by-schema).

AppDb_MSG objects live in DB `AppCatalog` on SG / `AppDb` in ID-UK-US / `AppDb_Dev` in CI.
AppDb_MSG_data objects live in DB `AppDb_Data` (`AppDb_MSG_Data_Dev` in CI). Test each object in the DB it lives in.

## Workflow (per object)

### 1. Capture structure — from a schema source, never needed from production
Run the introspection script against a DB that already has the schema. In CI that is the just-published
throwaway DB; locally, your `db-up.sh` container. **Structure never requires production.**

```bash
SERVER=localhost PORT=1433 SA_PASSWORD=... DB=AppDb_Dev \
  bash .claude/skills/db-unit-test-synth/scripts/introspect.sh rt.fnSubAccountRoutingGroup > /tmp/fixture.rt.fnSubAccountRoutingGroup.json
```

It emits a fixture skeleton: signature, referenced tables (what to `FakeTable`), each dep table's columns
(type/nullability/identity/computed/default), the FK closure (parents you must seed first), CHECK
constraint definitions, and the raw object definition. Read the JSON — you will fill the `branches` array.

### 2. (Optional, guarded) Sample REAL enum domains — production read replica only
Only to make seeds *realistic* and to learn the true set of values a branch predicate compares against
(e.g. the actual `TrafficCategory` / `Status` codes). This is the only step that may touch production, and
it is fenced hard:

- **Target the READ-ONLY SECONDARY only.** For SG that is **`region1-node1`** (verified: `AppCatalog` and
  `AppDb_Data` are `Updateability = READ_ONLY` there — writes are physically impossible). Never the
  `sg-primary` / `region1-node2` primary.
- Run via the MCP `mcp__appdb-sql__execute_query` with `instance_name: "region1-node1"`. The sampler
  `scripts/sample-domains.sql` self-guards: it `RAISERROR`s and returns nothing unless
  `DATABASEPROPERTYEX(DB_NAME(),'Updateability') = 'READ_ONLY'`.
- **Column all/deny.** Sample a column ONLY if its name fails the denylist `config/sensitive.deny`
  (msg/body/content/phone/msisdn/email/name/token/secret/key/password/pan/card/dob/… ) **and** it is
  low-cardinality (`COUNT(DISTINCT) <= 50`). Those are enums/status/type/category — safe, and exactly the
  values that make seeds valid. High-cardinality or denylisted columns get synthetic type-correct values
  instead. You pull a *domain list of distinct values*, never a joined-back row, so no record is ever
  reconstructed.
- Read-uncommitted, `TOP 50`, `LOCK_TIMEOUT 3000` — zero blocking on prod.

If you cannot reach a read-only secondary, skip this step entirely and use synthetic values from the CHECK
constraints and type metadata. Coverage is unaffected; only seed realism is.

### 3. Reason the branches — THIS is your job, not the script's
Read `definition` in the fixture. Enumerate every branch: each `IF`, `CASE WHEN`, `WHERE`/`HAVING`
predicate, each `JOIN` that can match/not-match, each `EXISTS`/`NOT EXISTS`, `ISNULL`/`COALESCE` fork, and
`@param`-driven path. For **each** branch, write the minimal seed set that forces that predicate true (and,
for the negative case, a seed that forces it false) while satisfying the FK closure and CHECK constraints
from step 1. Prefer the real domain values from step 2. Record them in `branches[]`:

```json
"branches": [
  { "id": "default-plan/any-operator wins",
    "seed": [ {"table":"rt.RoutingPlanCoverage","row":{"RoutingPlanId":500,"Country":"AF","OperatorId":null,"TrafficCategory":"DEF","RoutingGroupId":111,"Deleted":0}} ],
    "call": {"args":["108","AF"]},
    "needs_human_oracle": false },
  { "id": "deleted coverage excluded even when country passed",
    "seed": [ {"...":"same + a Deleted=1 decoy with RoutingGroupId 999"} ],
    "call": {"args":["108","AF"]},
    "needs_human_oracle": false }
]
```

Flag `needs_human_oracle: true` when the branch decides money, routing selection, dedup, auth, or anything
where "current output" is not self-evidently "correct output" — that branch becomes a `tests/curated/` stub.

### 4. Emit the test + capture the golden baseline
```bash
node .claude/skills/db-unit-test-synth/scripts/emit-tsqlt.mjs /tmp/fixture.rt.fnSubAccountRoutingGroup.json > tests/characterization/AppDb_MSG/rt.gen.sql
```
The emitter writes one tSQLt class per object: `FakeTable`s every dep, seeds each branch's rows inside a
rolled-back transaction, calls the object, and writes an `AssertEquals` **against a placeholder** expected.
Then run it once in the throwaway DB to capture the actual return and freeze that as the baseline — that is
the accurate regression oracle (no human needed). For `needs_human_oracle:true` branches the emitter writes
a curated stub under `tests/curated/<schema>/` with `@Expected = /* TODO: a human states the correct value */`
instead of a captured one.

### 5. Verify before you hand it back
- Every emitted test **compiles and runs** in the throwaway DB (load the schema file, `EXEC tSQLt.Run`).
- Re-run twice → identical result (deterministic). If a branch depends on `GETDATE/NEWID/RAND/@@`, do not
  freeze a value — mark it non-deterministic and skip the assert (cover the line, don't pin the value).
- Report coverage honestly from the run: line % from the coverage summary; **branch % is `n/a` for
  procedures/TVFs on SQL-for-Linux** (row-existence branches aren't reachable via XEvents) — say `n/a`,
  never a fabricated number. Only scalar-function branches get a real %.

## Validating a change to this skill

Two suites, both run against a throwaway DB — never production:

```bash
# SQL side: object-type coverage, large definitions, idempotency, error paths,
# injection refusal, and a read-only proof. 22 checks.
cd local-test && docker compose -f docker-compose.yml -f docker-compose.ci.yml run --rm   tools bash .claude/skills/db-unit-test-synth/tests/run-validation.sh

# Emitter: quote/injection escaping, type formatting, the never-fabricate-an-expected
# rule, the tSQLt "test" prefix, determinism. 17 checks.
node .claude/skills/db-unit-test-synth/tests/emit-tests.mjs
```

Both must be green before this skill changes. The read-only check counts **user** tables only —
Query Store is `READ_WRITE` on the test DB and writes to internal (`is_ms_shipped=1`) tables
whenever any query runs, so a naive total row count drifts without anything being written.

## Hard rules (do not violate)
- **Never write to production.** Structure comes from CI/dev; only enum-domain *lists* come from prod, and
  only from a `READ_ONLY` secondary through the self-guarding sampler.
- **Never copy a production row into a test.** Synthetic values only; sampled *distinct domain values* are
  allowed, full rows are not.
- **Never assert a golden value is "correct".** It is "current behaviour, pinned". Correctness = curated.
- **Never invent a coverage or branch number.** Measured, or `n/a`.
- Follow repo conventions: no brackets on schema.object, tabs, standard header. Tests go under `tests/`
  (excluded from the sql-doc gate).
