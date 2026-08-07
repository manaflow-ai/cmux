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
        test_filter = "cmuxUITests/testMissingMethod\n::error::injected"
        result = self.run_guard(
            "Executed 0 tests, with 0 failures (0 unexpected)",
            test_filter,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            result.stderr,
            "selected iOS test filter matched zero tests; "
            "use target/class or target/class/method syntax\n",
        )
        self.assertNotIn(test_filter, result.stderr)

    def test_rejects_missing_execution_summary_for_requested_filter(self) -> None:
        result = self.run_guard("** TEST SUCCEEDED **", "cmuxUITests/testMissingMethod")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            result.stderr,
            "selected iOS test execution summary was not found; "
            "verify the test log format\n",
        )

    def test_missing_log_does_not_echo_its_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_log = str(Path(temp_dir) / "missing.log")
            result = subprocess.run(
                ["bash", str(GUARD), missing_log, "cmuxUITests/testExample"],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            result.stderr,
            "selected iOS test execution log is unavailable\n",
        )
        self.assertNotIn(missing_log, result.stderr)

    def test_accepts_mixed_nested_summaries_when_tests_executed(self) -> None:
        result = self.run_guard(
            "\n".join(
                (
                    "Executed 0 tests, with 0 failures (0 unexpected)",
                    "Executed 1 test, with 0 failures (0 unexpected)",
                )
            ),
            "cmuxUITests/cmuxUITests/testExample",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_allows_empty_filter_without_an_execution_summary(self) -> None:
        result = self.run_guard("** TEST SUCCEEDED **", "")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
