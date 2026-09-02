#!/usr/bin/env python3
"""Behavior tests for the base-owned CI status gate."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts" / "ci" / "ci_status_gate.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ci-status-gate.yml"

spec = importlib.util.spec_from_file_location("ci_status_gate", GATE)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


HEAD_SHA = "a" * 40


def check(
    name: str,
    *,
    number: int,
    status: str = "completed",
    conclusion: str = "success",
    head_sha: str = HEAD_SHA,
    app_id: int = 15368,
) -> dict[str, object]:
    return {
        "id": number,
        "name": name,
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "head_sha": head_sha,
        "app": {"id": app_id},
    }


def complete_checks() -> list[dict[str, object]]:
    names = [
        "changes",
        "workflow-guard-tests",
        "GhosttyKit release check",
        "linux-preflight",
        "tests",
        "tests-build-and-lag",
        "swift-package-tests",
        "release-build",
        "web-typecheck",
        "react-apps-check",
        "diff-sidecar-check",
        "web-db-migrations",
        "remote-daemon-tests",
        "agent-session-web-resources",
    ]
    checks = [check(name, number=index + 1) for index, name in enumerate(names)]
    checks.extend(
        check(f"app-host unit tests ({index}/6)", number=100 + index)
        for index in range(1, 7)
    )
    return checks


ALL_FALSE = {route: False for route in module.ROUTE_NAMES}


def test_docs_only_snapshot_accepts_skipped_routes() -> None:
    failures = module.validate_snapshot(
        complete_checks(),
        ["docs/ci-required-checks.md"],
        head_sha=HEAD_SHA,
    )
    assert failures == []


def test_web_snapshot_requires_web_jobs() -> None:
    checks = complete_checks()
    checks[8]["conclusion"] = "failure"
    failures = module.validate_snapshot(
        checks,
        ["web/app/page.tsx"],
        head_sha=HEAD_SHA,
    )
    assert any("web-typecheck" in failure for failure in failures)


def test_missing_matrix_shard_fails_closed() -> None:
    checks = [
        item
        for item in complete_checks()
        if item["name"] != "app-host unit tests (6/6)"
    ]
    failures = module.validate_snapshot(
        checks,
        ["Sources/AppDelegate.swift"],
        head_sha=HEAD_SHA,
    )
    assert any("app-host-unit-tests" in failure for failure in failures)


def test_pending_check_does_not_pass() -> None:
    checks = complete_checks()
    checks[0] = check("changes", number=1, status="in_progress")
    failures = module.validate_snapshot(
        checks,
        ["README.md"],
        head_sha=HEAD_SHA,
    )
    assert any("changes" in failure for failure in failures)


def test_stale_or_untrusted_app_checks_are_not_accepted() -> None:
    checks = complete_checks()
    checks[0] = check("changes", number=1, head_sha="b" * 40)
    checks[1] = check("workflow-guard-tests", number=2, app_id=999)
    failures = module.validate_snapshot(
        checks,
        ["README.md"],
        head_sha=HEAD_SHA,
    )
    assert any("changes" in failure for failure in failures)
    assert any("workflow-guard-tests" in failure for failure in failures)


def test_unexpected_ci_job_is_rejected() -> None:
    checks = complete_checks()
    checks.append(check("unreviewed-job", number=999))
    failures = module.validate_snapshot(
        checks,
        ["README.md"],
        head_sha=HEAD_SHA,
    )
    assert any("unreviewed-job" in failure for failure in failures)


def test_workflow_is_base_owned_and_read_only() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "pull_request_target:" in text
    assert "workflow_run:" in text
    assert "pull_request:" not in text
    assert "ci-status-gate:" in text
    assert "actions: read" in text
    assert "checks: read" in text
    assert "pull-requests: read" in text
    assert "contents: write" not in text
    assert ".ci-trusted/scripts/ci/ci_status_gate.py" in text


def test_event_payload_parser_rejects_invalid_json() -> None:
    try:
        module.parse_event("not-json")
    except module.GateError as error:
        assert "event payload" in str(error)
    else:
        raise AssertionError("invalid event payload was accepted")


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: base-owned CI status gate")
