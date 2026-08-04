#!/usr/bin/env python3
"""Behavioral fixtures for the unit-shard log summary boundary."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SUMMARIZER = REPO_ROOT / "scripts" / "ci" / "unit_test_log_summary.py"


class UnitTestLogSummaryTests(unittest.TestCase):
    def summarize(self, log: str, lost_limit: int = 20) -> tuple[dict[str, int], list[str]]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            log_path = temporary / "xcodebuild.log"
            env_path = temporary / "summary.env"
            lost_path = temporary / "lost.txt"
            log_path.write_text(log, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    str(log_path),
                    "--env-output",
                    str(env_path),
                    "--lost-output",
                    str(lost_path),
                    "--lost-limit",
                    str(lost_limit),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            fields = {
                key: int(value)
                for key, value in (
                    line.split("=", 1)
                    for line in env_path.read_text(encoding="utf-8").splitlines()
                )
            }
            lost = lost_path.read_text(encoding="utf-8").splitlines()
        return fields, lost

    def test_swift_testing_zero_test_summary_is_zero(self) -> None:
        fields, _ = self.summarize(
            "✔ Test run with 0 tests in 1 suite passed after 0.001 seconds."
        )
        self.assertEqual(fields["TESTS_SEEN"], 0)

    def test_swift_testing_positive_summary_reports_its_count(self) -> None:
        fields, _ = self.summarize(
            "✔ Test run with 18 tests in 1 suite passed after 0.012 seconds."
        )
        self.assertEqual(fields["TESTS_SEEN"], 18)

    def test_xctest_uses_largest_nested_summary(self) -> None:
        fields, _ = self.summarize(
            "\n".join(
                (
                    "Executed 1 test, with 0 failures (0 unexpected)",
                    "Executed 17 tests, with 0 failures (0 unexpected)",
                )
            )
        )
        self.assertEqual(fields["TESTS_SEEN"], 17)

    def test_missing_summary_is_zero(self) -> None:
        fields, _ = self.summarize("** TEST SUCCEEDED **")
        self.assertEqual(fields["TESTS_SEEN"], 0)

    def test_reports_only_swift_test_without_verdict(self) -> None:
        _, lost = self.summarize(
            "\n".join(
                (
                    "◇ Test completedSwiftTest() started.",
                    "✔ Test completedSwiftTest() passed after 0.001 seconds.",
                    "◇ Test lostSwiftTest() started.",
                )
            )
        )
        self.assertEqual(lost, ["lostSwiftTest()"])

    def test_reports_only_xctest_without_verdict(self) -> None:
        _, lost = self.summarize(
            "\n".join(
                (
                    "Test Case '-[ExampleTests testCompleted]' started.",
                    "Test Case '-[ExampleTests testCompleted]' passed (0.001 seconds).",
                    "Test Case '-[ExampleTests testLost]' started.",
                )
            )
        )
        self.assertEqual(lost, ["ExampleTests testLost"])

    def test_one_verdict_removes_only_latest_repeated_start(self) -> None:
        _, lost = self.summarize(
            "\n".join(
                (
                    "◇ Test repeatedTest() started.",
                    "◇ Test repeatedTest() started.",
                    "✔ Test repeatedTest() passed after 0.001 seconds.",
                )
            )
        )
        self.assertEqual(lost, ["repeatedTest()"])

    def test_lost_limit_preserves_first_pending_log_order(self) -> None:
        _, lost = self.summarize(
            "\n".join(
                (
                    "◇ Test firstTest() started.",
                    "Test Case '-[ExampleTests testSecond]' started.",
                    "◇ Test thirdTest() started.",
                )
            ),
            lost_limit=2,
        )
        self.assertEqual(lost, ["firstTest()", "ExampleTests testSecond"])

    def test_counts_host_restarts_and_detects_package_resolution_failure(self) -> None:
        fields, _ = self.summarize(
            "\n".join(
                (
                    "Could not resolve package dependencies",
                    "Restarting after unexpected exit, crash, or test timeout",
                    "Restarting after unexpected exit, crash, or test timeout",
                )
            )
        )
        self.assertEqual(fields["PACKAGE_RESOLUTION_FAILED"], 1)
        self.assertEqual(fields["HOST_DEATHS"], 2)

    def test_last_xctest_failure_summary_controls_expected_failure_status(self) -> None:
        fields, _ = self.summarize(
            "\n".join(
                (
                    "Executed 3 tests, with 2 failures (0 unexpected)",
                    "Executed 1 test, with 1 failure (1 unexpected)",
                )
            )
        )
        self.assertEqual(fields["EXPECTED_FAILURES_ONLY"], 0)

        fields, _ = self.summarize(
            "Executed 3 tests, with 2 failures (0 unexpected)"
        )
        self.assertEqual(fields["EXPECTED_FAILURES_ONLY"], 1)


if __name__ == "__main__":
    unittest.main()
