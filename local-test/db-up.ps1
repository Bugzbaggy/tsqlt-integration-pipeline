<#
.SYNOPSIS
  Spin up an ephemeral SQL Server 2022 container, provision the AppDb_MSG baseline
  databases from the current branch, seed essential config, verify, and leave it
  ready for tests (PROJ-000 / PROJ-000, Local SQL Steps 1-3).

.DESCRIPTION
  Docker is the ONLY host dependency. The dacpac build and the publish run inside the
  "tools" container (the same image CI uses: .NET 8 SDK + sqlpackage + sqlcmd), so no
  .NET SDK or sqlpackage is needed on the host, and one command works on every OS. The
  provisioning logic lives once, in ci-publish.sh, shared by CI and this script — a local
  pass means the pipeline passes the same way.

  Databases created (per the Step-1 scope):
    AppDb_Dev       <- AppDb_MSG.sqlproj        (main messaging schema)
    AppDb_MSG_Data_Dev  <- AppDb_MSG_data.sqlproj   (data layer; cross-DB synonym target)

  AppDb_SIT is NOT created here: it is a separate database that lives in the US DB and
  has no source project/dacpac in this repo yet. Once its schema is sourced (extract a
  dacpac from the US instance, or add it as an SSDT project), wire it in as its own step.

  Lifecycle: fresh SQL container -> tools container (build? + bootstrap + publish + seed +
  verify). Tear down: docker compose -f local-test/docker-compose.yml down -v

.PARAMETER Build       Compile both dacpacs from local source INSIDE Docker (no host toolchain)
                       instead of pulling the prebuilt artifact from Jenkins.
.PARAMETER Branch      Pull this branch's dacpac from the Jenkins DB_Build job (default 'dev').
                       Ignored when -Build is set. Set $env:JENKINS_USER / $env:JENKINS_TOKEN for
                       authenticated download over VPN.

.EXAMPLE
  ./db-up.ps1                      # pull dev's dacpac from Jenkins, then stand up (default)
.EXAMPLE
  ./db-up.ps1 -Branch PROJ-000     # pull that branch's dacpac from Jenkins
.EXAMPLE
  ./db-up.ps1 -Build               # compile both dacpacs inside Docker (Docker-only)
#>
[CmdletBinding()]
param(
    [switch]$Build,
    [string]$Branch = 'dev',   # pull this branch's dacpac from Jenkins DB_Build (ignored if -Build)
    [string]$JenkinsDbBuild = 'https://jenkins1.int.appdb.io/job/DB/job/AppDb_MSG_DB/job/DB_Build',
    [string]$MsgDb     = 'AppDb_Dev',
    [string]$DataDb    = 'AppDb_MSG_Data_Dev',
    [string]$SaPassword = 'Local_Test_P@ssw0rd1',
    [int]$Port = 14330
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path "$PSScriptRoot/.."
Push-Location $PSScriptRoot
try {
    if (-not (Get-Command docker -EA SilentlyContinue)) {
        throw 'docker not found — Docker is the only host dependency for this script. Install Docker Desktop / Engine.'
    }

    $compose   = @('compose', '-f', 'docker-compose.yml')
    $ciCompose = @('compose', '-f', 'docker-compose.yml', '-f', 'docker-compose.ci.yml')
    $msgDacpac  = "$repo/AppDb_MSG/bin/Release/AppDb_MSG.dacpac"
    $dataDacpac = "$repo/AppDb_MSG_data/bin/Release/AppDb_MSG_data.dacpac"

    function Invoke-Native([string]$exe, [string[]]$argv) {
        & $exe @argv
        if ($LASTEXITCODE -ne 0) { throw "$exe $($argv -join ' ') failed (exit $LASTEXITCODE)" }
    }
    # Download a per-branch dacpac artifact from the Jenkins DB_Build multibranch job. Auth via
    # $env:JENKINS_USER / $env:JENKINS_TOKEN if set (needed on the internal Jenkins over VPN).
    function Get-BranchDacpac([string]$artifactPath, [string]$dest) {
        $enc = [uri]::EscapeDataString($Branch)   # url-encodes '/' -> %2F for feature/x branches
        $url = "$JenkinsDbBuild/job/$enc/lastSuccessfulBuild/artifact/$artifactPath"
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        $headers = @{}
        if ($env:JENKINS_USER -and $env:JENKINS_TOKEN) {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($env:JENKINS_USER):$($env:JENKINS_TOKEN)"))
            $headers['Authorization'] = "Basic $b64"
        }
        Write-Host "    fetch: $url"
        try { Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -UseBasicParsing }
        catch { throw "Failed to download dacpac for branch '$Branch' from $url. $($_.Exception.Message) — check the branch's DB_Build job succeeded, VPN access, and JENKINS_USER/JENKINS_TOKEN." }
    }

    # Both compose files read these via ${VAR:-default}; setting them here makes -SaPassword/
    # -Port/-MsgDb/-DataDb drive the sqlserver service AND the tools container in lock-step.
    $env:SA_PASSWORD = $SaPassword
    $env:MSG_DB      = $MsgDb
    $env:DATA_DB     = $DataDb
    $env:HOST_PORT   = "$Port"

    # 0. Default (pull) path fetches the prebuilt dacpac on the host. -Build needs no host
    #    toolchain: the tools container compiles from source.
    if (-not $Build) {
        Write-Host "==> Pulling dacpacs from Jenkins DB_Build/$Branch ..." -ForegroundColor Cyan
        Get-BranchDacpac 'AppDb_MSG/bin/Release/AppDb_MSG.dacpac'           $msgDacpac
        Get-BranchDacpac 'AppDb_MSG_data/bin/Release/AppDb_MSG_data.dacpac' $dataDacpac
        foreach ($d in @($msgDacpac, $dataDacpac)) {
            if (-not (Test-Path $d)) { throw "Dacpac not found after fetch: $d" }
        }
    }

    # 1. Fresh SQL Server container + wait healthy.
    Write-Host '==> Starting a fresh SQL Server 2022 container...' -ForegroundColor Cyan
    Invoke-Native 'docker' ($compose + @('up', '-d', '--force-recreate', 'sqlserver'))
    $cid = (& docker @compose ps -q sqlserver).Trim()
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 3
        $health = (& docker inspect -f '{{.State.Health.Status}}' $cid).Trim()
        Write-Host "    health: $health"
        if ((Get-Date) -gt $deadline) { throw 'SQL Server did not become healthy within 3 minutes.' }
    } while ($health -ne 'healthy')

    # 2. Build (only with -Build) + bootstrap + publish + seed + verify — ALL inside the tools
    #    container. `run --rm --build tools` with no command uses the compose default (dotnet
    #    build AppDb_MSG.sln && ci-publish.sh); overriding the command with just ci-publish.sh
    #    skips the build and publishes the already-fetched dacpacs.
    if ($Build) {
        Write-Host '==> Building dacpacs + publishing in the tools container (Docker-only)...' -ForegroundColor Cyan
        Invoke-Native 'docker' ($ciCompose + @('run', '--rm', '--build', 'tools'))
    } else {
        Write-Host '==> Publishing the prebuilt dacpacs in the tools container (Docker-only)...' -ForegroundColor Cyan
        Invoke-Native 'docker' ($ciCompose + @('run', '--rm', '--build', 'tools', 'bash', 'local-test/ci-publish.sh'))
    }

    Write-Host ''
    Write-Host "AppDb_MSG test databases ready: $MsgDb, $DataDb." -ForegroundColor Green
    Write-Host "  Connection: Server=localhost,$Port;Database=$MsgDb;User Id=sa;Password=$SaPassword;TrustServerCertificate=True"
    Write-Host '  Tear down:  docker compose -f local-test/docker-compose.yml down -v'
}
finally {
    Pop-Location
}
