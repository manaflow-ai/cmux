#!/usr/bin/env python3
"""launch_tti_check.fresh_copy: a cold round's copy goes to a new folder, never back into the path the app just ran
from. On 2026-11-20 (cmuxterm-hq run 44723138688) the re-copy in place hit "Operation not permitted" on every file
of the bundle on cmux-austin-mini-0, every cold round failed, and the three launch-to-interaction rows read STALE.

No Mac: `ditto` is replaced by a copy. So this proves where the copy goes and what is removed, NOT how macOS treats a
launched bundle's path.
Run: python3 -I scripts/ci/test_launch_tti_check.py"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import launch_tti_check as M  # noqa: E402


def fake_ditto(argv, **_):
    shutil.copytree(argv[1], argv[2], symlinks=True)
    return subprocess.CompletedProcess(argv, 0)


class FreshCopy(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="tti-fresh-copy-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.pristine = self.root / "pristine.noindex" / "cmux NIGHTLY.app"
        (self.pristine / "Contents" / "MacOS").mkdir(parents=True)
        (self.pristine / "Contents" / "MacOS" / "cmux").write_text("new")
        self.app = self.root / "app" / "cmux NIGHTLY.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "cmux").write_text("launched")

    def test_the_copy_goes_to_a_new_folder_and_the_launched_copy_is_removed(self):
        with mock.patch.object(M.subprocess, "run", fake_ditto):
            new = M.fresh_copy(self.app, self.pristine, 2)
        self.assertEqual(new, self.root / "app-cold-2" / "cmux NIGHTLY.app")
        self.assertEqual((new / "Contents" / "MacOS" / "cmux").read_text(), "new")
        self.assertFalse(self.app.exists())

    def test_each_cold_round_gets_its_own_folder(self):
        with mock.patch.object(M.subprocess, "run", fake_ditto):
            first = M.fresh_copy(self.app, self.pristine, 1)
            second = M.fresh_copy(first, self.pristine, 3)
        self.assertNotEqual(first.parent, second.parent)
        self.assertTrue(second.exists())
        self.assertFalse(first.exists())

    def test_a_launched_copy_that_cannot_be_removed_does_not_fail_the_round(self):
        def refuse(path, ignore_errors=False, **_):
            if not ignore_errors:
                raise PermissionError(1, "Operation not permitted", str(path))
        with mock.patch.object(M.subprocess, "run", fake_ditto), mock.patch.object(M.shutil, "rmtree", refuse):
            new = M.fresh_copy(self.app, self.pristine, 1)
        self.assertTrue(new.exists())

    def test_a_failed_copy_raises_for_the_round_to_report(self):
        def fail(argv, **_):
            raise subprocess.CalledProcessError(1, argv)
        with mock.patch.object(M.subprocess, "run", fail):
            with self.assertRaises(subprocess.SubprocessError):
                M.fresh_copy(self.app, self.pristine, 1)


class UpdaterOff(unittest.TestCase):
    """Every copy the check starts (the cold_install round's fresh copy of an older build included) has the app's
    updater off: on 2026-11-22 a cold_install copy saw a newer build, downloaded it, and Sparkle's installer asked
    the fleet Mac for an administrator password. The run's environment is the smoke's fresh_env."""

    def test_the_measured_launch_environment_turns_the_updater_off(self):
        import fresh_home_launch_smoke as smoke
        root = Path(tempfile.mkdtemp(prefix="tti-updater-off-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        env = smoke.fresh_env(root, root / "s.sock", 3)
        for path in ("in_app", "posted"):
            self.assertEqual(M.launch_env(env, root / "probe.csv", path)["CMUX_DISABLE_AUTO_UPDATE"], "1")


if __name__ == "__main__":
    unittest.main()
