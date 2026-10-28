# UnitAutogen coverage (report-only)

Auto-generates [tSQLt](https://tsqlt.org) tests for the branch's stored procedures and
measures **line coverage**, emitting Cobertura + JUnit per schema. Runs as the
`📊 Coverage (UnitAutogen, report-only)` stage of the integration pipeline
([`pipeline/Jenkinsfile`](../../pipeline/Jenkinsfile)).

> **Report-only, non-blocking.** [`coverage.sh`](coverage.sh) always exits 0 (once
> `SA_PASSWORD` is set), and the Jenkins stage wraps it in a Groovy `try/catch` around its own
> 20-minute `timeout` — not `catchError`, which does not reliably suppress a firing timeout — so
> a fault or timeout marks the build UNSTABLE instead of failing it. It publishes an informational
> signal; **it never fails the build**. One caveat: the pipeline's shipped `post` block reports
> any non-SUCCESS result to GitHub as a `failure` commit status, so if that status is a required
> check, a Coverage timeout or fault blocks the merge. Do not make it a merge gate without first
> resolving the constraints below.

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
   DBs' same-named schemas — e.g. `msg` — don't collide).

## Scope — which schemas run (this is what keeps it off the 20-min timeout)

`coverage.sh` picks what to report by this precedence:

| Env | Behaviour |
|---|---|
| `UA_OBJECTS="<schema.object …>"` + `UA_DATA_OBJECTS` *(preferred)* | **Object-scoped, per DB.** `UA_OBJECTS` are covered in `MSG_DB` (`AppDb_Dev`), `UA_DATA_OBJECTS` in `DATA_DB` (`AppDb_MSG_Data_Dev`). Set them from `affected-objects.sh AppDb_MSG` / `affected-objects.sh AppDb_MSG_data`. Both empty ⇒ no testable object changed ⇒ nothing to report. |
| `UA_SCHEMAS="<list>"` | exactly those schemas in `MSG_DB` (explicit override) |
| `UA_SCHEMAS=ALL` | every user schema in `MSG_DB` — the whole-DB sweep; **slow (~20 min), can hit the stage timeout.** Opt-in only. |
| all of the above unset / empty | **nothing is covered** — `coverage.sh` prints *nothing to cover* and exits 0. It does not self-scope; a caller runs [`affected-schemas.sh`](affected-schemas.sh) / [`affected-objects.sh`](affected-objects.sh) and passes the result in. |

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

**Kubernetes note (implemented — see the Jenkinsfile):** `coverage.sh` never computes its own
scope, and the `mssql-2022` sidecar has no `git` anyway. Compute the lists in a git-capable
container (the `dotnet-8` build container) and pass them in — in the build stage:

```groovy
env.UA_OBJECTS      = sh(returnStdout: true, script: 'bash local-test/unitautogen/affected-objects.sh AppDb_MSG || true').trim()
env.UA_DATA_OBJECTS = sh(returnStdout: true, script: 'bash local-test/unitautogen/affected-objects.sh AppDb_MSG_data || true').trim()
```

The coverage stage (and the contract, characterization, baseline and fixture stages) run only
when at least one of those is non-empty, and `coverage.sh` then uses them verbatim. The build
stage also computes `UA_SCHEMAS` with `affected-schemas.sh`, but `coverage.sh` only falls back
to it when both object lists are empty. Both helpers exit non-zero only when they genuinely
can't determine (no git / bad base ref), hence the `|| true` so a failed diff doesn't fail the
build.

## Baseline results — one-time whole-DB run (SQL Server 2022 **for Linux**)

> CI now runs **scoped to a PR** (see Scope above), not the whole DB. These are one-time baseline
> figures from a full `UA_SCHEMAS=ALL` sweep of every user proc in `AppDb_Dev`
> (`sys.procedures WHERE is_ms_shipped=0`).

- **51 of 88** procs that produced coverage reached **≥90% line coverage**; avg ≈ 74.5%. (Most
  procs are `NOT_TESTABLE` without the CLR predicate seeder — constraint 3 — so the measurable
  set is only a small fraction of the user procs.)
- Ceiling: `cfg.Account_CompanyId_Update` **100% line / 100% branch**; `tpl.Template_GetMany`
  100%; `tpl.Template_Add` 100% — **independently reproduced**.
- Weak spot — data-shape-heavy procs: `core.ReferralCode_Check` 42.9%, because its branches gate on
  row existence (`IF NOT EXISTS (SELECT … FROM …)`), which needs the predicate seeding this
  platform can't do (constraint 3).

## Five constraints found in live testing — read before relying on this

1. **`.xel` path fix is required on Linux (applied automatically).** UnitAutogen derives
   the Extended-Events file directory by splitting the log path on `\` only; on Linux that
   yields a bogus path → **0% coverage**. `coverage.sh` rewrites that line (separator-aware,
   via `CHAR(92)`) before install. If a future pin drops the target line, `fetch-deps.sh`
   warns and coverage silently reads 0 until the sed is updated. Target line:
   `CHARINDEX('\', REVERSE(physical_name))` in `Install_UnitAutogen.sql`.

2. **Never one whole-DB call — always per schema.** A single
   `GenerateAndCoverDatabase @SchemaFilter=NULL` over AppDb_MSG aborts at the final commit
   (`Msg 266/3998`): one proc leaves an open transaction and the **entire** run's coverage
   rolls back (observed: only a small fraction of the procs' results survived). `coverage.sh` invokes
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

## Running it locally (docker-compose)

This is the **local dev** path, not what CI does — the pipeline runs `coverage.sh` directly in
the `mssql-2022` sidecar of a Kubernetes pod agent and uses no docker-compose at all (see
*How it runs in CI* below). Locally it reuses the tools image; you need only Docker + outbound access to
`tsqlt.org` and `codeload.github.com` (the pinned dep fetches). After the schema is published:

```bash
# SQL already up + schema published by the earlier stages, then:
docker compose -f local-test/docker-compose.yml -f local-test/docker-compose.unitautogen.yml \
    run --rm --build unitautogen
# -> artifacts/coverage.<db>.<schema>.xml, artifacts/junit.<db>.<schema>.xml,
#    artifacts/summary.<db>.<schema>.txt   (per covered schema; <db> = AppDb_Dev here)
```

`coverage.sh` does **not** self-scope. With `UA_OBJECTS`, `UA_DATA_OBJECTS` and `UA_SCHEMAS` all
empty it prints *nothing to cover* and exits 0 — it contains no `git` call and never invokes
`affected-schemas.sh`; a caller runs that and passes the result in. Note the compose service only
forwards `UA_SCHEMAS`, so to use the preferred object scope run `coverage.sh` directly. Pin
the set explicitly, or force the whole DB, with `UA_SCHEMAS` (see **Scope** above):

```bash
UA_SCHEMAS="cfg tpl utility" docker compose ... run --rm --build unitautogen   # exactly these
UA_SCHEMAS=ALL                docker compose ... run --rm --build unitautogen   # whole DB (slow)
```

## How it runs in CI — `mssql-2022` Kubernetes sidecar (implemented)

**This is what the shipped pipeline does** — see the `📊 Coverage (UnitAutogen, report-only)` stage
in [`Jenkinsfile`](../../pipeline/Jenkinsfile). Same driver, run inside the
`mssql-2022` container (`sqlservr` on `localhost`). `coverage.sh` is portable: it needs only
`sqlcmd`, a reachable server, and the deps that `fetch-deps.sh` downloads (needs `unzip` for
tSQLt). The shipped stage leaves `SQLCMD_ENC` at its default `-C` (trust the server
certificate); `-No` (optional encryption) also works.

The sketch below shows the shape; the shipped stage differs in ways that matter — the sa
password comes from the `SA_PASSWORD_CRED` **credential** (never a literal); SQL Server is
started once, in its own earlier stage; the scope is computed in the `dotnet-8` container
(which has git) and passed in via `UA_OBJECTS` / `UA_DATA_OBJECTS` / `UA_SCHEMAS`, because the
sidecar has no git and `coverage.sh` does not self-scope; the run is wrapped in a Groovy
`try/catch` around a 20-minute `timeout` instead of `catchError`; and the same stage also
generates ready-to-finish curated-test starters (`gen-starter-tests.sh`) into
`artifacts/starters/`. Read the Jenkinsfile for the authoritative version.

```groovy
stage('UnitAutogen coverage (report-only)') {
  agent { kubernetes { inheritFrom POD_TEMPLATE; defaultContainer 'mssql-2022' } }
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
