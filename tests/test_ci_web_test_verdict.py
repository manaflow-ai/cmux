#!/usr/bin/env python3
"""web_test_verdict: one verdict from a test's history and its import graph."""
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("verdict", ROOT / "scripts/ci/web_test_verdict.py")
verdict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict)

OWN = [{"test": "t", "kind": "timeout", "rerun": "passed", "where": "pr", "branch": "fix/repause",
        "job_url": "https://github.com/x/job/117692683085"}]
MAIN = {"test": "t", "where": "main", "branch": "main", "job_url": "u", "at": "2026-10-16"}
OTHER_PR = {"test": "t", "where": "pr", "branch": "other", "pr": 21600, "job_url": "u", "at": "2026-10-15"}
OUTSIDE = {"touches": False, "summary": "no changed file is in vm-route-deadlines.test.ts's import graph"}
INSIDE = {"touches": True, "summary": "vm-route-deadlines.test.ts runs changed code in 1 file(s)"}


class Decide(unittest.TestCase):
    def test_unreachable_and_failing_elsewhere_is_an_unrelated_flake(self):
        result = verdict.decide(OWN, [MAIN, OTHER_PR], OUTSIDE, 7)
        self.assertEqual(result["verdict"], "unrelated flake")
        self.assertEqual(result["line"], "unrelated flake: 2 other failures in 7 days (1 on main, 1 other PR branch); "
                                         "no changed file is in vm-route-deadlines.test.ts's import graph; "
                                         "1 of 1 failure(s) here passed on a re-run of the same SHA")

    def test_unreachable_with_no_other_sighting_is_only_probably_unrelated(self):
        self.assertEqual(verdict.decide(OWN, [], OUTSIDE, 7)["verdict"], "probably unrelated")

    def test_reachable_code_is_likely_the_prs(self):
        self.assertEqual(verdict.decide(OWN, [], INSIDE, 7)["verdict"], "likely this PR's")
        self.assertEqual(verdict.decide(OWN, [MAIN], INSIDE, 7)["verdict"], "touched, also flaky")

    def test_own_failures_are_the_prs_branch(self):
        own, others = verdict.own_and_others({"failures": [*OWN, MAIN, OTHER_PR]}, "fix/repause")
        self.assertEqual((len(own), len(others)), (1, 2))

    def test_render_names_each_job(self):
        pr = {"number": 21651, "head": {"sha": "43c75ca3529fe64132ceaf8309bb6af851153192", "ref": "fix/repause"}}
        result = {"file": "tests/vm-route-deadlines.test.ts", "own": OWN, "others": [MAIN, OTHER_PR],
                  "source": "logs", "verdict": verdict.decide(OWN, [MAIN, OTHER_PR], OUTSIDE, 7)}
        body = verdict.render(pr, [result], 7)
        self.assertTrue(body.startswith(verdict.MARKER))
        self.assertIn("**unrelated flake**", body)
        self.assertIn("[job](https://github.com/x/job/117692683085)", body)
        self.assertIn("#21600", body)


if __name__ == "__main__":
    unittest.main()
