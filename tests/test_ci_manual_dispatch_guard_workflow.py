#!/usr/bin/env python3
"""Contracts for the manual-dispatch guard's CI-side check and its non-main dispatch route."""

from pathlib import Path
import unittest

import yaml
from test_seed_derived_data import evaluate, github_context
import workflow_jobs

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github" / "workflows" / "ci.yml"


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
    cells = workflow_jobs.runs_on_cells(workflow["jobs"]["remote-daemon-macos-tests"])
    assert cells is not None and len(cells) == 1, cells
    route = cells[0]
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
