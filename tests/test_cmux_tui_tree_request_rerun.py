#!/usr/bin/env python3
"""A tree request re-runs only what it must: a coalesced run in full, a failed run's failed jobs, and stops at 3.

efficiency-scout, 2026-11-21 22:37Z: "Make re-runs go through the coalescing too, or cap automatic re-runs of these
legs." On 2026-11-21 cmux-tui-tree-request.yml re-ran failed runs in full, rebuilding legs that had passed, up to
attempt 4.

Run: python3 tests/test_cmux_tui_tree_request_rerun.py
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "cmux_tui_tree_request_rerun.py"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-tree-request.yml"
sys.path.insert(0, str(SCRIPT.parent))
import cmux_tui_tree_request_rerun as rerun  # noqa: E402


class DecideTest(unittest.TestCase):
    def test_a_coalesced_run_reruns_in_full(self) -> None:
        # Its builds skipped and it succeeded: only a full re-run (attempt > 1 runs past the coalescing) builds it.
        for attempt in (1, 2, 5):
            self.assertEqual(rerun.decide(attempt, "success"), "full")

    def test_a_failed_run_reruns_only_its_failed_jobs(self) -> None:
        for conclusion in ("failure", "cancelled", "timed_out", "startup_failure"):
            for attempt in (1, 2):
                with self.subTest(conclusion=conclusion, attempt=attempt):
                    self.assertEqual(rerun.decide(attempt, conclusion), "failed-jobs")

    def test_three_failed_attempts_stop(self) -> None:
        for attempt in (3, 4, 17):
            self.assertEqual(rerun.decide(attempt, "failure"), "cap")
        self.assertEqual(rerun.MAX_ATTEMPTS, 3)

    def test_cli(self) -> None:
        out = subprocess.run([sys.executable, str(SCRIPT), "--attempt", "2", "--conclusion", "FAILURE"],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(out, "failed-jobs")


class WiringTest(unittest.TestCase):
    def setUp(self) -> None:
        job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["request"]
        self.step = next(s for s in job["steps"] if s.get("id") == "request")["run"]
        self.sparse = job["steps"][0]["with"]["sparse-checkout"]

    def test_the_request_asks_the_script_with_the_runs_attempt_and_conclusion(self) -> None:
        self.assertIn('\\(.run_attempt)\\t\\(.conclusion // "")', self.step)
        self.assertIn("read -r run_id run_status run_url run_attempt run_conclusion", self.step)
        self.assertIn("scripts/ci/cmux_tui_tree_request_rerun.py", self.step)
        self.assertIn("scripts/ci", self.sparse)

    def test_each_decision_takes_its_own_endpoint(self) -> None:
        self.assertIn('actions/runs/$run_id/rerun-failed-jobs"', self.step.split("failed-jobs)", 1)[1].split(";;")[0])
        self.assertIn('actions/runs/$run_id/rerun"', self.step.split("full)", 1)[1].split(";;")[0])
        cap = self.step.split("cap)", 1)[1].split(";;")[0]
        self.assertIn("exit 1", cap)
        self.assertNotIn("gh api", cap)


if __name__ == "__main__":
    unittest.main()
