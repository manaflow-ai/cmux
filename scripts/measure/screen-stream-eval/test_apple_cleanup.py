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

    def test_second_launch_during_settle_binds_neither(self):
        # Someone else's Screen Sharing starts 0.3 s after ours: which one is ours is unknown, so the
        # run binds neither and stops neither (binding theirs would later quit their viewer).
        others = self.tools / "others.launched"
        stub(self.tools, "open", 'while (($#)); do [[ $1 == -a ]] && { app=$2; shift; }; shift; done\n'
                                 '"$app/Contents/MacOS/Screen Sharing" 1000 </dev/null >/dev/null 2>&1 &\n'
                                 'echo $! >>"$0.launched"\n'
                                 '(sleep 0.3; "$app/Contents/MacOS/Screen Sharing" 1000 </dev/null >/dev/null 2>&1 &\n'
                                 ' echo $! >>"' + str(others) + '") </dev/null >/dev/null 2>&1 &\n')
        def reap_others():
            for pid in ([int(p) for p in others.read_text().split()] if others.exists() else []):
                if alive(pid):
                    os.kill(pid, 9)
        self.addCleanup(reap_others)
        run = window_view(self.root, self.env, 2)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("not 1", run.stderr)
        self.assertFalse((self.root / "state/viewer.pid").exists())
        theirs = [int(p) for p in others.read_text().split()]
        self.assertEqual(len(theirs), 1)
        self.assertTrue(alive(theirs[0]), "a Screen Sharing process this run did not start was stopped")

    def test_watchdog_of_a_killed_verb_acts_on_nothing(self):
        # The verb is killed outright, so its EXIT trap never runs. At the deadline its watchdog must
        # not act on pids it can no longer trust (the verb's pid and viewer.pid may be reused by then).
        hung = self.tools / "osascript.pid"
        stub(self.tools, "osascript", f'cat >/dev/null; echo $$ >"{hung}"; exec sleep 1000\n')
        def reap_hung():
            if hung.exists() and alive(int(hung.read_text())):
                os.kill(int(hung.read_text()), 9)
        self.addCleanup(reap_hung)
        verb = subprocess.Popen(["bash", str(Path(__file__).resolve().parent / "targets/apple.sh"), "window-view", "2",
                                 str(self.root / "frame.png"), str(self.root / "go"), str(self.root / "window.raw")],
                                env={**self.env, "EVAL_APPLE_VIEW_DEADLINE_S": "3"},
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        end = time.monotonic() + 10
        while not hung.exists() and time.monotonic() < end:
            time.sleep(0.1)
        self.assertTrue(hung.exists(), "the view never reached the hung step")
        rows = subprocess.run(["ps", "-eo", "pid=,ppid=,args="], capture_output=True, text=True).stdout.splitlines()
        watchdogs = [int(f[0]) for f in (r.split(None, 2) for r in rows)
                     if len(f) == 3 and f[1] == str(verb.pid) and "apple-watchdog" in f[2]]
        self.assertEqual(len(watchdogs), 1, f"the verb's watchdog: {watchdogs}")
        verb.kill()
        verb.wait()
        pids = launched(self.tools)
        self.assertEqual(len(pids), 1, pids)
        # The watchdog exits once its 3 s deadline passed and it decided what to act on.
        self.assertTrue(gone_within(watchdogs[0], 15), "the orphaned watchdog never reached its 3 s deadline")
        self.assertTrue(alive(pids[0]), "an orphaned watchdog stopped a viewer after its verb was gone")
        self.assertFalse((self.root / "state/view-timed-out").exists())

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
