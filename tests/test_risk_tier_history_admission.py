#!/usr/bin/env python3
"""Risk evidence skips the expensive base-history fetch only when it cannot help.

The existing recent-revert classifier blames base-side lines deleted by the PR.
A PR with exactly zero deleted lines cannot take back another PR's code by
deletion, irrespective of its added files or risk tier. Unknown metadata must
keep the full audit; every event that can change the verdict must still
publish a risk evidence verdict.
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
        # An expression coerces null to 0 in a comparison, so `deletions == null` is
        # true for zero too and `deletions != 0` would skip a missing field. toJSON
        # tells them apart as strings: '0' for zero, 'null' for missing.
        self.assertEqual(
            history["if"],
            "${{ toJSON(github.event.pull_request.deletions) != '0' }}",
        )
        self.assertIn('git -C "$history" fetch', history["run"])
        self.assertIn('echo "BASE_HISTORY=$history"', history["run"])

    def test_the_risk_gate_and_all_its_reads_still_run_on_every_event(self):
        # A skipped JOB named risk evidence can be mistaken for a passed required
        # check (#38003). The one job-level if skips only a label event that cannot
        # change the verdict (any label but risk:human-ok or risk:waived, including
        # the risk:* label this job sets), and that skipped run takes another name
        # and its own concurrency group, so the newest "risk evidence" is always a
        # real grade (the backend-migrations gate's "label (ignored)" pattern).
        # freeze-ok grades too (this job posts the merge freeze status into feat-cmux-next), and so does
        # every edit but a title-only one (risk_tier.py never reads the title) or a review bot's summary edit.
        label = ("((github.event.action == 'labeled' || github.event.action == 'unlabeled') && "
                 "github.event.label.name != 'risk:human-ok' && github.event.label.name != 'risk:waived' && "
                 "(github.event.label.name != 'freeze-ok' || vars.MERGE_FREEZE_OWN_RUNNER == '1'))")
        title = "(github.event.action == 'edited' && !github.event.changes.body && !github.event.changes.base)"
        # A review bot's own summary edit of the description (cubic-dev-ai, blacksmith-sh) never touches a line
        # risk_tier.py reads: it skips the same way, under its own name and group.
        bot = ("(github.event.action == 'edited' && !github.event.changes.base && "
               "(github.event.sender.login == 'cubic-dev-ai[bot]' || github.event.sender.login == 'blacksmith-sh[bot]'))")
        self.assertEqual(self.job["if"], "${{ !(" + label + " || " + title + " || " + bot + ") }}")
        self.assertEqual(self.job["name"],
                         "${{ " + label + " && 'risk evidence label (ignored)' || " + title
                         + " && 'risk evidence title edit (ignored)' || " + bot
                         + " && 'risk evidence review bot edit (ignored)' || 'risk evidence' }}")
        self.assertIn("(" + label + " || " + title + " || " + bot + ") && format('-ignored-{0}', github.run_id)",
                      self.job["concurrency"]["group"])
        for name in ("Checkout the classifier at the tip of the pull request's base branch",
                     "Grade the pull request", "Set the risk label",
                     "Hold only an unowned takeback"):
            self.assertIn(name, self.steps)
        grade = self.steps["Grade the pull request"]
        self.assertNotIn("if", grade)
        self.assertIn('${BASE_HISTORY:+--repo-dir "$BASE_HISTORY"}', grade["run"])
        self.assertIn('ready=true', grade["run"])


if __name__ == "__main__":
    unittest.main()
