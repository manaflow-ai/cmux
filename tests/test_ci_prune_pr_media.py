#!/usr/bin/env python3
"""PR media pruning: which folders go, and the rewrite keeps everything else."""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prune_pr_media", ROOT / "scripts/ci/prune_pr_media.py")
assert spec and spec.loader
prune = importlib.util.module_from_spec(spec)
sys.modules["prune_pr_media"] = prune
spec.loader.exec_module(prune)

NOW = dt.datetime(2026, 9, 28, tzinfo=dt.timezone.utc)
LONG_AGO = "2026-08-01T00:00:00Z"
LATELY = "2026-09-20T00:00:00Z"


class PlanTests(unittest.TestCase):
    def test_only_long_closed_pull_requests_are_dropped(self) -> None:
        states = {
            1: {"state": "MERGED", "closedAt": LONG_AGO},
            2: {"state": "CLOSED", "closedAt": LONG_AGO},
            3: {"state": "MERGED", "closedAt": LATELY},
            4: {"state": "OPEN", "closedAt": None},
        }
        keep, drop = prune.plan(["1", "2", "3", "4", "5", "README.md", "ui-lab", "fuzz"], states, NOW)
        self.assertEqual(drop, ["1", "2"])
        # 5 is unknown to GitHub: a lookup gap never deletes media.
        self.assertEqual(keep, ["3", "4", "5", "README.md", "ui-lab", "fuzz"])

    def test_a_reopened_pull_request_is_kept(self) -> None:
        keep, drop = prune.plan(["7"], {7: {"state": "OPEN", "closedAt": LONG_AGO}}, NOW)
        self.assertEqual((keep, drop), (["7"], []))


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class RewriteTests(unittest.TestCase):
    def test_apply_squashes_the_branch_to_the_kept_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            remote, work, checkout = Path(temp, "remote.git"), Path(temp, "work"), Path(temp, "checkout")
            env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@e"}
            patcher = mock.patch.dict(os.environ, env)
            patcher.start()
            self.addCleanup(patcher.stop)
            subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
            subprocess.run(["git", "init", "-q", "-b", prune.BRANCH, str(work)], check=True)
            for name in ("1/a.png", "3/b.png", "README.md"):
                Path(work, name).parent.mkdir(parents=True, exist_ok=True)
                Path(work, name).write_text(name)
                git("add", name, cwd=work)
                git("commit", "-qm", name, cwd=work)
            git("push", "-q", str(remote), prune.BRANCH, cwd=work)
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            git("remote", "add", "origin", str(remote), cwd=checkout)

            original = prune.pull_states
            prune.pull_states = lambda _repo, _numbers: {1: {"state": "MERGED", "closedAt": LONG_AGO},
                                                         3: {"state": "OPEN"}}
            self.addCleanup(setattr, prune, "pull_states", original)
            prune.prune("o/r", checkout, apply=False, now=NOW)
            self.assertEqual(git("rev-list", "--count", prune.BRANCH, cwd=remote), "3")
            prune.prune("o/r", checkout, apply=True, now=NOW)
            self.assertEqual(git("rev-list", "--count", prune.BRANCH, cwd=remote), "1")
            self.assertEqual(git("ls-tree", "-r", "--name-only", prune.BRANCH, cwd=remote).split(),
                             ["3/b.png", "README.md"])


class WorkflowTests(unittest.TestCase):
    def test_only_main_prunes_and_a_dry_run_is_the_default(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/pr-media-prune.yml").read_text())
        self.assertEqual(workflow["permissions"], {})
        job = workflow["jobs"]["prune"]
        self.assertIn("refs/heads/main", job["if"])
        self.assertEqual(job["permissions"], {"contents": "write", "pull-requests": "read"})
        self.assertFalse(workflow[True]["workflow_dispatch"]["inputs"]["apply"]["default"])


if __name__ == "__main__":
    unittest.main()
