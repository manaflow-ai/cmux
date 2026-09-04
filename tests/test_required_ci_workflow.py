#!/usr/bin/env python3
"""Behavioral unit tests for the trusted required-CI watcher."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "required-ci.yml"
HELPER = ROOT / "scripts" / "ci" / "verify_required_ci_run.py"

spec = importlib.util.spec_from_file_location("verify_required_ci_run", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def test_select_exact_ci_run_rejects_wrong_sha_and_workflow() -> None:
    expected = "a" * 40
    runs = [
        {"id": 1, "head_sha": "b" * 40, "path": ".github/workflows/ci.yml@refs/heads/main", "created_at": "2026-01-01T00:00:00Z"},
        {"id": 2, "head_sha": expected, "path": ".github/workflows/other.yml@refs/heads/main", "created_at": "2026-01-02T00:00:00Z"},
    ]
    assert module.select_exact_ci_run(runs, expected_sha=expected) is None


def test_select_exact_ci_run_uses_newest_matching_run() -> None:
    expected = "a" * 40
    runs = [
        {"id": 1, "head_sha": expected, "path": ".github/workflows/ci.yml@refs/pull/1/merge", "created_at": "2026-01-01T00:00:00Z", "status": "completed", "conclusion": "failure"},
        {"id": 2, "head_sha": expected, "path": ".github/workflows/ci.yml@refs/pull/1/merge", "created_at": "2026-01-02T00:00:00Z", "status": "completed", "conclusion": "success"},
    ]
    selected = module.select_exact_ci_run(runs, expected_sha=expected)
    assert selected is not None
    assert selected.run_id == 2


def test_select_exact_ci_run_ignores_malformed_matching_items() -> None:
    expected = "a" * 40
    runs = [
        {"head_sha": expected, "path": ".github/workflows/ci.yml@refs/pull/1/merge"},
        {"id": 3, "head_sha": expected, "path": ".github/workflows/ci.yml@refs/pull/1/merge", "created_at": "2026-01-03T00:00:00Z"},
    ]
    selected = module.select_exact_ci_run(runs, expected_sha=expected)
    assert selected is not None
    assert selected.run_id == 3


def test_github_api_timeout_is_converted_to_a_sanitized_verification_error() -> None:
    original_run = module.subprocess.run

    def raise_timeout(*_args: object, **_kwargs: object) -> object:
        raise subprocess.TimeoutExpired(cmd="gh api", timeout=30)

    module.subprocess.run = raise_timeout  # type: ignore[assignment]
    try:
        module._gh_json("repos/manaflow-ai/cmux/actions/workflows/ci.yml/runs")
    except module.RequiredCIVerificationError as error:
        assert str(error) == "GitHub API request failed"
    else:
        raise AssertionError("a hung GitHub API call must fail closed")
    finally:
        module.subprocess.run = original_run


def test_github_api_rejects_endpoints_outside_the_fixed_actions_surface() -> None:
    try:
        module._gh_json("repos/manaflow-ai/cmux/issues/1")
    except module.RequiredCIVerificationError as error:
        assert "outside the allowed endpoint" in str(error)
    else:
        raise AssertionError("the watcher must not execute arbitrary gh endpoints")


def test_verify_ci_jobs_requires_one_successful_aggregate() -> None:
    run = module.RunSummary(
        run_id=7,
        status="completed",
        conclusion="success",
        path=".github/workflows/ci.yml",
        head_sha="a" * 40,
        created_at="2026-01-01T00:00:00Z",
    )
    module.verify_ci_jobs(
        [{"name": "ci-status", "status": "completed", "conclusion": "success"}],
        run=run,
    )

    try:
        module.verify_ci_jobs(
            [{"name": "ci-status", "status": "completed", "conclusion": "failure"}],
            run=run,
        )
    except module.RequiredCIVerificationError:
        pass
    else:
        raise AssertionError("a failed ci-status job must fail the trusted watcher")


def test_cancellation_aware_wait_stops_before_retry_interval() -> None:
    waiter = module.CancellationAwareWait()
    waiter.cancel()
    try:
        waiter.wait(300)
    except module.RequiredCIVerificationError as error:
        assert "cancelled" in str(error)
    else:
        raise AssertionError("a cancelled watcher must not wait for the full interval")


def test_repository_polling_uses_injected_wait_and_cancellation() -> None:
    expected = "a" * 40
    calls: list[str] = []
    clock = iter((0.0, 0.0, 1.0, 1.0, 2.0))

    def fake_now() -> float:
        return next(clock)

    def fake_wait(seconds: float) -> None:
        calls.append(str(seconds))

    runs = {"workflow_runs": []}
    try:
        module.verify_repository_ci(
            repository="manaflow-ai/cmux",
            expected_sha=expected,
            browser_required="false",
            browser_result="skipped",
            timeout_seconds=1,
            poll_seconds=7,
            now=fake_now,
            sleep=fake_wait,
            api=lambda _endpoint: runs,
        )
    except module.RequiredCIVerificationError as error:
        assert "timeout" in str(error)
    else:
        raise AssertionError("a pending exact run must time out")
    assert calls == ["7"]


def test_workflow_runs_from_base_and_checks_exact_head() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "pull_request_target:" in workflow
    assert "ref: ${{ github.event.pull_request.base.sha }}" in workflow
    assert "EXPECTED_SHA: ${{ github.event.pull_request.head.sha }}" in workflow
    assert "verify_required_ci_run.py" in workflow
    assert "required-browser-runtime" in workflow
    assert "uses: ./.github/workflows/test-e2e.yml" in workflow
    assert "trusted_ref: ${{ github.event.pull_request.base.sha }}" in workflow
    assert "testBrowserEngineSmokeRendersEvaluatesScreenshotsAndReopens" in workflow
    assert "BROWSER_REQUIRED" in workflow
    assert "BROWSER_RESULT" in workflow
    assert "actions: read" in workflow
    assert "contents: read" in workflow
    assert "pull-requests: read" in workflow
    assert "runs-on: ubuntu-24.04 # github-hosted-required" in workflow
    assert "previous_filename // empty" in workflow
    assert "EXPECTED_HEAD_SHA: ${{ github.event.pull_request.head.sha }}" in workflow
    assert "observed_head_sha" in workflow
    assert "group: required-ci-${{ github.event.pull_request.number }}" in workflow
    assert "head.sha }}" not in workflow.split("concurrency:", 1)[1].split("jobs:", 1)[0]


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: trusted CI watcher contract")
