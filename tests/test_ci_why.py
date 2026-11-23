#!/usr/bin/env python3
"""scripts/ci-why reads each red check's verdict from scripts/ci/base_red_excuse.py's exit and message.

The classifier's exit 0 is a base red, 3 a rate limit, and 1 one of: fixed on the base (update the branch),
not comparable yet (ask again), a rerun (cancelled, lost, refused at setup) or the PR's own red. These pin
that mapping and the shard folding of waiting checks, with the classifier and gh stubbed (no network).
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("ci_why", str(ROOT / "scripts" / "ci-why"))
spec = importlib.util.spec_from_loader("ci_why", loader)
ci_why = importlib.util.module_from_spec(spec)
sys.modules["ci_why"] = ci_why
loader.exec_module(ci_why)


def classifier(code: int, stdout: str = "", stderr: str = ""):
    return mock.patch.object(ci_why.subprocess, "run",
                             return_value=subprocess.CompletedProcess([], code, stdout, stderr))


class Verdicts(unittest.TestCase):
    def judge(self, code, stdout="", stderr=""):
        with classifier(code, stdout, stderr):
            return ci_why.judge("o/r", "main", "a" * 40, "tests")

    def test_exit_zero_is_a_base_red_without_the_repeated_name(self):
        self.assertEqual(self.judge(0, "excused 'tests': main run 1 fails the same way\n"),
                         ("base red", "main run 1 fails the same way"))

    def test_a_red_only_on_the_pr_is_yours(self):
        self.assertEqual(self.judge(1, stderr="not excused: 'tests': test_x fails only here\n"),
                         ("yours", "test_x fails only here"))

    def test_a_cancelled_or_lost_job_is_a_rerun(self):
        self.assertEqual(self.judge(1, stderr="not excused: 'tests' is cancelled: it has no verdict to compare "
                                              "with the base; re-run it\n")[0], "rerun")
        self.assertEqual(self.judge(1, stderr="not excused: infra, not a verdict: runner lost\n")[0], "rerun")

    def test_fixed_on_base_asks_for_a_base_merge(self):
        self.assertEqual(self.judge(1, stderr="fixed on base by abc: update the branch\n")[0], "update")

    def test_no_comparable_base_run_yet_is_not_yet(self):
        said = "not excused: 'tests' has no main verdict at or after this PR's merge-base yet; re-check once a run"
        self.assertEqual(self.judge(1, stderr=said)[0], "not yet")

    def test_a_rate_limit_is_not_yet_never_yours(self):
        self.assertEqual(self.judge(3, stderr="rate-limited: 403\n")[0], "not yet")

    def test_a_classifier_past_its_bound_is_not_yet(self):
        with mock.patch.object(ci_why.subprocess, "run", side_effect=subprocess.TimeoutExpired("x", 1)):
            self.assertEqual(ci_why.judge("o/r", "main", "a" * 40, "tests")[0], "not yet")


class Waiting(unittest.TestCase):
    def test_shards_fold_into_one_line_with_a_count(self):
        names = ["web / check (1)", "web / check (2)", "tooling-tests", "web / check (10)"]
        self.assertEqual(ci_why.collapsed(names), [("web / check", 3), ("tooling-tests", 1)])


class PullRequestArgument(unittest.TestCase):
    def test_a_number_or_a_url_names_the_pr(self):
        self.assertEqual(ci_why.find_pr("o/r", "123"), 123)
        self.assertEqual(ci_why.find_pr("o/r", "https://github.com/o/r/pull/456/checks"), 456)
        self.assertEqual(ci_why.find_pr("o/r", "https://github.com/o/r/pull/789"), 789)


if __name__ == "__main__":
    unittest.main()
