#!/usr/bin/env python3
"""pr-checks.yml skips its advisory jobs only on a push that just merged the base.

A base-only update (the new head's parents are the old head and a commit on the
base branch, and the pull request's diff is unchanged) started about 6.5
advisory runs per head on 2026-10-26; the folded workflow starts one run whose
first job answers this. Anything else must answer false, so every check runs:
another event, a plain commit, a merge that also edits, a merge of a branch
that is not the base, or a head the branch has already moved past.

pr-capture-check can block a merge and a merger reads a missing verdict as a
pass, so it never waits on that answer.

The step runs here as the workflow runs it, against a local origin.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/pr-checks.yml").read_text())
JOBS = WORKFLOW["jobs"]
STEP = next(s for s in JOBS["base-only"]["steps"] if s.get("id") == "decide")
SKIPPED_ON_BASE_ONLY = ("link", "size", "split")
ANSWER = "needs.base-only.outputs.base_only != 'true'"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


class BaseOnlyStepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.src = src = root / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "feat-cmux-next")
        git(src, "config", "user.email", "t@example.com")
        git(src, "config", "user.name", "t")
        git(src, "config", "uploadpack.allowFilter", "true")
        write(src, "app/a.swift", "".join(f"let a{i} = {i}\n" for i in range(40)))
        write(src, "docs/base.md", "base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        git(src, "checkout", "-qb", "pr")
        write(src, "app/a.swift", "".join(f"let a{i} = {i * (2 if i == 5 else 1)}\n" for i in range(40)))
        write(src, "app/new.swift", "let n = 1\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "pr")
        self.before = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "feat-cmux-next")
        # The base moves under the pull request: a line far from its hunk, and a file of its own.
        write(src, "app/a.swift", "".join(f"let a{i} = {i * (3 if i == 30 else 1)}\n" for i in range(40)))
        write(src, "docs/base.md", "base moved\n")
        git(src, "commit", "-qam", "base moves on")
        self.base = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "pr")
        self.temp = root / "temp"
        self.temp.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def push(self, sha: str) -> str:
        git(self.src, "update-ref", "refs/pull/7/head", sha)
        return sha

    def merge_base(self, *extra: str) -> str:
        git(self.src, "merge", "-q", "--no-ff", "--no-commit", "feat-cmux-next")
        for path in extra:
            write(self.src, path, "edited in the merge\n")
            git(self.src, "add", path)
        git(self.src, "commit", "-qm", "Merge feat-cmux-next")
        return self.push(git(self.src, "rev-parse", "HEAD"))

    def decide(self, after: str, action: str = "synchronize", before: str | None = None) -> tuple[str, str]:
        output = self.temp / "github_output"
        output.write_text("")
        env = {**os.environ, "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(output),
               "GITHUB_STEP_SUMMARY": str(self.temp / "summary.md"), "ACTION": action,
               "BEFORE": self.before if before is None else before, "AFTER": after,
               "BASE_REF": "feat-cmux-next", "PR": "7", "REMOTE": f"file://{self.src}"}
        subprocess.run(["rm", "-rf", str(self.temp / "base-only")], check=True)
        result = subprocess.run(["bash", "-c", STEP["run"]], cwd=self.temp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        return outputs.get("base_only", ""), result.stdout

    def test_a_merge_of_the_base_is_base_only(self):
        answer, why = self.decide(self.merge_base())
        self.assertEqual(answer, "true", why)

    def test_a_merge_that_also_edits_runs_everything(self):
        answer, why = self.decide(self.merge_base("app/new.swift"))
        self.assertEqual(answer, "false", why)
        self.assertIn("own diff", why)

    def test_a_plain_commit_runs_everything(self):
        write(self.src, "app/new.swift", "let n = 2\n")
        git(self.src, "commit", "-qam", "more")
        answer, _ = self.decide(self.push(git(self.src, "rev-parse", "HEAD")))
        self.assertEqual(answer, "false")

    def test_a_merge_of_another_branch_runs_everything(self):
        git(self.src, "checkout", "-qb", "other", self.base)
        write(self.src, "docs/other.md", "other\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "other")
        git(self.src, "checkout", "-q", "pr")
        git(self.src, "merge", "-q", "--no-ff", "-m", "Merge other", "other")
        answer, why = self.decide(self.push(git(self.src, "rev-parse", "HEAD")))
        self.assertEqual(answer, "false")
        self.assertIn("not on feat-cmux-next", why)

    def test_other_events_and_a_new_branch_run_everything(self):
        after = self.merge_base()
        self.assertEqual(self.decide(after, action="opened")[0], "false")
        self.assertEqual(self.decide(after, before="0" * 40)[0], "false")
        # A merge onto some other previous head (a force push) is not a base-only update.
        self.assertEqual(self.decide(after, before=self.base)[0], "false")

    def test_a_head_the_branch_moved_past_runs_everything(self):
        after = self.merge_base()
        write(self.src, "app/new.swift", "let n = 3\n")
        git(self.src, "commit", "-qam", "newer")
        self.push(git(self.src, "rev-parse", "HEAD"))
        answer, why = self.decide(after)
        self.assertEqual(answer, "false")
        self.assertIn("moved past", why)

    def test_a_failed_fetch_runs_everything(self):
        output = self.temp / "github_output"
        output.write_text("")
        env = {**os.environ, "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(output),
               "GITHUB_STEP_SUMMARY": str(self.temp / "summary.md"), "ACTION": "synchronize",
               "BEFORE": self.before, "AFTER": "a" * 40, "BASE_REF": "feat-cmux-next", "PR": "7",
               "REMOTE": f"file://{self.temp}/missing"}
        result = subprocess.run(["bash", "-c", STEP["run"]], cwd=self.temp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("base_only=false", output.read_text())


class WorkflowShapeTests(unittest.TestCase):
    def test_the_answer_never_fails_the_run(self):
        self.assertTrue(STEP.get("continue-on-error"))
        self.assertEqual(JOBS["base-only"]["permissions"], {"contents": "read"})
        self.assertNotIn("GH_TOKEN", str(STEP.get("env")))

    def test_only_the_advisory_jobs_wait_on_it(self):
        for job_id in SKIPPED_ON_BASE_ONLY:
            with self.subTest(job=job_id):
                job = JOBS[job_id]
                self.assertEqual(job["needs"], "base-only")
                # A skipped or failed answer runs the job: no implicit success().
                self.assertTrue(str(job["if"]).startswith("${{ !cancelled() && " + ANSWER))
        self.assertNotIn("needs", JOBS["capture"])
        self.assertEqual(JOBS["capture"]["name"], "pr-capture-check")

    def test_check_names_are_unchanged(self):
        names = {job_id: job.get("name", job_id) for job_id, job in JOBS.items()}
        self.assertEqual(names["capture"], "pr-capture-check")
        self.assertEqual(names["link"], "link")
        self.assertEqual(names["size"], "PR size (advisory)")
        self.assertEqual(names["split"], "split-plan advisory")


if __name__ == "__main__":
    unittest.main()
