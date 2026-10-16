#!/usr/bin/env python3

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "ci" / "require_swift_test_execution.py"


class SwiftTestExecutionTests(unittest.TestCase):
    def run_guard(self, output: str, mode: str = "--log") -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "swift.txt"
            log.write_text(output, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(GUARD), mode, str(log)],
                text=True, capture_output=True, check=False,
            )

    def test_accepts_supported_swift_testing_summaries(self) -> None:
        for summary in (
            "✔ Test run with 1 test passed after 0.001 seconds.",
            "✔ Test run with 11 tests in 1 suite passed after 1.230 seconds.",
            "✔ Test run with 11 tests in 2 suites passed after 1.230 seconds.",
            "\x1b[32m✔ Test run with 11 tests in 0 suites passed after 1.230 seconds.\x1b[0m",
        ):
            with self.subTest(summary=summary):
                result = self.run_guard(summary)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreater(int(result.stdout), 0)

    def test_rejects_empty_zero_and_incomplete_runs(self) -> None:
        for output in (
            "",
            "Build complete! (1.0 secs.)\n",
            "◇ Test run started.\n✔ Test one() passed after 0.001 seconds.\n",
            "✔ Test run with 0 tests passed after 0.001 seconds.",
            "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.",
            "Test run with 4 tests in 2 suites",
            "Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds",
            "Test Suite 'ChildSuite' passed at 2026-09-23 00:00:00.000.\n"
            "Executed 1 test, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n",
        ):
            with self.subTest(output=output):
                result = self.run_guard(output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no completed nonzero", result.stderr)

    def test_xctest_only_package_can_have_zero_swift_testing_tests(self) -> None:
        result = self.run_guard(
            "Executed 1 test, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
            "Executed 3 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
            "Test Suite 'All tests' passed at 2026-09-23 00:00:00.000.\n"
            "\n"
            "Executed 3 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
            "✔ Test run with 0 tests passed after 0.001 seconds.\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "3")

    def test_selected_xctest_run_requires_overall_completion(self) -> None:
        result = self.run_guard(
            "Test Suite 'Selected tests' passed at 2026-09-23 00:00:00.000.\n"
            "Executed 1 test, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1")

    def test_xctest_skips_do_not_count_as_execution(self) -> None:
        for skipped, expected in ((1, 2), (3, 0)):
            with self.subTest(skipped=skipped):
                result = self.run_guard(
                    "Test Suite 'All tests' passed at 2026-09-23 00:00:00.000.\n"
                    f"Executed 3 tests, with {skipped} tests skipped and 0 failures "
                    "(0 unexpected) in 0.0 (0.0) seconds\n"
                )
                if expected:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), str(expected))
                else:
                    self.assertNotEqual(result.returncode, 0)

    def test_failure_is_not_erased_by_a_later_passing_summary(self) -> None:
        for failure in (
            "✘ Test run with 2 tests in 1 suite failed after 1.0 seconds with 1 issue.",
            "Executed 2 tests, with 1 failure (0 unexpected) in 0.0 (0.0) seconds",
            "Executed 2 tests, with 0 failures (1 unexpected) in 0.0 (0.0) seconds",
            "Test Suite 'All tests' failed at 2026-09-23 00:00:00.000.",
            "Test Suite 'Selected tests' failed at 2026-09-23 00:00:00.000.",
        ):
            with self.subTest(failure=failure):
                result = self.run_guard(failure + "\n✔ Test run with 3 tests passed after 1.0 seconds.\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fail", result.stderr)

    def test_discovery_preserves_top_level_and_module_qualified_suites(self) -> None:
        result = self.run_guard(
            "FirstTests.Suite/testOne()\nFirstTests.Suite/testTwo()\n"
            "SecondTests.Suite/testThree()\nFirstTests.topLevel()\n",
            "--list-filters",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            r"^FirstTests\.Suite/", r"^FirstTests\.topLevel\(\)($|/)",
            r"^SecondTests\.Suite/",
        ])

    def test_discovery_fails_closed_on_unrecognized_or_empty_output(self) -> None:
        for output in ("", "FirstTests.Suite/testOne()\nunrecognized new test record\n"):
            with self.subTest(output=output):
                result = self.run_guard(output, "--list-filters")
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
