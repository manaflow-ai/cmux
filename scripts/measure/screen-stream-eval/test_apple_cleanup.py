"""apple.sh quits only the Screen Sharing instance it launched, and a hung view ends within its deadline.

No Mac: the app is a stand-in whose executable is `sleep` at Screen Sharing's executable path
(test_apple_bytes.apple_fixture), so the target's ps-by-path checks see it as Screen Sharing.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_apple_bytes import apple_fixture, stub, window_view


def alive(pid: int) -> bool:
    state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


def launched(tools: Path) -> list[int]:
    path = tools / "open.launched"
    return [int(line) for line in path.read_text().split()] if path.exists() else []


def gone_within(pid: int, seconds: float) -> bool:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not alive(pid):
            return True
        time.sleep(0.1)
    return not alive(pid)


class AppleCleanupTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.env, self.tools, self.bin = apple_fixture(self.root)
        self.addCleanup(self.dir.cleanup)
        # Never leave a stand-in running: end any the target failed to quit, by this test's own record.
        self.addCleanup(self.reap_launched)

    def reap_launched(self):
        for pid in launched(self.tools):
            if alive(pid):
                os.kill(pid, 9)

    def assert_quit_launched(self):
        pids = launched(self.tools)
        self.assertEqual(len(pids), 1, pids)
        self.assertTrue(gone_within(pids[0], 2), f"launched viewer {pids[0]} still running")
        self.assertFalse((self.root / "state/viewer.pid").exists())

    def test_success_quits_launched_viewer(self):
        run = window_view(self.root, self.env, 2)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue((self.root / "go").exists())
        self.assert_quit_launched()

    def test_failure_quits_launched_viewer(self):
        stub(self.bin, "cmux-rd", "exit 1\n")  # source readiness fails after the viewer is up
        run = window_view(self.root, self.env, 2)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("next:", run.stderr)
        self.assertFalse((self.root / "go").exists())
        self.assert_quit_launched()

    def test_wrong_presented_pid_fails_and_quits_launched_viewer(self):
        run = window_view(self.root, {**self.env, "EVAL_PRESENTED_OBSERVER_PID": "1"}, 2)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("not the instance this run launched", run.stderr)
        self.assert_quit_launched()

    def test_preexisting_screen_sharing_is_left_running(self):
        exe = Path(self.env["EVAL_SCREEN_SHARING_APP"]) / "Contents/MacOS/Screen Sharing"
        theirs = subprocess.Popen([str(exe), "1000"], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(theirs.wait)
        self.addCleanup(theirs.kill)
        run = window_view(self.root, self.env, 2)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn(theirs.pid, launched(self.tools))
        self.assert_quit_launched()
        self.assertTrue(alive(theirs.pid), "a Screen Sharing process this run did not start was stopped")

    def test_watchdog_ends_hung_view(self):
        stub(self.tools, "osascript", "cat >/dev/null; exec sleep 1000\n")  # the quality menu never answers
        start = time.monotonic()
        run = window_view(self.root, {**self.env, "EVAL_APPLE_VIEW_DEADLINE_S": "3"}, 2, timeout=30)
        elapsed = time.monotonic() - start
        self.assertEqual(run.returncode, 124, run.stderr)
        self.assertIn("deadline", run.stderr)
        self.assertIn("next:", run.stderr)
        # 3 s deadline, up to 5 s for the viewer, plus slack for a loaded runner.
        self.assertLess(elapsed, 15)
        self.assert_quit_launched()

    def test_deadline_hook_ignores_longer_or_invalid_values(self):
        # A longer, zero or non-numeric override is ignored (the bound stays seconds + 120 s);
        # a normal view still finishes and quits its viewer.
        for value in ("10000", "0", "off"):
            with self.subTest(value=value):
                (self.tools / "open.launched").unlink(missing_ok=True)
                run = window_view(self.root, {**self.env, "EVAL_APPLE_VIEW_DEADLINE_S": value}, 1)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assert_quit_launched()


if __name__ == "__main__":
    unittest.main()
