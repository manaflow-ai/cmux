#!/usr/bin/env python3
"""Exercise the node-local immutable compiled-product cache without network."""

import hashlib
import importlib.util
import io
import json
import os
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/ci/node_product_cache.py"
spec = importlib.util.spec_from_file_location("node_product_cache", MODULE)
cache = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cache
spec.loader.exec_module(cache)


class NodeProductCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "cache"
        self.store = cache.Store(self.root)
        self.contract = {"tree": "tree-a", "xcode": "Xcode 26", "environment": {"A": "B"}}
        self.product_key = cache._canonical_contract_key(self.contract)
        self.revision = "a" * 40
        self.archive = Path(self.temp.name) / "app-host-products.tar.gz"
        self._write_archive(self.archive, self.contract, self.revision)
        self.archive_digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.identity = cache.Identity(
            repository="manaflow-ai/cmux",
            artifact_id=123,
            provider_digest="b" * 64,
            archive_digest=self.archive_digest,
            product_contract=self.product_key,
            source_revision=self.revision,
            producer_run_id=456,
        )
        self.provider_created_at = "2026-09-21T09:00:00Z"

    def _write_archive(self, path, contract, revision):
        reuse = {"contract": contract, "revision": revision, "run_id": "456", "run_attempt": "1"}
        product = {
            "revision": revision,
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
            payload = b"compiled bytes"
            info = tarfile.TarInfo("Build/Products/Debug/cmux")
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))

    def provider(self, identity=None, digest=None):
        identity = identity or self.identity
        return {
            "id": identity.artifact_id,
            "expired": False,
            "digest": "sha256:" + (digest or identity.provider_digest),
            "workflow_run": {"id": identity.producer_run_id},
            "created_at": self.provider_created_at,
        }

    def reserve(self, identity=None):
        identity = identity or self.identity
        destination = Path(self.temp.name) / f"dest-{time.time_ns()}"
        result = cache.acquire(self.store, identity, destination, wait=0)
        self.assertTrue(result["fill"])
        return result["token"], destination

    def publish(self, identity=None, archive=None, source="github", budget=10**9):
        identity = identity or self.identity
        archive = archive or self.archive
        token, _ = self.reserve(identity)
        result = cache.finalize(
            self.store,
            identity,
            archive,
            token=token,
            source_class=source,
            restore_succeeded=True,
            budget=budget,
            provider_metadata=lambda _: self.provider(identity),
        )
        self.assertEqual(result["status"], "published", result)
        return result

    def test_partial_download_never_publishes_and_releases_fill(self):
        token, _ = self.reserve()
        partial = Path(self.temp.name) / "partial.tar.gz"
        partial.write_bytes(self.archive.read_bytes()[:50])
        result = cache.finalize(
            self.store,
            self.identity,
            partial,
            token=token,
            source_class="github",
            restore_succeeded=True,
            provider_metadata=lambda _: self.provider(),
        )
        self.assertEqual(result["status"], "cache-error")
        self.assertFalse(self.store.entry(self.identity.key()).exists())
        self.assertFalse(self.store.fill(self.identity.key()).exists())

    def test_corrupt_local_object_is_removed_and_becomes_a_fill(self):
        self.publish()
        obj = self.store.entry(self.identity.key()) / cache.OBJECT_NAME
        obj.chmod(0o644)
        obj.write_bytes(b"corrupt")
        destination = Path(self.temp.name) / "corrupt-destination"
        result = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertFalse(result["hit"])
        self.assertTrue(result["fill"])
        self.assertFalse(self.store.entry(self.identity.key()).exists())

    def test_mismatched_provider_digest_never_publishes(self):
        token, _ = self.reserve()
        result = cache.finalize(
            self.store,
            self.identity,
            self.archive,
            token=token,
            source_class="r2",
            restore_succeeded=True,
            provider_metadata=lambda _: self.provider(digest="c" * 64),
        )
        self.assertEqual(result["status"], "cache-error")
        self.assertFalse(self.store.entry(self.identity.key()).exists())
        self.assertFalse(self.store.fill(self.identity.key()).exists())

    def test_interrupted_publication_staging_is_ignored(self):
        junk = self.root / "staging" / "interrupted"
        junk.mkdir()
        (junk / cache.OBJECT_NAME).write_bytes(b"partial")
        destination = Path(self.temp.name) / "interrupted-destination"
        result = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(result["fill"])
        self.assertFalse(result["hit"])
        self.assertTrue(junk.exists())

    def test_concurrent_missing_consumers_coalesce_on_one_fill(self):
        first_dest = Path(self.temp.name) / "first"
        first = cache.acquire(self.store, self.identity, first_dest, wait=1)
        self.assertTrue(first["fill"])
        second_dest = Path(self.temp.name) / "second"
        observed = {}

        def waiter():
            observed.update(cache.acquire(self.store, self.identity, second_dest, wait=2))

        thread = threading.Thread(target=waiter)
        thread.start()
        time.sleep(0.1)
        result = cache.finalize(
            self.store,
            self.identity,
            self.archive,
            token=first["token"],
            source_class="r2",
            restore_succeeded=True,
            provider_metadata=lambda _: self.provider(),
        )
        self.assertEqual(result["status"], "published")
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertTrue(observed["hit"], observed)
        self.assertFalse(observed["fill"])
        self.assertGreater(observed["waited_seconds"], 0)
        self.assertEqual((second_dest / cache.ARCHIVE_NAME).read_bytes(), self.archive.read_bytes())

    def test_consumer_crash_stale_fill_can_be_reclaimed(self):
        token, _ = self.reserve()
        fill_path = self.store.fill(self.identity.key())
        fill = json.loads(fill_path.read_text())
        self.assertEqual(fill["token"], token)
        fill["deadline_epoch"] = time.time() - 1
        fill_path.write_text(json.dumps(fill))
        destination = Path(self.temp.name) / "reclaim-destination"
        result = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(result["fill"])
        self.assertNotEqual(result["token"], token)

    def test_object_deleted_after_lookup_does_not_break_materialized_archive(self):
        self.publish()
        destination = Path(self.temp.name) / "materialized"
        result = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(result["hit"])
        with self.store.lock(self.identity.key()):
            cache._remove_entry_locked(self.store, self.identity.key())
        materialized = destination / cache.ARCHIVE_NAME
        self.assertTrue(materialized.exists())
        self.assertEqual(hashlib.sha256(materialized.read_bytes()).hexdigest(), self.identity.archive_digest)

    def test_disk_full_publication_is_acceleration_only(self):
        token, _ = self.reserve()
        with mock.patch.object(cache, "_copy_verified", side_effect=OSError(28, "disk full")):
            result = cache.finalize(
                self.store,
                self.identity,
                self.archive,
                token=token,
                source_class="github",
                restore_succeeded=True,
                provider_metadata=lambda _: self.provider(),
            )
        self.assertEqual(result["status"], "cache-error")
        self.assertFalse(self.store.entry(self.identity.key()).exists())
        self.assertFalse(self.store.fill(self.identity.key()).exists())

    def test_stale_schema_generation_is_invalidated(self):
        self.publish()
        metadata_path = self.store.entry(self.identity.key()) / cache.METADATA_NAME
        metadata_path.chmod(0o644)
        metadata = json.loads(metadata_path.read_text())
        metadata["schema_generation"] = 0
        metadata_path.write_text(json.dumps(metadata))
        destination = Path(self.temp.name) / "schema-destination"
        result = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(result["fill"])
        self.assertFalse(result["hit"])
        self.assertFalse(self.store.entry(self.identity.key()).exists())

    def test_incompatible_product_contract_is_rejected(self):
        bad = Path(self.temp.name) / "bad-contract.tar.gz"
        self._write_archive(bad, {"tree": "different"}, self.revision)
        bad_digest = hashlib.sha256(bad.read_bytes()).hexdigest()
        identity = cache.Identity(
            repository=self.identity.repository,
            artifact_id=self.identity.artifact_id,
            provider_digest=self.identity.provider_digest,
            archive_digest=bad_digest,
            product_contract=self.product_key,
            source_revision=self.revision,
            producer_run_id=self.identity.producer_run_id,
        )
        token, _ = self.reserve(identity)
        result = cache.finalize(
            self.store,
            identity,
            bad,
            token=token,
            source_class="github",
            restore_succeeded=True,
            provider_metadata=lambda _: self.provider(identity),
        )
        self.assertEqual(result["status"], "cache-error")
        self.assertFalse(self.store.entry(identity.key()).exists())

    def test_failed_canonical_restore_aborts_fill_without_publishing(self):
        token, _ = self.reserve()
        result = cache.finalize(
            self.store,
            self.identity,
            self.archive,
            token=token,
            source_class="r2",
            restore_succeeded=False,
            provider_metadata=lambda _: self.provider(),
        )
        self.assertEqual(result["status"], "aborted")
        self.assertFalse(self.store.fill(self.identity.key()).exists())
        self.assertFalse(self.store.entry(self.identity.key()).exists())

    def test_eviction_skips_an_object_while_its_lock_is_in_use(self):
        self.publish()
        with self.store.lock(self.identity.key(), exclusive=False):
            result = cache.reclaim(self.store, 0)
            self.assertEqual(result["evicted_objects"], 0)
            self.assertTrue(self.store.entry(self.identity.key()).exists())
        result = cache.reclaim(self.store, 0)
        self.assertEqual(result["evicted_objects"], 1)
        self.assertFalse(self.store.entry(self.identity.key()).exists())

    def test_hit_and_verified_restore_update_bounded_measurement(self):
        self.publish(source="r2")
        destination = Path(self.temp.name) / "measured"
        with mock.patch.dict(os.environ, {"CMUX_NODE_PRODUCT_CACHE_FALLBACK_SOURCE": "r2"}):
            hit = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(hit["hit"])
        complete = cache.finalize(
            self.store,
            self.identity,
            destination / cache.ARCHIVE_NAME,
            restore_succeeded=True,
        )
        self.assertEqual(complete["status"], "verified-hit")
        state = json.loads(self.store.state(self.identity.key()).read_text())
        self.assertEqual(state["consumer_hit_count"], 1)
        self.assertEqual(state["verified_restore_count"], 2)
        stats = json.loads((self.root / "state/stats.json").read_text())
        self.assertEqual(stats["hits"], 1)
        self.assertEqual(stats["bytes_avoided_r2"], self.archive.stat().st_size)
        self.assertEqual(hit["snapshot"]["local_hit_rate"], 0.5)


if __name__ == "__main__":
    unittest.main()
