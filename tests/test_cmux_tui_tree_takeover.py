#!/usr/bin/env python3
"""A waiter takes over a cmux-tui tree whose owning artifacts run ended without publishing it.

2026-11-09: artifacts run 42673437035 (a lane-branch push) owned tree c9b813e8. GitHub never
created its x86_64 musl build job, so it ended without publishing, and its notify dispatched
feat-cmux-next's tip daemon suite and base tier in red ("artifacts run ... ended without
publishing tree ..."). Base stayed red until a later commit published the tree. Now the waiting
feat-cmux-next commit re-runs its own artifacts run (cmux-tui-tree-request.yml), which builds and
publishes the key; that publication starts the waiters' tree jobs, so nobody goes red for a run
that is not theirs.
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
import cmux_tui_tree_takeover as takeover  # noqa: E402

KEY = "c9b813e86eddf897113a8117ab43337ff79baca8"
TIP = "c126e737f3a3b96525ad8ea71a71bfa41e118ad1"  # the waiting feat-cmux-next commit
LANE = "134193c6792356e54f3fc419fc52a5eb26318536"  # the owner's lane-branch commit
REPO = "o/r"


def marker_zip(marker: dict) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("marker.json", json.dumps(marker))
    return buffer.getvalue()


def tip_marker(suite: str, run_id: int) -> dict:
    tiers = ["daemon"] if suite == "daemon" else ["daemon", "scheme"]
    return {"version": 1, "key": KEY, "sha": TIP, "status_sha": TIP, "tiers": tiers, "origin": "dispatch",
            "branch": "feat-cmux-next", "ref_kind": "heads", "tip_suite": suite, "run_id": run_id}


class Repo:
    """GitHub as notify and the takeover see it, with a tree-request dispatch that re-runs the
    waiter's artifacts run and a publish that the re-run makes."""

    def __init__(self, markers: list[dict], tip_runs: list[dict]):
        self.artifacts = [
            {"id": 100 + index, "name": f"cmux-next-tree-wait-{KEY}", "expired": False,
             "created_at": "2026-11-09T18:20:00Z", "archive_download_url": f"zip/{100 + index}",
             "workflow_run": {"id": marker["run_id"]}}
            for index, marker in enumerate(markers)]
        self.zips = {f"zip/{100 + index}": marker_zip(marker) for index, marker in enumerate(markers)}
        self.tip_runs = tip_runs
        self.next_dispatches: list[dict] = []  # cmux-next.yml same-tree dispatches
        self.tree_requests: list[dict] = []  # cmux-tui-tree-request.yml dispatches
        self.deleted: list[int] = []
        self.published = False

    def get(self, path: str):
        if path.startswith(f"repos/{REPO}/actions/artifacts?name=cmux-next-tree-wait-{KEY}"):
            live = [a for a in self.artifacts if a["id"] not in self.deleted]
            return {"total_count": len(live), "artifacts": live}
        if path.startswith(f"repos/{REPO}/actions/workflows/cmux-next.yml/runs?event=workflow_dispatch"):
            return {"workflow_runs": []}
        if path.startswith(f"repos/{REPO}/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha="):
            sha = path.split("head_sha=", 1)[1].split("&", 1)[0]
            return {"workflow_runs": self.tip_runs if sha == TIP else []}
        raise AssertionError(f"unexpected GET {path}")

    def download(self, url: str) -> bytes:
        return self.zips[url]

    def post(self, path: str, body: dict) -> int:
        if path == f"repos/{REPO}/actions/workflows/cmux-next.yml/dispatches":
            self.next_dispatches.append(body)
            return 204
        if path == f"repos/{REPO}/actions/workflows/cmux-tui-tree-request.yml/dispatches":
            self.tree_requests.append(body)
            return 204
        raise AssertionError(f"unexpected POST {path}")

    def delete(self, path: str) -> int:
        self.deleted.append(int(path.rsplit("/", 1)[1]))
        return 204

    def tree_request_runs(self) -> None:
        """cmux-tui-tree-request.yml re-runs the waiter's artifacts run, which wins the claim and
        publishes the key (publish-cmux-tui-tree.py writes completion.json)."""
        for request in self.tree_requests:
            assert request == {"ref": "feat-cmux-next", "inputs": {"commit": TIP}}, request
            for run in self.tip_runs:
                run["run_attempt"] = int(run.get("run_attempt") or 1) + 1
        self.published = bool(self.tree_requests)


def notify_run(repo: Repo, state: str) -> int:
    completion = {"key": KEY, "binaries": {"cmux-tui-aarch64-apple-darwin": "f" * 64}} if repo.published else None
    return notify.notify(repo, repo=REPO, key=KEY, state=state,
                         reason=f"the cmux-tui artifacts run 42673437035 ended without publishing tree {KEY}",
                         log=lambda _line: None, fetch_completion=lambda _key: completion)


def tip_run(attempt: int = 1, status: str = "completed") -> dict:
    # The tip's own push run: GitHub created none of its jobs (completed, failure, 0 jobs).
    return {"id": 42672456466, "event": "push", "head_branch": "feat-cmux-next", "status": status,
            "conclusion": "failure", "run_attempt": attempt, "html_url": "https://x/runs/42672456466"}


class OwnerEndedWithoutPublishing(unittest.TestCase):
    def test_the_waiter_takes_over_and_publishes_instead_of_going_red(self):
        """The incident: the owner ended without publishing, then a waiter publishes the tree."""
        repo = Repo([tip_marker("daemon", 1), tip_marker("base", 2)], [tip_run()])
        # The lane owner ends without publishing: notify --state failed.
        self.assertEqual(notify_run(repo, "failed"), 0)
        self.assertEqual([body["inputs"]["same_tree_state"] for body in repo.next_dispatches], [],
                         "no waiter goes red for a run that is not its own")
        self.assertEqual(repo.tree_requests, [{"ref": "feat-cmux-next", "inputs": {"commit": TIP}}],
                         "one takeover per key, from the waiting feat-cmux-next commit")
        self.assertEqual(repo.deleted, [], "the markers stay for the publication")
        # The waiter's re-run publishes the key, and its notify --state ready starts both waiters green.
        repo.tree_request_runs()
        self.assertTrue(repo.published)
        self.assertEqual(notify_run(repo, "ready"), 2)
        self.assertEqual([body["inputs"]["same_tree_state"] for body in repo.next_dispatches], ["ready", "ready"])

    def test_an_active_waiter_run_is_already_the_publisher(self):
        repo = Repo([tip_marker("daemon", 1)], [tip_run(status="in_progress")])
        self.assertEqual(notify_run(repo, "failed"), 0)
        self.assertEqual(repo.tree_requests, [])
        self.assertEqual(repo.next_dispatches, [])

    def test_a_tree_that_failed_every_takeover_is_red_again(self):
        """A key that cannot build is still seen: past the re-run cap the waiters go red."""
        repo = Repo([tip_marker("daemon", 1)], [tip_run(attempt=takeover.MAX_ATTEMPT)])
        self.assertEqual(notify_run(repo, "failed"), 1)
        self.assertEqual(repo.tree_requests, [])
        self.assertEqual(repo.next_dispatches[0]["inputs"]["same_tree_state"], "failed")

    def test_a_waiter_without_a_feat_cmux_next_run_cannot_take_over(self):
        lane = dict(tip_marker("daemon", 1), sha=LANE, status_sha=LANE, origin="push", branch="lane/x")
        lane.pop("tip_suite")
        repo = Repo([lane], [tip_run()])
        self.assertFalse(takeover.take_over_any(repo, repo=REPO, commits=[LANE], key=KEY, log=lambda _l: None))
        self.assertEqual(repo.tree_requests, [])

    def test_a_refused_tree_request_is_no_takeover(self):
        repo = Repo([tip_marker("daemon", 1)], [tip_run()])
        repo.post = lambda path, body: 422  # type: ignore[method-assign]
        taken, why = takeover.take_over(repo, repo=REPO, commit=TIP, key=KEY)
        self.assertFalse(taken)
        self.assertIn("HTTP 422", why)

    def test_the_same_tree_job_takes_over_before_it_reports_red(self):
        """cmux-next.yml's same-tree job runs the takeover first; red only when it is not taken."""
        workflow = (ROOT / ".github" / "workflows" / "cmux-next.yml").read_text(encoding="utf-8")
        job = workflow.split("\n  same-tree-cmux-tui:\n", 1)[1].split("\n  swift-canary-fleet:\n", 1)[0]
        self.assertIn("python3 scripts/ci/cmux_tui_tree_takeover.py", job)
        self.assertIn("actions: write", job)
        self.assertLess(job.index("Take over the unpublished same-tree cmux-tui"),
                        job.index("Report the unavailable same-tree cmux-tui"))
        self.assertIn("steps.takeover.outputs.taken != 'true'", job.split("Report the unavailable", 1)[1])


if __name__ == "__main__":
    unittest.main()
