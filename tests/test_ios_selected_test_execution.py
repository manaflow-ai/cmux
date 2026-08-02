#!/usr/bin/env python3

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GUARD = REPO_ROOT / "scripts" / "ci" / "require_selected_test_execution.sh"


class SelectedIOSTestExecutionGuardTests(unittest.TestCase):
    def run_guard(self, log: str, test_filter: str) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as log_file:
            log_file.write(log)
            log_file.flush()
            return subprocess.run(
                ["bash", str(GUARD), log_file.name, test_filter],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_accepts_xctest_singular_and_plural_nonzero_counts(self) -> None:
        for summary in (
            "Executed 1 test, with 0 failures (0 unexpected)",
            "Executed 17 tests, with 0 failures (0 unexpected)",
        ):
            with self.subTest(summary=summary):
                result = self.run_guard(summary, "cmuxUITests/cmuxUITests/testExample")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_swift_testing_nonzero_count(self) -> None:
        result = self.run_guard(
            "Test run with 2 tests passed after 0.012 seconds.",
            "cmuxFeatureTests/ExampleSuite",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_zero_tests_for_requested_filter(self) -> None:
        test_filter = "cmuxUITests/testMissingMethod"
        result = self.run_guard(
            "Executed 0 tests, with 0 failures (0 unexpected)",
            test_filter,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(test_filter, result.stderr)
        self.assertIn("zero tests", result.stderr)

    def test_rejects_missing_execution_summary_for_requested_filter(self) -> None:
        result = self.run_guard("** TEST SUCCEEDED **", "cmuxUITests/testMissingMethod")
        self.assertNotEqual(result.returncode, 0)

    def test_allows_empty_filter_without_an_execution_summary(self) -> None:
        result = self.run_guard("** TEST SUCCEEDED **", "")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
