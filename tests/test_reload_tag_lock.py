#!/usr/bin/env python3
"""Behavior checks for concurrent tagged reloads without invoking Xcode."""

from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
