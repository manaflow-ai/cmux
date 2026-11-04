#!/usr/bin/env python3
"""The base autofix takes the Swift exports a push's generated-files job already built, or the Mac job
regenerates them (cmuxterm-hq#5424, "one compile per base tree").

scripts/cmux-next/base-autofix-exports-pack.sh packs every export on the generated-files job's own
package build, named after the commit's tree; scripts/cmux-next/base_autofix_pushed_exports.py takes a
pack only from this repository's own feat-cmux-next push runs with every digest intact, prefers the
newest commit up to the tip (as the Mac job regenerated on the newest tip), waits a bounded time for this
push's own pack, and otherwise misses so cmux-next-base-autofix.yml's Mac job runs as before.
"""

from __future__ import annotations

import hashlib
import http.server
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import base_autofix_pushed_exports as px  # noqa: E402

PACK_SCRIPT = ROOT / "scripts/cmux-next/base-autofix-exports-pack.sh"
AUTOFIX = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())
NEXT = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())
REPO, REPO_ID = "manaflow-ai/cmux", "123"
ENV = {"GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID}
NAMES = px.exports(ROOT)


def oid(n: int) -> str:
    return f"{n:040x}"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pack_zip(tree: str, run_id: int, head: str, files: dict[str, bytes] | None = None, **overrides) -> bytes:
    files = files if files is not None else {rel: f"fresh {rel}\n".encode() for rel in NAMES}
    manifest = {"schema": px.SCHEMA, "tree": tree, "run_id": run_id, "source_sha": head,
                "files": {rel: sha256(data) for rel, data in files.items()}}
    manifest.update(overrides)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        for rel, data in files.items():
            archive.writestr(rel, data)
    return buffer.getvalue()


def artifact(tree: str, run_id: int, ident: int, *, repo_id: str = REPO_ID, branch: str = px.BRANCH,
             expired: bool = False, created: str = "2026-10-30T12:00:00Z") -> dict:
    return {"id": ident, "name": px.pack_name(tree), "expired": expired, "created_at": created,
            "archive_download_url": f"https://api/artifacts/{ident}",
            "workflow_run": {"id": run_id, "repository_id": int(repo_id), "head_repository_id": int(repo_id),
                             "head_branch": branch}}


def push_run(run_id: int, head: str, **overrides) -> dict:
    run = {"id": run_id, "event": "push", "path": px.WORKFLOW_PATH, "head_branch": px.BRANCH, "head_sha": head,
           "display_title": f"cmux-next · {head}", "status": "completed", "repository": {"full_name": REPO},
           "head_repository": {"full_name": REPO}}
    run.update(overrides)
    return run


def base_tier_run(run_id: int, commit: str, head: str | None = None, **overrides) -> dict:
    """cmux-next-base-tier-kick.yml's dispatch; a same-tree rerun's head is the newer tip."""
    return push_run(run_id, head or commit, event="workflow_dispatch", display_title=f"cmux-next base tier · {commit}",
                    **overrides)


class FakeApi(px.Api):
    """Artifacts by tree, runs by id, cmux-next push runs (with their jobs) by head commit, and a clock."""

    def __init__(self, *, packs=None, blobs=None, runs=None, listed=None, jobs=None, wait=600.0):
        self.packs, self.blobs, self.runs = packs or {}, blobs or {}, runs or {}
        # The branch's cmux-next.yml runs, newest first (actions/workflows/cmux-next.yml/runs).
        self.listed, self.jobs = listed or [], jobs or {}
        self.now, self.deadline = 0.0, wait
        self.calls: list[str] = []
        self.on_sleep = None

    def left(self) -> float:
        return self.deadline - self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds
        if self.on_sleep:
            self.on_sleep(self)

    def json(self, path: str) -> dict:
        self.calls.append(path)
        if path.startswith("actions/artifacts?"):
            name = path.split("name=")[1].split("&")[0]
            return {"artifacts": [a for tree, items in self.packs.items() for a in items if px.pack_name(tree) == name]}
        if path.startswith("actions/workflows/"):
            assert f"branch={px.BRANCH}" in path
            return {"workflow_runs": self.listed}
        run_id = int(path.split("/")[2].split("?")[0])
        if "/jobs" in path:
            return {"jobs": self.jobs.get(run_id, [])}
        if run_id not in self.runs:
            raise px.Miss(f"GET actions/runs/{run_id} failed: HTTP 404")
        return self.runs[run_id]

    def download(self, url: str, dest: Path) -> None:
        self.calls.append(url)
        dest.write_bytes(self.blobs[int(url.rsplit("/", 1)[1])])


def lookup(api: FakeApi, history, sha: str, tree: str, into: Path, **kw):
    return px.lookup(api, lambda: history, sha, tree, ENV, NAMES, into, poll=60, first_run_grace=kw.get("grace", 0))


class ConditionalApiReads(unittest.TestCase):
    """Exercise urllib's real 304/HTTPError path against an ephemeral HTTP origin."""

    def setUp(self):
        self.responses = {}
        self.requests = []
        responses, requests = self.responses, self.requests

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                status, etag, body = responses.get(self.path, (404, None, b"missing"))
                conditional = self.headers.get("If-None-Match")
                if status == 200 and etag and conditional == etag:
                    status = 304
                requests.append((self.path, conditional, status))
                self.send_response(status)
                if etag:
                    self.send_header("ETag", etag)
                self.end_headers()
                if status != 304:
                    self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.api = self.new_api()

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.assertFalse(self.thread.is_alive())

    def new_api(self):
        return px.Api("synthetic-read-token", REPO, self.base, time.monotonic() + 60)

    def reply(self, path, data=None, *, etag='"v1"', status=200, body=None):
        self.responses[f"/repos/{REPO}/{path}"] = (status, etag, body if body is not None else json.dumps(data).encode())

    def test_thirty_unchanged_polls_revalidate_five_endpoints(self):
        # The existing 45-minute / 90-second wait, with one runs and four jobs reads per poll.
        paths = [f"actions/workflows/{px.WORKFLOW_FILE}/runs?branch={px.BRANCH}&per_page=50",
                 *[f"actions/runs/{run_id}/jobs?filter=latest&per_page=100" for run_id in range(1, 5)]]
        for path in paths:
            self.reply(path, {"status": "in_progress", "path": path})
        for _ in range(30):
            for path in paths:
                self.assertEqual(self.api.json(path), {"status": "in_progress", "path": path})
        counts = {"requests": len(self.requests), "charged_200": sum(r[2] == 200 for r in self.requests),
                  "revalidated_304": sum(r[2] == 304 for r in self.requests)}
        print("pushed-exports conditional-read harness: " + json.dumps(counts, sort_keys=True))
        self.assertEqual(counts, {"requests": 150, "charged_200": 5, "revalidated_304": 145})

    def test_changed_jobs_are_returned_on_the_next_read_and_mutation_is_not_retained(self):
        path = "actions/runs/7/jobs?filter=latest&per_page=100"
        self.reply(path, {"jobs": [{"status": "in_progress"}]})
        self.api.json(path)["jobs"].clear()
        self.assertEqual(self.api.json(path), {"jobs": [{"status": "in_progress"}]})
        self.reply(path, {"jobs": [{"status": "completed"}]}, etag='"v2"')
        self.assertEqual(self.api.json(path), {"jobs": [{"status": "completed"}]})
        self.assertEqual(self.api.json(path), {"jobs": [{"status": "completed"}]})
        self.assertEqual([r[2] for r in self.requests], [200, 304, 200, 304])

    def test_lookup_takes_a_new_pack_after_unchanged_304_reads(self):
        sha, tree = oid(1), oid(101)
        run = push_run(7, sha, status="in_progress")
        runs_path = f"actions/workflows/{px.WORKFLOW_FILE}/runs?branch={px.BRANCH}&per_page=50"
        jobs_path = "actions/runs/7/jobs?filter=latest&per_page=100"
        packs_path = f"actions/artifacts?name={px.pack_name(tree)}&per_page=10"
        self.reply(runs_path, {"workflow_runs": [run]})
        self.reply(jobs_path, {"jobs": [{"name": px.GENERATED_JOB, "status": "in_progress"}]})
        self.reply(packs_path, {"artifacts": []})
        self.reply("actions/runs/7", run)
        sleeps = []

        def publish_after_one_unchanged_poll(seconds):
            sleeps.append(seconds)
            if len(sleeps) == 2:
                self.reply(jobs_path, {"jobs": [{"name": px.GENERATED_JOB, "status": "in_progress",
                                                "steps": [{"name": px.UPLOAD_STEP, "status": "completed"}]}]}, etag='"v2"')
                self.reply(packs_path, {"artifacts": [artifact(tree, 7, 70)]}, etag='"v2"')

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(self.api, "sleep", side_effect=publish_after_one_unchanged_poll), \
                mock.patch.object(self.api, "download", side_effect=lambda _url, dest: dest.write_bytes(pack_zip(tree, 7, sha))):
            into = Path(scratch) / "into"
            hit = px.lookup(self.api, lambda: [(sha, tree)], sha, tree, ENV, NAMES, into, poll=1, first_run_grace=0)
            self.assertEqual(hit["hit"], "true")
            self.assertEqual(hit["source_run_id"], "7")
            for rel in NAMES:
                self.assertEqual((into / rel).read_bytes(), f"fresh {rel}\n".encode())
        self.assertEqual(sleeps, [1, 1])
        self.assertIn(304, [r[2] for r in self.requests])

    def test_an_etag_removed_by_the_server_is_not_sent_again(self):
        path = "actions/runs/7"
        self.reply(path, {"status": "in_progress"})
        self.api.json(path)
        self.reply(path, {"status": "completed"}, etag=None)
        for _ in range(2):
            self.assertEqual(self.api.json(path), {"status": "completed"})
        self.assertEqual([r[1] for r in self.requests], [None, '"v1"', None])

    def test_cache_is_scoped_to_one_api_instance_and_exact_query(self):
        for path in ("actions/artifacts?name=one", "actions/artifacts?name=two"):
            self.reply(path, {"name": path})
            self.assertEqual(self.api.json(path), {"name": path})
        self.new_api().json("actions/artifacts?name=one")
        self.assertEqual([r[1] for r in self.requests], [None, None, None])

    def test_http_errors_never_fall_back_to_cached_success_or_include_response_bodies(self):
        path = "actions/runs/7"
        self.reply(path, {"status": "in_progress"})
        self.api.json(path)
        for status in (403, 404, 429, 500):
            with self.subTest(status=status):
                self.reply(path, status=status, body=b"secret-bearing-error-body")
                with self.assertRaises(px.Miss) as caught:
                    self.api.json(path)
                self.assertIn(f"GET {path} failed: HTTP Error {status}", str(caught.exception))
                self.assertNotIn("secret-bearing", str(caught.exception))

    def test_304_without_a_retained_response_is_a_miss(self):
        self.reply("actions/runs/7", status=304)
        with self.assertRaisesRegex(px.Miss, "HTTP Error 304"):
            self.api.json("actions/runs/7")

    def test_invalid_or_oversized_json_is_still_a_miss(self):
        path = "actions/runs/7"
        self.reply(path, {"status": "in_progress"})
        self.api.json(path)
        self.reply(path, etag='"v2"', body=b"not JSON")
        with self.assertRaisesRegex(px.Miss, "answered no JSON"):
            self.api.json(path)
        with mock.patch.object(px, "MAX_JSON_BYTES", 16):
            self.reply(path, etag='"v3"', body=b"x" * 17)
            with self.assertRaisesRegex(px.Miss, "answered over 16 bytes"):
                self.api.json(path)

    def test_entry_and_byte_budgets_evict_responses(self):
        for limit in ("JSON_CACHE_ENTRIES", "JSON_CACHE_BYTES"):
            with self.subTest(limit=limit), mock.patch.object(px, limit, 2, create=True):
                api = self.new_api()
                self.requests.clear()
                for path in ("actions/runs/1", "actions/runs/2", "actions/runs/3", "actions/runs/1"):
                    self.reply(path, {"id": path})
                    self.assertEqual(api.json(path), {"id": path})
                self.assertTrue(all(r[2] == 200 for r in self.requests))


class TakesOnlyTrustedIntactPacks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.into = Path(self.tmp.name) / "into"
        self.sha, self.tree = oid(1), oid(101)

    def tearDown(self):
        self.tmp.cleanup()

    def api_with(self, blob: bytes, *, run=None, art=None) -> FakeApi:
        return FakeApi(packs={self.tree: [art or artifact(self.tree, 7, 70)]}, blobs={70: blob},
                       runs={7: run or push_run(7, self.sha)})

    def test_a_pack_of_this_commit_is_taken_and_unpacked(self):
        api = self.api_with(pack_zip(self.tree, 7, self.sha))
        hit = lookup(api, [(self.sha, self.tree)], self.sha, self.tree, self.into)
        self.assertEqual(hit["hit"], "true")
        self.assertEqual(hit["made_at"], self.sha)
        self.assertEqual(hit["source_run_id"], "7")
        for rel in NAMES:
            self.assertEqual((self.into / rel).read_bytes(), f"fresh {rel}\n".encode())

    def assert_miss(self, api: FakeApi, why: str):
        with self.assertRaises(px.Miss) as caught:
            lookup(api, [(self.sha, self.tree)], self.sha, self.tree, self.into)
        self.assertIn(why, str(caught.exception))
        self.assertFalse(self.into.exists(), "a refused pack must leave nothing behind")

    def test_a_file_that_does_not_match_its_digest_is_refused(self):
        files = {rel: b"fresh\n" for rel in NAMES}
        blob = pack_zip(self.tree, 7, self.sha, files)
        tampered = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(blob)) as source, zipfile.ZipFile(tampered, "w") as sink:
            for info in source.infolist():
                data = source.read(info.filename)
                sink.writestr(info.filename, b"replaced\n" if info.filename == NAMES[-1] else data)
        self.assert_miss(self.api_with(tampered.getvalue()), "does not match the pack's digest")

    def test_a_pack_missing_an_export_is_refused(self):
        files = {rel: b"x" for rel in NAMES[:-1]}
        self.assert_miss(self.api_with(pack_zip(self.tree, 7, self.sha, files)), "exactly the exports")

    def test_a_manifest_of_another_tree_or_run_is_refused(self):
        self.assert_miss(self.api_with(pack_zip(oid(999), 7, self.sha)), "another tree")
        self.assert_miss(self.api_with(pack_zip(self.tree, 8, self.sha)), "another run")

    def test_a_pack_whose_commit_is_not_its_runs_head_is_refused(self):
        self.assert_miss(self.api_with(pack_zip(self.tree, 7, oid(2))), "not the commit of the run")

    def test_only_push_runs_of_cmux_next_on_the_branch_in_this_repository(self):
        blob = pack_zip(self.tree, 7, self.sha)
        cases = {
            "not a push": push_run(7, self.sha, event="pull_request"),
            "not .github/workflows/cmux-next.yml": push_run(7, self.sha, path=".github/workflows/other.yml"),
            "this repository's own": push_run(7, self.sha, head_repository={"full_name": "fork/cmux"}),
        }
        for why, run in cases.items():
            with self.subTest(why=why):
                self.assert_miss(self.api_with(blob, run=run), why.split(" on ")[0] if why != "not a push" else "not a push")

    def test_artifacts_of_forks_other_branches_or_expired_are_never_read(self):
        for art in (artifact(self.tree, 7, 70, repo_id="999"), artifact(self.tree, 7, 70, branch="main"),
                    artifact(self.tree, 7, 70, expired=True)):
            with self.subTest(art=art):
                api = self.api_with(pack_zip(self.tree, 7, self.sha), art=art)
                self.assert_miss(api, "none is coming")
                self.assertFalse(any(call.startswith("https://") for call in api.calls), "nothing downloaded")

    def test_no_repository_id_trusts_nothing(self):
        api = self.api_with(pack_zip(self.tree, 7, self.sha))
        with self.assertRaises(px.Miss):
            px.lookup(api, lambda: [], self.sha, self.tree, {"GITHUB_REPOSITORY": REPO}, NAMES, self.into, 60, 0)


class PrefersTheNewestPackUpToTheTip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.into = Path(self.tmp.name) / "into"
        # The tip's first-parent line, newest first: tip (3), 2, the run's commit (1), an older one (0).
        self.history = [(oid(3), oid(103)), (oid(2), oid(102)), (oid(1), oid(101)), (oid(0), oid(100))]

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_newer_commits_pack_is_taken_and_named_as_made_at(self):
        api = FakeApi(packs={oid(102): [artifact(oid(102), 9, 90)], oid(101): [artifact(oid(101), 7, 70)]},
                      blobs={90: pack_zip(oid(102), 9, oid(2)), 70: pack_zip(oid(101), 7, oid(1))},
                      runs={9: push_run(9, oid(2)), 7: push_run(7, oid(1))})
        hit = lookup(api, self.history, oid(1), oid(101), self.into)
        self.assertEqual(hit["made_at"], oid(2))
        self.assertEqual(hit["source_run_id"], "9")

    def test_an_older_commits_pack_is_never_taken(self):
        api = FakeApi(packs={oid(100): [artifact(oid(100), 5, 50)]}, blobs={50: pack_zip(oid(100), 5, oid(0))},
                      runs={5: push_run(5, oid(0))})
        with self.assertRaises(px.Miss):
            lookup(api, self.history, oid(1), oid(101), self.into)

    def test_candidates_are_bounded_and_end_with_the_run_commit(self):
        history = [(oid(n), oid(100 + n)) for n in range(30, 0, -1)]
        got = px.candidates(history, oid(1), oid(101))
        self.assertEqual(len(got), px.NEWER_CANDIDATES + 1)
        self.assertEqual(got[0], (oid(30), oid(130)))
        self.assertEqual(got[-1], (oid(1), oid(101)))

    def test_a_commit_the_history_does_not_reach_looks_only_at_itself(self):
        self.assertEqual(px.candidates([], oid(1), oid(101)), [(oid(1), oid(101))])
        self.assertEqual(px.candidates(self.history[:1], oid(1), oid(101)), [(oid(1), oid(101))])


class WaitsABoundedTimeThenFallsBack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.into = Path(self.tmp.name) / "into"
        self.sha, self.tree = oid(1), oid(101)
        self.history = [(self.sha, self.tree)]

    def tearDown(self):
        self.tmp.cleanup()

    def test_it_waits_for_this_pushs_generated_files_job_and_takes_its_pack(self):
        run = push_run(7, self.sha, status="in_progress")
        api = FakeApi(listed=[run], jobs={7: [{"name": px.GENERATED_JOB, "status": "in_progress"}]},
                      runs={7: push_run(7, self.sha)}, blobs={70: pack_zip(self.tree, 7, self.sha)}, wait=2700)

        def finish(fake):
            if fake.now >= 600:  # the job finishes and uploads ten minutes in
                fake.jobs[7] = [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "success"}]
                fake.packs[self.tree] = [artifact(self.tree, 7, 70)]
        api.on_sleep = finish
        hit = lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertEqual(hit["hit"], "true")
        self.assertLessEqual(api.now, 600 + 90)
        # A poll reads the run list and one jobs list; artifacts only once the producer is done.
        self.assertEqual(len([c for c in api.calls if c.startswith("actions/artifacts?")]), 2)

    def test_a_folded_daemon_test_pack_is_taken_once_its_upload_step_is_done(self):
        upload = {"name": px.UPLOAD_STEP, "status": "queued"}
        api = FakeApi(listed=[push_run(7, self.sha, status="in_progress")],
                      jobs={7: [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "skipped"},
                                {"name": px.DAEMON_JOB, "status": "in_progress", "steps": [upload]}]},
                      runs={7: push_run(7, self.sha)}, blobs={70: pack_zip(self.tree, 7, self.sha)}, wait=2700)

        def upload_done(fake):
            if fake.now >= 300:  # the daemon tests go on for another 20 minutes after this
                upload["status"], upload["conclusion"] = "completed", "success"
                fake.packs[self.tree] = [artifact(self.tree, 7, 70)]
        api.on_sleep = upload_done
        hit = lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertEqual(hit["hit"], "true")
        self.assertLessEqual(api.now, 300 + 90)

    def test_the_base_tier_runs_pack_of_a_newer_commit_is_taken(self):
        # Pushes leave the generated files to the base tier: this push's run packs nothing, and the
        # kick dispatches `cmux-next base tier · <tip>` up to 15 minutes later, on a newer commit.
        history = [(oid(5), oid(105)), (oid(3), oid(103)), (self.sha, self.tree)]
        own = push_run(7, self.sha, status="in_progress")
        skipped = [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "skipped"},
                   {"name": px.DAEMON_JOB, "status": "completed", "conclusion": "skipped"}]
        api = FakeApi(listed=[own], jobs={7: skipped}, wait=2700,
                      runs={9: base_tier_run(9, oid(5))}, blobs={90: pack_zip(oid(105), 9, oid(5))})

        def kick(fake):
            if fake.now >= 900 and len(fake.listed) == 1:
                fake.listed.insert(0, base_tier_run(9, oid(5), status="in_progress"))
                fake.jobs[9] = [{"name": px.GENERATED_JOB, "status": "in_progress"}]
            if fake.now >= 1700:
                fake.jobs[9] = [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "failure"}]
                fake.packs[oid(105)] = [artifact(oid(105), 9, 90)]
        api.on_sleep = kick
        hit = px.lookup(api, lambda: history, self.sha, self.tree, ENV, NAMES, self.into, 90, 0, expect_base_tier=True)
        self.assertEqual(hit["made_at"], oid(5))
        self.assertEqual(hit["source_run_id"], "9")
        self.assertLessEqual(api.now, 1700 + 90)

    def test_a_same_tree_base_tier_run_is_named_after_its_commit_not_its_head(self):
        self.assertEqual(px.check_run(base_tier_run(9, oid(3), head=oid(5)), REPO), oid(3))
        self.assertEqual(px.check_run(push_run(7, oid(3)), REPO), oid(3))
        for run in (push_run(9, oid(3), event="workflow_dispatch", display_title=f"cmux NEXT DEV daily · {oid(3)}"),
                    base_tier_run(9, oid(3), head_branch="main"),
                    base_tier_run(9, oid(3), head_repository={"full_name": "fork/cmux"})):
            with self.subTest(run=run["display_title"]), self.assertRaises(px.Miss):
                px.check_run(run, REPO)

    def test_a_base_tier_pack_whose_manifest_names_the_newer_head_is_refused(self):
        tree = oid(103)
        api = FakeApi(packs={tree: [artifact(tree, 9, 90)]}, blobs={90: pack_zip(tree, 9, oid(5))},
                      runs={9: base_tier_run(9, oid(3), head=oid(5))})
        with self.assertRaises(px.Miss) as caught:
            lookup(api, [(oid(3), tree)], oid(3), tree, self.into)
        self.assertIn("not the commit of the run", str(caught.exception))

    def test_with_the_base_tier_on_it_waits_for_the_kick_then_gives_up_at_the_deadline(self):
        skipped = [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "skipped"},
                   {"name": px.DAEMON_JOB, "status": "completed", "conclusion": "skipped"}]
        api = FakeApi(listed=[push_run(7, self.sha)], jobs={7: skipped}, wait=2700)
        with self.assertRaises(px.Miss) as caught:
            px.lookup(api, lambda: self.history, self.sha, self.tree, ENV, NAMES, self.into, 90, 0, expect_base_tier=True)
        self.assertIn("no base tier run", str(caught.exception))
        self.assertLessEqual(api.now, 2700)
        self.assertGreater(api.now, 2500)

    def test_daemon_test_is_not_waited_for_when_generated_files_packed(self):
        upload = {"name": px.UPLOAD_STEP, "status": "queued"}
        done = {"name": px.GENERATED_JOB, "status": "completed", "conclusion": "failure"}
        daemon = {"name": px.DAEMON_JOB, "status": "in_progress", "steps": [upload]}
        self.assertEqual(px.job_pending([done, daemon]), "")
        self.assertIn(px.DAEMON_JOB, px.job_pending([{**done, "conclusion": "skipped"}, daemon]))
        self.assertIn(px.DAEMON_JOB, px.job_pending([{**done, "conclusion": "skipped"}]))  # not listed yet
        self.assertIn(px.GENERATED_JOB, px.job_pending([{"name": px.GENERATED_JOB, "status": "queued"}, daemon]))
        self.assertIn("not listed yet", px.job_pending([]))

    def test_it_gives_up_at_the_deadline_while_the_job_still_runs(self):
        api = FakeApi(listed=[push_run(7, self.sha, status="in_progress")],
                      jobs={7: [{"name": px.GENERATED_JOB, "status": "queued"}]}, wait=2700)
        with self.assertRaises(px.Miss) as caught:
            lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertIn("no pack within the wait", str(caught.exception))
        self.assertLessEqual(api.now, 2700)

    def test_it_does_not_wait_when_no_pack_is_coming(self):
        # Both producers skipped and the base tier off: miss at once.
        api = FakeApi(listed=[push_run(7, self.sha, status="in_progress")],
                      jobs={7: [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "skipped"},
                                {"name": px.DAEMON_JOB, "status": "completed", "conclusion": "skipped"}]})
        with self.assertRaises(px.Miss) as caught:
            lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertIn("none is coming", str(caught.exception))
        self.assertEqual(api.now, 0)

    def test_a_run_not_listed_yet_gets_a_grace_then_misses(self):
        api = FakeApi(wait=2700)
        with self.assertRaises(px.Miss):
            lookup(api, self.history, self.sha, self.tree, self.into, grace=180)
        self.assertGreaterEqual(api.now, 180)
        self.assertLess(api.now, 400)

    def test_runs_of_older_commits_pull_requests_and_other_dispatches_are_not_watched(self):
        history = [(oid(3), oid(103)), (self.sha, self.tree), (oid(0), oid(100))]
        listed = [push_run(8, oid(0), status="in_progress"),
                  push_run(6, oid(3), status="in_progress", event="pull_request"),
                  push_run(5, oid(3), status="in_progress", event="workflow_dispatch", display_title="cmux-next · x")]
        api = FakeApi(listed=listed)
        self.assertEqual(px.producers(api, px.window_of(history, self.sha, self.tree), REPO), [])
        self.assertEqual(list(px.window_of(history, self.sha, self.tree)), [oid(3), self.sha])


class ChangedExports(unittest.TestCase):
    def test_only_exports_that_differ_from_head_go_to_the_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, staged, out = Path(tmp) / "repo", Path(tmp) / "staged", Path(tmp) / "out"
            for rel in NAMES:
                for base, text in ((repo, "committed"), (staged, "committed")):
                    (base / rel).parent.mkdir(parents=True, exist_ok=True)
                    (base / rel).write_text(text)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"], check=True)
            (staged / NAMES[0]).write_text("fresh")
            self.assertEqual(px.changed_exports(repo, staged, NAMES, out), [NAMES[0]])
            self.assertEqual((out / NAMES[0]).read_text(), "fresh")
            self.assertFalse((out / NAMES[1]).exists())


class PackScript(unittest.TestCase):
    """base-autofix-exports-pack.sh on a scratch repository, with fake regenerations."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        for name in ("base-autofix-exports-pack.sh", "base_autofix_pushed_exports.py", "settings-exports.txt"):
            (self.repo / "scripts/cmux-next" / name).write_bytes((ROOT / "scripts/cmux-next" / name).read_bytes())
        for rel in NAMES:
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / rel).write_text(f"committed {rel}\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
        self.fake = Path(self.tmp.name) / "regen.sh"

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout.strip()

    def run_pack(self, actions_writes: list[str], settings_writes: list[str]):
        def script(paths):
            return "#!/usr/bin/env bash\n" + "".join(f"printf 'fresh %s\\n' '{p}' > '{p}'\n" for p in paths)
        actions, settings = Path(self.tmp.name) / "a.sh", Path(self.tmp.name) / "s.sh"
        actions.write_text(script(actions_writes))
        settings.write_text(script(settings_writes))
        actions.chmod(0o755)
        settings.chmod(0o755)
        out = Path(self.tmp.name) / "out"
        env = {**os.environ, "CMUX_BASE_EXPORTS_REGENERATE_ACTIONS": str(actions),
               "CMUX_BASE_EXPORTS_REGENERATE_SETTINGS": str(settings), "GITHUB_RUN_ID": "42"}
        # A stale export the checks left in the checkout, for the job's later steps.
        (self.repo / NAMES[0]).write_text("left by the checks\n")
        result = subprocess.run(["bash", "scripts/cmux-next/base-autofix-exports-pack.sh", str(out)],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        return result, out

    def test_every_export_is_packed_with_its_digest_and_the_checkout_is_put_back(self):
        actions = list(px.ACTION_EXPORTS)
        settings = [rel for rel in NAMES if rel not in actions]
        result, out = self.run_pack(actions, settings)
        self.assertEqual(result.returncode, 0, result.stderr)
        tree = self.git("rev-parse", "HEAD^{tree}")
        self.assertIn(f"name={px.NAME_PREFIX}{tree}", result.stdout)
        manifest = json.loads((out / "manifest.json").read_text())
        self.assertEqual(manifest["tree"], tree)
        self.assertEqual(manifest["source_sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(manifest["run_id"], 42)
        for rel in NAMES:
            self.assertEqual((out / rel).read_text(), f"fresh {rel}\n")
            self.assertEqual(manifest["files"][rel], sha256((out / rel).read_bytes()))
        self.assertEqual((self.repo / NAMES[0]).read_text(), "left by the checks\n")
        self.assertEqual((self.repo / NAMES[1]).read_text(), f"committed {NAMES[1]}\n")

    def test_an_export_a_failing_test_did_not_rewrite_makes_no_pack(self):
        actions = list(px.ACTION_EXPORTS)
        settings = [rel for rel in NAMES if rel not in actions][:-1]
        result, out = self.run_pack(actions, settings)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not rewrite", result.stderr)
        self.assertNotIn("name=", result.stdout)
        self.assertEqual((self.repo / NAMES[0]).read_text(), "left by the checks\n")
        self.assertEqual((self.repo / NAMES[-1]).read_text(), f"committed {NAMES[-1]}\n")


class Wiring(unittest.TestCase):
    def test_app_recheck_admits_one_waiter_after_the_primary_read_fails(self):
        """Nine concurrent candidates survive a failed job-token read; the App recheck keeps one."""
        step = next((s for s in AUTOFIX["jobs"]["pushed-exports"]["steps"]
                     if s.get("id") == "carrier"), {})
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / "bin").mkdir()
            gh = work / "bin/gh"
            gh.write_text('''#!/usr/bin/env python3
import json, subprocess, sys, os
if os.environ.get("GH_TOKEN") != "app-read-token":
    sys.exit(1)
path, query = sys.argv[2], sys.argv[sys.argv.index("--jq") + 1]
if "/jobs?" in path:
    body = {"jobs": [{"name": "exports from the push's generated files", "status": "in_progress"}]}
else:
    body = {"workflow_runs": [{"id": i, "status": "in_progress"} for i in range(9, 0, -1)]}
sys.exit(subprocess.run(["jq", "-r", query], input=json.dumps(body), text=True).returncode)
''')
            gh.chmod(0o755)
            common = {**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
                      "GITHUB_REPOSITORY": REPO, "GITHUB_REF_NAME": "feat-cmux-next",
                      "COALESCE": "1"}
            admitted = 0
            for run in range(1, 10):
                primary = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/base-autofix-mac-busy.sh"), str(run)],
                                         env={**common, "GH_TOKEN": "unavailable-job-token"},
                                         capture_output=True, text=True)
                self.assertEqual(primary.stdout, "mac_busy=false\n")
                out = work / f"output-{run}"
                done = subprocess.run(["bash", "-c", step.get("run", "")], cwd=ROOT,
                                      env={**common, "GH_TOKEN": "app-read-token", "GITHUB_RUN_ID": str(run),
                                           "GITHUB_OUTPUT": str(out)}, capture_output=True, text=True)
                self.assertEqual(done.returncode, 0, done.stderr)
                deferred = "mac_busy=true" in (out.read_text() if out.exists() else "")
                admitted += not deferred
            print(f"export waiter admissions after failed primary read: {admitted}/9")
            self.assertEqual(admitted, 1)
            # The kill switch restores admission even with a positively known older carrier.
            out = work / "disabled-output"
            done = subprocess.run(["bash", "-c", step.get("run", "")], cwd=ROOT,
                                  env={**common, "GH_TOKEN": "app-read-token", "GITHUB_RUN_ID": "9",
                                       "COALESCE": "0", "GITHUB_OUTPUT": str(out)}, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(out.read_text(), "mac_busy=false\n")

    def pack_step_on(self, event: str, payload: dict) -> str:
        """Run the producer step's dispatch gate with a fake event and a fake pack script."""
        step = next(s for s in NEXT["jobs"]["generated-files"]["steps"] if s.get("id") == "base-exports")
        with tempfile.TemporaryDirectory() as tmp:
            event_path, script = Path(tmp) / "event.json", Path(tmp) / "scripts/cmux-next/base-autofix-exports-pack.sh"
            event_path.write_text(json.dumps(payload))
            script.parent.mkdir(parents=True)
            script.write_text("#!/usr/bin/env bash\necho name=packed\n")
            script.chmod(0o755)
            out = Path(tmp) / "out"
            env = {**os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_EVENT_PATH": str(event_path),
                   "GITHUB_OUTPUT": str(out), "RUNNER_TEMP": tmp}
            result = subprocess.run(["bash", "-c", step["run"]], cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return out.read_text() if out.exists() else ""

    def test_the_producer_packs_on_a_push_and_a_base_tier_dispatch_only(self):
        self.assertIn("name=packed", self.pack_step_on("push", {}))
        self.assertIn("name=packed", self.pack_step_on("workflow_dispatch", {"inputs": {"base_tier": "true"}}))
        self.assertNotIn("name=", self.pack_step_on("workflow_dispatch", {"inputs": {"dev_daily": "true"}}))
        self.assertNotIn("name=", self.pack_step_on("workflow_dispatch", {"inputs": {"base_tier": "false"}}))

    def test_the_mac_job_runs_only_without_a_pack(self):
        mac = AUTOFIX["jobs"]["action-exports"]
        self.assertIn("pushed-exports", mac["needs"])
        self.assertIn("needs.pushed-exports.outputs.hit != 'true'", mac["if"])
        # Only the run that carries the exports waits for a pack; the others defer and repair the rest at once.
        self.assertIn("needs.action-areas.outputs.mac_busy != 'true'", AUTOFIX["jobs"]["pushed-exports"]["if"])
        self.assertIn("needs.pushed-exports.outputs.deferred != 'true'", mac["if"])
        marker = AUTOFIX["jobs"]["mac-exports-deferred"]
        self.assertEqual(marker["needs"], ["action-areas", "pushed-exports"])
        self.assertIn("!cancelled()", marker["if"])
        self.assertIn("needs.action-areas.outputs.mac_busy == 'true'", marker["if"])
        self.assertIn("needs.pushed-exports.outputs.deferred == 'true'", marker["if"])

    def test_the_consumer_reads_only_and_its_wait_is_bounded(self):
        job = AUTOFIX["jobs"]["pushed-exports"]
        self.assertEqual(job["permissions"], {"contents": "read"})
        step = next(s for s in job["steps"] if s.get("id") == "lookup")
        # It polls, so only through the App's own budget, never github.token's shared one.
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ steps.read-token.outputs.token }}")
        self.assertIn("steps.carrier.outputs.mac_busy != 'true'", step["if"])
        carrier = next(s for s in job["steps"] if s.get("id") == "carrier")
        self.assertEqual(carrier["env"]["GH_TOKEN"], step["env"]["GH_TOKEN"])
        mint = next(s for s in job["steps"] if s.get("id") == "read-token")
        self.assertEqual(mint["with"]["permission-actions"], "read")
        self.assertTrue(step["continue-on-error"])
        self.assertIn("--wait 2700", step["run"])
        self.assertIn('--base-tier "$BASE_TIER"', step["run"])
        self.assertIn("CMUX_NEXT_BASE_TIER_COALESCE", step["env"]["BASE_TIER"])
        self.assertLess(2700 / 60, step["timeout-minutes"])
        self.assertLess(step["timeout-minutes"], job["timeout-minutes"])
        self.assertNotIn("runs-on: macos", json.dumps(job))
        self.assertIn("ubuntu", job["runs-on"])

    def test_the_consumer_job_cannot_fail_so_the_mac_job_always_has_its_fallback(self):
        # action-exports needs pushed-exports with no status function: a failed pushed-exports would
        # skip the Mac job. Every step continues on error, and the steps' limits fit inside the job's.
        job = AUTOFIX["jobs"]["pushed-exports"]
        for step in job["steps"]:
            with self.subTest(step=step.get("name") or step.get("uses")):
                self.assertTrue(step.get("continue-on-error"))
                self.assertIn("timeout-minutes", step)
        self.assertLess(sum(step["timeout-minutes"] for step in job["steps"]), job["timeout-minutes"])
        # A hit whose exports did not upload is a miss: the Mac job regenerates.
        self.assertEqual(job["outputs"]["hit"], "${{ steps.lookup.outputs.hit == 'true' && (steps.lookup.outputs.exports != 'true' || steps.upload.outcome == 'success') && 'true' || 'false' }}")
        self.assertIn("pushed-exports", AUTOFIX["jobs"]["action-exports"]["needs"])

    def test_autofix_uses_the_pack_as_this_commits_exports(self):
        job = AUTOFIX["jobs"]["autofix"]
        self.assertIn("pushed-exports", job["needs"])
        repair = next(s for s in job["steps"] if s.get("name") == "Repair")
        self.assertIn("needs.pushed-exports.outputs.hit == 'true'", repair["env"]["EXPORTS_VERIFIED"])
        download = next(s for s in job["steps"] if s.get("name") == "Download the regenerated action exports")
        self.assertIn("needs.pushed-exports.outputs.exports", download["if"])

    def test_the_producer_runs_on_branch_pushes_only_and_never_fails_its_job(self):
        steps = NEXT["jobs"]["generated-files"]["steps"]
        pack = next(s for s in steps if s.get("id") == "base-exports")
        # Both trigger shapes: a push, and the base tier dispatch pushes leave these checks to.
        self.assertIn("(github.event_name == 'push' || github.event_name == 'workflow_dispatch')", pack["if"])
        self.assertIn('.get("base_tier", "")', pack["run"])
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", pack["if"])
        self.assertTrue(pack["continue-on-error"])
        self.assertIn("base-autofix-exports-pack.sh", pack["run"])
        names = [s.get("name") for s in steps]
        self.assertLess(names.index("Check the settings exports"), names.index(pack["name"]))
        self.assertLess(names.index(pack["name"]), names.index("Regenerate stale files"))
        upload = steps[names.index(pack["name"]) + 1]
        self.assertIn("upload-artifact", upload["uses"])
        self.assertEqual(upload["with"]["name"], "${{ steps.base-exports.outputs.name }}")
        self.assertEqual(upload["with"]["retention-days"], 1)

    def test_a_folded_daemon_test_packs_on_its_own_build(self):
        steps = NEXT["jobs"]["daemon-test"]["steps"]
        names = [s.get("name") for s in steps]
        pack = next(s for s in steps if s.get("id") == "base-exports")
        self.assertIn("env.CMUX_NEXT_FOLD_GENERATED == 'true'", pack["if"])
        self.assertIn("github.event_name == 'workflow_dispatch'", pack["if"])
        self.assertIn('.get("base_tier", "")', pack["run"])
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", pack["if"])
        self.assertTrue(pack["continue-on-error"])
        self.assertLess(names.index("Check the settings exports"), names.index(pack["name"]))
        self.assertEqual(steps[names.index(pack["name"]) + 1]["name"], px.UPLOAD_STEP)
        self.assertEqual(NEXT["jobs"]["daemon-test"]["name"], px.DAEMON_JOB)
        self.assertEqual(NEXT["jobs"]["generated-files"]["name"], px.GENERATED_JOB)

    def test_both_workflows_start_on_changes_to_the_scripts(self):
        autofix_paths = AUTOFIX[True]["push"]["paths"]
        for path in ("scripts/cmux-next/base_autofix_pushed_exports.py", "scripts/cmux-next/base-autofix-exports-pack.sh"):
            self.assertIn(path, autofix_paths)

    def test_ci_runs_this_test(self):
        self.assertIn("tests/test_base_autofix_pushed_exports.py", (ROOT / ".github/workflows/cmux-next.yml").read_text())


if __name__ == "__main__":
    unittest.main()
