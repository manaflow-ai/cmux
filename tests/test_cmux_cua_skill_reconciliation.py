#!/usr/bin/env python3
"""Exercise cross-process skill migration without a live agent or app UI."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "skills/cmux-cua/link-policy.sh"


class SkillReconciliationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sandbox = tempfile.TemporaryDirectory(prefix="cmux-skill-reconcile-")
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {"HOME": str(self.home), "CODEX_HOME": str(self.home / ".codex"),
                    "PATH": "/usr/bin:/bin"}
        self.old = self.bundle("old")
        self.first = self.bundle("first")
        self.second = self.bundle("second")
        self.links = [self.home / root / "skills/cmux-cua" for root in (".agents", ".claude")]
        for link in self.links:
            link.parent.mkdir(parents=True)
            link.symlink_to(self.old)
        self.lock = self.lock_path(self.home)
        self.addCleanup(self.lock.unlink, missing_ok=True)

    def bundle(self, name: str) -> Path:
        app = self.home / "Applications" / f"cmux DEV {name}.app"
        skill = app / "Contents/Resources/cmux-cua"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text("---\nname: cmux-cua\n---\nDriver.\n")
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": f"com.cmuxterm.app.debug.{name}"}, stream)
        return skill

    def lock_path(self, home: Path) -> Path:
        result = subprocess.run(
            ["/bin/bash", "-c", '. "$1"; cmux_cua_skill_home_lock_path "$2"',
             "skill-lock", str(POLICY), str(home)],
            env=self.env, capture_output=True, text=True, check=True,
        )
        return Path(result.stdout)

    def launch(self, provider: str, source: Path) -> subprocess.Popen[str]:
        process = subprocess.Popen(
            ["/bin/bash", "-c", '. "$1"; printf "started\\n"; shift; cmux_cua_skill_reconcile "$@"',
             "skill-reconcile", str(POLICY), provider, str(source), str(self.root), "1"],
            env={**self.env, "CMUX_CUA_TEST_LOCK_READY": "1"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop, process)
        self.assertEqual(process.stdout.readline(), "started\n")
        return process

    def wait_for_lock_attempt(self, process: subprocess.Popen[str]) -> None:
        self.assertEqual(process.stdout.readline(), "ready\n")

    @staticmethod
    def stop(process: subprocess.Popen[str]) -> None:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=20)

    def finish(self, process: subprocess.Popen[str]) -> None:
        stdout, stderr = process.communicate(timeout=25)
        self.assertEqual(process.returncode, 0, f"{stdout}\n{stderr}")

    def test_contending_providers_converge_after_lock_release(self) -> None:
        # Hold the shared lock while both actual reconcilers start. Neither may
        # change either root until release, and both must subsequently finish.
        with self.lock.open("w") as lock:
            self.lock.chmod(0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            first = self.launch("codex", self.first)
            second = self.launch("claude", self.second)
            self.wait_for_lock_attempt(first)
            self.wait_for_lock_attempt(second)
            self.assertEqual([link.resolve() for link in self.links], [self.old.resolve()] * 2)
            fcntl.flock(lock, fcntl.LOCK_UN)
        self.finish(first)
        self.finish(second)
        targets = [link.resolve() for link in self.links]
        self.assertEqual(targets[0], targets[1])
        self.assertIn(targets[0], (self.first.resolve(), self.second.resolve()))

    def test_terminated_lock_owner_does_not_leave_a_stale_lock(self) -> None:
        self.lock.touch(mode=0o600)
        self.lock.chmod(0o600)
        owner = subprocess.Popen(
            [os.sys.executable, "-c",
             'import fcntl,signal,sys; f=open(sys.argv[1],"w"); '
             'fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); signal.pause()',
             str(self.lock)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop, owner)
        self.assertEqual(owner.stdout.readline(), "locked\n")
        process = self.launch("codex", self.first)
        self.wait_for_lock_attempt(process)
        owner.kill()
        owner.communicate(timeout=20)
        self.finish(process)
        self.assertEqual([link.resolve() for link in self.links], [self.first.resolve()] * 2)

    def test_home_alias_uses_the_same_lock(self) -> None:
        alias = self.root / "home-alias"
        alias.symlink_to(self.home)
        self.assertEqual(self.lock_path(alias), self.lock)

    def test_lock_symlink_fails_closed_without_touching_user_data(self) -> None:
        protected = self.root / "user-owned"
        protected.write_text("preserve\n")
        self.lock.symlink_to(protected)
        process = self.launch("codex", self.first)
        process.communicate(timeout=25)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(protected.read_text(), "preserve\n")
        self.assertTrue(self.lock.is_symlink())
        self.assertEqual([link.resolve() for link in self.links], [self.old.resolve()] * 2)


if __name__ == "__main__":
    unittest.main()
