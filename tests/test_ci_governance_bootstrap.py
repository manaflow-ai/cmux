#!/usr/bin/env python3
"""Check ownership of the trusted CI policy inputs."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CODEOWNERS = ROOT / ".github" / "CODEOWNERS"
TRUSTED_OWNERS = {"@austinywang", "@azooz2003-bit"}
SENSITIVE_PATTERNS = ("/.github/workflows/**", "/scripts/ci/**", "/.github/CODEOWNERS")


def _entries() -> dict[str, set[str]]:
    entries: dict[str, set[str]] = {}
    for raw_line in CODEOWNERS.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        pattern, *owners = line.split()
        entries[pattern] = set(owners)
    return entries


def test_sensitive_ci_inputs_have_two_trusted_owners() -> None:
    entries = _entries()
    for pattern in SENSITIVE_PATTERNS:
        assert entries.get(pattern) == TRUSTED_OWNERS, pattern


if __name__ == "__main__":
    test_sensitive_ci_inputs_have_two_trusted_owners()
    print("PASS: bootstrap CI governance contract")
