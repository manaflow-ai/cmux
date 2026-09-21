#!/usr/bin/env python3
"""Exercise the exact-object peer source against a real loopback HTTP server."""

import hashlib
import http.client
import io
import json
import os
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import node_product_cache as cache
import peer_artifact_source as peer


class PeerArtifactSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = cache.Store(self.root / "source-cache")
        self.contract = {
            "tree": "tree-a",
            "xcode": "Xcode 26",
            "sdk": "26A",
            "architecture": "arm64",
        }
        self.product_key = cache._canonical_contract_key(self.contract)
        self.archive = self.root / cache.ARCHIVE_NAME
        self._write_archive(self.archive)
        self.identity = cache.Identity(
            repository="manaflow-ai/cmux",
            artifact_id=123,
            provider_digest="b" * 64,
            archive_digest=hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            product_contract=self.product_key,
            source_revision="a" * 40,
            producer_run_id=456,
        )
        self.token = "peer-token-" + "x" * 48
        self._publish()
        self.server = peer.make_server(self.store, self.token)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop_server)
        host, port = self.server.server_address
        self.base = f"http://{host}:{port}"

    def _stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def _write_archive(self, path):
        reuse = {
            "contract": self.contract,
            "revision": self.identity.source_revision if hasattr(self, "identity") else "a" * 40,
            "run_id": "456",
            "run_attempt": "1",
        }
        product = {
            "revision": "a" * 40,
            "xcode": "Xcode 26",
            "architecture": "arm64",
            "developer": "/Xcode",
            "checkout": "/work",
            "derived": "/derived",
        }
        with tarfile.open(path, "w:gz") as tar:
            for name, value in [
                (cache.REUSE_RECEIPT, reuse),
                (cache.PRODUCT_RECEIPT, product),
            ]:
                raw = json.dumps(value).encode()
                info = tarfile.TarInfo(name)
                info.size = len(raw)
                tar.addfile(info, io.BytesIO(raw))
            payload = b"compiled bytes" * 4096
            info = tarfile.TarInfo("Build/Products/Debug/cmux")
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))

    def _provider(self):
        return {
            "id": self.identity.artifact_id,
            "expired": False,
            "digest": "sha256:" + self.identity.provider_digest,
            "workflow_run": {"id": self.identity.producer_run_id},
            "created_at": "2026-09-21T09:00:00Z",
        }

    def _publish(self):
        reservation = cache.acquire(
            self.store,
            self.identity,
            self.root / "unused-destination",
            wait=0,
        )
        result = cache.finalize(
            self.store,
            self.identity,
            self.archive,
            token=reservation["token"],
            source_class="github",
            restore_succeeded=True,
            budget=10**9,
            provider_metadata=lambda _: self._provider(),
        )
        self.assertEqual(result["status"], "published", result)

    def _restore(self, name="consumer"):
        return peer.restore(
            [self.base],
            self.token,
            self.identity,
            self.root / name,
        )

    def test_exact_probe_and_fetch_returns_only_requested_object(self):
        size = peer.probe(
            self.base,
            self.identity.key(),
            self.identity.archive_digest,
            self.token,
        )
        self.assertEqual(size, self.archive.stat().st_size)
        result = self._restore()
        self.assertTrue(result["hit"], result)
        restored = self.root / "consumer" / cache.ARCHIVE_NAME
        self.assertEqual(
            hashlib.sha256(restored.read_bytes()).hexdigest(),
            self.identity.archive_digest,
        )
        self.assertEqual(result["bytes_transferred"], self.archive.stat().st_size)

    def test_unauthorized_listing_and_write_routes_disclose_no_cache_contents(self):
        for path in ("/", "/v1/objects", f"{peer.API_PREFIX}{self.identity.key()}"):
            request = urllib.request.Request(f"{self.base}{path}", method="HEAD")
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(error.exception.code, 404)

        request = urllib.request.Request(
            f"{self.base}{peer.API_PREFIX}{self.identity.key()}",
            data=b"overwrite",
            method="PUT",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request, timeout=2)
        self.assertEqual(error.exception.code, 405)

    def test_similar_metadata_with_different_exact_identity_is_a_miss(self):
        wrong_key = "f" * 64
        self.assertIsNone(
            peer.probe(self.base, wrong_key, self.identity.archive_digest, self.token)
        )
        self.assertTrue(self.store.entry(self.identity.key()).exists())

    def test_corrupt_peer_object_becomes_a_miss(self):
        obj = self.store.entry(self.identity.key()) / cache.OBJECT_NAME
        obj.chmod(0o644)
        obj.write_bytes(b"corrupt")
        result = self._restore("corrupt-consumer")
        self.assertFalse(result["hit"], result)
        self.assertEqual(result["status"], "miss")
        self.assertFalse(self.store.entry(self.identity.key()).exists())

    def test_two_consumers_can_fetch_one_leased_source_object_concurrently(self):
        barrier = threading.Barrier(3)
        results = [None, None]

        def consume(index):
            barrier.wait()
            results[index] = self._restore(f"consumer-{index}")

        threads = [threading.Thread(target=consume, args=(index,)) for index in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(5)
            self.assertFalse(thread.is_alive())
        self.assertTrue(all(result and result["hit"] for result in results), results)
        self.assertTrue(self.store.entry(self.identity.key()).exists())

    def test_consumer_cancellation_releases_source_transfer_lease(self):
        request = urllib.request.Request(
            f"{self.base}{peer.API_PREFIX}{self.identity.key()}",
            method="GET",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        response = urllib.request.urlopen(request, timeout=2)
        response.read(32)
        response.close()
        deadline = time.time() + 2
        while time.time() < deadline:
            if not list((self.store.root / "leases").glob(f"{self.identity.key()}.*.json")):
                break
            time.sleep(0.02)
        self.assertEqual(
            list((self.store.root / "leases").glob(f"{self.identity.key()}.*.json")),
            [],
        )

    def test_drain_refuses_new_fetch_but_existing_transfer_lease_blocks_eviction(self):
        drain = self.root / "drain"
        self.server.drain_file = drain
        lease = cache.acquire_peer_transfer(self.store, self.identity.key())
        self.assertIsNotNone(lease)
        drain.write_text("draining")
        self.assertIsNone(
            peer.probe(
                self.base,
                self.identity.key(),
                self.identity.archive_digest,
                self.token,
            )
        )
        reclaimed = cache.reclaim(self.store, 0)
        self.assertEqual(reclaimed["evicted_objects"], 0)
        cache.release_peer_transfer(self.store, self.identity.key(), lease["lease"])
        reclaimed = cache.reclaim(self.store, 0)
        self.assertEqual(reclaimed["evicted_objects"], 1)

    def test_peer_dies_mid_transfer_leaves_no_partial_destination(self):
        class Headers:
            def __init__(self, values):
                self.values = values

            def get(self, name):
                return self.values.get(name)

        class ShortResponse:
            status = 200

            def __init__(self, body, size):
                self.body = body
                self.offset = 0
                self.headers = Headers({
                    "X-CMUX-Object-Identity": f"sha256:{self_key}",
                    "X-CMUX-Object-Schema": str(cache.SCHEMA_GENERATION),
                    "X-CMUX-Content-SHA256": f"sha256:{self_digest}",
                    "Content-Length": str(size),
                })

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, size):
                if self.offset >= len(self.body):
                    return b""
                chunk = self.body[self.offset:self.offset + min(size, 16)]
                self.offset += len(chunk)
                return chunk

        self_key = self.identity.key()
        self_digest = self.identity.archive_digest
        full = self.archive.read_bytes()
        calls = 0

        def opener(request, _timeout):
            nonlocal calls
            calls += 1
            body = b"" if request.get_method() == "HEAD" else full[: len(full) // 2]
            return ShortResponse(body, len(full))

        destination = self.root / "short-transfer"
        result = peer.restore(
            ["http://127.0.0.1:9"],
            self.token,
            self.identity,
            destination,
            opener=opener,
        )
        self.assertFalse(result["hit"], result)
        self.assertFalse(destination.exists())
        self.assertGreaterEqual(calls, 2)


if __name__ == "__main__":
    unittest.main()
