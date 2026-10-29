"""scripts/ci/test_reds.py: a red test job is the base's only when every failing test fails on the base too, and a
crash or a cut-short run is never the base's."""
import importlib.util
import json
import subprocess
import sys
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


def log(*lines):
    return "\n".join(f"2026-10-28T03:40:35.1790820Z {line}" for line in lines)


def failed(name):
    return f"✘ Test {name} recorded an issue at X.swift:1:2: Expectation failed"


SUMMARY = "✔ Test run with 40 tests in 3 suites passed after 1.0 seconds."
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


class PerTest(unittest.TestCase):
    def test_the_same_test_failing_on_both_sides_is_a_base_red(self):
        verdict = reds.classify(log(failed("a()"), SUMMARY), log(failed("a()"), failed("b()"), SUMMARY))
        self.assertFalse(verdict.own, verdict.reasons)
        self.assertEqual(verdict.shared, ["a()"])

    def test_a_new_failing_test_is_the_heads_own(self):
        verdict = reds.classify(log(failed("a()"), failed("c()"), SUMMARY), log(failed("a()"), SUMMARY))
        self.assertTrue(verdict.own)
        self.assertIn("pass or do not run on the base: c()", verdict.reasons[0])

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

    def test_a_whole_unittest_run_and_a_known_issue_run_end_are_whole(self):
        self.assertEqual(reds.read(log("test_a (mod.T.test_a) ... ok", "Ran 1 test in 0.001s", "OK")).truncated, [])
        self.assertEqual(reds.read(log("◇ Test run started.", "━ Test run with 1 test in 1 suite passed after 0.1 "
                                       "seconds with 1 known issue.")).truncated, [])

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


if __name__ == "__main__":
    unittest.main()
