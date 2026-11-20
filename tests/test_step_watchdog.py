#!/usr/bin/env python3
"""scripts/ci/step_watchdog.py: a silent step is killed at its limit, a chatty long one is left alone.

Run it yourself (cmux-ci test -- python3 tests/test_step_watchdog.py); it is no CI job.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "step_watchdog.py"


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie still answers kill(0); read its state where /proc exists.
    stat = pathlib.Path(f"/proc/{pid}/stat")
    if stat.exists():
        try:
            return stat.read_text().split(") ", 1)[1][:1] != "Z"
        except (OSError, IndexError):
            return False
    return True


def wait_gone(pid: int, seconds: float = 5.0) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return not alive(pid)


def python(code: str) -> list[str]:
    return [sys.executable, "-c", textwrap.dedent(code)]


class StepWatchdogTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.temp = pathlib.Path(self._temp.name)

    def tearDown(self) -> None:
        self._temp.cleanup()

    def run_watchdog(self, *args: str, command: list[str], deadline: float = 60.0):
        started = time.monotonic()
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), *args, "--", *command],
            cwd=ROOT, text=True, capture_output=True, timeout=deadline,
        )
        return completed, time.monotonic() - started

    def test_a_silent_child_and_its_grandchild_are_killed_at_the_limit(self) -> None:
        pids = self.temp / "pids"
        # The child prints, then starts a grandchild (as the perf cron plan's python3 -> python3 -> git) and both
        # go quiet. No flush: through a pipe this would sit in a buffer; the pty makes it reach the log at once.
        completed, took = self.run_watchdog(
            "--silent-seconds", "2", "--label", "perf cron plan", "--sample-seconds", "0", "--pty",
            command=python(f"""
                import os, subprocess, sys, time
                print("perf-cron: state from artifact 1")
                print("perf-cron fetch-state: 3 GitHub API call(s)")
                child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
                open({str(pids)!r}, "w").write(f"{{os.getpid()}} {{child.pid}}")
                time.sleep(600)
            """),
        )
        self.assertEqual(completed.returncode, 97, completed.stdout + completed.stderr)
        self.assertLess(took, 15, "the watchdog did not fire near its 2 s limit")
        out = completed.stdout
        self.assertIn("::error title=Silent step%3A perf cron plan::perf cron plan timed out after 2s with no output",
                      out)
        self.assertIn("last output: perf-cron fetch-state: 3 GitHub API call(s)", out)
        self.assertIn("Last 2 line(s) of output before it went quiet:", out)
        self.assertIn("  perf-cron: state from artifact 1", out)
        self.assertIn("Processes in the step's group:", out)
        # The reason appears once, so a log grep counts one hit per silent step.
        self.assertEqual(out.count("timed out"), 1, out)
        parent, grandchild = (int(p) for p in pids.read_text().split())
        self.assertTrue(wait_gone(parent), "the silent child survived")
        self.assertTrue(wait_gone(grandchild), "the silent grandchild survived")

    def test_a_chatty_step_longer_than_the_limit_is_left_alone(self) -> None:
        # 6 s of work, a line every 0.5 s, under a 2 s silent limit: three limits long, never quiet for one.
        completed, took = self.run_watchdog(
            "--silent-seconds", "2", "--label", "chatty",
            command=python("""
                import time
                for index in range(12):
                    print(f"working {index}", flush=index % 2 == 0)
                    time.sleep(0.5)
                print("done")
            """),
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertGreaterEqual(took, 6)
        self.assertNotIn("::error", completed.stdout)
        self.assertIn("working 11\ndone\n", completed.stdout)

    def test_stderr_counts_as_output_and_the_exit_status_passes_through(self) -> None:
        completed, _ = self.run_watchdog(
            "--silent-seconds", "2",
            command=python("""
                import sys, time
                for index in range(6):
                    sys.stderr.write(f"progress {index}\\n")
                    sys.stderr.flush()
                    time.sleep(0.5)
                raise SystemExit(3)
            """),
        )
        self.assertEqual(completed.returncode, 3, completed.stdout)
        self.assertNotIn("::error", completed.stdout)
        self.assertIn("progress 5", completed.stdout)

    def test_a_step_that_never_prints_is_killed_and_says_so(self) -> None:
        completed, took = self.run_watchdog(
            "--silent-seconds", "1", "--sample-seconds", "0", "--label", "quiet",
            command=["sleep", "600"],
        )
        self.assertEqual(completed.returncode, 97, completed.stdout)
        self.assertLess(took, 12)
        self.assertIn("No output at all.", completed.stdout)
        self.assertIn("quiet timed out after 1s with no output; it printed nothing.", completed.stdout)

    def test_the_whole_step_timeout_keeps_its_own_code(self) -> None:
        completed, _ = self.run_watchdog(
            "--silent-seconds", "30", "--timeout-seconds", "2", "--sample-seconds", "0",
            command=python("""
                import time
                while True:
                    print("still here", flush=True)
                    time.sleep(0.2)
            """),
        )
        self.assertEqual(completed.returncode, 124, completed.stdout)
        self.assertIn("timed out after 2s;", completed.stdout)

    def test_the_tail_is_capped(self) -> None:
        completed, _ = self.run_watchdog(
            "--silent-seconds", "1", "--sample-seconds", "0", "--tail-lines", "3",
            command=python("""
                import time
                for index in range(50):
                    print(f"line {index}", flush=True)
                time.sleep(600)
            """),
        )
        self.assertEqual(completed.returncode, 97, completed.stdout)
        self.assertIn("Last 3 line(s) of output before it went quiet:\n  line 47\n  line 48\n  line 49\n",
                      completed.stdout)

    def test_through_the_default_pipe_unflushed_output_reads_as_silence(self) -> None:
        # Why --pty exists: a Python child's prints sit in its pipe buffer, so the step looks quiet.
        completed, _ = self.run_watchdog(
            "--silent-seconds", "1", "--sample-seconds", "0",
            command=python("""
                import time
                print("buffered")
                time.sleep(600)
            """),
        )
        self.assertEqual(completed.returncode, 97, completed.stdout)
        self.assertIn("No output at all.", completed.stdout)

    def test_a_pipe_by_default_and_a_terminal_with_pty(self) -> None:
        probe = python("""
            import os, sys
            print("tty" if os.isatty(1) else "pipe", os.environ.get("TERM", "-"), flush=True)
        """)
        plain, _ = self.run_watchdog("--silent-seconds", "5", command=probe)
        self.assertEqual(plain.returncode, 0, plain.stdout)
        self.assertTrue(plain.stdout.startswith("pipe "), plain.stdout)
        tty, _ = self.run_watchdog("--silent-seconds", "5", "--pty", command=probe)
        self.assertEqual(tty.stdout, "tty dumb\n")

    def test_a_missing_limit_is_refused(self) -> None:
        completed, _ = self.run_watchdog(command=["true"])
        self.assertEqual(completed.returncode, 2)
        self.assertIn("--silent-seconds", completed.stderr)


if __name__ == "__main__":
    unittest.main()
