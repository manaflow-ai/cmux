#!/usr/bin/env python3
"""Keep automatic Apple notarization recovery alive through slow queues."""

from __future__ import annotations

import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"


class NightlyNotarizationBudgetTests(unittest.TestCase):
    def test_recovery_polls_cover_four_hour_apple_queues_with_upload_headroom(self) -> None:
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
                    r"deadline=\$\(\( \$\(date \+%s\) \+ (\d+) \* 60 \)\)",
                    body,
                )
                self.assertIsNotNone(timeout, f"{job} timeout is missing")
                self.assertIsNotNone(deadline, f"{job} deadline is missing")
                timeout_minutes = int(timeout.group(1))
                poll_minutes = int(deadline.group(1))

                self.assertEqual(poll_minutes, 240)
                self.assertEqual(timeout_minutes, 270)
                self.assertGreaterEqual(timeout_minutes, poll_minutes + 30)


if __name__ == "__main__":
    unittest.main()
