#!/usr/bin/env python3
"""PR media pruning: which folders go, and the rewrite keeps everything else."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
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

    def test_a_recent_upload_to_a_long_closed_pull_request_is_kept(self) -> None:
        states = {7: {"state": "MERGED", "closedAt": LONG_AGO}}
        self.assertEqual(prune.plan(["7"], states, NOW, frozenset({"7"})), (["7"], []))

    def test_a_reopened_pull_request_is_kept(self) -> None:
        keep, drop = prune.plan(["7"], {7: {"state": "OPEN", "closedAt": LONG_AGO}}, NOW)
        self.assertEqual((keep, drop), (["7"], []))


class PullStatesTests(unittest.TestCase):
    def answer(self, returncode: int, stdout: str):
        calls = []

        def run(args, **_):
            calls.append(args)
            return subprocess.CompletedProcess(args, returncode, stdout, "boom")

        patcher = mock.patch.object(prune.subprocess, "run", run)
        patcher.start()
        self.addCleanup(patcher.stop)
        return calls

    def test_a_number_graphql_does_not_know_is_absent(self) -> None:
        data = {"data": {"repository": {"p1": {"state": "MERGED", "closedAt": LONG_AGO}, "p2": None}},
                "errors": [{"type": "NOT_FOUND"}]}
        self.answer(1, json.dumps(data))
        self.assertEqual(prune.pull_states("o/r", [1, 2]), {1: {"state": "MERGED", "closedAt": LONG_AGO}})

    def test_a_failed_query_raises(self) -> None:
        self.answer(1, "")
        with self.assertRaises(RuntimeError):
            prune.pull_states("o/r", [1])

    def test_numbers_are_batched(self) -> None:
        calls = self.answer(0, json.dumps({"data": {"repository": {}}}))
        prune.pull_states("o/r", list(range(1, prune.GRAPHQL_BATCH + 2)))
        self.assertEqual(len(calls), 2)


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class RewriteTests(unittest.TestCase):
    def setup_remote(self, temp: str) -> tuple[Path, Path, Path]:
        if True:
            remote, work, checkout = Path(temp, "remote.git"), Path(temp, "work"), Path(temp, "checkout")
            env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@e",
                   # Uploaded before the retention window.
                   "GIT_AUTHOR_DATE": "2026-07-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-07-01T00:00:00Z"}
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
            return remote, work, checkout

    def test_apply_squashes_the_branch_to_the_kept_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            remote, _work, checkout = self.setup_remote(temp)
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
            # The squash re-dates every file, but is not read as a fresh upload.
            prune.pull_states = lambda _repo, _numbers: {3: {"state": "MERGED", "closedAt": LONG_AGO}}
            prune.prune("o/r", checkout, apply=True, now=NOW)
            self.assertEqual(git("ls-tree", "-r", "--name-only", prune.BRANCH, cwd=remote).split(), ["README.md"])

    def test_an_upload_during_the_prune_wins(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            remote, work, checkout = self.setup_remote(temp)

            def states_while_uploading(_repo, _numbers):
                Path(work, "4").mkdir()
                Path(work, "4/c.png").write_text("c")
                git("add", "4/c.png", cwd=work)
                git("commit", "-qm", "4", cwd=work)
                git("push", "-q", str(remote), prune.BRANCH, cwd=work)
                return {1: {"state": "MERGED", "closedAt": LONG_AGO}}

            original = prune.pull_states
            prune.pull_states = states_while_uploading
            self.addCleanup(setattr, prune, "pull_states", original)
            self.assertEqual(prune.prune("o/r", checkout, apply=True, now=NOW), 0)
            self.assertEqual(git("rev-parse", prune.BRANCH, cwd=remote), git("rev-parse", "HEAD", cwd=work))


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
