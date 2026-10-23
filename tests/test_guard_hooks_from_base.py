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
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / ".claude/settings.json"
GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
# Stand-ins for the two guards: each says which copy ran.
GUARD = """import json, sys
json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
           "permissionDecisionReason": "merge guard %s"}}, sys.stdout)
"""
# A stand-in guard that lets the merge through with a warning, as the real guard does for a pending compile.
HOLD = """import json, sys
text = "merge guard %s holds nothing; merging anyway"
json.dump({"systemMessage": text, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}},
          sys.stdout)
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
        self.isolate_git()
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

    def isolate_git(self) -> None:
        """Every git this test starts, its own and the hook's, reads config only from inside self.tmp, and that
        config turns auto maintenance and gc off. Otherwise a commit, push or fetch leaves a detached
        `git maintenance run --auto` taking and dropping .git/objects/maintenance.lock while the cleanup's rmtree
        walks the directory, and the rmtree fails with FileNotFoundError."""
        home = self.tmp / "home"
        home.mkdir()
        config = home / ".gitconfig"
        config.write_text("[maintenance]\n\tauto = false\n\tautoDetach = false\n"
                          "[gc]\n\tauto = 0\n\tautoDetach = false\n")
        env = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"), "GIT_CONFIG_GLOBAL": str(config),
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

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

    def test_a_merge_whose_guards_cannot_be_read_goes_ahead_with_a_warning(self):
        """The merge guard refuses only a compile that finished red; a merge it can't judge, because GitHub or the
        guards could not be read, goes ahead with a warning the agent and the person both see (2026-10-21: the
        guard's timed-out reads held #23660 and #23371 for hours with every gate met)."""
        old = self.old_base()
        git(self.lane, "remote", "set-url", "origin", str(self.tmp / "gone.git"))
        git(self.lane, "update-ref", "refs/remotes/origin/feat-cmux-next", old)
        code, out, err = self.hook("gh pr merge 5 --squash")
        self.assertEqual(code, 0, err)
        self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
        self.assertIn("merge guards did not run", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(out["systemMessage"], out["hookSpecificOutput"]["additionalContext"])
        # The update-branch warning only warns: unreadable, it does not block.
        code, out, err = self.hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertIsNone(out)
        self.assertNotEqual(code, 2)

    def test_a_base_without_the_guards_lets_a_merge_through_with_a_warning(self):
        """guards-from-base.sh itself is on the base but the guards are not (`git archive` fails)."""
        git(self.seed, "rm", "-q", "scripts/ci/merge_compile_guard.py")
        git(self.seed, "commit", "-qm", "the guard leaves the base")
        git(self.seed, "push", "-q", "origin", "feat-cmux-next")
        code, out, err = self.hook("gh pr merge 5 --squash")
        self.assertEqual(code, 0, err)
        self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
        self.assertIn("cannot read the guards", out["systemMessage"])
        self.assertEqual(out["systemMessage"], out["hookSpecificOutput"]["additionalContext"])

    def land_on_base(self, path: str, text: str) -> None:
        (self.seed / path).write_text(text)
        git(self.seed, "commit", "-qam", f"the base changes {path}")
        git(self.seed, "push", "-q", "origin", "feat-cmux-next")

    def test_a_guard_that_crashes_never_blocks_a_merge(self):
        """Codex review of #24265: a hook that exits 2 (a bash syntax error does) blocks the tool call in Claude
        Code, though no compile finished red. Every failure of a guard is a warning."""
        for broken in ("if then fi\n", "exit 2\n", "exit 3\n"):
            with self.subTest(hook=broken):
                self.land_on_base("scripts/ci/merge-compile-guard-hook.sh", broken)
                code, out, err = self.hook("gh pr merge 5 --squash")
                self.assertNotEqual(code, 2, err)
                if out is not None:
                    self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
                    self.assertIn("merging anyway", out["systemMessage"])
        self.land_on_base("scripts/ci/base-merge-warning-hook.sh", "exit 2\n")
        code, out, err = self.hook("gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertNotEqual(code, 2, err)

    def test_the_settings_hook_never_exits_2_when_the_launcher_itself_breaks(self):
        self.land_on_base("scripts/ci/guards-from-base.sh", "exit 2\n")
        code, out, err = self.hook("gh pr merge 5 --squash")
        self.assertNotEqual(code, 2, err)

    def test_a_merge_warning_does_not_hide_the_update_branch_warning(self):
        """Codex review of #24265: `gh pr merge ...; gh api .../update-branch` used to be refused whole; now the merge
        may go ahead with a warning, and the update-branch warning must still be said."""
        self.land_on_base("scripts/ci/merge_compile_guard.py", HOLD % "base v1")
        code, out, err = self.hook("gh pr merge 5 --squash; gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertEqual(code, 0, err)
        context = out["hookSpecificOutput"]["additionalContext"]
        self.assertIn("merge guard base v1 holds nothing", context)
        self.assertIn("base merge warning base v1", context)
        self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
        self.assertIn("merge guard base v1 holds nothing", out["systemMessage"])

    def test_a_refusal_still_wins_over_a_warning(self):
        code, out, err = self.hook("gh pr merge 5 --squash; gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(out["hookSpecificOutput"]["permissionDecisionReason"], "merge guard base v1")

    def test_a_refusal_in_any_json_spacing_still_refuses(self):
        """Codex review of #24265 (round 2): the loop matched `"permissionDecision": "deny"` as text, so a valid
        refusal written with other spacing was merged into a warning and the red compile's refusal was lost."""
        spaced = GUARD.replace("sys.stdout)", "sys.stdout, separators=(',', ':  '), indent=2)")
        self.land_on_base("scripts/ci/merge_compile_guard.py", spaced % "base v1")
        for command in ("gh pr merge 5 --squash",
                        "gh pr merge 5 --squash; gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch"):
            with self.subTest(command=command):
                code, out, err = self.hook(command)
                self.assertEqual(code, 0, err)
                self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertEqual(out["hookSpecificOutput"]["permissionDecisionReason"], "merge guard base v1")

    def test_a_refusal_never_waits_for_the_next_guard(self):
        """Codex review of #24265 (round 3): both guards ran before the refusal was read, so a slow update-branch
        warning could run the hook past its timeout with the refusal unprinted, and the merge went through."""
        self.land_on_base("scripts/ci/base-merge-warning-hook.sh", "sleep 30\n")
        started = time.monotonic()
        code, out, err = self.hook("gh pr merge 5 --squash; gh api -X PUT repos/manaflow-ai/cmux/pulls/5/update-branch")
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(code, 0, err)
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

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
            self.hook("gh pr merge 5 --squash")
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
