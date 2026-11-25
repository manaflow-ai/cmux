#!/usr/bin/env python3
"""A nightly-tip tour's base is the last tip a tour finished on.

Push runs of cmux-next media share one group, so dropped and deferred tips
never tour on their own: the next tour must start from the last toured tip,
or their changes would go untoured (scripts/ci/media_last_toured.py).
"""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci"))
import media_last_toured as m  # noqa: E402

A, B, C, D = ("a" * 40, "b" * 40, "c" * 40, "d" * 40)


def run(rid, sha, conclusion="success", status="completed"):
    return {"id": rid, "head_sha": sha, "conclusion": conclusion, "status": status}


def tour(conclusion, at="2026-11-25T01:00:00Z"):
    return [{"name": "Pick the tour runner", "conclusion": "success"},
            {"name": m.TOUR_JOB, "conclusion": conclusion, "completed_at": at}]


class ChooseTests(unittest.TestCase):
    def pick(self, runs, jobs, run_id=100, ancestors=None):
        ancestors = ancestors if ancestors is not None else {A, B, C, D}
        return m.choose(runs, run_id, lambda rid: jobs.get(rid, []), lambda sha: sha in ancestors)

    def test_skips_runs_that_took_no_mac_or_were_cancelled(self):
        runs = [run(99, D), run(98, C, "cancelled"), run(97, B), run(96, A)]
        jobs = {99: tour("skipped"), 97: tour("success"), 96: tour("success")}
        self.assertEqual(self.pick(runs, jobs)[0], B)

    def test_failed_publish_after_a_finished_tour_counts(self):
        runs = [run(99, B, "failure"), run(98, A)]
        self.assertEqual(self.pick(runs, {99: tour("success"), 98: tour("success")})[0], B)

    def test_failed_tour_does_not_count(self):
        runs = [run(99, B, "failure"), run(98, A)]
        self.assertEqual(self.pick(runs, {99: tour("failure"), 98: tour("success")})[0], A)

    def test_ignores_newer_and_running_runs(self):
        runs = [run(101, D), run(99, C, None, "in_progress"), run(98, B)]
        jobs = {101: tour("success"), 98: tour("success")}
        self.assertEqual(self.pick(runs, jobs)[0], B)

    def test_rewound_tip_is_skipped(self):
        runs = [run(99, B), run(98, A)]
        jobs = {99: tour("success"), 98: tour("success")}
        self.assertEqual(self.pick(runs, jobs, ancestors={A})[0], A)

    def test_none_found(self):
        self.assertIsNone(self.pick([run(99, B)], {99: tour("skipped")}))

    def test_lookups_are_bounded(self):
        runs = [run(90 - i, B) for i in range(30)]
        seen = []
        m.choose(runs, 100, lambda rid: seen.append(rid) or tour("skipped"), lambda s: True, max_lookups=5)
        self.assertEqual(len(seen), 5)


if __name__ == "__main__":
    unittest.main()
