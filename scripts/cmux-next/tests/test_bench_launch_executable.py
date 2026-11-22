#!/usr/bin/env python3
"""A bench launches the executable its bundle names in Info.plist (CFBundleExecutable), not a guessed name.

Mini scheduler job 12728f0a2b3798713a647469 (2026-11-01, cmux24): scripts/measure/close-flash.sh built a bench
(Release) `cmux DEV closeflash.app` in 817 s, then close-flash-bench.py started `Contents/MacOS/cmux DEV`, which that
bundle does not have: FileNotFoundError before any close. bench_launch.BenchApp guessed the same name and, when it
was missing, took the first file in Contents/MacOS, which can be another executable.

1. BenchApp.binary is the Info.plist's CFBundleExecutable, also when another executable sorts before it and when
   the bundle has no `cmux DEV`; with no Info.plist it keeps the old guess.
   An unreadable plist (truncated XML, not a dictionary) also keeps the guess.
2. close-flash-bench.py's main() starts that executable and lets the app activate (Popen is captured, no app runs,
   and the tag teardown is a no-op, so nothing is signalled).

No app, build or GUI session: fake bundles with Info.plist files, run anywhere with
    python3 -I scripts/cmux-next/tests/test_bench_launch_executable.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

os.environ["BENCH_LAUNCH_OSASCRIPT"] = "/usr/bin/false"
os.environ["BENCH_LAUNCH_STATE_BASE"] = tempfile.mkdtemp(prefix="bench-launch-state-")

OK_SESSION = {"ok": True, "user": "worker", "console_user": "worker", "screen_locked": False,
              "detail": "worker is the console user"}


def fake_bundle(folder: str, tag: str, executable: str | None, files: tuple[str, ...]) -> str:
    """A `cmux DEV <tag>.app` with the given files in Contents/MacOS, and an Info.plist naming `executable`
    (none when it is None)."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    macos = os.path.join(app, "Contents/MacOS")
    os.makedirs(macos)
    for name in files:
        path = os.path.join(macos, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(path, 0o755)
    if executable is not None:
        with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleExecutable": executable, "CFBundleIdentifier": f"com.cmuxterm.app.debug.{tag}"}, f)
    return app


class Started(Exception):
    """Raised by the captured Popen: the command is recorded and nothing runs."""


class BinaryTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-exe-")

    def test_the_binary_is_the_info_plist_executable_when_another_one_sorts_first(self):
        app = fake_bundle(self.folder, "exe-a", "cmux", ("a-helper", "cmux"))
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION)
        self.assertEqual(bench.binary, os.path.join(app, "Contents/MacOS/cmux"))

    def test_the_info_plist_executable_wins_over_a_cmux_dev_file(self):
        app = fake_bundle(self.folder, "exe-b", "cmux", ("cmux", "cmux DEV"))
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION)
        self.assertEqual(bench.binary, os.path.join(app, "Contents/MacOS/cmux"))

    def test_a_bundle_with_no_info_plist_keeps_the_cmux_dev_guess(self):
        app = fake_bundle(self.folder, "exe-c", None, ("a-helper", "cmux DEV"))
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION)
        self.assertEqual(bench.binary, os.path.join(app, "Contents/MacOS/cmux DEV"))

    def test_an_unreadable_info_plist_keeps_the_cmux_dev_guess(self):
        for name, body in (("truncated", b"<?xml version='1.0'?><plist><dict><key>CFBundleExecutable"), ("array", None)):
            with self.subTest(name):
                app = fake_bundle(self.folder, f"exe-bad-{name}", None, ("a-helper", "cmux DEV"))
                with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
                    if body is None:
                        plistlib.dump(["not", "a", "dict"], f)
                    else:
                        f.write(body)
                bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION)
                self.assertEqual(bench.binary, os.path.join(app, "Contents/MacOS/cmux DEV"))

    def test_an_info_plist_naming_a_missing_executable_says_so(self):
        app = fake_bundle(self.folder, "exe-d", "cmux", ("a-helper",))
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION)
        with self.assertRaises(SystemExit) as raised:
            _ = bench.binary
        self.assertIn("CFBundleExecutable", str(raised.exception))


class CloseFlashLaunchTests(unittest.TestCase):
    def test_close_flash_main_starts_the_info_plist_executable_and_may_activate(self):
        """The fleet run's path: close-flash-bench.py main() on a bench bundle whose executable is not `cmux DEV`.
        On the base it started `Contents/MacOS/cmux DEV` (job 12728f0a2b37: FileNotFoundError)."""
        folder = tempfile.mkdtemp(prefix="close-flash-exe-")
        app = fake_bundle(folder, "closeflash", "cmux", ("a-helper", "cmux"))
        spec = importlib.util.spec_from_file_location("close_flash_bench", HERE / "close-flash-bench.py")
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        started: list[tuple[list[str], dict]] = []
        real_popen = bl.subprocess.Popen

        def popen(argv, **kwargs):
            # Only a spawn from the bundle is captured; the launch's own probes run (sw_vers answers a fixed version).
            if argv and argv[0] == "sw_vers":
                return real_popen(["echo", "26.0"], **kwargs)
            if not str(argv[0]).startswith(app + "/"):
                return real_popen(argv, **kwargs)
            started.append((list(argv), dict(kwargs.get("env") or {})))
            raise Started()

        class NoTeardown:
            """The tag teardown would signal the bundle's processes: here there are none, and none may be signalled."""
            def __init__(self, *_args, **_kwargs): pass
            def install(self): pass
            def end(self): pass

        # The host checks of a real launch are macOS facts; here they answer "fine" so the launch reaches its spawn.
        with mock.patch.object(bl.subprocess, "Popen", popen), \
                mock.patch.dict(sys.modules, {"tag_teardown": type(sys)("tag_teardown")}), \
                mock.patch.object(bl, "gui_session", lambda: OK_SESSION), \
                mock.patch.object(bl, "lpm_switch_problem", lambda: None), \
                mock.patch.object(bl, "low_power_mode", lambda: False), \
                mock.patch.object(bl, "mute_output", lambda: "muted (test)"), \
                mock.patch.object(bl, "finder_limits", lambda: contextlib.nullcontext({})), \
                mock.patch.object(bl.BenchApp, "running_pids", lambda self: []):
            sys.modules["tag_teardown"].TagTeardown = NoTeardown
            with self.assertRaises(Started):
                bench.main(["--app", app, "--out", os.path.join(folder, "out"), "--kinds", "closeWindow", "--close-rounds", "1"])
        self.assertEqual([argv for argv, _ in started], [[os.path.join(app, "Contents/MacOS/cmux")]])
        # The app must be allowed to activate (the close button flashes only in an active app).
        self.assertNotIn("CMUX_NEXT_NO_ACTIVATE", started[0][1])


if __name__ == "__main__":
    unittest.main()
