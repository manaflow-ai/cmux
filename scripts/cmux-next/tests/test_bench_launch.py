#!/usr/bin/env python3
"""bench_launch.py never cuts off a live same-tag app (review 2 of pl-fleet-gui).

1. `check` against a bundle whose app already runs refuses with tag-in-use, and its stop() must not run the tag
   teardown: that teardown ends every process of the bundle, which here is the live app, not one this run started.
2. The pre-launch socket probe unlinks only a socket nothing listens on: a socket that accepts but does not answer in
   time (a busy main thread, a long restore) belongs to a live app of the tag (another bundle path).
3. No environment variable passes the GUI-session gate; the one launch without a session is the explicit socket-only
   check, and its report says so.

Runs on any Mac, no GUI session or build needed (the session read is injected or the check is `--socket-only`, and a
copy of /bin/sleep stands in for the app's executable). Signals only the processes it starts.

    python3 scripts/cmux-next/tests/test_bench_launch.py
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402


def fake_bundle(folder: str, tag: str) -> str:
    """A `cmux DEV <tag>.app` whose main executable is a copy of /bin/sleep."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    macos = os.path.join(app, "Contents/MacOS")
    os.makedirs(macos)
    # copy, not copy2: copy2 also copies /bin/sleep's system flags, and chflags fails with EPERM for a normal
    # account (Python 3.9 of Xcode 26.6 on aws-m4pro-3, macOS 27.0.1).
    shutil.copy("/bin/sleep", os.path.join(macos, "cmux DEV"))
    return app


OK_SESSION = {"ok": True, "user": "worker", "console_user": "worker", "screen_locked": False,
              "detail": "worker is the console user"}
NO_SESSION = {"ok": False, "user": "worker", "console_user": None, "screen_locked": None,
              "detail": "nobody is logged in on the console (login window); worker has no GUI session"}


class SessionGateTests(unittest.TestCase):
    """No environment variable turns the GUI-session gate off (deep review of fleet-gui, findings 3 and 7): a step
    that exported BENCH_LAUNCH_ANY_SESSION=1 got past it, and every bench in that environment then measured a display
    that does not tick and wrote its frame rows as a normal run."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-gate-")
        self.tag = f"bl-gate-{os.getpid()}"

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_launch_without_a_gui_session_starts_no_app_whatever_the_environment(self):
        app = bl.BenchApp(fake_bundle(self.folder, self.tag), out=os.path.join(self.folder, "out"), teardown=False)
        with mock.patch.object(bl, "gui_session", return_value=NO_SESSION), \
                mock.patch.dict(os.environ, {"BENCH_LAUNCH_ANY_SESSION": "1"}):
            with self.assertRaises(bl.LaunchError) as refused:
                app.launch(timeout=5)
        try:
            self.assertEqual(refused.exception.reason, "no-gui-session")
            self.assertIsNone(app.process, "the gate let an app start with no GUI session")
        finally:
            if app.process and app.process.poll() is None:
                app.process.kill()  # the exact process this test made launch() start
                app.process.wait()

    def test_the_bench_session_check_cannot_be_skipped(self):
        with mock.patch.object(bl, "gui_session", return_value=NO_SESSION), \
                mock.patch.dict(os.environ, {"BENCH_LAUNCH_ANY_SESSION": "1"}), \
                mock.patch.object(bl, "note"):
            with self.assertRaises(SystemExit) as refused:
                bl.require_gui_session("test", argv=[])
        self.assertEqual(refused.exception.code, 1)


class TagInUseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-test-")
        self.tag = f"bl-test-{os.getpid()}"
        self.started: list[subprocess.Popen] = []

    def tearDown(self):
        for process in self.started:
            if process.poll() is None:
                process.kill()  # the exact process this test started
                process.wait()
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_check_refused_as_tag_in_use_leaves_the_running_app_alive(self):
        app = fake_bundle(self.folder, self.tag)
        live = subprocess.Popen([os.path.join(app, "Contents/MacOS/cmux DEV"), "300"])
        self.started.append(live)
        report_path = os.path.join(self.folder, "check.json")
        result = subprocess.run(
            [sys.executable, str(HERE / "bench_launch.py"), "check", "--socket-only", "--app", app, "--timeout", "5",
             "--out", os.path.join(self.folder, "out"), "--json", report_path],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tag-in-use", result.stdout)
        self.assertIsNone(live.poll(), "the refused check's teardown ended the live app of the bundle:\n" + result.stdout)
        with open(report_path) as f:
            report = json.load(f)
        self.assertEqual(report.get("reason"), "tag-in-use")
        self.assertIs(report.get("socket_only"), True, "a socket-only check's report does not say so")
        self.assertIn("ok", report.get("gui_session") or {}, "a socket-only check's report has no gui_session")

    def test_a_launch_with_an_injected_session_is_refused_as_tag_in_use_and_stops_nothing(self):
        app_path = fake_bundle(self.folder, self.tag)
        live = subprocess.Popen([os.path.join(app_path, "Contents/MacOS/cmux DEV"), "300"])
        self.started.append(live)
        app = bl.BenchApp(app_path, out=os.path.join(self.folder, "out"), session=lambda: OK_SESSION)
        with mock.patch.object(bl, "note"):
            with self.assertRaises(bl.LaunchError) as refused:
                app.launch(timeout=5)
            app.stop()  # what every bench's finally runs: the bundle's live app is another run's
        self.assertEqual(refused.exception.reason, "tag-in-use")
        self.assertIsNone(app.process)
        self.assertEqual(refused.exception.report.get("gui_session"), OK_SESSION)
        self.assertIsNone(live.poll(), "stop() after a refused launch ended the live app of the bundle")

    def test_a_socket_that_accepts_but_does_not_answer_is_in_use(self):
        path = os.path.join(self.folder, "silent.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(4)  # never accepts or answers: connect() still succeeds through the backlog
        try:
            self.assertTrue(bl.socket_in_use(path), "a live socket that answers slowly counted as free")
        finally:
            listener.close()

    def test_a_socket_nothing_listens_on_is_free(self):
        path = os.path.join(self.folder, "stale.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.close()  # the file stays, nothing listens: connect() is refused
        self.assertTrue(os.path.exists(path))
        self.assertFalse(bl.socket_in_use(path))
        self.assertFalse(bl.socket_in_use(os.path.join(self.folder, "missing.sock")))

    def test_the_state_socket_and_its_tmp_link_are_probed_once(self):
        target = os.path.join(self.folder, "state.sock")
        open(target, "w").close()
        link = os.path.join(self.folder, "link.sock")
        os.symlink(target, link)
        self.assertEqual(bl.unique_paths([target, link]), [target])


if __name__ == "__main__":
    unittest.main()
