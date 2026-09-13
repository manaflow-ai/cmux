#!/usr/bin/env python3

import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/classify-app-host-test-output.py"
SPEC = importlib.util.spec_from_file_location("classify_app_host_test_output", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class AppHostTestOutputTests(unittest.TestCase):
    def test_ordinary_assertion_failures_are_not_tolerated(self) -> None:
        passed, message = MODULE.classify(
            "Executed 4 tests, with 1 failure (0 unexpected)\n"
            "Executed 8 tests, with 2 failures (0 unexpected)\n"
        )

        self.assertFalse(passed)
        self.assertIn("XCTest failure", message)

    def test_earlier_assertion_failure_is_not_hidden_by_a_later_clean_summary(self) -> None:
        passed, _ = MODULE.classify(
            "Executed 4 tests, with 1 failure (0 unexpected)\n"
            "Executed 8 tests, with 0 failures (0 unexpected)\n"
        )

        self.assertFalse(passed)

    def test_swift_testing_failure_is_not_hidden_by_zero_xctest_failures(self) -> None:
        passed, message = MODULE.classify(
            "Executed 0 tests, with 0 failures (0 unexpected)\n"
            "◇ Test run started.\n"
            "✘ Test run with 5 tests in 1 suite failed after 0.2 seconds with 2 issues.\n"
        )

        self.assertFalse(passed)
        self.assertIn("Swift Testing", message)

    def test_passing_swift_testing_run_is_supported(self) -> None:
        passed, _ = MODULE.classify(
            "Executed 0 tests, with 0 failures (0 unexpected)\n"
            "◇ Test run started.\n"
            "✔ Test run with 5 tests in 1 suite passed after 0.2 seconds.\n"
        )

        self.assertTrue(passed)

    def test_an_unfinished_swift_testing_run_is_not_tolerated(self) -> None:
        passed, _ = MODULE.classify(
            "Executed 8 tests, with 0 failures (0 unexpected)\n"
            "◇ Test run started.\n"
            "◇ Test waitingForCallback() started.\n"
        )

        self.assertFalse(passed)

    def test_zero_executed_tests_is_not_a_passing_run(self) -> None:
        passed, _ = MODULE.classify("Executed 0 tests, with 0 failures (0 unexpected)\n")

        self.assertFalse(passed)

    def test_unexpected_failure_in_earlier_summary_is_not_masked(self) -> None:
        passed, message = MODULE.classify(
            "Executed 4 tests, with 1 failure (1 unexpected)\n"
            "Executed 8 tests, with 2 failures (0 unexpected)\n"
        )

        self.assertFalse(passed)
        self.assertIn("1 unexpected failure", message)

    def test_missing_summary_is_not_tolerated(self) -> None:
        passed, message = MODULE.classify("xcodebuild aborted before reporting results\n")

        self.assertFalse(passed)
        self.assertIn("no trustworthy XCTest summary", message)

    def test_singular_summary_is_supported(self) -> None:
        passed, _ = MODULE.classify("Executed 1 test, with 0 failures (0 unexpected)\n")

        self.assertTrue(passed)


if __name__ == "__main__":
    unittest.main()
