# Local / ephemeral AppDb_MSG test databases (PROJ-000 / PROJ-000, Local SQL Steps 1-3)

Spin up a throwaway SQL Server **2022** container, apply the **current branch's** schema,
seed minimal config, run integration/E2E tests against it, then destroy it. No shared
dev server, no schema/data drift.

> **Docker is the only host dependency.** The dacpac build *and* the publish run inside the
> `tools` container (the image the docker-compose CI overlay uses) — no .NET SDK, `sqlpackage`,
> or `sqlcmd` needed on the host. `db-up.sh --build` / `db-up.ps1 -Build` is one command that
> behaves identically on Windows, Linux and macOS, and runs the same provisioning script
> (`ci-publish.sh`) the pipeline runs. (The Kubernetes [`pipeline/Jenkinsfile`](../pipeline/Jenkinsfile)
> runs it in its pod's own `dotnet-8` / `mssql-2022` containers, not this image.)

> **Requires SQL Server 2022.** The schema uses 2022-only functions (`GREATEST`, `LEAST`,
> `DATETRUNC`), so it will **not** publish to a 2019 engine (incl. SQL 2019 LocalDB) — the
> `mcr.microsoft.com/mssql/server:2022-latest` container is mandatory, not just convenient.

> **What success looks like:** `db-up` on a fresh SQL 2022 container publishes both databases,
> seeds, and ends with `VERIFY OK` after the five checks in `verify.sql`. See the ordering/stub
> notes below.

> **Optional report-only coverage:** [`unitautogen/`](unitautogen/) auto-generates tSQLt tests
> and measures line coverage on the published DB (Cobertura + JUnit). Runs as a non-blocking
> stage in the integration pipeline; see [`unitautogen/README.md`](unitautogen/README.md).

## Publish order & cross-DB variables

- **Order matters:** publish `AppDb_Dev` **before** `AppDb_MSG_Data_Dev`. The data project's views
  reference synonyms that resolve to `AppDb_Dev` objects (e.g. `core.Account`), and a view
  validates its synonym's target at CREATE time (`Msg 5313`).
- **Undeployed cross-region targets → a non-existent stub DB** (`AppDb_XDB_Stub`), not `AppDb_Dev`.
  Their synonyms then resolve to nothing and procs create via deferred name resolution. Pointing
  them at `AppDb_Dev` makes e.g. `etl.Vendor_Get`'s `remote.svc_Vendor` synonym resolve to
  `AppDb_Dev`'s own (different) `svc.Vendor` → `Msg 207`. Only `AppDb_MSG_Data` points at a real DB.

## Databases created

| Database | Source project | Notes |
|---|---|---|
| `AppDb_Dev` | `AppDb_MSG.sqlproj` | Main messaging schema; seed + tests target this |
| `AppDb_MSG_Data_Dev` | `AppDb_MSG_data.sqlproj` | Data layer; the cross-DB synonym target (so synonyms resolve) |

> **`AppDb_SIT` is not provisioned** by this kit. It is a **separate database, hosted in a
> single production region, that has no source project/dacpac in this repo yet** — so it can't
> be built from source here. To include it later: extract a dacpac from that region's database
> (`sqlpackage /Action:Extract`) or add it as an SSDT project, then add a publish step for it.

## Quick start

```powershell
# Windows (devs) — pulls dev's DACPAC from Jenkins by default, then stands up + provisions + verifies
./db-up.ps1                     # default: pull dev
./db-up.ps1 -Branch PROJ-000    # pull a specific branch's DACPAC
./db-up.ps1 -Build              # compile inside Docker (no host toolchain)
```
```bash
# Linux / CI
./db-up.sh                      # default: pull dev
./db-up.sh --branch PROJ-000    # a specific branch
./db-up.sh --build              # compile inside Docker (no host toolchain)
```
Then point tests at:
```
Server=localhost,14330;Database=AppDb_Dev;User Id=sa;Password=Local_Test_P@ssw0rd1;TrustServerCertificate=True
```
Tear down: `docker compose -f local-test/docker-compose.yml down -v`

## Why it's built this way (the non-obvious bits)

The AppDb_MSG dacpac is **not** self-sufficient against an empty instance. Three things are
provisioned out-of-band in `bootstrap.sql`, mirroring how dev/prod are actually set up:

| Concern | Why the dacpac alone fails | Handled by |
|---|---|---|
| **Filegroups** | `Storage/FG_0*.sql` add filegroups with **no file**. `route.PriceListHistory` is `ON PS_PartitionKey`, and a fileless filegroup → `CREATE TABLE` fails (Msg 622). | `bootstrap.sql` adds a file per FG, then publish runs with `CreateNewDatabase=False`. |
| **Database Master Key** | The 7 certificates are self-signed (`CREATE CERTIFICATE WITH SUBJECT`); without a DMK, cert creation fails (error 15581). | `bootstrap.sql` regenerates the DMK fresh with a **throwaway local-dev password** (`L0c@lD3vSQL`) — never a real/prod DMK password. |
| **Encrypted config** | Certs/keys are **regenerated fresh** here, so prod/dev ciphertext won't decrypt. | Seed **plaintext** and re-encrypt in-container via `EncryptByKey` — see `seed/20_encrypted_config.sql`. |

Server principals (34 logins, 45 users, ~1,979 grants) are **excluded** from the publish —
tests connect as `sa`, so they're pure noise and a source of orphaned-user failures (one
`app_*` login even has `DEFAULT_DATABASE=[AppCatalog]`, which fails outright).

> **Gotcha:** `sqlpackage` **ignores `ExcludeObjectTypes` set in a `.publish.xml` profile**
> (verified — it still runs `CREATE LOGIN`). `db-up` therefore passes
> `/p:ExcludeObjectTypes=...` on the sqlpackage **CLI**, where it is honored. `AppDb_MSG_Data`
> is passed as a `/v:` variable pointing at `AppDb_MSG_Data_Dev` so the 41 cross-DB synonyms resolve.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | SQL Server 2022 **Developer** edition, port 14330, tmpfs data (fast + auto-wiped) |
| `bootstrap.sql` | Creates the `AppDb_Dev` DB + its 6 filegroups(+files) + DMK; parameterized by `-v DbName=` |
| `bootstrap.data.sql` | Same for `AppDb_MSG_Data_Dev` — 12 filegroups feeding the 5 data-layer partition schemes (`PS_Month`, `PS_BYDAY180/90/62/31`) |
| `db-up.ps1` / `db-up.sh` | Local dev: pull (or, with `-Build` / `--build`, build) both dacpacs, stand up the container, provision + publish all DBs, seed, verify |
| `ci-publish.sh` | CI/Kubernetes: bootstrap→publish→seed→verify against an **already-running** SQL 2022 (no compose/build). For a tools sidecar in the same pod as the mssql container — see below |
| `AppDb_MSG.local.publish.xml` | Shared sqlpackage options (`CreateNewDatabase=False`, `Ignore*`, `AllowIncompatiblePlatform`); `db-up`/`ci-publish` supply `ExcludeObjectTypes` + SQLCMD vars on the CLI |
| `seed/00_lookups.sql` | FK-parent lookup rows (DimCompany, Region, BusinessUnit, Tier, CustomerSegment, AccountGroup, ProtectionStatus) the account needs |
| `seed/10_accounts.sql` | The `MsgIntTest` account (fixed AccountUid) + one SMS-enabled subaccount |
| `seed/20_encrypted_config.sql` | Pattern for re-encrypting config in-container; skips cleanly until its scenario parents exist |
| `seed/30_authapi_key.sql` | Proposed workaround for the symmetric-key blocker (see below): seeds a re-encrypted test API key |
| `verify.sql` | End-to-end smoke test run last; `THROW`s on any failure so `db-up` exits non-zero (green/red gate for CI and the "validate spin-up" task) |

## Contract, characterization & curated tests (`tsqlt/`)

Once a DB is up, `tsqlt/` holds the generators and runners for the auto-generated and
hand-written tSQLt suites the pipeline runs against whatever this branch just published. The
suites themselves live under `tests/` at the repo root (`tests/contract/`,
`tests/characterization/`, `tests/curated/`); none ship with this repository.

| File | Role |
|---|---|
| `gen-auto-tests.sh` | generates **contract** baselines (parameter signature + first result-set) for every proc/function, from catalog metadata only — no execution |
| `gen-characterization-tests.sh` | generates **characterization** baselines (output for a fixed representative input) for eligible deterministic scalar functions |
| `char-eligible.where.sql` | the ONE predicate for "can this object have a characterization baseline at all?" — shared by the generator and the runner so the two can't drift |
| `run-contract-tests.sh` / `run-characterization-tests.sh` | run those baselines, scoped to a PR's changed objects |
| `autogen-missing-baselines.sh` | generates a baseline for an object that has **none yet**, without ever touching one that already exists |
| `run-curated-tests.sh` / `gen-starter-tests.sh` / `gen-scaffolds.mjs` | the hand-written suite and its ready-to-finish starters (both generators write to `tests/generated/` by default, which is git-ignored; `gen-scaffolds.mjs` reads `docs/schemas/<schema>/test_scenarios.json`, which you supply — none ship with this repository) |

Both baseline kinds are golden-master style: zero hand-written assertions, just "does the live
value still match the committed one". An intended change makes the test RED and you regenerate
the baseline with the matching `gen-*` script (a reviewable diff on the PR).

**What "eligible" means for characterization.** It covers only **deterministic scalar
functions** — no `GETDATE`/`NEWID`/`RAND`-style built-ins, and every dependency a same-database
**table**, which the generated test fakes with `tSQLt.FakeTable` and seeds (a function with no
table dependency at all is the simplest case) — the one shape whose output can be captured once
and compared forever. A stored procedure, a table-valued function, or a function that reads a
view, calls another procedure or function, or reaches into another database is simply out of
scope: it will never get a `test_char_` class, so reporting it
as "missing a baseline" would be a warning no command could ever clear. `char-eligible.where.sql`
is the single source of truth for that boundary; if the generator and the runner each carried
their own copy of the predicate, a changed stored procedure would start getting flagged as
missing a baseline it can never produce.

**Missing baselines are generated for you.** A PR that changes an object with no contract or
characterization baseline yet (a brand-new object, or one nobody ever generated) used to just
report "nothing ran" — someone had to remember to run the right `gen-*` script by hand and
commit the result. `autogen-missing-baselines.sh` closes that gap. The generators rewrite a
whole `<schema>.sql`, so a naive regeneration could overwrite the baseline of an object whose
interface genuinely *changed* — silently destroying the signal the test exists to raise. So the
regeneration goes to a scratch tree and **only the missing objects' class blocks are appended**
to the committed file: additive by construction, not by diffing afterwards. A zero-deletions
check still runs as an assertion, and any deletion reverts the file. A schema with no baseline
file in git at all is additive by definition (there's nothing to overwrite), so a new file is
created from the generated header.

That matters for a case a whole-file "keep it only if the diff is purely additive" rule gets
wrong: a PR that changes `svc.A`'s signature *and* adds `svc.B` would regenerate `svc.sql`,
rewrite A's baseline line, and be refused — leaving B with no baseline because of an unrelated
object. Appending only B's block cannot do that. (The appended block lands at the end of the
file rather than in sorted position; a later full regeneration by a human reorders it.)

- **Some objects can never have a generated baseline** — a seeded call that returns NULL, one
  that errors, a baseline past the 8000-character cap. They are reported as "no automated
  baseline is possible … needs a hand-written test" and are *not* left on the missing list,
  because telling you to run a generator that will never emit for them is a warning with no way
  to clear it.
- **Each way it can decline says which one it was.** The generator **failed** for a schema
  (read the log, or retry — nothing in the repo changed), the append would have **rewritten an
  existing baseline** (impossible by construction, so a person must look), or the file has
  **local edits** and was skipped. One shared message would blame an interface change for what
  was really a transient generator failure, in an object the author never touched.
- **A refusal is reported, not swallowed.** It appears in the PR comment **and** marks the stage
  UNSTABLE on every build, whether or not `AUTO_COMMIT_BASELINES` is on.
- **It never writes over uncommitted work** — including a file you never `git add`ed. If a
  baseline file has local edits, or exists only in your working tree, the precheck marks it and
  the generator skips that schema entirely — it is reported in its own `localedits` state,
  separate from a refusal, and your edits are left exactly as they were. If the
  generator fails part-way through a schema, the partial file it left is discarded rather than
  kept, archived or counted as a new baseline.
- **An object the PR deleted is not reported at all.** `affected-objects.sh` lists changed
  *files* (and excludes deleted ones with `--diff-filter=d`); the runners also check the
  published schema first and skip anything that no longer exists, rather than reporting it as
  missing a baseline and then asking for a hand-written test for something you removed.

It never pushes to your branch by default — it generates and archives the result, and the
pipeline's PR comment says so. The `AUTO_COMMIT_BASELINES` build parameter makes it commit and
push instead, with its own guardrails (never to `dev`/`main`/`master`/`release/*`, never onto a
PR's pseudo-branch, never on top of a merge commit, never twice in a row).

It runs as three phases — `precheck` / `generate` / `verify` — because generating needs
`sqlcmd` and the additive-only guard needs `git`, and in the pipeline those live in different
containers of the same pod. `PHASE=all` (the default) runs all three in order and is what you
want anywhere both tools exist, such as this local kit's `tools` container. Run it from the
repo root (its paths are relative to the current directory) with `SERVER` / `PORT` /
`SA_PASSWORD` set as for the other scripts:

```bash
PHASE=all KIND=contract DB=AppDb_Dev OUT_ROOT=tests/contract/AppDb_MSG LABEL=AppDb_MSG \
    bash local-test/tsqlt/autogen-missing-baselines.sh 'core.SomeNewProc'
```

## CI / Kubernetes

`ci-publish.sh` is the orchestrator-agnostic core of `db-up`, for when SQL is started by
something else (a K8s pod, a compose service, a CI service container). It does **not** start
SQL or build dacpacs — it runs bootstrap → publish → seed → verify against an already-running
server, then exits non-zero if `verify.sql` fails.

Recommended K8s shape: a build pod with an `mssql` container and a `tools` container
(sqlcmd + sqlpackage) sharing `localhost`; the build stage produces the dacpacs; the `tools`
container runs `ci-publish.sh`. (The shipped [`pipeline/Jenkinsfile`](../pipeline/Jenkinsfile)
runs it in the `mssql-2022` container itself, which carries sqlcmd + sqlpackage.)

```bash
SA_PASSWORD=<from Secret> SERVER=localhost PORT=1433 ./local-test/ci-publish.sh
```

Config is all via env (`SERVER`, `PORT`, `SA_PASSWORD`, `MSG_DB`, `DATA_DB`, `STUB_DB`,
`MSG_DACPAC`, `DATA_DACPAC`). Validated in a Linux tools container against the SQL 2022
container end-to-end → `VERIFY OK`. It carries the same publish order, stub-DB, and
CLI-`ExcludeObjectTypes` rules as `db-up` (see above) — reuse it; don't re-implement them.

## Known blocker: symmetric-key / API-key decryption

The application's API-key lookup → `svc.AuthApi_GetApiKeys` does
`OPEN SYMMETRIC KEY AuthApi_Key DECRYPTION BY CERTIFICATE AuthApi` then decrypts
`svc.AuthApi.ApiKey_encrypt`. The `AuthApi` certificate's private key is **not in
source**, so prod/dev ciphertext cannot be decrypted in a fresh container —
restoring prod data does not help.

**Proposed test-safe workaround** (implemented in `seed/30_authapi_key.sql`): seed a
*known plaintext* test key, re-encrypted under this container's freshly-generated
`AuthApi_Key`. `AuthApi_GetApiKeys` then returns that value, and `verify.sql` asserts
the round-trip. This makes auth-dependent tests viable locally **provided the harness
accepts a seeded test key** rather than a specific production key value — that harness
decision is the item tracked alongside PROJ-000.

Extra seeders that are config (not runtime) and can be added to `seed/` or run as-is:
`AppDb_MSG/Scripts/Post-Deployment/Script.InitMessagingApps.sql`, `Script.InitTemplates.sql`,
`Script.IndustryDropdown.sql`.

## Branch-awareness (Step 3)

By default `db-up` **pulls the branch's DACPAC from Jenkins** — no local build, no database PR —
so a developer can test any branch's DB changes locally without merging to dev first:

```powershell
./db-up.ps1                     # pull dev's DACPAC (default), stand up + provision + seed + verify
./db-up.ps1 -Branch PROJ-000    # pull that branch's DACPAC instead
./db-up.ps1 -Build              # compile inside Docker (no host toolchain)
```
```bash
./db-up.sh                      # pull dev (default)
./db-up.sh --branch PROJ-000    # pull that branch
./db-up.sh --build              # compile inside Docker (no host toolchain)
```

It downloads both archived DACPACs from the `DB_Build` multibranch job
(`.../DB_Build/job/<branch>/lastSuccessfulBuild/artifact/AppDb_MSG/bin/Release/AppDb_MSG.dacpac` and the
`AppDb_MSG_data` one, fingerprinted by the build pipeline) into `AppDb_MSG/bin/Release` +
`AppDb_MSG_data/bin/Release`, then publishes as usual.

**Auth:** a private Jenkins usually needs credentials (and VPN, if it is internal). Set `JENKINS_USER` / `JENKINS_TOKEN`
(a Jenkins API token) in the environment and the scripts send them as HTTP Basic auth. Override the
job base URL with `JENKINS_DB_BUILD` (PowerShell: `-JenkinsDbBuild`) — the default is a placeholder.

> Branch names with `/` (e.g. `feature/x`) are URL-encoded to `%2F`. Simple names (`PROJ-000`,
> random names — the common case) need no encoding.

`ci-publish.sh` takes the same DACPACs via `MSG_DACPAC` / `DATA_DACPAC` env overrides if you
already have them on disk.

## Prerequisites

- **Docker** (or Rancher/Podman) with **Linux containers** — the *only* host dependency.
  Both the dacpac build and the publish run inside the `tools` container (`.NET 8 SDK +
  sqlpackage + sqlcmd`, built from [`tools.Dockerfile`](tools.Dockerfile) — the image the
  docker-compose CI overlay uses), so you do **not** install the .NET SDK, `sqlpackage`, or
  `sqlcmd` on the host.
  One command, every OS.
- The default (pull-from-Jenkins) path additionally uses `curl` (bash) / `Invoke-WebRequest`
  (PowerShell) to download the prebuilt DACPAC — both ship with the OS. `--build` needs
  nothing but Docker.

### macOS / Apple Silicon (arm64)

- **Use Rosetta, not QEMU.** The SQL Server 2022 image is amd64 and **segfaults on boot under QEMU**
  (exit 139, `qemu: uncaught target signal 11`). Enable Rosetta x86-64 emulation:
  - Docker Desktop → Settings → General → **Use Rosetta for x86-64/amd64 emulation**.
  - Rancher Desktop: `rdctl set --virtual-machine.type vz --virtual-machine.use-rosetta=true --virtual-machine.mount.type virtiofs`.
- **`azure-sql-edge` is not a substitute** — it's a 2019 engine and lacks `GREATEST`/`LEAST`/`DATETRUNC`, so publish fails.
- Validated end-to-end on macOS 26.6 (arm64, Rancher Desktop VZ + Rosetta + virtiofs) → `VERIFY OK`, ~68s.

### Building with `--build` (all platforms)

`db-up.ps1 -Build` / `db-up.sh --build` compile both dacpacs **inside the `tools` container**
(`docker compose -f docker-compose.yml -f docker-compose.ci.yml run --rm --build tools`), so the
host needs only Docker — no .NET SDK, no Visual Studio, no MSBuild. The container runs
`dotnet build AppDb_MSG.sln -c Release` on the SDK-style (`Microsoft.Build.Sql`) projects — the same
build command the Jenkins pipeline runs in its `dotnet-8` container. A docker-only CI agent that
uses [`docker-compose.ci.yml`](docker-compose.ci.yml) gets a byte-for-byte identical toolchain
(no "works on my machine"); the Kubernetes pipeline uses its pod template's containers, so keep
their SDK in step with [`tools.Dockerfile`](tools.Dockerfile). Want a different SDK or build
flags? Change them in `tools.Dockerfile` / `docker-compose.ci.yml` (and the pod template). Omit
the flag to publish a prebuilt/Jenkins-produced DACPAC instead.

## Alternative: Testcontainers (per-test isolation, no scripts)

For true per-test-class isolation from inside a .NET (xUnit) suite, drive the same lifecycle
programmatically. Publish the dacpac in-process with `Microsoft.SqlServer.DacFx` so CI needs no
external `sqlpackage`:

```csharp
var sql = new MsSqlBuilder()
    .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
    .WithPassword("Local_Test_P@ssw0rd1")
    .Build();
await sql.StartAsync();

// 1. bootstrap.sql (filegroups + DMK) against the new instance
// 2. new DacServices(sql.GetConnectionString()).Publish(
//        DacPackage.Load("AppDb_MSG.dacpac"),
//        new PublishOptions { ... CreateNewDatabase = false, ExcludeObjectTypes = [Logins, Users, ...] })
// 3. run seed/*.sql
```

Reuse `bootstrap.sql`, `AppDb_MSG.local.publish.xml` values, and `seed/*.sql` verbatim — the
publish knobs are identical; only the driver differs.
