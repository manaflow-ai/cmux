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


if __name__ == "__main__":
    unittest.main()
