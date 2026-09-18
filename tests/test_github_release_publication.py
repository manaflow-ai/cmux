#!/usr/bin/env python3
"""Publication must recover ambiguous uploads and never advertise missing files."""
import hashlib
import http.server
import socket
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/ci/publish-release-assets.py")
publisher = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = publisher
spec.loader.exec_module(publisher)


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
        self.client.overlap_event = threading.Event()
        self.publish(payloads, feeds)
        self.assertEqual([event[1] for event in self.client.events if event[0] == "rename"], [asset.path.name for asset in feeds])
        self.assertEqual(self.client.peak, 2)

    def test_rerun_reuses_verified_payloads_and_feeds(self):
        payload, feed = self.asset("build.dmg"), self.asset("appcast.xml", True)
        self.publish([payload], [feed])
        self.client.events.clear()
        self.publish([payload], [feed])
        self.assertEqual(self.client.events, [])

    def test_failed_alias_rename_restores_the_current_asset(self):
        asset = self.asset("latest.dmg", True)
        old = {**remote(asset), "digest": "sha256:old"}
        self.client.stored[asset.path.name] = old
        self.client.rename_failures = [None, "before", None]
        with self.assertRaises(publisher.RequestError):
            self.publish([asset])
        self.assertEqual(self.client.stored[asset.path.name], old)
        self.assertNotIn(".cmux-backup-latest.dmg", self.client.stored)

    def test_failed_alias_replacement_preserves_the_current_asset(self):
        asset = self.asset("latest.dmg", True)
        old = {**remote(asset), "digest": "sha256:old"}
        self.client.stored[asset.path.name] = old
        self.client.failures[".cmux-upload-latest.dmg-" + asset.digest[7:19]] = ["timeout"] * 3
        with self.assertRaises(publisher.RequestError):
            self.publish([asset])
        self.assertEqual(self.client.stored[asset.path.name], old)
        self.assertEqual([event[0] for event in self.client.events], ["upload", "upload", "upload"])
        self.assertEqual(list(self.root.glob(".cmux-upload-*")), [])

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
        with patch.object(client, "request", side_effect=[publisher.RequestError("missing", status=404), {"id": 9}]) as request:
            self.assertEqual(client.release_id("nightly"), 9)
        self.assertEqual(request.call_args.args[0], "POST")
        self.assertIn(b'"draft": true', request.call_args.kwargs["body"])

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

    def test_stable_release_stays_draft_until_downloads_are_verified(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        upload = text.index("- name: Upload release asset")
        finalize = text.index("- name: Publish verified release")
        self.assertLess(upload, finalize)
        self.assertIn("--tag", text[upload:finalize])
        self.assertIn("draft: false", text[finalize:])
        self.assertIn("prerelease: false", text[finalize:])


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.uploads = []
        self.stored = {}
        self.drop_response = False
        self.status = 201
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
