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


class RevisionPlanTests(unittest.TestCase):
    def info(self, **values):
        return {"state": "OPEN", "closedAt": None, "headRefOid": "a" * 40,
                "body": "", "commentBodies": [], "commentsComplete": True, **values}

    def test_body_comments_current_and_three_recent_revisions_survive(self):
        revisions = [f"{n:08x}" for n in range(1, 7)]
        files = [f"42/{revision}/tour/image.png" for revision in revisions]
        files += ["42/aaaaaaaa/tour/image.png", "42/manual.png", "README.md"]
        recent = {f"42/{revision}": int(NOW.timestamp()) - n for n, revision in enumerate(revisions)}
        recent["42/aaaaaaaa"] = 1
        info = self.info(
            body=f"![body](https://raw.githubusercontent.com/o/r/pr-media/{files[4]}?v=2)",
            commentBodies=[f'<img src="https://github.com/o/r/raw/refs/heads/pr-media/{files[5]}#frame">'],
        )
        keep, drop = prune.plan_media("o/r", files, {42: info}, NOW, recent)
        self.assertEqual(drop, [files[3]])
        self.assertEqual(set(keep), set(files) - set(drop))

    def test_latest_available_revision_is_fallback_when_head_has_no_media(self):
        files = ["42/00000001/tour/a.png", "42/00000002/tour/a.png"]
        recent = {"42/00000001": 1, "42/00000002": 2}
        keep, drop = prune.plan_media("o/r", files, {42: self.info()}, NOW, recent)
        self.assertEqual((keep, drop), ([files[1]], [files[0]]))

    def test_lookup_gaps_pagination_and_history_failure_keep_everything(self):
        files = ["42/00000001/tour/a.png", "README.md"]
        for details, history in (({}, {}), ({42: self.info(commentsComplete=False)}, {}),
                                 ({42: self.info()}, None)):
            with self.subTest(details=details, history=history):
                self.assertEqual(prune.plan_media("o/r", files, details, NOW, history), (files, []))

    def test_keep_marker_preserves_old_closed_root(self):
        files = ["42/00000001/tour/a.png"]
        info = self.info(state="MERGED", closedAt=LONG_AGO, body="<!-- cmux:pr-media:keep -->")
        self.assertEqual(prune.plan_media("o/r", files, {42: info}, NOW, {}), (files, []))

    def test_live_pr_reference_preserves_media_of_another_old_closed_pr(self):
        files = ["42/00000001/tour/a.png", "7/00000001/tour/a.png"]
        details = {42: self.info(body=f"https://raw.githubusercontent.com/o/r/pr-media/{files[1]}"),
                   7: self.info(state="MERGED", closedAt=LONG_AGO)}
        self.assertEqual(prune.plan_media("o/r", files, details, NOW, {}), (files, []))

    def test_closed_policy_preserves_recent_uploads_and_drops_old_unreferenced_media(self):
        files = ["1/a.png", "2/a.png", "3/a.png"]
        details = {1: self.info(state="MERGED", closedAt=LONG_AGO),
                   2: self.info(state="CLOSED", closedAt=LATELY),
                   3: self.info(state="MERGED", closedAt=LONG_AGO)}
        recent = {"3": int(NOW.timestamp())}
        self.assertEqual(prune.plan_media("o/r", files, details, NOW, recent),
                         ([files[1], files[2]], [files[0]]))

    def test_different_repository_url_does_not_protect_stale_revision(self):
        files = ["42/00000001/tour/a.png", "42/aaaaaaaa/tour/a.png"]
        info = self.info(body=f"https://raw.githubusercontent.com/other/r/pr-media/{files[0]}")
        self.assertEqual(prune.plan_media("o/r", files, {42: info}, NOW, {"42/00000001": 1}),
                         ([files[1]], [files[0]]))

    def test_revision_without_reliable_age_is_preserved(self):
        files = ["42/00000001/tour/a.png", "42/aaaaaaaa/tour/a.png"]
        self.assertEqual(prune.plan_media("o/r", files, {42: self.info()}, NOW, {}), (files, []))


class PullDetailsTests(unittest.TestCase):
    def test_bounded_query_includes_metadata_and_incomplete_comments_are_marked(self):
        payload = {"data": {"repository": {
            "p1": {"state": "OPEN", "comments": {"nodes": [{"body": "evidence"}],
                     "pageInfo": {"hasNextPage": True}}}, "p2": None}}}
        with mock.patch.object(prune.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, json.dumps(payload), "missing number")) as run:
            details = prune.pull_details("o/r", [1, 2])
        self.assertFalse(details[1]["commentsComplete"])
        self.assertEqual(details[1]["commentBodies"], ["evidence"])
        self.assertNotIn(2, details)
        query = run.call_args[0][0][-1]
        for field in ("headRefOid", "body", "state", "closedAt", "hasNextPage", "comments(first: 100)"):
            self.assertIn(field, query)


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
            original = prune.pull_details
            prune.pull_details = lambda _repo, _numbers: {1: {"state": "MERGED", "closedAt": LONG_AGO, "commentsComplete": True},
                                                         3: {"state": "OPEN", "commentsComplete": True}}
            self.addCleanup(setattr, prune, "pull_details", original)
            prune.prune("o/r", checkout, apply=False, now=NOW)
            self.assertEqual(git("rev-list", "--count", prune.BRANCH, cwd=remote), "3")
            prune.prune("o/r", checkout, apply=True, now=NOW)
            self.assertEqual(git("rev-list", "--count", prune.BRANCH, cwd=remote), "1")
            self.assertEqual(git("ls-tree", "-r", "--name-only", prune.BRANCH, cwd=remote).split(),
                             [prune.RETENTION_INDEX, "3/b.png", "README.md"])
            # The squash re-dates every file, but is not read as a fresh upload.
            prune.pull_details = lambda _repo, _numbers: {3: {"state": "MERGED", "closedAt": LONG_AGO, "commentsComplete": True}}
            prune.prune("o/r", checkout, apply=True, now=NOW)
            self.assertEqual(git("ls-tree", "-r", "--name-only", prune.BRANCH, cwd=remote).split(), [prune.RETENTION_INDEX, "README.md"])

    def test_an_upload_during_the_prune_wins(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            remote, work, checkout = self.setup_remote(temp)

            def states_while_uploading(_repo, _numbers):
                Path(work, "4").mkdir()
                Path(work, "4/c.png").write_text("c")
                git("add", "4/c.png", cwd=work)
                git("commit", "-qm", "4", cwd=work)
                git("push", "-q", str(remote), prune.BRANCH, cwd=work)
                return {1: {"state": "MERGED", "closedAt": LONG_AGO, "commentsComplete": True}}

            original = prune.pull_details
            prune.pull_details = states_while_uploading
            self.addCleanup(setattr, prune, "pull_details", original)
            self.assertEqual(prune.prune("o/r", checkout, apply=True, now=NOW), 0)
            self.assertEqual(git("rev-parse", prune.BRANCH, cwd=remote), git("rev-parse", "HEAD", cwd=work))

    def test_nested_revision_pruning_keeps_upload_ages_across_squash(self):
        with tempfile.TemporaryDirectory() as temp:
            remote, work, checkout = self.setup_remote(temp)
            old = "3/11111111/tour/évidence.png"
            current = "3/aaaaaaaa/tour/a.png"
            for path in (old, current):
                Path(work, path).parent.mkdir(parents=True, exist_ok=True)
                Path(work, path).write_text(path)
                git("add", path, cwd=work)
                git("commit", "-qm", path, cwd=work)
            git("push", "-q", str(remote), prune.BRANCH, cwd=work)
            info = {3: {"state": "OPEN", "headRefOid": "a" * 40, "commentsComplete": True}}
            with mock.patch.object(prune, "pull_details", return_value=info):
                prune.prune("o/r", checkout, apply=True, now=NOW)
                paths = git("ls-tree", "-r", "--name-only", prune.BRANCH, cwd=remote).splitlines()
                self.assertIn(current, paths)
                self.assertNotIn(old, paths)
                index = json.loads(git("show", f"{prune.BRANCH}:{prune.RETENTION_INDEX}", cwd=remote))
                self.assertEqual(index["3/aaaaaaaa"], int(dt.datetime(2026, 7, 1, tzinfo=dt.timezone.utc).timestamp()))
                ages = prune.recent_revision_groups(checkout, f"refs/remotes/origin/{prune.BRANCH}", NOW)
                self.assertEqual(ages["3/aaaaaaaa"], index["3/aaaaaaaa"])


class WorkflowTests(unittest.TestCase):
    def test_only_main_prunes_and_a_dry_run_is_the_default(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/pr-media-prune.yml").read_text())
        self.assertEqual(workflow["permissions"], {})
        job = workflow["jobs"]["prune"]
        self.assertIn("refs/heads/main", job["if"])
        self.assertEqual(job["permissions"], {"contents": "write", "pull-requests": "read"})
        self.assertFalse(workflow[True]["workflow_dispatch"]["inputs"]["apply"]["default"])


if __name__ == "__main__":
    unittest.main(buffer=True)
