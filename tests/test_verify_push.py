#!/usr/bin/env python3
"""Exercise the installed pre-push hook with real Git pushes and isolated repos."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
FAKE_RECIPE = '''import json, os, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
state = (root / "state.txt").read_text()
sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
with open(os.environ["CMUX_CHECK_RECORD"], "a") as log:
    log.write(json.dumps({"sha": sha, "state": state, "root": str(root)}) + "\\n")
print("fixture static check:", state)
sys.exit(0 if state == "good" else 1)
'''


class PushVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-push-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / "repo with spaces"
        self.repo.mkdir()
        self.remote = self.directory / "remote.git"
        self.record = self.directory / "checks.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        CMUX_CHECK_RECORD=str(self.record), PYTHONDONTWRITEBYTECODE="1")
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("init", "--quiet", "--bare", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        for name in ("scripts/verify-push.py", "scripts/git-hooks/pre-push",
                     "scripts/git-hooks/pre-commit", "scripts/install-git-hooks.sh"):
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, target)
            target.chmod(0o755)
        (self.repo / "scripts/verify-local.py").write_text(FAKE_RECIPE)
        (self.repo / ".gitignore").write_text(".local/\n")
        self.good = self.commit("good")
        self.install()

    def git(self, *args, check=True, input=None):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              text=True, capture_output=True, check=check, input=input)

    def install(self, check=True):
        return subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo,
                              env=self.env, text=True, capture_output=True, check=check)

    def commit(self, state):
        (self.repo / "state.txt").write_text(state)
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", state)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def records(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def assert_cleaned(self):
        self.assertFalse((self.repo / ".local/cmux-pre-push").exists())

    def test_installed_hook_passes_and_repeated_install_preserves_precommit(self):
        before = (self.repo / "scripts/git-hooks/pre-commit").read_bytes()
        self.install()
        result = self.git("push", "origin", "HEAD:refs/heads/main")
        self.assertIn("passed static checks", result.stdout)
        self.assertEqual([r["sha"] for r in self.records()], [self.good])
        self.assertEqual((self.repo / "scripts/git-hooks/pre-commit").read_bytes(), before)
        self.assert_cleaned()

    def test_bad_committed_source_is_rejected_even_with_good_dirty_file(self):
        bad = self.commit("bad")
        (self.repo / "state.txt").write_text("good")
        before = self.git("status", "--porcelain").stdout
        result = self.git("push", "origin", "HEAD:refs/heads/main", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("static checks failed", result.stderr)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").stdout, "")
        self.assertEqual(self.records()[0]["sha"], bad)
        self.assertEqual(self.records()[0]["state"], "bad")
        self.assertEqual(self.git("status", "--porcelain").stdout, before)
        self.assert_cleaned()

    def test_dirty_and_untracked_files_do_not_contaminate_committed_check(self):
        (self.repo / "state.txt").write_text("bad")
        self.git("add", "state.txt")
        (self.repo / "private.txt").write_text("untracked")
        before = self.git("status", "--porcelain").stdout
        self.git("push", "origin", "HEAD:refs/heads/main")
        self.assertEqual(self.records()[0]["state"], "good")
        self.assertEqual(self.git("status", "--porcelain").stdout, before)
        self.assert_cleaned()

    def test_pushes_other_branch_not_current_head(self):
        self.git("branch", "good-branch", self.good)
        self.commit("bad")
        self.git("push", "origin", "good-branch:refs/heads/main")
        self.assertEqual(self.records()[0]["sha"], self.good)
        self.assert_cleaned()

    def test_multiple_refs_deduplicate_same_commit_and_peel_tags(self):
        self.git("tag", "-a", "v1", "-m", "release")
        self.git("push", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/copy", "refs/tags/v1")
        self.assertEqual(len(self.records()), 1)
        self.assert_cleaned()

    def test_any_failing_tip_blocks_all_refs(self):
        self.git("branch", "good-branch")
        self.commit("bad")
        result = self.git("push", "origin", "good-branch:refs/heads/good", "HEAD:refs/heads/bad", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("ls-remote", "origin").stdout, "")
        self.assertIn("bad", {r["state"] for r in self.records()})
        self.assert_cleaned()

    def test_two_distinct_good_tips_are_both_checked(self):
        self.git("branch", "first")
        (self.repo / "extra.txt").write_text("another commit")
        second = self.commit("good")
        self.git("push", "origin", "first:refs/heads/first", "HEAD:refs/heads/second")
        self.assertEqual({r["sha"] for r in self.records()}, {self.good, second})
        self.assert_cleaned()

    def test_malformed_hook_input_fails_before_running_checks(self):
        result = subprocess.run(["bash", "scripts/git-hooks/pre-push"], cwd=self.repo,
                                env=self.env, text=True, input="broken input\n", capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed pre-push input", result.stderr)
        self.assertEqual(self.records(), [])
        self.assert_cleaned()

    def test_hook_does_not_inherit_an_alternate_index_or_worktree(self):
        env = dict(self.env, GIT_INDEX_FILE=str(self.directory / "wrong-index"),
                   GIT_WORK_TREE=str(self.directory / "wrong-worktree"))
        result = subprocess.run(["bash", "scripts/git-hooks/pre-push"], cwd=self.repo,
                                env=env, text=True, capture_output=True,
                                input=f"refs/heads/main {self.good} refs/heads/main {'0' * 40}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records()[0]["sha"], self.good)
        self.assertFalse((self.directory / "wrong-index").exists())
        self.assert_cleaned()

    def test_deletion_only_push_runs_no_checks(self):
        self.git("push", "origin", "HEAD:refs/heads/removable")
        self.record.unlink()
        self.git("push", "origin", ":refs/heads/removable")
        self.assertEqual(self.records(), [])
        self.assert_cleaned()

    def test_missing_recipe_rejects_push(self):
        (self.repo / "scripts/verify-local.py").unlink()
        self.commit("good")
        result = self.git("push", "origin", "HEAD:refs/heads/main", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no supported scripts/verify-local.py", result.stderr)
        self.assert_cleaned()

    def test_non_commit_tag_is_explicitly_unsupported(self):
        blob = self.git("hash-object", "-w", "--stdin", input="blob").stdout.strip()
        self.git("update-ref", "refs/tags/blob", blob)
        result = self.git("push", "origin", "refs/tags/blob", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not point to a supported commit", result.stderr)
        self.assert_cleaned()

    def test_installer_preserves_custom_hooks_path(self):
        self.git("config", "core.hooksPath", "my-hooks")
        result = self.install(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("config", "--get", "core.hooksPath").stdout.strip(), "my-hooks")

    def test_installer_preserves_executable_default_hook(self):
        self.git("config", "--unset", "core.hooksPath")
        existing = self.repo / ".git/hooks/pre-push"
        existing.write_text("#!/bin/sh\nexit 0\n")
        existing.chmod(0o755)
        result = self.install(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(self.git("config", "--get", "core.hooksPath", check=False).returncode, 0)
        self.assertTrue(existing.exists())


if __name__ == "__main__":
    unittest.main()
