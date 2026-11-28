#!/usr/bin/env python3
"""A reused self-hosted Linux workspace left sparse or broken is removed before actions/checkout.

On 2026-11-20 the persistent runner pool (cmux-runner-pool-*) kept each job's checkout as a git cache. A job that
checked out sparse left `core.sparseCheckout`, patterns and skip-worktree bits behind; the next job's actions/checkout
then printed `Path '...' not uptodate; will not remove from working tree`, reported success, and left a tree with
files missing (rust workspaces run 44739498261: `.github/rust-workspaces.toml` not found; guards run 44733869883
tooling-tests: scripts/cmux-next/continue-nightly-next.sh not found). A stale `refs/remotes/pull/N/merge` naming a
missing object failed checkout outright (`fatal: bad object`, release-notary in the same run).

The runner hook (cmuxterm-hq skills/infra/linux-runner-pool/job-clean.sh) is the first line; this step is the second,
in the workflow, so a VM that still runs an older hook cannot hand a job a broken tree. It runs before checkout, so
it is inline shell: the repository's scripts are not there yet.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import importlib.util as _git_fixture_importlib
import yaml

ROOT = Path(__file__).resolve().parents[1]
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
STEP_NAME = "Remove a reused workspace left sparse or broken (self-hosted Linux)"
WORKFLOWS = (
    ROOT / ".github/workflows/rust-workspaces.yml",
    ROOT / ".github/workflows/cmux-next-guards.yml",
    # cloud-vm-image-roll.yml's bake job calls this one: rolls 44741017720, 44748040694 and 44750854346 failed on
    # "not uptodate; will not remove" and then "Module not found ../images/cmux-vm/pin-cmux-tui.ts" (2026-11-20).
    ROOT / ".github/workflows/cloud-vm-image-bake.yml",
    ROOT / ".github/workflows/cloud-vm-image-roll.yml",
    ROOT / ".github/workflows/cmux-next-tooling-tests-batch.yml",
)
CHECKOUT = re.compile(r"^actions/checkout@")
POOL = re.compile(r"RUNNER_POOLS|LINUX_RUNNER|linux_runner|mini_runner")


def jobs(path: Path) -> dict:
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]


def step_script() -> str:
    for path in WORKFLOWS:
        for job in jobs(path).values():
            for step in job.get("steps", []):
                if step.get("name") == STEP_NAME:
                    return step["run"]
    raise AssertionError(f"no step named {STEP_NAME!r}")


def git(cwd: Path, *args: str) -> str:
    env = git_fixture_env.fixture_env({**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


class Fixture:
    def __init__(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="reused-sparse-"))
        self.ws = self.tmp / "work" / "cmux" / "cmux"
        self.ws.mkdir(parents=True)
        git_fixture_env.init_repo(self.ws, "-b", "main", env=git_fixture_env.fixture_env())
        for rel in ("a/x", "b/y", ".github/rust-workspaces.toml"):
            (self.ws / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.ws / rel).write_text(rel + "\n")
        git(self.ws, "add", "-A")
        git(self.ws, "commit", "-qm", "A")

    def run_step(self, environment: str = "self-hosted") -> subprocess.CompletedProcess:
        env = git_fixture_env.fixture_env({**os.environ, "HOME": str(self.tmp), "GITHUB_WORKSPACE": str(self.ws),
                                           "RUNNER_ENVIRONMENT": environment})
        # `shell: bash` is `bash --noprofile --norc -eo pipefail {0}`: run the step the way the runner does, so a pipe
        # whose reader exits early (`ls-files -v | grep -q`) fails here as it fails there.
        return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step_script()], env=env,
                              capture_output=True, text=True)

    def entries(self) -> list[str]:
        return sorted(p.name for p in self.ws.iterdir())

    def close(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


class StepBehavior(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = Fixture()
        self.addCleanup(self.fx.close)

    def assert_removed(self) -> None:
        result = self.fx.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fx.entries(), [], result.stdout)
        self.assertTrue(self.fx.ws.is_dir(), "the workspace directory itself stays (the runner owns it)")

    def test_a_sparse_checkout_is_removed(self) -> None:
        git(self.fx.ws, "sparse-checkout", "set", "--cone", "a")
        self.assert_removed()

    def test_skip_worktree_bits_alone_are_removed(self) -> None:
        git(self.fx.ws, "update-index", "--skip-worktree", "b/y")
        self.assert_removed()

    def test_a_ref_to_a_missing_object_is_removed(self) -> None:
        (self.fx.ws / ".git/refs/remotes/pull/46338").mkdir(parents=True)
        (self.fx.ws / ".git/refs/remotes/pull/46338/merge").write_text("1" * 40 + "\n")
        self.assert_removed()

    def test_an_early_skip_worktree_bit_in_a_large_index_is_removed(self) -> None:
        # A real checkout's `ls-files -v` is megabytes. `| grep -q '^S'` under pipefail exited at an early match, git
        # died writing the rest, and the pipeline read "no skip-worktree entries": the broken tree stayed.
        big = self.fx.ws / "z"
        big.mkdir()
        for i in range(6000):
            (big / f"file-{i:05d}-with-a-long-enough-name.txt").write_text("x\n")
        git(self.fx.ws, "add", "-A")
        git(self.fx.ws, "commit", "-qm", "B")
        git(self.fx.ws, "update-index", "--skip-worktree", ".github/rust-workspaces.toml")
        self.assert_removed()

    def test_an_early_missing_ref_among_many_is_removed(self) -> None:
        head = git(self.fx.ws, "rev-parse", "HEAD").strip()
        lines = ["0" * 40 + " refs/remotes/pull/00001/merge\n"]
        lines += [f"{head} refs/remotes/pull/{i:05d}/head\n" for i in range(2, 4000)]
        (self.fx.ws / ".git/packed-refs").write_text("".join(lines))
        self.assert_removed()

    def test_an_unresolved_head_is_removed(self) -> None:
        (self.fx.ws / ".git/HEAD").write_text("2" * 40 + "\n")
        self.assert_removed()

    def test_a_healthy_checkout_stays_as_a_cache(self) -> None:
        (self.fx.ws / "untracked").write_text("left by the last job\n")
        result = self.fx.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(".git", self.fx.entries())
        self.assertIn("untracked", self.fx.entries(), "actions/checkout's own clean handles untracked files")

    def test_no_checkout_yet_is_a_no_op(self) -> None:
        shutil.rmtree(self.fx.ws / ".git")
        result = self.fx.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_hosted_runner_is_never_touched(self) -> None:
        git(self.fx.ws, "sparse-checkout", "set", "--cone", "a")
        result = self.fx.run_step(environment="github-hosted")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(".git", self.fx.entries())


class Wiring(unittest.TestCase):
    def test_every_pool_job_runs_the_step_before_its_first_checkout(self) -> None:
        missing = []
        for path in WORKFLOWS:
            for name, job in jobs(path).items():
                steps = job.get("steps") or []
                checkouts = [i for i, s in enumerate(steps) if CHECKOUT.match(s.get("uses", ""))]
                if not checkouts or not POOL.search(job.get("runs-on", "")):
                    continue
                before = [s.get("name") for s in steps[: checkouts[0]]]
                if STEP_NAME not in before:
                    missing.append(f"{path.name}:{name}")
        self.assertEqual(missing, [])

    def test_the_step_runs_in_the_workspace_root(self) -> None:
        # It runs before checkout, so a job's `defaults.run.working-directory` (web/ in cloud-vm-image-bake.yml) does
        # not exist yet: the runner then fails the step at start ("trying to start process '/usr/bin/bash' with
        # working directory '.../web'. No such file or directory", roll 44760854970, 2026-11-20).
        wrong = []
        for path in WORKFLOWS:
            for name, job in jobs(path).items():
                for step in job.get("steps") or []:
                    if step.get("name") == STEP_NAME and step.get("working-directory") != "${{ github.workspace }}":
                        wrong.append(f"{path.name}:{name}")
        self.assertEqual(wrong, [])

    def test_the_step_is_one_text_everywhere(self) -> None:
        texts = {step["run"] for path in WORKFLOWS for job in jobs(path).values()
                 for step in job.get("steps", []) if step.get("name") == STEP_NAME}
        self.assertEqual(len(texts), 1, "every copy of the step must be identical")


if __name__ == "__main__":
    sys.exit(unittest.main())
