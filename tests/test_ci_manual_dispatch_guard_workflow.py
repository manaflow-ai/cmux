#!/usr/bin/env python3
"""Contracts for the privileged manual-dispatch cancellation watcher."""

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci-manual-dispatch-guard.yml"
CI = ROOT / ".github" / "workflows" / "ci.yml"


def trigger(document: dict) -> dict:
    return document.get("on", document.get(True))


def test_watcher_is_requested_ci_workflow_run() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    event = trigger(document)
    assert event["workflow_run"] == {"workflows": ["CI"], "types": ["requested"]}
    assert document["env"]["SOURCE_WORKFLOW_PATHS"] == ".github/workflows/ci.yml"
    assert document["permissions"] == {}


def test_only_manual_dispatches_get_a_writer() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    guard = document["jobs"]["guard"]
    assert guard["if"] == (
        "github.event.workflow_run.path == '.github/workflows/ci.yml' && "
        "github.event.workflow_run.event == 'workflow_dispatch'"
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
    assert all("manual_dispatch_guard.py" not in str(step) for step in changes["steps"])


if __name__ == "__main__":
    suite = unittest.TestSuite()
    for name, function in sorted(globals().items()):
        if name.startswith("test_"):
            suite.addTest(unittest.FunctionTestCase(function))
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        raise SystemExit(1)
