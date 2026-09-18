# Integration-test pipeline

Stands up an **ephemeral SQL Server 2022 container**, publishes **this branch's** schema
into it, runs the integration/E2E suite against it, and tears it down — instead of running
tests against the shared Dev DB (which suffered schema/data drift and cross-branch
interference).

```
docker compose up sqlserver ─▶ tools container: dotnet build + ci-publish.sh
                             (bootstrap + publish + seed + verify)
                            ─▶ run E2E suite ─▶ docker compose down -v   (always)
```

Everything runs in containers, so a **Linux Jenkins agent needs only Docker** — the .NET SDK,
`sqlpackage` and `sqlcmd` all live in the tools image, not on the agent.

## Pieces

| File | Role |
|---|---|
| `Jenkinsfile` | the pipeline (Linux agent) |
| [`local-test/docker-compose.yml`](../../local-test/docker-compose.yml) | the SQL Server 2022 service |
| [`local-test/docker-compose.ci.yml`](../../local-test/docker-compose.ci.yml) | CI overlay: the `tools` container |
| [`local-test/tools.Dockerfile`](../../local-test/tools.Dockerfile) | tools image — .NET 8 SDK + `sqlpackage` + `sqlcmd` |
| [`local-test/ci-publish.sh`](../../local-test/ci-publish.sh) | bootstrap + publish + seed + verify (runs inside the tools container) |

Run it by hand (any Linux/macOS box with Docker):

```bash
docker compose -f local-test/docker-compose.yml up -d --wait
docker compose -f local-test/docker-compose.yml -f local-test/docker-compose.ci.yml run --rm --build tools
# ... run E2E against localhost,14330 ...
docker compose -f local-test/docker-compose.yml -f local-test/docker-compose.ci.yml down -v
```

> Local Windows dev uses [`local-test/db-up.ps1`](../../local-test/db-up.ps1) instead (same
> lifecycle, native PowerShell). CI is Linux and uses the container flow above.

## Agent requirements

| Requirement | Notes |
|---|---|
| Linux agent | set the node `label` in the Jenkinsfile to your Linux Docker agent |
| Docker (Linux containers) | runs `mcr.microsoft.com/mssql/server:2022-latest` + builds the tools image |

## Wiring in the E2E suite

The integration/E2E tests live outside this repo (`appdb-AppCatalog`), so the
**"Integration / E2E tests" stage is the plug-in point**. The DB is provisioned and
schema-verified (`VERIFY OK`) before it runs; connect using the exported env vars:

| Env var | Value |
|---|---|
| `TEST_SQL_SERVER` | `localhost,14330` |
| `TEST_SQL_DB` | `AppDb_Dev` |
| `TEST_SQL_USER` | `sa` |
| `TEST_SQL_PASSWORD` | throwaway container password (torn down at end of run) |

Two ways to run the suite:

1. **`E2E_TEST_COMMAND` build parameter** — a shell command that invokes your runner.
2. **Trigger a downstream job** — uncomment the `build job: 'E2E/…'` block in the stage and
   pass the `TEST_SQL_*` values as parameters.

Until one of those is set, the run is a **schema smoke gate** (build + publish + `VERIFY OK`)
and prints the connection string for a manual/downstream run.

## Auto-generated regression tests (report-only)

Between publish and the E2E stage, the pipeline runs report-only checks **scoped to the
procedures/functions your PR changed** (it loads that object's per-schema test file and runs
only its class). None can block a merge — only publish + `VERIFY OK` gates.

| Stage | What it checks | Runner / source |
|---|---|---|
| `📐 Contract tests` | your changed proc/fn's **interface** (parameters + result-set columns) is unchanged, from catalog metadata (no execution) | [`run-contract-tests.sh`](../../local-test/tsqlt/run-contract-tests.sh) over [`tests/contract/`](../../tests/contract) |
| `🔬 Characterization tests` | a changed **deterministic scalar function** still returns the same **output** for a fixed input | [`run-characterization-tests.sh`](../../local-test/tsqlt/run-characterization-tests.sh) over [`tests/characterization/`](../../tests/characterization) |
| `🧮 Auto-generate missing baselines` | generates a contract/characterization baseline for a changed object that has **none yet** (report-only; never overwrites an existing baseline) | [`autogen-missing-baselines.sh`](../../local-test/tsqlt/autogen-missing-baselines.sh) |
| `✅ tSQLt regression tests` | hand-written **curated** tSQLt tests with real assertions | [`run-curated-tests.sh`](../../local-test/tsqlt/run-curated-tests.sh) over `tests/curated/` |

Contract + characterization baselines are **auto-generated, no hand-written assertions** — an
intended change makes a test RED and you regenerate the baseline (a reviewable diff).
Characterization only ever covers **deterministic scalar functions**
([`char-eligible.where.sql`](../../local-test/tsqlt/char-eligible.where.sql) is the single
definition of that scope, shared by the generator and the runner); a changed stored procedure
is out of scope, not a gap.

A changed object with **no baseline at all yet** (new, or never generated) used to just report
"nothing ran". The `🧮 Auto-generate missing baselines` stage now generates it for you and
attaches it to the build instead — **nothing is pushed to your branch by default**, and the PR
comment says so. It keeps the result only when regenerating the schema file was purely additive
(zero deleted lines); any deletion means an *existing* baseline changed, which it reverts and
leaves for a human. The `AUTO_COMMIT_BASELINES` build parameter turns on committing + pushing
the generated file to the PR branch instead, with its own guardrails (see the Jenkinsfile's
`autoCommitBaselines()`).

Full detail: [`local-test/README.md`](../../local-test/README.md) ("Contract, characterization & curated tests").

## Coverage (report-only)

Between publish and the E2E stage, the `📊 Coverage (UnitAutogen, report-only)` stage
auto-generates tSQLt tests for the branch's stored procedures and measures **line coverage**,
publishing **Cobertura + JUnit** per schema (`artifacts/*.xml`). It reuses the tools image via
[`local-test/docker-compose.unitautogen.yml`](../../local-test/docker-compose.unitautogen.yml)
and runs [`local-test/unitautogen/coverage.sh`](../../local-test/unitautogen/coverage.sh).

**Report-only / non-blocking:** wrapped in `catchError(buildResult: 'SUCCESS')` with a 20-min
timeout — a fault or timeout marks the stage `UNSTABLE`, never failing the build. Needs outbound
access to `codeload.github.com` (the pinned UnitAutogen fetch). On SQL Server for Linux most
procs reach 90–100% line coverage; branch coverage is best-effort. Full details, constraints,
and the Kubernetes (`mssql-2022`) variant: [`local-test/unitautogen/README.md`](../../local-test/unitautogen/README.md).
