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


class KitState(unittest.TestCase):
    """results.jsonl rows carry run.py's harness record, not kit/kit_dirty (a pass was never counted before)."""

    def test_the_harness_record_decides_and_no_record_is_never_clean(self):
        ks = video_golden.kit_state
        self.assertEqual(ks({"harness": {"commit": "c", "dirty": [], "pinned": True}}), ("c", False))
        self.assertEqual(ks({"harness": {"commit": "c", "dirty": [" M x"], "pinned": True}}), ("c", True))
        self.assertEqual(ks({"harness": {"commit": "c", "dirty": [], "pinned": False}}), ("c", True))
        self.assertEqual(ks({"harness": {"commit": None, "dirty": []}})[1], None)
        self.assertEqual(ks({}), (None, None))
        self.assertEqual(ks({"kit": "k", "kit_dirty": False}), ("k", False))


if __name__ == "__main__":
    unittest.main()
