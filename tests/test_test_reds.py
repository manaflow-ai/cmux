"""scripts/ci/test_reds.py: a red test job is the base's only when every failing test fails on the base too, and a
crash or a cut-short run is never the base's."""
import importlib.util
import json
import subprocess
import sys
import tempfile
from collections import Counter
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("test_reds", ROOT / "scripts/ci/test_reds.py")
reds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reds)

FIXTURES = ROOT / "tests/fixtures/test_reds"
# cmux#26346's head 1caa870b, run 40620080851 (attempt 3, job 122609320390), and the feat-cmux-next run its swift
# test red was compared with (40626248565, job 122611913105, at 94455680). Excerpts of the real job logs: the test
# results, the crash and the job's error lines.
HEAD_26346 = FIXTURES / "26346-head-run-40620080851.log"
BASE_26346 = FIXTURES / "26346-base-run-40626248565.log"
# `bun test` reds, trimmed to the bun run: fast checks run 41057297193 (job 124067944438, feat-cmux-next ad6de25e,
# chat-unavailable.test.ts run from the repo root, 3 fails) and run 41056184399 (job 124064196820, a pasteWall
# toBeLessThan fail), as the job logs print them. Run 41060421706 printed bun's raw output for throwaway tests: a
# toBe, a toBeLessThan, a timeout, an error between tests, a file that cannot load, and a run killed mid-file.
BUN_CHAT_UNAVAILABLE = FIXTURES / "bun-chat-unavailable-run-41057297193.log"
BUN_PASTE_WALL = FIXTURES / "bun-paste-wall-run-41056184399.log"
BUN_RAW = FIXTURES / "bun-raw-run-41060421706.log"
BUN_RAW_KILLED = FIXTURES / "bun-raw-killed-run-41060421706.log"


def log(*lines):
    return "\n".join(f"2026-10-28T03:40:35.1790820Z {line}" for line in lines)


def failed(name):
    return f"✘ Test {name} recorded an issue at X.swift:1:2: Expectation failed"


def failed_suite(name):
    return f"✘ Suite {name} recorded an issue at {name}.swift:12:13: Issue recorded"


SUMMARY = "✔ Test run with 40 tests in 3 suites passed after 1.0 seconds."


def step(script):
    """The runner's echo of a `run:` step, as a job log shows it before the step's output."""
    return [f"##[group]Run {script}", script, "shell: /usr/bin/bash -e {0}", "env:", "  GITHUB_REPO_NAME: o/r",
            "##[endgroup]"]
ABORT = ("error: Process '/x/swiftpm-testing-helper --test-bundle-path /x/CmuxNextPackageTests.xctest' exited with "
         "unexpected signal code 6")


class Replay26346(unittest.TestCase):
    def test_the_26346_head_is_its_own_red_for_its_crash(self):
        verdict = reds.classify(HEAD_26346.read_text(), BASE_26346.read_text(), "cmux-next swift test",
                                "feat-cmux-next run 40626248565")
        self.assertTrue(verdict.own)
        self.assertEqual(verdict.reasons[0],
                         "HomeTypeToFocusTests.aPaneFocusShortcutFromAnotherPaneThenTypingFillsTheBox crashed (signal 6)")
        # The base crashed the same way (the intro was on the base by then): still the head's.
        self.assertTrue(reds.read(BASE_26346.read_text()).crashes)
        self.assertIn("3 failing test(s) pass or do not run on feat-cmux-next run 40626248565", verdict.reasons[-1])

    def test_the_command_line_exits_1_and_names_the_crash(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/test_reds.py"), "classify", "--head",
                               str(HEAD_26346), "--base", str(BASE_26346), "--json"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertTrue(json.loads(done.stdout)["own"])
        self.assertIn("crashed (signal 6)", json.loads(done.stdout)["reasons"][0])


def objc_line(path="Sources/A.swift", line=12, member="viewDidMove", cls="NSView", sel="viewDidMove"):
    return (f"objc-selectors: {path}:{line}: super.{member} ({cls} call:{sel}/0): probe needed; "
            "run scripts/cmux-next/check-objc-selectors.py --probe --write on a Mac and commit table.json")


class CrashClassRuleLines(unittest.TestCase):
    # cmux#33113 added an unprobed `super` call; the rule printed this line and the job had no test name to match.
    def test_the_line_is_a_named_failure_keyed_by_rule_site_and_selector(self):
        found = reds.read(log(objc_line()))
        self.assertEqual(found.failed, {"objc-selectors Sources/A.swift:12 super.viewDidMove (NSView call:viewDidMove/0)"})
        self.assertTrue(reds.is_test_red(found))

    def test_the_same_diagnostic_on_head_and_base_is_a_base_red(self):
        verdict = reds.classify(log(objc_line()), log(objc_line()))
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(len(verdict.shared), 1)

    def test_error_annotation_prefix_and_timestamp_still_match(self):
        verdict = reds.classify(log("##[error]" + objc_line()), log(objc_line()))
        self.assertFalse(verdict.own, verdict.reasons)

    def test_a_different_file_line_or_selector_is_the_heads_own(self):
        for other in (objc_line(path="Sources/B.swift"), objc_line(line=13),
                      objc_line(member="mouseDown", sel="mouseDown")):
            with self.subTest(other=other):
                verdict = reds.classify(log(other), log(objc_line()))
                self.assertTrue(verdict.own)
                self.assertIn("pass or do not run", " ".join(verdict.reasons))

    def test_no_base_log_excuses_nothing(self):
        self.assertTrue(reds.classify(log(objc_line()), None).own)

    def test_the_cef_contract_rule_is_keyed_by_its_detail(self):
        line = "cef-objc-contract: NSApp foo:: verdict 'x' (review it: a, b)"
        self.assertFalse(reds.classify(log(line), log(line)).own)
        self.assertTrue(reds.classify(log(line), log(line.replace("foo", "bar"))).own)


class KnownIssueSuiteCompletion(unittest.TestCase):
    # Reduced from the #27127 comparison: a completed ClassicUpgradeSimulationTests suite
    # was treated as unfinished even though its known-issue test and run summary were read.
    def setUp(self):
        self.whole = (FIXTURES / "known-issue-suite.log").read_text()

    def test_a_completed_known_issue_suite_does_not_hide_a_shared_red(self):
        self.assertEqual(reds.read(self.whole).truncated, [])
        both = log(failed("unrelated()"), SUMMARY) + "\n" + self.whole
        verdict = reds.classify(both, both)
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["unrelated()"])

    def test_a_known_issue_marker_does_not_excuse_missing_completion(self):
        for end in ("━ Test aRunCutOffMidwayFinishesWithoutDuplicates() passed",
                    "━ Suite ClassicUpgradeSimulationTests passed", "━ Test run with"):
            with self.subTest(end=end):
                cut = "\n".join(line for line in self.whole.splitlines() if not line.startswith(end))
                verdict = reds.classify(cut, cut)
                self.assertTrue(verdict.own)
                self.assertIn("per-test results are not whole", verdict.reasons[0])
                if end.startswith("━ Suite"):
                    self.assertIn("suite(s) started and never finished: ClassicUpgradeSimulationTests",
                                  verdict.reasons[0])

    def test_a_crash_after_a_completed_known_issue_suite_is_still_its_own(self):
        crashed = self.whole + "\n" + ABORT
        verdict = reds.classify(crashed, crashed)
        self.assertTrue(verdict.own)
        self.assertIn("crashed (signal 6)", verdict.reasons[0])


class EchoedStepScripts(unittest.TestCase):
    """The runner echoes each step's script (`##[group]Run ...`, the script, `shell:`/`env:`, `##[endgroup]`)
    before running it, so a script that prints, greps or filters test names puts those names in every run's log,
    green or red. Only what the step printed is a result. 2026-10-30: cmux#28145's kit job at c39d28ef failed
    HomeRetryTests.failedHomeLoadRetriesTheFeedOnTheExistingLink and MacHomeFeedTests.aFailedOpenIsTriedAgain on the
    iOS simulator; base run 41138142557 (feat-cmux-next f4cebb13) failed only TerminalSurfaceFramePacingTests.
    busyOutputDrawsAtMostOneFramePerDisplayRefresh, yet the red was excused as the base's."""

    HEAD = FIXTURES / "ios-kit-head-run-41079430021.log"  # trimmed; gh printed it without colours
    BASE = FIXTURES / "ios-kit-base-run-41138142557.log"  # trimmed; the job-log endpoint's raw text, colours kept

    def test_the_kit_reds_on_28145_are_its_own_against_base_run_41138142557(self):
        verdict = reds.classify(self.HEAD.read_text(), self.BASE.read_text(),
                                "CmuxMobileKit tests (macOS swift test, iOS simulator)",
                                "feat-cmux-next run 41138142557")
        self.assertIsNotNone(verdict, "the xcresult FAILED: lines name the failing tests")
        self.assertTrue(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, [])
        self.assertIn("2 failing test(s) pass or do not run on feat-cmux-next run 41138142557: "
                      "HomeRetryTests.failedHomeLoadRetriesTheFeedOnTheExistingLink(); "
                      "MacHomeFeedTests.aFailedOpenIsTriedAgain()", verdict.reasons[-1])

    def test_xcresult_and_xcodebuild_failure_lines_name_the_failing_tests(self):
        self.assertEqual(reds.read(self.BASE.read_text()).failed,
                         {"TerminalSurfaceFramePacingTests.busyOutputDrawsAtMostOneFramePerDisplayRefresh()"})
        self.assertEqual(reds.read(self.HEAD.read_text()).failed,
                         {"HomeRetryTests.failedHomeLoadRetriesTheFeedOnTheExistingLink()",
                          "MacHomeFeedTests.aFailedOpenIsTriedAgain()"})

    def test_a_test_named_only_in_the_bases_step_script_is_not_a_base_red(self):
        # The base's script names X in every failure format this classifier reads (a grep, a filter, an echo),
        # but the base's real failure is Y. The head fails X: its own red.
        script = ["##[group]Run set -euo pipefail",
                  "\x1b[36;1mset -euo pipefail\x1b[0m",
                  "\x1b[36;1mswift test --filter 'x()' 2>&1 | tee out.txt\x1b[0m",
                  "\x1b[36;1mgrep -E '✘ Test x\\(\\) recorded an issue' out.txt && echo 'known: x()'\x1b[0m",
                  "FAILED: Pkg / Mod / XTests / x()",
                  "Test Case '-[XTests x]' failed",
                  "test x ... FAILED",
                  "FAIL: x (xtests.XTests)",
                  "FAILED xtests.py::x",
                  "Failing tests:",
                  "\tXTests.x()",
                  "shell: /bin/bash -e {0}",
                  "env:",
                  "  FILTER: ✘ Test x() recorded an issue",
                  "##[endgroup]"]
        base = log(*script, "◇ Test run started.", failed("y()"),
                   "✘ Test run with 2 tests in 1 suite failed after 0.1 seconds with 1 issue.")
        head = log(*script, "◇ Test run started.", failed("x()"),
                   "✘ Test run with 2 tests in 1 suite failed after 0.1 seconds with 1 issue.")
        self.assertEqual(reds.read(base).failed, {"y()"})
        verdict = reds.classify(head, base, "cmux-next swift test")
        self.assertTrue(verdict.own, verdict.reasons)
        self.assertIn("1 failing test(s) pass or do not run on the base: x()", verdict.reasons[-1])
        # The same script with X really failing on both sides is still a base red.
        verdict = reds.classify(head, head, "cmux-next swift test")
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["x()"])

    def test_a_steps_own_run_group_is_still_read(self):
        # A step's own `::group::Run ...` holds what it printed, not an echo (no shell/with/env lines): read.
        own = log("##[group]Run the suite", failed("x()"), "##[endgroup]",
                  "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.")
        self.assertEqual(reds.read(own).failed, {"x()"})
        # A crash a step prints inside its own group is a crash.
        self.assertTrue(reds.read(log("##[group]Run the suite", ABORT, "##[endgroup]")).crashes)
        # A step's own group whose output quotes `env:` or `shell:` before a failure is output, not an echo.
        for quoted in ("env:", "shell: /bin/bash -e {0}", "with:"):
            with self.subTest(quoted=quoted):
                group = log("##[group]Run the suite", quoted, "  HOME: /x", failed("x()"), "##[endgroup]")
                self.assertEqual(reds.read(group).failed, {"x()"})
        # An echo the log cut before its `##[endgroup]` is no echo: everything after it is read.
        self.assertEqual(reds.read(log("##[group]Run x", "shell: /bin/bash -e {0}", failed("x()"))).failed,
                         {"x()"})


class PerTest(unittest.TestCase):
    def test_suite_teardown_issue_is_a_failing_suite(self):
        found = reds.read(log(failed_suite("SidebarGroupHoverCardTests"),
                              "✘ Suite SidebarGroupHoverCardTests failed after 0.2 seconds with 1 issue."))
        self.assertEqual(found.failed, {"SidebarGroupHoverCardTests"})

    def test_quoted_suite_teardown_issue_is_a_failing_suite(self):
        found = reds.read(log(
            '✘ Suite "Cloud sidebar Ports status controls" recorded an issue at Cloud.swift:1:2: Issue recorded',
            '✘ Suite "Cloud sidebar Ports status controls" failed after 0.2 seconds with 1 issue.',
        ))
        self.assertEqual(found.failed, {"Cloud sidebar Ports status controls"})

    def test_swift_test_summary_fixture_signal_text_is_not_a_crash(self):
        fixture = log(
            "scripts/cmux-next/tests/swift-test-summary.test.sh:148: "
            '"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"}',
            "scripts/cmux-next/tests/swift-test-summary.test.sh:157: "
            "error: Process '/x/swiftpm-testing-helper' exited with unexpected signal code 5",
        )
        shared = fixture + "\n" + log(failed("a()"), SUMMARY)
        self.assertEqual(reds.read(shared).crashes, [])
        verdict = reds.classify(shared, log(failed("a()"), SUMMARY), "cmux-next checks")
        self.assertFalse(verdict.own, verdict.reasons)

    def test_signal_exit_after_a_complete_summary_is_never_a_base_red(self):
        whole = log("◇ Test run started.", failed("a()"),
                    "✘ Test a() failed after 0.1 seconds with 1 issue.",
                    "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.")
        for code in (129, 130, 134, 137, 139, 141, 143, 192):
            for prefix in ("##[error]", "::error::"):
                with self.subTest(code=code, prefix=prefix):
                    killed = whole + "\n" + log(f"{prefix}Process completed with exit code {code}.")
                    # Even identical base output cannot excuse a signal-style termination.
                    verdict = reds.classify(killed, killed, "cmux-next swift test")
                    self.assertTrue(verdict.own, verdict.reasons)
                    self.assertIn(f"crashed (signal {code - 128})", verdict.reasons[0])
                    self.assertEqual(verdict.shared, ["a()"])

    def test_signal_exit_after_passing_tests_does_not_fall_back_to_job_comparison(self):
        killed = log(SUMMARY, "##[error]Process completed with exit code 143.")
        verdict = reds.classify(killed, killed, "cmux-next swift test")
        self.assertIsNotNone(verdict)
        self.assertTrue(verdict.own)
        self.assertIn("crashed (signal 15)", verdict.reasons[0])

    def test_ordinary_exit_status_and_quoted_signal_status_keep_shared_failures(self):
        for line in ("##[error]Process completed with exit code 1.",
                     "##[error]Process completed with exit code 75.",
                     "##[error]Process completed with exit code 128.",
                     "##[error]Process completed with exit code 193.",
                     "✔ Test diagnostic() passed: ##[error]Process completed with exit code 143.",
                     "✘ Test a() recorded an issue at X.swift:1:2: ##[error]Process completed with exit code 143."):
            with self.subTest(line=line):
                shared = log(failed("a()"), SUMMARY, line)
                verdict = reds.classify(shared, shared, "cmux-next swift test")
                self.assertFalse(verdict.own, verdict.reasons)
                self.assertEqual(reds.read(shared).crashes, [])


    def test_the_same_test_failing_on_both_sides_is_a_base_red(self):
        verdict = reds.classify(log(failed("a()"), SUMMARY), log(failed("a()"), failed("b()"), SUMMARY))
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["a()"])

    def test_a_new_failing_test_is_the_heads_own(self):
        verdict = reds.classify(log(failed("a()"), failed("c()"), SUMMARY), log(failed("a()"), SUMMARY))
        self.assertTrue(verdict.own)
        self.assertIn("pass or do not run on the base: c()", verdict.reasons[0])

    def test_display_named_swift_testing_reds_are_compared_by_name(self):
        # PR 35296's shard 2: `@Test("…")` names print quoted, with no `()`.
        shared = '✘ Test "A capped plan shows used/limit" recorded an issue at X.swift:25:9: Expectation failed'
        param = ('✘ Test "Hovering shows help" recorded an issue with 2 arguments activeCount → 1, help → "x" '
                 'at X.swift:1:2: Expectation failed')
        self.assertEqual(reds.read(log(shared, param, SUMMARY)).failed,
                         {'"A capped plan shows used/limit"', '"Hovering shows help"'})
        self.assertFalse(reds.classify(log(shared, SUMMARY), log(shared, SUMMARY)).own)
        new = log(shared, '✘ Test "Another" recorded an issue at X.swift:3:4: Expectation failed', SUMMARY)
        self.assertIn('"Another"', reds.classify(new, log(shared, SUMMARY)).reasons[0])

    def test_two_suites_same_display_name_are_not_one_test(self):
        # A `@Test("...")` name prints with no suite, and suites interleave (three were open at once in
        # tests/fixtures/test_reds/26346-head-run-40620080851.log), so the suite cannot be read from the
        # ✘ line. The issue's file can: a display name whose head and base failures record their issues in
        # files that do not overlap is two tests, not one red (cmux#35902).
        head = log('✘ Test "shows the plan" recorded an issue at CloudPlanTests.swift:25:9: Expectation failed',
                   '✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.', SUMMARY)
        base = log('✘ Test "shows the plan" recorded an issue at HomePlanTests.swift:14:9: Expectation failed',
                   '✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.', SUMMARY)
        verdict = reds.classify(head, base)
        self.assertTrue(verdict.own, verdict.reasons)
        self.assertIn("CloudPlanTests.swift", verdict.reasons[0])
        self.assertEqual(verdict.shared, [])

    def test_the_same_display_named_test_is_still_a_base_red(self):
        # The same test, failing at another line of its own file, or at a second expectation in it: the
        # files overlap, so it stays the base's red. The classifier is per test, not per assertion.
        head = log('✘ Test "shows the plan" recorded an issue at CloudPlanTests.swift:25:9: Expectation failed',
                   '✘ Test "shows the plan" recorded an issue at CloudPlanHelper.swift:3:1: Expectation failed',
                   SUMMARY)
        base = log('✘ Test "shows the plan" recorded an issue at CloudPlanTests.swift:31:9: Expectation failed',
                   SUMMARY)
        self.assertFalse(reds.classify(head, base).own, reds.classify(head, base).reasons)

    def test_a_module_relative_issue_location_records_its_file(self):
        # A location can be module-relative (`Package/CloudPlanTests.swift:25:9`). With no `/` in the file
        # class, neither side recorded a file, both fell back to name-only comparison, and two distinct
        # suites with one display name read as a single base red (cmux#35961 F1).
        head = log('✘ Test "shows the plan" recorded an issue at Pkg/Cloud/CloudPlanTests.swift:25:9: '
                   'Expectation failed', '✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.',
                   SUMMARY)
        base = log('✘ Test "shows the plan" recorded an issue at Pkg/Home/HomePlanTests.swift:14:9: '
                   'Expectation failed', '✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.',
                   SUMMARY)
        self.assertEqual(reds.read(head).sites, {'"shows the plan"': {"Pkg/Cloud/CloudPlanTests.swift"}})
        verdict = reds.classify(head, base)
        self.assertTrue(verdict.own, verdict.reasons)
        self.assertIn("Pkg/Cloud/CloudPlanTests.swift", verdict.reasons[0])
        self.assertEqual(verdict.shared, [])

    def test_a_location_quoted_after_the_real_one_is_not_the_issue_site(self):
        # The source location is not at end of line: the expectation text follows it and can quote another
        # ` at <file>.swift:<line>:<col>`. Reading the last one recorded the wrong file, so a test that fails
        # in the same file on both sides read as two tests and the shared base red became the head's own
        # (cmux#35961 F2). The first location after the arguments clause is the one Swift Testing printed.
        head = log('✘ Test "shows the plan" recorded an issue at CloudPlanTests.swift:25:9: Expectation '
                   'failed: (trace → "raised at HomePlanTests.swift:14:2")',
                   '✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.', SUMMARY)
        base = log('✘ Test "shows the plan" recorded an issue at CloudPlanTests.swift:25:9: Expectation failed',
                   '✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.', SUMMARY)
        self.assertEqual(reds.read(head).sites, {'"shows the plan"': {"CloudPlanTests.swift"}})
        verdict = reds.classify(head, base)
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ['"shows the plan"'])

    def test_an_arguments_clause_still_yields_the_location_after_it(self):
        # A parameterized test prints `with N arguments ...` before the location, and an argument value may
        # itself hold a `.swift:` (cmux#35902); the clause is skipped, the location after it is recorded.
        head = log('✘ Test "shows the plan" recorded an issue with 1 argument p → "A.swift:1:1" at '
                   'Pkg/CloudPlanTests.swift:25:9: Expectation failed', SUMMARY)
        self.assertEqual(reds.read(head).sites, {'"shows the plan"': {"Pkg/CloudPlanTests.swift"}})

    def test_a_display_name_with_no_file_on_either_side_compares_by_name(self):
        # Only the `failed after` line, as a rerun summary prints: nothing says which suite, so the name
        # alone decides, exactly as before this comparison existed.
        both = log('✘ Test "shows the plan" failed after 0.1 seconds with 1 issue.', SUMMARY)
        self.assertFalse(reds.classify(both, both).own)

    def test_a_crash_on_both_sides_is_still_the_heads_own(self):
        both = log(failed("a()"), ABORT, "*** Terminating app due to uncaught exception 'NSInternalInconsistencyException'")
        verdict = reds.classify(both, both)
        self.assertTrue(verdict.own)
        self.assertEqual(verdict.reasons[0], "the test process crashed (signal 6)")

    def test_truncated_output_is_the_heads_own(self):
        cut = log(failed("a()"), '##[error]no "Test run with" summary line (crash, kill or truncation); swift test '
                  "exited 1, and SwiftPM prints no line when the test helper ends on SIGINT, SIGTERM or SIGKILL")
        verdict = reds.classify(cut, log(failed("a()"), SUMMARY))
        self.assertTrue(verdict.own)
        self.assertIn("per-test results are not whole", verdict.reasons[0])

    def test_no_base_log_excuses_nothing(self):
        self.assertTrue(reds.classify(log(failed("a()"), SUMMARY), None).own)

    def test_an_unreadable_head_log_is_the_heads_own(self):
        self.assertTrue(reds.classify(None, log(failed("a()"))).own)

    def test_a_job_that_runs_no_tests_is_not_judged_here(self):
        self.assertIsNone(reds.classify(log("error: cannot find 'x' in scope"), log("error: cannot find 'x' in scope")))

    def test_a_lint_red_beside_passing_unit_tests_is_not_judged_here(self):
        lint = log("Ran 26 tests in 0.003s", "OK", "##[error]Localizable.xcstrings:key: missing uk")
        self.assertIsNone(reds.classify(lint, lint))

    def test_crash_words_in_source_listings_and_passing_test_names_are_not_crashes(self):
        quiet = log("[12/40] Compiling CmuxNextHome CrashReporter.swift", " 3 | /// A caught signal returns to its "
                    "default action", "✔ Test aCrashEndsTheApp() passed after 0.1 seconds.", failed("a()"), SUMMARY)
        self.assertFalse(reds.read(quiet).crashes)
        self.assertFalse(reds.classify(quiet, log(failed("a()"), SUMMARY)).own)

    def test_a_run_cut_off_with_no_marker_is_the_heads_own(self):
        for cut in (log("◇ Test a() started.", failed("a()"), "✘ Test a() failed after 0.1 seconds with 1 issue.",
                        "◇ Test b() started."),
                    log("running 2 tests", "test a ... FAILED", "test b ...")):
            with self.subTest(cut):
                verdict = reds.classify(cut, log(failed("a()"), "test a ... FAILED", SUMMARY))
                self.assertTrue(verdict.own)
                self.assertIn("per-test results are not whole", verdict.reasons[0])

    def test_a_whole_parameterized_run_is_not_cut_off(self):
        whole = log('◇ Test f(_:) started.', '◇ Test case passing 1 argument x → 1 to f(_:) started.',
                    "✔ Test f(_:) with 2 test cases passed after 0.1 seconds.", failed("a()"),
                    "✘ Test a() failed after 0.1 seconds with 1 issue.", SUMMARY)
        self.assertEqual(reds.read(whole).truncated, [])

    def test_a_suite_end_after_a_zero_width_space_is_whole(self):
        # PR 35296's app-host shard 2: Swift Testing printed "\u200b✔ Suite ... passed" after interleaved app logs.
        whole = log('◇ Suite "Cloud sidebar recorded interaction" started.',
                    '\u200b✔ Suite "Cloud sidebar recorded interaction" passed after 0.001 seconds.', SUMMARY)
        self.assertEqual(reds.read(whole).truncated, [])
        cut = log('\u200b◇ Suite "s" started.', SUMMARY)
        self.assertIn('1 suite(s) started and never finished: "s"', reds.read(cut).truncated)

    def test_a_run_cut_off_between_tests_is_the_heads_own(self):
        cut = log("◇ Test run started.", "◇ Suite S started.", "◇ Test a() started.", failed("a()"),
                  "✘ Test a() failed after 0.1 seconds with 1 issue.")
        verdict = reds.classify(cut, log(failed("a()"), SUMMARY))
        self.assertTrue(verdict.own)
        self.assertIn("printed no `Test run with` summary", verdict.reasons[0])

    def test_a_summary_below_the_tests_that_ran_or_an_open_xctest_suite_is_cut_short(self):
        short = log("◇ Test run started.", "✔ Test b() passed after 0.1 seconds.", failed("a()"),
                    "✘ Test a() failed after 0.1 seconds with 1 issue.",
                    "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.")
        self.assertIn("the summaries count 1 tests but 2 finished", reds.read(short).truncated)
        xc = log("Test Suite 'All tests' started at 2026-10-28 03:38:42.712.",
                 "Test Case '-[M.T testA]' started.", "Test Case '-[M.T testA]' failed (0.1 seconds).")
        self.assertTrue(reds.classify(xc, xc).own)

    def test_bare_signal_and_exception_lines_are_crashes_and_an_empty_log_is_unreadable(self):
        for line in ("error: Exited with unexpected signal code 6", "Process '/x' exited with signal 6", "terminated by signal 9", "EXC_BAD_ACCESS (code=1)"):
            with self.subTest(line):
                self.assertTrue(reds.classify(log(line), log(line), "cmux-next swift test").own)
        self.assertTrue(reds.classify("  \n", log(failed("a()")), "cmux-next swift test").own)

    def test_a_harness_heading_that_names_a_crash_is_not_one_but_the_crash_under_it_is(self):
        # cmuxterm-hq#7285, run 42053582212: fresh_home_launch_smoke.py's heading above a launch over its budget.
        heading = "--- the app's errors in the system log (an uncaught exception or assertion names itself here)"
        over = "relaunch restore took 3042 ms, over its 3000 ms budget"
        self.assertFalse(reds.read(log(over, heading, "--- app output (last 60 lines)")).crashes)
        crash = "*** Terminating app due to uncaught exception 'NSInternalInconsistencyException'"
        self.assertTrue(reds.read(log(over, heading, crash)).crashes)
        self.assertTrue(reds.read(log(over, f"--- {crash}")).crashes)

    def test_a_whole_unittest_run_and_a_known_issue_run_end_are_whole(self):
        self.assertEqual(reds.read(log("test_a (mod.T.test_a) ... ok", "Ran 1 test in 0.001s", "OK")).truncated, [])
        self.assertEqual(reds.read(log("◇ Test run started.", "━ Test run with 1 test in 1 suite passed after 0.1 "
                                       "seconds with 1 known issue.")).truncated, [])

    def test_a_test_that_passed_with_a_known_issue_finished(self):
        # cmux-next daemon tests, run 40705037968: aRunCutOffMidwayFinishesWithoutDuplicates passed with a
        # known issue ("━ Test ... passed ... with 1 known issue") and was read as started and never finished.
        run = log("◇ Test run started.", "◇ Test a() started.",
                  "━ Test a() recorded a known issue at A.swift:1:1: Expectation failed",
                  "━ Test a() passed after 9.5 seconds with 1 known issue.",
                  "━ Test run with 1 test in 1 suite passed after 9.5 seconds with 1 known issue.")
        self.assertEqual(reds.read(run).truncated, [])

    def test_a_pass_line_another_stream_cut_into_finished(self):
        # cmux-next swift test, run 41665450504 shard 14: the runtime's stderr cut into a pass line and the helper was
        # killed before the rest was written. It passed; the run is still cut short (no summary), never a base red.
        run = log("◇ Test run started.", "◇ Test aFailureNothingRetriesShowsAtOnce() started.",
                  "✔ Test aFailureNothingRetriesShowsAtOnceswift runtime: backtrace-on-crash is not supported for "
                  "privileged executables.")
        self.assertFalse(any("never finished" in why for why in reds.read(run).truncated))
        # foo() is not closed by fooBar()'s pass.
        other = log("◇ Test run started.", "◇ Test foo() started.", "◇ Test fooBar() started.",
                    "✔ Test fooBar() passed after 0.1 seconds.")
        self.assertIn("1 test(s) started and never finished: foo", reds.read(other).truncated)
        # A cut-into pass closes the longest name it fits, once: fooBar(), never foo() as well.
        both = log("◇ Test run started.", "◇ Test foo() started.", "◇ Test fooBar() started.",
                   "✔ Test fooBarswift runtime: backtrace-on-crash is not supported for privileged executables.")
        self.assertIn("1 test(s) started and never finished: foo", reds.read(both).truncated)
        # A run's own summary does not close a test named run().
        named_run = log("◇ Test run started.", "◇ Test run() started.", "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.")
        self.assertIn("1 test(s) started and never finished: run", reds.read(named_run).truncated)

    def test_the_bundle_runners_exited_line_is_a_crash_after_a_shared_failure(self):
        crash = log("◇ Test run started.", failed("a()"), "✘ Test a() failed after 0.1 seconds with 1 issue.",
                    "error: Exited with unexpected signal code 6")
        verdict = reds.classify(crash, log(failed("a()"), SUMMARY), "cmux-next swift test")
        self.assertTrue(verdict.own)
        self.assertIn("crashed (signal 6)", verdict.reasons[0])

    def test_the_hang_watchdog_and_timeout_annotations_are_cut_short(self):
        for line in ("::error title=Hung test::CmuxNextAppTests: a() made no progress for 600s",
                     "::error title=Cancelled test::a() was stopped by SIGTERM",
                     "::error::command timed out after 1800s: swift test"):
            with self.subTest(line):
                shared = log("◇ Test run started.", failed("a()"), "✘ Test a() failed after 0.1 seconds with 1 issue.",
                             "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.", line)
                self.assertTrue(reds.classify(shared, log(failed("a()"), SUMMARY), "cmux-next swift test").own)

    def test_a_shell_reporting_a_killed_child_after_a_whole_run_is_a_crash(self):
        whole = ["◇ Test run started.", failed("a()"), "✘ Test a() failed after 0.1 seconds with 1 issue.",
                 "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue."]
        for line, signal in (("/tmp/run.sh: line 5: 1234 Killed                  ./helper", "9"),
                             ("/tmp/run.sh: line 5: 1234 Terminated: 15          ./helper", "15")):
            with self.subTest(line):
                verdict = reds.classify(log(*whole, line), log(*whole), "cmux-next swift test")
                self.assertTrue(verdict.own)
                self.assertIn(f"signal {signal}", verdict.reasons[0])

    def test_a_kill_inside_a_step_that_passed_is_not_a_crash(self):
        # cmuxterm-hq run 41195277420, Fleet tests (job 124520995516): scripts/test-reload-cloud-terminate-app.sh kills
        # the children it starts and passes; a later step's unittest fails the same way on the base. The step's
        # `Killed` lines read as "the test process crashed (signal 9)", so no red in the job was ever excused.
        killer = ["PASS: the quit is waited for, a second SIGTERM follows the timeout, and nothing is SIGKILLed",
                  "scripts/test-reload-cloud-terminate-app.sh: line 12: 34013 Killed                  perl -e 'sleep 300'",
                  "scripts/test-reload-cloud-terminate-app.sh: line 12: 34020 Killed                  \"$other_exe\" 300"]
        red = ["F.", "=" * 70, "FAIL: test_b (fleet_client_test.WaitTest.test_b)", "-" * 70, "Ran 2 tests in 0.1s", "",
               "FAILED (failures=1)", "##[error]Process completed with exit code 1."]
        job = log(*step("bash scripts/test-reload-cloud-terminate-app.sh"), *killer,
                  *step("python3 -m unittest discover -s build-fleet -p 'fleet_client_test.py'"), *red)
        self.assertEqual(reds.read(job).crashes, [])
        verdict = reds.classify(job, job, "Fleet tests")
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["test_b (fleet_client_test.WaitTest.test_b)"])
        # The same kill in the step that failed, or in the last step (it may be the one that died), is a crash.
        for job in (log(*step("python3 -m unittest"), *killer, *red),
                    log(*step("bash a.sh"), "ok", *step("python3 -m unittest"), *red[:-1], *killer),
                    log(*step("bash a.sh"), *killer, "::error::a.sh: the tagged app survived",
                        *step("python3 -m unittest"), *red)):
            with self.subTest(job=job[-200:]):
                verdict = reds.classify(job, job, "Fleet tests")
                self.assertTrue(verdict.own)
                self.assertIn("crashed (signal 9)", verdict.reasons[0])

    def test_a_fault_inside_a_step_that_passed_is_still_a_crash(self):
        # Only a signal someone sent is the step's own business; a segfault or SwiftPM's signal line is a crash.
        red = ["FAIL: test_b (m.T.test_b)", "Ran 1 test in 0.1s", "FAILED (failures=1)",
               "##[error]Process completed with exit code 1."]
        for line in ("run.sh: line 3: 4242 Segmentation fault      ./helper",
                     "error: exited with unexpected signal code 6"):
            with self.subTest(line):
                job = log(*step("bash run.sh"), line, *step("python3 -m unittest"), *red)
                verdict = reds.classify(job, job, "Fleet tests")
                self.assertTrue(verdict.own)
                self.assertIn("crashed", verdict.reasons[0])

    def test_a_tools_error_line_is_not_a_unittest_run(self):
        pip = log("ERROR: Could not find a version that satisfies the requirement foo")
        self.assertFalse(reds.read(pip).ran)
        self.assertIsNone(reds.classify(pip, pip, "cmux-next fast tier"))

    def test_a_webviews_file_the_wrapper_timed_out_or_bun_crashed_is_the_heads_own(self):
        timeout = log("START src/a.test.ts (hard limit 300s)", "TIMEOUT src/a.test.ts (limit 300s)")
        verdict = reds.classify(timeout, timeout, "web / react-apps-check (1)")
        self.assertTrue(verdict.own)
        self.assertIn("src/a.test.ts timed out", verdict.reasons[0])
        panic = log("START src/b.test.ts (hard limit 300s)", "panic(main thread): Segmentation fault at address 0x0",
                    "FAIL src/b.test.ts (limit 300s)")
        self.assertTrue(reds.classify(panic, panic, "web / react-apps-check (2)").own)
        for name in ("src/foo_test.ts", "src/foo_spec.tsx", "src/foo.spec.mjs"):
            with self.subTest(name):
                cut = log(f"START {name} (hard limit 300s)", f"TIMEOUT {name} (limit 300s)")
                self.assertTrue(reds.classify(cut, cut, "web / react-apps-check (4)").own)
        passing = log("START src/c.test.ts (hard limit 300s)", "PASS src/c.test.ts (raw log retained)")
        self.assertIsNone(reds.classify(passing, passing, "web / react-apps-check (3)"))

    def test_a_compile_job_that_prints_fatal_error_is_left_to_the_caller(self):
        compile_log = log("Fatal error: module map file not found")
        self.assertIsNone(reds.classify(compile_log, compile_log, "cmux app scheme compile (Debug)"))
        self.assertTrue(reds.classify(compile_log, compile_log, "cmux-next swift test").own)

    def test_crash_words_inside_a_test_result_line_are_not_a_crash_but_a_killed_helper_is(self):
        quoting = log("◇ Test run started.", "◇ Test t() started.",
                      '✘ Test t() recorded an issue at A.swift:1:2: Expectation failed: (m → "Terminating app due to '
                      'uncaught exception; Fatal Python error; EXC_GUARD") == "x"',
                      "✘ Test t() failed after 0.1 seconds with 1 issue.",
                      "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.")
        self.assertEqual(reds.read(quoting).crashes, [])
        self.assertTrue(reds.read(log("✔ Test a() perror: Process '/x/helper --a' exited with unexpected signal code 6"))
                        .crashes)

    def test_duplicate_names_odd_counts_and_other_frameworks_cut_short(self):
        dup = log("◇ Test run started.", "✔ Test foo() passed after 0.1 seconds.", "✔ Test foo() passed after 0.1 seconds.",
                  "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.")
        self.assertTrue(reds.read(dup).truncated)
        reds.read(log("✔ Test run with " + "9" * 5000 + " tests in 1 suite passed after 0.1 seconds."))
        for cut in (log("============================= test session starts ==============================",
                        "FAILED test_mod.py::test_x"), log("FAIL: test_x (mod.T.test_x)"),
                    log("test_a (mod.T.test_a) ... ok", "test_b (mod.T.test_b) ..."),
                    log("FAIL: test_old (mod.T.test_old)", "Ran 1 test in 0.001s", "FAILED (failures=1)",
                        "test_new (mod.T.test_new) ...")):
            with self.subTest(cut):
                self.assertTrue(reds.classify(cut, cut).own)

    def test_assertion_text_that_quotes_a_crash_or_a_hang_is_not_one(self):
        quoting = log("◇ Test run started.", "◇ Test parsesCrash() started.",
                      '✘ Test parsesCrash() recorded an issue at A.swift:1:2: Expectation failed: (message → '
                      '"EXC_BAD_ACCESS Fatal error: x never finished") == "other"',
                      "✘ Test parsesCrash() failed after 0.1 seconds with 1 issue.",
                      "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.")
        found = reds.read(quoting)
        self.assertEqual((found.crashes, found.truncated), ([], []))
        self.assertFalse(reds.classify(quoting, quoting).own)

    def test_a_hang_sampler_crash_with_no_report_and_a_shell_abort_count(self):
        for line in ("##[error]the test helper died on signal 6; crashed thread: no crash report from this run",
                     "/tmp/run.sh: line 5: 1234 Aborted (core dumped) cargo test",
                     "/tmp/run.sh: line 5: 1234 Abort trap: 6 ./helper", "/tmp/run.sh: line 5: 1234 Aborted ./helper",
                     "Fatal error: unexpected warning: bad input"):
            with self.subTest(line):
                self.assertTrue(reds.read(log(line)).crashes)

    def test_crash_words_in_a_test_argument_or_odd_symbols_do_not_crash_the_reader(self):
        start = '◇ Test case passing 1 argument text → "Fatal error: bad input" to parsesDiagnostic(text:) started.'
        self.assertFalse(reds.read(log(start, "✔ Test parsesDiagnostic(text:) passed after 0.1 seconds.")).crashes)
        self.assertIsNone(reds.demangle_test("$s5Tests0\u0130"))
        reds.read(log(ABORT, "  4 CmuxNextPackageTests 0x1 $s5Tests0\u0130 + 3"))

    def test_xctest_and_fatal_error_crashes_count(self):
        for line in ("Restarting after unexpected exit, crash, or test timeout in FooTests.testBar(); summary will "
                     "include totals from previous launches.",
                     "Fatal error: Unexpectedly found nil while unwrapping an Optional value",
                     "Thread 0 Crashed:: EXC_BAD_ACCESS (SIGSEGV)"):
            with self.subTest(line):
                self.assertTrue(reds.classify(log(line), log(line), "cmux-next swift test").own)


def health(fresh=(), known=(), slow=(), **extra):
    """A shard's health.json (scripts/gallery-matrix/health.ts): its broken states and its states over budget."""
    return json.dumps({"fresh": [{"state": s, "reason": r} for s, r in fresh],
                       "known": [{"state": s, "reason": r} for s, r in known], "fixed": [],
                       "slow": [{"state": s, "ms": ms, "budget": b} for s, ms, b in slow], "lower": [], **extra})


WAIT = "play: waitFor did not hold within 5000 ms"


class ReportedFailuresAreAllNamed(unittest.TestCase):
    """#41166's review F2: failed_tests recorded a runner's failure line as unnamed only when nothing at all was named,
    so one parsed name beside an unparsed failure read as fully identified. Each runner's summary is now set against the
    names that runner printed since its last summary (unnamed_failures)."""

    def unnamed(self, *lines):
        found: list = []
        reds.failed_tests(list(lines), found)
        return found

    def test_a_summary_counting_more_than_its_runner_named_is_unnamed(self):
        cases = {
            "cargo": ["test tests::a ... FAILED", "test src/lib.rs - f (line 3) ... FAILED",
                      "test result: FAILED. 0 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out"],
            "unittest": ["FAIL: test_a (pkg.Case.test_a)", "FAIL: [interrupted]", "Ran 2 tests in 0.010s",
                         "FAILED (failures=2)"],
            "pytest": ["FAILED tests/test_m.py::test_a - assert 0", "FAILED tests/test_m.py - setup broke",
                       "===== 2 failed in 0.12s ====="],
            "swift": ["✘ Test a() recorded an issue at A.swift:1:1: x", "✘ Test b recorded an issue at A.swift:2:1: x",
                      "✘ Test run with 2 tests in 1 suite failed after 0.1 seconds with 2 issues."],
            "bun": ["bun test v1.3.0", "test/a.test.ts:", "(fail) a > one [1.00ms]", " 0 pass", " 2 fail"],
            # Another runner's name never stands for this one's failure.
            "cargo beside swift": ["✘ Test a() recorded an issue at A.swift:1:1: x",
                                   "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.",
                                   "test result: FAILED. 0 passed; 1 failed; 0 ignored"],
            "xctest beside swift": ["✘ Test a() recorded an issue at A.swift:1:1: x",
                                    "Executed 1 test, with 1 failure (0 unexpected) in 0.1 (0.1) seconds"],
        }
        for runner, lines in cases.items():
            with self.subTest(runner=runner):
                self.assertTrue(self.unnamed(*lines), lines)

    def test_a_summary_whose_failures_are_all_named_is_not(self):
        cases = {
            "cargo": ["test tests::a ... FAILED", "test result: FAILED. 0 passed; 1 failed; 0 ignored"],
            "unittest": ["FAIL: test_a (pkg.Case.test_a)", "ERROR: test_b (pkg.Case.test_b)", "Ran 2 tests in 0.1s",
                         "FAILED (failures=1, errors=1)"],
            "pytest": ["FAILED tests/test_m.py::test_a - assert 0", "===== 1 failed, 1 rerun in 0.12s ====="],
            "swift": ["✘ Test a() recorded an issue at A.swift:1:1: x", "✘ Test a() recorded an issue at A.swift:2:1: y",
                      "✘ Test run with 3 tests in 1 suite failed after 0.1 seconds with 2 issues."],
            # The wrapper's retry is its own run: the first run's count is set against its own results.
            "bun retry": ["bun test v1.3.0", "test/a.test.ts:", "(fail) a > one [1.00ms]", "(fail) a > two [1.00ms]",
                          " 0 pass", " 2 fail", "--- retry, alone ---", "bun test v1.3.0", "test/a.test.ts:",
                          "(fail) a > one [1.00ms]", " 1 pass", " 1 fail"],
        }
        for runner, lines in cases.items():
            with self.subTest(runner=runner):
                self.assertEqual(self.unnamed(*lines), [])

    def test_the_recorded_fixtures_name_every_failure_they_report(self):
        for path in sorted(FIXTURES.glob("*.log")):
            with self.subTest(fixture=path.name):
                self.assertEqual(self.unnamed(*reds.lines_of(path.read_text())), [])


# One bun invocation of test/a.test.ts: RESULTS printed in the run, the recap (`N tests failed:`) of RECAP titles, and
# bun's ` N fail` count.
def bun_invocation(results=(), recap=(), fail=None):
    out = ["bun test v1.3.0", "test/a.test.ts:"]
    for title in results:
        out += ["error: expect(received).toBe(expected)", f"(fail) {title} [1.00ms]"]
    if recap:
        out += [f"{len(recap)} test{'s' if len(recap) != 1 else ''} failed:", *(f"(fail) {t}" for t in recap)]
    return out + [" 0 pass", f" {len(results) if fail is None else fail} fail"]


class UnnamedFailuresAreReadOnceForEveryConsumer(unittest.TestCase):
    """#41222's review, earlier F1: "Move the refusal into the shared path every consumer goes through ... Cover each
    entry point (classify, read, expand_job)". read() records a failure no parser names (Result.unnamed) and calls
    its per-test results not whole, so classify, classify_any, judge()'s read_head and next_batch's expand_job all
    refuse it from the one reading."""

    CARGO = ["running 2 tests", "test tests::reconnects ... FAILED", "test src/lib.rs - parse (line 3) ... FAILED",
             "test result: FAILED. 0 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"]

    def test_read_says_the_results_are_not_whole(self):
        found = reds.read(log(*self.CARGO))
        self.assertEqual(found.unnamed, [self.CARGO[-1]])
        self.assertTrue(any("more failing tests than it names" in why for why in found.truncated), found.truncated)
        named = [line for line in self.CARGO if "src/lib.rs" not in line]
        named[-1] = named[-1].replace("2 failed", "1 failed")
        self.assertEqual((reds.read(log(*named)).unnamed, reds.read(log(*named)).truncated), ([], []))

    def test_classify_calls_it_the_heads_own_whatever_the_base(self):
        verdict = reds.classify(log(*self.CARGO), log(*self.CARGO), "cmux-next rust tests")
        self.assertTrue(verdict.own)
        self.assertIn("more failing tests than it names", "; ".join(verdict.reasons))
        verdict = reds.classify_any(log(*self.CARGO), [("base run 1", log(*self.CARGO)),
                                                      ("base run 2", log(*self.CARGO))], "cmux-next rust tests")
        self.assertTrue(verdict.own)

    def test_bun_is_read_by_the_same_reading(self):
        lines = bun_invocation(results=["a > one"], fail=2)
        self.assertEqual(reds.read(log(*lines)).unnamed, [" 2 fail"])
        self.assertTrue(reds.classify(log(*lines), log(*lines), "web tests").own)


class BunCountsTheIdentitiesItKeeps(unittest.TestCase):
    """#41222's review F1 (test_reds.py:508): "Two identical `(fail)` recap entries followed by `2 fail` produce one
    identity because `read_bun` deduplicates them, but `recap == 2` prevents an unnamed marker." The count is set
    against the failures read_bun keeps, never the recap's lines. And at 6719ba22: "Count identities with
    multiplicity: a name failing twice is 2." A recap title counts as often as the recap lists it, less the results
    of its run that named it."""

    def unnamed(self, lines):
        return reds.unnamed_failures(lines)

    def test_two_recap_lines_of_one_title_are_two_failures_of_it(self):
        lines = bun_invocation(recap=["a > one", "a > one"], fail=2)
        found = reds.Result()
        reds.read_bun(lines, found)
        self.assertEqual(found.counts, Counter({"a > one": 2}))
        self.assertEqual(self.unnamed(lines), [])
        self.assertEqual(reds.read(log(*lines)).truncated, [])
        # A count above what the recap names is still unnamed.
        self.assertEqual(self.unnamed(bun_invocation(recap=["a > one", "a > one"], fail=3)), [" 3 fail"])

    def test_a_recap_that_repeats_the_results_names_them_once_each(self):
        for lines, counts in (
                (bun_invocation(results=["a > one", "a > two"], recap=["a > one", "a > two"]),
                 {"test/a.test.ts > a > one": 1, "test/a.test.ts > a > two": 1}),
                (bun_invocation(results=["a > one", "a > one"], recap=["a > one", "a > one"]),
                 {"test/a.test.ts > a > one": 2}),
                (bun_invocation(results=["a > one"], recap=["a > one", "a > two"], fail=2),
                 {"test/a.test.ts > a > one": 1, "a > two": 1}),
                (bun_invocation(recap=["a > one", "a > two"], fail=2), {"a > one": 1, "a > two": 1})):
            with self.subTest(lines=lines):
                found = reds.Result()
                reds.read_bun(lines, found)
                self.assertEqual(found.counts, Counter(counts))
                self.assertEqual(self.unnamed(lines), [])



class RetryDropsEveryKindOfItsAttempt(unittest.TestCase):
    """#41329's review F1: "recap_failures() records bare titles, but retry cleanup removes only file-prefixed
    identities. Two attempts that each recap `a > one` count it twice ... Class: a retry merge that drops only one of
    an attempt's record kinds." And its follow-up F1 (test_reds.py:737): "retry cleanup removes only `file > title`
    failures, while recap failures are stored as bare titles, so a superseded first run stays charged after a passing
    retry. Store every failure, recap or named, under one identity that carries its file and attempt, and drop by
    attempt." Each kind read_bun keeps goes with its attempt (BunAttempt): named failures, counts, diagnostics,
    passes, ` N fail` markers, recap-only titles, an unhandled error named before its file's header, and whether the
    attempt named anything at all."""

    RETRY = "--- retry, alone ---"

    def read(self, *lines):
        found = reds.Result()
        reds.read_bun(list(lines), found)
        return found

    def test_recap_only_titles_of_the_superseded_attempt_go(self):
        attempt = bun_invocation(recap=["a > one"], fail=1)
        found = self.read(*attempt, self.RETRY, *attempt)
        self.assertEqual((found.counts, found.unnamed), (Counter({"a > one": 1}), []))

    def test_a_superseded_recap_failure_is_not_charged_after_a_passing_retry(self):
        found = self.read(*bun_invocation(recap=["a > one"], fail=1), self.RETRY, *bun_invocation())
        self.assertEqual((found.failed, found.counts, found.unnamed), (set(), Counter(), []))
        self.assertEqual(found.records, [])

    def test_an_unhandled_error_before_the_files_header_goes_with_its_attempt(self):
        first = ["bun test v1.3.0", "# Unhandled error between tests", "-------------------------------",
                 "error: listen EADDRINUSE", "-------------------------------", "test/a.test.ts:",
                 "error: expect(received).toBe(expected)", "(fail) a > one [1.00ms]", " 0 pass", " 2 fail"]
        retry = bun_invocation(results=["a > one"])
        self.assertIn("unhandled error: listen EADDRINUSE", self.read(*first).failed)
        found = self.read(*first, self.RETRY, *retry)
        self.assertEqual((found.failed, found.unnamed), ({"test/a.test.ts > a > one"}, []))

    def test_a_superseded_attempts_named_failure_never_names_the_retry(self):
        # The retry failed with nothing named (no `(fail)`, ` 0 fail`): the wrapper's `FAIL file` line is unnamed,
        # whatever the superseded attempt named.
        lines = [*bun_invocation(results=["a > one"]), self.RETRY, "bun test v1.3.0", "test/a.test.ts:",
                 "error: Cannot find module './gone'", " 0 pass", " 0 fail", "FAIL test/a.test.ts (limit 120s)"]
        self.assertEqual(reds.unnamed_failures(lines), ["FAIL test/a.test.ts (limit 120s)"])

    def test_every_record_carries_its_step_and_attempt(self):
        found = reds.read(log(*step("bun test a"), *bun_invocation(results=["a > one"]),
                              "##[error]Process completed with exit code 1.",
                              *step("bun test b"), *bun_invocation(recap=["b > two"], fail=2),
                              "##[error]Process completed with exit code 1."))
        self.assertEqual(found.records, [(1, 1, "failed", "test/a.test.ts > a > one"), (2, 1, "failed", "b > two"),
                                         (2, 1, "unnamed", " 2 fail")])


class BunStateStaysInItsStep(unittest.TestCase):
    """#41329's review follow-up F2 (test_reds.py:751): "a `(fail)` from a passing step sets the global any_named,
    which hides a later failed step's fallback `FAIL file` markers, so an unnamed failed file goes missing from
    `unnamed`. Keep that state per step or invocation, not global." A step that passed is read by no reader
    (red_lines); here a failed step's named failure must not name another failed step's file either."""

    def test_a_named_failure_in_one_failed_step_never_names_anothers_fail_file(self):
        named = [*step("bun test a"), *bun_invocation(results=["a > one"]),
                 "##[error]Process completed with exit code 1."]
        unnamed = [*step("bash scripts/run-webviews-tests.sh"), "FAIL test/b.test.ts (exit 1)",
                   "##[error]Process completed with exit code 1."]
        found = reds.read(log(*named, *unnamed))
        self.assertEqual(found.unnamed, ["FAIL test/b.test.ts (exit 1)"])
        unnamed_list: list = []
        reds.failed_in(log(*named, *unnamed), unnamed_list)
        self.assertEqual(unnamed_list, ["FAIL test/b.test.ts (exit 1)"])


class PassingStepsPrintNoUnnamedFailure(unittest.TestCase):
    """#41244's review F1: "read_bun keeps unnamed markers from passing steps, so a passing negative-case step printing
    "(fail)" and "2 fail" makes judge() refuse an unrelated inherited red." A step that passed (passed_steps) prints no
    red's marker."""

    def test_a_passing_steps_bun_count_is_not_unnamed(self):
        passing = ["##[group]Run bun test test/negative.test.ts", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
                   *bun_invocation(results=["a > one"], fail=2)]
        failing = ["##[group]Run cargo test", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
                   "test tests::reconnects ... FAILED",
                   "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out",
                   "##[error]Process completed with exit code 101."]
        found = reds.read(log(*passing, *failing))
        self.assertEqual((found.unnamed, found.truncated), ([], []))
        # Printed by the failed step, the same count is the red's own.
        found = reds.read(log(*failing[:3], *bun_invocation(results=["a > one"], fail=2), *failing[3:]))
        self.assertEqual(found.unnamed, [" 2 fail"])



class NoReaderSeesAPassingStepsLines(unittest.TestCase):
    """#41244's review F1: "parse_log() hands every line to read_bun() before the passing-step filter, so a Bun
    Result.unnamed marker from a passing step (one `(fail)` plus `2 fail`) marks the whole job truncated, and
    read_head() can then refuse an unrelated red. Apply the step filter before every reader, not inside each one.
    Fixture: a passing Bun step with those markers next to a failing step." parse_log filters the lines once
    (red_lines); failed_tests' callers read the same source."""

    PASSING = ["##[group]Run bun test test/negative.test.ts", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
               *bun_invocation(results=["a > one"], fail=2)]
    FAILING = ["##[group]Run cargo test", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
               "test tests::reconnects ... FAILED",
               "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out",
               "##[error]Process completed with exit code 101."]

    def test_a_passing_bun_steps_fail_and_count_are_no_readers(self):
        job = log(*self.PASSING, *self.FAILING)
        found = reds.read(job)
        self.assertEqual((found.failed, found.unnamed, found.truncated), ({"tests::reconnects"}, [], []))
        unnamed: list = []
        self.assertEqual(reds.failed_tests(reds.red_lines(job), unnamed), Counter({"tests::reconnects": 1}))
        self.assertEqual(unnamed, [])
        # A base that fails only the cargo test fails the same way: the passing step's `(fail)` is no new failure.
        base = log(*self.FAILING)
        verdict = reds.classify(job, base, "web / tests")
        self.assertFalse(verdict.own, verdict.reasons)

    def test_a_passing_steps_named_bun_failure_does_not_hide_a_failing_steps_unnamed_one(self):
        # The wrapper's `FAIL file` with no bun line naming a failure is unnamed; a `(fail)` a passing step printed
        # named nothing of this red, so it is still unnamed.
        failing = ["##[group]Run bash scripts/run-webviews-tests.sh", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
                   "FAIL test/b.test.ts (exit 1)", "##[error]Process completed with exit code 1."]
        found = reds.read(log(*self.PASSING, *failing))
        self.assertEqual(found.unnamed, ["FAIL test/b.test.ts (exit 1)"])
        self.assertEqual(found.failed, set())


class BunRetrySupersedesItsCount(unittest.TestCase):
    """#41222's review F2 (test_reds.py:493): "The wrapper retry resets counters but retains earlier unnamed markers in
    `found`. ... Apply the same final-attempt rule to unnamed markers". The attempt run-webviews-tests.sh ran again
    alone is dropped with its count, as read_bun drops its failures."""

    def test_a_fully_named_retry_supersedes_an_unnamed_first_attempt(self):
        lines = bun_invocation(results=["a > one"], fail=2) + ["--- retry, alone ---"] + bun_invocation(results=["a > one"])
        self.assertEqual(reds.unnamed_failures(lines), [])
        found = reds.read(log(*lines))
        self.assertEqual((found.unnamed, found.truncated, found.failed), ([], [], {"test/a.test.ts > a > one"}))

    def test_an_unnamed_retry_is_still_unnamed(self):
        lines = bun_invocation(results=["a > one"]) + ["--- retry, alone ---"] + bun_invocation(results=["a > one"], fail=2)
        self.assertEqual(reds.unnamed_failures(lines), [" 2 fail"])

    def test_another_files_unnamed_run_is_kept(self):
        other = [line.replace("test/a.test.ts", "test/b.test.ts") for line in bun_invocation(results=["b > x"], fail=2)]
        lines = other + bun_invocation(results=["a > one"], fail=2) + ["--- retry, alone ---"] + bun_invocation(results=["a > one"])
        self.assertEqual(reds.unnamed_failures(lines), [" 2 fail"])


class GalleryHealth(unittest.TestCase):
    """Gallery health's broken and over-budget states, judged per state against the same states rendered on the base
    (gallery-health.yml): the base entries that held SHIP'd webview PRs (streaming-text#jump-during-stream over budget,
    narrow#model-menu and model-picker#many-harnesses never reaching their state) are warnings, nothing else is."""

    # Base run 40777215289 (feat-cmux-next 4e1a84f9), shards 0, 2 and 3.
    BASE = health(fresh=[("agent-pane.empty-state#search", WAIT), ("agent-pane.narrow#model-menu", WAIT),
                         ("agent-pane.model-picker#many-harnesses", WAIT)],
                  slow=[("agent-pane.streaming-text#jump-during-stream", 17342, 2000)])

    def test_states_broken_the_same_way_on_the_base_are_the_bases(self):
        head = health(fresh=[("agent-pane.narrow#model-menu", WAIT)],
                      slow=[("agent-pane.streaming-text#jump-during-stream", 16890, 2000)])
        verdict = reds.gallery_classify(head, self.BASE, "feat-cmux-next 4e1a84f9")
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["agent-pane.narrow#model-menu: " + WAIT.replace("5000", "#"),
                                          "agent-pane.streaming-text#jump-during-stream: over its ready-time budget"])

    def test_a_state_the_allowlist_names_on_the_base_counts_as_broken_there(self):
        verdict = reds.gallery_classify(health(fresh=[("a.b#c", WAIT)]), health(known=[("a.b#c", WAIT)]))
        self.assertFalse(verdict.own, verdict.reasons)

    def test_a_state_the_base_renders_is_the_heads_own(self):
        head = health(fresh=[("agent-pane.narrow#model-menu", WAIT), ("agent-pane.composer#new", WAIT)])
        verdict = reds.gallery_classify(head, self.BASE)
        self.assertTrue(verdict.own)
        self.assertIn("agent-pane.composer#new", verdict.reasons[0])
        self.assertNotIn("narrow", verdict.reasons[0])

    def test_a_state_broken_another_way_on_the_base_is_the_heads_own(self):
        # The base reaches the state slowly; the head never reaches it: another red.
        base = health(slow=[("a.b#c", 4000, 2000)])
        self.assertTrue(reds.gallery_classify(health(fresh=[("a.b#c", WAIT)]), base).own)
        self.assertTrue(reds.gallery_classify(health(slow=[("a.b#c", 4000, 2000)]), health(fresh=[("a.b#c", WAIT)])).own)
        thrown = health(fresh=[("a.b#c", "play threw: no tray")])
        self.assertTrue(reds.gallery_classify(thrown, health(fresh=[("a.b#c", "play threw: no rows")])).own)
        # Any budget miss is the same red, however far over; the numbers in a reason are not its kind.
        self.assertFalse(reds.gallery_classify(health(slow=[("a.b#c", 9000, 2000)]), base).own)
        within = health(fresh=[("a.b#c", "play: waitFor did not hold within 3000 ms")])
        self.assertFalse(reds.gallery_classify(within, health(fresh=[("a.b#c", WAIT)])).own)

    def test_a_state_past_its_shift_baseline_is_red_and_the_base_can_share_it(self):
        shifted = [{"state": "agent-pane.tool-expand#bottom", "score": 0.02, "baseline": 0, "moves": []}]
        head = health(shifted=shifted)
        self.assertTrue(reds.gallery_classify(head, health()).own)
        self.assertFalse(reds.gallery_classify(head, health(shifted=shifted)).own)
        self.assertEqual(reds.gallery_entries(head), ["agent-pane.tool-expand"])
        # A base checker from before the shift gate wrote no `shifted` list: it still reads as whole.
        self.assertIsNone(reds.gallery_classify(health(), health()))

    def test_a_geometry_break_is_red_per_violation_and_the_base_can_share_it(self):
        broke = [{"state": "agent-pane.transcript#worked", "violations": [{"rule": "icon-column", "key": "icon-column:row r1", "detail": "x"}]}]
        head = health(geometry=broke)
        self.assertTrue(reds.gallery_classify(head, health()).own)
        self.assertFalse(reds.gallery_classify(head, health(geometry=broke)).own)
        other = [{"state": "agent-pane.transcript#worked", "violations": [{"rule": "icon-column", "key": "icon-column:row r2", "detail": "x"}]}]
        self.assertTrue(reds.gallery_classify(head, health(geometry=other)).own)

    def test_a_crashed_render_is_never_the_bases(self):
        crashed = health(fresh=[("a.b#c", "did not render: page.goto: Target crashed")])
        verdict = reds.gallery_classify(crashed, crashed)
        self.assertTrue(verdict.own)
        self.assertIn("crashed", verdict.reasons[0])

    def test_a_cut_short_or_unreadable_head_is_never_the_bases(self):
        for head in (None, "", "{not json", json.dumps({"error": "gallery health could not render: browser launch"}),
                     json.dumps({"fresh": []})):
            with self.subTest(head=head):
                verdict = reds.gallery_classify(head, self.BASE)
                self.assertTrue(verdict.own)
                self.assertIn("per-state results are not whole", verdict.reasons[0])

    def test_no_base_or_a_cut_short_base_excuses_nothing(self):
        head = health(fresh=[("agent-pane.narrow#model-menu", WAIT)])
        for base in (None, "", json.dumps({"error": "gallery health could not render: browser launch"})):
            with self.subTest(base=base):
                verdict = reds.gallery_classify(head, base)
                self.assertTrue(verdict.own)
                self.assertIn("no whole base result", verdict.reasons[-1])

    def test_a_head_with_nothing_red_is_not_a_gallery_red(self):
        self.assertIsNone(reds.gallery_classify(health(known=[("a.b#c", WAIT)]), None))

    def test_the_entries_to_replay_are_the_heads_red_entries(self):
        head = health(fresh=[("agent-pane.narrow#model-menu", WAIT), ("agent-pane.narrow#effort", WAIT)],
                      slow=[("agent-pane.streaming-text#jump-during-stream", 17342, 2000)], known=[("x.y#z", WAIT)])
        self.assertEqual(reds.gallery_entries(head), ["agent-pane.narrow", "agent-pane.streaming-text"])

    def test_a_state_red_in_any_base_render_is_the_bases(self):
        head = health(shifted=[{"state": "a.b#c", "score": 0.08, "limit": 0.05}])
        self.assertTrue(reds.gallery_classify(head, [health(), health()]).own)
        self.assertFalse(reds.gallery_classify(head, [health(), health(shifted=[{"state": "a.b#c"}])]).own)
        # Any base render with no verdict leaves nothing excused.
        self.assertTrue(reds.gallery_classify(head, [health(shifted=[{"state": "a.b#c"}]), None]).own)

    def test_the_base_replays_only_the_heads_red_states(self):
        # Replaying whole entries re-rendered 1,308 cases for one shard's ~40 red states and ran past the job's timeout.
        head = health(fresh=[("agent-pane.narrow#model-menu", WAIT), ("agent-pane.narrow#effort", WAIT)],
                      slow=[("agent-pane.streaming-text#jump-during-stream", 17342, 2000)], known=[("x.y#z", WAIT)])
        self.assertEqual(reds.gallery_states(head), ["agent-pane.narrow#effort", "agent-pane.narrow#model-menu",
                                                     "agent-pane.streaming-text#jump-during-stream"])

    def test_the_command_line_warns_on_base_reds_and_fails_on_its_own(self):
        with tempfile.TemporaryDirectory() as tmp:
            head, base = Path(tmp, "head.json"), Path(tmp, "base.json")
            base.write_text(self.BASE)
            run = lambda *args: subprocess.run([sys.executable, str(ROOT / "scripts/ci/test_reds.py"), "gallery",
                                                "--head", str(head), *args], capture_output=True, text=True)
            head.write_text(health(fresh=[("agent-pane.narrow#model-menu", WAIT)]))
            found = run("--entries")
            self.assertEqual((found.returncode, found.stdout.strip()), (0, "agent-pane.narrow"))
            found = run("--states")
            self.assertEqual((found.returncode, found.stdout.strip()), (0, "agent-pane.narrow#model-menu"))
            found = run("--base", str(base), "--annotate")
            self.assertEqual(found.returncode, 0, found.stdout + found.stderr)
            self.assertIn("::warning title=gallery health: base red::agent-pane.narrow#model-menu", found.stdout)
            head.write_text(health(fresh=[("agent-pane.composer#new", WAIT)]))
            found = run("--base", str(base), "--annotate")
            self.assertEqual(found.returncode, 1)
            self.assertIn("::error title=gallery health::", found.stdout)
            # A crash needs no replay: it is the head's whatever the base shows.
            head.write_text(health(fresh=[("a.b#c", "did not render: Target crashed")]))
            self.assertEqual(run("--entries").returncode, 1)
            self.assertEqual(run("--states").returncode, 1)
            head.write_text(health())
            self.assertEqual(run("--entries").returncode, 2)
            head.unlink()
            self.assertEqual(run("--base", str(base)).returncode, 1)


class Demangle(unittest.TestCase):
    def test_a_word_substituted_test_name(self):
        self.assertEqual(reds.demangle_test("$s16CmuxNextAppTests015HomeTypeToFocusD0V05aPaneh19ShortcutFromAnotherI21"
                                            "ThenTypingFillsTheBoxyyAC9ContainerOYaKFTQ0_"),
                         ("HomeTypeToFocusTests", "aPaneFocusShortcutFromAnotherPaneThenTypingFillsTheBox"))

    def test_a_literal_test_name(self):
        self.assertEqual(reds.demangle_test("$s16CmuxNextAppTests015HomeChiefRosterD0V35noSegmentedControlFloatsOver"
                                            "TheChatyyF"), ("HomeChiefRosterTests", "noSegmentedControlFloatsOverTheChat"))

    def test_a_frame_outside_a_tests_module_is_not_a_test(self):
        self.assertIsNone(reds.demangle_test("$s12CmuxNextHome0C12FirstRunViewC12applySpacing"))



def web_job(*files, summary=True):
    """A webview test job log (run-webviews-tests.sh): each file is (name, [(test, error, line) or (test, None)])."""
    lines = []
    for name, tests in files:
        lines.append(f"##[group]FAIL {name}")
        lines.append("--- first run: FAIL ---")
        for test, *rest in tests:
            error, at = (rest + [None, None])[:2]
            if error:
                lines += [f"error: {error}", "", f"      at <anonymous> (/home/runner/_work/cmux/cmux/webviews/{name}:{at}:22)"]
            lines.append(f"(fail) {test} [12.00ms]")
        lines.append("##[endgroup]")
    lines.append(f"### webviews tests: 295 files, {len(files)} failed or timed out")
    if summary:
        lines += [f"FAIL {name} (limit 120s)" for name, _ in files]
    return log(*lines)


def replay(charged=(), shared=()):
    """react-apps-base-check's log: guards_new_reds.py's verdicts on the head's reds replayed on the merge parent."""
    return log(*[f"##[error]{name}" for name in charged], *[f"##[warning]{name}" for name in shared],
               f"{len(charged)} webview test steps red on this change, {len(shared)} red on the base too, 0 flaky on the base, "
               "0 fixed")


CAPSULES = "test/agent-pane-no-capsules.test.ts"
CAPSULE_TEST = "agent pane page > rounds its controls as small-radius rects, not capsules"
CAPSULE_ERROR = "expect(received).toBe(expected)"


class WebviewTestsAcrossJobs(unittest.TestCase):
    """2026-10-29: agent-pane-no-capsules was red on feat-cmux-next as `react-apps-check (1)` and on a PR as
    `react-apps-base-check (4)`; a per-job comparison could never match the two names. A webview test is judged by its
    file, title and error across every job that ran it."""

    def test_a_replay_red_the_base_shares_in_another_shard_is_the_base(self):
        head_shard = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))  # react-apps-check (3) on the head
        base_shard = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))  # react-apps-check (1) on the base
        verdict = reds.classify_web([replay(charged=[f"{CAPSULES} > {CAPSULE_TEST}"]), head_shard], [base_shard],
                                    "react-apps-base-check (4)", "feat-cmux-next")
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, [f"{CAPSULES} > {CAPSULE_TEST}"])

    def test_the_same_test_failing_differently_on_the_base_is_its_own(self):
        head_shard = web_job((CAPSULES, [(CAPSULE_TEST, "expect(received).toEqual(expected)", 140)]))
        base_shard = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        verdict = reds.classify_web([replay(charged=[f"{CAPSULES} > {CAPSULE_TEST}"]), head_shard], [base_shard])
        self.assertTrue(verdict.own)
        self.assertIn("fail differently", verdict.reasons[0])

    def test_a_test_only_the_head_fails_is_its_own_and_one_shared_test_excuses_nothing_else(self):
        other = "test/composer-footer-plain.test.ts"
        head_shard = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]), (other, [("rests flat", CAPSULE_ERROR, 9)]))
        base_shard = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        verdict = reds.classify_web([replay(charged=[f"{CAPSULES} > {CAPSULE_TEST}", f"{other} > rests flat"]),
                                     head_shard], [base_shard])
        self.assertTrue(verdict.own)
        self.assertIn("composer-footer-plain", verdict.reasons[0])

    def test_a_head_shard_red_matches_the_base_in_another_shard(self):
        verdict = reds.classify_web([web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))],
                                    [web_job(("test/x.test.ts", [("x", "boom", 1)])),
                                     web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))])
        self.assertFalse(verdict.own, verdict.reasons)

    def test_an_error_read_on_one_side_only_or_a_timeout_or_no_base_is_its_own(self):
        named = f"{CAPSULES} > {CAPSULE_TEST}"
        no_error = web_job((CAPSULES, [(CAPSULE_TEST, None)]))
        with_error = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        self.assertTrue(reds.classify_web([replay(charged=[named]), no_error], [with_error]).own)
        timed = log(f"##[group]TIMEOUT {CAPSULES}", "##[endgroup]", "### webviews tests: 1 files",
                    f"TIMEOUT {CAPSULES} (limit 120s)")
        verdict = reds.classify_web([timed], [timed])
        self.assertTrue(verdict.own)
        self.assertIn("timed out", verdict.reasons[0])
        self.assertTrue(reds.classify_web([with_error], []).own)
        self.assertTrue(reds.classify_web([with_error], [None]).own)
        self.assertTrue(reds.classify_web([None], [with_error]).own)

    def test_assertion_values_are_part_of_the_error(self):
        head = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR + "\nExpected: 3\nReceived: 9", 87)]))
        base = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR + "\nExpected: 3\nReceived: 4", 87)]))
        self.assertTrue(reds.classify_web([head], [base]).own)

    def test_an_unnamed_file_failure_needs_a_matching_error(self):
        def unloadable(error):
            return log(f"##[group]FAIL {CAPSULES}", f"error: {error}", "##[endgroup]",
                       "### webviews tests: 1 files, 1 failed or timed out", f"FAIL {CAPSULES} (limit 120s)")
        self.assertTrue(reds.classify_web([unloadable("missing export foo")],
                                          [unloadable("missing export bar")]).own)
        self.assertTrue(reds.classify_web([unloadable("")], [unloadable("")]).own)
        self.assertFalse(reds.classify_web([unloadable("missing export foo")],
                                           [unloadable("missing export foo")]).own)

    def test_crashes_and_cut_short_logs_are_never_shared(self):
        shared = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        for broken in (shared + "\n2026-10-28T03:40:35Z Segmentation fault (core dumped)",
                       shared.split("### webviews tests:")[0],
                       shared.replace("##[endgroup]", "... output truncated; complete log retained ...\n##[endgroup]")):
            with self.subTest(log=broken):
                self.assertTrue(reds.classify_web([broken], [broken]).own)

    def test_replay_cannot_excuse_a_crashed_head_shard(self):
        head = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        head += "\n2026-10-28T03:40:35Z oh no: Bun has crashed"
        verdict = reds.classify_web([replay(charged=[f"{CAPSULES} > {CAPSULE_TEST}"]), head], [head])
        self.assertTrue(verdict.own)

    def test_a_replay_names_only_its_head_rerun_and_final_verdict(self):
        # cmux#34111's replay (2): the merge parent timed out a file; the head re-run then passed one charged test.
        named, again = f"{CAPSULES} > {CAPSULE_TEST}", "test/composer-footer-plain.test.ts > rests flat"
        merge_parent = log("##[group]TIMEOUT test/transcript-toggle.test.ts", "##[endgroup]",
                           "### webviews tests: 1 files", "TIMEOUT test/transcript-toggle.test.ts (limit 120s)")
        text = "\n".join([merge_parent, replay(charged=[named, again]), log("re-running alone on the head:"),
                          web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)])),
                          replay(charged=[named], shared=[again])])
        found = reds.web_failures(text)
        self.assertEqual(found.charged, {named})
        self.assertEqual(found.timed_out, set())
        self.assertNotIn("transcript-toggle", "".join(reds.read(reds.web_head_part(text)).truncated))
        self.assertIn("transcript-toggle", "".join(reds.read(text).truncated))
        self.assertFalse(reds.classify_web_window(
            [text, web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))],
            iter([("base run 1", [web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))])])).own)
        # A replay with no head re-run holds no run of the head.
        self.assertEqual(reds.web_head_part("\n".join([merge_parent, replay(charged=[named])])), "")
        self.assertEqual(reds.web_failures("\n".join([merge_parent, replay(charged=[named])])).timed_out, set())

    def test_a_replay_compares_only_what_its_final_verdict_charged_in_a_shared_file(self):
        # Review F2 on #38380: the head failed A and B in one file; the final verdict charged A only (B passed alone).
        # B is not compared, so the base failing A alone excuses the replay; an unnamed diagnostic there still counts.
        a, b = f"{CAPSULES} > {CAPSULE_TEST}", f"{CAPSULES} > rests flat"
        head = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87), ("rests flat", "boom", 9)]))
        text = "\n".join([replay(charged=[a, b]), log("re-running alone on the head:"),
                          web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)])), replay(charged=[a], shared=[b])])
        base = [web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))]
        self.assertFalse(reds.classify_web_window([text, head], iter([("run 1", base)])).own)
        self.assertFalse(reds.classify_web([text, head], base).own)
        unhandled = head.replace("### webviews tests:", f"##[group]FAIL {CAPSULES}\nerror: thrown outside a test\n"
                                 "##[endgroup]\n### webviews tests:")
        self.assertTrue(reds.classify_web_window([text, unhandled], iter([("run 1", base)])).own)

    def test_a_replay_with_no_final_charged_test_verdict_is_never_judged_per_test(self):
        # Review follow-up (1) on #38380: the head re-run ended (cut short, or its compare never ran) before
        # guards_new_reds.py printed the final verdict. The failures it printed are no charged-test verdict: the
        # replay is the head's own, never compared with the base per test.
        named = f"{CAPSULES} > {CAPSULE_TEST}"
        rerun = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        base = [web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))]
        whole = "\n".join([replay(charged=[named]), log("re-running alone on the head:"), rerun,
                           replay(charged=[named])])
        self.assertFalse(reds.classify_web_window([whole, rerun], iter([("run 1", base)])).own)
        for cut in ("\n".join([replay(charged=[named]), log("re-running alone on the head:"), rerun]),
                    "\n".join([replay(charged=[named]), log("re-running alone on the head:"), rerun,
                               log(f"##[error]{named}")]),
                    "\n".join([log(f"##[error]{named}"), log("re-running alone on the head:"), rerun,
                               replay(charged=[named])]).replace("1 webview test steps red", "webview test steps red")):
            with self.subTest(log=cut[-120:]):
                found = reds.web_failures(cut)
                self.assertIn("no final charged-test verdict", " ".join(found.truncated))
                verdict = reds.classify_web_window([cut, rerun], iter([("run 1", base)]))
                self.assertTrue(verdict.own)
                self.assertIn("no final charged-test verdict", " ".join(verdict.reasons))
        # A replay with no head re-run needs its one verdict line too.
        self.assertIn("no final charged-test verdict", " ".join(reds.web_failures(log(f"##[error]{named}")).truncated))
        self.assertEqual(reds.web_failures(replay(charged=[named])).truncated, [])

    def test_a_cut_off_final_verdict_line_is_no_verdict(self):
        # Review F1 on #38434: a log cut off right after "red on the base too" printed no whole closing line.
        named = f"{CAPSULES} > {CAPSULE_TEST}"
        whole = "1 webview test steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"
        for line, cut in ((whole, False),
                          ("1 webview test steps red on this change, 0 red on the base too, 0 fixed", False),
                          ("1 webview test steps red on this change, 0 red on the base too", True),
                          ("1 webview test steps red on this change, 0 red on the base too, 0 flaky on the base", True),
                          ("1 webview test steps red on this change, 0 red on the base too, 0 flaky on the base, 0", True),
                          (whole + ", 2 more", True)):
            with self.subTest(line=line):
                found = reds.web_failures(log(f"##[error]{named}", line))
                self.assertEqual("no final charged-test verdict" in " ".join(found.truncated), cut)

    def test_a_window_matches_each_test_on_any_one_run_and_reads_no_further(self):
        other = "test/composer-footer-plain.test.ts"
        head = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]), (other, [("rests flat", "boom", 9)]))
        read = []

        def windows():
            for label, logs in (("run 3", [web_job((CAPSULES, [(CAPSULE_TEST, "other error", 87)]))]),
                                ("run 2", [web_job((other, [("rests flat", "boom", 9)]))]),
                                ("run 1", [web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))]),
                                ("run 0", [None])):
                read.append(label)
                yield label, logs
        verdict = reds.classify_web_window([head], windows())
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(read, ["run 3", "run 2", "run 1"])
        verdict = reds.classify_web_window([head], iter([("run 3", [web_job((CAPSULES, [(CAPSULE_TEST, "x", 87)]))])]))
        self.assertTrue(verdict.own)
        self.assertIn("1 failing test(s) pass or do not run on run 3: test/composer-footer-plain.test.ts > rests flat",
                      verdict.reasons)
        self.assertTrue(any("fail on none of run 3 the same way" in reason for reason in verdict.reasons))
        self.assertTrue(reds.classify_web_window([head], iter([])).own)

    def test_retry_only_failure_cannot_be_excused_by_the_first_attempt(self):
        head = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        head = head.replace("##[endgroup]", "--- retry, alone ---\nerror: new retry failure\n(fail) " + CAPSULE_TEST + "\n##[endgroup]")
        base = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        self.assertTrue(reds.classify_web([head], [base]).own)

    def test_another_head_job_cannot_overwrite_the_red_jobs_diagnostic(self):
        own = web_job((CAPSULES, [(CAPSULE_TEST, "new failure", 87)]))
        shared = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        self.assertTrue(reds.classify_web([own, shared], [shared]).own)

    def test_a_started_webview_file_without_results_is_cut_short(self):
        broken = log(f"START {CAPSULES} (hard limit 120s)")
        verdict = reds.classify_web([broken], [broken])
        self.assertIsNotNone(verdict)
        self.assertTrue(verdict.own)

    def test_a_later_invocation_needs_its_own_completion(self):
        shared = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        later = shared + "\n" + log("START test/other.test.ts (hard limit 120s)")
        self.assertTrue(reds.classify_web([later], [later]).own)
        later += "\n" + log("PASS test/other.test.ts (raw log retained for the final bounded summary)")
        self.assertTrue(reds.classify_web([later], [later]).own)

    def test_a_pass_does_not_erase_an_unnamed_error(self):
        shared = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        extra = shared.replace("--- first run: FAIL ---", "--- first run: FAIL ---\nerror: unhandled failure\n(pass) unrelated test")
        self.assertTrue(reds.classify_web([extra], [shared]).own)

    def test_replay_compares_unnamed_errors_in_its_charged_files(self):
        shared = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        extra = shared.replace("--- first run: FAIL ---", "--- first run: FAIL ---\nerror: unhandled failure\n(pass) unrelated test")
        verdict = reds.classify_web([replay(charged=[f"{CAPSULES} > {CAPSULE_TEST}"]), extra], [shared])
        self.assertTrue(verdict.own)
        self.assertIn(CAPSULES, verdict.reasons[0])

    def test_missing_auxiliary_head_evidence_is_own(self):
        shared = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        self.assertTrue(reds.classify_web([shared, None], [shared]).own)

    def test_a_job_that_names_no_webview_test_is_not_this_classifiers(self):
        self.assertIsNone(reds.classify_web([log("error: oxlint found 3 problems")], [replay()]))


UNAVAILABLE = "test/chat-unavailable.test.ts"


def bun_run(*files, recap=True, counts=True):
    """A raw `bun test` log as Actions prints it: each file is (name, [(test, error or None, timeout ms or None)]);
    a test with no error passed."""
    lines, failures = [], []
    for name, tests in files:
        lines.append(f"##[group]{name}:")
        for test, error, *timeout in tests:
            if error:
                lines += [f"error: {error}", "", f"      at <anonymous> (/home/runner/work/cmux/webviews/{name}:9:5)"]
                lines.append(f"(fail) {test} [12.34ms]")
                if timeout and timeout[0]:
                    lines.append(f"  ^ this test timed out after {timeout[0]}ms.")
                failures.append(f"(fail) {test} [12.34ms]")
            else:
                lines.append(f"(pass) {test} [0.51ms]")
        lines.append("##[endgroup]")
    if recap and failures:
        lines += ["", f"{len(failures)} tests failed:", *failures]
    if counts:
        lines += ["", " 4 pass", f" {len(failures)} fail", " 9 expect() calls",
                  f"Ran {4 + len(failures)} tests across {len(files)} files. [1.02s]"]
    return log(*lines)


class BunTestReds(unittest.TestCase):
    """A raw `bun test` log (cmux-ci test, fast checks) is judged per test like Swift's: before, test_reds.py read no
    bun output and exited 2 on it, so every bun red was compared with the base by hand."""

    def test_the_chat_unavailable_red_on_ad6de25e_compares_by_name_wherever_bun_ran(self):
        head = BUN_CHAT_UNAVAILABLE.read_text()
        found = reds.read(head)
        self.assertEqual(sorted(found.failed), [
            f"{UNAVAILABLE} > ChatUnavailableState > a chat never seen here is not found, never deleted",
            f"{UNAVAILABLE} > ChatUnavailableState > a deleted chat names the machine it was on, not the tab's",
            f"{UNAVAILABLE} > ChatUnavailableState > every case keeps the session id and Resume; Close Tab on all but "
            "deleted (Remove from Sidebar)"])
        for said, line, expected in zip(sorted(found.messages.values(), key=lambda said: said[-3:]), (133, 140, 155),
                                        ("It&#x27;s no longer on build-box.", "Can&#x27;t find this chat",
                                         "Session 01a1201b-d3c3")):
            self.assertTrue(said.startswith(f'expect(received).toContain(expected) / Expected to contain: "{expected}" / '
                                            'Received: "<div class='), said)
            self.assertTrue(said.endswith(f" at {UNAVAILABLE}:{line}"), said)
        self.assertEqual((found.crashes, found.truncated), ([], []))
        # The base ran it from webviews/: the same tests by name.
        base = head.replace("##[group]webviews/test/", "##[group]test/")
        verdict = reds.classify(head, base, "fast checks", "feat-cmux-next")
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, sorted(found.failed))

    def test_the_paste_wall_red_is_its_own_when_the_base_passes_it(self):
        head = BUN_PASTE_WALL.read_text()
        name = ("test/reopened-chat-history.test.ts > a reopened pasteWall chat shows its history under the composer, "
                "with no blank band")
        found = reds.read(head)
        self.assertEqual(found.failed, {name})
        said = ("expect(received).toBeLessThan(expected) / Expected: < 96 / Received: 368.25 "
                "at test/reopened-chat-history.test.ts:505")
        self.assertEqual(found.messages[name], said)
        passing = head.replace("(fail) a reopened pasteWall", "(pass) a reopened pasteWall").replace(" 1 fail", " 0 fail")
        verdict = reds.classify(head, passing, "fast checks", "feat-cmux-next")
        self.assertTrue(verdict.own)
        self.assertEqual(verdict.reasons, [f"1 failing test(s) pass or do not run on feat-cmux-next: {name} ({said})"])
        self.assertFalse(reds.classify(head, head, "fast checks").own)

    def test_bun_raw_output_names_each_failure_with_its_error(self):
        found = reds.read(BUN_RAW.read_text())
        red, load = "test/zz-capture/red.test.ts > chat unavailable > ", "test/zz-capture/load.test.ts > "
        self.assertEqual(found.messages, {
            red + "shows the notice": ('expect(received).toBe(expected) / Expected: "unavailable" / Received: "open" '
                                       "at test/zz-capture/red.test.ts:3"),
            red + "pasteWall settles at the bottom": ("expect(received).toBeLessThan(expected) / Expected: < 2 / "
                                                      "Received: 3.5 at test/zz-capture/red.test.ts:5"),
            red + "reads the slow history": "timed out after 50ms",
            "test/zz-capture/unhandled.test.ts > waits": "late failure outside a test at test/zz-capture/unhandled.test.ts:3",
            load + "unhandled error: Cannot find module './does-not-exist' from 'test/zz-capture/load.test.ts'":
                "Cannot find module './does-not-exist' from 'test/zz-capture/load.test.ts'",
        })
        self.assertEqual(found.failed, set(found.messages))
        self.assertEqual((found.crashes, found.truncated), ([], []))

    def test_a_bun_run_killed_mid_file_is_a_crash_and_cut_short(self):
        killed = BUN_RAW_KILLED.read_text()
        found = reds.read(killed)
        self.assertEqual(found.failed, {"test/zz-capture/slow.test.ts > first"})
        self.assertEqual(found.crashes, ["the test process crashed (signal 9)"])
        self.assertEqual(found.truncated, ["a bun test run printed no ` N pass` / ` N fail` summary before the log ended"])
        self.assertTrue(reds.classify(killed, killed, "fast checks").own)

    def test_the_same_bun_failure_on_both_sides_is_a_base_red_and_a_new_one_is_its_own(self):
        both = (UNAVAILABLE, [("chat > shows the notice", "expect(received).toBe(expected)"), ("chat > opens", None)])
        head = bun_run(both, ("test/b.test.ts", [("b > rests", "expect(received).toEqual(expected)")]))
        verdict = reds.classify(bun_run(both), bun_run(both))
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, [f"{UNAVAILABLE} > chat > shows the notice"])
        verdict = reds.classify(head, bun_run(both))
        self.assertTrue(verdict.own)
        self.assertEqual(verdict.reasons, ["1 failing test(s) pass or do not run on the base: "
                                           "test/b.test.ts > b > rests (expect(received).toEqual(expected) at test/b.test.ts:9)"])
        self.assertEqual(verdict.shared, [f"{UNAVAILABLE} > chat > shows the notice"])

    def test_the_same_bun_test_failing_with_another_error_on_the_base_is_its_own(self):
        # Sol on #28330 at a0afd92b: an assertion on the base must not excuse a new TypeError on the head.
        base = BUN_PASTE_WALL.read_text()
        name = ("test/reopened-chat-history.test.ts > a reopened pasteWall chat shows its history under the composer, "
                "with no blank band")
        for head in (base.replace("error: expect(received).toBeLessThan(expected)",
                                  "error: TypeError: undefined is not an object (evaluating 'state.lastLine')"),
                     base.replace("reopened-chat-history.test.ts:505:30)", "reopened-chat-history.test.ts:503:20)")):
            with self.subTest(head=head[-200:]):
                verdict = reds.classify(head, base, "fast checks", "feat-cmux-next")
                self.assertTrue(verdict.own)
                self.assertEqual(verdict.shared, [])
                self.assertIn(f"1 test(s) fail differently on feat-cmux-next: {name} (", verdict.reasons[0])
                self.assertIn("expect(received).toBeLessThan(expected) / Expected: < 96 / Received: 368.25 at "
                              "test/reopened-chat-history.test.ts:505 on feat-cmux-next", verdict.reasons[0])
        # The checkout's path and spacing are not the error: the same failure elsewhere is still the base's.
        moved = base.replace("/home/runner/_work/cmux/cmux/.fast-checks-checkout/webviews/", "/Users/ci/cmux/webviews/")
        self.assertFalse(reds.classify(moved, base).own)
        # Swift names carry no error and still compare by name.
        self.assertFalse(reds.classify(log(failed("a()"), SUMMARY), log(failed("a()"), SUMMARY)).own)

    def test_the_same_assertion_with_other_values_on_the_base_is_its_own(self):
        # Sol on #28330 at 9ae70ca2: the headline alone (`expect(received).toBe(expected)`) excused a test whose
        # Expected / Received changed. The whole block is compared; only paths, timings and spacing are not.
        base = BUN_PASTE_WALL.read_text()
        for head in (base.replace("Received: 368.25", "Received: 512"), base.replace("Expected: < 96", "Expected: < 48")):
            with self.subTest(head=head[-300:]):
                verdict = reds.classify(head, base, "fast checks", "feat-cmux-next")
                self.assertTrue(verdict.own)
                self.assertIn("1 test(s) fail differently on feat-cmux-next", verdict.reasons[0])
        def run(took, path):
            return log("##[group]test/a.test.ts:", "error: expect(received).toBe(expected)", "",
                       f"Expected: \"ready after {took}\"", f"Received:   \"{path}/webviews/test/a.test.ts\"", "",
                       f"      at <anonymous> ({path}/webviews/test/a.test.ts:4:9)", "(fail) a > b [1.00ms]",
                       "##[endgroup]", " 0 pass", " 1 fail")
        self.assertFalse(reds.classify(run("120ms", "/home/runner/_work/cmux/cmux"), run("120ms", "/Users/ci/cmux")).own)
        # Sol on #28330 at b669c53c: a duration inside an assertion is the assertion's value, never masked.
        verdict = reds.classify(run("120ms", "/x"), run("95.5 ms", "/x"))
        self.assertTrue(verdict.own)
        self.assertIn("fail differently", verdict.reasons[0])
        self.assertEqual(reds.read(run("1s", "/x")).messages,
                         {"test/a.test.ts > a > b": 'expect(received).toBe(expected) / Expected: "ready after 1s" / '
                                                    'Received: "test/a.test.ts" at test/a.test.ts:4'})

    def test_every_diagnostic_of_a_test_failing_more_than_once_is_compared(self):
        # Sol on #28330 at b669c53c: the first diagnostic of a repeated name hid a later TypeError.
        def run(*errors):
            lines = ["bun test v1.4.4 (38afee6c8)", "##[group]test/a.test.ts:"]
            for error in errors:
                lines += [f"error: {error}", "      at <anonymous> (/r/webviews/test/a.test.ts:4:9)", "(fail) a > b [1.00ms]"]
            return log(*lines, "##[endgroup]", " 0 pass", f" {len(errors)} fail")
        assertion, type_error = "expect(received).toBe(expected)", "TypeError: undefined is not a function"
        head = run(assertion, type_error)
        self.assertEqual(reds.read(head).messages["test/a.test.ts > a > b"],
                         f"{type_error} at test/a.test.ts:4\n--- repeated failure ---\n{assertion} at test/a.test.ts:4")
        verdict = reds.classify(head, run(assertion))
        self.assertTrue(verdict.own)
        self.assertIn("1 test(s) fail differently on the base", verdict.reasons[0])
        self.assertIn(type_error, verdict.reasons[0])
        self.assertFalse(reds.classify(head, run(type_error, assertion, assertion)).own)

    def test_the_command_line_judges_a_bun_log_instead_of_exiting_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            head, base = Path(tmp, "head.log"), Path(tmp, "base.log")
            head.write_text(bun_run((UNAVAILABLE, [("chat > a", "boom")])))
            base.write_text(bun_run((UNAVAILABLE, [("chat > a", "boom"), ("chat > b", "bang")])))
            run = lambda h, b: subprocess.run([sys.executable, str(ROOT / "scripts/ci/test_reds.py"), "classify",
                                               "--head", str(h), "--base", str(b), "--json"],
                                              capture_output=True, text=True)
            done = run(head, base)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertEqual(json.loads(done.stdout)["shared"], [f"{UNAVAILABLE} > chat > a"])
            self.assertEqual(run(base, head).returncode, 1)

    def test_timing_is_stripped_the_recap_is_not_counted_twice_and_a_timeout_is_its_message(self):
        found = reds.read(bun_run((UNAVAILABLE, [("chat > slow", "timed out", 5000), ("chat > a", "boom")])))
        self.assertEqual(found.failed, {f"{UNAVAILABLE} > chat > slow", f"{UNAVAILABLE} > chat > a"})
        self.assertEqual(found.messages[f"{UNAVAILABLE} > chat > slow"], "timed out after 5000ms")
        self.assertEqual(found.messages[f"{UNAVAILABLE} > chat > a"], f"boom at {UNAVAILABLE}:9")
        # A failure only the recap names (it failed before its file's header printed) keeps its bare name.
        recap_only = log("1 tests failed:", "(fail) crashed before its header [3.00ms]", " 0 pass", " 1 fail")
        self.assertEqual(reds.read(recap_only).failed, {"crashed before its header"})

    def test_an_unhandled_error_between_tests_is_a_failure_named_by_its_error(self):
        unhandled = log(f"##[group]{UNAVAILABLE}:", "# Unhandled error between tests", "-------------------------------",
                        "error: Cannot find module './gone'", "-------------------------------", "",
                        " 0 pass", " 1 fail", " 1 error")
        self.assertEqual(reds.read(unhandled).failed, {f"{UNAVAILABLE} > unhandled error: Cannot find module './gone'"})
        other = unhandled.replace("./gone", "./missing")
        self.assertTrue(reds.classify(unhandled, other).own)
        self.assertFalse(reds.classify(unhandled, unhandled).own)

    def test_an_unhandled_assertion_compares_its_whole_block_and_location(self):
        # Sol on #28330 at d571e44a: an unhandled error kept only its headline, so two assertions with the same matcher
        # but other values or lines compared as one shared failure.
        def run(received, line=7):
            return log("bun test v1.4.4 (38afee6c8)", f"##[group]{UNAVAILABLE}:", "# Unhandled error between tests",
                       "-------------------------------", "error: expect(received).toBe(expected)", "", "Expected: 1",
                       f"Received: {received}", "",
                       f"      at <anonymous> (/home/runner/_work/cmux/cmux/webviews/{UNAVAILABLE}:{line}:3)",
                       "-------------------------------", "", " 0 pass", " 1 fail", " 1 error")
        name = f"{UNAVAILABLE} > unhandled error: expect(received).toBe(expected)"
        self.assertEqual(reds.read(run(2)).messages,
                         {name: f"expect(received).toBe(expected) / Expected: 1 / Received: 2 at {UNAVAILABLE}:7"})
        for head in (run(3), run(2, line=9)):
            with self.subTest(head=head[-260:]):
                verdict = reds.classify(head, run(2))
                self.assertTrue(verdict.own)
                self.assertIn("1 test(s) fail differently on the base", verdict.reasons[0])
        self.assertFalse(reds.classify(run(2), run(2)).own)

    def test_bun_native_exceptions_are_the_diagnostic(self):
        # Sol on #28330 at d571e44a: bun prints a thrown TypeError / ReferenceError as `TypeError: ...`, not `error:`;
        # ignored, two different exceptions in one test compared as one shared failure.
        def run(error):
            return log("bun test v1.4.4 (38afee6c8)", f"##[group]{UNAVAILABLE}:", "5 |   render(state.pane);",
                       "                   ^", error,
                       f"      at render (/home/runner/_work/cmux/cmux/webviews/{UNAVAILABLE}:5:19)",
                       "(fail) chat > renders [0.40ms]", "##[endgroup]", " 0 pass", " 1 fail")
        type_error = "TypeError: undefined is not an object (evaluating 'state.pane')"
        self.assertEqual(reds.read(run(type_error)).messages,
                         {f"{UNAVAILABLE} > chat > renders": f"{type_error} at {UNAVAILABLE}:5"})
        for base in ("ReferenceError: state is not defined", "TypeError: null is not an object (evaluating 'state.pane')",
                     "error: expect(received).toBe(expected)"):
            with self.subTest(base=base):
                verdict = reds.classify(run(type_error), run(base))
                self.assertTrue(verdict.own)
                self.assertIn("1 test(s) fail differently on the base", verdict.reasons[0])
        self.assertFalse(reds.classify(run(type_error), run(type_error)).own)

    def test_a_cut_short_bun_run_is_never_a_base_red(self):
        tests = (UNAVAILABLE, [("chat > a", "boom"), ("chat > b", None)])
        for cut in (bun_run(tests, recap=False, counts=False), bun_run(tests, counts=False),
                    # a second run that never finished after a whole first one
                    bun_run(tests) + "\n" + log("##[group]test/c.test.ts:", "(pass) c > d [1.00ms]"),
                    # ... or that ended before its first result (Sol on #28330 at a0afd92b)
                    bun_run(tests) + "\n" + log("bun test v1.4.4 (38afee6c8)"),
                    bun_run(tests) + "\n" + log("::group::test/c.test.ts:"),
                    # an earlier run cut short, then a whole one (Sol on #28330 at b669c53c)
                    log("bun test v1.4.4 (38afee6c8)") + "\n" + bun_run(tests, recap=False, counts=False) + "\n"
                    + log("bun test v1.4.4 (38afee6c8)") + "\n" + bun_run(tests)):
            with self.subTest(cut=cut[-80:]):
                verdict = reds.classify(cut, cut, "fast checks")
                self.assertTrue(verdict.own)
                self.assertIn("printed no ` N pass` / ` N fail` summary before", verdict.reasons[0])
        whole = log("bun test v1.4.4 (38afee6c8)") + "\n" + bun_run(tests)
        self.assertFalse(reds.classify(whole + "\n" + whole, whole + "\n" + whole, "fast checks").own)
        # The wrapper's first run, killed, then its retry alone: the first run was cut short.
        retried = log("##[group]FAIL test/a.test.ts", "--- first run: TIMEOUT ---", "bun test v1.4.4 (38afee6c8)",
                      "::group::test/a.test.ts:", "(pass) a > b [1.00ms]", "--- retry, alone ---",
                      "bun test v1.4.4 (38afee6c8)", "::group::test/a.test.ts:", "(fail) a > c [1.00ms]", "::endgroup::",
                      " 1 pass", " 1 fail", "##[endgroup]")
        self.assertIn("before the wrapper ran its file again", reds.read(retried).truncated[0])

    def test_a_bun_run_cut_before_its_first_result_is_judged_whatever_the_job_is_named(self):
        # Sol on #28330 at bd2322b0: a run that only reached `bun test v…` or a file header was cut short but never
        # counted as having run tests, so a job not named for tests ("fast checks") got no verdict (exit 2).
        for cut in (log("bun test v1.4.4 (38afee6c8)"), log("bun test v1.4.4 (38afee6c8)", "::group::test/a.test.ts:"),
                    log("##[group]test/a.test.ts:")):
            with self.subTest(cut=cut):
                found = reds.read(cut)
                self.assertTrue(found.ran)
                self.assertEqual(found.truncated, ["a bun test run printed no ` N pass` / ` N fail` summary before the "
                                                   "log ended"])
                verdict = reds.classify(cut, cut, "fast checks")
                self.assertIsNotNone(verdict)
                self.assertTrue(verdict.own)
                with tempfile.TemporaryDirectory() as tmp:
                    head = Path(tmp, "head.log")
                    head.write_text(cut)
                    done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/test_reds.py"), "classify", "--head",
                                           str(head), "--base", str(head), "--job", "fast checks"],
                                          capture_output=True, text=True)
                    self.assertEqual(done.returncode, 1, done.stdout + done.stderr)

    def test_a_bun_crash_or_a_killed_runner_after_a_whole_run_is_never_a_base_red(self):
        whole = bun_run((UNAVAILABLE, [("chat > a", "boom")]))
        for end in ("panic(main thread): Segmentation fault at address 0x0",
                    "oh no: Bun has crashed. This indicates a bug in Bun, not your code.",
                    "##[error]Process completed with exit code 137.", "bash: line 1: 4242 Killed                  bun test"):
            with self.subTest(end=end):
                crashed = whole + "\n" + log(end)
                verdict = reds.classify(crashed, crashed, "fast checks")
                self.assertTrue(verdict.own, verdict.reasons)
                self.assertIn("crashed", verdict.reasons[0])

    def test_a_webviews_retry_alone_replaces_the_files_first_run(self):
        file = "test/agent-pane.test.ts"
        def wrapper(retry_fails):
            run = lambda fails: [f"::group::{file}:", *[f"(fail) pane > {name} [1.00ms]" for name in fails],
                                 "(pass) pane > rests [1.00ms]", "::endgroup::", " 1 pass", f" {len(fails)} fail"]
            return log(f"##[group]FAIL {file}", "--- first run: FAIL ---", *run(["flake", "real"]),
                       "--- retry, alone ---", *run(retry_fails), "##[endgroup]")
        self.assertEqual(reds.read(wrapper(["real"])).failed, {f"{file} > pane > real"})
        self.assertEqual(reds.read(wrapper([])).failed, set())

    def test_the_webview_wrappers_comparison_is_unchanged(self):
        # web_failures hands read() its log without result lines: a wrapper log of bun output with no counts (as in
        # web_job) is judged as before, by classify_web's own rules.
        head_shard = web_job((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))
        self.assertEqual(reds.web_failures(head_shard).truncated, [])
        self.assertFalse(reds.classify_web([head_shard], [head_shard]).own)



class ClassifyAny(unittest.TestCase):
    """base_red_excuse.py's window: a failing test is the base's when any one of the base logs fails it."""

    def test_a_test_red_on_any_base_is_shared_and_names_that_base(self):
        head = log(failed("a()"), failed("b()"), SUMMARY)
        verdict = reds.classify_any(head, [("run 2", log(failed("a()"), SUMMARY)),
                                           ("run 1", log(failed("b()"), SUMMARY))], "cmux-next swift test")
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["a() (run 2)", "b() (run 1)"])

    def test_a_test_red_on_no_base_is_the_heads(self):
        head = log(failed("a()"), failed("c()"), SUMMARY)
        verdict = reds.classify_any(head, [("run 2", log(failed("a()"), SUMMARY)),
                                           ("run 1", log(failed("b()"), SUMMARY))])
        self.assertTrue(verdict.own)
        self.assertIn("c()", verdict.reasons[0])
        self.assertIn("run 2, run 1", verdict.reasons[0])

    def test_one_base_is_classify(self):
        head = log(failed("a()"), SUMMARY)
        base = log(failed("b()"), SUMMARY)
        self.assertEqual(reds.classify_any(head, [("run 1", base)]).reasons, reds.classify(head, base, "", "run 1").reasons)

    def test_a_crash_is_the_heads_whatever_any_base_shows(self):
        crashed = log(failed("a()"), ABORT)
        verdict = reds.classify_any(crashed, [("run 2", log(SUMMARY)), ("run 1", crashed)], "cmux-next swift test")
        self.assertTrue(verdict.own)


# cmux#33162's `web / react-apps-base-check (3)`, job 126154996598 (run 41698414997 attempt 1, 2026-11-03), as GitHub
# serves it: its runner lost communication mid-step, so the job failed with that annotation, its "Run base reds and
# compare" step still in_progress, and no log stored (the logs endpoint answers BlobNotFound).
LOST_JOB = FIXTURES / "lost-runner-job-126154996598.json"
LOST_NOTES = FIXTURES / "lost-runner-annotations-126154996598.json"
LOST_LOG = FIXTURES / "lost-runner-log-126154996598.txt"


class VolatileTokens(unittest.TestCase):
    """The same error on two runs names each run's own temp dir, checkout root and times (2026-11-04: the
    release-notary red on #34660 and on feat-cmux-next printed /tmp/tmp.Pw5bL0wmeb and /tmp/tmp9j12s3ib-style
    names); those tokens are masked before two errors are compared, and nothing else is."""

    # Lines as the release-notary job printed them on cmux#34660's head run 41808383454 (job 126501169622).
    HEAD = [
        "check_bundle_notices: every Mach-O in /tmp/tmp.Pw5bL0wmeb/cmux.app has its notices",
        "6 media DerivedData dir(s) in /tmp/tmp9j12s3ib outside this tour's and the 0 warm slots'; keeping at most 4",
        '  File "/tmp/tmpckvlipun/workspace/scripts/ci/media_app_cache.py", line 294, in <module>',
        "AssertionError: publish-nightly at /home/runner/work/cmux/cmux/tests/test_nightly_delivery_concurrency.py",
    ]
    BASE = [
        "check_bundle_notices: every Mach-O in /tmp/tmp.Zq81xKcd0A/cmux.app has its notices",
        "6 media DerivedData dir(s) in /tmp/tmpa_yfgwgq outside this tour's and the 0 warm slots'; keeping at most 4",
        '  File "/tmp/tmp_n8aiuq4/workspace/scripts/ci/media_app_cache.py", line 294, in <module>',
        "AssertionError: publish-nightly at /Users/ci/actions-runner/_work/cmux/cmux/tests/"
        "test_nightly_delivery_concurrency.py",
    ]

    def test_each_runs_own_temp_dirs_and_checkout_root_compare_equal(self):
        for head, base in zip(self.HEAD, self.BASE):
            with self.subTest(head=head):
                self.assertNotEqual(head, base)
                self.assertTrue(reds.same_error(head, base), (reds.volatile(head), reds.volatile(base)))

    def test_runner_temp_macos_temp_and_times_are_masked(self):
        pairs = [
            ("wrote /home/runner/work/_temp/4b1c0e2a-9f7d-4d3e-8a55-0c1f2e3d4b5a.sh", "wrote /home/runner/work/_temp/"
             "8e2f1a3b-1c2d-4e5f-9a8b-7c6d5e4f3a2b.sh"),
            ("no such file: /private/var/folders/x1/abc_123/T/cmux-AbC/f.json",
             "no such file: /var/folders/q9/zz_987/T/cmux-AbC/f.json"),
            ("stale since 2026-11-04T09:35:26.94Z", "stale since 2026-11-03T22:01:02Z"),
        ]
        for head, base in pairs:
            with self.subTest(head=head):
                self.assertTrue(reds.same_error(head, base), (reds.volatile(head), reds.volatile(base)))

    def test_a_different_error_still_differs(self):
        pairs = [
            ("AssertionError: publish-nightly", "AssertionError: publish-nightly-next"),
            ("no such file: /tmp/tmpab12cd34/a.json", "permission denied: /tmp/tmpzz99yy88/a.json"),
            ("expected stable to be in Sources/App/Feature.swift", "expected stable to be in Sources/App/Other.swift"),
            ("TypeError: undefined is not a function", "expect(received).toBe(expected)"),
            # Only run-named temp dirs are masked: two plain files in /tmp or $RUNNER_TEMP stay two errors.
            ("missing /tmp/release-notes.md", "missing /tmp/appcast.xml"),
            ("missing /home/runner/work/_temp/notary-key.p8", "missing /home/runner/work/_temp/signing.keychain"),
            ("no such file: /var/folders/x1/abc/T/a.json", "no such file: /var/folders/x1/abc/T/b.json"),
            # A test's message keeps its numbers: a timing or count that changed is another failure.
            ("render took 1200ms, budget 16ms", "render took 20ms, budget 16ms"),
            ("expected 3m rows", "expected 5m rows"),
            # Ids outside a temp dir are compared as they are.
            ("session 0f3e2d1c-aaaa-4bbb-8ccc-1234567890ab expired", "session 9a8b7c6d-1111-4222-8333-abcdefabcdef expired"),
            ("error: artifact deadbeef1 missing", "error: artifact abcdef12 missing"),
        ]
        for head, base in pairs:
            with self.subTest(head=head):
                self.assertFalse(reds.same_error(head, base))
        self.assertFalse(reds.same_error("", ""))
        self.assertFalse(reds.same_error("boom", None))

    def test_a_bun_failure_with_another_temp_dir_fails_the_same_way(self):
        head = bun_run(("test/a.test.ts", [("a > b", "ENOENT: no such file, open '/tmp/tmp.Pw5bL0wmeb/state.json'")]))
        base = bun_run(("test/a.test.ts", [("a > b", "ENOENT: no such file, open '/tmp/tmp.Zq81xKcd0A/state.json'")]))
        verdict = reds.classify(head, base, "react-apps-check (1)")
        self.assertFalse(verdict.own, verdict.reasons)
        other = bun_run(("test/a.test.ts", [("a > b", "EACCES: permission denied, open '/tmp/tmp.Zq81xKcd0A/state.json'")]))
        verdict = reds.classify(head, other, "react-apps-check (1)")
        self.assertTrue(verdict.own)
        self.assertIn("fail differently", verdict.reasons[0])


class LostRunner(unittest.TestCase):
    """A job whose runner was lost is infra, not a verdict: never the PR's own red, it needs a re-run."""

    def setUp(self):
        self.job = json.loads(LOST_JOB.read_text())
        self.notes = json.loads(LOST_NOTES.read_text())

    def test_the_real_lost_job_is_infra_from_any_one_signal(self):
        self.assertIn("lost communication", reds.lost_runner(self.job, self.notes))
        self.assertIn("still in_progress", reds.lost_runner(self.job))  # its steps alone, no read
        steps_done = dict(self.job, steps=[dict(s, status="completed") for s in self.job["steps"][:14]])
        self.assertIn("BlobNotFound", reds.lost_runner(steps_done, (), LOST_LOG.read_text()))
        # As cmuxterm-hq's next-autoland asks: the check run's conclusion and its annotations only.
        self.assertTrue(reds.lost_runner({"conclusion": "failure"}, self.notes))
        self.assertTrue(reds.lost_runner({"conclusion": "failure"}, [n["message"] for n in self.notes]))

    def test_a_real_test_failure_keeps_its_verdict(self):
        failed = dict(self.job, steps=[dict(s, status="completed", conclusion="success") for s in self.job["steps"]])
        failed["steps"][14]["conclusion"] = "failure"
        self.assertIsNone(reds.lost_runner(failed))
        self.assertIsNone(reds.lost_runner(failed, [{"annotation_level": "failure",
                                                     "message": "Process completed with exit code 1."}], "log"))
        # A failed step decides even beside an unread log.
        self.assertIsNone(reds.lost_runner(failed, (), LOST_LOG.read_text()))
        # Only a failure is judged: a cancelled or passed job has no lost-runner red.
        self.assertIsNone(reds.lost_runner(dict(self.job, conclusion="cancelled"), self.notes))
        # A notice that quotes the words is not the runner's failure.
        self.assertIsNone(reds.lost_runner({"conclusion": "failure"},
                                           [{"annotation_level": "notice", "message": self.notes[0]["message"]}]))

    def test_the_cli_marks_the_real_job_infra_needing_a_re_run(self):
        script = ROOT / "scripts/ci/test_reds.py"
        done = subprocess.run([sys.executable, str(script), "runner", "--job", str(LOST_JOB), "--annotations",
                               str(LOST_NOTES), "--log", str(LOST_LOG)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("infra, not a verdict: 'web / react-apps-base-check (3)' (job 126154996598)", done.stdout)
        self.assertIn("never the PR's own red; re-run it", done.stdout)
        with tempfile.TemporaryDirectory() as tmp:
            failed = json.loads(LOST_JOB.read_text())
            failed["steps"] = [dict(s, status="completed", conclusion="success") for s in failed["steps"]]
            failed["steps"][14]["conclusion"] = "failure"
            path = Path(tmp) / "job.json"
            path.write_text(json.dumps(failed))
            done = subprocess.run([sys.executable, str(script), "runner", "--job", str(path)],
                                  capture_output=True, text=True)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("a verdict", done.stdout)


class ReadOncePerLog(unittest.TestCase):
    """A log is parsed once per process, however often the judge reads it (2026-11-06, cmux#36356 at 2c9f6957):
    base_red_excuse.py's window re-classified every log each time it grew, 50 reads of six 20 to 27 MB logs, 110 s
    of CPU, and merge_hold's 120 s bound on the classifier refused the merge."""

    def setUp(self):
        reds._parsed.clear()
        self.addCleanup(reds._parsed.clear)

    def test_a_window_parses_each_log_once(self):
        head, base = HEAD_26346.read_text(), BASE_26346.read_text()
        older = base + "\n"  # another base run's log: another text
        parsed = []
        real = reds.parse_log

        def counting(log, bun=True):
            parsed.append(log)
            return real(log, bun)

        reds.parse_log = counting
        self.addCleanup(setattr, reds, "parse_log", real)
        # As compare_window does as the window grows: the newest, then the newest and an older one.
        first = reds.classify_any(head, [("feat-cmux-next run 1", base)], "cmux-next swift test")
        grown = reds.classify_any(head, [("feat-cmux-next run 1", base), ("feat-cmux-next run 2", older)],
                                  "cmux-next swift test")
        self.assertEqual([parsed.count(text) for text in (head, base, older)], [1, 1, 1])
        reds.parse_log = real
        reds._parsed.clear()
        fresh = reds.classify_any(head, [("feat-cmux-next run 1", base), ("feat-cmux-next run 2", older)],
                                  "cmux-next swift test")
        self.assertEqual((grown.own, grown.reasons, grown.shared), (fresh.own, fresh.reasons, fresh.shared))
        self.assertIsNotNone(first)

    def test_a_kept_read_is_the_callers_own_copy(self):
        log = HEAD_26346.read_text()
        mine = reds.read(log)
        mine.failed.add("a test that never ran")
        mine.crashes.append("a crash that never happened")
        again = reds.read(log)
        self.assertNotIn("a test that never ran", again.failed)
        self.assertNotIn("a crash that never happened", again.crashes)
        self.assertEqual((again.failed, again.crashes), (reds.parse_log(log).failed, reds.parse_log(log).crashes))

    def test_at_most_keep_parsed_logs_are_kept(self):
        for n in range(reds.KEEP_PARSED + 3):
            reds.read(f"✘ Test t{n}() failed after 0.1 seconds with 1 issue.\n")
        self.assertEqual(len(reds._parsed), reds.KEEP_PARSED)


if __name__ == "__main__":
    unittest.main()
