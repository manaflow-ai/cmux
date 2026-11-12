#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/submodule_forward_only.py."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
import contextlib
import io
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/submodule_forward_only.py"
import sys
sys.path.insert(0, str(ROOT / "scripts/ci"))
import submodule_forward_only  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)


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
            env={
                **os.environ,
                "GITHUB_TOKEN": "",
                "GH_TOKEN": "",
                # The fixture uses a local submodule URL. Production URLs are
                # HTTPS and never need this test-only transport allowance.
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "protocol.file.allow",
                "GIT_CONFIG_VALUE_0": "always",
            },
        )

    def test_unchanged_pointer_passes(self) -> None:
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unchanged_pointer_does_not_need_a_submodule_checkout(self) -> None:
        # An unrelated guard run must stay cheap even when the submodule URL
        # is unavailable. The unchanged gitlink short-circuits before init.
        shutil.rmtree(self.superrepo / "deps/sample")
        modules = (self.superrepo / ".gitmodules").read_text(encoding="utf-8")
        (self.superrepo / ".gitmodules").write_text(
            modules.replace(str(self.subrepo), "/unavailable/subrepo"), encoding="utf-8"
        )
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

    def test_shallow_clone_defers_forward_move_to_github(self) -> None:
        # CI checks submodules out shallow, so a forward bump's shared history
        # is missing locally and must not read as divergence.
        b = self.commit_sub("base subject")
        c = self.commit_sub("new subject")
        git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=self.subrepo)
        shallow = self.root / "shallow"
        git("clone", "-q", "--depth", "1", f"file://{self.subrepo}", str(shallow), cwd=self.root)
        git("fetch", "-q", "--depth", "1", "origin", b, cwd=shallow)
        self.assertEqual(git("rev-parse", "--is-shallow-repository", cwd=shallow), "true")
        self.assertIsNone(submodule_forward_only.local_relation(str(shallow), b, c))

    def test_removed_submodule_is_reinitialized_and_backward_move_fails(self) -> None:
        b = self.commit_sub("unavailable subject")
        self.pointer(b)
        self.base = git("rev-parse", "HEAD", cwd=self.superrepo)
        git("-C", str(self.subrepo), "checkout", "-q", self.a, cwd=self.superrepo)
        self.pointer(self.a)
        result = self.run_guard(remove_submodule=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backward", result.stderr)

    def test_undecidable_ancestry_fails_closed(self) -> None:
        b = self.commit_sub("unavailable ancestry")
        self.pointer(b)
        stderr = io.StringIO()
        previous = os.getcwd()
        os.chdir(self.superrepo)
        try:
            with contextlib.redirect_stderr(stderr), \
                 patch.object(sys, "argv", [str(SCRIPT), "--base", self.base, "--head", "HEAD"]), \
                 patch.object(submodule_forward_only, "initialize_changed_submodule", return_value=True), \
                 patch.object(submodule_forward_only, "local_relation", return_value=None), \
                 patch.object(submodule_forward_only, "github_relation", return_value=None), \
                 patch.object(submodule_forward_only, "deepened_relation", return_value=None):
                status = submodule_forward_only.main()
        finally:
            os.chdir(previous)
        self.assertNotEqual(status, 0)
        self.assertIn("could not determine ancestry", stderr.getvalue())

    def test_changed_pointer_initializes_missing_submodule(self) -> None:
        # The guard checkout starts without submodules. A changed pin must
        # still be checked locally when its shallow repository can be restored.
        b = self.commit_sub("changed pin subject")
        self.pointer(b)
        result = self.run_guard(remove_submodule=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_pointer_init_failure_fails_closed(self) -> None:
        b = self.commit_sub("unavailable changed pin")
        self.pointer(b)
        modules = (self.superrepo / ".gitmodules").read_text(encoding="utf-8")
        (self.superrepo / ".gitmodules").write_text(
            modules.replace(str(self.subrepo), "/unavailable/subrepo"), encoding="utf-8"
        )
        result = self.run_guard(remove_submodule=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not initialize changed submodule", result.stderr)

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

    def shallow_clone(self, name: str, *extra: str) -> Path:
        clone = self.root / name
        git("-c", "protocol.file.allow=always", "clone", "-q", "--depth", "1",
            f"file://{self.subrepo}", str(clone), cwd=self.root)
        for sha in extra:
            git("fetch", "-q", "--depth", "1", "origin", sha, cwd=clone)
        self.assertEqual(git("rev-parse", "--is-shallow-repository", cwd=clone), "true")
        return clone

    def test_shallow_gap_is_decided_from_fetched_history_when_github_cannot(self) -> None:
        # The GitHub compare fails whenever the Actions token is out of API
        # quota. A forward bump whose old pin is deeper than the shallow
        # clone must then be decided from fetched history, not fail as
        # undecidable; a backward one must still read as backward.
        self.commit_sub("middle subject")
        tip = self.commit_sub("tip subject")
        forward = self.shallow_clone("shallow-forward", self.a)
        self.assertIsNone(submodule_forward_only.local_relation(str(forward), self.a, tip))
        self.assertEqual(submodule_forward_only.deepened_relation(str(forward), self.a, tip), "forward")
        backward = self.shallow_clone("shallow-backward", self.a)
        self.assertEqual(submodule_forward_only.deepened_relation(str(backward), tip, self.a), "backward")

    def test_deepening_leaves_a_complete_clone_to_the_local_check(self) -> None:
        # Only a shallow clone lacks history; a complete one already had its answer.
        self.assertIsNone(submodule_forward_only.deepened_relation(str(self.subrepo), self.a, self.a))

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


class InitTimeoutTests(unittest.TestCase):
    """A busy runner makes the shallow submodule clone slower, never red on its own (cmux#41742's class).

    Each case fakes a slow `git submodule update`: the guard's run() answers it with the timeout's exit 124.
    """

    # The same fixture, without running SubmoduleForwardOnlyTests' cases a second time.
    setUp = SubmoduleForwardOnlyTests.setUp
    commit_sub = SubmoduleForwardOnlyTests.commit_sub
    pointer = SubmoduleForwardOnlyTests.pointer

    def guard_in_process(self, timeouts: int) -> tuple[int, str, list[float]]:
        """main() in the superrepo, with the first TIMEOUTS submodule updates timing out. Returns (exit code,
        stderr, the limit each submodule update got)."""
        real = submodule_forward_only.run
        limits: list[float] = []

        def slow(*args: str, cwd: str | None = None, timeout: float = submodule_forward_only.FETCH_TIMEOUT_SECONDS):
            if args[:3] == ("git", "submodule", "update"):
                limits.append(timeout)
                if len(limits) <= timeouts:
                    return subprocess.CompletedProcess(args, 124, stdout="", stderr="command timed out")
            return real(*args, cwd=cwd, timeout=timeout)

        env = {"GITHUB_TOKEN": "", "GH_TOKEN": "", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow",
               "GIT_CONFIG_VALUE_0": "always"}
        here = os.getcwd()
        err = io.StringIO()
        try:
            os.chdir(self.superrepo)
            with patch.object(submodule_forward_only, "run", slow), patch.dict(os.environ, env), \
                    patch.object(sys, "argv", ["submodule_forward_only.py", "--base", self.base, "--head", "HEAD"]), \
                    contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = submodule_forward_only.main()
        finally:
            os.chdir(here)
        return code, err.getvalue(), limits

    def test_an_untouched_submodule_never_waits_on_a_clone(self) -> None:
        shutil.rmtree(self.superrepo / "deps/sample")
        code, err, limits = self.guard_in_process(timeouts=99)
        self.assertEqual((code, limits), (0, []), err)

    def test_a_timed_out_update_is_retried_once_with_a_longer_limit(self) -> None:
        self.pointer(self.commit_sub("forward subject"))
        shutil.rmtree(self.superrepo / "deps/sample")
        code, err, limits = self.guard_in_process(timeouts=1)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(limits), 2, limits)
        self.assertGreater(limits[1], limits[0])

    def test_a_changed_submodule_that_times_out_twice_fails_and_says_it_timed_out(self) -> None:
        """The change moved this gitlink, so the guard cannot pass it unjudged: it fails, naming the timeout."""
        self.pointer(self.commit_sub("forward subject"))
        shutil.rmtree(self.superrepo / "deps/sample")
        code, err, limits = self.guard_in_process(timeouts=2)
        self.assertEqual(code, 1, err)
        self.assertEqual(len(limits), 2, limits)
        self.assertIn(f"timed out after {limits[0]:g} s and again after {limits[1]:g} s", err)


if __name__ == "__main__":
    unittest.main()
