#!/usr/bin/env python3
"""The PR autofix's `autofix repairs` job runs on a pull request only on a re-run.

Its patch (artifact pr-autofix-patch) is consumed only by ci-oops act_fixer after a mechanical red, which re-runs
the job (run_attempt > 1) when the head's run has no artifact; running it on every head cost 28,441 runner-min/day.
Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."
A non-pull_request caller (workflow_call from another event) still runs it on the first attempt.
"""
import re
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-pr-autofix.yml"


def repair_if() -> str:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["repair"]["if"]


class RepairOnRedTests(unittest.TestCase):
    def test_a_pull_request_runs_it_only_on_a_rerun(self):
        expr = repair_if()
        self.assertIn("github.run_attempt > 1", expr)
        # the first term gates the whole expression: event is not a pull request, or this is a re-run
        self.assertRegex(expr, r"^\$\{\{ \(+github\.event_name != 'pull_request' \|\| github\.run_attempt > 1\) &&")

    def test_a_rerun_of_a_draft_head_still_repairs(self):
        # the re-run's event payload keeps draft=true; the draft tier must not skip an explicit re-run
        self.assertNotIn("draft", repair_if())

    def test_other_events_are_not_gated_by_the_attempt(self):
        # the attempt term is only ever OR-ed with the non-pull_request case
        self.assertEqual(len(re.findall(r"run_attempt", repair_if())), 1)

    def test_the_push_job_still_needs_the_repair_patch(self):
        push_if = yaml.safe_load(WORKFLOW.read_text())["jobs"]["push"]["if"]
        self.assertIn("needs.repair.outputs.patch == 'true'", push_if)


if __name__ == "__main__":
    unittest.main()
