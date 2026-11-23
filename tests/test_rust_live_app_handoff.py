#!/usr/bin/env python3
"""rust-live.py swaps a cmux app's daemon the way the app hands off its own: the new build renamed over
the app's bin/cmux (its cmux-tui link kept), SIGTERM to the owner, and the app's own `server ensure`
brings up the next owner. A no-show puts the file back; `stop` restores the app's own build.

The owner is a real process (sleep); a thread plays the app, starting the next owner from the file
once the old one exits. No cmux build or app is needed."""
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
rust_live = importlib.util.module_from_spec(spec)
sys.modules["rust_live"] = rust_live  # dataclasses look their module up here
spec.loader.exec_module(rust_live)


class FakeApp:
    """An app bundle whose daemon is a sleep process; `respawn` is the app's reconnect."""

    def __init__(self, root: Path, respawn: bool = True, backoff: float = 0.05):
        self.bin = root / "cmux DEV.app" / "Contents" / "Resources" / "bin"
        self.bin.mkdir(parents=True)
        self.file = self.bin / "cmux"
        self.file.write_text("base build\n")
        (self.bin / "cmux-tui").symlink_to("cmux")
        self.respawn = respawn
        self.backoff = backoff
        self.builds_run: list[str] = []
        self.owner = self.start()
        self.changed = threading.Condition()  # notified each time the app brings up a next owner
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.supervise, daemon=True)
        self.thread.start()

    def start(self) -> subprocess.Popen:
        self.builds_run.append(self.file.read_text())
        return subprocess.Popen(["sleep", "600"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def supervise(self) -> None:
        while not self.stopped.is_set():
            if self.owner.poll() is not None and self.respawn:
                if self.stopped.wait(self.backoff):  # the app's reconnect backoff
                    break
                with self.changed:
                    self.owner = self.start()
                    self.changed.notify_all()
            time.sleep(0.01)

    def status(self):
        return (self.owner.pid, self.file) if self.owner.poll() is None else None

    def wait_for_owner_other_than(self, old: int, timeout: float = 30) -> bool:
        """Until the app has brought up an owner that is not `old` (the timeout bounds only a failure)."""
        with self.changed:
            return self.changed.wait_for(lambda: (self.status() or (old, None))[0] != old, timeout)

    def close(self) -> None:
        self.stopped.set()
        self.thread.join()
        if self.owner.poll() is None:
            self.owner.send_signal(signal.SIGKILL)
            self.owner.wait()


class AppHandoffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.new = self.tmp / "build" / "cmux-tui"
        self.new.parent.mkdir()
        self.new.write_text("pr build\n")
        self.state = self.tmp / "state"
        self.state.mkdir()

    def swapper(self, app: FakeApp):
        swapper = rust_live.Swapper(None, "/fake.sock", state=self.state)
        swapper.owner = lambda _cli, **_k: app.status()
        swapper.cli = lambda *_a, **_k: self.fail("an app's daemon must not go through server restart/stop/ensure")
        return swapper

    def test_the_new_build_runs_from_the_apps_file_with_the_link_kept(self):
        app = FakeApp(self.tmp)
        self.addCleanup(app.close)
        first = app.owner.pid
        steps = self.swapper(app).swap({"cmux-tui": self.new})
        self.assertEqual(steps["cmux-tui"], "app handoff")
        self.assertNotEqual(app.owner.pid, first)
        self.assertEqual(app.builds_run, ["base build\n", "pr build\n"])
        self.assertTrue((app.bin / "cmux-tui").is_symlink())
        self.assertEqual((app.bin / "cmux-tui").read_text(), "pr build\n")
        self.assertEqual(sorted(p.name for p in app.bin.iterdir()), ["cmux", "cmux-tui"])

    def test_stop_puts_the_apps_own_build_back_and_hands_off_to_it(self):
        app = FakeApp(self.tmp)
        self.addCleanup(app.close)
        swapper = self.swapper(app)
        swapper.swap({"cmux-tui": self.new})
        second = self.new.with_name("cmux-tui-2")
        second.write_text("pr build 2\n")
        swapper.swap({"cmux-tui": second})
        marker = swapper.marker()
        self.assertTrue(marker.is_file())
        # A new watcher (the old one died) still knows the app's own build.
        later = rust_live.Swapper(None, "/fake.sock", state=self.state)
        later.owner = lambda _cli, **_k: app.status()
        self.assertEqual(later.restore_app(), str(app.file))
        self.assertEqual(app.file.read_text(), "base build\n")
        self.assertEqual(app.builds_run[-1], "base build\n")
        self.assertFalse(marker.exists())

    def test_no_new_owner_puts_the_file_back(self):
        app = FakeApp(self.tmp, respawn=False)
        self.addCleanup(app.close)
        swapper = self.swapper(app)
        old = rust_live.APP_OWNER_SECS
        rust_live.APP_OWNER_SECS = 0.5
        self.addCleanup(setattr, rust_live, "APP_OWNER_SECS", old)
        with self.assertRaisesRegex(RuntimeError, "back as it was"):
            swapper.swap({"cmux-tui": self.new})
        self.assertEqual(app.file.read_text(), "base build\n")
        self.assertEqual(sorted(p.name for p in app.bin.iterdir()), ["cmux", "cmux-tui"])

    def test_a_watcher_on_another_session_leaves_this_apps_marker_and_daemon_alone(self):
        app = FakeApp(self.tmp)
        self.addCleanup(app.close)
        self.swapper(app).swap({"cmux-tui": self.new})
        swapped_owner = app.owner.pid
        other = rust_live.Swapper(None, "/other.sock", state=self.state)
        other.owner = lambda _cli, **_k: app.status()
        self.assertIsNone(other.restore_app())
        self.assertEqual(app.owner.pid, swapped_owner)
        self.assertEqual(app.file.read_text(), "pr build\n")
        self.assertTrue(self.swapper(app).marker().is_file())

    def test_an_owner_that_comes_up_after_the_deadline_is_handed_back_to_the_restored_file(self):
        app = FakeApp(self.tmp)
        self.addCleanup(app.close)
        swapper = self.swapper(app)
        real_wait = swapper.wait_for_new_owner
        missed = []

        def wait(cli, old):
            # The first wait gives up just before the app's new owner (from the new build) answers: it returns
            # once that owner is up, as a poll that ran out a moment too soon.
            if missed:
                return real_wait(cli, old)
            missed.append(old)
            if not app.wait_for_owner_other_than(old):
                raise AssertionError("the app brought up no new owner after the handoff")
            return None

        swapper.wait_for_new_owner = wait
        with self.assertRaisesRegex(RuntimeError, "back as it was"):
            swapper.swap({"cmux-tui": self.new})
        self.assertEqual(app.file.read_text(), "base build\n")
        self.assertEqual(app.builds_run, ["base build\n", "pr build\n", "base build\n"])

    def test_a_pid_that_is_no_longer_the_owner_gets_no_signal(self):
        # The owner and the stranger are pids only; a fake kill records every signal sent.
        swapper = rust_live.Swapper(None, "/fake.sock", state=self.state)
        owner, stranger = 4242, 4343  # the stranger: an owner that exited, its pid another process's by now
        swapper.owner = lambda _cli, **_k: (owner, self.new)
        sent = []
        with unittest.mock.patch.object(rust_live.os, "kill", lambda pid, sig: sent.append((pid, sig))):
            swapper.terminate_owner(self.new, stranger)
            self.assertEqual(sent, [])
            swapper.terminate_owner(self.new, owner)  # the owner still is: it gets the SIGTERM
        self.assertEqual(sent, [(owner, signal.SIGTERM)])

    def test_a_status_that_hangs_counts_as_no_owner(self):
        swapper = rust_live.Swapper(None, "/fake.sock", state=self.state)

        def hang(*words, timeout):
            raise subprocess.TimeoutExpired(words, timeout)

        swapper.cli = lambda _bin, *words, timeout=60: hang(*words, timeout=timeout)
        self.assertIsNone(swapper.owner(self.new, timeout=0.5))

    @unittest.skipUnless(Path("/proc/self/exe").exists(), "reads /proc")
    def test_an_owner_whose_file_a_swap_renamed_over_is_still_this_apps_owner(self):
        # On Linux the owner's /proc/PID/exe reads "PATH (deleted)" right after the new build is renamed over
        # PATH, and so does `server status`'s pid. Before: no owner, no SIGTERM, a 35 s wait and a rollback.
        bin_dir = self.tmp / "cmux DEV.app" / "Contents" / "Resources" / "bin"
        bin_dir.mkdir(parents=True)
        file = bin_dir / "cmux"
        shutil.copy2(shutil.which("sleep"), file)
        owner = subprocess.Popen([str(file), "600"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(owner.wait)
        self.addCleanup(owner.kill)
        staged = bin_dir / ".cmux.new"
        shutil.copy2(shutil.which("sleep"), staged)
        os.replace(staged, file)
        self.assertTrue(os.readlink(f"/proc/{owner.pid}/exe").endswith(" (deleted)"))
        swapper = rust_live.Swapper(None, "/fake.sock", state=self.state)
        # The status a cmux-tui of today prints: its text form pads `pid`, so the JSON form is asked for.
        swapper.cli = lambda _bin, *words, **_k: subprocess.CompletedProcess(
            words, 0, json.dumps({"pid": owner.pid, "status": "running"}) if "--json" in words else f"pid         {owner.pid}\n", "")
        self.assertEqual(swapper.owner(file), (owner.pid, file))
        self.assertEqual(swapper.app_file(file), file.resolve())

    def test_a_restore_whose_daemon_never_comes_back_says_so_and_keeps_the_marker(self):
        app = FakeApp(self.tmp)
        self.addCleanup(app.close)
        swapper = self.swapper(app)
        swapper.swap({"cmux-tui": self.new})
        app.respawn = False
        old = rust_live.APP_OWNER_SECS
        rust_live.APP_OWNER_SECS = 0.5
        self.addCleanup(setattr, rust_live, "APP_OWNER_SECS", old)
        with self.assertRaisesRegex(RuntimeError, "run stop again"):
            swapper.restore_app()
        self.assertEqual(app.file.read_text(), "base build\n")
        self.assertTrue(swapper.marker().is_file())

    def test_stop_finishes_a_restore_the_watcher_left_and_says_when_it_cannot(self):
        # The watcher's own restore timed out and it exited: its pid file is gone, its marker is not.
        # Before: `stop` said "not watching" and nothing put the app's build back.
        app = FakeApp(self.tmp)
        self.addCleanup(app.close)
        self.swapper(app).swap({"cmux-tui": self.new})
        status = lambda self_, _cli, **_k: app.status()
        self.addCleanup(setattr, rust_live.Swapper, "owner", rust_live.Swapper.owner)
        rust_live.Swapper.owner = status
        old_env = os.environ.get("CMUX_RUST_LIVE_STATE_DIR")
        os.environ["CMUX_RUST_LIVE_STATE_DIR"] = str(self.state)
        self.addCleanup(lambda: os.environ.pop("CMUX_RUST_LIVE_STATE_DIR") if old_env is None
                        else os.environ.__setitem__("CMUX_RUST_LIVE_STATE_DIR", old_env))
        app.respawn = False
        old = rust_live.APP_OWNER_SECS
        rust_live.APP_OWNER_SECS = 0.5
        self.addCleanup(setattr, rust_live, "APP_OWNER_SECS", old)
        self.assertEqual(rust_live.command_stop(None), 1)
        self.assertTrue(any(self.state.glob("app-original-*.json")))
        app.respawn = True
        app.owner = app.start()
        self.assertEqual(rust_live.command_stop(None), 0)
        self.assertEqual(app.file.read_text(), "base build\n")
        self.assertEqual(app.builds_run[-1], "base build\n")
        self.assertFalse(any(self.state.glob("app-original-*.json")))

    def test_a_daemon_outside_an_app_still_restarts_through_the_cli(self):
        swapper = rust_live.Swapper("s", None, state=self.state)
        loose = self.tmp / "target" / "cmux-tui"
        loose.parent.mkdir()
        loose.write_text("x")
        calls = []
        swapper.owner = lambda _cli, **_k: (os.getpid(), loose)
        swapper.cli = lambda _bin, *words, **_k: calls.append(words) or subprocess.CompletedProcess(words, 0, "", "")
        self.assertEqual(swapper.swap({"cmux-tui": self.new})["cmux-tui"], "server restart")
        self.assertEqual(calls, [("server", "restart")])


if __name__ == "__main__":
    unittest.main()
