#!/usr/bin/env python3
"""Risk evidence skips the expensive base-history fetch only when it cannot help.

The existing recent-revert classifier blames base-side lines deleted by the PR.
A PR with exactly zero deleted lines cannot take back another PR's code by
deletion, irrespective of its added files or risk tier. Unknown metadata must
keep the full audit; every event must still publish a risk evidence verdict.
"""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"


class HistoryAdmission(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        job = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)["jobs"]["evidence"]
        cls.job = job
        cls.steps = {s["name"]: s for s in job["steps"]}

    def test_zero_deletions_skips_history_but_unknown_still_fetches(self):
        history = self.steps["Fetch the base's recent history"]
        # GitHub compares null as numeric zero. The explicit null arm is essential
        # or a missing field would suppress the safety check.
        self.assertEqual(
            history["if"],
            "${{ github.event.pull_request.deletions == null || "
            "github.event.pull_request.deletions > 0 }}",
        )
        self.assertIn('git -C "$history" fetch', history["run"])
        self.assertIn('echo "BASE_HISTORY=$history"', history["run"])

    def test_the_risk_gate_and_all_its_reads_still_run_on_every_event(self):
        # A skipped JOB can be mistaken for a passed required risk evidence
        # check. Restrict the optimization to history, keeping the check itself
        # and its classification, signoff and labels untouched.
        self.assertNotIn("if", self.job)
        for name in ("Checkout the classifier at the tip of the pull request's base branch",
                     "Grade the pull request", "Set the risk label",
                     "Hold high until a person looked"):
            self.assertIn(name, self.steps)
        grade = self.steps["Grade the pull request"]
        self.assertNotIn("if", grade)
        self.assertIn('${BASE_HISTORY:+--repo-dir "$BASE_HISTORY"}', grade["run"])
        self.assertIn('ready=true', grade["run"])


if __name__ == "__main__":
    unittest.main()
