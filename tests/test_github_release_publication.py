#!/usr/bin/env python3
"""Publication must recover ambiguous uploads and never advertise missing files."""
import concurrent.futures
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

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
        self.active = 0
        self.peak = 0
        self.lock = threading.Lock()

    def assets(self, release_id):
        return dict(self.stored)

    def delete(self, asset_id):
        self.events.append(("delete", asset_id))
        self.stored = {name: value for name, value in self.stored.items() if value["id"] != asset_id}

    def upload(self, release_id, asset):
        name = asset.path.name
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
            self.events.append(("upload", name))
        try:
            time.sleep(0.005)
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
        self.assertEqual([event[1] for event in self.client.events[-2:]], [asset.path.name for asset in feeds])
        self.assertEqual(self.client.peak, 2)

    def test_rerun_reuses_verified_payloads_and_feeds(self):
        payload, feed = self.asset("build.dmg"), self.asset("appcast.xml", True)
        self.publish([payload], [feed])
        self.client.events.clear()
        self.publish([payload], [feed])
        self.assertEqual(self.client.events, [])

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
        self.assertEqual([event[0] for event in self.client.events], ["delete", "upload"])

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

    def test_asset_listing_is_paginated(self):
        client = publisher.GitHub("owner/repo", "fake-token")
        page1 = [{"name": f"file-{index}"} for index in range(100)]
        with patch.object(client, "request", side_effect=[page1, [{"name": "last"}]]) as request:
            self.assertEqual(len(client.assets(42)), 101)
            self.assertIn("page=2", request.call_args.args[1])

    def test_both_publication_workflows_use_the_shared_publisher(self):
        for name in ("nightly.yml", "release.yml"):
            text = (ROOT / ".github/workflows" / name).read_text()
            self.assertIn("scripts/ci/publish-release-assets.py", text)
            self.assertIn("--feed", text)


if __name__ == "__main__":
    unittest.main()
