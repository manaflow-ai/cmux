"""scripts/cmux-next/cargo-locks.py: every tracked Cargo.lock is judged whatever changed, and `fix` rewrites only locks.

2026-11-10: eb4f3eb1d94 changed cmux-tui/Cargo.toml and updated cmux-tui/Cargo.lock only; the cmux-app-ffi workspace
(its own lock, cmux-tui's crates by path) went stale and every feat-cmux-next pull request went red.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
SCRIPT = SOURCE / "scripts/cmux-next/cargo-locks.py"


@unittest.skipIf(shutil.which("cargo") is None, "no cargo on this host")
class CargoLocksTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-cargo-locks-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
                    "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"}
        self.git("init", "-q")
        # Two workspaces: core (crates a and b) and ffi, its own workspace, which builds a by path.
        self.write("core/Cargo.toml", '[workspace]\nmembers = ["a", "b"]\nresolver = "2"\n')
        for name in ("a", "b"):
            self.write(f"core/{name}/Cargo.toml", f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\n')
            self.write(f"core/{name}/src/lib.rs", "")
        self.write("ffi/Cargo.toml", '[package]\nname = "ffi"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\na = { path = "../core/a" }\n\n[workspace]\n')
        self.write("ffi/src/lib.rs", "")
        for root in ("core", "ffi"):
            self.cargo(root, "generate-lockfile", "--offline")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True, capture_output=True,
                              text=True).stdout

    def cargo(self, root, *args):
        done = subprocess.run(["cargo", *args], cwd=self.repo / root, env=self.env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def locks(self, mode):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), mode, "--repo", str(self.repo)], env=self.env,
                              capture_output=True, text=True)

    def break_ffi(self):
        """a gains a dependency; only core's lock follows (what eb4f3eb1d94 did)."""
        self.write("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\nb = { path = "../b" }\n')
        self.cargo("core", "metadata", "--offline", "--format-version", "1")
        self.git("add", "-A")
        self.git("commit", "-qm", "a uses b")

    def test_matching_locks_pass(self):
        result = self.locks("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 workspaces, 0 stale", result.stderr)

    def test_a_manifest_change_in_one_workspace_fails_the_other_workspaces_lock(self):
        self.break_ffi()

        result = self.locks("check")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("stale: ffi/Cargo.lock: does not match its manifests", result.stdout)
        self.assertNotIn("core/Cargo.lock", result.stdout)

    def test_fix_rewrites_only_the_stale_lock_and_then_the_check_passes(self):
        self.break_ffi()

        fixed = self.locks("fix")

        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        self.assertIn("fixed: ffi/Cargo.lock", fixed.stdout)
        self.assertEqual(self.git("status", "--porcelain").split(), ["M", "ffi/Cargo.lock"])
        self.assertEqual(self.locks("check").returncode, 0)

    def test_fix_with_nothing_stale_changes_nothing(self):
        fixed = self.locks("fix")

        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        self.assertEqual(fixed.stdout.strip(), "")
        self.assertEqual(self.git("status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
