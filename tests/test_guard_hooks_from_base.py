#!/usr/bin/env python3
"""The PreToolUse merge guards run the feat-cmux-next tip's guard code, never the checkout's.

palette-audit, 2026-10-21: `.claude/settings.json` ran `"$CLAUDE_PROJECT_DIR"/scripts/ci/merge-compile-guard-hook.sh`,
so a session in a pull request's worktree ran that branch's copy of the guard: a branch made before a guard fix
kept the old guard, and a pull request could edit the guard that judges its own merge. The hook now loads
scripts/ci/guards-from-base.sh from origin/feat-cmux-next, which runs the guards from that commit.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / ".claude/settings.json"
GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
# Stand-ins for the two guards: each says which copy ran.
GUARD = """import json, sys
json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
           "permissionDecisionReason": "merge guard %s"}}, sys.stdout)
"""
WARNING = """import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "base merge warning %s"}}))
"""


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
        git(self.tmp, "init", "-q", "--bare", "-b", "feat-cmux-next", "remote.git")
        self.seed = self.tmp / "seed"
        git(self.tmp, "clone", "-q", "remote.git", "seed")
        git(self.seed, "checkout", "-q", "-b", "feat-cmux-next")
        for path in (".claude/settings.json", "scripts/ci/guards-from-base.sh", "scripts/ci/merge-compile-guard-hook.sh",
                     "scripts/ci/base-merge-warning-hook.sh"):
            if (ROOT / path).exists():
                (self.seed / path).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / path, self.seed / path)
        self.guards("base v1")
        git(self.seed, "add", "-A")
        git(self.seed, "commit", "-qm", "base")
        git(self.seed, "push", "-q", "origin", "feat-cmux-next")
        # The pull request's worktree: branched from the base, with its own edit of the guard and its hook.
        self.lane = self.tmp / "lane"
        git(self.tmp, "clone", "-q", "-b", "feat-cmux-next", "remote.git", "lane")
        git(self.lane, "checkout", "-q", "-b", "pr")
        (self.lane / "scripts/ci/merge_compile_guard.py").write_text("")  # lets every merge through
        (self.lane / "scripts/ci/merge-compile-guard-hook.sh").write_text("exit 0\n")
        (self.lane / "scripts/ci/base_merge_warning.py").write_text("")
        git(self.lane, "commit", "-qam", "the pull request edits the guard that judges it")

    def guards(self, label: str) -> None:
        (self.seed / "scripts/ci/merge_compile_guard.py").write_text(GUARD % label)
        (self.seed / "scripts/ci/base_merge_warning.py").write_text(WARNING % label)

    def hook(self, command: str) -> tuple[int, dict | None, str]:
        payload = json.dumps({"tool_name": "Bash", "cwd": str(self.lane), "tool_input": {"command": command}})
        outputs, code, err = [], 0, ""
        for hook in pre_tool_use_commands():
            done = subprocess.run(["bash", "-c", hook], input=payload, capture_output=True, text=True, timeout=60,
                                  cwd=self.lane, env={**os.environ, "CLAUDE_PROJECT_DIR": str(self.lane)})
            code, err = code or done.returncode, err + done.stderr
            if done.stdout.strip():
                outputs.append(json.loads(done.stdout))
        self.assertLessEqual(len(outputs), 1, outputs)
        return code, (outputs[0] if outputs else None), err

    def test_a_merge_is_judged_by_the_base_guard_not_the_pull_requests_copy(self):
        code, out, err = self.hook("gh pr merge 5 -R manaflow-ai/cmux --squash")
        self.assertEqual(code, 0, err)
        self.assertIsNotNone(out, "the pull request's own copy of the guard judged its merge")
        self.assertEqual(out["hookSpecificOutput"]["permissionDecisionReason"], "merge guard base v1")

    def test_a_guard_fix_on_the_base_judges_a_branch_made_before_it(self):
        self.guards("base v2")
        git(self.seed, "commit", "-qam", "a guard fix lands")
        git(self.seed, "push", "-q", "origin", "feat-cmux-next")
        code, out, err = self.hook("gh pr merge 5 --squash")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["permissionDecisionReason"], "merge guard base v2")

    def test_the_update_branch_warning_comes_from_the_base_too(self):
        code, out, err = self.hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["additionalContext"], "base merge warning base v1")

    def test_a_stale_origin_is_fetched_before_a_merge(self):
        """A clone last fetched before the launcher landed has no origin/feat-cmux-next:scripts/ci/guards-from-base.sh;
        the hook fetches first, so the merge is still judged by the base guard."""
        git(self.lane, "update-ref", "refs/remotes/origin/feat-cmux-next", self.old_base())
        code, out, err = self.hook("gh pr merge 5 --squash")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["permissionDecisionReason"], "merge guard base v1")

    def test_a_merge_whose_guards_cannot_be_read_is_refused(self):
        """The merge guard fails closed (it refuses when it can't read GitHub), so the hook does too: a merge it can't
        judge is denied, never let through with only a stderr line."""
        old = self.old_base()
        git(self.lane, "remote", "set-url", "origin", str(self.tmp / "gone.git"))
        git(self.lane, "update-ref", "refs/remotes/origin/feat-cmux-next", old)
        code, out, err = self.hook("gh pr merge 5 --squash")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("merge guards did not run", out["hookSpecificOutput"]["permissionDecisionReason"])
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

    def test_ci_runs_this_test(self):
        self.assertIn("tests/test_guard_hooks_from_base.py", (ROOT / ".github/workflows/cmux-next.yml").read_text())


if __name__ == "__main__":
    unittest.main()
