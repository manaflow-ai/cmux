#!/usr/bin/env python3
"""Publication must recover ambiguous uploads and never advertise missing files."""
import hashlib
import http.server
import socket
import importlib.util
import json
import subprocess
import math
import os
import io
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/ci/publish-release-assets.py")
publisher = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = publisher
spec.loader.exec_module(publisher)
# The tests' faked waits go to a ledger of their own, never a real job's.
_LEDGER_DIR = tempfile.TemporaryDirectory()
publisher._LEDGER = Path(_LEDGER_DIR.name) / "waited"


def remote(asset, asset_id=1):
    return {"id": asset_id, "name": asset.path.name, "state": "uploaded", "size": asset.size, "digest": asset.digest}


class FakeClient:
    def __init__(self):
        self.stored = {}
        self.events = []
        self.failures = {}
        self.rename_failures = []
        self.active = 0
        self.peak = 0
        self.lock = threading.Lock()
        self.overlap_event = None

    def assets(self, release_id):
        return dict(self.stored)

    def asset_digest(self, remote):
        return remote.get("actual_digest") or remote.get("digest")

    def delete(self, asset_id):
        self.events.append(("delete", asset_id))
        self.stored = {name: value for name, value in self.stored.items() if value["id"] != asset_id}

    def rename(self, asset_id, name):
        self.events.append(("rename", name))
        mode = self.rename_failures.pop(0) if self.rename_failures else None
        if mode == "before":
            raise publisher.RequestError("rename timeout")
        old_name = next(key for key, value in self.stored.items() if value["id"] == asset_id)
        value = self.stored.pop(old_name)
        value["name"] = name
        self.stored[name] = value
        if mode == "after":
            raise publisher.RequestError("response lost after rename")
        return value

    def upload(self, release_id, asset):
        name = asset.path.name
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
            self.events.append(("upload", name))
            overlap_event = self.overlap_event
            should_wait = overlap_event is not None and self.active < 2
            if overlap_event is not None and self.active >= 2:
                overlap_event.set()
        try:
            if should_wait:
                overlap_event.wait(timeout=5)
            failure = self.failures.get(name, [])
            mode = failure.pop(0) if failure else None
            if mode == "auth":
                raise publisher.RequestError("HTTP 401", status=401)
            if mode == "timeout":
                raise publisher.RequestError("curl timeout")
            if mode == "starter":
                self.stored[name] = {**remote(asset), "state": "starter", "size": 0, "digest": None}
                raise publisher.RequestError("HTTP 502", status=502)
            self.stored[name] = remote(asset, len(self.stored) + 1)
            if mode == "committed_timeout":
                raise publisher.RequestError("response lost")
            if mode == "corrupt":
                self.stored[name]["digest"] = "sha256:wrong"
            return self.stored[name]
        finally:
            with self.lock:
                self.active -= 1


class PublicationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.client = FakeClient()
        self.sleeper = patch.object(publisher, "backoff")
        self.sleeper.start()
        self.addCleanup(self.sleeper.stop)

    def asset(self, name, replace=False):
        path = self.root / name
        path.write_bytes(name.encode())
        return publisher.Asset.read(path, replace=replace)

    def publish(self, payloads, feeds=()):
        publisher.publish(self.client, 42, [payloads, [], list(feeds)])

    def test_lost_success_response_is_reconciled_without_deleting_or_reuploading(self):
        asset = self.asset("build.dmg")
        self.client.failures[asset.path.name] = ["committed_timeout"]
        self.publish([asset])
        self.assertEqual(self.client.events, [("upload", "build.dmg")])

    def test_retry_removes_only_incomplete_starter_asset(self):
        asset = self.asset("build.dmg")
        self.client.failures[asset.path.name] = ["starter"]
        self.publish([asset])
        self.assertEqual([event[0] for event in self.client.events], ["upload", "delete", "upload"])

    def test_exhausted_upload_preserves_all_feeds(self):
        asset, feed = self.asset("build.dmg"), self.asset("appcast.xml", replace=True)
        self.client.failures[asset.path.name] = ["timeout"] * 3
        old = {**remote(feed), "digest": "sha256:previous"}
        self.client.stored[feed.path.name] = old
        with self.assertRaises(publisher.RequestError):
            self.publish([asset], [feed])
        self.assertEqual(self.client.stored[feed.path.name], old)
        self.assertEqual(len(self.client.events), 3)

    def test_payloads_finish_before_any_feed_changes(self):
        payloads = [self.asset(f"build-{index}.dmg") for index in range(5)]
        feeds = [self.asset("appcast-arm64.xml", True), self.asset("appcast.xml", True)]
        self.publish(payloads, feeds)
        self.assertEqual([event[1] for event in self.client.events if event[0] == "rename"], [asset.path.name for asset in feeds])
        # One upload at a time: parallel uploads from one token burst into GitHub's secondary limit.
        self.assertEqual(self.client.peak, 1)

    def test_rerun_reuses_verified_payloads_and_feeds(self):
        payload, feed = self.asset("build.dmg"), self.asset("appcast.xml", True)
        self.publish([payload], [feed])
        self.client.events.clear()
        self.publish([payload], [feed])
        self.assertEqual(self.client.events, [])

    def test_null_github_digest_is_rehashed_before_reuse(self):
        asset = self.asset("build.dmg")
        self.client.stored[asset.path.name] = {
            **remote(asset), "digest": None, "actual_digest": asset.digest
        }
        self.publish([asset])
        self.assertEqual(self.client.events, [])

    def test_null_digest_uses_the_authenticated_api_asset_url(self):
        client = publisher.GitHub("owner/repo", "fake-token")
        remote_asset = {"name": "draft.bin", "url": "https://api.github.com/assets/1", "browser_download_url": "https://github.com/draft.bin"}
        with patch("publisher.urllib.request.urlopen") as urlopen:
            response = urlopen.return_value.__enter__.return_value
            response.read.side_effect = [b"draft-content", b""]
            response.__iter__ = lambda self: iter([b"draft-content"])
            response.__enter__.return_value.read.side_effect = [b"draft-content", b""]
            client.asset_digest(remote_asset)
            request = urlopen.call_args.args[0]
            self.assertEqual(request.full_url, "https://api.github.com/assets/1")

    def test_a_rate_limited_digest_download_backs_off_and_retries(self):
        client = publisher.GitHub("owner/repo", "fake-token")
        remote_asset = {"name": "a.bin", "url": "https://api.github.com/assets/1", "size": 3}
        refused = urllib.error.HTTPError("https://api.github.com/assets/1", 403, "Forbidden", {},
                                         io.BytesIO(b'{"message": "API rate limit exceeded for installation."}'))
        ok = unittest.mock.MagicMock()
        ok.__enter__.return_value.read.side_effect = [b"abc", b""]
        with patch("publisher.urllib.request.urlopen", side_effect=[refused, ok]), \
                patch.object(publisher, "backoff") as backoff:
            self.assertEqual(client.asset_digest(remote_asset), "sha256:" + hashlib.sha256(b"abc").hexdigest())
        self.assertTrue(backoff.call_args.args[1].rate_limited)

    def test_a_permission_403_on_the_digest_download_fails_at_once(self):
        client = publisher.GitHub("owner/repo", "fake-token")
        refused = urllib.error.HTTPError("https://api.github.com/assets/1", 403, "Forbidden", {},
                                         io.BytesIO(b'{"message": "Resource not accessible by integration"}'))
        with patch("publisher.urllib.request.urlopen", side_effect=[refused]), \
                patch.object(publisher, "backoff") as backoff:
            with self.assertRaises(publisher.RequestError):
                client.asset_digest({"name": "a.bin", "url": "https://api.github.com/assets/1"})
        backoff.assert_not_called()

    def test_failed_alias_rename_restores_the_current_asset(self):
        asset = self.asset("latest.dmg", True)
        old = {**remote(asset), "digest": "sha256:old"}
        self.client.stored[asset.path.name] = old
        self.client.rename_failures = [None, "before", None]
        with self.assertRaises(publisher.RequestError):
            self.publish([asset])
        self.assertEqual(self.client.stored[asset.path.name], old)
        self.assertNotIn("cmux-backup-latest.dmg", self.client.stored)

    def test_null_digest_replacement_resolves_the_old_asset_before_rename(self):
        asset = self.asset("latest.dmg", True)
        old = {**remote(asset), "digest": None, "actual_digest": "sha256:old"}
        self.client.stored[asset.path.name] = old
        self.publish([asset])
        self.assertEqual(self.client.stored[asset.path.name]["digest"], asset.digest)

    def test_failed_alias_replacement_preserves_the_current_asset(self):
        asset = self.asset("latest.dmg", True)
        old = {**remote(asset), "digest": "sha256:old"}
        self.client.stored[asset.path.name] = old
        self.client.failures["cmux-upload-latest.dmg-" + asset.digest[7:19]] = ["timeout"] * 3
        with self.assertRaises(publisher.RequestError):
            self.publish([asset])
        self.assertEqual(self.client.stored[asset.path.name], old)
        self.assertEqual([event[0] for event in self.client.events], ["upload", "upload", "upload"])
        self.assertEqual(list(self.root.glob("cmux-upload-*")), [])

    def test_immutable_digest_collision_is_fatal_without_deletion(self):
        asset = self.asset("build.dmg")
        self.client.stored[asset.path.name] = {**remote(asset), "digest": "sha256:different"}
        with self.assertRaisesRegex(RuntimeError, "immutable"):
            self.publish([asset])
        self.assertEqual(self.client.events, [])

    def test_same_size_different_content_alias_is_replaced(self):
        asset = self.asset("latest.dmg", True)
        self.client.stored[asset.path.name] = {**remote(asset), "digest": "sha256:different"}
        self.publish([asset])
        self.assertEqual([event[0] for event in self.client.events], ["upload", "rename", "rename", "delete"])

    def test_wrong_uploaded_digest_blocks_feeds(self):
        asset, feed = self.asset("build.dmg"), self.asset("appcast.xml", True)
        self.client.failures[asset.path.name] = ["corrupt"]
        with self.assertRaisesRegex(RuntimeError, "verification"):
            self.publish([asset], [feed])
        self.assertNotIn(feed.path.name, self.client.stored)

    def test_auth_failure_is_not_retried(self):
        asset = self.asset("build.dmg")
        self.client.failures[asset.path.name] = ["auth"]
        with self.assertRaises(publisher.RequestError):
            self.publish([asset])
        self.assertEqual(len(self.client.events), 1)

    def test_final_ambiguous_attempt_is_reconciled(self):
        asset = self.asset("build.dmg")
        self.client.failures[asset.path.name] = ["timeout", "timeout", "committed_timeout"]
        self.publish([asset])
        self.assertEqual(len(self.client.events), 3)

    def test_plan_requires_every_mandatory_pattern_before_network(self):
        self.asset("one.dmg")
        with self.assertRaisesRegex(ValueError, "No files"):
            publisher.plan([str(self.root / "one.dmg"), str(self.root / "missing.dmg")], [], [], [])

    def test_optional_delta_and_duplicate_basename_handling(self):
        self.asset("one.dmg")
        phases = publisher.plan([str(self.root / "one.dmg")], [str(self.root / "*.delta")], [], [])
        self.assertEqual(len(phases[0]), 1)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            publisher.plan([str(self.root / "one.dmg")], [], [str(self.root / "one.dmg")], [])

    def test_empty_asset_is_rejected(self):
        path = self.root / "empty.dmg"
        path.touch()
        with self.assertRaises(ValueError):
            publisher.Asset.read(path)

    def test_missing_release_is_created_draft_and_existing_release_is_untouched(self):
        client = publisher.GitHub("owner/repo", "fake-token")
        with patch.object(client, "request", side_effect=[publisher.RequestError("missing", status=404), [], {"id": 9}]) as request:
            self.assertEqual(client.release_id("nightly"), 9)
        self.assertEqual(request.call_args.args[0], "POST")
        self.assertIn(b'"draft": true', request.call_args.kwargs["body"])

    def test_rerun_adopts_the_existing_draft_instead_of_staging_another(self):
        # The tags endpoint 404s for drafts. Staging a second draft on a rerun
        # left two full asset sets, so a rerun adopts its single staged draft.
        client = publisher.GitHub("owner/repo", "fake-token")
        listing = [
            {"id": 11, "tag_name": "v1.2.2", "draft": False},
            {"id": 8, "tag_name": "v1.2.4", "draft": True},
            {"id": 5, "tag_name": "v1.2.3", "draft": True},
        ]
        with patch.object(client, "request", side_effect=[publisher.RequestError("missing", status=404), listing]) as request:
            self.assertEqual(client.release_id("v1.2.3"), 5)
        self.assertNotIn("POST", [call.args[0] for call in request.call_args_list])

    def test_asset_listing_is_paginated(self):
        client = publisher.GitHub("owner/repo", "fake-token")
        page1 = [{"name": f"file-{index}"} for index in range(100)]
        with patch.object(client, "request", side_effect=[page1, [{"name": "last"}]]) as request:
            self.assertEqual(len(client.assets(42)), 101)
            self.assertIn("page=2", request.call_args.args[1])

    def test_both_publication_workflows_use_the_shared_publisher(self):
        for name in ("nightly.yml", "release.yml"):
            text = (ROOT / ".github/workflows" / name).read_text()
            self.assertTrue("scripts/ci/publish-release-assets.py" in text, name)
            self.assertIn("--feed", text)

    def test_replacement_names_are_preserved_by_github(self):
        # GitHub normalizes leading-dot release asset names, so replacement
        # staging and backup names must remain ordinary filenames.
        text = (ROOT / "scripts/ci/publish-release-assets.py").read_text()
        self.assertIn('f"cmux-upload-', text)
        self.assertIn('f"cmux-backup-', text)

    def test_nightly_finalization_targets_the_channel_release(self):
        text = (ROOT / ".github/workflows/nightly.yml").read_text()
        metadata = text.index("- name: Publish verified nightly release metadata")
        self.assertIn("RELEASE_TAG: ${{ needs.decide.outputs.release_tag }}", text[metadata:])
        self.assertIn("RELEASE_ID: ${{ steps.publish_assets.outputs.release_id }}", text[metadata:])
        self.assertNotIn("softprops/action-gh-release", text[metadata:])

    def test_stable_release_stays_draft_until_downloads_are_verified(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        upload = text.index("- name: Upload release asset")
        finalize = text.index("- name: Publish verified release")
        self.assertLess(upload, finalize)
        self.assertIn("--tag", text[upload:finalize])
        self.assertIn('--github-output "$GITHUB_OUTPUT"', text[upload:finalize])
        # v0.65.2: a tag lookup cannot see drafts, so the publish action made a
        # second release and published it with 0 assets. Publish the staged id.
        step = text[finalize:text.index("- name: Upload release appcast to R2")]
        self.assertNotIn("softprops/action-gh-release", step)
        self.assertIn("RELEASE_ID: ${{ steps.upload_release.outputs.release_id", step)
        self.assertIn('finalize-release.py publish', step)
        self.assertIn('--release-id "$RELEASE_ID"', step)
        self.assertIn('--expect-count "$UPLOADED_COUNT"', step)

    def test_stable_release_clears_staged_prerelease_before_finalizing(self):
        # publish-release-assets.py stages a missing release as a draft
        # prerelease. GitHub refuses make_latest on a prerelease, so v0.65.1
        # failed with "Latest release cannot be draft or prerelease".
        text = (ROOT / ".github/workflows/release.yml").read_text()
        finalize = text.index("- name: Publish verified release")
        step = text[finalize:text.index("- name: Upload release appcast to R2")]
        self.assertIn("--prerelease false", step)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.uploads = []
        self.stored = {}
        self.drop_response = False
        self.status = 201
        # Queued (code, headers, body) answers for uploads, before the normal 201.
        self.responses = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def answer(self, code, body):
                encoded = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                self.answer(200, list(owner.stored.values()))

            def do_POST(self):
                name = parse_qs(urlsplit(self.path).query)["name"][0]
                data = self.rfile.read(int(self.headers["Content-Length"]))
                owner.uploads.append((name, data, dict(self.headers)))
                if owner.responses:
                    code, headers, body = owner.responses.pop(0)
                    encoded = json.dumps(body).encode()
                    self.send_response(code)
                    for header, value in headers.items():
                        self.send_header(header, value)
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
                if owner.status != 201:
                    self.answer(owner.status, {"message": "failure"})
                    return
                asset = {"id": len(owner.stored) + 1, "name": name, "size": len(data),
                         "digest": "sha256:" + hashlib.sha256(data).hexdigest(), "state": "uploaded"}
                owner.stored[name] = asset
                if owner.drop_response:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.answer(201, asset)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        def stop():
            server.shutdown()
            thread.join()
            server.server_close()
        self.addCleanup(stop)
        url = f"http://127.0.0.1:{server.server_port}"
        self.client = publisher.GitHub("owner/repo", "fake-test-token", api_url=url, upload_url=url)

    def file(self, name="build file+.dmg"):
        path = self.root / name
        path.write_bytes(bytes(range(256)) * 32)
        return publisher.Asset.read(path)

    def test_real_curl_preserves_bytes_name_and_authenticated_headers(self):
        asset = self.file()
        publisher.publish(self.client, 42, [[asset], [], []])
        name, data, headers = self.uploads[0]
        self.assertEqual(name, asset.path.name)
        self.assertEqual(data, asset.path.read_bytes())
        self.assertEqual(headers["Authorization"], "Bearer fake-test-token")
        self.assertEqual(headers["Accept"], "application/vnd.github+json")
        self.assertNotIn("Transfer-Encoding", headers)

    def test_real_curl_lost_response_reconciles_server_committed_asset(self):
        self.drop_response = True
        publisher.publish(self.client, 42, [[self.file()], [], []])
        self.assertEqual(len(self.uploads), 1)

    def test_real_curl_permanent_error_blocks_feed(self):
        self.status = 401
        with self.assertRaises(publisher.RequestError) as raised:
            publisher.publish(self.client, 42, [[self.file()], [], [self.file("appcast.xml")]])
        self.assertEqual(raised.exception.status, 401)
        self.assertEqual(len(self.uploads), 1)

    def rate_limited_publish(self, *responses):
        """Publish one file after the queued answers; returns the waits slept."""
        self.responses = list(responses)
        publisher._rate_limit_deadline = None
        publisher._secondary_waits = 0
        publisher._waited_here = 0.0
        publisher._ledger_at_start = None
        self.addCleanup(setattr, publisher, "_waited_here", 0.0)
        self.addCleanup(setattr, publisher, "_ledger_at_start", None)
        self.addCleanup(setattr, publisher, "_rate_limit_deadline", None)
        self.addCleanup(setattr, publisher, "_secondary_waits", 0)
        waits = []
        with patch.object(publisher, "_sleep", side_effect=waits.append):
            publisher.publish(self.client, 42, [[self.file()], [], []])
        return waits

    def test_rate_limit_403_with_no_remaining_waits_until_the_reset(self):
        reset = int(publisher.time.time()) + 120
        waits = self.rate_limited_publish(
            (403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(reset), "x-ratelimit-limit": "5000"},
             {"message": "API rate limit exceeded for installation."}))
        self.assertEqual(len(self.uploads), 2)
        self.assertEqual(len(waits), 1)
        self.assertGreater(waits[0], 100)
        self.assertLessEqual(waits[0], 125)

    def test_rate_limit_403_with_retry_after_waits_that_long(self):
        waits = self.rate_limited_publish((403, {"retry-after": "30"}, {"message": "You have exceeded a secondary rate limit."}))
        self.assertEqual(waits, [30.0])
        self.assertEqual(len(self.uploads), 2)

    def test_a_refusal_with_no_reset_backs_off_exponentially_within_the_budget(self):
        # GitHub's secondary limit: no retry-after and no x-ratelimit headers (2026-10-26, run 40298250989).
        refused = (403, {"x-github-request-id": "E60C:1"}, {"message": "API rate limit exceeded for installation."})
        with patch.object(publisher, "RATE_LIMIT_BUDGET_SECONDS", 1800):
            waits = self.rate_limited_publish(*[refused] * 5)
        self.assertEqual(waits, [60.0, 120.0, 240.0, 300.0, 300.0])
        self.assertEqual(len(self.uploads), 6)

    def test_a_refusal_logs_every_header_and_the_rate_limit_snapshot(self):
        refused = (403, {"x-github-request-id": "E60C:1", "x-oauth-scopes": ""}, {"message": "API rate limit exceeded"})
        with patch("sys.stderr", new_callable=io.StringIO) as err:
            self.rate_limited_publish(refused)
        text = err.getvalue()
        self.assertIn("Rate-limited POST response headers: ", text)
        self.assertIn("x-github-request-id=E60C:1", text)
        self.assertIn("/rate_limit at the refusal: ", text)
        self.assertNotIn("fake-test-token", text)

    def test_a_job_s_waits_share_one_ledger_with_gh_budget_wait(self):
        # Every rate-limit wait of a job (this publisher, gh_budget_wait.sh) adds to one ledger and
        # stops at GH_BUDGET_WAIT_MAX_SECONDS, so a job's steps never wait past its timeout together.
        ledger = self.root / "ledger" / "waited"
        ledger.parent.mkdir()
        ledger.write_text("3590")
        refused = (403, {}, {"message": "API rate limit exceeded"})
        with patch.object(publisher, "_LEDGER", ledger), patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "3600"}), \
                patch.object(publisher, "RATE_LIMIT_BUDGET_SECONDS", 1800):
            with self.assertRaisesRegex(RuntimeError, "did not reset within"):
                self.rate_limited_publish(refused, refused)
        self.assertEqual(int(ledger.read_text()), 3600)

    def test_an_unusable_ledger_path_fails_closed(self):
        # A ledger path that cannot be read (its directory is a file) counts as the hour spent.
        refused = (403, {}, {"message": "API rate limit exceeded"})
        unwritable = self.root / "file" / "waited"
        (self.root / "file").write_text("not a directory")
        with patch.object(publisher, "_LEDGER", unwritable), patch.object(publisher, "_waited_here", 0.0), \
                patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "100"}), \
                patch.object(publisher, "RATE_LIMIT_BUDGET_SECONDS", 1800):
            with self.assertRaisesRegex(RuntimeError, "did not reset within"):
                self.rate_limited_publish(refused, refused, refused)
            self.assertEqual(publisher._waited_here, 0.0)

    def test_a_ledger_that_cannot_be_written_stops_the_wait(self):
        # A wait the ledger cannot record would be invisible to the job's later steps: fail, don't wait.
        ledger = self.root / "ro" / "waited"
        ledger.parent.mkdir()
        ledger.write_text("3590")
        refused = (403, {}, {"message": "API rate limit exceeded"})
        real_write = Path.write_text

        def read_only(path, *args, **kwargs):
            if path.parent == ledger.parent:
                raise PermissionError("read-only")
            return real_write(path, *args, **kwargs)

        waits = []
        with patch.object(publisher, "_LEDGER", ledger), patch.object(Path, "write_text", read_only), \
                patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "3600"}), \
                patch.object(publisher, "RATE_LIMIT_BUDGET_SECONDS", 1800), \
                patch.object(publisher, "_sleep", side_effect=waits.append):
            self.responses = [refused] * 5
            publisher._rate_limit_deadline = None
            publisher._secondary_waits = 0
            publisher._waited_here = 0.0
            publisher._ledger_at_start = None
            self.addCleanup(setattr, publisher, "_ledger_at_start", None)
            self.addCleanup(setattr, publisher, "_waited_here", 0.0)
            self.addCleanup(setattr, publisher, "_rate_limit_deadline", None)
            with self.assertRaisesRegex(RuntimeError, "did not reset within"):
                publisher.publish(self.client, 42, [[self.file()], [], []])
        self.assertEqual(waits, [])
        self.assertEqual(ledger.read_text(), "3590")

    def test_an_unreadable_or_malformed_ledger_counts_as_spent(self):
        ledger = self.root / "bad" / "waited"
        ledger.parent.mkdir()
        ledger.write_text("garbage")
        refused = (403, {}, {"message": "API rate limit exceeded"})
        with patch.object(publisher, "_LEDGER", ledger), patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "3600"}):
            with self.assertRaisesRegex(RuntimeError, "did not reset within"):
                self.rate_limited_publish(refused)
        for bad in ("", "-50", "nan", "inf", "1e9", "12.5"):
            ledger.write_text(bad)
            with patch.object(publisher, "_LEDGER", ledger), patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "3600"}):
                self.assertEqual(publisher._ledger_spent(), 3600.0, bad)
        ledger.write_bytes(b"\xff\xfe12")  # not UTF-8
        with patch.object(publisher, "_LEDGER", ledger), patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "3600"}):
            self.assertEqual(publisher._ledger_spent(), 3600.0)
        missing = self.root / "none" / "waited"
        with patch.object(publisher, "_LEDGER", missing):
            self.assertEqual(publisher._ledger_spent(), 0.0)

    def test_a_fractional_wait_is_recorded_rounded_up(self):
        # 10.2 s waited must not be logged as 10: later steps would wait past the cap.
        ledger = self.root / "frac" / "waited"
        with patch.object(publisher, "_LEDGER", ledger), patch.dict(os.environ, {"GH_BUDGET_WAIT_MAX_SECONDS": "3600"}):
            publisher._ledger_at_start = None
            self.addCleanup(setattr, publisher, "_ledger_at_start", None)
            waited_before = publisher._waited_here
            self.addCleanup(setattr, publisher, "_waited_here", waited_before)
            with publisher._rate_limit_lock:
                publisher._record_job_wait(10.2)
        self.assertEqual(ledger.read_text(), str(math.ceil(waited_before + 10.2)))

    def test_the_budget_comes_from_the_environment(self):
        script = Path(publisher.__file__)
        out = subprocess.run([sys.executable, "-c", f"import runpy; m = runpy.run_path({str(script)!r}, run_name='x'); "
                              "print(m['RATE_LIMIT_BUDGET_SECONDS'])"],
                             env={**os.environ, "CMUX_RELEASE_RATE_LIMIT_SECONDS": "1800"},
                             capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "1800")

    def test_rate_limit_403_named_only_in_the_body_is_retried(self):
        waits = self.rate_limited_publish((403, {}, {"message": "API rate limit exceeded for installation ID 1."}))
        self.assertEqual(waits, [60.0])
        self.assertEqual(len(self.uploads), 2)

    def test_rate_limit_wait_is_capped_by_the_budget(self):
        reset = int(publisher.time.time()) + 3600
        waits = self.rate_limited_publish(
            (403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(reset)}, {"message": "API rate limit exceeded"}))
        self.assertEqual(len(waits), 1)
        self.assertLessEqual(waits[0], publisher.RATE_LIMIT_BUDGET_SECONDS)

    def test_rate_limit_that_outlasts_the_budget_fails(self):
        publisher._rate_limit_deadline = publisher.time.monotonic() - 1
        self.addCleanup(setattr, publisher, "_rate_limit_deadline", None)
        self.responses = [(403, {"x-ratelimit-remaining": "0"}, {"message": "API rate limit exceeded"})]
        with patch.object(publisher, "_sleep"):
            with self.assertRaisesRegex(RuntimeError, "did not reset within"):
                publisher.publish(self.client, 42, [[self.file()], [], []])
        self.assertEqual(len(self.uploads), 1)

    def test_permission_403_fails_at_once_and_names_github_s_message(self):
        self.responses = [(403, {"x-ratelimit-remaining": "4999", "x-github-request-id": "ABC:1"},
                           {"message": "Resource not accessible by integration"})]
        with patch.object(publisher, "_sleep") as sleep:
            with self.assertRaises(publisher.RequestError) as raised:
                publisher.publish(self.client, 42, [[self.file()], [], [self.file("appcast.xml")]])
        sleep.assert_not_called()
        self.assertEqual(len(self.uploads), 1)
        error = raised.exception
        self.assertEqual(error.status, 403)
        self.assertFalse(error.rate_limited)
        self.assertIn("Resource not accessible by integration", str(error))
        self.assertIn("x-ratelimit-remaining=4999", str(error))
        self.assertIn("x-github-request-id=ABC:1", str(error))

    def test_error_text_never_contains_the_token(self):
        self.responses = [(403, {}, {"message": "bad token fake-test-token"})]
        with self.assertRaises(publisher.RequestError) as raised:
            publisher.publish(self.client, 42, [[self.file()], [], []])
        self.assertNotIn("fake-test-token", str(raised.exception))

    def test_token_is_only_in_stdin_and_request_deadlines_are_bounded(self):
        asset = self.file()
        real_run = publisher.subprocess.run
        with patch.object(publisher.subprocess, "run", wraps=real_run) as run:
            self.client.upload(42, asset)
        command = run.call_args.args[0]
        self.assertNotIn("fake-test-token", " ".join(command))
        self.assertIn("fake-test-token", run.call_args.kwargs["input"])
        self.assertEqual(command[command.index("--max-time") + 1], "600")
        self.assertNotIn("--location", command)


if __name__ == "__main__":
    unittest.main()
