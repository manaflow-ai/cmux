#!/usr/bin/env python3
"""The PR autofix pushes its repair commit only after the export areas were read.

A pushed autofix head carries an Autofix-Run trailer, and action-areas skips the
Mac exports for such a head. So a push made while action-areas was cancelled
(its full fetch hit the 5-minute timeout) or the Mac exports failed leaves the
pull request with stale exports that no later autofix run regenerates (seen on
#21814: run 39315375602).
"""

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-pr-autofix.yml"


def job_block(text: str, name: str) -> str:
    match = re.search(rf"^  {re.escape(name)}:\n((?:    .*\n|\s*\n)+)", text, re.MULTILINE)
    assert match, f"job {name} not found"
    return match.group(1)


class PushGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.push = job_block(WORKFLOW.read_text(), "push")

    def test_push_waits_for_the_export_areas_and_exports(self) -> None:
        needs = re.search(r"^    needs: \[(.*)\]$", self.push, re.MULTILINE)
        self.assertIsNotNone(needs, "push needs a list naming action-areas and action-exports")
        names = {n.strip() for n in needs.group(1).split(",")}
        self.assertLessEqual({"action-areas", "action-exports", "repair"}, names)

    def test_push_requires_areas_success_and_exports_not_failed(self) -> None:
        cond = re.search(r"^    if: (.*)$", self.push, re.MULTILINE).group(1)
        self.assertIn("needs.action-areas.result == 'success'", cond)
        self.assertIn("needs.action-exports.result == 'success' || needs.action-exports.result == 'skipped'", cond)
        self.assertIn("needs.repair.result == 'success'", cond)


if __name__ == "__main__":
    unittest.main()
