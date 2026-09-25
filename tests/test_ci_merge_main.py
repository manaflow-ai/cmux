#!/usr/bin/env python3
"""scripts/merge-main.sh: merge the newest green main commit, then label guard failures.

The selection cases give last_green_base.py a main history in a temp git
repository and a verdict source (a dict, or a stub `gh` on PATH answering the
workflow-runs request), and check which commit it picks and what it says about
the newer ones. The merge cases run merge_main.py against a temp remote: it
must merge the green commit rather than the red tip, and a conflict must leave
the branch untouched with the paths named. The classification cases give the
temp repository its own small ci-guards.yml, break one guard on main and
another on the branch, and run the real scripts/ci/run_ci_guards.py through
merge_main.py: the first must come back inherited, the second introduced, and
a local pass stamp for the main commit must settle it without a rerun.
"""

from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import last_green_base  # noqa: E402
import merge_main  # noqa: E402
import run_ci_guards  # noqa: E402

GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_AUTHOR_NAME": "Merge Main Test",
    "GIT_AUTHOR_EMAIL": "merge-main@example.invalid",
    "GIT_COMMITTER_NAME": "Merge Main Test",
    "GIT_COMMITTER_EMAIL": "merge-main@example.invalid",
}
RUN_CI_GUARDS = [sys.executable, str(ROOT / "scripts/ci/run_ci_guards.py")]

GUARDS_WORKFLOW = textwrap.dedent("""\
    name: CI guards
    on: workflow_call
    jobs:
      workflow-guard-tests:
        strategy:
          matrix:
            group: ${{ fromJSON(inputs.groups) }}
        runs-on: ubuntu-24.04
        steps:
          - name: Checkout
            uses: actions/checkout@0000000000000000000000000000000000000000
          - name: Guard alpha
            if: ${{ matrix.group == 'ci' }}
            run: python3 guards/check.py alpha
          - name: Guard beta
            if: ${{ matrix.group == 'ci' }}
            run: python3 guards/check.py beta
      workflow-guard-history:
        runs-on: ubuntu-24.04
        steps:
          - name: History noop
            run: "true"
      workflow-guard-cli-scripts:
        runs-on: ubuntu-24.04
        steps:
          - name: CLI noop
            run: "true"
      workflow-guard-source-lints:
        runs-on: ubuntu-24.04
        steps:
          - name: Lint noop
            run: "true"
    """)
CHECK_SCRIPT = textwrap.dedent("""\
    import sys
    from pathlib import Path
    name = sys.argv[1]
    value = Path("guards", name).read_text().strip()
    print(f"{name} is {value}")
    sys.exit(0 if value == "ok" else 1)
    """)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env={**os.environ, **GIT_ENV}).stdout.strip()


def commit(repo: Path, message: str, files: dict[str, str]) -> str:
    for path, text in files.items():
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


class TempRepoCase(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(os.environ, GIT_ENV)
        self.env.start()
        self.addCleanup(self.env.stop)
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        # The remote holds main; the clone is the agent's checkout on a branch.
        self.remote = self.scratch / "remote"
        self.remote.mkdir()
        git(self.remote, "init", "-q", "-b", "main")
        self.base = commit(self.remote, "base", {"README": "base\n", ".github/workflows/ci-guards.yml": GUARDS_WORKFLOW,
                                                 "guards/check.py": CHECK_SCRIPT, "guards/alpha": "ok\n",
                                                 "guards/beta": "ok\n"})
        self.repo = self.scratch / "repo"
        git(self.scratch, "clone", "-q", str(self.remote), str(self.repo))
        git(self.repo, "checkout", "-q", "-b", "feature")

    def main_commit(self, message: str, files: dict[str, str]) -> str:
        return commit(self.remote, message, files)

    def run_merge(self, verdicts: dict[str, str], **options) -> tuple[int, str]:
        opts = merge_main.Options(repo=self.repo, remote="origin", **options)
        out = io.StringIO()
        lines: list[str] = []
        with redirect_stdout(out):
            code = merge_main.merge_main(opts, source=lambda shas: {s: verdicts.get(s, "missing") for s in shas},
                                         guard_command=[*RUN_CI_GUARDS, "--root", str(self.repo)],
                                         output=lines.append, stamps=self.scratch / "stamps")
        return code, "\n".join(lines)


class VerdictTests(unittest.TestCase):
    def test_newest_run_per_commit_decides(self) -> None:
        runs = [
            {"head_sha": "a", "status": "completed", "conclusion": "failure", "created_at": "2026-09-25T10:00:00Z"},
            {"head_sha": "a", "status": "completed", "conclusion": "success", "created_at": "2026-09-25T11:00:00Z"},
            {"head_sha": "b", "status": "in_progress", "conclusion": None, "created_at": "2026-09-25T11:00:00Z"},
            {"head_sha": "c", "status": "completed", "conclusion": "timed_out", "created_at": "2026-09-25T11:00:00Z"},
            {"head_sha": "d", "status": "completed", "conclusion": "cancelled", "created_at": "2026-09-25T11:00:00Z"},
        ]
        self.assertEqual(
            last_green_base.verdicts_from_runs(runs, ["a", "b", "c", "d", "e"]),
            {"a": "success", "b": "pending", "c": "failure", "d": "missing", "e": "missing"},
        )

    def test_choose_skips_newer_commits_until_green(self) -> None:
        selection = last_green_base.choose(
            ["tip", "mid", "old", "older"], {"tip": "pending", "mid": "failure", "old": "success"}, "tip")
        self.assertEqual(selection.chosen, "old")
        self.assertEqual(selection.skipped, [("tip", "pending"), ("mid", "failure")])
        lines = last_green_base.describe(selection)
        self.assertIn("skipping 2 newer commit(s) (1 failure, 1 pending)", lines[0])

    def test_no_green_commit_chooses_nothing(self) -> None:
        selection = last_green_base.choose(["tip", "mid"], {"tip": "failure"}, "tip")
        self.assertIsNone(selection.chosen)
        self.assertEqual(selection.skipped, [("tip", "failure"), ("mid", "missing")])


class SelectionTests(TempRepoCase):
    def test_candidates_are_first_parent_commits_the_branch_lacks(self) -> None:
        first = self.main_commit("one", {"README": "one\n"})
        git(self.repo, "fetch", "-q", "origin")
        git(self.repo, "merge", "-q", "--no-edit", "origin/main")
        second = self.main_commit("two", {"README": "two\n"})
        third = self.main_commit("three", {"README": "three\n"})
        git(self.repo, "fetch", "-q", "origin")
        seen: list[list[str]] = []

        def source(shas: list[str]) -> dict[str, str]:
            seen.append(shas)
            return {third: "failure", second: "success"}

        selection = last_green_base.select(self.repo, "origin/main", source)
        self.assertEqual(seen, [[third, second]], "commits already merged are not candidates")
        self.assertNotIn(first, seen[0])
        self.assertEqual(selection.chosen, second)
        self.assertEqual(selection.skipped, [(third, "failure")])

    def test_up_to_date_branch_needs_no_verdicts(self) -> None:
        git(self.repo, "fetch", "-q", "origin")
        selection = last_green_base.select(self.repo, "origin/main", lambda shas: self.fail("no GitHub read"))
        self.assertTrue(selection.up_to_date)

    def test_github_source_reads_one_workflow_runs_page(self) -> None:
        tip = self.main_commit("tip", {"README": "tip\n"})
        git(self.repo, "fetch", "-q", "origin")
        bin_dir = self.scratch / "bin"
        bin_dir.mkdir()
        calls = self.scratch / "gh-calls"
        runs = {"workflow_runs": [
            {"head_sha": tip, "status": "completed", "conclusion": "failure", "created_at": "2026-09-25T12:00:00Z"},
            {"head_sha": self.base, "status": "completed", "conclusion": "success", "created_at": "2026-09-25T11:00:00Z"},
        ]}
        gh = bin_dir / "gh"
        gh.write_text(f"#!/bin/sh\necho \"$*\" >> {calls}\ncat <<'JSON'\n{json.dumps(runs)}\nJSON\n")
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        with mock.patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}):
            code = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/last_green_base.py"), "--repo", str(self.repo),
                 "--ref", "origin/main", "--head", self.base + "~0", "--json"],
                capture_output=True, text=True,
            )
        # The branch holds base already, so tip is the only candidate and it is red.
        self.assertEqual(code.returncode, 1, code.stderr)
        self.assertEqual(json.loads(code.stdout)["skipped"], [{"sha": tip, "verdict": "failure"}])
        logged = calls.read_text().splitlines()
        self.assertEqual(len(logged), 1, "one request for every candidate")
        self.assertIn("actions/workflows/ci-fast-guards.yml/runs?branch=main", logged[0])


class MergeTests(TempRepoCase):
    def test_merges_the_last_green_commit_not_the_red_tip(self) -> None:
        commit(self.repo, "branch work", {"feature.txt": "feature\n"})
        green = self.main_commit("green", {"green.txt": "green\n"})
        red = self.main_commit("red", {"red.txt": "red\n"})
        code, output = self.run_merge({red: "failure", green: "success"}, guards=False)
        self.assertEqual(code, 0, output)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD^2"), green)
        self.assertTrue((self.repo / "green.txt").exists())
        self.assertFalse((self.repo / "red.txt").exists())
        self.assertIn(f"skipping 1 newer commit(s) (1 failure)", output)
        self.assertIn(red[:11], output)
        self.assertIn("Merge main", git(self.repo, "log", "-1", "--format=%s"))

    def test_tip_flag_merges_the_red_tip(self) -> None:
        self.main_commit("green", {"green.txt": "green\n"})
        red = self.main_commit("red", {"red.txt": "red\n"})
        code, output = self.run_merge({red: "failure"}, guards=False, tip=True)
        self.assertEqual(code, 0, output)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD^2"), red)

    def test_no_green_commit_merges_nothing(self) -> None:
        red = self.main_commit("red", {"red.txt": "red\n"})
        head = git(self.repo, "rev-parse", "HEAD")
        code, output = self.run_merge({red: "pending"}, guards=False)
        self.assertEqual(code, 1)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        self.assertIn("--tip", output)

    def test_dry_run_changes_nothing(self) -> None:
        green = self.main_commit("green", {"green.txt": "green\n"})
        head = git(self.repo, "rev-parse", "HEAD")
        code, output = self.run_merge({green: "success"}, dry_run=True)
        self.assertEqual(code, 0)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        self.assertIn(f"would merge {green[:11]}", output)

    def test_conflict_aborts_and_names_the_paths(self) -> None:
        commit(self.repo, "branch readme", {"README": "branch\n"})
        green = self.main_commit("main readme", {"README": "main\n"})
        head = git(self.repo, "rev-parse", "HEAD")
        code, output = self.run_merge({green: "success"})
        self.assertEqual(code, 1)
        self.assertIn("README: not a generated file", output)
        self.assertIn(f"git merge {green}", output)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")


class ClassificationTests(TempRepoCase):
    def test_inherited_and_introduced_failures_are_told_apart(self) -> None:
        # Main breaks alpha (say CI passed it on Linux, so its verdict is green);
        # the branch breaks beta. After the merge both fail locally.
        broken_main = self.main_commit("main breaks alpha", {"guards/alpha": "bad\n"})
        commit(self.repo, "branch breaks beta", {"guards/beta": "bad\n"})
        code, output = self.run_merge({broken_main: "success"})
        self.assertEqual(code, 0, "guard failures never fail the merge")
        self.assertIn(f"inherited from main {broken_main[:11]}: workflow-guard-tests / ci: Guard alpha", output)
        self.assertIn("introduced by this branch: workflow-guard-tests / ci: Guard beta", output)
        self.assertIn("next: fix the failure(s) this branch introduced", output)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD^2"), broken_main)
        self.assertEqual(git(self.repo, "worktree", "list").count("\n"), 0, "the base worktree is removed")

    def test_strict_exits_nonzero_only_for_introduced_failures(self) -> None:
        broken_main = self.main_commit("main breaks alpha", {"guards/alpha": "bad\n"})
        code, output = self.run_merge({broken_main: "success"}, strict=True)
        self.assertEqual(code, 0, output)
        self.assertIn("nothing to fix on this branch", output)
        git(self.repo, "reset", "-q", "--hard", "HEAD^1")
        commit(self.repo, "branch breaks beta", {"guards/beta": "bad\n"})
        code, output = self.run_merge({broken_main: "success"}, strict=True)
        self.assertEqual(code, 3, output)

    def test_a_pass_stamp_on_main_settles_it_without_a_rerun(self) -> None:
        green = self.main_commit("green", {"green.txt": "green\n"})
        commit(self.repo, "branch breaks beta", {"guards/beta": "bad\n"})
        git(self.repo, "fetch", "-q", "origin")
        stamps = self.scratch / "stamps"
        stamps.mkdir()
        (stamps / green).write_text(json.dumps({"sha": green, "groups": ["ci"]}))
        failure = merge_main.GuardFailure(unit="workflow-guard-tests / ci", job="workflow-guard-tests",
                                          group="ci", name="Guard beta", output_tail="")
        merge_main.classify(self.repo, [failure], green, ["false"], stamps)
        self.assertEqual(failure.origin, "introduced")
        self.assertIn("pass stamp", failure.why)
        # A stamp for a narrower set of groups does not cover another group.
        other = merge_main.GuardFailure(unit="workflow-guard-tests / preflight", job="workflow-guard-tests",
                                        group="preflight", name="Guard beta", output_tail="")
        self.assertFalse(merge_main.stamp_covers(stamps, green, "no-tree", {"preflight"}))
        merge_main.classify(self.repo, [other], green, [*RUN_CI_GUARDS], stamps)
        self.assertNotIn("pass stamp", other.why)

    def test_step_selection_keeps_stateful_groups_whole(self) -> None:
        setup = run_ci_guards.Step(name="Init submodule", run="git submodule update --init x", env={},
                                   working_directory=None)
        lint = run_ci_guards.Step(name="Lint", run="python3 lint.py", env={}, working_directory=None)
        other = run_ci_guards.Step(name="Other", run="python3 other.py", env={}, working_directory=None)
        stateful = run_ci_guards.Unit(job="j", group="a", steps=[setup, lint])
        plain = run_ci_guards.Unit(job="j", group="b", steps=[lint, other])
        selected = run_ci_guards.select_steps([stateful, plain], {"Lint"})
        self.assertEqual([step.name for step in selected[0].steps], ["Init submodule", "Lint"])
        self.assertEqual([step.name for step in selected[1].steps], ["Lint"])


class RemoteTests(unittest.TestCase):
    def test_detects_the_cmux_remote_by_url(self) -> None:
        with tempfile.TemporaryDirectory() as scratch, mock.patch.dict(os.environ, GIT_ENV):
            repo = Path(scratch)
            git(repo, "init", "-q")
            git(repo, "remote", "add", "origin", "git@github.com:someone/cmux.git")
            git(repo, "remote", "add", "upstream", "https://github.com/manaflow-ai/cmux.git")
            git(repo, "remote", "add", "mf", "git@github.com:manaflow-ai/cmux.git")
            self.assertEqual(merge_main.cmux_remote(repo), "mf")
            git(repo, "remote", "set-url", "origin", "https://github.com/manaflow-ai/cmux")
            self.assertEqual(merge_main.cmux_remote(repo), "origin")


if __name__ == "__main__":
    unittest.main()
