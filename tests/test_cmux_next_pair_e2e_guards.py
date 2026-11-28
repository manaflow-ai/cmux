#!/usr/bin/env python3
"""Exercise pair-e2e attachment selection without launching the expensive payload leg."""

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PAIR_E2E = ROOT / "scripts/ci/cmux_next_pair_e2e.py"
SPEC = importlib.util.spec_from_file_location("cmux_next_pair_e2e", PAIR_E2E)
PAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAIR)


class PairE2EGuardTests(unittest.TestCase):
    def test_connect_timeline_skips_attachment_and_normal_run_records_failure(self):
        calls = []

        def attach_leg():
            calls.append("attachment")
            return False

        self.assertTrue(
            PAIR.run_attachment_leg(True, True, True, attach_leg),
            "connect-timeline-only run must not invoke attachment",
        )
        self.assertEqual(calls, [])
        self.assertFalse(
            PAIR.run_attachment_leg(True, True, False, attach_leg),
            "ordinary run must fail when attachment leg fails",
        )
        self.assertEqual(calls, ["attachment"])
        self.assertTrue(
            PAIR.run_attachment_leg(True, False, False, attach_leg),
            "runs without attachment capability must keep the leg neutral",
        )
        self.assertEqual(calls, ["attachment"])
        self.assertTrue(PAIR.run_attachment_leg(False, True, False, attach_leg))
        self.assertEqual(calls, ["attachment"])
        self.assertTrue(PAIR.run_attachment_leg(True, True, False, lambda: True))


if __name__ == "__main__":
    unittest.main()
