#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/submodule_forward_only.py."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/submodule_forward_only.py"
import sys
sys.path.insert(0, str(ROOT / "scripts/ci"))
import submodule_forward_only  # noqa: E402


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
        modules = (self.superrepo / ".gitmodules").read_text(encoding="utf-8")
        (self.superrepo / ".gitmodules").write_text(modules.replace('submodule "deps/sample"', 'submodule "sample-alias"'), encoding="utf-8")
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
            git("commit", "--allow-empty", "-qm", "submodule-forward-only: allow deps/sample", cwd=self.superrepo)
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

    def test_uses_merge_base_instead_of_base_tip(self) -> None:
        b = self.commit_sub("main-only bump")
        self.pointer(b)
        base_tip = git("rev-parse", "HEAD", cwd=self.superrepo)
        branch_point = self.base
        git("checkout", "-q", "-b", "feature", branch_point, cwd=self.superrepo)
        result = subprocess.run(
            ["python3", str(SCRIPT), "--base", base_tip, "--head", "HEAD"],
            cwd=self.superrepo, text=True, capture_output=True,
            env={**os.environ, "GITHUB_TOKEN": "", "GH_TOKEN": ""},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unchanged", result.stdout)

    def test_submodule_added_on_branch_passes(self) -> None:
        git("-c", "protocol.file.allow=always", "submodule", "add", str(self.subrepo), "deps/new", cwd=self.superrepo)
        git("commit", "-qm", "add submodule", cwd=self.superrepo)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("submodule added", result.stdout)

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

    def test_shallow_clone_gap_is_not_divergence(self) -> None:
        # CI checks submodules out shallowly. When a forward bump spans more
        # history than the clone holds, both commits exist locally but no
        # ancestry connects them; the local check must defer to GitHub.
        self.commit_sub("middle subject")
        tip = self.commit_sub("tip subject")
        shallow = self.root / "shallow"
        git("-c", "protocol.file.allow=always", "clone", "-q", "--depth", "1",
            f"file://{self.subrepo}", str(shallow), cwd=self.root)
        git("fetch", "-q", "--depth", "1", "origin", self.a, cwd=shallow)
        self.assertEqual(git("rev-parse", "--is-shallow-repository", cwd=shallow), "true")
        self.assertIsNone(submodule_forward_only.local_relation(str(shallow), self.a, tip))

    def test_declared_rollback_passes(self) -> None:
        b = self.commit_sub("intentional rollback")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        self.pointer(self.a)
        result = self.run_guard(marker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("declared", result.stdout)

    def test_rollback_marker_for_another_path_does_not_excuse_this_path(self) -> None:
        b = self.commit_sub("intentional rollback")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        self.pointer(self.a)
        git("commit", "--allow-empty", "-qm", "submodule-forward-only: allow vendor/bonsplit", cwd=self.superrepo)
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)


class GitHubRelationTests(unittest.TestCase):
    class Response:
        def __init__(self, payload: dict) -> None:
            self.payload = payload

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self):
            import json
            return json.dumps(self.payload).encode()

    def relation(self, payload: dict) -> str | None:
        with patch.object(submodule_forward_only, "urlopen", return_value=self.Response(payload)) as opener:
            relation = submodule_forward_only.github_relation(
                "https://github.com/example/sample.git", "newsha", "basesha"
            )
            request = opener.call_args.args[0]
            self.assertIn("/compare/newsha...basesha", request.full_url)
            return relation

    def test_identical_compare(self) -> None:
        self.assertEqual(self.relation({"status": "identical", "ahead_by": 0, "behind_by": 0}), "unchanged")

    def test_forward_compare_direction(self) -> None:
        self.assertEqual(self.relation({"status": "behind", "ahead_by": 0, "behind_by": 4}), "forward")

    def test_backward_compare_direction(self) -> None:
        self.assertEqual(self.relation({"status": "ahead", "ahead_by": 4, "behind_by": 0}), "backward")

    def test_diverged_compare_is_not_forward(self) -> None:
        self.assertEqual(self.relation({"status": "diverged", "ahead_by": 1, "behind_by": 1593}), "diverged")


if __name__ == "__main__":
    unittest.main()
