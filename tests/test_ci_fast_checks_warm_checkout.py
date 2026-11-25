#!/usr/bin/env python3
"""fast-checks.yml's sanitize step leaves the warm checkout a Git repository actions/checkout keeps.

2026-11-25, run 45685122297 (cmux#56859's `cmux-ci test`): the sanitize step removed `.git/refs`, so
Git no longer took `.git` for a repository. actions/checkout's first probe, `git config --local --get
remote.origin.url`, printed `##[error]fatal: --local can only be used inside a git repository`, and
checkout then deleted the whole sticky-disk checkout and cloned again. Every run lost the warm object
store, and a red run showed a git error the test never caused. With `clean: true`, checkout's `git reset
--hard HEAD` on the sanitized (unborn) HEAD would fail the same way. So the step now rebuilds an empty
refs tree and a fixed HEAD, empties the work tree itself, and checkout runs with `clean: false`.

This runs the step's own script against a used checkout and then the probes checkout makes.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "fast-checks.yml"
STEP = "Sanitize persistent checkout metadata"
CHECKOUT_PATH = ".fast-checks-checkout"


def checks_steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["checks"]["steps"]


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=check)


class WarmCheckoutTests(unittest.TestCase):
    def sanitize(self, workspace: Path) -> None:
        step = next(s for s in checks_steps() if s.get("name") == STEP)
        done = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=workspace, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_used_checkout_stays_a_repository_checkout_keeps(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            origin = workspace / "origin"
            origin.mkdir()
            git(origin, "init", "-q", "-b", "main")
            (origin / "a.txt").write_text("a\n")
            git(origin, "add", "a.txt")
            git(origin, "commit", "-q", "-m", "a")
            sha = git(origin, "rev-parse", "HEAD").stdout.strip()
            # The sticky disk as a prior run left it: a checkout, a hook, a stray file, a branch.
            warm = workspace / CHECKOUT_PATH
            git(workspace, "clone", "-q", str(origin), str(warm))
            (warm / ".git" / "hooks" / "post-checkout").write_text("#!/bin/sh\nexit 1\n")
            (warm / "left-by-a-prior-command").write_text("x\n")
            git(warm, "branch", "planted")
            objects_before = sorted(p.name for p in (warm / ".git" / "objects").iterdir())

            self.sanitize(workspace)

            # actions/checkout's probes on an existing directory (git-directory-helper.ts): the fetch URL
            # read must succeed and match, or it deletes everything (the 2026-11-25 ##[error]).
            url = git(warm, "config", "--local", "--get", "remote.origin.url", check=False)
            self.assertEqual(url.returncode, 0, url.stderr)
            self.assertEqual(url.stdout.strip(), "https://github.com/manaflow-ai/cmux")
            self.assertEqual(git(warm, "rev-parse", "--git-dir").stdout.strip(), ".git")
            # The object store is kept (the point of the warm disk); metadata and the work tree are not.
            self.assertEqual(sorted(p.name for p in (warm / ".git" / "objects").iterdir()), objects_before)
            self.assertEqual(sorted(p.name for p in warm.iterdir()), [".git"])
            self.assertFalse((warm / ".git" / "hooks").exists())
            self.assertEqual(git(warm, "for-each-ref").stdout, "")
            self.assertEqual((warm / ".git" / "HEAD").read_text(), "ref: refs/heads/main\n")
            # checkout then fetches and checks out the commit; the kept store already holds it.
            git(warm, "checkout", "-q", "--force", sha)
            self.assertEqual((warm / "a.txt").read_text(), "a\n")

    def test_a_fresh_disk_and_a_planted_git_file_still_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            self.sanitize(workspace)
            self.assertEqual(list((workspace / CHECKOUT_PATH).iterdir()), [])
            (workspace / CHECKOUT_PATH / ".git").write_text("gitdir: /elsewhere\n")
            self.sanitize(workspace)
            self.assertEqual(list((workspace / CHECKOUT_PATH).iterdir()), [])

    def test_checkout_does_not_reset_the_unborn_head(self) -> None:
        # clean: true runs `git reset --hard HEAD`, which fails on the sanitized HEAD and makes checkout
        # delete the warm store; the sanitize step already emptied the work tree.
        checkout = next(s for s in checks_steps()
                        if str(s.get("uses", "")).startswith("actions/checkout@")
                        and s.get("with", {}).get("path") == CHECKOUT_PATH)
        self.assertIs(checkout["with"]["clean"], False)


if __name__ == "__main__":
    unittest.main()
