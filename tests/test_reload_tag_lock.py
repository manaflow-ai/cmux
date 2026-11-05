#!/usr/bin/env python3
"""Behavior checks for concurrent tagged reloads without invoking Xcode."""

import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


HELPER = Path(__file__).resolve().parents[1] / "scripts/lib/tagged-reload-lock.py"


class ReloadTagLockTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cmux-reload-lock-test-")
        self.addCleanup(self.directory.cleanup)
        self.script = Path(self.directory.name) / "build.sh"
        self.script.write_text(
            'test "$CMUX_RELOAD_TAG_LOCK_OWNER" = "$PPID" || exit 90\n'
            'printf "ready\\n"\n'
            'read -r release\n'
            'exit "${release:-0}"\n'
        )
        self.tag = "test-" + uuid.uuid4().hex

    def start_reload(self, tag):
        process = subprocess.Popen(
            [sys.executable, str(HELPER), tag, str(self.script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.stop_reload, process)
        return process

    def stop_reload(self, process):
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        for pipe in (process.stdin, process.stdout, process.stderr):
            pipe.close()

    def read_signal(self, process):
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(10), "Reload did not signal progress")
            return process.stdout.readline().strip()

    def finish_reload(self, process, result=0):
        process.stdin.write(f"{result}\n")
        process.stdin.flush()
        return process.wait(timeout=10)

    def test_same_tag_waits_and_other_tags_run_independently(self):
        first = self.start_reload(self.tag)
        self.assertEqual(self.read_signal(first), "ready")
        second = self.start_reload(self.tag)
        self.assertNotEqual(self.read_signal(second), "ready")

        other = self.start_reload(self.tag + "-other")
        self.assertEqual(self.read_signal(other), "ready")
        self.assertEqual(self.finish_reload(other), 0)

        # A failed build must release the lease and preserve its exit status.
        self.assertEqual(self.finish_reload(first, result=7), 7)
        self.assertEqual(self.read_signal(second), "ready")
        self.assertEqual(self.finish_reload(second), 0)

    def test_termination_reaches_build_and_releases_lease(self):
        interrupted = self.start_reload(self.tag)
        self.assertEqual(self.read_signal(interrupted), "ready")
        interrupted.terminate()
        self.assertEqual(interrupted.wait(timeout=10), 143)

        following = self.start_reload(self.tag)
        self.assertEqual(self.read_signal(following), "ready")
        self.assertEqual(self.finish_reload(following), 0)

    def wait_until(self, condition, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return True
            time.sleep(0.05)
        return condition()

    def start_detached_reload(self, body, grace):
        """Start a supervisor in its own process group, like a fleet step."""
        script = Path(self.directory.name) / "detached.sh"
        script.write_text(body)
        environment = dict(os.environ, CMUX_RELOAD_TAG_LOCK_KILL_GRACE=str(grace))
        supervisor = subprocess.Popen(
            [sys.executable, str(HELPER), self.tag, str(script)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            start_new_session=True,
        )
        self.addCleanup(self.kill_group, supervisor.pid)
        return supervisor

    def kill_group(self, group):
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def read_pids(self):
        pid_file = Path(self.directory.name) / "pids"
        self.assertTrue(
            self.wait_until(lambda: pid_file.exists() and pid_file.read_text().endswith("\n"), 10),
            "Reload did not record its pids",
        )
        session, grandchild, watcher = (pid_file.read_text().split() + ["", "", ""])[:3]
        self.addCleanup(self.kill_group, int(session))
        return int(session), int(grandchild), watcher

    @staticmethod
    def group_alive(group):
        try:
            os.killpg(group, 0)
        except ProcessLookupError:
            return False
        return True

    @staticmethod
    def process_alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def test_killing_supervisor_group_ends_reload_session(self):
        # The grandchild ignores SIGTERM, so only the SIGKILL after the grace ends it.
        supervisor = self.start_detached_reload(
            '(trap "" TERM; exec sleep 1000) &\n'
            'printf "%s %s %s\\n" "$$" "$!" "$CMUX_RELOAD_TAG_LOCK_WATCHER" '
            '> "$(dirname "$0")/pids"\n'
            "wait\n",
            grace=1,
        )
        session, grandchild, _watcher = self.read_pids()
        self.assertTrue(self.group_alive(session))

        # A step stop that kills the supervisor's whole group, with no chance
        # to forward the signal.
        os.killpg(supervisor.pid, signal.SIGKILL)
        supervisor.wait(timeout=10)

        self.assertTrue(
            self.wait_until(lambda: not self.group_alive(session), 10),
            f"Reload session {session} (grandchild {grandchild}) outlived its supervisor",
        )
        # The watcher never held the lease: the next reload of the tag runs.
        following = self.start_reload(self.tag)
        self.assertEqual(self.read_signal(following), "ready")
        self.assertEqual(self.finish_reload(following), 0)

    def test_normal_exit_leaves_nothing_behind(self):
        supervisor = self.start_detached_reload(
            'printf "%s %s %s\\n" "$$" "$$" "$CMUX_RELOAD_TAG_LOCK_WATCHER" '
            '> "$(dirname "$0")/pids"\n'
            "exit 3\n",
            grace=1,
        )
        self.assertEqual(supervisor.wait(timeout=10), 3)
        session, _grandchild, watcher = self.read_pids()
        self.assertTrue(watcher.isdigit(), "Supervisor started no session watcher")
        self.assertTrue(
            self.wait_until(lambda: not self.process_alive(int(watcher)), 5),
            f"Session watcher {watcher} outlived a normal reload",
        )
        self.assertFalse(self.group_alive(session))


if __name__ == "__main__":
    unittest.main()
