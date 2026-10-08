#!/usr/bin/env python3
"""The cmux-tui artifacts workflow starts the cmux-next tree jobs it unblocked.

cmux-next's path routing probes the same-tree cmux-tui once. When the tree is
not published yet it leaves a marker artifact `cmux-next-tree-wait-<key>` and
skips the tree jobs instead of polling. When an artifacts run publishes <key>
(or fails to), scripts/ci/cmux_next_tree_notify.py finds those markers and
dispatches cmux-next's same-tree mode for each run that is still current.
"""

from __future__ import annotations

import io
import json
import sys
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_tree_notify as notify  # noqa: E402

KEY = "a" * 40
SHA = "b" * 40
HEAD = "c" * 40
NEWER = "d" * 40


def marker_zip(marker: dict) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("marker.json", json.dumps(marker))
    return buffer.getvalue()


def push_marker(**extra) -> dict:
    marker = {"version": 1, "key": KEY, "sha": SHA, "status_sha": SHA, "tiers": ["daemon", "scheme"],
              "origin": "push", "branch": "feat-cmux-next", "run_id": 11}
    marker.update(extra)
    return marker


def pr_marker(**extra) -> dict:
    marker = {"version": 1, "key": KEY, "sha": SHA, "status_sha": HEAD, "tiers": ["daemon"],
              "origin": "pull_request", "pr": 7, "head_ref": "lane/x", "head_repo": "o/r",
              "base_ref": "feat-cmux-next", "run_id": 12}
    marker.update(extra)
    return marker


class FakeApi:
    def __init__(self, markers: list[dict], *, branch_head: str = SHA, pr: dict | None = None,
                 refuse_refs: tuple[str, ...] = ()):
        self.artifacts = [
            {"id": 100 + index, "name": f"cmux-next-tree-wait-{KEY}", "expired": False,
             "archive_download_url": f"zip/{100 + index}", "workflow_run": {"id": marker.get("run_id")}}
            for index, marker in enumerate(markers)
        ]
        self.zips = {f"zip/{100 + index}": marker_zip(marker) for index, marker in enumerate(markers)}
        self.branch_head = branch_head
        self.pr = pr if pr is not None else {"state": "open", "head": {"sha": HEAD}}
        self.refuse_refs = refuse_refs
        self.dispatched: list[dict] = []
        self.deleted: list[int] = []

    def get(self, path: str):
        if path.startswith(f"repos/o/r/actions/artifacts?name=cmux-next-tree-wait-{KEY}"):
            return {"total_count": len(self.artifacts), "artifacts": self.artifacts}
        if path == "repos/o/r/git/ref/heads/feat-cmux-next":
            return {"object": {"sha": self.branch_head}}
        if path == "repos/o/r/pulls/7":
            return self.pr
        raise AssertionError(f"unexpected GET {path}")

    def download(self, url: str) -> bytes:
        return self.zips[url]

    def post(self, path: str, body: dict) -> int:
        assert path == "repos/o/r/actions/workflows/cmux-next.yml/dispatches", path
        if body["ref"] in self.refuse_refs:
            return 422
        self.dispatched.append(body)
        return 204

    def delete(self, path: str) -> int:
        self.deleted.append(int(path.rsplit("/", 1)[1]))
        return 204


def run(api: FakeApi, state: str = "ready") -> int:
    return notify.notify(api, repo="o/r", key=KEY, state=state, reason="publish failed: u3",
                         log=lambda _line: None)


class Notify(unittest.TestCase):
    def test_a_published_tree_dispatches_the_current_push_and_drops_its_marker(self):
        api = FakeApi([push_marker()])
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["ref"], "feat-cmux-next")
        self.assertEqual(body["inputs"]["same_tree_sha"], SHA)
        self.assertEqual(body["inputs"]["same_tree_status_sha"], SHA)
        self.assertEqual(body["inputs"]["same_tree_tiers"], "daemon,scheme")
        self.assertEqual(body["inputs"]["same_tree_state"], "ready")
        self.assertEqual(body["inputs"]["same_tree_origin"], "push")
        self.assertEqual(api.deleted, [100])

    def test_a_superseded_push_is_not_dispatched(self):
        api = FakeApi([push_marker()], branch_head=NEWER)
        self.assertEqual(run(api), 0)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.deleted, [100])

    def test_a_pull_request_runs_on_its_head_branch_with_its_merge_commit(self):
        api = FakeApi([pr_marker()])
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["ref"], "lane/x")
        self.assertEqual(body["inputs"]["same_tree_sha"], SHA)
        self.assertEqual(body["inputs"]["same_tree_status_sha"], HEAD)
        self.assertEqual(body["inputs"]["same_tree_tiers"], "daemon")
        self.assertEqual(body["inputs"]["same_tree_origin"], "pull_request")

    def test_a_head_branch_without_the_inputs_falls_back_to_the_base_branch(self):
        api = FakeApi([pr_marker()], refuse_refs=("lane/x",))
        self.assertEqual(run(api), 1)
        self.assertEqual([body["ref"] for body in api.dispatched], ["feat-cmux-next"])

    def test_a_moved_or_closed_pull_request_is_not_dispatched(self):
        for pr in ({"state": "open", "head": {"sha": NEWER}}, {"state": "closed", "head": {"sha": HEAD}}):
            with self.subTest(pr=pr):
                api = FakeApi([pr_marker()], pr=pr)
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])

    def test_a_fork_pull_request_runs_on_the_base_branch(self):
        api = FakeApi([pr_marker(head_repo="someone/cmux")])
        self.assertEqual(run(api), 1)
        self.assertEqual([body["ref"] for body in api.dispatched], ["feat-cmux-next"])

    def test_a_failed_publish_reports_red_and_keeps_the_marker(self):
        """A takeover run may still publish the key; its notify then dispatches green."""
        api = FakeApi([push_marker()])
        self.assertEqual(run(api, state="failed"), 1)
        [body] = api.dispatched
        self.assertEqual(body["inputs"]["same_tree_state"], "failed")
        self.assertIn("publish failed", body["inputs"]["same_tree_reason"])
        self.assertEqual(api.deleted, [])

    def test_a_malformed_marker_is_ignored(self):
        for bad in (push_marker(sha="not-a-sha"), push_marker(key="e" * 40), push_marker(tiers=["rm -rf"]),
                    push_marker(origin="schedule"), pr_marker(pr="7; true")):
            with self.subTest(marker=bad):
                api = FakeApi([bad])
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])


if __name__ == "__main__":
    unittest.main()
