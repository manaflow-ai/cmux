#!/usr/bin/env python3
"""Policy tests for scripts/ci/shed_superseded_runs.py over fixture runs (no network): the base autofix carrier kept by main's sweep."""

from __future__ import annotations

import datetime as dt
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/shed_superseded_runs.py"
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
import shed_superseded_runs as shed  # noqa: E402

class BaseAutofixCarrierTests(unittest.TestCase):
    """2026-11-24: cmux-next base autofix completed no run for 15 hours. Its run on a pushed commit waits up to 45
    minutes for that push's exports, then queues "action exports (Mac)"; by then base has moved, the run has nothing
    running, and each sweep cancelled it as superseded-base (run 45371841534, sweep 45378739122) although it carries
    the exports of every run that deferred to it."""

    PATH = ".github/workflows/cmux-next-base-autofix.yml"

    def carrier(self, **over):
        r = {
            "id": 45371841534, "status": "in_progress", "run_attempt": 1, "event": "push",
            "head_branch": "feat-cmux-next", "head_sha": "7e9b5a72dd", "name": "cmux-next base autofix",
            "path": self.PATH, "created_at": "2026-11-24T10:08:10Z",
            "head_repository": {"full_name": "manaflow-ai/cmux"},
        }
        r.update(over)
        return r

    def why(self, r, jobs=None):
        return shed.verdict(r, "manaflow-ai/cmux", {"feat-cmux-next": "newer-tip", "feature": "tip"}, jobs)

    def test_carrier_whose_mac_exports_wait_for_a_runner_is_kept_after_base_moves(self):
        r = self.carrier()
        done = {"status": "completed", "runner_id": 7, "steps": [{"name": "x"}]}
        waiting = {"status": "queued", "name": "action exports (Mac)", "runner_id": 0, "steps": []}
        pending = {"status": "queued", "name": "autofix feat-cmux-next", "runner_id": 0, "steps": []}
        jobs = {r["id"]: [dict(done, name="action areas the push touched"),
                          dict(done, name="exports from the push's generated files"), waiting, pending]}
        # The ordering that starved it: nothing of the run is running, and its commit is no longer the tip.
        self.assertTrue(shed.unstarted(jobs[r["id"]]))
        self.assertEqual(self.why(r, jobs), "keep:answers-every-push-since")
        self.assertEqual(self.why(self.carrier(status="queued")), "keep:answers-every-push-since")
        picks, counts = shed.plan([r, self.carrier(id=2, status="queued")], "manaflow-ai/cmux",
                                  {"feat-cmux-next": "newer-tip"}, 100, jobs)
        self.assertEqual((picks, counts), ([], {"keep:answers-every-push-since": 2}))

    def test_only_the_base_push_run_of_that_workflow_is_kept(self):
        # Another base push workflow in the same state is still shed, and so is this workflow on a lane branch.
        other = self.carrier(path=".github/workflows/ci.yml", name="CI", status="queued")
        self.assertEqual(self.why(other), "superseded-base")
        self.assertEqual(self.why(self.carrier(head_branch="feature", status="queued")), "superseded")


if __name__ == "__main__":
    unittest.main()
