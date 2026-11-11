#!/usr/bin/env python3
"""scripts/ci/test_deadline.py ends a hosted Rust test run when one test hangs.

A hung cmux-tui test held its job until the job timeout (40 min, then 70 min on
macOS), so a real hang read as "cancelled" with no test named (runs 42712581504
and 42687069230, 2026-11-09). libtest itself has no per-test limit. The watchdog
reads libtest's own output and ends the run once one test passes its deadline:

- parallel runs: libtest prints `test NAME has been running for over 60 seconds`
  once a test passes 60 s; the test started 60 s before that line;
- one test at a time (`--test-threads=1`, the isolated cmux-tui-core runner):
  libtest prints no such notice, but writes `test NAME ... ` before the test
  starts and its result after it ends.

These tests run the real script against small Python programs that print
libtest output, with deadlines of a few seconds (no network, no cargo).
"""

from __future__ import annotations

import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "test_deadline.py"
SPEC = importlib.util.spec_from_file_location("test_deadline", SCRIPT)
assert SPEC and SPEC.loader
deadline = importlib.util.module_from_spec(SPEC)
sys.modules["test_deadline"] = deadline
SPEC.loader.exec_module(deadline)


class TrackerTests(unittest.TestCase):
    """The decision: which test is overdue, from libtest output and a clock."""

    def test_a_parallel_test_is_dated_60_s_before_its_notice(self):
        tracker = deadline.Tracker(default_seconds=180)
        tracker.feed("running 3 tests\ntest a ... ok\n", now=1000.0)
        tracker.feed("test b has been running for over 60 seconds\n", now=1060.0)
        self.assertIsNone(tracker.overdue(now=1179.0))
        self.assertEqual(tracker.overdue(now=1181.0), ("b", 180))

    def test_a_result_line_clears_a_slow_test(self):
        tracker = deadline.Tracker(default_seconds=180)
        tracker.feed("test b has been running for over 60 seconds\n", now=60.0)
        tracker.feed("test b ... ok\n", now=100.0)
        self.assertIsNone(tracker.overdue(now=10_000.0))

    def test_a_sequential_test_is_dated_from_its_unfinished_line(self):
        tracker = deadline.Tracker(default_seconds=5)
        tracker.feed("running 2 tests\ntest first ... ok\ntest second ... ", now=10.0)
        self.assertIsNone(tracker.overdue(now=14.0))
        self.assertEqual(tracker.overdue(now=15.5), ("second", 5))
        tracker.feed("ok\n", now=16.0)
        self.assertIsNone(tracker.overdue(now=100.0))

    def test_a_line_split_across_reads_is_joined(self):
        tracker = deadline.Tracker(default_seconds=5)
        tracker.feed("test sec", now=10.0)
        tracker.feed("ond ... ", now=11.0)
        self.assertEqual(tracker.overdue(now=16.5), ("second", 5))

    def test_a_named_slow_test_gets_its_own_deadline(self):
        tracker = deadline.Tracker(default_seconds=180, slow={"big_terminal_test": 300})
        tracker.feed("test tests::big_terminal_test has been running for over 60 seconds\n", now=60.0)
        self.assertIsNone(tracker.overdue(now=290.0))
        self.assertEqual(tracker.overdue(now=301.0), ("tests::big_terminal_test", 300))

    def test_test_output_that_is_not_libtest_is_ignored(self):
        tracker = deadline.Tracker(default_seconds=5)
        tracker.feed("   Compiling cmux-tui v0.1.0\nwarning: test something ... odd\n", now=0.0)
        tracker.feed("test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; finished in 0.1s\n", now=1.0)
        self.assertIsNone(tracker.overdue(now=100.0))

    def test_a_result_line_with_terminal_escapes_before_it_clears_its_test(self):
        """macOS proof run 42808325625: app::tests write terminal escapes (`ESC]12;#ffffff BEL ESC[1 q`, a bare
        BEL) to the shared stdout, so libtest's own line reads `<escapes>test NAME ... ok`. That result must still
        clear the test, or a finished test looks hung and the run ends at a false deadline."""
        tracker = deadline.Tracker(default_seconds=5)
        tracker.feed("test app::tests::a_slow_test has been running for over 60 seconds\n", now=0.0)
        tracker.feed("\x1b]12;#ffffff\x07\x1b[1 qtest app::tests::a_slow_test ... ok\n", now=1.0)
        self.assertIsNone(tracker.overdue(now=100.0))

    def test_a_sequential_line_with_escapes_before_it_is_still_timed(self):
        tracker = deadline.Tracker(default_seconds=5)
        tracker.feed("\x07test app::tests::hangs ... ", now=10.0)
        self.assertEqual(tracker.overdue(now=15.5), ("app::tests::hangs", 5))

    def test_a_new_test_binary_clears_the_tests_of_a_binary_that_crashed(self):
        """nofailfast-rev-1 on #40404: a test binary that crashes mid-test prints no result line, so its test stayed
        "running" and, under --no-fail-fast, the next binary was ended about 180 s later at a false deadline.
        cargo's `Running` line for the next binary means the old one has exited."""
        tracker = deadline.Tracker(default_seconds=180)
        # A parallel run: the test has its 60 s notice, then its binary crashes (no result line for it).
        tracker.feed("test crashes has been running for over 60 seconds\n", now=0.0)
        tracker.feed("error: test failed, to rerun pass `-p a --lib`\n\nCaused by:\n"
                     "  process didn't exit successfully: `a-0123abcd` (signal: 11, SIGSEGV)\n"
                     "     Running unittests src/lib.rs (target/debug/deps/b-0123abcd)\n", now=1.0)
        self.assertIsNone(tracker.overdue(now=500.0))
        tracker.feed("     Running tests/terminal.rs (target/debug/deps/terminal-0123abcd)\n"
                     "test other ... ", now=600.0)
        self.assertEqual(tracker.overdue(now=781.0), ("other", 180))

    def test_a_doc_tests_line_clears_the_tests_of_a_binary_that_crashed(self):
        """deadline-rev item 1 on #40523: cargo runs doctests after the last test binary, so when that binary
        crashed under --no-fail-fast its test stayed "running" through rustdoc and ended the run at a false deadline.
        cargo's `Doc-tests` line, like `Running`, means the binary has exited."""
        tracker = deadline.Tracker(default_seconds=180)
        tracker.feed("test crashes has been running for over 60 seconds\n", now=0.0)
        tracker.feed("error: test failed, to rerun pass `-p a --lib`\n\nCaused by:\n"
                     "  process didn't exit successfully: `a-0123abcd` (signal: 11, SIGSEGV)\n"
                     "   Doc-tests a\n\nrunning 3 tests\n", now=1.0)
        self.assertIsNone(tracker.overdue(now=500.0))

    def test_test_output_that_starts_with_running_does_not_clear_open_tests(self):
        """deadline-rev item 2 on #40523: only cargo's own `Running <target> (<path>)` line ends a binary. A test
        that prints `Running ...` itself must not clear the tests still open, or a hang there is never timed."""
        tracker = deadline.Tracker(default_seconds=180)
        tracker.feed("test hangs has been running for over 60 seconds\n", now=0.0)
        tracker.feed("Running the migration step\n  Running worker 2 of 4\n", now=1.0)
        self.assertEqual(tracker.overdue(now=121.0), ("hangs", 180))

    def test_a_test_result_line_clears_every_open_test(self):
        tracker = deadline.Tracker(default_seconds=5)
        tracker.feed("test a has been running for over 60 seconds\n", now=0.0)
        tracker.feed("\ntest result: FAILED. 0 passed; 1 failed\n", now=1.0)
        self.assertIsNone(tracker.overdue(now=100.0))


FAKE = textwrap.dedent(
    """
    import sys, time
    mode = sys.argv[1]
    def out(text):
        sys.stdout.write(text); sys.stdout.flush()
    out("running 2 tests\\n")
    if mode == "pass":
        out("test a ... ok\\ntest b ... ok\\n\\ntest result: ok. 2 passed; 0 failed\\n")
        sys.exit(0)
    if mode == "fail":
        out("test a ... FAILED\\n\\ntest result: FAILED. 0 passed; 1 failed\\n")
        sys.exit(101)
    if mode == "sequential-hang":
        out("test a ... ok\\ntest b_hangs ... ")
        time.sleep(30)
    if mode == "escaped-pass":
        # app::tests write terminal escapes before libtest's own result line. The result comes before the
        # deadline; the binary then stays quiet past it (other output, no summary yet), so only a read result
        # line keeps the finished test from looking hung.
        out("test slow has been running for over 60 seconds\\n")
        time.sleep(0.5)
        out("\\x1b]12;#ffffff\\x07\\x1b[1 qtest slow ... ok\\n")
        time.sleep(4)
        out("\\ntest result: ok. 1 passed; 0 failed\\n")
        sys.exit(0)
    if mode == "crash-then-next":
        # Binary 1 crashes in a parallel run (its test has a 60 s notice, then no result line); cargo goes on
        # to binary 2 (--no-fail-fast), which passes.
        out("test crashes has been running for over 60 seconds\\n")
        out("error: test failed, to rerun pass `-p a --lib`\\n\\nCaused by:\\n  process didn't exit successfully: "
            "`a-0123abcd` (signal: 11, SIGSEGV)\\n")
        out("     Running unittests src/main.rs (target/debug/deps/b-0123abcd)\\n\\nrunning 1 tests\\n")
        time.sleep(4)
        out("test fine ... ok\\n\\ntest result: ok. 1 passed; 0 failed\\n")
        sys.exit(101)
    if mode == "trap-term":
        # A test that writes a file when the wrapper's cancel reaches it.
        import signal
        def stop(signum, frame):
            # The test ends cleanly on the cancel: the job must still read as cancelled.
            open(sys.argv[2], "w").write(str(signum)); sys.exit(0)
        signal.signal(signal.SIGTERM, stop)
        out("ready\\ntest waits ... ")
        time.sleep(60)
    if mode == "parallel-hang":
        out("test a ... ok\\ntest b_hangs has been running for over 60 seconds\\n")
        time.sleep(30)
    """
)


class ProcessTests(unittest.TestCase):
    """The real script, around a fake test command."""

    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="test-deadline."))
        self.fake = self.dir / "fake_libtest.py"
        self.fake.write_text(FAKE, encoding="utf-8")

    def run_script(self, mode: str, *options: str) -> tuple[int, str, float]:
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *options, "--", sys.executable, "-I", str(self.fake), mode],
            capture_output=True, text=True, timeout=60,
        )
        return result.returncode, result.stdout + result.stderr, time.monotonic() - started

    def test_a_passing_run_keeps_its_status_and_output(self):
        code, out, _ = self.run_script("pass", "--deadline-seconds", "5")
        self.assertEqual(code, 0, out)
        self.assertIn("test result: ok. 2 passed", out)

    def test_a_failing_run_keeps_its_own_status(self):
        code, out, _ = self.run_script("fail", "--deadline-seconds", "5")
        self.assertEqual(code, 101, out)

    def test_a_sequential_hang_ends_at_its_deadline_and_names_the_test(self):
        code, out, took = self.run_script("sequential-hang", "--deadline-seconds", "2")
        self.assertEqual(code, deadline.DEADLINE_EXIT, out)
        self.assertIn("b_hangs", out)
        self.assertIn("2 s deadline", out)
        self.assertLess(took, 30, out)

    def test_a_parallel_hang_ends_after_its_notice(self):
        # The notice dates the test 60 s back: a 61 s deadline ends it about 1 s later.
        code, out, took = self.run_script("parallel-hang", "--deadline-seconds", "61")
        self.assertEqual(code, deadline.DEADLINE_EXIT, out)
        self.assertIn("b_hangs", out)
        self.assertLess(took, 30, out)

    def test_a_slow_override_lets_a_named_test_run_longer(self):
        code, out, took = self.run_script("sequential-hang", "--deadline-seconds", "1", "--slow", "b_hangs=3")
        self.assertEqual(code, deadline.DEADLINE_EXIT, out)
        self.assertIn("3 s deadline", out)
        self.assertGreaterEqual(took, 2.5, out)

    def test_escapes_before_a_result_line_do_not_end_a_run_at_a_false_deadline(self):
        # The notice dates the test 60 s back, so a 62 s deadline falls at about 2 s: after the escaped result
        # (0.5 s), before the summary (4.5 s). A missed result line ends the run there.
        code, out, _ = self.run_script("escaped-pass", "--deadline-seconds", "62")
        self.assertEqual(code, 0, out)
        self.assertNotIn("deadline", out)

    def test_a_crashed_binary_does_not_end_the_next_binary_at_a_false_deadline(self):
        # The notice dates the crashed test 60 s back: a 61 s deadline would end binary 2 about 1 s later.
        code, out, _ = self.run_script("crash-then-next", "--deadline-seconds", "61")
        self.assertEqual(code, 101, out)
        self.assertNotIn("ran past", out)
        self.assertIn("test fine ... ok", out)

    def test_a_cancel_of_the_watchdog_reaches_the_test_process(self):
        """A cancelled job (Ctrl-C, the runner's SIGTERM) must stop the tests too, not leave them running orphaned."""
        marker = self.dir / "got-signal"
        process = subprocess.Popen(
            [sys.executable, "-I", str(SCRIPT), "--deadline-seconds", "120", "--", sys.executable, "-I",
             str(self.fake), "trap-term", str(marker)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert process.stdout is not None
        line = process.stdout.readline()
        while line and line.strip() != "ready":
            line = process.stdout.readline()
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=20)
        finally:
            process.kill()
        deadline_at = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline_at:
            time.sleep(0.1)
        self.assertTrue(marker.exists(), "the test process never got the cancel")
        self.assertEqual(marker.read_text(), str(int(signal.SIGTERM)))
        # deadline-rev item 4 on #40523: the watchdog exits 128 + the signal, not the test's own status.
        self.assertEqual(process.returncode, 128 + int(signal.SIGTERM))

    def test_the_deadline_comes_from_the_environment_when_no_flag_names_it(self):
        env = {**os.environ, "CMUX_TEST_DEADLINE_SECONDS": "2"}
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--", sys.executable, "-I", str(self.fake), "sequential-hang"],
            capture_output=True, text=True, timeout=60, env=env,
        )
        self.assertEqual(result.returncode, deadline.DEADLINE_EXIT, result.stdout + result.stderr)
        self.assertIn("2 s deadline", result.stdout + result.stderr)


class WrapperTests(unittest.TestCase):
    """scripts/ci/cargo-test-deadline.sh, the one place workflows run cargo test through."""

    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="cargo-test-deadline."))
        (self.dir / "fake_libtest.py").write_text(FAKE, encoding="utf-8")
        cargo = self.dir / "cargo"
        # The fake cargo records its arguments and plays the libtest run that FAKE_MODE names.
        cargo.write_text(
            "#!/usr/bin/env bash\n"
            'printf "%s\\n" "$*" > "$(dirname "$0")/cargo-args"\n'
            f'exec "{sys.executable}" -I "$(dirname "$0")/fake_libtest.py" "$FAKE_MODE"\n',
            encoding="utf-8")
        cargo.chmod(0o755)

    def run_wrapper(self, mode: str, **env: str) -> tuple[int, str, float]:
        started = time.monotonic()
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / "ci" / "cargo-test-deadline.sh"), "-p", "cmux-tui-core", "--lib"],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "PATH": f"{self.dir}:{os.environ['PATH']}", "FAKE_MODE": mode, **env},
        )
        return result.returncode, result.stdout + result.stderr, time.monotonic() - started

    def test_the_wrapper_passes_its_arguments_to_cargo_test_and_keeps_the_status(self):
        code, out, _ = self.run_wrapper("fail", CMUX_TEST_DEADLINE_SECONDS="5")
        self.assertEqual(code, 101, out)
        self.assertEqual((self.dir / "cargo-args").read_text(encoding="utf-8").strip(), "test -p cmux-tui-core --lib")

    def test_the_wrapper_ends_a_hung_test_at_the_env_deadline(self):
        code, out, took = self.run_wrapper("sequential-hang", CMUX_TEST_DEADLINE_SECONDS="2")
        self.assertEqual(code, deadline.DEADLINE_EXIT, out)
        self.assertIn("test b_hangs ran past its 2 s deadline", out)
        self.assertLess(took, 30, out)

    def test_the_wrapper_reads_slow_overrides_from_the_env(self):
        code, out, took = self.run_wrapper("sequential-hang", CMUX_TEST_DEADLINE_SECONDS="1",
                                           CMUX_TEST_DEADLINE_SLOW="other=9 b_hangs=3")
        self.assertEqual(code, deadline.DEADLINE_EXIT, out)
        self.assertIn("3 s deadline", out)
        self.assertGreaterEqual(took, 2.5, out)


if __name__ == "__main__":
    unittest.main()
