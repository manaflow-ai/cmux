import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/app_host_failure_ratchet.py"
SPEC = importlib.util.spec_from_file_location("app_host_failure_ratchet", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

BASELINE = "1" * 40


def catalog(*ids):
    return MODULE.load_catalog_data({
        "version": 1,
        "baseline_sha": BASELINE,
        "failures": [
            {
                "id": identifier,
                "framework": framework,
                "category": "stale test",
                "issue": 8565,
                "first_seen_run": 100,
                "last_confirmed_run": 200,
            }
            for identifier, framework in ids
        ],
    })


def xctest_failure(identifier: str) -> str:
    suite, test = identifier.removeprefix("xctest:").split("/", 1)
    return (
        f"Test Case '-[{suite} {test}]' started.\n"
        f"/tmp/Test.swift:1: error: -[{suite} {test}] : XCTAssertEqual failed\n"
        f"Test Case '-[{suite} {test}]' failed (0.1 seconds).\n"
        "Executed 7 tests, with 1 failure (0 unexpected)\n"
    )


def swift_failure(name: str) -> str:
    return (
        "◇ Test run started.\n"
        f"◇ Test {name} started.\n"
        f"✘ Test {name} recorded an issue at ExampleTests.swift:12:5: Expectation failed\n"
        f"✘ Test {name} failed after 0.1 seconds with 1 issue.\n"
        "✘ Test run with 9 tests failed after 1.0 seconds with 1 issue.\n"
    )


class AppHostFailureRatchetTests(unittest.TestCase):
    def test_known_xctest_failure_is_tolerated(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testExample"
        passed, message = MODULE.evaluate(
            xctest_failure(identifier),
            exit_code=65,
            catalog=catalog((identifier, "xctest")),
        )
        self.assertTrue(passed)
        self.assertIn(identifier, message)

    def test_swift_run_summary_is_never_a_failure_identifier(self) -> None:
        name = "parameterizedThing(value: 3)"
        ids = MODULE.failure_ids(swift_failure(name))
        self.assertEqual(ids, {f"swift:{name}"})

    def test_new_xctest_failure_blocks(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testNew"
        passed, message = MODULE.evaluate(
            xctest_failure(identifier),
            exit_code=65,
            catalog=catalog(),
        )
        self.assertFalse(passed)
        self.assertIn("new app-host failure", message)

    def test_quoted_swift_display_name_matches_census_identifier(self) -> None:
        display = '"parameterized thing(value: 3)"'
        identifier = "swift:parameterized thing(value: 3)"
        ids = MODULE.failure_ids(swift_failure(display))
        self.assertEqual(ids, {identifier})
        passed, message = MODULE.evaluate(
            swift_failure(display),
            exit_code=65,
            catalog=catalog((identifier, "swift-testing")),
        )
        self.assertTrue(passed)
        self.assertIn(identifier, message)

    def test_known_swift_testing_failure_is_tolerated(self) -> None:
        name = "parameterizedThing(value: 3)"
        identifier = f"swift:{name}"
        passed, message = MODULE.evaluate(
            swift_failure(name),
            exit_code=65,
            catalog=catalog((identifier, "swift-testing")),
        )
        self.assertTrue(passed)
        self.assertIn(identifier, message)

    def test_zero_matching_tests_never_passes(self) -> None:
        passed, message = MODULE.evaluate(
            "Executed 0 tests, with 0 failures (0 unexpected)\n",
            exit_code=0,
            catalog=catalog(),
        )
        self.assertFalse(passed)
        self.assertIn("zero executed tests", message)

    def test_timeout_and_crash_markers_stay_hard_failures(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testExample"
        known = catalog((identifier, "xctest"))
        for extra in (
            "Restarting after unexpected exit, crash, or test timeout; summary follows.\n",
            "✘ Test thing() recorded an issue: Time limit was exceeded: 300.000 seconds\n",
            "Failed to establish communication with the test runner\n",
        ):
            with self.subTest(extra=extra):
                passed, message = MODULE.evaluate(
                    xctest_failure(identifier) + extra,
                    exit_code=65,
                    catalog=known,
                )
                self.assertFalse(passed)
                self.assertIn("hard app-host failure", message)

    def test_known_assertion_cannot_hide_signal_termination(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testExample"
        known = catalog((identifier, "xctest"))
        for signal_line in (
            "Process terminated due to signal 11\n",
            "*** SIGABRT received by test host\n",
            "xctest exited with signal 6\n",
        ):
            with self.subTest(signal_line=signal_line):
                passed, message = MODULE.evaluate(
                    xctest_failure(identifier) + signal_line,
                    exit_code=65,
                    catalog=known,
                )
                self.assertFalse(passed)
                self.assertIn("hard app-host failure", message)

    def test_trailing_zero_xctest_summary_does_not_erase_aggregate_failure(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testKnown"
        output = (
            xctest_failure(identifier)
            + "Executed 0 tests, with 0 failures (0 unexpected)\n"
        )
        passed, message = MODULE.evaluate(
            output,
            exit_code=65,
            catalog=catalog((identifier, "xctest")),
        )
        self.assertTrue(passed)
        self.assertIn(identifier, message)

    def test_known_xctest_failure_cannot_hide_unparsed_second_failure(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testKnown"
        output = xctest_failure(identifier).replace(
            "Executed 7 tests, with 1 failure (0 unexpected)",
            "Executed 7 tests, with 2 failures (0 unexpected)",
        )
        passed, message = MODULE.evaluate(
            output,
            exit_code=65,
            catalog=catalog((identifier, "xctest")),
        )
        self.assertFalse(passed)
        self.assertIn("unparsed app-host failure evidence", message)
        self.assertIn("2 failure(s)", message)

    def test_known_swift_failure_cannot_hide_unparsed_second_issue(self) -> None:
        name = "knownThing()"
        identifier = f"swift:{name}"
        output = swift_failure(name).replace(
            "✘ Test run with 9 tests failed after 1.0 seconds with 1 issue.",
            "✘ Test run with 9 tests failed after 1.0 seconds with 2 issues.",
        )
        passed, message = MODULE.evaluate(
            output,
            exit_code=65,
            catalog=catalog((identifier, "swift-testing")),
        )
        self.assertFalse(passed)
        self.assertIn("unparsed app-host failure evidence", message)
        self.assertIn("2 issue(s)", message)

    def test_failed_swift_summary_without_issue_count_blocks(self) -> None:
        name = "knownThing()"
        identifier = f"swift:{name}"
        output = swift_failure(name).replace(
            "✘ Test run with 9 tests failed after 1.0 seconds with 1 issue.",
            "✘ Test run with 9 tests failed after 1.0 seconds.",
        )
        passed, message = MODULE.evaluate(
            output,
            exit_code=65,
            catalog=catalog((identifier, "swift-testing")),
        )
        self.assertFalse(passed)
        self.assertIn("omitted its issue count", message)

    def test_failed_summary_without_identifier_blocks(self) -> None:
        passed, message = MODULE.evaluate(
            "Executed 2 tests, with 1 failure (0 unexpected)\n",
            exit_code=65,
            catalog=catalog(),
        )
        self.assertFalse(passed)
        self.assertIn("no typed test identifier", message)

    def test_passing_summaries_require_zero_xcodebuild_status(self) -> None:
        output = "Executed 4 tests, with 0 failures (0 unexpected)\n"
        self.assertTrue(MODULE.evaluate(output, exit_code=0, catalog=catalog())[0])
        passed, message = MODULE.evaluate(output, exit_code=65, catalog=catalog())
        self.assertFalse(passed)
        self.assertIn("exited 65", message)

    def test_known_failure_only_normalizes_xcodebuild_status_65(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testExample"
        output = xctest_failure(identifier)
        known = catalog((identifier, "xctest"))
        self.assertTrue(MODULE.evaluate(output, exit_code=65, catalog=known)[0])
        for status in (1, 70, 124, 134):
            with self.subTest(status=status):
                passed, message = MODULE.evaluate(
                    output,
                    exit_code=status,
                    catalog=known,
                )
                self.assertFalse(passed)
                self.assertIn("only for xcodebuild status 65", message)

    def test_catalog_rejects_duplicate_ids(self) -> None:
        identifier = "xctest:cmuxTests.ExampleTests/testExample"
        value = {
            "version": 1,
            "baseline_sha": BASELINE,
            "failures": [
                {
                    "id": identifier,
                    "framework": "xctest",
                    "category": "stale test",
                    "issue": 1,
                    "first_seen_run": 1,
                    "last_confirmed_run": 1,
                },
                {
                    "id": identifier,
                    "framework": "xctest",
                    "category": "stale test",
                    "issue": 1,
                    "first_seen_run": 1,
                    "last_confirmed_run": 1,
                },
            ],
        }
        with self.assertRaisesRegex(ValueError, "duplicate"):
            MODULE.load_catalog_data(value)

    def test_existing_catalog_may_only_shrink(self) -> None:
        a = ("xctest:cmuxTests.A/testA", "xctest")
        b = ("swift:testB()", "swift-testing")
        base = catalog(a, b)
        smaller = catalog(a)
        passed, message = MODULE.check_shrink_only(smaller, base, base_ref="origin/main")
        self.assertTrue(passed)
        self.assertIn("shrank", message)

        larger = catalog(a, b)
        passed, message = MODULE.check_shrink_only(larger, catalog(a), base_ref="origin/main")
        self.assertFalse(passed)
        self.assertIn("may only shrink", message)

    def test_initial_catalog_requires_baseline_ancestor(self) -> None:
        current = catalog()
        completed = type("Completed", (), {"returncode": 0})()
        with patch.object(MODULE.subprocess, "run", return_value=completed) as run:
            passed, _ = MODULE.check_shrink_only(
                current,
                None,
                base_ref="origin/feature",
                baseline_ref="origin/main",
            )
        self.assertTrue(passed)
        self.assertEqual(
            run.call_args.args[0][:3],
            ["git", "merge-base", "--is-ancestor"],
        )
        self.assertEqual(run.call_args.args[0][-1], "origin/main")


if __name__ == "__main__":
    unittest.main()
