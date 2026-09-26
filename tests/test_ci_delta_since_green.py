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

    def test_pull_request_that_changes_ci_policy_keeps_its_whole_diff(self) -> None:
        # At H1 the pull request edited the router. The delta would no longer
        # contain it, and the pull request's own router would judge the delta.
        for policy in ("scripts/ci/detect_ci_change_areas.py", ".github/workflows/ci.yml",
                       "tests/test_ci_change_areas.py", "scripts/ci/subprocess.py"):
            with self.subTest(policy):
                self.setUp()
                h1 = self.origin.commit("pr", {"app/a.txt": "a-pr\n", policy: "edited\n"})
                self.origin.commit("main", {"web/w.txt": "w1\n"})
                self.origin.merge_main_into_pr()
                self.assertIn("changes CI policy", self.skip_reason({h1: "success"}))
                self.assertEqual(self.queried, [], "no API call once the diff rules it out")

    def test_main_changing_ci_policy_still_takes_the_delta(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("main", {"scripts/ci/detect_ci_change_areas.py": "main edit\n"})
        self.origin.merge_main_into_pr()
        decision = self.decide({h1: "success"})
        self.assertEqual(decision.base, h1)
        # The delta carries main's router edit, so ci.yml still classifies it.
        self.assertEqual(git(self.work, "diff", "--name-only", h1, "HEAD"),
                         "scripts/ci/detect_ci_change_areas.py")

    def test_complete_history_is_not_deepened(self) -> None:
        # The chain fetch completes this short history; some git versions
        # (2.52 on the Linux runners) refuse --deepen on a complete repository.
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        self.origin.commit("main", {"docs/d.txt": "d1\n"})
        self.origin.merge_main_into_pr()
        fetched: list[tuple[str, ...]] = []
        original = delta.Git.fetch

        def record(git_self, object_filter, *args):
            fetched.append(args)
            return original(git_self, object_filter, *args)

        delta.Git.fetch = record
        self.addCleanup(setattr, delta.Git, "fetch", original)
        self.assertEqual(self.decide({h1: "success"}).base, h1)
        self.assertFalse([args for args in fetched if args[0].startswith("--deepen")], fetched)

    def test_a_refused_filter_falls_back_to_a_plain_fetch_and_says_so(self) -> None:
        h1 = self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        original = delta.Git.run

        def refuse_filters(git_self, *args):
            if args[0] == "fetch" and any(arg.startswith("--filter=") for arg in args):
                raise subprocess.CalledProcessError(128, ["git", *args], stderr="fatal: filter refused\n")
            return original(git_self, *args)

        delta.Git.run = refuse_filters
        self.addCleanup(setattr, delta.Git, "run", original)
        merge, head = self.origin.tested_merge()
        git_checkout = delta.Git(self.origin.checkout(merge))
        decision = delta.decide(git_checkout, merge, head, lambda oids: {oid: "success" for oid in oids if oid == h1})
        self.assertEqual(decision.base, h1)
        self.assertTrue(git_checkout.notes)
        self.assertIn("fatal: filter refused", git_checkout.notes[0])
        self.assertIn("retried without it", git_checkout.notes[0])

    def test_a_fetch_that_fails_both_ways_skips_with_git_stderr(self) -> None:
        self.pr_head()
        self.origin.commit("main", {"web/w.txt": "w1\n"})
        self.origin.merge_main_into_pr()
        original = delta.Git.run

        def refuse_fetch(git_self, *args):
            if args[0] == "fetch":
                raise subprocess.CalledProcessError(128, ["git", *args], stderr="fatal: remote hung up\n")
            return original(git_self, *args)

        delta.Git.run = refuse_fetch
        self.addCleanup(setattr, delta.Git, "run", original)
        self.assertIn("fatal: remote hung up", self.skip_reason({}))

    def test_head_that_is_not_the_tested_merge_parent_does_not_apply(self) -> None:
        self.pr_head()
        merge, _ = self.origin.tested_merge()
        work = self.origin.checkout(merge)
        with self.assertRaises(delta.Skip):
            delta.decide(delta.Git(work), merge, "0" * 40, lambda oids: {})


class VerdictTests(unittest.TestCase):
    @staticmethod
    def suite(conclusion: str | None, started: str, run_id: int = 1, event: str = "pull_request",
              path: str = ".github/workflows/ci.yml") -> dict:
        return {"workflowRun": {"databaseId": run_id, "event": event, "file": {"path": path}},
                "checkRuns": {"nodes": [{"conclusion": conclusion, "startedAt": started}]}}

    @staticmethod
    def pr_run(run_id: int, number: int = 7, base_ref: str = "main") -> dict:
        return {"id": run_id, "pull_requests": [{"number": number, "base": {"ref": base_ref}}]}

    def test_a_rerun_of_the_same_run_clears_a_flake(self) -> None:
        conclusions = delta.ci_status_runs([
            self.suite("FAILURE", "2026-09-25T01:00:00Z"),
            self.suite("SUCCESS", "2026-09-25T02:00:00Z"),
        ])
        self.assertEqual(conclusions, {1: "success"})

    def test_a_red_run_makes_the_commit_red_even_when_a_later_run_passed(self) -> None:
        conclusions = delta.ci_status_runs([
            self.suite("FAILURE", "2026-09-25T01:00:00Z", run_id=1),
            self.suite("SUCCESS", "2026-09-25T02:00:00Z", run_id=2),
        ])
        self.assertEqual(delta.verdict(conclusions, {1, 2}), "failure")
        self.assertEqual(delta.verdict(conclusions, {2}), "success")

    def test_cancelled_and_in_progress_runs_say_nothing(self) -> None:
        conclusions = delta.ci_status_runs([
            self.suite("SUCCESS", "2026-09-25T01:00:00Z", run_id=1),
            self.suite("CANCELLED", "2026-09-25T02:00:00Z", run_id=2),
            self.suite(None, "2026-09-25T03:00:00Z", run_id=3),
        ])
        self.assertEqual(conclusions, {1: "success"})

    def test_only_pull_request_runs_of_ci_yml_count_matched_by_file(self) -> None:
        self.assertEqual(delta.ci_status_runs([
            self.suite("SUCCESS", "2026-09-25T01:00:00Z", event="workflow_dispatch"),
            self.suite("SUCCESS", "2026-09-25T01:00:00Z", path=".github/workflows/ci-status-fallback.yml"),
            {"workflowRun": None, "checkRuns": {"nodes": [{"conclusion": "SUCCESS", "startedAt": "x"}]}},
        ]), {})

    def test_runs_of_another_pull_request_or_base_say_nothing(self) -> None:
        # A stacked pull request on another base ran CI on the same commit.
        runs = [self.pr_run(1), self.pr_run(2, number=8), self.pr_run(3, base_ref="feature"),
                {"id": 4, "pull_requests": []}]
        bound = delta.runs_for_pull_request(runs, 7, "main")
        self.assertEqual(bound, {1})
        self.assertIsNone(delta.verdict({2: "success", 3: "success", 4: "success"}, bound))
        self.assertEqual(delta.verdict({1: "success", 2: "failure"}, bound), "success")

    @classmethod
    def graphql(cls, retargets: object = 0) -> dict:
        repository = {"c0": {"checkSuites": {"nodes": [
            cls.suite("SUCCESS", "2026-09-25T01:00:00Z", run_id=11)]}}}
        if retargets is not None:
            # totalCount is the whole timeline whatever itemTypes says (seen live).
            repository["pullRequest"] = {"timelineItems": {
                "totalCount": 7, "filteredCount": retargets,
                "nodes": [{"__typename": "BaseRefChangedEvent"}] * retargets}}
        return {"data": {"repository": repository}}

    def lookup_with(self, graphql: dict, runs: list[dict], calls: list[str]):
        import io
        import json

        def fake_urlopen(request, timeout=0):
            calls.append(request.full_url)
            body = graphql if request.full_url.endswith("/graphql") else {"workflow_runs": runs}
            return io.BytesIO(json.dumps(body).encode())

        original = delta.urllib.request.urlopen
        delta.urllib.request.urlopen = fake_urlopen
        self.addCleanup(setattr, delta.urllib.request, "urlopen", original)
        return delta.github_verdicts("o/r", "t", "https://api.github.com/graphql", 7, "main")

    def test_a_retargeted_pull_request_keeps_its_whole_diff(self) -> None:
        # feature-x -> main: H1's old run now reports base main through the runs API.
        for retargets, reason in ((1, "changed its base branch"), (None, "could not read")):
            with self.subTest(retargets=retargets):
                calls: list[str] = []
                lookup = self.lookup_with(self.graphql(retargets), [self.pr_run(11)], calls)
                with self.assertRaises(delta.Skip) as caught:
                    lookup(["a" * 40])
                self.assertIn(reason, str(caught.exception))
                self.assertEqual(len(calls), 1, "no runs API call once the retarget rules it out")

    def test_lookup_binds_the_nearest_judged_commit_to_this_pull_request(self) -> None:
        oid = "a" * 40
        graphql = self.graphql()
        cases = {
            "this pull request": ([self.pr_run(11)], "success"),
            "another base": ([self.pr_run(11, base_ref="feature")], None),
            "a fork run": ([{"id": 11, "pull_requests": []}], None),
        }
        for label, (runs, expected) in cases.items():
            with self.subTest(label):
                calls = []

                def fake_urlopen(request, timeout=0, runs=runs):
                    calls.append(request.full_url)
                    body = graphql if request.full_url.endswith("/graphql") else {"workflow_runs": runs}
                    import io, json
                    return io.BytesIO(json.dumps(body).encode())

                original = delta.urllib.request.urlopen
                delta.urllib.request.urlopen = fake_urlopen
                try:
                    lookup = delta.github_verdicts("o/r", "t", "https://api.github.com/graphql", 7, "main")
                    self.assertEqual(lookup([oid]), {oid: expected})
                finally:
                    delta.urllib.request.urlopen = original
                self.assertIn(f"head_sha={oid}", calls[1])


class MainTests(unittest.TestCase):
    def test_fails_open_with_an_empty_base(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            env = {key: value for key, value in os.environ.items() if key not in {"GH_TOKEN", "GITHUB_TOKEN"}}
            result = subprocess.run(
                [sys.executable, str(HELPER), "--repository", "o/r", "--merge-sha", "1" * 40,
                 "--head-sha", "2" * 40, "--pull-request", "7", "--base-ref", "main",
                 "--github-output", str(output), "--summary", str(summary)],
                cwd=directory, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "base_sha=\n")
            self.assertIn("pull request diff:", summary.read_text())


def evaluate_condition(expression: str, context: dict[str, str]) -> bool:
    """Evaluate a GitHub Actions `if:` made of ==, !=, && and || over string contexts.

    Anything else in the expression is an error rather than a guess.
    """
    import re
    body = expression.strip()
    if body.startswith("${{") and body.endswith("}}"):
        body = body[3:-2]
    tokens = re.findall(r"'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*|==|!=|&&|\|\||\(|\)|\S", body)
    python = []
    for token in tokens:
        if token.startswith("'"):
            python.append(repr(token[1:-1]))
        elif token in ("==", "!=", "(", ")"):
            python.append(token)
        elif token == "&&":
            python.append("and")
        elif token == "||":
            python.append("or")
        elif re.fullmatch(r"(github|vars)\.[A-Za-z0-9_.-]+", token):
            python.append(repr(context.get(token, "")))
        else:
            raise AssertionError(f"unsupported token {token!r} in {expression!r}")
    return bool(eval(" ".join(python), {"__builtins__": {}}))


class WorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.job = yaml.safe_load(CI_WORKFLOW.read_text())["jobs"]["changes"]
        self.steps = {step.get("id"): step for step in self.job["steps"]}

    def test_changes_job_can_read_check_runs(self) -> None:
        self.assertEqual(self.job["permissions"].get("checks"), "read")

    def test_delta_step_runs_only_for_same_repository_pull_requests_with_the_switch_on(self) -> None:
        step = self.steps["delta"]
        same, fork = "manaflow-ai/cmux", "someone/cmux"
        cases = [
            # event, head repository, CI_DELTA_SINCE_GREEN (None: unset), runs
            ("pull_request", same, None, True),
            ("pull_request", same, "1", True),
            ("pull_request", same, "0", False),
            # Forks get no repository variables, so the switch cannot reach them.
            ("pull_request", fork, None, False),
            ("merge_group", same, None, False),
            ("workflow_dispatch", same, None, False),
        ]
        for event, head_repo, switch, expected in cases:
            context = {
                "github.event_name": event,
                "github.repository": same,
                "github.event.pull_request.head.repo.full_name": head_repo if event == "pull_request" else "",
                "vars.CI_DELTA_SINCE_GREEN": switch or "",
            }
            with self.subTest(event=event, head_repo=head_repo, switch=switch):
                self.assertIs(evaluate_condition(step["if"], context), expected)
        self.assertIs(step["continue-on-error"], True)
        self.assertIn('--pull-request "$PR_NUMBER" --base-ref "$BASE_REF"', step["run"])
        self.assertEqual(step["env"]["PR_NUMBER"], "${{ github.event.pull_request.number }}")
        self.assertEqual(step["env"]["BASE_REF"], "${{ github.event.pull_request.base.ref }}")
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
