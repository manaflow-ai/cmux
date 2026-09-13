#!/usr/bin/env python3

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
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

    def test_zero_summary_is_not_tolerated(self) -> None:
        passed, message = MODULE.classify(
            "Executed 0 tests, with 0 failures (0 unexpected)\n"
        )

        self.assertFalse(passed)
        self.assertIn("zero executed tests", message)

    def test_diagnoses_compile_failure_before_tests(self) -> None:
        diagnosis = MODULE.diagnose(
            "Sources/AppDelegate.swift:8:3: error: cannot find type 'Missing' in scope\n"
            "Testing failed:\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test build/setup failure")
        self.assertEqual(diagnosis["executed_tests"], 0)
        self.assertIn("cannot find type", diagnosis["first_causal_line"])

    def test_diagnoses_app_host_failure_before_tests(self) -> None:
        diagnosis = MODULE.diagnose(
            "The test runner timed out while preparing to run tests.\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test app-host failure")
        self.assertEqual(diagnosis["executed_tests"], 0)

    def test_diagnoses_assertion_failure_after_tests(self) -> None:
        diagnosis = MODULE.diagnose(
            "✘ Test notification() recorded an issue\n"
            "Test run with 9 tests in 1 suite failed after 0.1 seconds.\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "test assertion failure")
        self.assertEqual(diagnosis["executed_tests"], 9)

    def test_diagnoses_pass(self) -> None:
        diagnosis = MODULE.diagnose(
            "Test run with 3 tests in 1 suite passed after 0.1 seconds.\n",
            exit_code=0,
        )

        self.assertEqual(diagnosis["category"], "tests passed")
        self.assertEqual(diagnosis["executed_tests"], 3)

    def test_cli_diagnose_mode_does_not_change_default_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_path = pathlib.Path(temporary_directory) / "output.log"
            output_path.write_text(
                "Executed 1 test, with 1 failure (1 unexpected)\n",
                encoding="utf-8",
            )
            gated = subprocess.run(
                [sys.executable, str(SCRIPT), str(output_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            diagnostic = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(output_path),
                    "--suite",
                    "ExampleTests",
                    "--exit-code",
                    "65",
                    "--diagnose",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertNotEqual(gated.returncode, 0)
        self.assertEqual(diagnostic.returncode, 0)
        self.assertIn("category=test assertion failure", diagnostic.stdout)

    def test_singular_summary_is_supported(self) -> None:
        passed, _ = MODULE.classify("Executed 1 test, with 0 failures (0 unexpected)\n")

        self.assertTrue(passed)


if __name__ == "__main__":
    unittest.main()
