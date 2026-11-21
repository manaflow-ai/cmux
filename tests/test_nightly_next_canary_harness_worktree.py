"""The nightly-next canary's harness checkout survives an earlier job's worktree on the same runner.

The owned Macs keep the repository checkout between jobs but empty RUNNER_TEMP, so the
`git worktree add "$RUNNER_TEMP/build-src"` of an earlier job stayed registered with its folder gone,
and the next canary on that runner failed: "fatal: '.../_temp/build-src' is a missing but already
registered worktree" (run 44020590372, 2026-11-17). These tests run the workflow's own step scripts
against a repository in that state.
"""

import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly-next-canary.yml"


def step(text: str, name: str) -> str:
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - name: |^  \S|\Z)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no step {name!r}")
    return match.group(1)


def run_script(body: str) -> str:
    match = re.search(r"^        run: \|\n((?:          .*\n|\n)+)", body, re.M)
    if not match:
        raise AssertionError("step has no run block")
    return textwrap.dedent(match.group(1))


def git(cwd: pathlib.Path, *args: str) -> str:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main", *args],
        cwd=cwd, check=True, capture_output=True, text=True, env=env,
    ).stdout.strip()


class HarnessWorktreeOnAKeptCheckout(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        origin = self.tmp / "origin"
        origin.mkdir()
        git(origin, "init", "-q")
        (origin / "README").write_text("harness\n")
        git(origin, "add", "README")
        git(origin, "commit", "-q", "-m", "build")
        self.sha = git(origin, "rev-parse", "HEAD")
        git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.repo = self.tmp / "work"
        git(self.tmp, "clone", "-q", str(origin), str(self.repo))
        self.runner_temp = self.tmp / "_temp"
        self.runner_temp.mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(f"#!/bin/sh\necho {self.sha}\n")
        gh.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.tmp / "output"),
            "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            "SHORT": self.sha[:7],
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        }

    def run_step(self, name: str) -> subprocess.CompletedProcess:
        script = run_script(step(self.text, name))
        return subprocess.run(["bash", "-e", "-c", script], cwd=self.repo, env=self.env, capture_output=True, text=True)

    def leave_an_earlier_jobs_worktree(self) -> None:
        git(self.repo, "worktree", "add", "-q", "--detach", str(self.runner_temp / "build-src"), self.sha)
        shutil.rmtree(self.runner_temp)  # the runner empties RUNNER_TEMP between jobs
        self.runner_temp.mkdir()

    def test_checkout_succeeds_when_an_earlier_jobs_worktree_is_still_registered(self) -> None:
        self.leave_an_earlier_jobs_worktree()
        result = self.run_step("Check out the build's harness")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.runner_temp / "build-src", "rev-parse", "HEAD"), self.sha)

    def test_checkout_succeeds_on_a_clean_runner(self) -> None:
        result = self.run_step("Check out the build's harness")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.runner_temp / "build-src", "rev-parse", "HEAD"), self.sha)

    def test_the_job_unregisters_its_worktree_whatever_the_canary_did(self) -> None:
        canary = self.text.split("  # The durable verdict", 1)[0]
        body = step(canary, "Remove the harness worktree")
        self.assertIn("if: always() && steps.harness.outcome != 'skipped'", body)
        self.assertEqual(self.run_step("Check out the build's harness").returncode, 0)
        result = self.run_step("Remove the harness worktree")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(str(self.runner_temp / "build-src"), git(self.repo, "worktree", "list"))
        self.assertFalse((self.runner_temp / "build-src").exists())


if __name__ == "__main__":
    unittest.main()
