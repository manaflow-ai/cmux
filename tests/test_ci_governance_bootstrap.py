#!/usr/bin/env python3
"""Check ownership of the trusted CI policy inputs."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CODEOWNERS = ROOT / ".github" / "CODEOWNERS"
GATE_WORKFLOW = ROOT / ".github" / "workflows" / "ci-status-gate.yml"
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


def test_gate_workflow_is_read_only_and_has_both_lifecycle_triggers() -> None:
    text = GATE_WORKFLOW.read_text(encoding="utf-8")
    assert "pull_request_target:" in text
    assert "workflow_run:" in text
    assert "workflows: [CI]" in text
    assert "ci-status-gate:" in text
    assert "actions: read" in text
    assert "checks: read" in text
    assert "pull-requests: read" in text
    assert "contents: write" not in text
    assert "persist-credentials: false" in text
    assert ".ci-trusted/scripts/ci/ci_status_gate.py" in text


if __name__ == "__main__":
    test_sensitive_ci_inputs_have_two_trusted_owners()
    test_gate_workflow_is_read_only_and_has_both_lifecycle_triggers()
    print("PASS: bootstrap CI governance contract")
