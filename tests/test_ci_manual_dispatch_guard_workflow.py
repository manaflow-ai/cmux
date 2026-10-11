#!/usr/bin/env python3
"""Contracts for the privileged manual-dispatch cancellation watcher."""

from pathlib import Path
import unittest

import yaml
from test_seed_derived_data import evaluate, github_context

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci-manual-dispatch-guard.yml"
CI = ROOT / ".github" / "workflows" / "ci.yml"


def trigger(document: dict) -> dict:
    return document.get("on", document.get(True))


def test_watcher_is_requested_ci_workflow_run() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    event = trigger(document)
    assert event["workflow_run"] == {"workflows": ["CI"], "types": ["requested"], "branches": ["main"]}
    assert document["env"]["SOURCE_WORKFLOW_PATHS"] == ".github/workflows/ci.yml"
    assert document["permissions"] == {}
    watcher_env = document["jobs"]["guard"]["steps"][-1]["env"]
    for key in ("SOURCE_EVENT_NAME", "SOURCE_REPOSITORY", "SOURCE_REF_NAME", "SOURCE_SHA", "SOURCE_RUN_ID", "SOURCE_COVERAGE_FINGERPRINT"):
        assert key in watcher_env
    assert "GITHUB_EVENT_NAME" not in watcher_env


def test_only_manual_dispatches_get_a_writer() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    guard = document["jobs"]["guard"]
    assert guard["if"] == (
        "github.event.workflow_run.path == '.github/workflows/ci.yml' && "
        "github.event.workflow_run.event == 'workflow_dispatch' && "
        "github.event.workflow_run.head_branch == 'main'"
    )
    assert guard["permissions"] == {
        "actions": "write",
        "contents": "read",
        "pull-requests": "read",
    }
    assert "scripts/ci/manual_dispatch_guard.py" in guard["steps"][-1]["run"]


def test_ci_changes_job_remains_read_only() -> None:
    document = yaml.safe_load(CI.read_text(encoding="utf-8"))
    changes = document["jobs"]["changes"]
    assert changes["permissions"]["actions"] == "read"
    steps = changes["steps"]
    index = next(i for i, step in enumerate(steps) if "manual_dispatch_guard.py" in step.get("run", ""))
    guard = steps[index]
    assert guard["if"] == "github.event_name == 'workflow_dispatch'"
    assert guard["run"] == "python3 scripts/ci/manual_dispatch_guard.py --check-only"
    assert index < next(i for i, step in enumerate(steps) if step.get("id") == "detect")
    assert "continue-on-error" not in guard


def test_non_main_dispatch_remote_daemon_uses_picked_owned_side_runner() -> None:
    workflow = yaml.safe_load((CI.parent / "remote-daemon.yml").read_text())
    route = workflow["jobs"]["remote-daemon-macos-tests"]["runs-on"]
    context = github_context("workflow_dispatch", ref="refs/heads/topic")
    context["github"].update(repository="manaflow-ai/cmux", run_attempt=1,
                             workflow_ref="manaflow-ai/cmux/.github/workflows/ci.yml@refs/heads/topic")
    context["inputs"].update(pr_owned_jobs=" remote-daemon ", pr_side_runner="glaeda-side-std-xcode-26.6")
    assert evaluate(route, context) == "glaeda-side-std-xcode-26.6"


if __name__ == "__main__":
    suite = unittest.TestSuite()
    for name, function in sorted(globals().items()):
        if name.startswith("test_"):
            suite.addTest(unittest.FunctionTestCase(function))
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        raise SystemExit(1)
