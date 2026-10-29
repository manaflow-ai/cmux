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
    def test_unreachable_and_failing_on_other_prs_is_an_unrelated_flake(self):
        self.assertEqual(verdict.decide(OWN, [OTHER_PR], OUTSIDE, 7)["verdict"], "unrelated flake")

    def test_unreachable_but_red_on_main_points_at_main(self):
        result = verdict.decide(OWN, [MAIN, OTHER_PR], OUTSIDE, 7)
        self.assertEqual(result["verdict"], "also red on main")
        self.assertEqual(result["line"], "also red on main: 2 other failures in 7 days (1 on main, 1 other PR branch); "
                                         "no changed file is in vm-route-deadlines.test.ts's import graph; "
                                         "1 of 1 failure(s) here passed on a re-run of the same SHA")

    def test_unreachable_with_no_other_sighting_is_only_probably_unrelated(self):
        self.assertEqual(verdict.decide(OWN, [], OUTSIDE, 7)["verdict"], "probably unrelated")

    def test_reachable_code_is_likely_the_prs(self):
        self.assertEqual(verdict.decide(OWN, [], INSIDE, 7)["verdict"], "likely this PR's")
        self.assertEqual(verdict.decide(OWN, [MAIN], INSIDE, 7)["verdict"], "touched, also flaky")

    def test_a_refused_graph_still_reports_the_history(self):
        refused = {"touches": None, "summary": "can't analyse safely: lib/a.ts has an import attribute clause"}
        result = verdict.decide(OWN, [MAIN], refused, 7)
        self.assertEqual(result["verdict"], "can't analyse safely")
        self.assertIn("1 other failure in 7 days (1 on main", result["line"])

    def test_own_failures_are_the_prs_branch(self):
        own, others = verdict.own_and_others({"failures": [*OWN, MAIN, OTHER_PR]}, "fix/repause")
        self.assertEqual((len(own), len(others)), (1, 2))

    def test_a_forks_branch_of_the_same_name_is_someone_elses(self):
        fork = {**OWN[0], "head_repository_id": 77}
        mine = {**OWN[0], "head_repository_id": 1}
        own, others = verdict.own_and_others({"failures": [fork, mine]}, "fix/repause", head_repo_id=1)
        self.assertEqual((own, others), ([mine], [fork]))

    def test_coverage_is_refused_for_a_fork(self):
        ours = {"number": 1, "head": {"repo": {"full_name": "manaflow-ai/cmux"}}}
        verdict.refuse_fork_coverage(ours, "manaflow-ai/cmux")
        for head in ({"repo": {"full_name": "someone/cmux"}}, {"repo": None}):
            with self.assertRaises(SystemExit) as raised:
                verdict.refuse_fork_coverage({"number": 2, "head": head}, "manaflow-ai/cmux")
            self.assertIn("--coverage would run its code", str(raised.exception))
        with self.assertRaises(SystemExit) as raised:
            verdict.refuse_fork_coverage({"number": 2, "head": {"repo": None}}, "manaflow-ai/cmux", "--allow-unsandboxed")
        self.assertIn("--allow-unsandboxed would run its code", str(raised.exception))

    def test_log_text_cannot_format_or_mention_in_the_comment(self):
        self.assertEqual(verdict.safe("a `b`\n@team [x](y)"), "`a 'b' @\u200bteam [x](y)`")

    def test_unreadable_runs_are_named_in_the_verdict(self):
        result = verdict.decide(OWN, [OTHER_PR], OUTSIDE, 7, unreadable=3)
        self.assertEqual(result["verdict"], "unrelated flake")
        self.assertIn("3 CI run(s) unreadable, so the history may be incomplete", result["line"])

    def test_posting_again_edits_the_verdict_comment(self):
        class Recorder:
            def __init__(self, comments):
                self.existing, self.sent = comments, []

            def comments(self, number):
                return self.existing

            def request(self, method, path, body=None, text=False):
                self.sent.append((method, path))
                return {}

        first = Recorder([{"id": 5, "body": "unrelated"}])
        verdict.post(first, "manaflow-ai/cmux", 21651, f"{verdict.MARKER}\nnew")
        self.assertEqual(first.sent, [("POST", "repos/manaflow-ai/cmux/issues/21651/comments")])
        again = Recorder([{"id": 5, "body": "unrelated"}, {"id": 9, "body": f"{verdict.MARKER}\nold"}])
        verdict.post(again, "manaflow-ai/cmux", 21651, f"{verdict.MARKER}\nnew")
        self.assertEqual(again.sent, [("PATCH", "repos/manaflow-ai/cmux/issues/comments/9")])

    def test_render_names_each_job(self):
        pr = {"number": 21651, "head": {"sha": "43c75ca3529fe64132ceaf8309bb6af851153192", "ref": "fix/repause"}}
        result = {"file": "tests/vm-route-deadlines.test.ts", "own": OWN, "others": [MAIN, OTHER_PR],
                  "source": "logs", "verdict": verdict.decide(OWN, [MAIN, OTHER_PR], OUTSIDE, 7)}
        body = verdict.render(pr, [result], 7)
        self.assertTrue(body.startswith(verdict.MARKER))
        self.assertIn("**also red on main**", body)
        self.assertIn("[job](https://github.com/x/job/117692683085)", body)
        self.assertIn("#21600", body)


if __name__ == "__main__":
    unittest.main()
