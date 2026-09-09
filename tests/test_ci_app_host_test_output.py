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
# dataclasses resolves field types through sys.modules[<module name>].
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


PASSING_XCTEST = (
    "Test Case '-[cmuxTests.AlphaTests testOne]' started.\n"
    "Test Case '-[cmuxTests.AlphaTests testOne]' passed (0.001 seconds).\n"
    "Test Suite 'AlphaTests' passed at 2026-09-09 21:00:00.000.\n"
    "\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n"
    "Test Suite 'Selected tests' passed at 2026-09-09 21:00:00.000.\n"
    "\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n"
)
PASSING_SWIFT_TESTING = (
    "◇ Test run started.\n"
    "◇ Test alphaWorks() started.\n"
    "✔ Test alphaWorks() passed after 0.001 seconds.\n"
    "✔ Test run with 1 test in 1 suite passed after 0.002 seconds.\n"
)


class AppHostTestOutputTests(unittest.TestCase):
    def test_clean_xctest_and_swift_testing_runs_pass(self) -> None:
        report = MODULE.classify(PASSING_XCTEST + PASSING_SWIFT_TESTING)

        self.assertTrue(report.passed, report.reasons)
        self.assertEqual(report.failed_tests, [])
        self.assertEqual(report.crashes, [])

    def test_xctest_assertion_failure_is_not_tolerated_as_expected(self) -> None:
        # Plain XCTAssert failures are reported as "(0 unexpected)"; the old
        # classifier treated that as "all failures are expected" and passed.
        report = MODULE.classify(
            "Test Case '-[cmuxTests.AlphaTests testOne]' started.\n"
            "/repo/cmuxTests/AlphaTests.swift:12: error: -[cmuxTests.AlphaTests testOne] : "
            "XCTAssertEqual failed: (\"1\") is not equal to (\"2\")\n"
            "Test Case '-[cmuxTests.AlphaTests testOne]' failed (0.003 seconds).\n"
            "\t Executed 1 test, with 1 failure (0 unexpected) in 0.003 (0.003) seconds\n"
        )

        self.assertFalse(report.passed)
        self.assertEqual(len(report.failed_tests), 1)
        failed = report.failed_tests[0]
        self.assertEqual((failed.framework, failed.suite, failed.name), ("XCTest", "AlphaTests", "testOne"))
        self.assertIn("XCTAssertEqual failed", failed.message)
        self.assertIn("XCTest reported 1 failure(s) (0 unexpected)", report.reasons)

    def test_unwaited_expectation_counts_as_failure(self) -> None:
        report = MODULE.classify(
            "Test Case '-[cmuxTests.AlphaTests testOne]' started.\n"
            "/repo/cmuxTests/Support.swift:362: error: -[cmuxTests.AlphaTests testOne] : "
            "Failed due to unwaited expectation 'cli mock socket handled'.\n"
            "Test Case '-[cmuxTests.AlphaTests testOne]' failed (0.070 seconds).\n"
            "\t Executed 1 test, with 1 failure (1 unexpected) in 0.070 (0.070) seconds\n"
        )

        self.assertFalse(report.passed)
        self.assertEqual(report.xctest_unexpected_count, 1)
        self.assertIn("unwaited expectation", report.failed_tests[0].message)

    def test_swift_testing_failure_fails_even_with_clean_xctest_summary(self) -> None:
        report = MODULE.classify(
            PASSING_XCTEST
            + "◇ Test run started.\n"
            + "◇ Test betaWorks() started.\n"
            + "✘ Test betaWorks() recorded an issue at BetaTests.swift:40:9: Expectation failed: (a → 1) == 2\n"
            + "✘ Test betaWorks() failed after 0.010 seconds with 1 issue.\n"
            + "✘ Test run with 1 test in 1 suite failed after 0.011 seconds with 1 issue.\n"
        )

        self.assertFalse(report.passed)
        self.assertEqual(len(report.failed_tests), 1)
        failed = report.failed_tests[0]
        self.assertEqual((failed.framework, failed.suite, failed.name), ("Swift Testing", "BetaTests.swift", "betaWorks()"))
        self.assertIn("Expectation failed", failed.message)
        self.assertIn("a Swift Testing run reported failures", report.reasons)

    def test_parameterized_swift_testing_case_is_attributed_to_its_test(self) -> None:
        report = MODULE.classify(
            "◇ Test run started.\n"
            "◇ Test gamma(_:) started.\n"
            "◇ Test case passing 1 argument value → 3 to gamma(_:) started.\n"
            "✘ Test case passing 1 argument value → 3 to gamma(_:) recorded an issue at GammaTests.swift:9:5: Expectation failed: value < 3\n"
            "✘ Test case passing 1 argument value → 3 to gamma(_:) failed after 0.001 seconds with 1 issue.\n"
            "✘ Test gamma(_:) failed after 0.002 seconds with 1 issue.\n"
            "✘ Test run with 1 test in 1 suite failed after 0.003 seconds with 1 issue.\n"
        )

        self.assertFalse(report.passed)
        self.assertEqual([test.name for test in report.failed_tests], ["gamma(_:)"])
        self.assertIn("value < 3", report.failed_tests[0].message)

    def test_app_host_crash_fails_the_batch_and_names_the_in_flight_test(self) -> None:
        report = MODULE.classify(
            PASSING_XCTEST
            + "◇ Test run started.\n"
            + "◇ Test mobilePerformFailureReleasesAcceptedOperationID() started.\n"
            + "cmux_DEV/TabManager.swift:1313: Fatal error: Initial workspace creation failed for an active window manager\n"
            + "2026-09-09 21:07:05.683775+0000 cmux DEV[14877:70549] cmux_DEV/TabManager.swift:1313: Fatal error: Initial workspace creation failed for an active window manager\n"
            + "*** Signal 5: Backtracing from 0x1a87791f8... done ***\n"
            + "*** Program crashed: System trap at 0x00000001a87791f8 ***\n"
            + "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.\n"
            + PASSING_SWIFT_TESTING
        )

        self.assertFalse(report.passed)
        self.assertEqual(len(report.crashes), 1)
        crash = report.crashes[0]
        self.assertIn("Initial workspace creation failed", crash.kind)
        self.assertEqual(crash.in_flight_xctest, "cmuxTests.AlphaTests/testOne")
        self.assertEqual(crash.in_flight_swift_testing, "mobilePerformFailureReleasesAcceptedOperationID()")
        self.assertEqual(report.restarts, 1)
        self.assertIn("the app host crashed 1 time(s)", report.reasons)

    def test_missing_summary_is_not_tolerated(self) -> None:
        report = MODULE.classify("xcodebuild aborted before reporting results\n")

        self.assertFalse(report.passed)
        self.assertIn("no XCTest or Swift Testing run summary was found", report.reasons)

    def test_github_log_timestamps_are_ignored(self) -> None:
        stamped = "".join(
            f"2026-09-09T21:00:00.0000000Z {line}\n" for line in PASSING_XCTEST.splitlines()
        )
        report = MODULE.classify(stamped)

        self.assertTrue(report.passed, report.reasons)
        self.assertEqual(report.xctest_summaries, 2)

    def test_markdown_report_lists_failures_and_crashes(self) -> None:
        report = MODULE.classify(
            "Test Case '-[cmuxTests.AlphaTests testOne]' started.\n"
            "/repo/cmuxTests/AlphaTests.swift:12: error: -[cmuxTests.AlphaTests testOne] : XCTAssertTrue failed - a | b\n"
            "Test Case '-[cmuxTests.AlphaTests testOne]' failed (0.003 seconds).\n"
            "*** Program crashed: Bad pointer dereference at 0x0000000000000000 ***\n"
            "\t Executed 1 test, with 1 failure (0 unexpected) in 0.003 (0.003) seconds\n",
            label="shard 1/6 batch 1/12",
        )
        markdown = MODULE.render_markdown(report)

        self.assertIn("### shard 1/6 batch 1/12: FAILED", markdown)
        self.assertIn("| XCTest | AlphaTests | `testOne` | XCTAssertTrue failed - a \\| b |", markdown)
        self.assertIn("| Bad pointer dereference at 0x0000000000000000 | `cmuxTests.AlphaTests/testOne` |", markdown)


if __name__ == "__main__":
    unittest.main()
