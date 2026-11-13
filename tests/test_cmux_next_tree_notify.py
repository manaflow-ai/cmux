#!/usr/bin/env python3
"""The cmux-tui artifacts workflow starts the cmux-next tree jobs it unblocked.

cmux-next's path routing probes the same-tree cmux-tui once. When the tree is
not published yet it leaves a marker artifact `cmux-next-tree-wait-<key>` and
skips the tree jobs instead of polling. When an artifacts run publishes <key>
(or fails to), scripts/ci/cmux_next_tree_notify.py finds those markers and
dispatches cmux-next's same-tree mode for each run that is still current.
"""

from __future__ import annotations

import http.client
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
EARLIER = "2026-11-02T03:00:42Z"  # the run that uploaded the marker
UPLOADED = "2026-11-02T03:01:10Z"  # the marker artifact
LATER = "2026-11-02T03:30:02Z"


REPO_ID = 1144115288  # o/r
FORK_ID = 9  # someone/cmux
FORK_RUN = {"head_repository_id": FORK_ID}  # the artifact of a fork pull request's run


def pull(sha: str = HEAD, *, ref: str = "lane/x", repo: str = "o/r", base: str = "feat-cmux-next",
         state: str = "open") -> dict:
    """pulls/7 as GitHub returns it (the fields the notifier reads)."""
    return {"state": state, "head": {"sha": sha, "ref": ref, "repo": {"full_name": repo}}, "base": {"ref": base}}


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
                 artifact_runs: list[dict | None] | None = None,
                 refuse_refs: tuple[str, ...] = (), runs: list[dict] | None = None,
                 history_error: bool = False, jobs: dict[int, list[dict]] | None = None):
        self.artifacts = [
            {"id": 100 + index, "name": f"cmux-next-tree-wait-{KEY}", "expired": False,
             "created_at": UPLOADED,
             "archive_download_url": f"zip/{100 + index}",
             # The artifact's run as GitHub records it: a same-repository run unless the test says otherwise.
             "workflow_run": dict({"id": marker.get("run_id"), "repository_id": REPO_ID, "head_repository_id": REPO_ID,
                                   "head_branch": marker.get("head_ref") or marker.get("branch"),
                                   "head_sha": marker.get("status_sha")},
                                  **((artifact_runs or [None] * len(markers))[index] or {}))}
            for index, marker in enumerate(markers)
        ]
        self.zips = {f"zip/{100 + index}": marker_zip(marker) for index, marker in enumerate(markers)}
        self.branch_head = branch_head
        self.pr = pr if pr is not None else pull()
        self.refuse_refs = refuse_refs
        self.dispatched: list[dict] = []
        self.deleted: list[int] = []
        # cmux-next.yml's dispatch runs; each accepted dispatch adds one, as GitHub does.
        self.runs = list(runs or [])
        self.history_error = history_error
        self.history_reads: list[str] = []
        # run id -> its jobs (the jobs API); a run without an entry has a same-tree run's jobs, its Mac job queued.
        self.jobs = dict(jobs or {})
        self.cancelled: list[int] = []

    def get(self, path: str):
        if path.startswith(f"repos/o/r/actions/artifacts?name=cmux-next-tree-wait-{KEY}"):
            return {"total_count": len(self.artifacts), "artifacts": self.artifacts}
        if path.startswith("repos/o/r/git/ref/heads/"):
            return {"object": {"sha": self.branch_head}}
        if path == "repos/o/r/pulls/7":
            return self.pr
        if path.startswith("repos/o/r/actions/workflows/cmux-next.yml/runs?event=workflow_dispatch&created=%3E%3D"):
            self.history_reads.append(path)
            if self.history_error:
                raise RuntimeError("HTTP 403")
            since = path.split("created=%3E%3D", 1)[1].split("&", 1)[0]
            return {"workflow_runs": [run for run in self.runs if run["created_at"] >= since]}
        if path.startswith("repos/o/r/actions/workflows/cmux-next.yml/runs?branch="):
            branch = path.split("branch=", 1)[1].split("&", 1)[0]
            assert "event=workflow_dispatch" in path, path
            # GitHub lists the newest first.
            return {"workflow_runs": sorted((run for run in self.runs if run.get("head_branch") == branch),
                                            key=lambda run: run["created_at"], reverse=True)}
        if path.startswith("repos/o/r/actions/runs/") and "/jobs?" in path:
            run_id = int(path.split("/")[5])
            return {"jobs": self.jobs.get(run_id, same_tree_jobs())}
        if path.startswith("repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha="):
            # No artifacts run of the waiter's commit: the takeover (cmux_tui_tree_takeover.py) is refused, and
            # a failed state is reported red (tests/test_cmux_tui_tree_takeover.py covers the takeover).
            return {"workflow_runs": []}
        raise AssertionError(f"unexpected GET {path}")

    def download(self, url: str) -> bytes:
        return self.zips[url]

    def post(self, path: str, body: dict) -> int:
        if path.startswith("repos/o/r/actions/runs/") and path.endswith("/cancel"):
            self.cancelled.append(int(path.split("/")[5]))
            return 202
        assert path == "repos/o/r/actions/workflows/cmux-next.yml/dispatches", path
        if body["ref"] in self.refuse_refs:
            return 422
        self.dispatched.append(body)
        inputs = body["inputs"]
        sha = inputs["same_tree_sha"]
        name = (f"cmux NEXT DEV daily · {inputs['dev_daily_sha']}" if inputs.get("dev_daily") == "true"
                else f"cmux-next tip daemon suite · {sha}" if inputs.get("tip_daemon_suite") == "true"
                else f"cmux-next base tier · {sha}" if inputs.get("base_tier") == "true"
                else f"cmux-next · {inputs['same_tree_status_sha']}")
        # GitHub's clock moves on: each dispatch is created after everything before it.
        # As the REST API lists it: the evaluated run-name in display_title (and here a static `name`).
        # A plain same-tree run's name is `cmux-next · <github.sha>`: the dispatch ref's tip, which is
        # the commit that gets the statuses (a pull request's head on its head branch).
        self.runs.append({"name": "cmux-next", "display_title": name, "id": 9000 + len(self.runs),
                          "event": "workflow_dispatch", "head_branch": body["ref"],
                          "head_sha": inputs["same_tree_status_sha"], "status": "queued", "run_attempt": 1,
                          "created_at": f"2026-11-02T05:{len(self.runs):02d}:00Z"})
        return 204

    def delete(self, path: str) -> int:
        self.deleted.append(int(path.rsplit("/", 1)[1]))
        return 204


def same_tree_jobs(mac: str = "queued") -> list[dict]:
    """A same-tree run's jobs as the jobs API lists them (run 42607592895): its routing and push head
    preflight skipped, its Mac job in state MAC."""
    return [{"name": "cmux-next push head preflight", "status": "completed", "conclusion": "skipped"},
            {"name": "cmux-next path routing", "status": "completed", "conclusion": "skipped"},
            {"name": "cmux-next macOS placement", "status": "completed", "conclusion": "success"},
            {"name": "cmux app scheme compile (Debug)", "status": mac, "conclusion": None}]


def plain_dispatch_jobs() -> list[dict]:
    """A plain dispatch (no same-tree inputs) routes itself: its preflight and routing run."""
    return [{"name": "cmux-next push head preflight", "status": "completed", "conclusion": "success"},
            {"name": "cmux-next path routing", "status": "in_progress", "conclusion": None},
            {"name": "cmux app scheme compile (Debug)", "status": "queued", "conclusion": None}]


def open_run(run_id: int, minute: int, *, branch: str = "lane/x", sha: str | None = None,
             title: str | None = None, **extra) -> dict:
    """An open cmux-next.yml dispatch run created at 04:MINUTE (before any dispatch the fake makes)."""
    sha = sha or f"{run_id:040d}"
    record = {"id": run_id, "name": "cmux-next", "display_title": title or f"cmux-next · {sha}",
              "event": "workflow_dispatch", "head_branch": branch, "head_sha": sha, "status": "queued",
              "run_attempt": 1, "created_at": f"2026-11-02T04:{minute:02d}:00Z"}
    record.update(extra)
    return record


def run(api: FakeApi, state: str = "ready", completion: dict | None = None) -> int:
    """`completion` is the tree's completion.json on R2 (None: not published)."""
    return notify.notify(api, repo="o/r", key=KEY, state=state, reason="publish failed: u3",
                         log=lambda _line: None, fetch_completion=lambda key: completion)


def completion_json(key: str = KEY) -> dict:
    return {"key": key, "binaries": {"cmux-tui-aarch64-apple-darwin": "f" * 64}}


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

    def test_a_branch_dispatch_runs_again_on_its_branch_as_a_dispatch(self):
        """#22303: a dispatch on a working branch whose tree was still building gets its
        daemon tests once the tree publishes; origin push would skip them (daemon-test)."""
        api = FakeApi([push_marker(origin="dispatch", branch="lane/x")])
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["ref"], "lane/x")
        self.assertEqual(body["inputs"]["same_tree_origin"], "dispatch")
        moved = FakeApi([push_marker(origin="dispatch", branch="lane/x")], branch_head=NEWER)
        self.assertEqual(run(moved), 0)
        self.assertEqual(moved.dispatched, [])

    def test_a_tip_daemon_suite_runs_its_exact_commit_after_the_tip_moves(self):
        """2026-10-30 (#27692): in a landing burst the tip moves before its tree publishes, so a
        dispatch marker was always superseded and the base never got a daemon-test verdict. The tip
        daemon suite's marker names its commit, like the DEV daily, and its run keeps the suite's name."""
        marker = push_marker(origin="dispatch", tiers=["daemon"], tip_suite="daemon")
        api = FakeApi([marker], branch_head=NEWER)
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["ref"], "feat-cmux-next")
        self.assertEqual(body["inputs"]["same_tree_sha"], SHA)
        self.assertEqual(body["inputs"]["same_tree_origin"], "dispatch")
        self.assertEqual(body["inputs"]["same_tree_tiers"], "daemon")
        self.assertEqual(body["inputs"]["tip_daemon_suite"], "true")
        self.assertEqual(api.deleted, [100])
        plain = FakeApi([push_marker(origin="dispatch", tiers=["daemon"])])
        run(plain)
        self.assertNotIn("tip_daemon_suite", plain.dispatched[0]["inputs"])

    def test_only_a_daemon_dispatch_on_feat_cmux_next_is_a_tip_suite(self):
        for bad in (push_marker(origin="dispatch", tiers=["daemon"], tip_suite="swift"),
                    push_marker(origin="push", tiers=["daemon"], tip_suite="daemon"),
                    push_marker(origin="dispatch", branch="lane/x", tiers=["daemon"], tip_suite="daemon"),
                    push_marker(origin="dispatch", tiers=["daemon", "scheme"], tip_suite="daemon"),
                    push_marker(origin="dispatch", branch="feat-cmux-next", ref_kind="tags", tiers=["daemon"],
                                tip_suite="daemon")):
            with self.subTest(marker=bad):
                api = FakeApi([bad], branch_head=NEWER)
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])

    def test_a_base_tier_runs_its_exact_commit_after_the_tip_moves(self):
        """cmuxterm-hq#5424: a feat-cmux-next push leaves its base Mac tier to one `cmux-next base tier`
        run every 15 minutes. Its same-tree run tests the commit that run named (the tip moves on
        within minutes) and keeps the name push attribution and base_red_excuse.py look up."""
        marker = push_marker(origin="dispatch", tiers=["daemon", "scheme"], tip_suite="base")
        api = FakeApi([marker], branch_head=NEWER)
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["ref"], "feat-cmux-next")
        self.assertEqual(body["inputs"]["same_tree_sha"], SHA)
        self.assertEqual(body["inputs"]["same_tree_tiers"], "daemon,scheme")
        self.assertEqual(body["inputs"]["base_tier"], "true")
        self.assertNotIn("tip_daemon_suite", body["inputs"])
        scheme_only = FakeApi([push_marker(origin="dispatch", tiers=["scheme"], tip_suite="base")], branch_head=NEWER)
        self.assertEqual(run(scheme_only), 1)
        self.assertEqual(scheme_only.dispatched[0]["inputs"]["base_tier"], "true")

    def test_only_a_dispatch_on_feat_cmux_next_is_a_base_tier(self):
        for bad in (push_marker(origin="push", tip_suite="base"),
                    push_marker(origin="dispatch", branch="lane/x", tip_suite="base"),
                    push_marker(origin="dispatch", ref_kind="tags", tip_suite="base"),
                    push_marker(origin="dispatch", tip_suite=["base"]),
                    push_marker(origin="dispatch", dev_daily=True, dev_daily_sha=SHA, tip_suite="base")):
            with self.subTest(marker=bad):
                api = FakeApi([bad], branch_head=NEWER)
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])

    def test_a_tag_dispatch_runs_again_on_its_tag(self):
        """A tag has no branch head to move: its marker is current, like the DEV daily's SHA.
        Looking it up under refs/heads/ would fail and its tree jobs would never start."""
        api = FakeApi([push_marker(origin="dispatch", branch="v1.2.3", ref_kind="tags")], branch_head=NEWER)
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["ref"], "v1.2.3")
        self.assertEqual(body["inputs"]["same_tree_origin"], "dispatch")
        for bad in (push_marker(origin="dispatch", branch="lane/x", ref_kind="pull"),
                    push_marker(origin="push", branch="v1", ref_kind="tags")):
            with self.subTest(marker=bad):
                self.assertEqual(run(FakeApi([bad])), 0)

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

    def test_a_fork_pull_requests_marker_starts_nothing(self):
        """Review of #39634 (comment 6744212258): a fork pull request's run executes the fork's workflow file, so
        it can write any marker.json; its artifact (workflow_run.head_repository_id is the fork) is not trusted.
        The fork keeps its pull_request run; it gets no same-tree dispatch from its marker."""
        api = FakeApi([pr_marker(head_repo="someone/cmux")], artifact_runs=[FORK_RUN],
                      pr=pull(repo="someone/cmux"))
        self.assertEqual(run(api), 0)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [])

    def test_a_failed_publish_reports_red_and_keeps_the_marker(self):
        """A takeover run may still publish the key; its notify then dispatches green."""
        api = FakeApi([push_marker()])
        self.assertEqual(run(api, state="failed"), 1)
        [body] = api.dispatched
        self.assertEqual(body["inputs"]["same_tree_state"], "failed")
        self.assertIn("publish failed", body["inputs"]["same_tree_reason"])
        self.assertEqual(api.deleted, [])

    def test_a_cancelled_run_of_a_published_tree_starts_the_tree_jobs(self):
        """#23517: artifacts run 39630462696 ended cancelled (its notify-unpublished-tree job sent
        --state failed) while tree 3a3a9fbf's completion.json was on R2. completion.json is written
        last and once, so it, not the run's conclusion, says the tree is published."""
        api = FakeApi([pr_marker()])
        self.assertEqual(run(api, state="failed", completion=completion_json()), 1)
        [body] = api.dispatched
        self.assertEqual(body["inputs"]["same_tree_state"], "ready")
        self.assertNotIn("publish failed", body["inputs"]["same_tree_reason"])
        self.assertIn("completion.json", body["inputs"]["same_tree_reason"])
        self.assertEqual(api.deleted, [100])

    def test_a_cancelled_run_without_a_completion_record_still_reports_red(self):
        api = FakeApi([push_marker()])
        self.assertEqual(run(api, state="failed", completion=None), 1)
        [body] = api.dispatched
        self.assertEqual(body["inputs"]["same_tree_state"], "failed")
        self.assertEqual(api.deleted, [])

    def test_a_completion_record_for_another_key_or_without_binaries_is_not_trusted(self):
        for bad in (completion_json(key="e" * 40), {"key": KEY}, {"key": KEY, "binaries": ["x"]},
                    ["not", "an", "object"]):
            with self.subTest(completion=bad):
                api = FakeApi([push_marker()])
                self.assertEqual(run(api, state="failed", completion=bad), 1)
                [body] = api.dispatched
                self.assertEqual(body["inputs"]["same_tree_state"], "failed")
                self.assertEqual(api.deleted, [])

    def test_failed_pr_publication_is_a_named_skip_and_keeps_marker_for_recovery(self):
        api = FakeApi([pr_marker()])
        messages = []
        self.assertEqual(notify.notify(api, repo="o/r", key=KEY, state="failed", reason="HTTP 422",
                                       log=messages.append, fetch_completion=lambda _key: None), 0)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.deleted, [])
        self.assertIn("same-tree cmux-tui skipped", " ".join(messages))
        self.assertIn("no pin ref", " ".join(messages))
        # A later trusted publication can still start the PR's actual tests.
        self.assertEqual(run(api, state="ready"), 1)
        self.assertEqual(api.dispatched[0]["inputs"]["same_tree_state"], "ready")
        self.assertEqual(api.deleted, [100])

    def test_a_ready_publish_does_not_read_the_completion_record(self):
        def unexpected(_key):
            raise AssertionError("a ready notify reads no completion.json")
        api = FakeApi([push_marker()])
        self.assertEqual(notify.notify(api, repo="o/r", key=KEY, state="ready", reason="",
                                       log=lambda _line: None, fetch_completion=unexpected), 1)
        [body] = api.dispatched
        self.assertEqual(body["inputs"]["same_tree_state"], "ready")
        self.assertEqual(api.deleted, [100])

    def test_the_completion_record_is_read_from_the_tree_url(self):
        """A 404 (or any read error) is no record: the failed state stands."""
        seen = []

        def request(url, seconds):
            seen.append(url)
            self.assertEqual(seconds, notify.REQUEST_TIMEOUT_S)
            if "missing" in url:
                return 404, b"Not Found", {}
            if "truncated" in url:  # the connection drops mid-body
                raise http.client.IncompleteRead(b"{")
            if "timeout" in url:
                raise notify.RequestTimeout("no full answer")
            return 200, json.dumps(completion_json()).encode(), {}

        original = notify.deadline_http.request
        notify.deadline_http.request = request
        try:
            self.assertEqual(notify.fetch_completion(KEY), completion_json())
            self.assertTrue(seen[-1].startswith(f"https://files.cmux.com/cmux-tui/tree/{KEY}/completion.json?"))
            self.assertIsNone(notify.fetch_completion("missing"))
            self.assertIsNone(notify.fetch_completion("truncated"))
            self.assertIsNone(notify.fetch_completion("timeout"))
        finally:
            notify.deadline_http.request = original

    def test_a_failed_tree_is_reported_once_per_marker(self):
        """2026-11-02: tree 4e172926 could not build (a stale Cargo.lock on the base its commits came
        from), and every branch push cut from that base failed it again. Each failed notify
        re-dispatched the three `cmux-next base tier` markers it kept, about every 2 minutes for hours
        (runs 41383430152, 41384506675, 41389933894, ...). The run history is the record: a marker
        already reported after its upload is not dispatched again; a publication still starts it."""
        base = push_marker(origin="dispatch", tip_suite="base")
        api = FakeApi([base], branch_head=NEWER, runs=[{"name": "cmux-next",
                                                        "display_title": f"cmux-next base tier · {SHA}",
                                                        "created_at": EARLIER}])
        self.assertEqual(run(api, state="failed"), 1)
        self.assertEqual(api.dispatched[0]["inputs"]["same_tree_state"], "failed")
        for _ in range(5):
            self.assertEqual(run(api, state="failed"), 0)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(api.deleted, [])
        self.assertEqual(run(api, state="ready"), 1)
        self.assertEqual(api.dispatched[-1]["inputs"]["same_tree_state"], "ready")
        self.assertEqual(api.deleted, [100])

    def test_each_kind_of_marker_is_capped_by_its_own_run_name(self):
        for marker in (push_marker(), push_marker(origin="dispatch", tiers=["daemon"], tip_suite="daemon"),
                       push_marker(origin="dispatch", tip_suite="base"),
                       push_marker(dev_daily=True, dev_daily_sha=SHA),
                       push_marker(origin="dispatch", branch="v1.2.3", ref_kind="tags")):
            with self.subTest(marker=marker):
                api = FakeApi([marker])
                self.assertEqual(run(api, state="failed"), 1)
                self.assertEqual(run(api, state="failed"), 0)
                # Another commit's run of the same kind does not cap this one.
                other = FakeApi([marker], runs=[{"name": "cmux-next", "display_title": notify.run_name(dict(marker, sha=NEWER,
                                                                              dev_daily_sha=NEWER)),
                                                 "created_at": LATER}])
                self.assertEqual(run(other, state="failed"), 1)

    def test_a_marker_uploaded_again_is_reported_again(self):
        """A re-run of the deferring run uploads the marker anew (overwrite: true): one more report."""
        api = FakeApi([push_marker(origin="dispatch", tip_suite="base")], branch_head=NEWER)
        self.assertEqual(run(api, state="failed"), 1)
        api.artifacts[0]["created_at"] = "2026-11-02T05:00:30Z"  # after the first report
        self.assertEqual(run(api, state="failed"), 1)
        self.assertEqual(run(api, state="failed"), 0)

    def test_the_run_history_is_read_once_per_failed_notify_and_never_for_ready(self):
        markers = [push_marker(origin="dispatch", tip_suite="base", sha=sha, status_sha=sha)
                   for sha in ("1" * 40, "2" * 40, "3" * 40)]
        api = FakeApi(markers, branch_head=NEWER)
        self.assertEqual(run(api, state="failed"), 3)
        self.assertEqual(len(api.history_reads), 1)
        self.assertIn(f"created=%3E%3D{UPLOADED}&", api.history_reads[0])
        self.assertEqual(run(api, state="failed"), 0)
        self.assertEqual(len(api.history_reads), 2)
        self.assertEqual(run(api, state="ready"), 3)
        self.assertEqual(len(api.history_reads), 2)

    def test_the_run_name_is_read_from_display_title_or_name(self):
        """REST lists the evaluated run-name as display_title (and, with run-name set, as name)."""
        for run_record in ({"name": "cmux-next", "display_title": f"cmux-next base tier · {SHA}"},
                           {"name": f"cmux-next base tier · {SHA}"}):
            with self.subTest(run=run_record):
                api = FakeApi([push_marker(origin="dispatch", tip_suite="base")], branch_head=NEWER,
                              runs=[dict(run_record, created_at=LATER)])
                self.assertEqual(run(api, state="failed"), 0)
                self.assertEqual(api.dispatched, [])

    def test_an_unreadable_run_history_reports_as_before(self):
        """Without the record the red is still reported: a missing report hides a failure."""
        api = FakeApi([push_marker(origin="dispatch", tip_suite="base")], branch_head=NEWER, history_error=True)
        messages: list[str] = []
        for _ in range(2):
            notify.notify(api, repo="o/r", key=KEY, state="failed", reason="x", log=messages.append,
                          fetch_completion=lambda _key: None)
        self.assertEqual(len(api.dispatched), 2)
        self.assertTrue(any("could not read cmux-next.yml's run history" in line for line in messages))

    def test_the_failed_reason_names_the_tree(self):
        """cmux_next_same_tree_failed.py reads the key from the red run's reason, its only key input."""
        api = FakeApi([push_marker()])
        notify.notify(api, repo="o/r", key=KEY, state="failed", reason="the run ended without publishing",
                      log=lambda _line: None, fetch_completion=lambda _key: None)
        reason = api.dispatched[0]["inputs"]["same_tree_reason"]
        self.assertIn(f"tree {KEY}", reason)
        self.assertIn("ended without publishing", reason)
        named = FakeApi([push_marker()])
        run(named, state="failed")  # "publish failed: u3" names no tree: it is prefixed once
        self.assertEqual(named.dispatched[0]["inputs"]["same_tree_reason"].count(f"tree {KEY}"), 1)

    def test_a_publish_redispatches_every_tier_a_same_tree_run_reported_red(self):
        """2026-11-11, cmux#40449 at ec4a30d2: run 43009515785 reported the tree red for the daemon
        tests and the scheme compile. The tree's publication dispatched only the daemon tests (the pull
        request's marker); the scheme compile's red stayed. The red run leaves a reported marker
        (cmux_next_same_tree_failed.py), and the publication starts it with every tier."""
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import cmux_next_same_tree_failed as failed

        args = failed.parse(["--repo", "o/r", "--ref", "lane/x", "--reason", f"tree {KEY}: publish failed",
                             "--commit", HEAD, "--status-sha", HEAD, "--tiers", "daemon,scheme",
                             "--origin", "dispatch", "--origin-run", "11"])
        reported = failed.reported_marker(args, KEY, "43009515785")
        api = FakeApi([pr_marker(), reported], branch_head=HEAD)
        self.assertEqual(run(api), 2)
        tiers = {body["inputs"]["same_tree_origin"]: body["inputs"]["same_tree_tiers"] for body in api.dispatched}
        self.assertEqual(tiers, {"pull_request": "daemon", "dispatch": "daemon,scheme"})
        scheme = next(body for body in api.dispatched if body["inputs"]["same_tree_origin"] == "dispatch")
        self.assertEqual((scheme["ref"], scheme["inputs"]["same_tree_status_sha"]), ("lane/x", HEAD))
        self.assertEqual(scheme["inputs"]["same_tree_state"], "ready")
        self.assertEqual(sorted(api.deleted), [100, 101])

    def test_a_reported_marker_is_never_reported_red_again(self):
        """Its red is posted; only a publication starts it (no red loop on a key that cannot build)."""
        api = FakeApi([push_marker(reported=True, reported_run=5)])
        for _ in range(3):
            self.assertEqual(run(api, state="failed"), 0)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.deleted, [])
        self.assertEqual(run(api, state="ready"), 1)
        self.assertEqual(api.dispatched[0]["inputs"]["same_tree_tiers"], "daemon,scheme")
        self.assertIsNone(notify.read_marker(FakeApi([push_marker(reported="yes")]),
                                             {"archive_download_url": "zip/100"}, KEY))

    def test_markers_of_one_run_start_it_once_with_every_tier(self):
        """The marker that started a red run and the red run's reported marker are one same-tree run."""
        api = FakeApi([push_marker(tiers=["daemon"]), push_marker(tiers=["scheme"], reported=True)])
        self.assertEqual(run(api), 1)
        [body] = api.dispatched
        self.assertEqual(body["inputs"]["same_tree_tiers"], "daemon,scheme")
        self.assertEqual(sorted(api.deleted), [100, 101])
        failed = FakeApi([push_marker(tiers=["daemon"]), push_marker(tiers=["daemon"])])
        self.assertEqual(run(failed, state="failed"), 1)

    def test_a_malformed_marker_is_ignored(self):
        for bad in (push_marker(sha="not-a-sha"), push_marker(key="e" * 40), push_marker(tiers=["rm -rf"]),
                    push_marker(origin="schedule"), pr_marker(pr="7; true")):
            with self.subTest(marker=bad):
                api = FakeApi([bad])
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])



class SupersededSameTreeRuns(unittest.TestCase):
    """2026-11-09 13:30Z: 14 same-tree runs of pull requests whose heads had moved on waited in the Mac
    queue (glaeda-side-std-xcode-26.6: 11 runners, 100 queued jobs), each only for its `cmux app scheme
    compile (Debug)`; lane/review-from-link alone had 3 (42607592895, 42613668792, 42620815281). Each
    same-tree run has a concurrency group of its own, and is_current() is read only at the dispatch.
    After a dispatch for a pull request, the older open first-attempt same-tree runs of that pull request
    with no Mac job running are the candidates: the newest run and the OLDEST candidate (its queued job is
    nearest a runner, so verdicts keep coming when the Mac wait is longer than the push interval) are
    kept, the other candidates are cancelled."""

    def test_the_oldest_candidate_and_the_newest_run_are_kept_and_the_middle_ones_cancelled(self):
        older = [open_run(501, 1), open_run(502, 2), open_run(503, 3), open_run(504, 4)]
        api = FakeApi([pr_marker()], runs=older)
        self.assertEqual(run(api), 1)
        newest = api.runs[-1]["id"]
        self.assertEqual(sorted(api.cancelled), [502, 503, 504])
        self.assertNotIn(501, api.cancelled)
        self.assertNotIn(newest, api.cancelled)

    def test_a_run_whose_mac_job_is_running_is_never_cancelled(self):
        older = [open_run(501, 1, status="in_progress"), open_run(502, 2), open_run(503, 3), open_run(504, 4)]
        api = FakeApi([pr_marker()], runs=older, jobs={501: same_tree_jobs(mac="in_progress"),
                                                       503: same_tree_jobs(mac="in_progress")})
        self.assertEqual(run(api), 1)
        # 501 and 503 run a Mac job; 502 is the oldest candidate; only 504 goes.
        self.assertEqual(api.cancelled, [504])

    def test_one_older_run_is_the_oldest_candidate_and_stays(self):
        api = FakeApi([pr_marker()], runs=[open_run(501, 1)])
        self.assertEqual(run(api), 1)
        self.assertEqual(api.cancelled, [])

    def test_another_pull_requests_runs_are_left_alone(self):
        others = [open_run(601, 1, branch="lane/y"), open_run(602, 2, branch="lane/y"),
                  open_run(603, 3, branch="lane/y")]
        mine = [open_run(501, 4), open_run(502, 5), open_run(503, 6)]
        api = FakeApi([pr_marker()], runs=others + mine)
        self.assertEqual(run(api), 1)
        self.assertEqual(sorted(api.cancelled), [502, 503])

    def test_base_tier_tip_suite_dev_daily_and_plain_dispatch_runs_are_left_alone(self):
        runs = [open_run(501, 1),
                open_run(701, 3, title=f"cmux-next base tier · {'7' * 40}", sha="7" * 40),
                open_run(702, 4, title=f"cmux-next tip daemon suite · {'7' * 40}", sha="7" * 40),
                open_run(703, 5, title=f"cmux-next tip Swift suite · {'7' * 40}", sha="7" * 40),
                open_run(704, 6, title=f"cmux NEXT DEV daily · {'7' * 40}", sha="7" * 40),
                open_run(705, 7, title=f"cmux-next uncached · {'7' * 40}", sha="7" * 40),
                # A plain dispatch on the branch (its own routing), a push run and a re-run attempt.
                open_run(706, 8),
                open_run(707, 9, event="push"),
                open_run(708, 10, run_attempt=2),
                open_run(503, 11)]
        api = FakeApi([pr_marker()], runs=runs, jobs={706: plain_dispatch_jobs()})
        self.assertEqual(run(api), 1)
        self.assertEqual(api.cancelled, [503])

    def test_finished_runs_are_not_candidates(self):
        runs = [open_run(501, 1, status="completed", conclusion="success"), open_run(502, 2), open_run(503, 3)]
        api = FakeApi([pr_marker()], runs=runs)
        self.assertEqual(run(api), 1)
        # 502 is the oldest open candidate.
        self.assertEqual(api.cancelled, [503])

    def test_unreadable_jobs_keep_the_run(self):
        class JobsDown(FakeApi):
            def get(self, path):
                if "/jobs?" in path and "/runs/503/" in path:
                    raise RuntimeError("HTTP 502")
                return super().get(path)
        api = JobsDown([pr_marker()], runs=[open_run(501, 1), open_run(502, 2), open_run(503, 3)])
        self.assertEqual(run(api), 1)
        self.assertEqual(api.cancelled, [502])

    def test_push_and_fork_dispatches_cancel_nothing(self):
        """A push's same-tree run is the base's verdict, and a fork's runs on feat-cmux-next under the base
        tip's name, so neither names its pull request; only a pull request's head-branch run is swept."""
        tip_runs = [open_run(501, 1, branch="feat-cmux-next"), open_run(502, 2, branch="feat-cmux-next"),
                    open_run(503, 3, branch="feat-cmux-next")]
        api = FakeApi([push_marker()], runs=[dict(item) for item in tip_runs])
        self.assertEqual(run(api), 1)
        self.assertEqual(api.cancelled, [])
        # A same-repository run whose pull request GitHub says comes from a fork (the marker names it).
        api = FakeApi([pr_marker(head_repo="someone/cmux")], runs=[dict(item) for item in tip_runs],
                      pr=pull(repo="someone/cmux"))
        run(api)
        self.assertEqual(api.cancelled, [])

    def test_a_fork_branch_named_like_the_base_sweeps_nothing(self):
        """Review of #39634 (comment 6742425555): a fork pull request is dispatched on its base branch. When
        the fork's branch is also named feat-cmux-next, the base branch's same-tree runs (every fork pull
        request's and the push verdicts) must not be swept."""
        tip_runs = [open_run(501, 1, branch="feat-cmux-next"), open_run(502, 2, branch="feat-cmux-next"),
                    open_run(503, 3, branch="feat-cmux-next")]
        marker = pr_marker(head_repo="someone/cmux", head_ref="feat-cmux-next")
        for fork_run in (FORK_RUN, None):
            with self.subTest(artifact_run=fork_run):
                api = FakeApi([marker], runs=[dict(item) for item in tip_runs], artifact_runs=[fork_run],
                              pr=pull(ref="feat-cmux-next", repo="someone/cmux"))
                run(api)
                self.assertEqual(api.cancelled, [])
                stale = FakeApi([marker], runs=[dict(item) for item in tip_runs], artifact_runs=[fork_run],
                                pr=pull(NEWER, ref="feat-cmux-next", repo="someone/cmux"))
                self.assertEqual(run(stale), 0)
                self.assertEqual(stale.cancelled, [])

    def test_a_run_of_the_pull_requests_head_is_never_cancelled(self):
        """Review of #39634: two markers of one head (a re-run, other routing) give two runs of that head,
        perhaps with other tiers; the older may carry the only scheme compile of the head."""
        older = [open_run(501, 1), open_run(502, 2, sha=HEAD), open_run(503, 3), open_run(504, 4)]
        api = FakeApi([pr_marker()], runs=older)
        self.assertEqual(run(api), 1)
        self.assertEqual(sorted(api.cancelled), [503, 504])

    def test_a_superseded_marker_sweeps_its_branch_too(self):
        """A marker whose pull request head moved on dispatches nothing and is deleted; its branch's older
        same-tree runs get the same rule (keep the newest run, the head's runs and the oldest candidate)."""
        runs = [open_run(501, 1), open_run(502, 2), open_run(503, 3), open_run(504, 4, sha=NEWER)]
        api = FakeApi([pr_marker()], runs=runs, pr=pull(NEWER))
        self.assertEqual(run(api), 0)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.deleted, [100])
        self.assertEqual(sorted(api.cancelled), [502, 503])

    def test_several_superseded_markers_of_one_branch_sweep_it_once(self):
        runs = [open_run(501, 1), open_run(502, 2), open_run(503, 3), open_run(504, 4, sha=NEWER)]
        markers = [pr_marker(), pr_marker(status_sha="e" * 40, run_id=13)]
        api = FakeApi(markers, runs=runs, pr=pull(NEWER))
        self.assertEqual(run(api), 0)
        self.assertEqual(api.deleted, [100, 101])
        self.assertEqual(sorted(api.cancelled), [502, 503])

    # Review of #39634 (comment 6744212258): a fork pull request's run can write any marker.json, so the sweep
    # and the dispatch read what GitHub records (the artifact's run, pulls/<n>), never the marker's claims.
    FORGED = dict(head_repo="o/r", head_ref="feat-cmux-next", base_ref="x")

    def tip_runs(self) -> list[dict]:
        return [open_run(run_id, minute, branch="feat-cmux-next") for minute, run_id in enumerate((501, 502, 503, 504), 1)]

    def test_a_forged_marker_sweeps_nothing_on_the_dispatch_path(self):
        api = FakeApi([pr_marker(**self.FORGED)], runs=self.tip_runs(), artifact_runs=[FORK_RUN],
                      pr=pull(repo="someone/cmux"))
        run(api)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [])

    def test_a_forged_marker_sweeps_nothing_on_the_superseded_path(self):
        api = FakeApi([pr_marker(**self.FORGED)], runs=self.tip_runs(), artifact_runs=[FORK_RUN],
                      pr=pull(state="closed", repo="someone/cmux"))
        self.assertEqual(run(api), 0)
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [])

    def test_a_forged_marker_starts_no_same_tree_run_on_another_branch(self):
        """dispatch_refs reads the marker's head_ref: a fork run's marker must never get that far."""
        for marker in (pr_marker(head_repo="o/r", head_ref="lane/victim"), pr_marker(**self.FORGED),
                       push_marker(), push_marker(origin="dispatch", tip_suite="base"),
                       push_marker(origin="dispatch", branch="lane/victim")):
            with self.subTest(marker=marker):
                api = FakeApi([marker], artifact_runs=[FORK_RUN], branch_head=SHA, pr=pull(repo="someone/cmux"))
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])

    def test_a_missing_field_sweeps_nothing(self):
        cases = {
            "no head_repository_id": dict(artifact_runs=[{"head_repository_id": None}]),
            "no repository_id": dict(artifact_runs=[{"repository_id": None}]),
            "no head repo": dict(pr={"state": "open", "head": {"sha": HEAD, "ref": "lane/x"},
                                     "base": {"ref": "feat-cmux-next"}}),
            "no head ref": dict(pr={"state": "open", "head": {"sha": HEAD, "repo": {"full_name": "o/r"}},
                                    "base": {"ref": "feat-cmux-next"}}),
            "no base": dict(pr={"state": "open", "head": {"sha": HEAD, "ref": "lane/x", "repo": {"full_name": "o/r"}}}),
            "head ref is not the marker's": dict(pr=pull(ref="lane/other")),
            "head ref is the base ref": dict(pr=pull(ref="lane/x", base="lane/x")),
        }
        for name, extra in cases.items():
            with self.subTest(case=name):
                api = FakeApi([pr_marker()], runs=[open_run(501, 1), open_run(502, 2), open_run(503, 3)], **extra)
                run(api)
                self.assertEqual(api.cancelled, [])

    def test_a_head_branch_main_or_feat_cmux_next_sweeps_nothing(self):
        """Push-origin same-tree runs (the base verdicts) run on main and feat-cmux-next."""
        for head_ref, base_ref in (("main", "feat-cmux-next"), ("feat-cmux-next", "main")):
            with self.subTest(head_ref=head_ref):
                runs = [open_run(run_id, minute, branch=head_ref) for minute, run_id in enumerate((501, 502, 503), 1)]
                marker = pr_marker(head_ref=head_ref, base_ref=base_ref)
                for pr in (pull(ref=head_ref, base=base_ref), pull(NEWER, ref=head_ref, base=base_ref)):
                    api = FakeApi([marker], runs=[dict(item) for item in runs], pr=pr)
                    run(api)
                    self.assertEqual(api.cancelled, [])

    def test_fork_markers_do_not_fill_the_marker_slots(self):
        """Review of #39634 (comment 6745208604): fork markers are skipped, so they must be dropped before the
        MAX_MARKERS cut. Otherwise 50 newer fork markers (GitHub lists the newest first) hide a same-repository
        marker: its run is neither dispatched nor swept."""
        markers = [pr_marker(**self.FORGED, run_id=1000 + index) for index in range(notify.MAX_MARKERS + 5)]
        markers.append(pr_marker())
        api = FakeApi(markers, runs=[open_run(501, 1), open_run(502, 2), open_run(503, 3)],
                      artifact_runs=[FORK_RUN] * (len(markers) - 1) + [None])
        self.assertEqual(run(api), 1)
        self.assertEqual([body["ref"] for body in api.dispatched], ["lane/x"])
        self.assertEqual(sorted(api.cancelled), [502, 503])

    def test_an_artifact_without_a_run_is_skipped_and_the_rest_is_swept(self):
        """Older artifacts list `workflow_run: null`; reading its id must not end the notify."""
        api = FakeApi([pr_marker(run_id=13), pr_marker()],
                      runs=[open_run(501, 1), open_run(502, 2), open_run(503, 3)])
        api.artifacts[0]["workflow_run"] = None
        self.assertEqual(run(api), 1)
        self.assertEqual(sorted(api.cancelled), [502, 503])

    def test_a_marker_naming_another_head_branch_than_its_run_starts_nothing(self):
        """dispatch_refs reads the marker's head_ref; GitHub records the run's branch (workflow_run.head_branch).
        A pull request marker whose head_ref is not that branch starts no run on another branch."""
        for head_branch in ("lane/x", None):
            with self.subTest(head_branch=head_branch):
                api = FakeApi([pr_marker(head_ref="lane/victim")], artifact_runs=[{"head_branch": head_branch}],
                              runs=[open_run(501, 1, branch="lane/victim"), open_run(502, 2, branch="lane/victim"),
                                    open_run(503, 3, branch="lane/victim")])
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])
                self.assertEqual(api.cancelled, [])

    def test_an_unreadable_run_list_cancels_nothing_and_still_dispatches(self):
        class ListDown(FakeApi):
            def get(self, path):
                if "runs?branch=" in path:
                    raise RuntimeError("HTTP 403")
                return super().get(path)
        api = ListDown([pr_marker()], runs=[open_run(501, 1), open_run(502, 2), open_run(503, 3)])
        messages: list[str] = []
        self.assertEqual(notify.notify(api, repo="o/r", key=KEY, state="ready", reason="", log=messages.append,
                                       fetch_completion=lambda _key: None), 1)
        self.assertEqual(api.cancelled, [])
        self.assertTrue(any("superseded same-tree" in line for line in messages), messages)


if __name__ == "__main__":
    unittest.main()
