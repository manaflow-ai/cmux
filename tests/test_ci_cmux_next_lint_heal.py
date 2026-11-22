#!/usr/bin/env python3
"""A red `web lint (fast)` push names its culprit, then the tip gets the lint's fix or the culprit's revert.

Leo, 2026-11-22: "should've been caught and fixed faster. hell, maybe even should've been automatic."
The incident: #49052 (66beef47be66, 01:27Z) brought a webview type error; the push's lint step never ran (its Hook
tests step was red), and the NEXT nightly failed its webview checks for hours. These tests run the judge on a
throwaway git history with a fake lint (a file `RED` in the tree is a red), so they need no bun or network.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_lint_heal as heal  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-web-lint.yml"
ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def sh(repo: Path, *argv: str) -> str:
    return subprocess.run(["git", *argv], cwd=repo, env=ENV, check=True, capture_output=True, text=True).stdout.strip()


class History:
    """A main line of squash commits: each writes or removes files."""

    def __init__(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.dir.name) / "r"
        self.repo.mkdir()
        sh(self.repo, "init", "-q", "-b", "feat-cmux-next")
        self.commit("base (#1)", {"a.ts": "ok\n"})

    def commit(self, subject: str, files: dict[str, str | None]) -> str:
        for name, text in files.items():
            path = self.repo / name
            if text is None:
                path.unlink()
            else:
                path.write_text(text)
        sh(self.repo, "add", "-A")
        sh(self.repo, "commit", "-q", "-m", subject)
        return sh(self.repo, "rev-parse", "HEAD")

    def lint(self, fixable: bool = False):
        """The fake web lint: RED in the linted tree is red; with fixable, --fix deletes a RED whose text is fmt."""
        calls = []

        def run(base, head, repo, fix):
            calls.append((base, head, fix))
            if fix:
                red = Path(repo) / "RED"
                if fixable and red.exists() and red.read_text() == "fmt\n":
                    red.unlink()
                return not red.exists()
            return "RED" not in sh(self.repo, "ls-tree", "--name-only", head)

        run.calls = calls
        return run


class Judge(unittest.TestCase):
    def setUp(self):
        self.h = History()
        self.addCleanup(self.h.dir.cleanup)
        patcher = mock.patch.object(heal, "ROOT", self.h.repo)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.env = mock.patch.dict(os.environ, ENV)
        self.env.start()
        self.addCleanup(self.env.stop)

    def judge(self, before, sha, tip, lint):
        return heal.judge(before, sha, tip, run_lint=lint, work=Path(self.h.dir.name))

    def test_a_type_error_the_fixers_cannot_fix_gets_the_culprits_revert(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("Agent chat: a turn holds its header (#49052)", {"RED": "type error\n", "b.ts": "x\n"})
        tip = self.h.commit("unrelated swift (#49060)", {"c.swift": "y\n"})
        verdict = self.judge(good, bad, tip, self.h.lint())
        self.assertEqual((verdict.action, verdict.culprit, verdict.good), (heal.REVERT, bad, good), verdict.reason)

    def test_a_format_red_gets_the_fixers_patch_not_a_revert(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("web: a thing (#7)", {"RED": "fmt\n"})
        verdict = self.judge(good, bad, bad, self.h.lint(fixable=True))
        self.assertEqual(verdict.action, heal.AUTOFIX, verdict.reason)
        self.assertIn("RED", verdict.patch)

    def test_the_first_red_commit_of_a_multi_commit_push_is_the_culprit(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        self.h.commit("one", {"d.ts": "1\n"})
        bad = self.h.commit("two", {"RED": "type error\n"})
        tip = self.h.commit("three", {"e.ts": "3\n"})
        verdict = self.judge(good, tip, tip, self.h.lint())
        self.assertEqual((verdict.action, verdict.culprit), (heal.REVERT, bad))

    def test_a_red_that_does_not_repeat_opens_nothing(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        sha = self.h.commit("web: fine (#8)", {"f.ts": "ok\n"})
        verdict = self.judge(good, sha, sha, self.h.lint())
        self.assertEqual(verdict.action, heal.NONE)
        self.assertIn("did not repeat", verdict.reason)

    def test_a_red_fixed_at_the_tip_opens_nothing(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("web: broke (#9)", {"RED": "type error\n"})
        tip = self.h.commit("fix(agent-chat): the type error", {"RED": None})
        verdict = self.judge(good, bad, tip, self.h.lint())
        self.assertEqual(verdict.action, heal.NONE)
        self.assertIn("fixed already", verdict.reason)

    def test_a_revert_that_leaves_the_tip_red_opens_nothing(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("web: broke (#10)", {"RED": "type error\n"})
        tip = self.h.commit("web: also red, other file (#11)", {"RED2": "x\n"})

        def lint(base, head, repo, fix):
            tree = sh(self.h.repo, "ls-tree", "--name-only", head) if head else ""
            if fix:
                return False
            return "RED" not in tree.split() and "RED2" not in tree.split()

        verdict = self.judge(good, bad, tip, lint)
        self.assertEqual(verdict.action, heal.NONE)
        self.assertIn("not its alone", verdict.reason)

    def test_a_revert_that_conflicts_opens_nothing(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("web: broke (#12)", {"RED": "type error\n"})
        tip = self.h.commit("web: edits the same line (#13)", {"RED": "still red\n"})
        verdict = self.judge(good, bad, tip, self.h.lint())
        self.assertEqual(verdict.action, heal.NONE)
        self.assertIn("conflicts", verdict.reason)

    def files_lint(self, base, head, repo, fix):
        """Each RED* file in the linted tree is its own red, named by the file."""
        tree = sh(self.h.repo, "ls-tree", "--name-only", head).split() if head else []
        reds = frozenset(f"typescript(TS2304): {name}" for name in tree if name.startswith("RED"))
        return heal.Lint(not reds, reds)

    def test_other_commits_reds_at_the_tip_do_not_stop_the_culprits_revert(self):
        # The #49052 incident: the tip also failed checks other commits broke, so it never lints green.
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("Agent chat: a turn holds its header (#49052)", {"RED_folds": "x\n"})
        tip = self.h.commit("design tokens (#49061)", {"RED_tokens": "y\n"})
        verdict = self.judge(good, bad, tip, self.files_lint)
        self.assertEqual((verdict.action, verdict.culprit), (heal.REVERT, bad), verdict.reason)

    def test_a_revert_that_brings_a_new_red_opens_nothing(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("web: broke (#15)", {"RED_a": "x\n"})
        tip = self.h.commit("web: builds on it (#16)", {"b.ts": "uses a\n"})

        def lint(base, head, repo, fix):
            if head and sh(self.h.repo, "rev-parse", f"{head}^") == tip:  # the revert, on the tip
                return heal.Lint(False, frozenset({"typescript(TS2304): b.ts lost a"}))
            return self.files_lint(base, head, repo, fix)

        verdict = self.judge(good, bad, tip, lint)
        self.assertEqual(verdict.action, heal.NONE)
        self.assertIn("not its alone", verdict.reason)

    def test_a_lint_that_refused_to_run_is_no_red(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        bad = self.h.commit("web: broke (#14)", {"RED": "type error\n"})

        def lint(base, head, repo, fix):
            raise heal.NotLinted("web-lint: refused; nothing was linted. This worktree is a sparse checkout")

        verdict = self.judge(good, bad, bad, lint)
        self.assertEqual((verdict.action, verdict.culprit), (heal.NONE, ""))
        self.assertIn("could not run", verdict.reason)

    def test_the_real_lint_turns_a_refusal_into_no_verdict(self):
        fake = Path(self.h.dir.name) / "fake_lint.py"
        fake.write_text("import sys\nprint('web-lint: refused; nothing was linted. sparse', file=sys.stderr)\nsys.exit(1)\n")
        with mock.patch.object(heal, "LINT", fake):
            with self.assertRaises(heal.NotLinted):
                heal.lint("a" * 40, "b" * 40)

    def test_a_long_range_is_not_probed(self):
        good = sh(self.h.repo, "rev-parse", "HEAD")
        for i in range(heal.MAX_PROBES + 1):
            sha = self.h.commit(f"c{i}", {f"f{i}": "x\n"})
        lint = self.h.lint()
        verdict = self.judge(good, sha, sha, lint)
        self.assertEqual((verdict.action, lint.calls), (heal.NONE, []))


class PullRequest(unittest.TestCase):
    def test_a_revert_names_the_pr_and_lands_through_autoland(self):
        made = heal.pull_request(heal.REVERT, "6" * 40, "6" * 40, "Agent chat: header (#49052)", owner="",
                                 run_url="https://x/runs/1", branch="feat-cmux-next")
        self.assertEqual(made["head"], "revert/pr-49052")
        self.assertTrue(made["title"].startswith('Revert "Agent chat: header (#49052)"'))
        self.assertTrue(made["body"].startswith("Reverts #49052:"))
        self.assertIn("next-autoland lands it", made["body"])
        self.assertNotIn("HOLD", made["body"])

    def test_a_teammates_culprit_opens_held(self):
        made = heal.pull_request(heal.REVERT, "6" * 40, "6" * 40, "Sidebar: x", owner="lawrencecchen",
                                 run_url="u", branch="feat-cmux-next")
        self.assertTrue(made["body"].startswith("HOLD: lawrencecchen's merge."))
        self.assertEqual(made["head"], "revert/lint-" + "6" * 12)

    def test_an_autofix_says_which_base_red_it_fixes(self):
        made = heal.pull_request(heal.AUTOFIX, "6" * 40, "5" * 40, "web: x (#7)", owner="", run_url="u",
                                 branch="feat-cmux-next")
        self.assertEqual(made["head"], "heal/web-lint-" + "6" * 12)
        self.assertTrue(made["body"].startswith("Fixes base red: cmux-next web lint / web lint (fast)."))


class Reds(unittest.TestCase):
    INCIDENT = """
  ! eslint(no-unused-vars): Parameter 'foldsPrompt' is declared but never used.
  x typescript(TS2304): Cannot find name 'foldsPrompt'.
      ,-[src/agent-session/acpmux/conversation/turns.ts:3019:8]
  x jsx-a11y(aria-props): Invalid ARIA prop.
web-lint: web lint failed in 62.3s: webviews: bun run check:fixed-waits, webviews: vp lint
"""

    def test_the_incidents_output_reads_as_its_diagnostics_and_pieces(self):
        self.assertEqual(heal.reds_of(self.INCIDENT), {
            "typescript(TS2304): Cannot find name 'foldsPrompt'.", "jsx-a11y(aria-props): Invalid ARIA prop.",
            "piece: webviews: bun run check:fixed-waits", "piece: webviews: vp lint"})

    def test_a_revert_clears_when_only_other_reds_stay(self):
        culprit = heal.Lint(False, frozenset({"typescript(TS2304): foldsPrompt", "piece: webviews: vp lint"}))
        tip = heal.Lint(False, culprit.reds | {"piece: webviews: bun run check:fixed-waits", "piece: webviews: vp lint"})
        after = heal.Lint(False, frozenset({"piece: webviews: bun run check:fixed-waits", "piece: webviews: vp lint"}))
        self.assertTrue(heal.clears(culprit, tip, after))
        self.assertFalse(heal.clears(culprit, tip, heal.Lint(False, after.reds | {"typescript(TS2304): foldsPrompt"})))
        self.assertFalse(heal.clears(culprit, tip, heal.Lint(False, after.reds | {"typescript(TS2345): new"})))


class DirectPush(unittest.TestCase):
    """Leo, 2026-11-22 06:01Z: "if the fix is clear i think you guys should be able to unilaterally push commits
    directly." A verified revert goes straight to the branch; a refusal or a teammate's culprit opens the PR."""

    def setUp(self):
        self.h = History()
        self.addCleanup(self.h.dir.cleanup)
        self.remote = Path(self.h.dir.name) / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "feat-cmux-next", str(self.remote)], env=ENV, check=True)
        self.good = sh(self.h.repo, "rev-parse", "HEAD")
        self.bad = self.h.commit("Agent chat: a turn holds its header (#49052)", {"RED": "type error\n"})
        self.tip = self.h.commit("unrelated swift (#49060)", {"c.swift": "y\n"})
        sh(self.h.repo, "push", "-q", str(self.remote), "HEAD:refs/heads/feat-cmux-next")
        for target in (heal, heal.sys.modules["post_merge_batch"]):
            patcher = mock.patch.object(target, "ROOT", self.h.repo)
            patcher.start()
            self.addCleanup(patcher.stop)
        env = mock.patch.dict(os.environ, ENV)
        env.start()
        self.addCleanup(env.stop)
        self.posted = []
        self.out = Path(self.h.dir.name) / "out"
        self.out.write_text("")

    def api(self, path, method="GET", fields=None):
        if method == "POST" and path.endswith("/pulls"):
            self.posted.append(fields)
            return {"html_url": "https://x/pull/1"}
        return []

    def open(self, owner="", direct=True):
        argv = ["open", "--repo", "o/r", "--action", "revert", "--culprit", self.bad, "--good", self.good,
                "--tip", self.tip, "--push-url", str(self.remote), "--github-output", str(self.out),
                "--summary", os.devnull] + (["--direct"] if direct else [])
        with mock.patch.object(heal, "gh_api", self.api), mock.patch.object(heal, "culprit_owner", return_value=owner), \
                mock.patch.object(heal, "start_branch"):
            return heal.main(argv)

    def remote_tip(self):
        return subprocess.run(["git", "rev-parse", "feat-cmux-next"], cwd=self.remote, env=ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_a_clear_revert_is_pushed_straight_to_the_branch_with_no_pull_request(self):
        self.assertEqual(self.open(), 0)
        head = self.remote_tip()
        self.assertNotEqual(head, self.tip)
        self.assertEqual(sh(self.h.repo, "rev-parse", f"{head}^"), self.tip)
        self.assertNotIn("RED", sh(self.h.repo, "ls-tree", "--name-only", head).split())
        self.assertEqual(self.posted, [])
        self.assertIn(f"pushed={head}", self.out.read_text())

    def test_a_refused_direct_push_keeps_githubs_words_and_opens_the_pull_request(self):
        moved = self.h.commit("someone landed meanwhile (#49070)", {"m.ts": "1\n"})
        sh(self.h.repo, "push", "-q", str(self.remote), f"{moved}:refs/heads/feat-cmux-next")
        self.assertEqual(self.open(), 0)
        self.assertEqual(self.remote_tip(), moved)
        self.assertEqual(len(self.posted), 1)
        self.assertIn("refused", self.posted[0]["body"])
        self.assertIn("direct_refused=", self.out.read_text())

    def test_a_teammates_culprit_never_goes_direct(self):
        self.open(owner="lawrencecchen")
        self.assertEqual(self.remote_tip(), self.tip)
        self.assertTrue(self.posted[0]["body"].startswith("HOLD: lawrencecchen's merge."))

    def test_without_direct_it_opens_the_pull_request(self):
        self.open(direct=False)
        self.assertEqual(self.remote_tip(), self.tip)
        self.assertEqual(len(self.posted), 1)


class Workflow(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_the_lint_runs_after_a_red_hook_test_and_reports_its_own_red(self):
        steps = {s.get("name"): s for s in self.jobs["web-lint"]["steps"]}
        lint = steps["Web lint on the pushed range"]
        self.assertEqual((lint["id"], lint["if"]), ("lint", "${{ !cancelled() }}"))
        self.assertIn("steps.lint.outcome == 'failure'", self.jobs["web-lint"]["outputs"]["lint_red"])

    def test_heal_acts_only_on_the_lints_own_red_with_a_kill_switch_and_no_write_token(self):
        job = self.jobs["heal"]
        self.assertIn("needs.web-lint.outputs.lint_red == 'true'", job["if"])
        self.assertIn("vars.NEXT_LINT_HEAL != '0'", job["if"])
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertNotIn("environment", job)

    def test_only_heal_open_holds_the_app_token(self):
        job = self.jobs["heal-open"]
        self.assertEqual(job["environment"]["name"], "ci-routing-agent")
        runs = "\n".join(s.get("run", "") for s in job["steps"])
        self.assertIn("cmux_next_lint_heal.py open", runs)
        self.assertNotIn("web_lint_prepush", runs)
        self.assertNotIn("bun", runs)

    def test_heal_open_pushes_direct_onto_the_judged_tip_with_its_own_kill_switch(self):
        job = self.jobs["heal-open"]
        self.assertEqual(job["steps"][0]["with"]["ref"], "${{ needs.heal.outputs.tip }}")
        step = next(s for s in job["steps"] if "cmux_next_lint_heal.py open" in s.get("run", ""))
        self.assertIn("$DIRECT", step["run"])
        self.assertIn("vars.NEXT_LINT_HEAL_DIRECT != '0'", step["env"]["DIRECT"])
        self.assertEqual(self.jobs["heal"]["outputs"]["tip"], "${{ steps.judge.outputs.tip }}")


if __name__ == "__main__":
    unittest.main()
