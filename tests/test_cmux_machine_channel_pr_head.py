#!/usr/bin/env python3
"""scripts/ci/cmux_machine_channel_pr_head.py find: the merged PR head's build, or nothing (PR_HEAD_FAST_LANE)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pr_head", ROOT / "scripts/ci/cmux_machine_channel_pr_head.py")
pr_head = importlib.util.module_from_spec(spec)
sys.modules["pr_head"] = pr_head
spec.loader.exec_module(pr_head)

REPO = "manaflow-ai/cmux"
MERGE = "m" * 40
HEAD = "h" * 40
PREFIX = "machine-channel-"
BOTH = [{"name": f"{PREFIX}cmux-tui-{t}"} for t in pr_head.TARGETS]


def pull(**over):
    pr = {"merge_commit_sha": MERGE, "base": {"ref": "feat-cmux-next"},
          "head": {"sha": HEAD, "repo": {"full_name": REPO}}}
    pr.update(over)
    return pr


class Fake:
    def __init__(self, pulls, runs, artifacts, jobs=None):
        self.pulls, self.runs, self.artifacts, self.jobs = pulls, runs, artifacts, jobs or {}
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        if path.startswith("commits/"):
            return self.pulls
        if path.startswith("actions/workflows/"):
            return {"workflow_runs": self.runs() if callable(self.runs) else self.runs}
        run = int(path.split("/")[2])
        if path.endswith("artifacts?per_page=100"):
            a = self.artifacts(run) if callable(self.artifacts) else self.artifacts.get(run, [])
            return {"artifacts": a}
        return {"jobs": self.jobs.get(run, [])}


def run_find(api, keys=None, wait=0.0):
    keys = keys or {MERGE: "k1", HEAD: "k1"}
    clock = [0.0]
    return pr_head.find(api, REPO, MERGE, PREFIX, wait, key=lambda r: keys.get(r, ""),
                        sleep=lambda s: clock.__setitem__(0, clock[0] + s), now=lambda: clock[0])


class FindTest(unittest.TestCase):
    def test_same_tree_key_and_both_artifacts_take_the_run(self):
        api = Fake([pull()], [{"id": 7, "status": "completed"}], {7: BOTH})
        self.assertEqual(run_find(api), 7)
        self.assertIn(f"actions/workflows/pr-router.yml/runs?head_sha={HEAD}&event=pull_request&per_page=20", api.calls)

    def test_the_newest_run_with_both_wins(self):
        api = Fake([pull()], [{"id": 5, "status": "completed"}, {"id": 9, "status": "completed"}], {5: BOTH, 9: BOTH})
        self.assertEqual(run_find(api), 9)

    def test_keys_that_differ_build_here(self):
        api = Fake([pull()], [{"id": 7, "status": "completed"}], {7: BOTH})
        self.assertIsNone(run_find(api, keys={MERGE: "k1", HEAD: "k2"}))
        self.assertIsNone(run_find(api, keys={MERGE: "", HEAD: ""}))

    def test_a_fork_head_another_base_or_a_non_squash_build_here(self):
        for pr in (pull(head={"sha": HEAD, "repo": {"full_name": "someone/cmux"}}),
                   pull(base={"ref": "main"}), pull(merge_commit_sha="x" * 40)):
            with self.subTest(pr=pr):
                self.assertIsNone(run_find(Fake([pr], [{"id": 7, "status": "completed"}], {7: BOTH})))

    def test_one_target_or_expired_artifacts_build_here(self):
        expired = [dict(a, expired=True) for a in BOTH]
        for arts in (BOTH[:1], expired, []):
            with self.subTest(arts=arts):
                self.assertIsNone(run_find(Fake([pull()], [{"id": 7, "status": "completed"}], {7: arts})))

    def test_a_build_still_running_is_waited_for(self):
        polls = []

        def artifacts(run):
            polls.append(run)
            return BOTH if len(polls) >= 3 else []

        jobs = {7: [{"name": "machine channel PR head build / build-machine-channel / build x", "status": "in_progress"}]}
        api = Fake([pull()], [{"id": 7, "status": "in_progress"}], artifacts, jobs)
        self.assertEqual(run_find(api, wait=600), 7)
        self.assertEqual(len(polls), 3)

    def test_the_wait_is_bounded(self):
        jobs = {7: [{"name": "x / build-machine-channel / build y", "status": "in_progress"}]}
        api = Fake([pull()], [{"id": 7, "status": "in_progress"}], {}, jobs)
        self.assertIsNone(run_find(api, wait=90))

    def test_a_running_router_whose_channel_jobs_ended_is_not_waited_for(self):
        jobs = {7: [{"name": "x / does the machine channel need this commit", "status": "completed"}]}
        api = Fake([pull()], [{"id": 7, "status": "in_progress"}], {}, jobs)
        self.assertIsNone(run_find(api, wait=600))
        self.assertEqual(sum(c.startswith("actions/workflows/") for c in api.calls), 1)

    def test_main_prints_nothing_without_a_token(self):
        import io, contextlib, os
        out = io.StringIO()
        env = dict(os.environ)
        os.environ.pop("GH_TOKEN", None)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(pr_head.main(["find", MERGE]), 0)
        finally:
            os.environ.clear(); os.environ.update(env)
        self.assertEqual(out.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
