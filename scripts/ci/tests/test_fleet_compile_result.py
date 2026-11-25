#!/usr/bin/env python3
"""python3 -m unittest discover -s scripts/ci/tests -p test_fleet_compile_result.py"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fleet_compile_result as f  # noqa: E402

SHA = "a" * 40
REPO = "manaflow-ai/cmux"


def rec(state, **kw):
    r = {"sha": SHA, "repo": REPO, "recipe_version": 2, "configuration": "release-onone", "state": state}
    r.update(kw)
    return r


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def run(answers, wait=1500, no_record=600, per_read=5):
    """answers: list of (code, body) or (code, body, seconds the read takes), the last repeated."""
    clock = Clock()
    urls = []

    def fetch(url, timeout):
        urls.append(url)
        answer = answers[min(len(urls) - 1, len(answers) - 1)]
        clock.t += answer[2] if len(answer) > 2 else per_read
        return answer[0], answer[1]

    word, why = f.read(SHA, REPO, "12", wait, no_record, fetch=fetch, now=clock.now, sleep=clock.sleep)
    return word, why, urls, clock.t


class ReadTest(unittest.TestCase):
    def test_pass_and_fail_are_verdicts(self):
        self.assertEqual(run([(200, rec("pass"))])[0], "pass")
        self.assertEqual(run([(200, rec("fail"))])[0], "fail")

    def test_running_then_pass_waits_for_it(self):
        word, _, urls, _ = run([(404, None), (200, rec("running")), (200, rec("pass"))])
        self.assertEqual(word, "pass")
        self.assertEqual(len(urls), 3)
        self.assertIn("pr=12", urls[0])

    def test_each_hold_stays_under_the_gateway_limit(self):
        _, _, urls, _ = run([(404, None), (200, rec("running")), (200, rec("pass"))], wait=1500)
        holds = [int(u.rsplit("wait=", 1)[1]) for u in urls]
        self.assertTrue(holds and max(holds) <= 90, holds)

    def test_no_record_hands_back_to_the_compile(self):
        word, why, _, t = run([(404, None)], no_record=600)
        self.assertEqual(word, "none")
        self.assertIn("no record", why)
        self.assertLess(t, 700)

    def test_a_running_record_is_waited_for_past_the_no_record_bound(self):
        word, why, _, t = run([(200, rec("running"))], wait=1500, no_record=60)
        self.assertEqual(word, "none")
        self.assertIn("no verdict in 1500", why)
        self.assertGreaterEqual(t, 1490)

    def test_service_down_two_minutes_hands_back(self):
        word, why, _, t = run([(530, None)])
        self.assertEqual(word, "none")
        self.assertIn("down", why)
        self.assertLess(t, 200)

    def test_a_controller_that_does_not_answer_is_down_within_one_cdn_timeout(self):
        # 2026-11-23 10:34Z, job 137633284444: every read ended in the CDN's 524 at about 100 s; the old bound,
        # counted from the end of the first failed read, said "none" after 383 s, and the compile then waited
        # 5 min more on the same controller.
        word, why, urls, t = run([(524, None, 100)])
        self.assertEqual(word, "down")
        self.assertIn("524", why)
        self.assertEqual(len(urls), 1)
        self.assertLessEqual(t, 100)

    def test_a_read_that_times_out_is_down_too(self):
        word, why, _, t = run([(f.NO_ANSWER, None, 75)])
        self.assertEqual(word, "down")
        self.assertLessEqual(t, 75 + 30 + 75)

    def test_a_service_that_cannot_be_reached_compiles_as_before(self):
        # The tunnel down (530) or no connection says nothing of the controller's own address.
        for code in (530, 502, 0):
            word, why, _, t = run([(code, None, 1)])
            self.assertEqual(word, "none", code)
            self.assertIn("results service down", why)
            self.assertLess(t, 100)

    def test_down_only_when_every_failed_read_went_unanswered(self):
        self.assertEqual(run([(530, None, 1), (524, None, 100)])[0], "none")

    def test_one_524_then_an_answer_is_a_blip(self):
        word, _, _, _ = run([(524, None, 40), (200, rec("pass"), 1)])
        self.assertEqual(word, "pass")

    def test_too_many_waiters_is_an_answer_not_an_outage(self):
        word, _, urls, _ = run([(429, None, 1), (429, None, 1), (429, None, 1), (200, rec("pass"), 1)])
        self.assertEqual(word, "pass")
        self.assertEqual(len(urls), 4)

    def test_a_held_read_stays_inside_the_cdn_bound(self):
        # The CDN ends a request with no answer at 100 s; the service holds a pending read for its wait.
        _, _, urls, _ = run([(200, rec("running"))], wait=900, no_record=300)
        holds = {int(u.rsplit("wait=", 1)[1]) for u in urls}
        self.assertLessEqual(max(holds), 60)

    def test_a_record_for_another_head_or_recipe_is_never_a_verdict(self):
        for bad in (rec("pass", sha="b" * 40), rec("pass", repo="x/y"), rec("pass", recipe_version=1),
                    rec("pass", configuration="debug"), rec("unavailable"), "junk"):
            self.assertEqual(run([(200, bad)])[0], "none", bad)


    def test_a_superseded_push_tip_is_its_own_word_at_once(self):
        # The controller checks the newest feat-cmux-next push tip instead (2026-11-22 05-09Z: 97 push-tip
        # checks for 120 pushes, each queued by its own push run's read).
        word, why, urls, t = run([(200, rec("superseded", superseded_by="b" * 40))])
        self.assertEqual(word, "superseded")
        self.assertIn("b" * 40, why)
        self.assertEqual(len(urls), 1)

    def test_the_app_debug_phase_reads_only_the_debug_record(self):
        def phase_run(body):
            clock, urls = Clock(), []

            def fetch(url, timeout):
                urls.append(url)
                clock.t += 5
                return 200, body

            word, _ = f.read(SHA, REPO, "12", 600, 300, fetch=fetch, now=clock.now, sleep=clock.sleep,
                             phase="app-debug")
            return word, urls

        word, urls = phase_run(rec("pass", configuration="debug"))
        self.assertEqual(word, "pass")
        self.assertIn("phase=app-debug", urls[0])
        self.assertIn("pr=12", urls[0])
        self.assertEqual(phase_run(rec("fail", configuration="debug"))[0], "fail")
        # The land Release's record never answers the Debug phase, nor the other way round.
        self.assertEqual(phase_run(rec("pass"))[0], "none")
        self.assertNotIn("phase=", run([(200, rec("pass"))])[2][0])
        self.assertEqual(f.main(["--sha", SHA, "--repo", REPO, "--phase", "app-debug", "--wait", "0"]), 0)
        with self.assertRaises(SystemExit):
            f.main(["--sha", SHA, "--repo", REPO, "--phase", "release"])

    def test_the_workflow_skips_only_a_push_whose_head_moved(self):
        w = (Path(__file__).resolve().parents[3] / ".github/workflows/cmux-next.yml").read_text()
        i = w.index('if [[ "$word" == superseded && -z "${PR:-}" ]]; then')
        block = w[i:w.index("status=0", i)]
        self.assertIn('"$head" != "$REF"', block)
        self.assertIn("verdict=superseded", block)
        self.assertIn("word=none", block)  # a head that did not move, or no answer, compiles as before

class WorkflowCallsIt(unittest.TestCase):
    def test_every_stub_call_runs_without_gnu_timeout(self):
        # Mac runners have no GNU timeout: "timeout: command not found" made every stub word "none", so each
        # head compiled twice (2026-11-21 from 18Z). The script bounds its own wait (--wait) and the job has
        # timeout-minutes.
        wf = Path(__file__).resolve().parents[3] / ".github/workflows/cmux-next.yml"
        calls = [l for l in wf.read_text().splitlines() if "python3 scripts/ci/fleet_compile_result.py" in l]
        self.assertTrue(calls)
        for line in calls:
            self.assertNotRegex(line, r"\btimeout\s+\d", line.strip())


if __name__ == "__main__":
    unittest.main()
