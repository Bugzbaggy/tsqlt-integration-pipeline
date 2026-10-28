# Contributing to tsqlt-integration-pipeline

Per-PR database integration testing on a disposable SQL Server 2022 container, with tSQLt test synthesis and coverage.

Contributions are welcome. This project is maintained in spare time, so please
open an issue before starting anything large.

## Ground rules

1. **No real infrastructure in commits.** Hostnames, IPs, database names,
   service accounts, and credentials must be placeholders. See
   [SECURITY.md](SECURITY.md).
2. **One logical change per pull request.** Small PRs get reviewed; large
   ones stall.
3. **Explain the failure mode.** For a bug fix, say what broke and how to
   reproduce it. "Fixes a bug" is not reviewable.

## Getting started

```bash
git clone https://github.com/Bugzbaggy/tsqlt-integration-pipeline.git
cd tsqlt-integration-pipeline
```

Per-project setup lives in the [README](README.md).

## Pull request checklist

- [ ] CI is green
- [ ] No secrets, internal hostnames, or customer data introduced
- [ ] New behaviour has a test, or the PR says why it cannot
- [ ] Docs updated if behaviour changed

## Reporting bugs

Open an issue with the version, the platform, what you expected, what
happened, and the smallest reproduction you can manage.
