#!/usr/bin/env python3
"""Keep automatic Apple notarization recovery bounded and long enough."""

from __future__ import annotations

import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"
OUTER_POLLER = ROOT / "scripts/ci/poll-outer-notarizations.sh"


class NightlyNotarizationBudgetTests(unittest.TestCase):
    @staticmethod
    def _job_body(workflow: str, job: str, next_job: str) -> str:
        match = re.search(
            rf"^  {re.escape(job)}:\n(?P<body>.*?)(?=^  {re.escape(next_job)}:)",
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"{job} job is missing")
        return match.group("body")

    def test_apple_poll_has_four_hour_budget_and_explicit_reserves(self) -> None:
        body = self._job_body(
            WORKFLOW.read_text(encoding="utf-8"), "poll", "wait-and-staple"
        )
        timeout = re.search(r"^    timeout-minutes: (\d+)$", body, re.MULTILINE)
        reserves = re.search(
            r"poll_budget_minutes=(\d+)\n"
            r"\s+setup_reserve_minutes=(\d+)\n"
            r"\s+final_cycle_reserve_minutes=(\d+)\n"
            r"\s+evidence_reserve_minutes=(\d+)\n"
            r"\s+poll_interval_minutes=(\d+)",
            body,
        )
        self.assertIsNotNone(timeout, "poll timeout is missing")
        self.assertIsNotNone(reserves, "poll timing reserves are missing")
        assert timeout is not None
        assert reserves is not None

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
        self.assertIn(
            "deadline=$(( $(date +%s) + poll_budget_minutes * 60 ))", body
        )
        self.assertIn("deadline - final_cycle_reserve_minutes * 60", body)
        self.assertIn(
            "now + poll_interval_minutes * 60 + final_cycle_reserve_minutes * 60",
            body,
        )
        self.assertIn("sleep $((poll_interval_minutes * 60))", body)

    def test_outer_poll_uses_bounded_six_hour_fallback_budget(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        body = self._job_body(workflow, "poll-outer", "staple-outer")
        timeout = re.search(r"^    timeout-minutes: (\d+)$", body, re.MULTILINE)
        self.assertIsNotNone(timeout, "poll-outer timeout is missing")
        assert timeout is not None
        self.assertEqual(int(timeout.group(1)), 360)
        self.assertIn(
            'run: ./scripts/ci/poll-outer-notarizations.sh outer "$RUNNER_TEMP/outer-variants" poll-reports',
            body,
        )

        poller = OUTER_POLLER.read_text(encoding="utf-8")
        defaults = {
            "FALLBACK_SECONDS": 21600,
            "OUTER_POLL_SECONDS": 4800,
            "BUDGET_SECONDS": 21420,
            "INTERVAL_SECONDS": 300,
            "SLACK_SECONDS": 300,
        }
        for name, value in defaults.items():
            self.assertRegex(
                poller,
                rf'{name}="\$\{{CMUX_[A-Z_]+:-{value}\}}"',
                f"{name} default is missing",
            )
        self.assertIn("wake=$((current + INTERVAL_SECONDS))", poller)
        self.assertIn(
            "[ \"$wake\" -le $((start + BUDGET_SECONDS)) ] || wake=$((start + BUDGET_SECONDS))",
            poller,
        )
        self.assertIn("sleep $((wake - current))", poller)


if __name__ == "__main__":
    unittest.main()
