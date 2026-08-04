#!/usr/bin/env python3
"""Behavioral fixtures for the unit-shard executed-test counter."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COUNTER = REPO_ROOT / "scripts" / "ci" / "executed_test_count.py"


class ExecutedTestCountTests(unittest.TestCase):
    def count(self, log: str) -> int:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as log_file:
            log_file.write(log)
            log_file.flush()
            result = subprocess.run(
                [sys.executable, str(COUNTER), log_file.name],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return int(result.stdout.strip())

    def test_swift_testing_zero_test_summary_is_zero(self) -> None:
        self.assertEqual(
            self.count("✔ Test run with 0 tests in 1 suite passed after 0.001 seconds."),
            0,
        )

    def test_swift_testing_positive_summary_reports_its_count(self) -> None:
        self.assertEqual(
            self.count("✔ Test run with 18 tests in 1 suite passed after 0.012 seconds."),
            18,
        )

    def test_xctest_singular_and_plural_summaries_are_recognized(self) -> None:
        self.assertEqual(
            self.count(
                "\n".join(
                    (
                        "Executed 1 test, with 0 failures (0 unexpected)",
                        "Executed 17 tests, with 0 failures (0 unexpected)",
                    )
                )
            ),
            17,
        )

    def test_nested_zero_summary_does_not_override_executed_tests(self) -> None:
        self.assertEqual(
            self.count(
                "\n".join(
                    (
                        "✔ Test run with 0 tests in 1 suite passed after 0.001 seconds.",
                        "Executed 4 tests, with 0 failures (0 unexpected)",
                    )
                )
            ),
            4,
        )

    def test_missing_summary_is_zero(self) -> None:
        self.assertEqual(self.count("** TEST SUCCEEDED **"), 0)


if __name__ == "__main__":
    unittest.main()
