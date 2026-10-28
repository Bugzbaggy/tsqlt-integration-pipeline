# Integration-test pipeline

Publishes **this branch's** schema into a throwaway SQL Server 2022, runs a stack of checks
against it, and posts one summary comment on the PR — instead of testing against the shared
Dev DB (which suffered schema/data drift and cross-branch interference).

```
K8s pod agent (POD_TEMPLATE)
  ├── dotnet-8      container:  dotnet build, git, the .NET tooling
  └── mssql-2022    container:  the SQL Server 2022 sidecar  ← defaultContainer

  build dacpacs ─▶ publish + VERIFY OK ─▶ 6 report-only check stages ─▶ E2E ─▶ PR comment
```

**No docker-compose in CI.** The pod's `mssql-2022` sidecar is reachable over `localhost`, so
`ci-publish.sh` and `coverage.sh` talk to it directly. There is no explicit teardown — the pod
is recycled. The `docker-compose*.yml` files stay in the repo for the **local dev** workflow
(`db-up.sh` / `db-up.ps1`) and for a generic docker-only agent; this pipeline does not use them.

## Agent requirements

| Requirement | Notes |
|---|---|
| Kubernetes pod template `POD_TEMPLATE` (default `sql-ci-agent`) | must provide a `dotnet-8` container (with git + the checkout) and an `mssql-2022` container (SQL Server 2022 + sqlcmd + sqlpackage) |
| Jenkins credential `SA_PASSWORD_CRED` (default `sql-sa-password`) | must match the `MSSQL_SA_PASSWORD` the `mssql-2022` container is provisioned with, or nothing can connect |
| Jenkins credential `GITHUB_CRED` (default `github-ci-token`) | username/password credential (app id + token) — commit status, the PR comment, and the opt-in baseline push |
| `BOT_GIT_NAME` (default `ci-baseline-bot`) | author name of the opt-in auto-baseline commit |
| Outbound to `tsqlt.org` and `codeload.github.com` | the pinned tSQLt + UnitAutogen fetch (`fetch-deps.sh`) |

These are script-level variables at the top of the [`Jenkinsfile`](Jenkinsfile); rename them to match your
own pod template and credential IDs. `REPO_NAME` (in its `environment` block) and the `example`
GitHub owner in its GitHub URLs are the other site-specific values.

## Stages

Ten stages. **Only the first three can fail the build**, plus stage 10 once you wire an E2E
command into it — the six check stages can mark themselves UNSTABLE but never fail the build.
Stages 5–9 run only when the PR changed a stored procedure or function. Stages 4–8 use
`catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE')`; Coverage instead uses its own
`try/catch` around a `timeout`, because `catchError` does not reliably suppress the
`FlowInterruptedException` a firing `timeout()` raises. Unlike stages 4–8, which keep the build
result SUCCESS, that catch marks the whole build UNSTABLE, and the `post` block reports any
non-SUCCESS result to GitHub as a `failure` commit status — so if that status is a required
check, a Coverage timeout or fault blocks the merge. (`skipStagesAfterUnstable` is
deliberately *not* set, so an UNSTABLE report stage doesn't skip the stages after it.)

| # | Stage | Gates? | What it does |
|---|---|:---:|---|
| 1 | 🔨 Build dacpacs | **yes** | `dotnet build AppDb_MSG.sln -c Release`; also computes the PR's affected schemas/objects into `UA_SCHEMAS` / `UA_OBJECTS` / `UA_DATA_OBJECTS` (this container has git; the sidecar doesn't) |
| 2 | 🚀 Start SQL Server | **yes** | launches `sqlservr` inside the sidecar. Needed because the Jenkins Kubernetes plugin replaces every sidecar's entrypoint with `sleep`, so the image never starts SQL Server itself — `setsid nohup` detaches it so it outlives this step |
| 3 | 🗄️ Publish + verify schema | **yes** | [`ci-publish.sh`](../local-test/ci-publish.sh) — polls until SQL Server accepts connections, then bootstraps, publishes both dacpacs, seeds, and verifies. `verify.sql` THROWs on any failed check, so a non-zero exit fails the build. **This is the merge gate.** |
| 4 | ✅ tSQLt regression tests | no | hand-written curated tests with real assertions — [`run-curated-tests.sh`](../local-test/tsqlt/run-curated-tests.sh) over `tests/curated/`. `tSQLt.RunAll`, so the **whole repo-wide suite**, not just your PR. An empty `tests/curated/` passes cleanly |
| 5 | 📐 Contract tests | no | your changed proc/fn's **interface** (parameters + first result set) is unchanged, read from catalog metadata — [`run-contract-tests.sh`](../local-test/tsqlt/run-contract-tests.sh) over `tests/contract/` |
| 6 | 🔬 Characterization tests | no | a changed **deterministic scalar function** still returns the same output for a fixed input — [`run-characterization-tests.sh`](../local-test/tsqlt/run-characterization-tests.sh) over `tests/characterization/` |
| 7 | 🧮 Auto-generate missing baselines | no | for a changed object with no baseline yet, generates one — [`autogen-missing-baselines.sh`](../local-test/tsqlt/autogen-missing-baselines.sh). Archived and reported; **pushed only if `AUTO_COMMIT_BASELINES` is ON** |
| 8 | 🧬 Test fixtures (db-unit-test-synth) | no | one JSON per changed proc/fn — signature, dependencies to `FakeTable`, column types, FK closure, CHECK constraints, definition — so a dev can run the skill locally without re-introspecting. **Structure only**, from the throwaway DB. Skipped when no proc/fn changed |
| 9 | 📊 Coverage (UnitAutogen) | no | auto-generates tSQLt tests for the changed procs and measures **line coverage**; publishes Cobertura + JUnit per schema — [`coverage.sh`](../local-test/unitautogen/coverage.sh) — then writes a ready-to-finish curated-test starter per changed object (`gen-starter-tests.sh`) to `artifacts/starters/`. 20-minute timeout; same skip guard as stage 8 |
| 10 | 🧪 Integration / E2E tests | **yes**¹ | the plug-in point for the external suite — see below |

¹ only if you wire one in: `E2E_TEST_COMMAND` is not wrapped in `catchError`, so a non-zero
exit fails the build. Left blank (the default), the stage just prints the connection string.

`options`: `disableConcurrentBuilds()` (a newer push supersedes an in-flight run rather than
piling up pods), 30-minute timeout, 7-day build retention.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `AUTO_COMMIT_BASELINES` | `false` | OFF: generated baselines are archived and reported, **nothing is pushed** — no branch of yours is touched. ON: the pipeline commits them to the PR branch for you. |
| `E2E_TEST_COMMAND` | *(blank)* | shell command that runs the external integration/E2E suite against the published DB |

## Wiring in the E2E suite

The integration/E2E tests live outside this repo (`appdb-AppCatalog`), so stage 10 is the
plug-in point. The DB is published and schema-verified (`VERIFY OK`) before it runs; connect
using the exported env vars:

| Env var | Value |
|---|---|
| `TEST_SQL_SERVER` | `localhost,1433` — the same-pod sidecar |
| `TEST_SQL_DB` | `AppDb_Dev` (the data DB is `AppDb_MSG_Data_Dev`) |
| `TEST_SQL_USER` | `sa` |
| `TEST_SQL_PASSWORD` | from the `SA_PASSWORD_CRED` credential |

Two ways to run the suite:

1. **`E2E_TEST_COMMAND` build parameter** — a shell command that invokes your runner.
2. **Trigger a downstream job** — uncomment the `build job: 'E2E/…'` block in the stage and
   pass the `TEST_SQL_*` values as parameters.

Until one of those is set, the run is a **schema smoke gate** (build + publish + `VERIFY OK`)
and prints the connection string for a manual/downstream run.

## The three kinds of test

Contract and characterization baselines are **auto-generated, with no hand-written assertions** —
an intended change makes one RED and you regenerate the baseline, which lands as a reviewable
diff. Curated tests are the opposite: only a person can state what the answer *should* be.
Characterization only ever covers **deterministic scalar functions**
([`char-eligible.where.sql`](../local-test/tsqlt/char-eligible.where.sql) is the single
definition of that scope, shared by the generator and the runner); a changed stored procedure
is out of scope, not a gap.

A changed object with **no baseline at all yet** is generated for you by stage 7 into a scratch
tree, and only the missing objects' class blocks are **appended** to the committed file, so an
existing baseline is never rewritten. When it cannot add one it says why — the generator
failed, the file had local edits, or the append would have rewritten an existing line. A
generator failure or a would-be rewrite marks the stage UNSTABLE for a person to look at;
local edits are only reported.

Full detail: [`local-test/README.md`](../local-test/README.md) ("Contract, characterization & curated tests").

Coverage is a **coverage meter, not a correctness checker** — a generated test captures whatever
the code currently returns. Branch coverage is not reported: on SQL-for-Linux the UNSAFE CLR
predicate parser can't load (SAFE-only), so branch seeding is degraded. Constraints and the
Kubernetes variant: [`local-test/unitautogen/README.md`](../local-test/unitautogen/README.md).

## Running it by hand (local dev)

Local dev uses docker-compose, not the pod layout above:

```bash
bash local-test/db-up.sh          # or: pwsh local-test/db-up.ps1   (Windows)
# DB is on localhost,14330 · sa · AppDb_Dev
export PORT=14330 SA_PASSWORD='Local_Test_P@ssw0rd1'   # the scripts default to 1433 and require the password
bash local-test/unitautogen/fetch-deps.sh               # tSQLt into /tmp/tsqlt (needs curl, tar, unzip)
bash local-test/tsqlt/run-curated-tests.sh              # needs sqlcmd on the PATH
```

> Note the port difference: **`14330` locally** (the compose port mapping) vs **`1433` in CI**
> (the sidecar, same pod). This repo's scripts read `SERVER` / `PORT` (default `localhost` /
> `1433`), and the E2E stage exports `TEST_SQL_SERVER` for your suite, so don't hard-code it.
