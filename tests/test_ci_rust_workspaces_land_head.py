#!/usr/bin/env python3
"""The head handed to land runs rust-workspaces' plan, workspace matrix and summary.

next_autoland holds a pull request that changes a run workspace's Rust until `rust workspaces / <root>` passed on
its head. Tier A (scripts/ci/affected-jobs.json pull_request_skip) skipped those jobs on every feat-cmux-next pull
request, and since the hourly full tier (CI_LAND_FULL_PER_PR=0) the land tier skipped them on the landing head too, so
no head ever ran them and every Rust pull request was held ("changes Rust: no cmux-next-ios/rust ran on this head").
A non-draft `ready-to-land` head now runs them; plan is affected-only, so a head that changes no Cargo workspace
pays nothing past it. Every other pull request head still skips them.

Run: python3 tests/test_ci_rust_workspaces_land_head.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pr_test_lanes  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "rust-workspaces.yml"
LABELS = "github.event.pull_request.labels.*.name"


class Expression(pr_test_lanes.Expression):
    """pr_test_lanes' reader, with the pull request's labels read from the context."""

    @staticmethod
    def call(name, args):
        if name.lower() == "contains" and len(args) == 2 and isinstance(args[0], list):
            return args[1] in args[0]
        return pr_test_lanes.Expression.call(name, args)


def head(labels, draft=False, base="feat-cmux-next", land_full="0"):
    return {
        "github.event_name": "pull_request",
        "github.event.action": "labeled" if labels else "synchronize",
        "github.event.label.name": labels[-1] if labels else "",
        "github.event.pull_request.draft": draft,
        "github.event.pull_request.base.ref": base,
        "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
        "github.repository": "manaflow-ai/cmux",
        LABELS: list(labels),
        "vars.CI_LAND_FULL_PER_PR": land_full,
        "vars.CI_LAND_TIER": "",
        "vars.CI_DRAFT_CHEAP_TIER": "",
        "inputs.only": "",
        # No local test receipt; the change touches cmux-next-ios/rust only, which reads no outside file.
        "needs.receipt.result": "success",
        "needs.receipt.outputs.valid": "false",
        "needs.receipt.outputs.audit": "false",
        "needs.reads.outputs.hit": "",
        "needs.plan.result": "success",
        "needs.plan.outputs.jobs": '[{"root": "cmux-next-ios/rust"}]',
    }


def runs(job: str, context: dict) -> bool:
    condition = str(yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][job]["if"]).strip()
    if condition.startswith("${{") and condition.endswith("}}"):
        condition = condition[3:-2]
    value = pr_test_lanes.truthy(Expression(condition, context).evaluate())
    assert value is not pr_test_lanes.UNKNOWN, (job, condition)
    return value


JOBS = ("plan", "workspace", "summary")


class LandHeadRunsTheWorkspaceJobs(unittest.TestCase):
    def test_the_landing_head_runs_them_with_the_per_head_full_tier_off(self) -> None:
        for job in JOBS:
            self.assertTrue(runs(job, head(["ready-to-land"])), job)

    def test_other_heads_still_skip_them(self) -> None:
        for job in JOBS:
            self.assertFalse(runs(job, head([])), job)
            self.assertFalse(runs(job, head(["ready-to-land"], draft=True)), job)
            self.assertFalse(runs(job, head(["risk:low"])), job)

    def test_full_ci_still_runs_them(self) -> None:
        for job in JOBS:
            self.assertTrue(runs(job, head(["full-ci"])), job)


if __name__ == "__main__":
    unittest.main()
