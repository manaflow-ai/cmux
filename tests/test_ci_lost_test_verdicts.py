#!/usr/bin/env python3
"""Behavioral fixtures for lost unit-test verdict diagnostics."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTIC = REPO_ROOT / "scripts" / "ci" / "lost_test_verdicts.py"


class LostTestVerdictsTests(unittest.TestCase):
    def missing(self, log: str, limit: int = 20) -> list[str]:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as log_file:
            log_file.write(log)
            log_file.flush()
            result = subprocess.run(
                [
                    sys.executable,
                    str(DIAGNOSTIC),
                    log_file.name,
                    "--limit",
                    str(limit),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_reports_only_swift_test_without_verdict(self) -> None:
        self.assertEqual(
            self.missing(
                "\n".join(
                    (
                        "◇ Test completedSwiftTest() started.",
                        "✔ Test completedSwiftTest() passed after 0.001 seconds.",
                        "◇ Test lostSwiftTest() started.",
                    )
                )
            ),
            ["lostSwiftTest()"],
        )

    def test_reports_only_xctest_without_verdict(self) -> None:
        self.assertEqual(
            self.missing(
                "\n".join(
                    (
                        "Test Case '-[ExampleTests testCompleted]' started.",
                        "Test Case '-[ExampleTests testCompleted]' passed (0.001 seconds).",
                        "Test Case '-[ExampleTests testLost]' started.",
                    )
                )
            ),
            ["ExampleTests testLost"],
        )

    def test_restart_after_verdict_leaves_the_later_start_pending(self) -> None:
        self.assertEqual(
            self.missing(
                "\n".join(
                    (
                        "◇ Test retriedTest() started.",
                        "✘ Test retriedTest() failed after 0.001 seconds.",
                        "◇ Test retriedTest() started.",
                    )
                )
            ),
            ["retriedTest()"],
        )

    def test_limit_preserves_first_pending_log_order(self) -> None:
        self.assertEqual(
            self.missing(
                "\n".join(
                    (
                        "◇ Test firstTest() started.",
                        "Test Case '-[ExampleTests testSecond]' started.",
                        "◇ Test thirdTest() started.",
                    )
                ),
                limit=2,
            ),
            ["firstTest()", "ExampleTests testSecond"],
        )


if __name__ == "__main__":
    unittest.main()
