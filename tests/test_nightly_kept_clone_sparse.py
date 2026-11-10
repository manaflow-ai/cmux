#!/usr/bin/env python3
"""A kept nightly clone's sparse-checkout mode never hides files from the next job.

On an owned Mac the workspace clone stays between jobs, and git keeps the last checkout's sparse
mode in it. On 2026-11-10 the one nightly Mac ran, in this order:

1. a signing job: actions/checkout with patterns (`sparse-checkout-cone-mode: false`), which sets
   `core.sparseCheckout=true` and no cone setting;
2. generate-nightly-deltas: actions/checkout with `sparse-checkout: scripts` in cone mode, which runs
   `git sparse-checkout set scripts`. With sparse checkout already on and no cone setting, git reads
   that as the one pattern `scripts`: the root .xcode-version was not checked out and Select Xcode
   failed (runs 42819750253, 42829570644);
3. build-nightly-app: its warm checkout inherited the clone, `git status` was clean, and Select
   Xcode failed again (runs 42822119868, 42833135477).

This runs the workflow's own step scripts against a small repository put through the same order.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
JOBS = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
FORGET = "Forget the kept clone's sparse-checkout mode"
SPARSE_CHECKOUT = "Checkout build ref"
WARM = "Checkout build ref (warm nightly-next builder)"


def step(job: str, name: str) -> dict:
    return next(s for s in JOBS[job]["steps"] if s.get("name") == name)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, text=True, capture_output=True).stdout


class KeptClone(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        git(self.origin, "init", "-q", "-b", "main")
        (self.origin / "scripts/ci").mkdir(parents=True)
        (self.origin / "Sources").mkdir()
        (self.origin / ".xcode-version").write_text("26\n")
        (self.origin / "scripts/ci/git_fetch_retry.py").write_text(
            "import subprocess, sys\nsys.exit(subprocess.call(sys.argv[sys.argv.index('--') + 1:]))\n")
        (self.origin / "Sources/main.swift").write_text("print(1)\n")
        git(self.origin, "add", "-A")
        git(self.origin, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "one")
        self.sha = git(self.origin, "rev-parse", "HEAD").strip()
        self.clone = self.tmp / "workspace"
        git(self.tmp, "clone", "-q", str(self.origin), str(self.clone))

    def files(self) -> set[str]:
        return {p.name for p in self.clone.iterdir()} - {".git"}

    def signing_checkout(self) -> None:
        """actions/checkout with patterns: core.sparseCheckout=true and lines added to the pattern file."""
        git(self.clone, "config", "core.sparseCheckout", "true")
        with open(self.clone / ".git/info/sparse-checkout", "a") as handle:
            handle.write("\n/*\n!/Sources/\n")
        git(self.clone, "checkout", "-q", "--force", self.sha)

    def cone_checkout(self) -> None:
        """actions/checkout in cone mode with the paths the workflow step asks for."""
        with_ = step("generate-nightly-deltas", SPARSE_CHECKOUT)["with"]
        self.assertNotEqual(with_.get("sparse-checkout-cone-mode"), False, "this checkout is the cone one")
        git(self.clone, "sparse-checkout", "set", *with_["sparse-checkout"].split())
        git(self.clone, "checkout", "-q", "--force", self.sha)

    def run_step(self, job: str, name: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        runner_temp = self.tmp / "runner-temp"
        runner_temp.mkdir(exist_ok=True)
        return subprocess.run(
            ["bash", "-e", "-c", step(job, name)["run"]], cwd=self.clone, text=True, capture_output=True,
            env={**os.environ, "GITHUB_WORKSPACE": str(self.clone), "RUNNER_TEMP": str(runner_temp),
                 "GITHUB_REPOSITORY": "example/example", **(env or {})})

    def test_the_deltas_jobs_forget_the_mode_before_their_cone_checkout(self) -> None:
        for job in ("generate-nightly-deltas", "republish-nightly-deltas"):
            names = [s.get("name") for s in JOBS[job]["steps"]]
            self.assertIn(FORGET, names, job)
            self.assertLess(names.index(FORGET), names.index(SPARSE_CHECKOUT), job)

    def test_a_cone_checkout_after_a_signing_job_keeps_the_root_files(self) -> None:
        self.signing_checkout()
        done = self.run_step("generate-nightly-deltas", FORGET)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.cone_checkout()
        self.assertEqual(self.files(), {".xcode-version", "scripts"})

    def test_the_forget_step_passes_on_a_workspace_with_no_clone(self) -> None:
        empty = self.tmp / "empty"
        empty.mkdir()
        done = subprocess.run(["bash", "-e", "-c", step("generate-nightly-deltas", FORGET)["run"]], cwd=empty,
                              text=True, capture_output=True, env={**os.environ, "GITHUB_WORKSPACE": str(empty)})
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_the_warm_build_checkout_has_every_file_after_a_sparse_job(self) -> None:
        # The clone as the 2026-11-10 runs left it: patterns on, then `scripts` read as one pattern.
        self.signing_checkout()
        git(self.clone, "sparse-checkout", "set", "scripts")
        git(self.clone, "checkout", "-q", "--force", self.sha)
        self.assertEqual(self.files(), {"scripts"}, "the test no longer reproduces the kept clone")
        done = self.run_step("build-nightly-app", WARM, {
            "BUILD_SHA": self.sha, "WORKFLOW_SHA": self.sha, "REPO_URL": str(self.origin)})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.files(), {".xcode-version", "scripts", "Sources"})
        self.assertEqual(git(self.clone, "ls-files", "-t").count("\nS "), 0)


if __name__ == "__main__":
    unittest.main()
