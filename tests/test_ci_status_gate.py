#!/usr/bin/env python3
"""Behavior tests for the base-owned CI status gate."""

from __future__ import annotations

import importlib.util
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
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


class FakeAPI:
    """In-memory GitHub API fixture for the end-to-end gate path."""

    repository = "manaflow-ai/cmux"

    def __init__(self, checks: list[dict[str, object]]) -> None:
        self.checks = checks
        self.requests: list[str] = []

    def get(self, endpoint: str, *, paginate: bool = False) -> object:
        self.requests.append(endpoint)
        if endpoint.endswith("/pulls/1"):
            return {
                "number": 1,
                "state": "open",
                "changed_files": 1,
                "base": {"ref": "main", "repo": {"full_name": self.repository}},
                "head": {"sha": HEAD_SHA},
            }
        if "/actions/runs?event=" in endpoint:
            return {
                "workflow_runs": [
                    {
                        "id": 900,
                        "path": module.CI_WORKFLOW_PATH,
                        "event": "pull_request",
                        "head_sha": HEAD_SHA,
                        "status": "completed",
                        "created_at": "2026-09-01T00:00:00Z",
                        "pull_requests": [{"number": 1}],
                    }
                ]
            }
        if endpoint.endswith("/actions/runs/900/jobs?per_page=100"):
            jobs = []
            for item in self.checks:
                jobs.append(
                    {
                        "name": item["name"],
                        "head_sha": HEAD_SHA,
                        "check_run_url": f"https://api.github.com/repos/manaflow-ai/cmux/check-runs/{item['id']}",
                    }
                )
            return [{"jobs": jobs}]
        if "/commits/" in endpoint and "/check-runs" in endpoint:
            return [{"check_runs": self.checks}]
        if endpoint.endswith("/pulls/1/files?per_page=100"):
            return [{"files": [{"filename": "README.md"}]}]
        raise AssertionError(f"unexpected API endpoint: {endpoint}")


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


def test_gate_queries_exact_head_and_ci_run_jobs() -> None:
    api = FakeAPI(complete_checks())
    stdout = StringIO()
    stderr = StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        result = module._run_gate(
            api,
            "pull_request_target",
            {"number": 1, "pull_request": {"head": {"sha": HEAD_SHA}}},
        )
    assert result == 0, stderr.getvalue()
    assert any(
        f"/commits/{HEAD_SHA}/check-runs?per_page=100" in request
        for request in api.requests
    )
    assert "CI status gate passed." in stdout.getvalue()


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: base-owned CI status gate")
