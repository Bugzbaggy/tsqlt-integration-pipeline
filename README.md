# tsqlt-integration-pipeline

Every pull request gets a **brand-new, disposable SQL Server 2022** — your
schema is published into it, integrity-checked, exercised by auto-generated
and curated [tSQLt](https://tsqlt.org/) tests, and the result is posted back
as a plain-English PR comment.

Nothing is shared between runs. The container is discarded afterwards.

[![SQL Server 2022](https://img.shields.io/badge/SQL%20Server-2022-CC2927)](https://learn.microsoft.com/sql/)
[![tSQLt](https://img.shields.io/badge/tSQLt-unit%20tests-4B8BBE)](https://tsqlt.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What happens when you open a PR

```
1. Your branch's DB projects compile to DACPACs
2. A fresh, disposable SQL Server 2022 starts        ← nothing shared
3. Your schema is published + integrity-checked      ← THE GATE
4. Curated hand-written tests run                    ← report-only
5. Contract + characterization tests run for each changed object
                                                      ← report-only
6. A missing contract/characterization baseline (new object) is generated for you
                                                      ← attached to the build, never pushed by default
7. Test-synthesis fixtures are captured for each changed object
                                                      ← attached to the build
8. Auto-generated tests + line coverage run for each changed object,
   and a ready-to-finish test starter is generated   ← report-only / attached to the build
9. Your integration/E2E command runs, if you set one
10. A summary comment is posted on your PR
```

Steps 5–8 run only when the PR changes a stored procedure or function.

**Only step 3 is a test gate.** (A branch that doesn't compile in step 1, or an
E2E command you wire into step 9 that exits non-zero, also fails the build.)
Every generated and curated test stage is informational — which is the design
decision that makes this survivable. A generator that guesses a wrong expected
value must never block a correct change. One caveat: a Coverage (step 8) timeout
or fault marks the build UNSTABLE, and the shipped pipeline reports any
non-SUCCESS result to GitHub as a `failure` commit status — so if that status is
a required check, it blocks the merge.

## Reading the PR comment

| Part | What it means | Blocks the PR? |
|---|---|---|
| Deploys cleanly & passes integrity checks (top line) | Your schema applies to an empty database with no errors | **Yes — the only gate** |
| Database Coverage Report — *Tests* card and the per-object *Tests / Pass / Skip* columns | Tests a machine wrote and ran for each changed object. A failure usually means the generator guessed wrong, not that your change is broken | No |
| Database Coverage Report — *Line coverage* card and *Line %* column | Line coverage of your changed procedures and functions | No |
| Interface contract (params & columns) | Your changed proc still takes the same parameters and returns the same columns | No — Tier 1 |
| Behaviour (function output) | A changed deterministic function still returns the same output for fixed input | No — Tier 2 |
| Hand-written regression tests (repo-wide suite) / *Hand-written* card | The curated tests in `tests/curated/` — the whole suite, not only tests for your PR | No |

## Run it locally

The same provisioning script (`ci-publish.sh`) the pipeline runs, in Docker:

```bash
cd local-test
./db-up.sh            # or: pwsh db-up.ps1
```

By default that pulls your branch's prebuilt DACPACs from Jenkins (`--build` /
`-Build` compiles them inside Docker instead), starts SQL Server 2022 in Docker,
publishes the schema, seeds reference data, and runs `verify.sql`.

The test scripts read `SERVER` / `PORT` / `SA_PASSWORD` from the environment. Their
defaults are `localhost` / `1433` and `SA_PASSWORD` is required, so against the local
container set `PORT=14330` and the container password. They need `sqlcmd` on the
`PATH`, and their default paths (`tests/…`, `artifacts/`) are relative to the
current directory, so run them from the repo root:

```bash
export SERVER=localhost PORT=14330 SA_PASSWORD='Local_Test_P@ssw0rd1'
bash local-test/unitautogen/fetch-deps.sh # tSQLt + UnitAutogen into /tmp (the runners install tSQLt from there)
bash local-test/tsqlt/run-curated-tests.sh              # hand-written tests (tests/curated/)
bash local-test/tsqlt/gen-auto-tests.sh AppDb_Dev --out tests/contract/AppDb_MSG
                                          # regenerate contract baselines (every proc/function)
bash local-test/tsqlt/gen-characterization-tests.sh AppDb_Dev --out tests/characterization/AppDb_MSG
                                          # regenerate behaviour baselines (eligible scalar functions;
                                          # needs tSQLt installed in the database)
bash local-test/tsqlt/run-characterization-tests.sh     # check behaviour against the committed baselines
DB=AppDb_Dev bash local-test/tsqlt/autogen-missing-baselines.sh 'core.SomeNewProc'
                                          # generate a baseline for a brand-new object only (needs git too)
UA_SCHEMAS="core svc" bash local-test/unitautogen/coverage.sh
                                          # line coverage report - it does not self-scope: with
                                          # no UA_SCHEMAS / UA_OBJECTS it covers nothing
```

## Layout

| Path | What it is |
|---|---|
| `local-test/db-up.sh` / `.ps1` | Stand up the whole environment locally |
| `local-test/docker-compose*.yml` | Container definitions — local, CI, coverage |
| `local-test/seed/` | Reference data, accounts, and encrypted-config seeding |
| `local-test/tsqlt/` | Test generation and execution scripts |
| `local-test/unitautogen/` | Changed-object detection and coverage measurement |
| `local-test/verify.sql` | Post-publish integrity check — the gate |
| `pipeline/Jenkinsfile` | The per-PR integration pipeline (Jenkins, Kubernetes pod agent) |
| `skills/db-unit-test-synth/` | Claude Code skill that synthesizes tSQLt tests |
| `ci/`, `.github/workflows/ci.yml` | This repository's own CI: script/compose/denylist checks and a leak scan |

## The encrypted-config problem (and the fix)

If your schema uses symmetric keys, a fresh container can't decrypt production
ciphertext — the certificate's private key isn't in source control, and
restoring production data doesn't help.

`local-test/seed/20_encrypted_config.sql` and `local-test/seed/30_authapi_key.sql` show the way
around it: **seed known plaintext and re-encrypt under the container's own
freshly-generated key**, using the same `OPEN KEY` / `EncryptByKey` pattern the
application uses. Auth-dependent tests then run fully locally.

This is the single most common blocker to containerised database testing, and
it's worth reading those two files even if you adopt nothing else here.

## Test synthesis skill

`skills/db-unit-test-synth/` generates tSQLt tests by introspecting an object,
reasoning about its branches, and emitting a test per path. Coverage is
mechanical; correctness stays curated.

It can sample **enum domains** from a read-only replica to make tests realistic,
guarded by `config/sensitive.deny` — a deliberately broad column-name denylist.
A column is sampled only if it does **not** match that pattern *and* has
cardinality ≤ 50, so status and type columns are sampled while anything that
could carry a message body, identifier, or PII never is.

That denylist is reusable on its own.

## Adapting it

1. Point the build at your solution (`AppDb_MSG.sln` in `local-test/docker-compose.ci.yml`
   and `pipeline/Jenkinsfile`) and the dacpac paths at its output (`MSG_DACPAC` /
   `DATA_DACPAC` in `local-test/ci-publish.sh`, and the same paths in `db-up.sh` / `db-up.ps1`).
2. Replace `local-test/seed/*.sql` with your reference data.
3. Set the project and database names — the placeholders are the `AppDb_MSG` /
   `AppDb_MSG_data` projects, published as `AppDb_Dev` / `AppDb_MSG_Data_Dev`
   (`MSG_DB` / `DATA_DB`).
4. Update the site-specific names at the top of `pipeline/Jenkinsfile` (`POD_TEMPLATE`,
   `SA_PASSWORD_CRED`, `GITHUB_CRED`, `BOT_GIT_NAME`), plus `REPO_NAME` and the `example`
   GitHub owner in its GitHub URLs.

> The SA password in `docker-compose.yml` is a **local container credential**
> for a disposable database. It is not a secret, but don't reuse the pattern
> for anything that outlives the container.

## License

[MIT](LICENSE)
