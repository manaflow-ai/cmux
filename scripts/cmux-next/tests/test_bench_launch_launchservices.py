#!/usr/bin/env python3
"""A bench can start the app through LaunchServices (`open -n`), as a person's Finder or Dock launch does.

The direct launch (the default) makes the app a child of the bench's harness, so on a fleet worker it inherits the
worker step's scheduling: in fleet step f91e7c7b9c4f16ff1ddb0289 (cmux21, 2026-11-20) every thread of the app,
its main thread included, and of its Chromium renderer and GPU helpers ran at scheduler priority 20 (utility)
while it was frontmost, where a LaunchServices-launched frontmost app's main thread runs at 46-47.

1. BenchApp keeps `direct` as its default and refuses an unknown mode.
2. open_command starts a new instance (`-n`) of the bundle, passes every variable with `--env` and sends the
   app's output to the bench's log.
3. A `launchservices` launch runs `open`, finds the one new process of the bundle's main executable, and returns a
   LaunchedPid for it; `open` failing is a LaunchError (no app is started: subprocess.run and the process list
   are stubbed).
4. LaunchedPid.poll/wait follow the PID (this test's own short-lived child), and wait times out like Popen's.

No app, build or GUI session; run anywhere with
    python3 -I scripts/cmux-next/tests/test_bench_launch_launchservices.py
"""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

os.environ.setdefault("BENCH_LAUNCH_STATE_BASE", tempfile.mkdtemp(prefix="bench-launch-state-"))


def fake_bundle(folder: str, tag: str) -> str:
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    Path(app, "Contents/MacOS/cmux DEV").write_text("")
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleExecutable": "cmux DEV"}, f)
    return app


class LaunchModeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-ls-")
        self.app = fake_bundle(self.folder, "lstest")

    def test_default_is_direct_and_unknown_is_refused(self):
        self.assertEqual(bl.BenchApp(self.app, out=self.folder, teardown=False).launch_mode, "direct")
        with self.assertRaises(ValueError):
            bl.BenchApp(self.app, out=self.folder, teardown=False, launch="spawn")

    def test_open_command(self):
        command = bl.open_command(self.app, {"B": "2", "A": "x=y"}, "/tmp/log")
        self.assertEqual(command[:4], ["/usr/bin/open", "-n", "-a", self.app])
        self.assertEqual(command[4:8], ["--env", "A=x=y", "--env", "B=2"])
        self.assertEqual(command[-4:], ["--stdout", "/tmp/log", "--stderr", "/tmp/log"])

    def test_launchservices_finds_the_new_process(self):
        bench = bl.BenchApp(self.app, out=self.folder, teardown=False, launch="launchservices")
        main = os.path.join(self.app, "Contents/MacOS/cmux DEV")
        listings = iter([[], [], [4242]])
        ran = []

        def fake_run(command, **kwargs):
            ran.append(command)
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(bl.subprocess, "run", side_effect=fake_run), \
                mock.patch.object(bench, "running_pids", return_value=[]), \
                mock.patch.object(bl, "bundle_pids", side_effect=lambda app, inside: next(listings)) as pids:
            with open(os.path.join(self.folder, "log"), "a") as log:
                process = bench._open_through_launchservices({"K": "V"}, log, timeout=5)
        self.assertIsInstance(process, bl.LaunchedPid)
        self.assertEqual(process.pid, 4242)
        self.assertEqual(ran[0][:4], ["/usr/bin/open", "-n", "-a", self.app])
        self.assertIn("K=V", ran[0])
        self.assertEqual(pids.call_args.args[1], os.path.relpath(main, self.app))

    def test_open_failure_is_a_launch_error(self):
        bench = bl.BenchApp(self.app, out=self.folder, teardown=False, launch="launchservices")
        failed = subprocess.CompletedProcess([], 1, "", "LSOpenURLsWithRole() failed")
        with mock.patch.object(bl.subprocess, "run", return_value=failed), \
                mock.patch.object(bench, "running_pids", return_value=[]):
            with open(os.path.join(self.folder, "log"), "a") as log, self.assertRaises(bl.LaunchError) as raised:
                bench._open_through_launchservices({}, log, timeout=5)
        self.assertEqual(raised.exception.reason, "open-failed")


class LaunchedPidTests(unittest.TestCase):
    def test_poll_and_wait_follow_the_pid(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.5)"])
        launched = bl.LaunchedPid(child.pid)
        self.assertIsNone(launched.poll())
        with self.assertRaises(subprocess.TimeoutExpired):
            launched.wait(0.05)
        child.wait(10)  # reap our own child, so its PID is gone
        self.assertEqual(launched.wait(5), 1)


if __name__ == "__main__":
    unittest.main()
