#!/usr/bin/env python3
"""Unit tests for conservative fast-guard check selection."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import fast_guard_status  # noqa: E402


class FastGuardStatusTests(unittest.TestCase):
    def test_pending_current_check_does_not_use_old_success(self):
        checks = [
            {"name": "CI fast guards", "status": "completed", "conclusion": "success", "completed_at": "2026-09-30T17:00:00Z"},
            {"name": "CI fast guards", "status": "queued", "conclusion": None, "completed_at": None, "started_at": None},
        ]
        self.assertIsNone(fast_guard_status.completed_state(checks))

    def test_latest_completed_success_skips_duplicate(self):
        checks = [
            {"name": "CI fast guards", "status": "completed", "conclusion": "failure", "completed_at": "2026-09-30T17:00:00Z"},
            {"name": "CI fast guards", "status": "completed", "conclusion": "success", "completed_at": "2026-09-30T17:01:00Z"},
        ]
        self.assertEqual(fast_guard_status.completed_state(checks), "success")

    def test_nonmatching_checks_are_not_a_verdict(self):
        self.assertIsNone(fast_guard_status.completed_state([{"name": "CI", "status": "completed", "conclusion": "success"}]))


if __name__ == "__main__":
    unittest.main()
