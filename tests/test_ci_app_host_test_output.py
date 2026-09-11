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
    def test_all_expected_failures_are_tolerated(self) -> None:
        passed, message = MODULE.classify(
            "Executed 4 tests, with 1 failure (0 unexpected)\n"
            "Executed 8 tests, with 2 failures (0 unexpected)\n"
        )

        self.assertTrue(passed)
        self.assertIn("2 XCTest summary", message)

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
