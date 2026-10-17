#!/usr/bin/env python3
"""Keep automatic Apple notarization recovery alive through slow queues."""

from __future__ import annotations

import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"


class NightlyNotarizationBudgetTests(unittest.TestCase):
    def test_recovery_polls_cover_four_hour_apple_queues_with_explicit_reserves(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        for job, next_job in (("poll", "wait-and-staple"), ("poll-outer", "staple-outer")):
            with self.subTest(job=job):
                match = re.search(
                    rf"^  {re.escape(job)}:\n(?P<body>.*?)(?=^  {re.escape(next_job)}:)",
                    workflow,
                    re.MULTILINE | re.DOTALL,
                )
                self.assertIsNotNone(match, f"{job} job is missing")
                body = match.group("body")

                timeout = re.search(r"^    timeout-minutes: (\d+)$", body, re.MULTILINE)
                deadline = re.search(
                    r"deadline=\$\(\( \$\(date \+%s\) \+ poll_budget_minutes \* 60 \)\)",
                    body,
                )
                reserves = re.search(
                    r"poll_budget_minutes=(\d+)\n"
                    r"\s+setup_reserve_minutes=(\d+)\n"
                    r"\s+final_cycle_reserve_minutes=(\d+)\n"
                    r"\s+evidence_reserve_minutes=(\d+)\n"
                    r"\s+poll_interval_minutes=(\d+)",
                    body,
                )
                self.assertIsNotNone(timeout, f"{job} timeout is missing")
                self.assertIsNotNone(deadline, f"{job} deadline is missing")
                self.assertIsNotNone(reserves, f"{job} explicit timing reserves are missing")
                timeout_minutes = int(timeout.group(1))
                configured_poll_minutes = int(reserves.group(1))
                setup_reserve_minutes = int(reserves.group(2))
                final_cycle_reserve_minutes = int(reserves.group(3))
                evidence_reserve_minutes = int(reserves.group(4))
                poll_interval_minutes = int(reserves.group(5))

                self.assertEqual(configured_poll_minutes, 240)
                self.assertEqual(timeout_minutes, 300)
                self.assertGreaterEqual(
                    timeout_minutes,
                    configured_poll_minutes
                    + setup_reserve_minutes
                    + final_cycle_reserve_minutes
                    + evidence_reserve_minutes,
                )
                self.assertGreaterEqual(final_cycle_reserve_minutes, poll_interval_minutes)


if __name__ == "__main__":
    unittest.main()
