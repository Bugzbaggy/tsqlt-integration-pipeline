# Local / ephemeral AppDb_MSG test databases (PROJ-000 / PROJ-000, Local SQL Steps 1-3)

Spin up a throwaway SQL Server **2022** container, apply the **current branch's** schema,
seed minimal config, run integration/E2E tests against it, then destroy it. No shared
dev server, no schema/data drift.

> **Docker is the only host dependency.** The dacpac build *and* the publish run inside the
> `tools` container (the same image CI uses) — no .NET SDK, `sqlpackage`, or `sqlcmd` needed
> on the host. `db-up.sh --build` / `db-up.ps1 -Build` is one command that behaves identically
> on Windows, Linux and macOS, using the exact toolchain the pipeline uses.

> **Requires SQL Server 2022.** The schema uses 2022-only functions (`GREATEST`, `LEAST`,
> `DATETRUNC`), so it will **not** publish to a 2019 engine (incl. SQL 2019 LocalDB) — the
> `mcr.microsoft.com/mssql/server:2022-latest` container is mandatory, not just convenient.

> **Validated end-to-end (2026-07-28):** `db-up.ps1` on a fresh SQL 2022 container publishes
> both databases, seeds, and reports `VERIFY OK` (all 5 checks). See the ordering/stub notes below.

> **Optional report-only coverage:** [`unitautogen/`](unitautogen/) auto-generates tSQLt tests
> and measures line coverage on the published DB (Cobertura + JUnit). Runs as a non-blocking
> stage in the integration pipeline; see [`unitautogen/README.md`](unitautogen/README.md).

## Publish order & cross-DB variables

- **Order matters:** publish `AppDb_Dev` **before** `AppDb_MSG_Data_Dev`. The data project's views
  reference synonyms that resolve to `AppDb_Dev` objects (e.g. `core.Account`), and a view
  validates its synonym's target at CREATE time (`Msg 5313`).
- **Undeployed cross-region targets → a non-existent stub DB** (`AppDb_XDB_Stub`), not `AppDb_Dev`.
  Their synonyms then resolve to nothing and procs create via deferred name resolution. Pointing
  them at `AppDb_Dev` makes e.g. `mage_ai.Operator_Get`'s `txn.mno_Operator` synonym resolve to
  `AppDb_Dev`'s own (different) `mno.Operator` → `Msg 207`. Only `AppDb_MSG_Data` points at a real DB.

## Databases created

| Database | Source project | Notes |
|---|---|---|
| `AppDb_Dev` | `AppDb_MSG.sqlproj` | Main messaging schema; seed + tests target this |
| `AppDb_MSG_Data_Dev` | `AppDb_MSG_data.sqlproj` | Data layer; the cross-DB synonym target (so synonyms resolve) |

> **`AppDb_SIT` is not provisioned** by this kit. It is a **separate database that lives in
> the US DB and has no source project/dacpac in this repo yet** — so it can't be built from
> source here. To include it later: extract a dacpac from the US instance
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
| `bootstrap.data.sql` | Same for `AppDb_MSG_Data_Dev` — 12 filegroups feeding the 4 data-layer partition schemes |
| `db-up.ps1` / `db-up.sh` | Local dev: build both dacpacs, stand up the container, provision + publish all DBs, seed, verify |
| `ci-publish.sh` | CI/Kubernetes: bootstrap→publish→seed→verify against an **already-running** SQL 2022 (no compose/build). For a tools sidecar in the same pod as the mssql container — see below |
| `AppDb_MSG.local.publish.xml` | Shared sqlpackage options (`CreateNewDatabase=False`, `Ignore*`, `AllowIncompatiblePlatform`); `db-up`/`ci-publish` supply `ExcludeObjectTypes` + SQLCMD vars on the CLI |
| `seed/00_lookups.sql` | FK-parent lookup rows (DimCompany, Region, BusinessUnit, Tier, CustomerSegment, AccountGroup, OmnishieldStatus) the account needs |
| `seed/10_accounts.sql` | The `MsgIntTest` account (fixed AccountUid) + one SMS-enabled subaccount |
| `seed/20_encrypted_config.sql` | Pattern for re-encrypting config in-container; skips cleanly until its scenario parents exist |
| `seed/30_authapi_key.sql` | Proposed workaround for the symmetric-key blocker (see below): seeds a re-encrypted test API key |
| `verify.sql` | End-to-end smoke test run last; `THROW`s on any failure so `db-up` exits non-zero (green/red gate for CI and the "validate spin-up" task) |

## CI / Kubernetes

`ci-publish.sh` is the orchestrator-agnostic core of `db-up`, for when SQL is started by
something else (a K8s pod, a compose service, a CI service container). It does **not** start
SQL or build dacpacs — it runs bootstrap → publish → seed → verify against an already-running
server, then exits non-zero if `verify.sql` fails.

Recommended K8s shape: a build pod with an `mssql` container and a `tools` container
(sqlcmd + sqlpackage) sharing `localhost`; the build stage produces the dacpacs; the `tools`
container runs `ci-publish.sh`:

```bash
SA_PASSWORD=<from Secret> SERVER=localhost PORT=1433 ./local-test/ci-publish.sh
```

Config is all via env (`SERVER`, `PORT`, `SA_PASSWORD`, `MSG_DB`, `DATA_DB`, `STUB_DB`,
`MSG_DACPAC`, `DATA_DACPAC`). Validated in a Linux tools container against the SQL 2022
container end-to-end → `VERIFY OK`. It carries the same publish order, stub-DB, and
CLI-`ExcludeObjectTypes` rules as `db-up` (see above) — reuse it; don't re-implement them.

## Known blocker: symmetric-key / API-key decryption

`WebAppFactory.GetApiKey()` → `smsapi.AuthApi_GetApiKeys` does
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
| `db-up.ps1` / `db-up.sh` | One-command orchestration for devs and CI |

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

**Auth:** the internal Jenkins needs VPN + credentials. Set `JENKINS_USER` / `JENKINS_TOKEN`
(a Jenkins API token) in the environment and the scripts send them as HTTP Basic auth. Override the
job base URL with `JENKINS_DB_BUILD` (PowerShell: `-JenkinsDbBuild`) if the path differs.

> Branch names with `/` (e.g. `feature/x`) are URL-encoded to `%2F`. Simple names (`PROJ-000`,
> random names — the common case) need no encoding.

`ci-publish.sh` takes the same DACPACs via `MSG_DACPAC` / `DATA_DACPAC` env overrides if you
already have them on disk.

## Prerequisites

- **Docker** (or Rancher/Podman) with **Linux containers** — the *only* host dependency.
  Both the dacpac build and the publish run inside the `tools` container (`.NET 8 SDK +
  sqlpackage + sqlcmd`, built from [`tools.Dockerfile`](tools.Dockerfile) — the same image
  CI uses), so you do **not** install the .NET SDK, `sqlpackage`, or `sqlcmd` on the host.
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
`dotnet build AppDb_MSG.sln -c Release` on the SDK-style (`Microsoft.Build.Sql`) projects — the exact
build the CI pipeline runs, so a local `--build` and a CI run use a byte-for-byte identical
toolchain (no "works on my machine"). Want a different SDK or build flags? Change them once in
[`tools.Dockerfile`](tools.Dockerfile) / [`docker-compose.ci.yml`](docker-compose.ci.yml) and both
local and CI pick it up. Omit the flag to publish a prebuilt/Jenkins-produced DACPAC instead.

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
