#!/usr/bin/env python3
"""cmux_tui_channel_heal.decide: a stalled acpmux channel gets one action a tick, never a stack.

2026-11-24/25: feat-cmux-next.json held a304d6a4 for 13 h because failed point runs waited for a person
(hq docs/handbook/channel-stops-following-its-branch.md). The healer reruns the newest failed run, or
dispatches one, only when the lag passes its bound and nothing is in flight.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "ci"))
import cmux_tui_channel_heal as heal  # noqa: E402

NOW = 1_800_000_000.0


def run(i, status="completed", conclusion="success", attempt=1, age_h=1.0):
    return heal.Run(i, status, conclusion, attempt, NOW - age_h * 3600)


class Decide(unittest.TestCase):
    def test_fresh_channel_does_nothing(self):
        self.assertEqual(heal.decide(10, [run(1, conclusion="failure")], NOW)[0], "fresh")

    def test_in_flight_run_waits(self):
        a, rid, _ = heal.decide(120, [run(2, status="in_progress", conclusion=None), run(1, conclusion="failure")], NOW)
        self.assertEqual((a, rid), ("waiting", 2))

    def test_newest_failed_run_is_rerun(self):
        a, rid, _ = heal.decide(120, [run(3, conclusion="failure"), run(2)], NOW)
        self.assertEqual((a, rid), ("rerun", 3))

    def test_compile_red_holds_instead_of_rerun_or_dispatch(self):
        # 11-27 14Z..11-28 11Z: this job's reruns of red builds were 2,942 re-run runner-min; a compile error fails
        # the same way on a rerun (same source) and on a dispatch (same tip), so the heal holds and the alarm speaks.
        a, rid, _ = heal.decide(120, [run(3, conclusion="failure"), run(2)], NOW, compile_red=lambda i: i == 3)
        self.assertEqual((a, rid), ("hold", 3))
        a, _, _ = heal.decide(120, [run(3, conclusion="failure", attempt=3)], NOW, compile_red=lambda i: True)
        self.assertEqual(a, "hold")

    def test_compile_red_is_read_only_for_a_failed_newest_run(self):
        seen = []
        a, _, _ = heal.decide(120, [run(4), run(3, conclusion="failure")], NOW,
                              compile_red=lambda i: seen.append(i) or True)
        self.assertEqual((a, seen), ("dispatch", []))

    def test_spent_attempts_dispatch_instead(self):
        self.assertEqual(heal.decide(120, [run(3, conclusion="failure", attempt=3)], NOW)[0], "dispatch")

    def test_old_failure_dispatches(self):
        self.assertEqual(heal.decide(120, [run(3, conclusion="failure", age_h=8)], NOW)[0], "dispatch")

    def test_newest_green_but_lagging_dispatches(self):
        # A green run whose point found nothing newer (or a skipped point): dispatch the tip.
        self.assertEqual(heal.decide(120, [run(4), run(3, conclusion="failure")], NOW)[0], "dispatch")

    def test_unknown_lag_acts(self):
        self.assertEqual(heal.decide(None, [], NOW)[0], "dispatch")

    def test_parse_runs_reads_utc(self):
        runs = heal.parse_runs({"workflow_runs": [{"id": 9, "status": "completed", "conclusion": "failure",
                                                   "run_attempt": 2, "created_at": "2027-01-15T08:00:00Z"}]})
        self.assertEqual((runs[0].id, runs[0].attempt, runs[0].created), (9, 2, 1800000000.0))


class Alarm(unittest.TestCase):
    """2026-11-25/26: every run failed the daemon tests for about 24 h and the healer stayed green."""

    def test_lag_past_the_bound_is_red_and_names_the_failed_run(self):
        line = heal.alarm(24 * 60, [run(7, conclusion="failure", attempt=3), run(6)], 180)
        self.assertIsNotNone(line)
        self.assertTrue(line.startswith("::error"))
        self.assertIn("run 7", line)

    def test_lag_under_the_bound_is_quiet(self):
        self.assertIsNone(heal.alarm(120, [run(7, conclusion="failure")], 180))

    def test_unknown_lag_or_alarm_off_is_quiet(self):
        self.assertIsNone(heal.alarm(None, [], 180))
        self.assertIsNone(heal.alarm(24 * 60, [], 0))


def built(i, conclusion="failure", attempt=1, minutes=14.0, status="completed", age_h=1.0):
    return heal.Run(i, status, conclusion, attempt, NOW - age_h * 3600, minutes)


class CloudMachine(unittest.TestCase):
    """2026-11-28: the acpmux rustc was OOM-killed on both legs of runs 46151055654 and 46154021183, and the Cloud
    machine channel held f3ac175f for about 3 h with nothing rerunning the failed build."""

    def test_fresh_channel_does_nothing(self):
        self.assertEqual(heal.cloud_candidate(10, [built(1)], NOW)[0], "fresh")

    def test_newest_built_failure_is_a_candidate_even_with_pushes_in_flight(self):
        runs = [built(5, status="in_progress", conclusion=None, minutes=1), built(4, "cancelled", minutes=0.2),
                built(3, "cancelled"), built(2, "success")]
        self.assertEqual(heal.cloud_candidate(40, runs, NOW)[:2], ("candidate", 3))

    def test_a_rerun_in_flight_waits(self):
        runs = [built(3, status="in_progress", conclusion=None, attempt=2), built(2)]
        self.assertEqual(heal.cloud_candidate(40, runs, NOW)[:2], ("waiting", 3))

    def test_a_rerun_once_is_enough(self):
        self.assertEqual(heal.cloud_candidate(40, [built(3, attempt=2)], NOW)[0], "none")

    def test_newest_built_green_does_nothing(self):
        self.assertEqual(heal.cloud_candidate(40, [built(3, "success"), built(2)], NOW)[0], "none")

    def test_old_runs_are_not_rerun(self):
        self.assertEqual(heal.cloud_candidate(400, [built(3, age_h=8)], NOW)[0], "none")

    def test_only_a_failed_build_job_is_rerun(self):
        jobs = {"jobs": [
            {"name": "build-machine-channel x86_64 lane 0 / build x86_64-unknown-linux-musl", "conclusion": "failure"},
            {"name": "build-machine-channel aarch64 lane 0 / build aarch64-unknown-linux-musl", "conclusion": "success"},
            {"name": "request the Cloud VM image roll for this machine build", "conclusion": "failure"}]}
        self.assertEqual(len(heal.build_failed(jobs)), 1)
        self.assertEqual(heal.build_failed({"jobs": [{"name": "twin-x86_64", "conclusion": "failure"}]}), [])

    def test_parse_runs_reads_the_attempt_length(self):
        runs = heal.parse_runs({"workflow_runs": [{"id": 9, "status": "completed", "conclusion": "cancelled",
                                                   "run_attempt": 1, "created_at": "2027-01-15T08:00:00Z",
                                                   "run_started_at": "2027-01-15T08:00:00Z",
                                                   "updated_at": "2027-01-15T08:15:00Z"}]})
        self.assertEqual(runs[0].minutes, 15.0)


class Gh(unittest.TestCase):
    def test_failed_call_names_what_gh_said(self):
        # 2026-11-25: two ticks died on a bare CalledProcessError; gh's stderr was captured and dropped.
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            fake = os.path.join(d, "gh")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\necho 'HTTP 403: API rate limit exceeded for installation' >&2\nexit 1\n")
            os.chmod(fake, 0o755)
            old_path, old_here = os.environ["PATH"], heal.HERE
            os.environ["PATH"] = d + os.pathsep + old_path
            os.environ["GH_BUDGET_WAIT_ATTEMPTS"] = "1"
            heal.HERE = d  # no wrapper there: plain gh
            try:
                with self.assertRaises(heal.GhError) as ctx:
                    heal.gh("GET", "repos/o/r/actions/runs")
            finally:
                os.environ["PATH"], heal.HERE = old_path, old_here
                os.environ.pop("GH_BUDGET_WAIT_ATTEMPTS", None)
        self.assertIn("rate limit exceeded", str(ctx.exception))
        self.assertIn("exited 1", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
