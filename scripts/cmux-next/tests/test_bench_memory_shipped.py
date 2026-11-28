#!/usr/bin/env python3
"""bench_memory launches a shipped bundle (the published NIGHTLY, perf-idle-ab.sh dmg=nightly) as a first install:
its own home through CFFIXED_USER_HOME (the app finds Application Support through homeDirectoryForCurrentUser, not
HOME), the updater off, a socket of its own, and never beside another copy of the bundle id (a person's NIGHTLY).
A DEV bundle's launch is as before."""
from __future__ import annotations

import contextlib
import ctypes
import io
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402


def bundle(root: Path, bundle_id: str) -> str:
    app = root / "cmux NEXT NIGHTLY.app"
    (app / "Contents").mkdir(parents=True)
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "cmux"}, handle)
    return str(app)


class FakeSmoke:
    UPDATER_OFF_VARIABLE = "CMUX_DISABLE_AUTO_UPDATE"

    class CannotRun(Exception):
        pass

    def __init__(self, copies=()):
        self.copies = list(copies)
        self.keychains = []

    def live_copies(self, _bundle_id):
        return self.copies

    def login_keychain(self, env):
        self.keychains.append(env["CFFIXED_USER_HOME"])

    class DefaultsAside:
        def __init__(self, bundle_id, root):
            self.bundle_id = bundle_id

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False


class ShippedTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        bm._shipped_aside = None

    def test_dev_bundle_is_not_shipped(self):
        self.assertFalse(bm.is_shipped(bundle(self.tmp, "com.cmuxterm.app.debug.idleab-base")))
        self.assertTrue(bm.is_shipped(bundle(self.tmp / "n", "com.cmuxterm.app.nightly")))

    def test_isolation_sets_its_own_home_updater_off_and_socket(self):
        app = bundle(self.tmp, "com.cmuxterm.app.nightly")
        smoke = FakeSmoke()
        env = {"HOME": str(self.tmp / "scratch" / "home")}
        with mock.patch.object(bm, "_fresh_smoke", return_value=smoke), mock.patch("atexit.register"):
            bm.shipped_isolation(app, env, relaunch=False)
        self.assertEqual(env["CFFIXED_USER_HOME"], env["HOME"])
        self.assertEqual(env["CMUX_DISABLE_AUTO_UPDATE"], "1")
        self.assertTrue(env["CMUX_NEXT_SOCKET_PATH"].startswith("/tmp/cmux") and env["CMUX_NEXT_SOCKET_PATH"].endswith(".sock"))
        self.assertLess(len(env["CMUX_NEXT_SOCKET_PATH"]), 104)
        self.assertTrue((Path(env["HOME"]) / "Library" / "Application Support").is_dir())
        self.assertEqual(smoke.keychains, [env["HOME"]])
        self.assertIsNotNone(bm._shipped_aside)

    def test_refused_beside_another_copy(self):
        app = bundle(self.tmp, "com.cmuxterm.app.nightly")
        smoke = FakeSmoke([{"pid": 42, "bundle": "/Applications/cmux NEXT NIGHTLY.app"}])
        err = io.StringIO()
        with mock.patch.object(bm, "_fresh_smoke", return_value=smoke), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as stop:
                bm.shipped_isolation(app, {"HOME": str(self.tmp / "h")}, relaunch=False)
        self.assertEqual(stop.exception.code, 3)
        self.assertIn("another copy of com.cmuxterm.app.nightly runs on this host (pid 42", err.getvalue())

    def test_its_own_copy_is_not_another(self):
        app = bundle(self.tmp, "com.cmuxterm.app.nightly")
        smoke = FakeSmoke([{"pid": 43, "bundle": app}])
        with mock.patch.object(bm, "_fresh_smoke", return_value=smoke), mock.patch("atexit.register"):
            bm.shipped_isolation(app, {"HOME": str(self.tmp / "h")}, relaunch=False)


if __name__ == "__main__":
    unittest.main()
