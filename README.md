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
4. Auto-generated tests run for each changed object  ← report-only
5. A missing contract/characterization baseline (new object) is generated for you
                                                      ← attached to the build, never pushed by default
6. Curated hand-written tests run                    ← report-only
7. A ready-to-finish test starter is generated       ← attached to the build
8. A summary comment is posted on your PR
```

**Only step 3 can block you.** Everything else is informational — which is the
design decision that makes this survivable. A generator that guesses a wrong
expected value must never block a correct change.

## Reading the PR comment

| Row | What it means | Blocks the PR? |
|---|---|---|
| Deploys cleanly & passes integrity checks | Your schema applies to an empty database with no errors | **Yes — the only gate** |
| Auto-generated unit tests | Tests a machine wrote and ran. A failure usually means the generator guessed wrong, not that your change is broken | No |
| Code exercised by those tests | Line coverage of your changed procedures | No |
| Interface contract (params & columns) | Your changed proc still takes the same parameters and returns the same columns | No — Tier 1 |
| Behaviour (function output) | A changed deterministic function still returns the same output for fixed input | No — Tier 2 |

## Run it locally

The same container the pipeline uses:

```bash
cd local-test
./db-up.sh            # or: pwsh db-up.ps1
```

That builds your DACPACs, starts SQL Server 2022 in Docker, publishes the
schema, seeds reference data, and runs `verify.sql`.

```bash
./tsqlt/run-curated-tests.sh              # hand-written tests
./tsqlt/gen-auto-tests.sh                 # generate contract tests for changed objects
./tsqlt/run-characterization-tests.sh     # pin current behaviour before refactoring
./tsqlt/autogen-missing-baselines.sh      # generate a baseline for a brand-new object only
./unitautogen/coverage.sh                 # line coverage report
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
| `pipeline/Jenkinsfile` | The CI pipeline |
| `skills/db-unit-test-synth/` | Claude Code skill that synthesizes tSQLt tests |

## The encrypted-config problem (and the fix)

If your schema uses symmetric keys, a fresh container can't decrypt production
ciphertext — the certificate's private key isn't in source control, and
restoring production data doesn't help.

`seed/20_encrypted_config.sql` and `seed/30_authapi_key.sql` show the way
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

1. Point `local-test/db-up.sh` at your `.sqlproj` files.
2. Replace `local-test/seed/*.sql` with your reference data.
3. Set the database names — they're `AppDb_MSG` / `AppDb_MSG_Data` placeholders.
4. Update `pipeline/Jenkinsfile` with your agent labels and credential IDs.

> The SA password in `docker-compose.yml` is a **local container credential**
> for a disposable database. It is not a secret, but don't reuse the pattern
> for anything that outlives the container.

## License

[MIT](LICENSE)
