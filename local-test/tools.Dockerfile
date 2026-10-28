# CI "tools" image: builds the SDK-style dacpacs and publishes them into the sibling
# SQL Server container via local-test/ci-publish.sh. Bundles everything ci-publish.sh
# needs — .NET 8 SDK (dotnet build + sqlpackage) and mssql-tools18 (sqlcmd) — so the
# Jenkins/Linux agent only needs Docker. See local-test/ci-publish.sh and README.md.
FROM mcr.microsoft.com/dotnet/sdk:8.0

# mssql-tools18 (sqlcmd) + unixODBC from the Microsoft package repo. Use the official
# packages-microsoft-prod.deb, which registers the signing key + apt source correctly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && . /etc/os-release \
 && curl -sSL -o /tmp/packages-microsoft-prod.deb "https://packages.microsoft.com/config/debian/${VERSION_ID%%.*}/packages-microsoft-prod.deb" \
 && dpkg -i /tmp/packages-microsoft-prod.deb \
 && rm /tmp/packages-microsoft-prod.deb \
 && apt-get update \
 && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 unixodbc-dev unzip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# unzip: extract the tSQLt release archive in the report-only coverage step
# (local-test/unitautogen/fetch-deps.sh). curl + tar are already present.
ENV PATH="/opt/mssql-tools18/bin:${PATH}"

# sqlpackage (dotnet global tool) into a fixed path on PATH.
RUN dotnet tool install --tool-path /opt/sqlpackage microsoft.sqlpackage
ENV PATH="/opt/sqlpackage:${PATH}"

WORKDIR /repo
