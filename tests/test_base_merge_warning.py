#!/usr/bin/env python3
"""A base merge pushed while the PR's CI runs gets a warning, and nothing else does.

A push cancels every job still running on the old head; on 2026-10-21 base-merge
pushes cut 167 Mac runner-minutes in 55 minutes. scripts/ci/base_merge_warning.py
warns from the pre-push hook and from a Claude Code hook on update-branch calls.
It never refuses a push or a command, and stays quiet when GitHub can't be read.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
WARNING = SOURCE / "scripts/ci/base_merge_warning.py"
HOOK = SOURCE / "scripts/ci/base-merge-warning-hook.sh"
FAKE_GH = """#!/bin/sh
echo "$*" >> "$GH_LOG"
case "$*" in
  *check-runs*) cat "$GH_RUNNING" ;;
  *pulls/*) echo "$GH_HEAD" ;;
esac
exit "${GH_EXIT:-0}"
"""


class BaseMergeWarningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-base-merge-warning-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.running = self.root / "running"
        self.running.write_text("3\n")
        self.gh_log = self.root / "gh.log"
        self.gh_log.write_text("")
        global_config = self.root / "gitconfig"
        global_config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        git_fixture_env.without_auto_maintenance(self.env)
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", HOME=str(self.root),
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(global_config),
                        GH_LOG=str(self.gh_log), GH_RUNNING=str(self.running), GH_HEAD="f" * 40)

        self.git("init", "-q", "-b", "feat-cmux-next", str(self.repo), cwd=self.root)
        self.git("remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git")
        self.commit("base.txt", "base\n")
        self.git("switch", "-q", "-c", "topic")
        self.commit("topic.txt", "topic\n")
        self.old_head = self.rev("HEAD")
        self.git("update-ref", "refs/remotes/origin/topic", self.old_head)
        self.git("switch", "-q", "feat-cmux-next")
        self.commit("base.txt", "base moved\n")
        # The base's own history has merges too; a base merge brings them in, and they are not the branch's.
        self.git("switch", "-q", "-c", "side")
        self.commit("side.txt", "side\n")
        self.git("switch", "-q", "feat-cmux-next")
        self.git("merge", "-q", "--no-ff", "--no-edit", "side")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", self.rev("HEAD"))
        self.git("switch", "-q", "topic")

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def rev(self, ref):
        return self.git("rev-parse", ref)

    def commit(self, name, text):
        (self.repo / name).write_text(text)
        self.git("add", name)
        self.git("commit", "-q", "-m", f"change {name}")

    def merge_base(self):
        self.git("merge", "-q", "--no-edit", "origin/feat-cmux-next")
        return self.rev("HEAD")

    def pre_push(self, local, branch="topic", remote=None):
        remote = remote or self.old_head
        line = f"refs/heads/{branch} {local} refs/heads/{branch} {remote}\n"
        return subprocess.run(["python3", "-I", str(WARNING), "--pre-push", "--repo", str(self.repo)],
                              input=line, env=self.env, capture_output=True, text=True, timeout=60)

    def claude_hook(self, command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(self.repo)})
        return subprocess.run(["bash", str(HOOK)], input=payload, env=self.env, capture_output=True,
                              text=True, timeout=60)

    def test_a_clean_base_merge_while_checks_run_warns_and_still_pushes(self):
        done = self.pre_push(self.merge_base())
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("merges the base into topic while 3 check(s)", done.stderr)
        self.assertIn(self.old_head[:12], done.stderr)
        self.assertIn(f"commits/{self.old_head}/check-runs", self.gh_log.read_text())

    def test_no_warning_once_the_old_heads_checks_finished(self):
        self.running.write_text("0\n")
        done = self.pre_push(self.merge_base())
        self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_an_ordinary_commit_never_asks_github(self):
        self.commit("topic.txt", "more\n")
        done = self.pre_push(self.rev("HEAD"))
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertEqual(self.gh_log.read_text(), "")

    def test_a_merge_that_changes_more_than_the_base_is_not_a_clean_base_merge(self):
        self.git("merge", "-q", "--no-commit", "origin/feat-cmux-next")
        (self.repo / "fix.txt").write_text("resolved by hand\n")
        self.git("add", "fix.txt")
        self.git("commit", "-q", "--no-edit")
        done = self.pre_push(self.rev("HEAD"))
        self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_a_push_to_the_base_branch_or_a_new_branch_is_left_alone(self):
        merge = self.merge_base()
        for done in (self.pre_push(merge, branch="feat-cmux-next"), self.pre_push(merge, remote="0" * 40)):
            self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_github_unreadable_means_no_warning_and_no_failure(self):
        self.env["GH_EXIT"] = "1"
        done = self.pre_push(self.merge_base())
        self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_update_branch_while_checks_run_adds_context_without_blocking(self):
        done = self.claude_hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/22801/update-branch")
        self.assertEqual(done.returncode, 0, done.stderr)
        output = json.loads(done.stdout)["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertNotIn("permissionDecision", output)
        self.assertIn("update-branch on #22801 cancels the 3 check(s)", output["additionalContext"])
        self.assertIn(f"commits/{'f' * 40}/check-runs", self.gh_log.read_text())

    def test_other_update_branch_forms_warn_too(self):
        for command in ("gh pr update-branch 22801", "gh pr update-branch -R manaflow-ai/cmux 22801",
                        "gh api -X PUT repos/{owner}/{repo}/pulls/22801/update-branch"):
            with self.subTest(command=command):
                self.gh_log.write_text("")
                done = self.claude_hook(command)
                self.assertIn("update-branch on #22801", json.loads(done.stdout)["hookSpecificOutput"]["additionalContext"])
                self.assertIn("repos/manaflow-ai/cmux/pulls/22801", self.gh_log.read_text())

    def test_update_branch_with_nothing_running_says_nothing(self):
        self.running.write_text("0\n")
        done = self.claude_hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/22801/update-branch")
        self.assertEqual((done.returncode, done.stdout), (0, ""))

    def test_other_commands_exit_before_asking_github(self):
        done = self.claude_hook("gh pr view 22801")
        self.assertEqual((done.returncode, done.stdout), (0, ""))
        self.assertEqual(self.gh_log.read_text(), "")


if __name__ == "__main__":
    unittest.main()
