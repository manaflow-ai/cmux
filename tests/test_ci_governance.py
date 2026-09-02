#!/usr/bin/env python3
"""Behavioral checks for the required-CI governance contract.

CODEOWNERS and the rollout document are policy inputs, so this small test
checks their effective entries and required activation terms.
"""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CODEOWNERS = ROOT / ".github" / "CODEOWNERS"
DOC = ROOT / "docs" / "ci-required-checks.md"
TRUSTED_OWNERS = {"@austinywang", "@azooz2003-bit"}


def _entries() -> dict[str, set[str]]:
    entries: dict[str, set[str]] = {}
    for raw_line in CODEOWNERS.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        pattern, *owners = line.split()
        entries[pattern] = set(owners)
    return entries


def test_sensitive_ci_paths_have_trusted_owners() -> None:
    entries = _entries()
    for pattern in ("/.github/workflows/**", "/scripts/ci/**", "/.github/CODEOWNERS"):
        assert entries.get(pattern) == TRUSTED_OWNERS, pattern


def test_rollout_requires_code_owner_protection() -> None:
    text = DOC.read_text(encoding="utf-8")
    required_terms = (
        "ci-status",
        "15368",
        "require_code_owner_review=true",
        "required_approving_review_count >= 1",
        "separate active ruleset",
    )
    for term in required_terms:
        assert term in text, term


if __name__ == "__main__":
    test_sensitive_ci_paths_have_trusted_owners()
    test_rollout_requires_code_owner_protection()
    print("PASS: CI governance contract")
