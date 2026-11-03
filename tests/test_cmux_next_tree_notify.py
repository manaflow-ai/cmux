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
                 refuse_refs: tuple[str, ...] = (), runs: list[dict] | None = None,
                 history_error: bool = False):
        self.artifacts = [
            {"id": 100 + index, "name": f"cmux-next-tree-wait-{KEY}", "expired": False,
             "created_at": UPLOADED,
             "archive_download_url": f"zip/{100 + index}", "workflow_run": {"id": marker.get("run_id")}}
            for index, marker in enumerate(markers)
        ]
        self.zips = {f"zip/{100 + index}": marker_zip(marker) for index, marker in enumerate(markers)}
        self.branch_head = branch_head
        self.pr = pr if pr is not None else {"state": "open", "head": {"sha": HEAD}}
        self.refuse_refs = refuse_refs
        self.dispatched: list[dict] = []
        self.deleted: list[int] = []
        # cmux-next.yml's dispatch runs; each accepted dispatch adds one, as GitHub does.
        self.runs = list(runs or [])
        self.history_error = history_error
        self.history_reads: list[str] = []

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
        raise AssertionError(f"unexpected GET {path}")

    def download(self, url: str) -> bytes:
        return self.zips[url]

    def post(self, path: str, body: dict) -> int:
        assert path == "repos/o/r/actions/workflows/cmux-next.yml/dispatches", path
        if body["ref"] in self.refuse_refs:
            return 422
        self.dispatched.append(body)
        inputs = body["inputs"]
        sha = inputs["same_tree_sha"]
        name = (f"cmux NEXT DEV daily · {inputs['dev_daily_sha']}" if inputs.get("dev_daily") == "true"
                else f"cmux-next tip daemon suite · {sha}" if inputs.get("tip_daemon_suite") == "true"
                else f"cmux-next base tier · {sha}" if inputs.get("base_tier") == "true"
                else f"cmux-next · {sha}")
        # GitHub's clock moves on: each dispatch is created after everything before it.
        # As the REST API lists it: the evaluated run-name in display_title (and here a static `name`).
        self.runs.append({"name": "cmux-next", "display_title": name,
                          "created_at": f"2026-11-02T05:{len(self.runs):02d}:00Z"})
        return 204

    def delete(self, path: str) -> int:
        self.deleted.append(int(path.rsplit("/", 1)[1]))
        return 204


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

        class Response(io.BytesIO):
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            seen.append(request.full_url)
            if "missing" in seen[-1]:
                raise notify.urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, None)
            if "truncated" in seen[-1]:  # the connection drops mid-body
                raise http.client.IncompleteRead(b"{")
            return Response(json.dumps(completion_json()).encode())

        original = notify.urllib.request.urlopen
        notify.urllib.request.urlopen = urlopen
        try:
            self.assertEqual(notify.fetch_completion(KEY), completion_json())
            self.assertTrue(seen[-1].startswith(f"https://files.cmux.com/cmux-tui/tree/{KEY}/completion.json?"))
            self.assertIsNone(notify.fetch_completion("missing"))
            self.assertIsNone(notify.fetch_completion("truncated"))
        finally:
            notify.urllib.request.urlopen = original

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

    def test_a_malformed_marker_is_ignored(self):
        for bad in (push_marker(sha="not-a-sha"), push_marker(key="e" * 40), push_marker(tiers=["rm -rf"]),
                    push_marker(origin="schedule"), pr_marker(pr="7; true")):
            with self.subTest(marker=bad):
                api = FakeApi([bad])
                self.assertEqual(run(api), 0)
                self.assertEqual(api.dispatched, [])


if __name__ == "__main__":
    unittest.main()
