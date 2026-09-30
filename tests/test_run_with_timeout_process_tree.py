#!/usr/bin/env python3
"""run_with_timeout.py must stop the whole process tree when it times out.

SwiftPM starts `swiftpm-testing-helper` in its own process group. The old
timeout path only called `os.killpg` on the command's group, so a hung helper
survived the timeout and kept running after the CI step had failed.
"""

from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run_with_timeout.py"


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_exit(pid: int, seconds: float = 5.0) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return False


class RunWithTimeoutProcessTreeTests(unittest.TestCase):
    def test_sigterm_cleans_up_descendants_before_exiting(self) -> None:
        """Runner cancellation must not orphan a detached test helper."""
        with tempfile.TemporaryDirectory() as temp_dir:
            record = pathlib.Path(temp_dir) / "tree.json"
            command = [
                sys.executable,
                "-c",
                textwrap.dedent(f"""
                    import json, os, signal, subprocess, sys
                    helper = subprocess.Popen(
                        [sys.executable, "-c", "import signal; signal.pause()"],
                        start_new_session=True,
                    )
                    with open({str(record)!r} + ".tmp", "w") as handle:
                        json.dump({{"helper": helper.pid, "command": os.getpid()}}, handle)
                    os.rename({str(record)!r} + ".tmp", {str(record)!r})
                    signal.pause()
                """),
            ]
            helper = command_pid = None
            runner = subprocess.Popen(
                [sys.executable, str(RUNNER), "--timeout-seconds", "30", "--", *command],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.monotonic() + 5
                while not record.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(record.exists(), "child did not start")
                tree = json.loads(record.read_text())
                helper, command_pid = tree["helper"], tree["command"]
                os.kill(runner.pid, signal.SIGTERM)
                returncode = runner.wait(timeout=10)
                self.assertTrue(
                    wait_for_exit(helper),
                    "SIGTERM to run_with_timeout orphaned its detached helper",
                )
                self.assertEqual(returncode, 143)
            finally:
                if runner.poll() is None:
                    runner.kill()
                    runner.wait()
                for pid in (helper, command_pid):
                    if pid is not None and pid_alive(pid):
                        os.kill(pid, signal.SIGKILL)

    def test_sigint_kills_signal_ignoring_tree_before_actions_escalates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            record = pathlib.Path(directory) / "tree.json"
            child = pathlib.Path(directory) / "child.py"
            child.write_text(textwrap.dedent(f"""
                import json, os, signal, subprocess, sys, time
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                helper = subprocess.Popen(
                    [sys.executable, "-c", "import pathlib,signal; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path({str(record) + '.ready'!r}).touch(); signal.pause()"],
                    start_new_session=True,
                )
                while not os.path.exists({str(record) + '.ready'!r}): time.sleep(0.01)
                with open({str(record)!r} + ".tmp", "w") as handle:
                    json.dump({{"helper": helper.pid, "command": os.getpid()}}, handle)
                os.rename({str(record)!r} + ".tmp", {str(record)!r})
                signal.pause()
            """))
            runner = subprocess.Popen(
                [sys.executable, str(RUNNER), "--timeout-seconds", "60", "--", sys.executable, str(child)],
                cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            unrelated = subprocess.Popen([sys.executable, "-c", "import signal; signal.pause()"])
            helper = command_pid = None
            try:
                deadline = time.monotonic() + 5
                while not record.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(record.exists(), "child did not start")
                tree = json.loads(record.read_text())
                helper, command_pid = tree["helper"], tree["command"]
                started = time.monotonic()
                os.kill(runner.pid, signal.SIGINT)
                # A repeated cancellation signal must not recurse into cleanup.
                time.sleep(0.1)
                os.kill(runner.pid, signal.SIGTERM)
                self.assertEqual(runner.wait(timeout=7), 130)
                self.assertLess(time.monotonic() - started, 7.5)
                self.assertTrue(wait_for_exit(helper))
                self.assertIsNone(unrelated.poll(), "cleanup killed an unrelated process")
            finally:
                for process in (runner, unrelated):
                    if process.poll() is None:
                        process.kill()
                    process.wait()
                for pid in (helper, command_pid):
                    if pid is not None and pid_alive(pid):
                        os.kill(pid, signal.SIGKILL)

    def test_timeout_kills_a_grandchild_outside_the_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            record = pathlib.Path(temp_dir) / "tree.json"
            # The command starts a stand-in for swiftpm-testing-helper in a new
            # session, records both process groups, then hangs like swift test.
            command = [
                sys.executable,
                "-c",
                textwrap.dedent(f"""
                    import json, os, signal, subprocess, sys
                    helper = subprocess.Popen(
                        [sys.executable, "-c", "import signal; signal.pause()"],
                        start_new_session=True,
                    )
                    with open({str(record)!r} + ".tmp", "w") as handle:
                        json.dump({{
                            "helper": helper.pid,
                            "helper_group": os.getpgid(helper.pid),
                            "command_group": os.getpgid(0),
                        }}, handle)
                    os.rename({str(record)!r} + ".tmp", {str(record)!r})
                    signal.pause()
                """),
            ]
            helper = None
            try:
                # Output goes to a file, not a pipe: a leaked helper would hold
                # a pipe open and hide the leak behind a hang in this test.
                log_path = pathlib.Path(temp_dir) / "runner.log"
                with log_path.open("w") as log:
                    returncode = subprocess.run(
                        [sys.executable, str(RUNNER), "--timeout-seconds", "2", "--", *command],
                        cwd=ROOT,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                        timeout=30,
                    ).returncode
                output = log_path.read_text(encoding="utf-8")
                self.assertTrue(record.exists(), output)
                tree = json.loads(record.read_text(encoding="utf-8"))
                helper = tree["helper"]
                # This is why killpg alone leaked it: the helper is in its own
                # group, so a signal to the command's group never reaches it.
                self.assertNotEqual(tree["helper_group"], tree["command_group"])

                self.assertEqual(returncode, 124, output)
                self.assertIn("::error::command timed out after 2s", output)
                self.assertTrue(
                    wait_for_exit(helper),
                    "the grandchild in its own process group survived the timeout",
                )
            finally:
                if helper is not None and pid_alive(helper):
                    os.kill(helper, 9)

    def test_exit_status_passes_through_without_a_timeout(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(RUNNER), "--timeout-seconds", "30", "--",
             sys.executable, "-c", "raise SystemExit(7)"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(completed.returncode, 7, completed.stderr)


if __name__ == "__main__":
    unittest.main()
