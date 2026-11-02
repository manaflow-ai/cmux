#!/usr/bin/env python3
"""video_golden.routing_verdict judges only the attempts of its own case (review at 77ee5e82e93). No fleet, no app.

    python3 scripts/journeys/test_video_golden.py
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / "routing")]
import tally  # noqa: E402
import video_golden  # noqa: E402


class RoutingVerdictPerCase(unittest.TestCase):
    def setUp(self):
        self.saved = tally.attempts
        tally.attempts = lambda run: [
            {"case": "routing-cmdn-ctrlbt-at-once", "attempt": "B1", "verdict": "right"},
            {"case": "routing-cmdn-ctrlbt-at-once", "attempt": "B2", "verdict": "right"},
            {"case": "routing-smoke-seq", "attempt": "H1", "verdict": "wrong"},
        ]

    def tearDown(self):
        tally.attempts = self.saved

    def test_another_case_wrong_does_not_fail_this_case(self):
        ok, detail = video_golden.routing_verdict("/nowhere", "routing-cmdn-ctrlbt-at-once")
        self.assertTrue(ok, detail)
        self.assertEqual(detail["attempts"], 2)

    def test_its_own_wrong_fails_and_no_attempts_is_no_pass(self):
        self.assertFalse(video_golden.routing_verdict("/nowhere", "routing-smoke-seq")[0])
        ok, detail = video_golden.routing_verdict("/nowhere", "routing-split")
        self.assertFalse(ok)
        self.assertEqual(detail["attempts"], 0)


if __name__ == "__main__":
    unittest.main()
