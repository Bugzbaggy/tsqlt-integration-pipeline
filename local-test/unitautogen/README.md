# UnitAutogen coverage (report-only)

Auto-generates [tSQLt](https://tsqlt.org) tests for the branch's stored procedures and
measures **line coverage**, emitting Cobertura + JUnit per schema. Runs as the
`📊 Coverage (UnitAutogen, report-only)` stage of the integration pipeline
([`pipelines/integration-test/Jenkinsfile`](../../pipelines/integration-test/Jenkinsfile)).

> **Report-only, non-blocking.** [`coverage.sh`](coverage.sh) always exits 0, and the
> Jenkins stage is wrapped in `catchError(buildResult: 'SUCCESS')` with its own 20-min
> timeout. It publishes an informational signal; **it never fails the build**. Do not
> make it a merge gate without first resolving the constraints below.

## Layout

| Path | Role |
|---|---|
| [`coverage.sh`](coverage.sh) | driver: install tSQLt + framework (per DB), patch, **per-object generation** in the right DB, consolidate + **backfill** dropped objects, export |
| [`affected-schemas.sh`](affected-schemas.sh) | print the schemas this branch/PR changes (scopes the sweep to a PR — see below) |
| [`affected-objects.sh`](affected-objects.sh) | print the **objects** (`schema.object`, procs/functions only) this PR changes; optional `AppDb_MSG` / `AppDb_MSG_data` arg splits them by project so each is covered in the DB it lives in (`UA_OBJECTS` / `UA_DATA_OBJECTS`) |
| [`fetch-deps.sh`](fetch-deps.sh) | fetch tSQLt + UnitAutogen at **pinned versions** (nothing vendored in-repo) |
| [`../docker-compose.unitautogen.yml`](../docker-compose.unitautogen.yml) | the `unitautogen` service (reuses the tools image) |

**Pins (both in `fetch-deps.sh`):** UnitAutogen `ae479c1` (v0.16.8, AGPL, pinned commit);
tSQLt `1.0.8083.3529` (Apache-2.0, pinned by SHA-256 of the release zip). Neither is
vendored — they stay out of the repo's SQL lint/doc gates. Bump a pin deliberately (value
+ checksum) and re-validate the `.xel` path fix (constraint 1).

## What it does, per PR

For each changed proc/function — in the DB it lives in (`AppDb_MSG` → `AppDb_Dev`,
`AppDb_MSG_data` → `AppDb_MSG_Data_Dev`, both provisioned by `ci-publish.sh`):
1. auto-generate a `test_<proc>` tSQLt class (one test per analyzable branch),
2. run those tests (tables mocked) → pass/fail per proc,
3. instrument a shadow copy and measure **line coverage** via Extended Events,
4. export `coverage.<db>.<schema>.xml` (Cobertura) + `junit.<db>.<schema>.xml` +
   `summary.<db>.<schema>.txt` to `artifacts/` (filenames namespaced by DB so the two
   DBs' same-named schemas — e.g. `sms` — don't collide).

## Scope — which schemas run (this is what keeps it off the 20-min timeout)

`coverage.sh` picks what to report by this precedence:

| Env | Behaviour |
|---|---|
| `UA_OBJECTS="<schema.object …>"` + `UA_DATA_OBJECTS` *(preferred)* | **Object-scoped, per DB.** `UA_OBJECTS` are covered in `MSG_DB` (`AppDb_Dev`), `UA_DATA_OBJECTS` in `DATA_DB` (`AppDb_MSG_Data_Dev`). Set them from `affected-objects.sh AppDb_MSG` / `affected-objects.sh AppDb_MSG_data`. Both empty ⇒ no testable object changed ⇒ nothing to report. |
| `UA_SCHEMAS` unset / empty | the schemas **this branch/PR changes** — via [`affected-schemas.sh`](affected-schemas.sh). Whole-schema report (legacy fallback when no objects given). |
| `UA_SCHEMAS="<list>"` | exactly those schemas in `MSG_DB` (explicit override) |
| `UA_SCHEMAS=ALL` | every user schema in `MSG_DB` — the whole-DB sweep; **slow (~20 min), can hit the stage timeout.** Opt-in only. |

So a PR touching one proc reports on that one object; the whole-DB sweep is deliberate.

> **Per-object generation — each changed object in its own batch.** UnitAutogen rolls back the
> **whole batch** if any one proc leaves an open transaction, and a connection-recovery from
> one proc can cascade and silently drop the *rest* of the batch (`Msg 266/3998`; observed:
> `cfg`, 265 procs → empty summary, and 8-of-13 / 2-of-3 partial losses even after schema
> scoping). So in object-scoped mode `coverage.sh` runs `GenerateAndCoverDatabase` **once per
> object** — an install-time patch restricts its enumeration to a caller-supplied `#UA_Only`
> temp table (one name) — so a bad proc only loses **itself**. The per-object batches are then
> consolidated into one, and any requested object that produced **no** row is **backfilled**
> with an explicit "generation aborted" placeholder — so nothing the PR changed is ever
> silently missing. Procs **and** functions (`P/FN/IF/TF`), across both DBs, are covered.

**Kubernetes note:** the `mssql-2022` sidecar has no `git`, so `coverage.sh` can't auto-scope
there. Compute the list in a git-capable container (e.g. the `dotnet-8` build container) and pass
it — in the build stage:

```groovy
env.UA_SCHEMAS = sh(returnStdout: true, script: 'bash local-test/unitautogen/affected-schemas.sh').trim()
```

`coverage.sh` then uses it (empty ⇒ nothing changed ⇒ it skips). `affected-schemas.sh` exits
non-zero only when it genuinely can't determine (no git / bad base ref), so guard with `|| true`
if you don't want a failed diff to fail the build.

## Baseline results — one-time whole-DB run (SQL Server 2022 **for Linux**)

> CI now runs **scoped to a PR** (see Scope above), not the whole DB. These are one-time baseline
> figures from a full `UA_SCHEMAS=ALL` sweep of the **1084** user procs in `AppDb_Dev`
> (`sys.procedures WHERE is_ms_shipped=0`).

- **51 of 88** procs that produced coverage reached **≥90% line coverage**; avg ≈ 74.5%. (Most
  procs are `NOT_TESTABLE` without the CLR predicate seeder — constraint 3 — so the measurable
  set is ~88, not all 1084.)
- Ceiling: `cfg.Account_CompanyId_Update` **100% line / 100% branch**; `tpl.Template_GetMany`
  100%; `tpl.Template_Add` 100% — **independently reproduced**.
- Weak spot — data-shape-heavy procs: `core.ReferralCode_Check` 42.9%, because its branches gate on
  row existence (`IF NOT EXISTS (SELECT … FROM …)`), which needs the predicate seeding this
  platform can't do (constraint 3).

## Four constraints found in live testing — read before relying on this

1. **`.xel` path fix is required on Linux (applied automatically).** UnitAutogen derives
   the Extended-Events file directory by splitting the log path on `\` only; on Linux that
   yields a bogus path → **0% coverage**. `coverage.sh` rewrites that line (separator-aware,
   via `CHAR(92)`) before install. If a future pin drops the target line, `fetch-unitautogen.sh`
   warns and coverage silently reads 0 until the sed is updated. Target line:
   `CHARINDEX('\', REVERSE(physical_name))` in `Install_UnitAutogen.sql`.

2. **Never one whole-DB call — always per schema.** A single
   `GenerateAndCoverDatabase @SchemaFilter=NULL` over AppDb_MSG aborts at the final commit
   (`Msg 266/3998`): one proc leaves an open transaction and the **entire** run's coverage
   rolls back (observed: 1,121 procs → only 58 results survived). `coverage.sh` invokes
   **per schema** so a fault isolates to one schema.

3. **No branch/data-shape seeding on Linux.** UnitAutogen's predicate parser is a SQLCLR
   **UNSAFE** assembly; SQL Server on Linux loads **SAFE only** (`Msg 10342`). So
   `TestGen.PredicateInbox` stays empty and existence/COUNT/scalar-subquery branches fall
   back to `NOT_TESTABLE`. **Line coverage + test pass/fail are the trustworthy signals;
   branch coverage is best-effort.** (This is why `coverage.sh` does **not** install the
   CLR parser.)

4. **Line classifier is imperfect.** For some formatting it marks comment/blank lines
   executable (unhittable → caps %) and real statements non-executable. Treat per-proc %
   as indicative, not exact.

5. **One coverage run per SQL instance at a time.** Coverage uses a **server-scoped** XE
   session (`CREATE EVENT SESSION [TestGenCoverage] ON SERVER`), so two coverage runs against
   the *same* instance collide and stall. Fine in CI — each pipeline has its own ephemeral
   server — but don't point two runs at one shared instance.

Plus **AGPL-3.0** + **v0.16.8-beta** — an unsupported pre-1.0 copyleft tool, fetched and run
as a standalone CI tool (not linked or redistributed). Confirm this is acceptable for the example
toolchain. tSQLt is Apache-2.0.

## How it runs (current pipeline — docker-compose)

The stage reuses the tools image; the agent needs only Docker + outbound access to
`tsqlt.org` and `codeload.github.com` (the pinned dep fetches). After the schema is published:

```bash
# SQL already up + schema published by the earlier stages, then:
docker compose -f local-test/docker-compose.yml -f local-test/docker-compose.unitautogen.yml \
    run --rm --build unitautogen
# -> artifacts/coverage.<schema>.xml, artifacts/junit.<schema>.xml
```

By default this covers only the schemas the branch changed (via `affected-schemas.sh`, which
works here because the tools image has `git` and the repo — incl. `.git` — is bind-mounted). Pin
the set explicitly, or force the whole DB, with `UA_SCHEMAS` (see **Scope** above):

```bash
UA_SCHEMAS="cfg tpl utility" docker compose ... run --rm --build unitautogen   # exactly these
UA_SCHEMAS=ALL                docker compose ... run --rm --build unitautogen   # whole DB (slow)
```

## Migration path — DevOps `mssql-2022` Kubernetes image

Same driver, run inside the `mssql-2022` container (`sqlservr` on `localhost`). `coverage.sh`
is portable: it needs only `sqlcmd`, a reachable server, and the deps that `fetch-deps.sh`
downloads (needs `unzip` for tSQLt). Set `SQLCMD_ENC=-No` to match that image's encryption default.

```groovy
stage('UnitAutogen coverage (report-only)') {
  agent { kubernetes { inheritFrom 'db-dotnet-builder'; defaultContainer 'mssql-2022' } }
  steps {
    container('mssql-2022') {
      catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
        sh '''
          export PATH=$PATH:/opt/mssql-tools18/bin
          SA='CiTest#2024!'
          MSSQL_SA_PASSWORD="$SA" ACCEPT_EULA=Y /opt/mssql/bin/sqlservr &
          for i in $(seq 1 30); do sqlcmd -S localhost -U sa -P "$SA" -No -Q "SELECT 1" 2>/dev/null && break; sleep 5; done
          # ... publish schema into AppDb_Dev (SERVER=localhost bash local-test/ci-publish.sh) ...
          TSQLT_DIR=/tmp/tsqlt UA_DIR=/tmp/unitautogen bash local-test/unitautogen/fetch-deps.sh
          SERVER=localhost PORT=1433 SA_PASSWORD="$SA" SQLCMD_ENC="-No" \
          TSQLT_DIR=/tmp/tsqlt UA_DIR=/tmp/unitautogen \
          ARTIFACTS_DIR="$WORKSPACE/artifacts" bash local-test/unitautogen/coverage.sh
        '''
      }
    }
    junit testResults: 'artifacts/junit.*.xml', allowEmptyResults: true
    archiveArtifacts artifacts: 'artifacts/*.xml', allowEmptyArchive: true
  }
}
```
