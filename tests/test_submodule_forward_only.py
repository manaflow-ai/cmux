#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/submodule_forward_only.py."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/submodule_forward_only.py"


def git(*args: str, cwd: Path) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"git {' '.join(args)} failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


class SubmoduleForwardOnlyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="submodule-forward-only-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.subrepo = self.root / "subrepo"
        self.superrepo = self.root / "superrepo"
        self.subrepo.mkdir()
        self.superrepo.mkdir()
        git("init", "-q", cwd=self.subrepo)
        git("config", "user.name", "Test", cwd=self.subrepo)
        git("config", "user.email", "test@example.com", cwd=self.subrepo)
        (self.subrepo / "file").write_text("A\n", encoding="utf-8")
        self.a = self.commit_sub("first subject")
        git("init", "-q", cwd=self.superrepo)
        git("config", "user.name", "Test", cwd=self.superrepo)
        git("config", "user.email", "test@example.com", cwd=self.superrepo)
        git("-c", "protocol.file.allow=always", "submodule", "add", str(self.subrepo), "deps/sample", cwd=self.superrepo)
        git("commit", "-qm", "base", cwd=self.superrepo)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)

    def commit_sub(self, subject: str) -> str:
        with (self.subrepo / "file").open("a", encoding="utf-8") as handle:
            handle.write(subject + "\n")
        git("add", "file", cwd=self.subrepo)
        git("commit", "-qm", subject, cwd=self.subrepo)
        return git("rev-parse", "HEAD", cwd=self.subrepo)

    def pointer(self, sha: str) -> None:
        git("-C", str(self.superrepo / "deps/sample"), "fetch", "-q", "origin", sha, cwd=self.superrepo)
        git("-C", str(self.superrepo / "deps/sample"), "checkout", "-q", sha, cwd=self.superrepo)
        git("add", "deps/sample", cwd=self.superrepo)
        git("commit", "-qm", f"point at {sha[:7]}", cwd=self.superrepo)

    def run_guard(self, *, marker: bool = False, remove_submodule: bool = False) -> subprocess.CompletedProcess[str]:
        if marker:
            git("commit", "--allow-empty", "-qm", "submodule-forward-only: allow", cwd=self.superrepo)
        if remove_submodule:
            shutil.rmtree(self.superrepo / "deps/sample")
        return subprocess.run(
            ["python3", str(SCRIPT), "--base", self.base, "--head", "HEAD"],
            cwd=self.superrepo, text=True, capture_output=True,
            env={**os.environ, "GITHUB_TOKEN": "", "GH_TOKEN": ""},
        )

    def test_unchanged_pointer_passes(self) -> None:
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_forward_bump_passes(self) -> None:
        b = self.commit_sub("forward subject")
        self.pointer(b)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_backward_move_fails_with_actionable_detail(self) -> None:
        b = self.commit_sub("dropped subject")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        self.pointer(self.a)
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backward", result.stderr)
        self.assertIn("dropped subject", result.stderr)
        self.assertIn("merge main into the branch", result.stderr)

    def test_diverged_move_fails(self) -> None:
        b = self.commit_sub("base-only subject")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        c = self.commit_sub("new-only subject")
        self.pointer(c)
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("diverged", result.stderr)

    def test_undecidable_ancestry_fails(self) -> None:
        b = self.commit_sub("unavailable subject")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        self.pointer(self.a)
        result = self.run_guard(remove_submodule=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not determine ancestry", result.stderr)

    def test_declared_rollback_passes(self) -> None:
        b = self.commit_sub("intentional rollback")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        self.pointer(self.a)
        result = self.run_guard(marker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("declared", result.stdout)


if __name__ == "__main__":
    unittest.main()
