#!/usr/bin/env python3
"""scripts/ci/shed_superseded_runs.py's retired-route verdict over fixture runs (no network)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/shed_superseded_runs.py"
sys.path.insert(0, str(SCRIPT.parent))
import shed_superseded_runs as shed  # noqa: E402

REPO = "manaflow-ai/cmux"
TIPS = {"feature": "tip", "feat-cmux-next": "base"}
NEXT = ".github/workflows/cmux-next.yml"


def run(**over):
    base = {"id": 1, "status": "queued", "run_attempt": 1, "event": "pull_request", "head_branch": "feature",
            "head_sha": "tip", "name": "cmux-next", "path": NEXT, "created_at": "2026-11-25T00:17:22Z",
            "head_repository": {"full_name": REPO}}
    base.update(over)
    return base


class RetiredRouteTests(unittest.TestCase):
    def test_tip_pr_run_created_before_the_move_is_shed(self):
        self.assertEqual(shed.verdict(run(), REPO, TIPS), "retired-route")
        self.assertIn("retired-route", shed.SHED_VERDICTS)

    def test_later_runs_other_workflows_events_retries_and_base_are_kept(self):
        self.assertEqual(shed.verdict(run(created_at="2026-11-25T01:00:00Z"), REPO, TIPS), "keep:current-pull_request")
        self.assertEqual(shed.verdict(run(path=".github/workflows/ci.yml"), REPO, TIPS), "keep:current-pull_request")
        self.assertEqual(shed.verdict(run(event="push"), REPO, TIPS), "keep:current-push")
        self.assertEqual(shed.verdict(run(run_attempt=2), REPO, TIPS), "keep:attempt")
        self.assertEqual(shed.verdict(run(head_branch="feat-cmux-next", head_sha="base", event="push"), REPO, TIPS),
                         "keep:current-push")

    def test_in_progress_run_is_shed_only_when_unstarted(self):
        r = run(status="in_progress")
        queued = {"status": "queued", "runner_id": None, "runner_name": None, "steps": []}
        self.assertEqual(shed.verdict(r, REPO, TIPS, {1: [queued]}), "retired-route")
        self.assertEqual(shed.verdict(r, REPO, TIPS, {1: [{**queued, "status": "in_progress"}]}), "keep:running")


if __name__ == "__main__":
    unittest.main()
