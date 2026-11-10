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
