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
    """answers: list of (code, body), the last repeated."""
    clock = Clock()
    urls = []

    def fetch(url, timeout):
        urls.append(url)
        clock.t += per_read
        return answers[min(len(urls) - 1, len(answers) - 1)]

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

    def test_a_record_for_another_head_or_recipe_is_never_a_verdict(self):
        for bad in (rec("pass", sha="b" * 40), rec("pass", repo="x/y"), rec("pass", recipe_version=1),
                    rec("pass", configuration="debug"), rec("unavailable"), "junk"):
            self.assertEqual(run([(200, bad)])[0], "none", bad)


if __name__ == "__main__":
    unittest.main()
