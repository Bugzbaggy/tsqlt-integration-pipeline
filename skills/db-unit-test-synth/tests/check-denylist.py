#!/usr/bin/env python3
"""Assert the sensitive-column denylist classifies correctly.

The denylist guards production enum-domain sampling: a column is sampled only
if it does NOT match this pattern. A regression here would leak PII into test
fixtures, so it is asserted in CI rather than trusted.
"""
import pathlib
import re
import sys

DENY_FILE = pathlib.Path(__file__).resolve().parents[1] / "config" / "sensitive.deny"

# Columns that must NEVER be sampled from a replica.
MUST_DENY = [
    "MessageBody", "ApiKey", "PhoneNumber", "EmailAddress", "PasswordHash",
    "CustomerName", "AccountUid", "IpAddress", "DateOfBirth", "CardNumber",
    "AuthToken", "Msisdn", "FirstName", "StreetAddress", "PostalCode",
]

# Low-cardinality enum-ish columns that SHOULD remain samplable.
MUST_ALLOW = [
    "StatusCode", "ChannelType", "Direction", "Tier", "Priority",
    "Currency", "CountryCode", "IsActive",
]


def load_pattern() -> str:
    for line in DENY_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    raise SystemExit(f"no pattern found in {DENY_FILE}")


def main() -> int:
    rx = re.compile(load_pattern())

    leaked = [c for c in MUST_DENY if not rx.search(c)]
    over_blocked = [c for c in MUST_ALLOW if rx.search(c)]

    for c in leaked:
        print(f"FAIL: '{c}' is sensitive but would be sampled")
    for c in over_blocked:
        print(f"FAIL: '{c}' is a safe enum column but is denied")

    if leaked or over_blocked:
        return 1

    print(f"OK: {len(MUST_DENY)} sensitive columns denied, "
          f"{len(MUST_ALLOW)} enum columns allowed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
