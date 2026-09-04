#!/usr/bin/env python3
"""Behavioral unit tests for the trusted required-CI watcher."""

from __future__ import annotations

import importlib.util
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
        {"id": 1, "head_sha": "b" * 40, "path": ".github/workflows/ci.yml", "created_at": "2026-01-01T00:00:00Z"},
        {"id": 2, "head_sha": expected, "path": ".github/workflows/other.yml", "created_at": "2026-01-02T00:00:00Z"},
    ]
    assert module.select_exact_ci_run(runs, expected_sha=expected) is None


def test_select_exact_ci_run_uses_newest_matching_run() -> None:
    expected = "a" * 40
    runs = [
        {"id": 1, "head_sha": expected, "path": ".github/workflows/ci.yml", "created_at": "2026-01-01T00:00:00Z", "status": "completed", "conclusion": "failure"},
        {"id": 2, "head_sha": expected, "path": ".github/workflows/ci.yml", "created_at": "2026-01-02T00:00:00Z", "status": "completed", "conclusion": "success"},
    ]
    selected = module.select_exact_ci_run(runs, expected_sha=expected)
    assert selected is not None
    assert selected.run_id == 2


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


def test_workflow_runs_from_base_and_checks_exact_head() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "pull_request_target:" in workflow
    assert "ref: ${{ github.event.pull_request.base.sha }}" in workflow
    assert "EXPECTED_SHA: ${{ github.event.pull_request.head.sha }}" in workflow
    assert "verify_required_ci_run.py" in workflow
    assert "required-browser-runtime" in workflow
    assert "uses: ./.github/workflows/test-e2e.yml" in workflow
    assert "testBrowserEngineSmokeRendersEvaluatesScreenshotsAndReopens" in workflow
    assert "BROWSER_REQUIRED" in workflow
    assert "BROWSER_RESULT" in workflow
    assert "actions: read" in workflow
    assert "contents: read" in workflow
    assert "pull-requests: read" in workflow
    assert "runs-on: ubuntu-24.04 # github-hosted-required" in workflow
    assert "group: required-ci-${{ github.event.pull_request.number }}" in workflow
    assert "head.sha }}" not in workflow.split("concurrency:", 1)[1].split("jobs:", 1)[0]


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: trusted CI watcher contract")
