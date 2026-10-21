#!/usr/bin/env python3
"""The PreToolUse merge guards never run from the session's checkout.

palette-audit, 2026-10-21: `.claude/settings.json` ran `"$CLAUDE_PROJECT_DIR"/scripts/ci/merge-compile-guard-hook.sh`,
so a session in a pull request's worktree ran that branch's copy of the guard: a branch made before a guard fix
kept the old guard, and a pull request could edit the guard that judges its own merge. The hook now loads
scripts/ci/guards-from-base.sh from origin/feat-cmux-next, which runs the update-branch warning from that commit.

A merge is judged by the landing gate installed from cmuxterm-hq main (tools/agent-guards/require-cmux-guards,
which guards-sync keeps current every 10 minutes), never by a copy in this repository: a copy here reached a
worktree only through a base merge or a fetch, and after hq#2830 #23472 still ran a guard without its gh-throttle
fix (deputy-2, 2026-10-21). guards-from-base.sh defers to the installed gate when this account registers it, runs it
when only the file is there, and refuses the merge when it is not installed.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / ".claude/settings.json"
GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
# A stand-in for the update-branch warning: it says which copy ran.
WARNING = """import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "base merge warning %s"}}))
"""
# A stand-in for the installed landing gate (cmuxterm-hq tools/agent-guards/require-cmux-guards.sh).
GATE = """#!/bin/bash
input=$(</dev/stdin)
case $input in *"pr merge"*) printf '%s\\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse",
  "permissionDecision": "deny", "permissionDecisionReason": "installed landing gate"}}' ;; esac
exit 0
"""
MERGE = "gh pr merge 5 -R manaflow-ai/cmux --squash"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env={**os.environ, **GIT_ENV}).stdout.strip()


def pre_tool_use_commands() -> list[str]:
    hooks = json.loads(SETTINGS.read_text())["hooks"]["PreToolUse"]
    return [hook["command"] for entry in hooks if entry["matcher"] == "Bash" for hook in entry["hooks"]]


class GuardsRunFromTheBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.isolate_git()
        git(self.tmp, "init", "-q", "--bare", "-b", "feat-cmux-next", "remote.git")
        self.seed = self.tmp / "seed"
        git(self.tmp, "clone", "-q", "remote.git", "seed")
        git(self.seed, "checkout", "-q", "-b", "feat-cmux-next")
        for path in (".claude/settings.json", "scripts/ci/guards-from-base.sh", "scripts/ci/base-merge-warning-hook.sh"):
            (self.seed / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.seed / path)
        self.guards("base v1")
        git(self.seed, "add", "-A")
        git(self.seed, "commit", "-qm", "base")
        git(self.seed, "push", "-q", "origin", "feat-cmux-next")
        # The pull request's worktree: branched from the base, with its own edit of the guards.
        self.lane = self.tmp / "lane"
        git(self.tmp, "clone", "-q", "-b", "feat-cmux-next", "remote.git", "lane")
        git(self.lane, "checkout", "-q", "-b", "pr")
        (self.lane / "scripts/ci/guards-from-base.sh").write_text("exit 0\n")  # lets every merge through
        (self.lane / "scripts/ci/base_merge_warning.py").write_text("")
        git(self.lane, "commit", "-qam", "the pull request edits the guards that judge it")

    def isolate_git(self) -> None:
        """Every git this test starts, its own and the hook's, reads config only from inside self.tmp, and that
        config turns auto maintenance and gc off. Otherwise a commit, push or fetch leaves a detached
        `git maintenance run --auto` taking and dropping .git/objects/maintenance.lock while the cleanup's rmtree
        walks the directory, and the rmtree fails with FileNotFoundError. HOME is the test's too, so the installed
        landing gate is the one the test installs."""
        self.home = self.tmp / "home"
        self.home.mkdir()
        config = self.home / ".gitconfig"
        config.write_text("[maintenance]\n\tauto = false\n\tautoDetach = false\n"
                          "[gc]\n\tauto = 0\n\tautoDetach = false\n")
        env = {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / ".config"), "GIT_CONFIG_GLOBAL": str(config),
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def guards(self, label: str) -> None:
        (self.seed / "scripts/ci/base_merge_warning.py").write_text(WARNING % label)

    def install_gate(self, file: bool = True, registered_in: Path | None = None) -> Path:
        """The gate as tools/agent-guards/install.py installs it: the hook in ~/.claude/hooks/, registered as a
        PreToolUse(Bash) command in a config directory's settings.json."""
        gate = self.home / ".claude/hooks/require-cmux-guards.sh"
        if file:
            gate.parent.mkdir(parents=True, exist_ok=True)
            gate.write_text(GATE)
        if registered_in is not None:
            registered_in.mkdir(parents=True, exist_ok=True)
            (registered_in / "settings.json").write_text(json.dumps({"hooks": {"PreToolUse": [
                {"matcher": "Bash", "hooks": [{"type": "command", "command": f"bash {gate}", "timeout": 30}]}]}}))
        return gate

    def hook(self, command: str, env: dict | None = None) -> tuple[int, dict | None, str]:
        """What the repository's own hooks answer (Claude Code runs a registered installed gate beside them)."""
        payload = json.dumps({"tool_name": "Bash", "cwd": str(self.lane), "tool_input": {"command": command}})
        outputs, code, err = [], 0, ""
        for hook in pre_tool_use_commands():
            done = subprocess.run(["bash", "-c", hook], input=payload, capture_output=True, text=True, timeout=60,
                                  cwd=self.lane, env={**os.environ, "CLAUDE_PROJECT_DIR": str(self.lane), **(env or {})})
            code, err = code or done.returncode, err + done.stderr
            if done.stdout.strip():
                outputs.append(json.loads(done.stdout))
        self.assertLessEqual(len(outputs), 1, outputs)
        return code, (outputs[0] if outputs else None), err

    def assert_refused(self, out: dict | None, *words: str) -> None:
        self.assertIsNotNone(out, "the merge was let through")
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        for word in words:
            self.assertIn(word, out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_a_merge_defers_to_the_installed_landing_gate_this_account_registers(self):
        """Claude Code runs the registered gate itself; judging the merge here too would read GitHub twice."""
        self.install_gate(registered_in=self.home / ".claude")
        code, out, err = self.hook(MERGE)
        self.assertEqual((code, out), (0, None), err)

    def test_a_merge_runs_the_installed_landing_gate_when_this_account_did_not_register_it(self):
        self.install_gate()
        code, out, err = self.hook(MERGE)
        self.assertEqual(code, 0, err)
        self.assert_refused(out, "installed landing gate")

    def test_the_account_in_claude_config_dir_is_the_one_that_must_register_it(self):
        account = self.tmp / "account"
        self.install_gate(registered_in=account)
        self.assert_refused(self.hook(MERGE)[1], "installed landing gate")  # ~/.claude has no registration
        self.assertIsNone(self.hook(MERGE, env={"CLAUDE_CONFIG_DIR": str(account)})[1])
        self.assert_refused(self.hook(MERGE, env={"CLAUDE_CONFIG_DIR": str(self.tmp / "other")})[1],
                            "installed landing gate")

    def test_a_merge_with_no_installed_landing_gate_is_refused(self):
        """The gate fails closed (it refuses a merge it can't judge), so a merge with no gate to judge it is refused
        too, saying how to install it."""
        for registered_in in (None, self.home / ".claude"):  # a registration whose file is gone runs nothing
            with self.subTest(registered=registered_in is not None):
                self.install_gate(file=False, registered_in=registered_in)
                code, out, err = self.hook(MERGE)
                self.assertEqual(code, 0, err)
                self.assert_refused(out, "require-cmux-guards", "guards-sync", "install.py")

    def test_the_pull_requests_copy_of_the_launcher_does_not_judge_its_merge(self):
        code, out, err = self.hook(MERGE)
        self.assertEqual(code, 0, err)
        self.assert_refused(out, "not installed")

    def test_no_merge_guard_runs_from_this_repository(self):
        """The landing gate lives in cmuxterm-hq; a copy here would judge a merge by a stale rule again."""
        for path in ("scripts/ci/merge_compile_guard.py", "scripts/ci/merge-compile-guard-hook.sh"):
            self.assertFalse((ROOT / path).exists(), path)
        self.assertNotIn("merge_compile_guard", (ROOT / "scripts/ci/guards-from-base.sh").read_text())

    def test_a_warning_fix_on_the_base_reaches_a_branch_made_before_it(self):
        self.guards("base v2")
        git(self.seed, "commit", "-qam", "a warning fix lands")
        git(self.seed, "push", "-q", "origin", "feat-cmux-next")
        git(self.lane, "fetch", "-q", "origin")
        code, out, err = self.hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["additionalContext"], "base merge warning base v2")

    def test_the_update_branch_warning_comes_from_the_base(self):
        code, out, err = self.hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["additionalContext"], "base merge warning base v1")

    def test_a_stale_origin_is_fetched_before_a_merge(self):
        """A clone last fetched before the launcher landed has no origin/feat-cmux-next:scripts/ci/guards-from-base.sh;
        the hook fetches first, so the merge still goes to the landing gate."""
        self.install_gate()
        git(self.lane, "update-ref", "refs/remotes/origin/feat-cmux-next", self.old_base())
        code, out, err = self.hook(MERGE)
        self.assertEqual(code, 0, err)
        self.assert_refused(out, "installed landing gate")

    def test_a_merge_whose_guards_cannot_be_read_is_refused(self):
        """A merge the hook can't judge is denied, never let through with only a stderr line."""
        self.install_gate()
        old = self.old_base()
        git(self.lane, "remote", "set-url", "origin", str(self.tmp / "gone.git"))
        git(self.lane, "update-ref", "refs/remotes/origin/feat-cmux-next", old)
        code, out, err = self.hook(MERGE)
        self.assertEqual(code, 0, err)
        self.assert_refused(out, "merge guards did not run")
        # The update-branch warning only warns: unreadable, it does not block.
        code, out, err = self.hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertIsNone(out)
        self.assertNotEqual(code, 2)

    def old_base(self) -> str:
        """A commit on the base from before the launcher existed."""
        old = self.tmp / "old"
        git(self.tmp, "clone", "-q", "-b", "feat-cmux-next", "remote.git", "old")
        git(old, "checkout", "-q", "--orphan", "before")
        git(old, "rm", "-rq", "--cached", ".")
        (old / "README.md").write_text("before the guards ran from the base\n")
        git(old, "add", "README.md")
        git(old, "commit", "-qm", "before")
        git(old, "push", "-q", "origin", "before")
        git(self.lane, "fetch", "-q", "origin", "before")
        return git(old, "rev-parse", "HEAD")

    def test_other_commands_pass_without_a_guard(self):
        code, out, err = self.hook("ls -la")
        self.assertEqual((code, out), (0, None), err)

    def test_no_pre_tool_use_hook_runs_a_script_from_the_checkout(self):
        for command in pre_tool_use_commands():
            with self.subTest(command=command):
                self.assertNotIn('"$CLAUDE_PROJECT_DIR"/scripts', command)
                self.assertIn("origin/feat-cmux-next:scripts/ci/guards-from-base.sh", command)

    def test_git_starts_no_background_maintenance_in_the_fixture_repos(self):
        """A commit or fetch runs `git maintenance run --auto`, which detaches and keeps taking
        `.git/objects/maintenance.lock` after the test returns; the cleanup's rmtree then lists the lock, the
        maintenance child removes it, and the unlink fails with FileNotFoundError (script-tests, #23563). The
        fixture repos turn auto maintenance and gc off, so git never starts it: here or in the hook's fetch."""
        trace = self.tmp / "trace2.json"
        with mock.patch.dict(os.environ, {"GIT_TRACE2_EVENT": str(trace)}):
            git(self.seed, "commit", "-q", "--allow-empty", "-m", "another base commit")
            git(self.seed, "push", "-q", "origin", "feat-cmux-next")
            git(self.lane, "fetch", "-q", "origin")
            self.hook(MERGE)
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        started = [event.get("argv", []) for event in events if event.get("event") == "child_start"]
        background = [argv for argv in started if "maintenance" in argv or ("gc" in argv and "--auto" in argv)]
        self.assertEqual(background, [], "git started auto maintenance in a fixture repo")

    def test_git_reads_no_config_from_outside_the_test_directory(self):
        """The runner's own ~/.gitconfig or /etc/gitconfig can't turn auto maintenance back on."""
        tmp = self.tmp.resolve()
        files = {line.split("\t")[0][len("file:"):]
                 for line in git(self.lane, "config", "--list", "--show-origin").splitlines() if line.startswith("file:")}
        outside = [f for f in files if not (self.lane / f).resolve().is_relative_to(tmp)]
        self.assertEqual(outside, [], "git read config from outside the test's directory")

    def test_ci_runs_this_test(self):
        self.assertIn("tests/test_guard_hooks_from_base.py", (ROOT / ".github/workflows/cmux-next.yml").read_text())


if __name__ == "__main__":
    unittest.main()
