#!/usr/bin/env python3
"""A clean base merge carries a pull request's Mac tiers from its older head, as merge_hold carries their checks.

merge_hold lands a base merge M of a head H whose checks passed on its merged-tree checks alone, yet cmux-next.yml
ran every Mac tier again at M (2026-11-16 05:44Z: 18 of 60 open cmux-next PR runs on base-merge heads, glaeda-std
134 queued, glaeda-side-std 126). scripts/ci/cmux_next_base_merge_carry.py turns those tiers off at M when M is
git's clean merge of a feat-cmux-next commit into H and H's cmux-next run passed (docs/ci/cmux-next-workflow-notes.md
note-388).
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_base_merge_carry as carry  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
REPO = "manaflow-ai/cmux"
BASE_REF = "feat-cmux-next"
H, B, X, M = "a" * 40, "b" * 40, "c" * 40, "d" * 40


class FakeApi:
    """compare (B in the base, the merge base) and H's cmux-next runs."""

    def __init__(self, in_base: set[str] = frozenset({B}), runs: list[dict] | None = None, fail: bool = False):
        self.in_base, self.fail, self.calls = set(in_base), fail, []
        self.runs = runs if runs is not None else [
            {"id": 7, "head_sha": H, "status": "completed", "conclusion": "success"}]

    def get(self, path: str):
        self.calls.append(path)
        if self.fail:
            raise RuntimeError(f"GET {path}: HTTP 502")
        if path.startswith(f"repos/{REPO}/compare/"):
            one, two = path.split("/compare/", 1)[1].split("?")[0].split("...")
            if two == BASE_REF:
                return {"status": "ahead" if one in self.in_base else "diverged"}
            return {"status": "diverged", "merge_base_commit": {"sha": X}}
        if path.startswith(f"repos/{REPO}/actions/workflows/cmux-next.yml/runs?head_sha="):
            sha = path.split("head_sha=", 1)[1].split("&")[0]
            return {"workflow_runs": [run for run in self.runs if run["head_sha"] == sha]}
        raise AssertionError(f"unexpected read {path}")


def fake_git(parents: list[str]):
    def git(*args: str, cwd: str | None = None) -> str:
        assert args[:2] == ("cat-file", "commit"), args
        lines = ["tree " + "e" * 40, *(f"parent {p}" for p in parents), "author a <a> 0 +0000", "", "Merge"]
        return "\n".join(lines)
    return git


def tree_check(result: bool, seen: list | None = None):
    def check(repo, older, base, ancestor, head, git=None):
        if seen is not None:
            seen.append((older, base, ancestor, head))
        return result
    return check


class Decide(unittest.TestCase):
    def decide(self, api=None, parents=(H, B), labels="", clean=True, seen=None):
        return carry.decide(api or FakeApi(), REPO, M, BASE_REF, labels, git=fake_git(list(parents)),
                            tree_check=tree_check(clean, seen))

    def test_clean_base_merge_of_a_passing_head_carries(self):
        seen: list = []
        older, run_id, why = self.decide(seen=seen)
        self.assertEqual((older, run_id), (H, 7), why)
        self.assertEqual(seen, [(H, B, X, M)])

    def test_merge_with_the_base_as_first_parent_carries_too(self):
        older, run_id, why = self.decide(parents=(B, H))
        self.assertEqual((older, run_id), (H, 7), why)

    def test_older_head_without_a_passing_run_runs_the_tiers(self):
        for runs in ([], [{"id": 8, "head_sha": H, "status": "completed", "conclusion": "cancelled"}],
                     [{"id": 9, "head_sha": H, "status": "in_progress", "conclusion": None}],
                     [{"id": 10, "head_sha": H, "status": "completed", "conclusion": "failure"}]):
            with self.subTest(runs=runs):
                older, _, why = self.decide(api=FakeApi(runs=runs))
                self.assertEqual(older, "", why)
                self.assertIn("no passing", why)

    def test_a_merge_that_is_not_gits_clean_merge_runs_the_tiers(self):
        older, _, why = self.decide(clean=False)
        self.assertEqual(older, "")
        self.assertIn("not git's clean merge", why)

    def test_full_ci_runs_every_tier(self):
        older, _, why = self.decide(labels="dev-build, full-ci")
        self.assertEqual(older, "")
        self.assertIn("full-ci", why)

    def test_a_plain_commit_runs_the_tiers(self):
        older, _, why = self.decide(parents=(H,))
        self.assertEqual(older, "")
        self.assertIn("not a merge commit", why)

    def test_a_merge_of_a_branch_outside_the_base_runs_the_tiers(self):
        older, _, why = self.decide(api=FakeApi(in_base=set()))
        self.assertEqual(older, "")
        self.assertIn(f"in {BASE_REF}", why)

    def test_github_unreadable_is_no_carry(self):
        older, _, why = self.decide(api=FakeApi(fail=True))
        self.assertEqual(older, "")
        self.assertIn("could not be read", why)


class Main(unittest.TestCase):
    def test_carry_appends_every_mac_tier_off_after_the_router(self):
        with tempfile.TemporaryDirectory() as scratch:
            out, summary = Path(scratch, "out"), Path(scratch, "summary")
            out.write_text("fast_tier=true\ngenerated=true\nnative=true\n")
            original = carry.decide
            carry.decide = lambda *a, **k: (H, 7, "a clean merge")
            try:
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(carry.main(["--repo", REPO, "--head", M, "--base-ref", BASE_REF,
                                                 "--github-output", str(out), "--summary", str(summary)]), 0)
            finally:
                carry.decide = original
            values: dict[str, str] = {}
            for line in out.read_text().splitlines():  # GitHub keeps an output's last value
                key, _, value = line.partition("=")
                values[key] = value
            for tier in carry.CARRIED_TIERS:
                self.assertEqual(values[tier], "false", tier)
            self.assertEqual(values["native"], "true")
            self.assertEqual(values["base_merge_carry"], H)
            self.assertIn("run 7 passed", summary.read_text())

    def test_a_crash_is_no_carry_and_exit_zero(self):
        with tempfile.TemporaryDirectory() as scratch:
            out = Path(scratch, "out")
            original = carry.decide
            carry.decide = lambda *a, **k: (_ for _ in ()).throw(ValueError("boom"))
            try:
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(carry.main(["--repo", REPO, "--head", M, "--base-ref", BASE_REF,
                                                 "--github-output", str(out)]), 0)
            finally:
                carry.decide = original
            self.assertFalse(out.exists())


def git_version() -> tuple[int, ...]:
    try:
        text = subprocess.run(["git", "version"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return ()
    return tuple(int(part) for part in text.split()[2].split(".")[:2] if part.isdigit())


@unittest.skipUnless(git_version() >= (2, 40), "git merge-tree --merge-base needs git 2.40")
class CleanMergeTree(unittest.TestCase):
    """clean_merge_tree against a real upstream over file://, as the route step fetches from GitHub."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="carry-test-")
        self.up = os.path.join(self.dir, "up")
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_NOSYSTEM": "1"}
        self.env = env

        def git(*args):
            return subprocess.run(["git", "-C", self.up, *args], check=True, capture_output=True, text=True,
                                  env=env).stdout.strip()

        def write(name, text):
            Path(self.up, name).write_text(text)

        subprocess.run(["git", "init", "-q", "-b", "base", self.up], check=True, env=env)
        git("config", "uploadpack.allowFilter", "true")
        git("config", "uploadpack.allowAnySHA1InWant", "true")
        write("f", "a\nb\nc\nd\ne\nf\ng\n")
        write("g", "x\n")
        git("add", ".")
        git("commit", "-qm", "base")
        self.x = git("rev-parse", "HEAD")
        git("checkout", "-qb", "pr")
        write("f", "A\nb\nc\nd\ne\nf\ng\n")
        git("commit", "-qam", "pr")
        self.h = git("rev-parse", "HEAD")
        git("checkout", "-q", "base")
        write("f", "a\nb\nc\nd\ne\nf\nG\n")
        write("g", "y\n")
        git("commit", "-qam", "base change in a file the PR changed too")
        self.b = git("rev-parse", "HEAD")
        git("checkout", "-q", "pr")
        git("merge", "-q", "--no-edit", "base")
        self.m = git("rev-parse", "HEAD")
        write("g", "slipped in\n")
        git("commit", "-q", "--amend", "-a", "--no-edit")
        self.dirty = git("rev-parse", "HEAD")
        self.git = git

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def check(self, head):
        def git(*args, cwd=None):
            return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                                  env=self.env, timeout=60).stdout.strip()
        return carry.clean_merge_tree(REPO, self.h, self.b, self.x, head, git=git, url=f"file://{self.up}")

    def test_gits_own_merge_is_clean(self):
        self.assertTrue(self.check(self.m))

    def test_a_change_slipped_into_the_merge_commit_is_not(self):
        self.assertFalse(self.check(self.dirty))

    def test_parents_read_from_the_merge_commit(self):
        def git(*args, cwd=None):
            return subprocess.run(["git", "-C", self.up, *args], check=True, capture_output=True, text=True,
                                  env=self.env).stdout.strip()
        self.assertEqual(carry.commit_parents(git, self.m), [self.h, self.b])


class Workflow(unittest.TestCase):
    """cmux-next.yml asks the carry after the router, and the carried outputs are the Mac tiers'."""

    @classmethod
    def setUpClass(cls):
        cls.doc = yaml.safe_load(WORKFLOW.read_text())
        cls.route_job = cls.doc["jobs"]["path_route"]
        cls.step = next(step for step in cls.route_job["steps"] if step.get("id") == "route")

    def test_route_step_asks_the_carry_after_the_router(self):
        run = self.step["run"]
        router = run.index("scripts/ci/cmux_next_route.py")
        asked = run.index("scripts/ci/cmux_next_base_merge_carry.py")
        self.assertLess(router, asked)
        self.assertIn('"$EVENT_NAME" == pull_request', run[run.rindex("if [[", 0, asked):asked])
        for name in ("PR_HEAD_SHA", "PR_BASE_REF", "SAME_REPO_PR", "BASE_MERGE_CARRY", "GH_TOKEN"):
            self.assertIn(name, self.step["env"])
        self.assertIn("github.event.pull_request.head.sha", self.step["env"]["PR_HEAD_SHA"])
        self.assertIn("CMUX_NEXT_BASE_MERGE_CARRY", self.step["env"]["BASE_MERGE_CARRY"])

    def test_carried_outputs_are_path_route_outputs_read_from_the_route_step(self):
        outputs = self.route_job["outputs"]
        for tier in carry.CARRIED_TIERS:
            self.assertIn(f"steps.route.outputs.{tier}", outputs[tier], tier)
        self.assertNotIn("native", carry.CARRIED_TIERS)  # cmux-next/compile is a merged-tree check
        self.assertNotIn("mac_release", carry.CARRIED_TIERS)

    def test_every_mac_tier_job_is_gated_on_a_carried_output(self):
        jobs = self.doc["jobs"]
        for job in ("fast-tier", "generated-files", "daemon-test", "swift-test", "swift-canary"):
            text = yaml.safe_dump(jobs[job])
            self.assertTrue(any(f"needs.path_route.outputs.{tier}" in text for tier in carry.CARRIED_TIERS), job)

    def test_new_files_start_the_workflow(self):
        paths = self.doc[True]["pull_request"]["paths"] if True in self.doc else self.doc["on"]["pull_request"]["paths"]
        self.assertIn("scripts/ci/cmux_next_base_merge_carry.py", paths)
        self.assertIn("tests/test_cmux_next_base_merge_carry.py", paths)


if __name__ == "__main__":
    unittest.main()
