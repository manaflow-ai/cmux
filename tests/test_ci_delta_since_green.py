#!/usr/bin/env python3
"""Delta CI: route a pull request from its last green head (RFC #14631, slice 2).

Each case builds an origin repository, a pull request history on it and the
merge commit GitHub would test, then runs the selector from a depth-2 clone of
that merge commit, as actions/checkout leaves it in ci.yml's `changes` job.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "delta_since_green.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

spec = importlib.util.spec_from_file_location("delta_since_green", HELPER)
assert spec and spec.loader
delta = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = delta
spec.loader.exec_module(delta)

GIT_ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-c", "init.defaultBranch=main", *args],
        cwd=cwd, env=GIT_ENV, check=True, capture_output=True, text=True,
    ).stdout.strip()


class Origin:
    """The server-side repository: main plus a pull request branch."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.path = root / "origin"
        self.path.mkdir()
        git(self.path, "init", "-q")
        git(self.path, "config", "uploadpack.allowFilter", "true")
        git(self.path, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.commit("main", {"app/a.txt": "a0\n", "web/w.txt": "w0\n", "docs/d.txt": "d0\n"})
        git(self.path, "checkout", "-q", "-b", "pr")
        git(self.path, "checkout", "-q", "main")

    def commit(self, branch: str, files: dict[str, str], message: str = "change") -> str:
        if git(self.path, "branch", "--list", branch):
            git(self.path, "checkout", "-q", branch)
        for name, text in files.items():
            target = self.path / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", message)
        return git(self.path, "rev-parse", "HEAD")

    def merge_main_into_pr(self, keep_ours: tuple[str, ...] = ()) -> str:
        git(self.path, "checkout", "-q", "pr")
        git(self.path, "merge", "-q", "--no-ff", "--no-commit", "main")
        for name in keep_ours:
            git(self.path, "checkout", "HEAD", "--", name)
        git(self.path, "commit", "-q", "-m", "Merge main")
        return git(self.path, "rev-parse", "HEAD")

    def merge_branch_into_pr(self, branch: str) -> str:
        git(self.path, "checkout", "-q", "pr")
        git(self.path, "merge", "-q", "--no-ff", "-m", f"Merge {branch}", branch)
        return git(self.path, "rev-parse", "HEAD")

    def force_pr(self, commit: str) -> None:
        git(self.path, "checkout", "-q", "pr")
        git(self.path, "reset", "-q", "--hard", commit)

    def tested_merge(self) -> tuple[str, str]:
        """GitHub's refs/pull/N/merge: main first, the head second."""
        head = git(self.path, "rev-parse", "pr")
        git(self.path, "checkout", "-q", "--detach", "main")
        git(self.path, "merge", "-q", "--no-ff", "-m", "GitHub merge", head)
        merge = git(self.path, "rev-parse", "HEAD")
        git(self.path, "update-ref", "refs/pull/1/merge", merge)
        git(self.path, "checkout", "-q", "main")
        return merge, head

    def checkout(self, merge: str) -> Path:
        """actions/checkout with fetch-depth 2."""
        work = self.root / "work"
        work.mkdir()
        git(work, "init", "-q")
        git(work, "remote", "add", "origin", self.path.as_uri())
        git(work, "fetch", "-q", "--no-tags", "--depth=2", "origin", merge)
        git(work, "checkout", "-q", "--detach", merge)
        return work


class Case(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.origin = Origin(Path(directory.name))
        self.queried: list[list[str]] = []

    def decide(self, verdicts: dict[str, str]) -> "delta.Decision":
        merge, head = self.origin.tested_merge()
        work = self.origin.checkout(merge)
        # rev-list must not see past the shallow boundary before the selector fetches.
        self.assertEqual(len(git(work, "rev-list", merge).split()), 3)

        def lookup(oids: list[str]) -> dict[str, str | None]:
            self.queried.append(oids)
            return {oid: verdicts.get(oid) for oid in oids}

        self.work = work
        return delta.decide(delta.Git(work), merge, head, lookup)

    def skip_reason(self, verdicts: dict[str, str]) -> str:
        with self.assertRaises(delta.Skip) as caught:
            self.decide(verdicts)
        return str(caught.exception)

    def pr_head(self) -> str:
        return self.origin.commit("pr", {"app/a.txt": "a-pr\n"}, "pull request work")


class DecideTests(Case):
    def test_clean_merge_of_main_routes_from_the_green_head(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        decision = self.decide({h1: "success"})
        self.assertEqual(decision.base, h1)
        self.assertIn(f"delta since green head {h1[:10]}: 1 files", decision.reason)
        # Only main's change is new since H1; the pull request's file passed there.
        self.assertEqual(git(self.work, "diff", "--name-only", h1, "HEAD"), "web/w.txt")

    def test_merge_plus_one_resolution_commit(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        self.origin.commit("pr", {"docs/d.txt": "resolved\n"}, "resolve")
        decision = self.decide({h1: "success"})
        self.assertEqual(decision.base, h1)
        self.assertEqual(set(git(self.work, "diff", "--name-only", h1, "HEAD").split()),
                         {"web/w.txt", "docs/d.txt"})

    def test_normal_new_commit_does_not_apply(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("pr", {"app/a.txt": "a-pr-2\n"}, "more work")
        self.assertIn("new commit, not a merge of main", self.skip_reason({h1: "success"}))
        self.assertEqual(self.queried, [], "a plain push needs no API call")

    def test_new_commit_on_a_green_merge_does_not_apply(self) -> None:
        self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        merged = self.origin.merge_main_into_pr()
        self.origin.commit("pr", {"app/a.txt": "a-pr-2\n"}, "more work")
        self.assertIn(f"new commit on green {merged[:10]}", self.skip_reason({merged: "success"}))

    def test_red_green_head_does_not_apply(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        self.assertIn(f"{h1[:10]}, was not green (failure)", self.skip_reason({h1: "failure"}))

    def test_missing_verdict_does_not_apply(self) -> None:
        self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        self.assertIn("has no CI verdict and is not a merge", self.skip_reason({}))

    def test_two_merges_in_one_push_route_from_the_green_head(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        self.origin.commit("main", {"docs/d.txt": "d1\n"})
        self.origin.merge_main_into_pr()
        decision = self.decide({h1: "success"})
        self.assertEqual(decision.base, h1)
        self.assertIn(": 2 files", decision.reason)

    def test_second_merge_routes_from_the_first_when_it_was_green(self) -> None:
        self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        first = self.origin.merge_main_into_pr()
        self.origin.commit("main", {"docs/d.txt": "d1\n"})
        self.origin.merge_main_into_pr()
        decision = self.decide({first: "success"})
        self.assertEqual(decision.base, first)
        self.assertIn(": 1 files", decision.reason)

    def test_force_push_whose_first_parent_is_not_the_old_head(self) -> None:
        h1 = self.pr_head()
        self.origin.force_pr(git(self.origin.path, "rev-parse", "main"))
        self.origin.commit("pr", {"app/a.txt": "a-rewritten\n"}, "rewritten work")
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        self.assertIn("has no CI verdict and is not a merge", self.skip_reason({h1: "success"}))

    def test_merge_of_another_branch_does_not_apply(self) -> None:
        h1 = self.pr_head()
        git(self.origin.path, "checkout", "-q", "-b", "side", "main")
        self.origin.commit("side", {"web/w.txt": "side\n"})
        self.origin.merge_branch_into_pr("side")
        self.assertIn("which is not on main", self.skip_reason({h1: "success"}))

    def test_merge_that_keeps_the_head_side_of_a_main_only_file_does_not_apply(self) -> None:
        # The pull request never touched web/w.txt, but its merge kept the old
        # content over main's. That content was never tested against main.
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n", "docs/d.txt": "d1\n"})
        self.origin.merge_main_into_pr(keep_ours=("web/w.txt",))
        self.assertIn("1 files the pull request changes were not in its diff", self.skip_reason({h1: "success"}))

    def test_head_that_is_not_the_tested_merge_parent_does_not_apply(self) -> None:
        self.pr_head()
        merge, _ = self.origin.tested_merge()
        work = self.origin.checkout(merge)
        with self.assertRaises(delta.Skip):
            delta.decide(delta.Git(work), merge, "0" * 40, lambda oids: {})


class VerdictTests(unittest.TestCase):
    @staticmethod
    def suite(conclusion: str | None, started: str, event: str = "pull_request", workflow: str = "CI") -> dict:
        return {"workflowRun": {"event": event, "workflow": {"name": workflow}},
                "checkRuns": {"nodes": [{"conclusion": conclusion, "startedAt": started}]}}

    def test_latest_conclusive_run_wins(self) -> None:
        self.assertEqual(delta.verdict_from_suites([
            self.suite("SUCCESS", "2026-09-25T01:00:00Z"),
            self.suite("FAILURE", "2026-09-25T02:00:00Z"),
        ]), "failure")
        self.assertEqual(delta.verdict_from_suites([
            self.suite("FAILURE", "2026-09-25T01:00:00Z"),
            self.suite("SUCCESS", "2026-09-25T02:00:00Z"),
        ]), "success")

    def test_cancelled_and_in_progress_runs_say_nothing(self) -> None:
        self.assertEqual(delta.verdict_from_suites([
            self.suite("SUCCESS", "2026-09-25T01:00:00Z"),
            self.suite("CANCELLED", "2026-09-25T02:00:00Z"),
            self.suite(None, "2026-09-25T03:00:00Z"),
        ]), "success")
        self.assertIsNone(delta.verdict_from_suites([self.suite("CANCELLED", "2026-09-25T02:00:00Z")]))

    def test_only_pull_request_runs_of_the_ci_workflow_count(self) -> None:
        self.assertIsNone(delta.verdict_from_suites([
            self.suite("SUCCESS", "2026-09-25T01:00:00Z", event="workflow_dispatch"),
            self.suite("SUCCESS", "2026-09-25T01:00:00Z", workflow="CI status fallback"),
            {"workflowRun": None, "checkRuns": {"nodes": [{"conclusion": "SUCCESS", "startedAt": "x"}]}},
        ]))


class MainTests(unittest.TestCase):
    def test_fails_open_with_an_empty_base(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            env = {key: value for key, value in os.environ.items() if key not in {"GH_TOKEN", "GITHUB_TOKEN"}}
            result = subprocess.run(
                [sys.executable, str(HELPER), "--repository", "o/r", "--merge-sha", "1" * 40,
                 "--head-sha", "2" * 40, "--github-output", str(output), "--summary", str(summary)],
                cwd=directory, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "base_sha=\n")
            self.assertIn("pull request diff:", summary.read_text())


class WorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.job = yaml.safe_load(CI_WORKFLOW.read_text())["jobs"]["changes"]
        self.steps = {step.get("id"): step for step in self.job["steps"]}

    def test_changes_job_can_read_check_runs(self) -> None:
        self.assertEqual(self.job["permissions"].get("checks"), "read")

    def test_delta_step_is_pull_request_only_fail_open_and_switchable(self) -> None:
        step = self.steps["delta"]
        self.assertIn("github.event_name == 'pull_request'", step["if"])
        self.assertIn("vars.CI_DELTA_SINCE_GREEN != '0'", step["if"])
        self.assertIs(step["continue-on-error"], True)
        # The base revision's copy, like the trusted router.
        self.assertIn("git show HEAD^1:scripts/ci/delta_since_green.py", step["run"])
        names = [step.get("id") for step in self.job["steps"]]
        self.assertLess(names.index("delta"), names.index("detect"))

    def test_detector_diffs_from_the_green_head_only_when_one_was_found(self) -> None:
        detect = self.steps["detect"]
        self.assertEqual(detect["env"]["DELTA_BASE_SHA"], "${{ steps.delta.outputs.base_sha }}")
        run = detect["run"]
        override = run.index('BASE_SHA="$DELTA_BASE_SHA"')
        self.assertLess(run.index('BASE_SHA="$(git rev-parse "$MERGE_SHA^1")"'), override)
        self.assertLess(override, run.index("> /tmp/cmux-ci-changed-files.txt"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
