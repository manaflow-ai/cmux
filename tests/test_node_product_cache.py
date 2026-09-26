#!/usr/bin/env python3
"""Exercise the node-local immutable compiled-product cache without network."""

import errno
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
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/ci/node_product_cache.py"
spec = importlib.util.spec_from_file_location("node_product_cache", MODULE)
cache = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cache
spec.loader.exec_module(cache)

PEER_MODULE = ROOT / "scripts/ci/peer_product_source.py"
peer_spec = importlib.util.spec_from_file_location("peer_product_source", PEER_MODULE)
peer = importlib.util.module_from_spec(peer_spec)
sys.modules[peer_spec.name] = peer
peer_spec.loader.exec_module(peer)


class ConfiguredRootTests(unittest.TestCase):
    def test_owned_runners_get_the_default_root(self):
        for name in ("cmux12s-mac-mini-glaeda", "cmux12s-mac-mini-glaeda-3", "cmux14-glaeda-1"):
            self.assertEqual(cache.configured_root({"RUNNER_NAME": name}), cache.OWNED_DEFAULT_ROOT, name)

    def test_disposable_runners_keep_no_store(self):
        for name in ("", "blacksmith-6vcpu-macos-26-Runner-abc", "GitHub Actions 12", "glaeda", "x-glaeda-1b"):
            self.assertIsNone(cache.configured_root({"RUNNER_NAME": name}), name)
            self.assertIsNone(cache.configured_store({"RUNNER_NAME": name}), name)

    def test_the_variable_wins_and_off_disables(self):
        self.assertEqual(cache.configured_root({"CMUX_NODE_PRODUCT_CACHE_ROOT": "/tmp/x",
                                                "RUNNER_NAME": "cmux14-glaeda"}), "/tmp/x")
        self.assertEqual(cache.configured_root({"CMUX_NODE_PRODUCT_CACHE_ROOT": "/tmp/x",
                                                "RUNNER_NAME": "blacksmith-1"}), "/tmp/x")
        for value in ("off", "OFF", " off "):
            self.assertIsNone(cache.configured_root({"CMUX_NODE_PRODUCT_CACHE_ROOT": value,
                                                     "RUNNER_NAME": "cmux14-glaeda"}))

    def test_ci_waiters_do_not_wait_for_another_fill_by_default(self):
        self.assertEqual(cache.wait_seconds({}), 0.0)
        self.assertEqual(cache.wait_seconds({"CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS": "bad"}), 0.0)
        self.assertEqual(cache.wait_seconds({"CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS": "90"}), 90.0)

    def test_an_owned_runner_opens_a_store_at_the_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(cache, "OWNED_DEFAULT_ROOT", str(Path(tmp) / "node-products")):
                store = cache.configured_store({"RUNNER_NAME": "cmux8s-mac-mini-glaeda-2"})
            self.assertIsNotNone(store)
            self.assertTrue((Path(tmp) / "node-products" / "objects").is_dir())


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

    def test_publication_keeps_staging_writable_until_atomic_rename(self):
        real_rename = os.rename
        saw_publish = []

        def checked_rename(source, destination):
            source = Path(source)
            destination = Path(destination)
            if source.parent == self.root / "staging":
                saw_publish.append(True)
                self.assertTrue(source.stat().st_mode & 0o200)
            return real_rename(source, destination)

        with mock.patch.object(cache.os, "rename", side_effect=checked_rename):
            self.publish()
        self.assertEqual(saw_publish, [True])

    def test_interrupted_publication_staging_is_ignored(self):
        junk = self.root / "staging" / f"{self.identity.key()}.interrupted"
        junk.mkdir()
        (junk / cache.OBJECT_NAME).write_bytes(b"partial")
        destination = Path(self.temp.name) / "interrupted-destination"
        result = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(result["fill"])
        self.assertFalse(result["hit"])
        self.assertTrue(junk.exists())
        reclaimed = cache.reclaim(self.store, 10**9)
        self.assertEqual(reclaimed["staging_reclaims"], 1)
        self.assertEqual(reclaimed["staging_reclaimed_bytes"], len(b"partial"))
        self.assertFalse(junk.exists())

    def test_departed_fifo_waiter_does_not_fail_completion_signal(self):
        key = self.identity.key()
        waiter = "a" * 32
        with (
            mock.patch.object(cache.os, "open", return_value=99),
            mock.patch.object(
                cache.os,
                "write",
                side_effect=BrokenPipeError(errno.EPIPE, "waiter departed"),
            ),
            mock.patch.object(cache.os, "close") as close,
        ):
            cache._signal_waiters(self.store, key, [waiter])
        close.assert_called_once_with(99)

    def test_concurrent_missing_consumers_coalesce_on_one_fill(self):
        first_dest = Path(self.temp.name) / "first"
        first = cache.acquire(self.store, self.identity, first_dest, wait=1)
        self.assertTrue(first["fill"])
        second_dest = Path(self.temp.name) / "second"
        observed = {}
        waiter_registered = threading.Event()
        real_wait = cache._wait_for_fill_signal

        def wait_for_signal(read_fd, timeout):
            waiter_registered.set()
            return real_wait(read_fd, timeout)

        def waiter():
            observed.update(cache.acquire(self.store, self.identity, second_dest, wait=2))

        with mock.patch.object(cache, "_wait_for_fill_signal", side_effect=wait_for_signal):
            thread = threading.Thread(target=waiter)
            thread.start()
            self.assertTrue(waiter_registered.wait(1), "waiter never registered its FIFO signal")
            fill = json.loads(self.store.fill(self.identity.key()).read_text())
            self.assertEqual(len(fill["waiters"]), 1)

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
        self.assertEqual((second_dest / cache.ARCHIVE_NAME).read_bytes(), self.archive.read_bytes())

    def test_seven_consumer_persistent_node_fanout_uses_one_transfer(self):
        owner_destination = Path(self.temp.name) / "fanout-owner"
        consumer_destinations = [
            Path(self.temp.name) / f"fanout-consumer-{index}"
            for index in range(6)
        ]
        results = [None] * len(consumer_destinations)

        with mock.patch.dict(
            os.environ,
            {"CMUX_NODE_PRODUCT_CACHE_FALLBACK_SOURCE": "r2"},
        ):
            owner = cache.acquire(
                self.store,
                self.identity,
                owner_destination,
                wait=1,
            )
            self.assertTrue(owner["fill"])

            def waiter(index):
                results[index] = cache.acquire(
                    self.store,
                    self.identity,
                    consumer_destinations[index],
                    wait=3,
                )

            threads = [
                threading.Thread(target=waiter, args=(index,))
                for index in range(len(consumer_destinations))
            ]
            waiters_registered = threading.Event()
            registration_lock = threading.Lock()
            registration_count = 0
            real_wait = cache._wait_for_fill_signal

            def wait_for_signal(read_fd, timeout):
                nonlocal registration_count
                with registration_lock:
                    registration_count += 1
                    if registration_count == len(consumer_destinations):
                        waiters_registered.set()
                return real_wait(read_fd, timeout)

            with mock.patch.object(cache, "_wait_for_fill_signal", side_effect=wait_for_signal):
                for thread in threads:
                    thread.start()
                self.assertTrue(waiters_registered.wait(2), "fan-out waiters never registered")
                fill = json.loads(self.store.fill(self.identity.key()).read_text())
                self.assertEqual(len(fill["waiters"]), len(consumer_destinations))

                published = cache.finalize(
                    self.store,
                    self.identity,
                    self.archive,
                    token=owner["token"],
                    source_class="r2",
                    restore_succeeded=True,
                    provider_metadata=lambda _: self.provider(),
                )
                self.assertEqual(published["status"], "published")

                for thread in threads:
                    thread.join(3)
                    self.assertFalse(thread.is_alive())

            for result, destination in zip(results, consumer_destinations):
                self.assertIsNotNone(result)
                self.assertTrue(result["hit"], result)
                completed = cache.finalize(
                    self.store,
                    self.identity,
                    destination / cache.ARCHIVE_NAME,
                    lease_token=result["lease"],
                    restore_succeeded=True,
                )
                self.assertEqual(completed["status"], "verified-hit")

        stats = json.loads((self.root / "state/stats.json").read_text())
        state = json.loads(self.store.state(self.identity.key()).read_text())
        archive_bytes = self.archive.stat().st_size
        snapshot = cache._snapshot(self.store, stats)

        self.assertEqual(stats["lookups"], 7)
        self.assertEqual(stats["fill_owners"], 1)
        self.assertEqual(stats["hits"], 6)
        self.assertEqual(stats["bytes_avoided_r2"], archive_bytes * 6)
        self.assertEqual(stats["bytes_avoided_github"], 0)
        self.assertEqual(snapshot["local_hit_rate"], round(6 / 7, 4))
        self.assertEqual(snapshot["disk_bytes"], archive_bytes)
        self.assertEqual(snapshot["eviction_rate"], 0)
        self.assertEqual(state["verified_restore_count"], 7)

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

    def test_eviction_skips_an_object_while_restore_lease_is_active(self):
        self.publish()
        destination = Path(self.temp.name) / "leased"
        hit = cache.acquire(self.store, self.identity, destination, wait=0)
        self.assertTrue(hit["hit"])
        self.assertTrue(hit["lease"])
        result = cache.reclaim(self.store, 0)
        self.assertEqual(result["evicted_objects"], 0)
        self.assertTrue(self.store.entry(self.identity.key()).exists())
        cache.finalize(
            self.store,
            self.identity,
            destination / cache.ARCHIVE_NAME,
            lease_token=hit["lease"],
            restore_succeeded=True,
        )
        result = cache.reclaim(self.store, 0)
        self.assertEqual(result["evicted_objects"], 1)
        self.assertFalse(self.store.entry(self.identity.key()).exists())

    def test_consumer_crash_lease_expires_before_reclamation(self):
        self.publish()
        destination = Path(self.temp.name) / "crashed-consumer"
        hit = cache.acquire(self.store, self.identity, destination, wait=0)
        lease_path = self.store.lease(self.identity.key(), hit["lease"])
        lease = json.loads(lease_path.read_text())
        lease["deadline_epoch"] = time.time() - 1
        lease_path.write_text(json.dumps(lease))
        result = cache.reclaim(self.store, 0)
        self.assertEqual(result["evicted_objects"], 1)
        self.assertFalse(lease_path.exists())

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
            lease_token=hit["lease"],
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


    def test_peer_transfer_uses_one_absolute_deadline_across_reads(self):
        destination = Path(self.temp.name) / "peer-deadline.tar.gz"
        clock = {"now": 0.0}
        timeouts = []

        class FakeSocket:
            def settimeout(self, value):
                timeouts.append(value)

        class FakeResponse:
            status = 200

            def __init__(self):
                self.chunks = [b"a", b"b"]

            def getheader(self, name, default=None):
                if name == "Content-Length":
                    return "2"
                return default

            def read(self, _size=-1):
                clock["now"] += 0.6
                if self.chunks:
                    return self.chunks.pop(0)
                return b""

            read1 = read

        class FakeConnection:
            def __init__(self):
                self.timeout = 1.0
                self.sock = FakeSocket()
                self.response = FakeResponse()

            def request(self, *_args, **_kwargs):
                return None

            def getresponse(self):
                return self.response

            def close(self):
                return None

        connection = FakeConnection()
        with mock.patch.object(
            peer.time,
            "monotonic",
            side_effect=lambda: clock["now"],
        ):
            with mock.patch.object(
                peer,
                "_connection",
                return_value=(connection, "peer.example"),
            ):
                with self.assertRaisesRegex(
                    peer.PeerUnavailable,
                    "deadline exceeded",
                ):
                    peer.transfer_http(
                        peer.PeerSource("https://peer.example"),
                        "a" * 64,
                        "read-token",
                        destination,
                        2,
                        timeout=1.0,
                    )

        self.assertEqual(destination.read_bytes(), b"ab")
        self.assertGreaterEqual(len(timeouts), 2)
        self.assertGreater(timeouts[0], timeouts[-1])

    def test_peer_transfer_rearms_deadline_before_each_underlying_receive(self):
        destination = Path(self.temp.name) / "peer-receive-deadline.tar.gz"
        clock = {"now": 0.0}
        timeouts = []

        class FakeSocket:
            def settimeout(self, value):
                timeouts.append(value)

        class FakeResponse:
            status = 200

            def __init__(self):
                self.chunks = [b"a", b"b"]

            def getheader(self, name, default=None):
                if name == "Content-Length":
                    return "2"
                return default

            def read(self, _size=-1):
                raise AssertionError("buffered response.read must not own the peer deadline")

            def read1(self, _size=-1):
                clock["now"] += 0.6
                if self.chunks:
                    return self.chunks.pop(0)
                return b""

        class FakeConnection:
            def __init__(self):
                self.timeout = 1.0
                self.sock = FakeSocket()
                self.response = FakeResponse()

            def request(self, *_args, **_kwargs):
                return None

            def getresponse(self):
                return self.response

            def close(self):
                return None

        connection = FakeConnection()
        with mock.patch.object(
            peer.time,
            "monotonic",
            side_effect=lambda: clock["now"],
        ):
            with mock.patch.object(
                peer,
                "_connection",
                return_value=(connection, "peer.example"),
            ):
                with self.assertRaisesRegex(
                    peer.PeerUnavailable,
                    "deadline exceeded",
                ):
                    peer.transfer_http(
                        peer.PeerSource("https://peer.example"),
                        "a" * 64,
                        "read-token",
                        destination,
                        2,
                        timeout=1.0,
                    )

        self.assertEqual(destination.read_bytes(), b"ab")
        self.assertGreaterEqual(len(timeouts), 2)
        self.assertGreater(timeouts[0], timeouts[-1])


    def test_peer_server_bounds_client_time_and_active_requests(self):
        server = peer.PeerHTTPServer(
            ("127.0.0.1", 0),
            peer.PeerRequestHandler,
            store=self.store,
            token="read-token",
            drain_marker=None,
            client_timeout_seconds=0.25,
            max_active_requests=1,
        )
        self.addCleanup(server.server_close)

        client = peer.socket.create_connection(server.server_address, timeout=1)
        accepted = None
        try:
            accepted, _ = server.get_request()
            self.assertAlmostEqual(accepted.gettimeout(), 0.25)
        finally:
            if accepted is not None:
                accepted.close()
            client.close()

        self.assertTrue(server._request_slots.acquire(blocking=False))
        try:
            request = mock.Mock()
            with mock.patch.object(server, "shutdown_request") as shutdown:
                server.process_request(request, ("127.0.0.1", 1))
                shutdown.assert_called_once_with(request)
        finally:
            server._request_slots.release()

    def test_peer_probe_and_fetch_use_only_exact_object_identity(self):
        self.publish()
        offer = peer.local_availability(self.store, self.identity.key())
        self.assertIsNotNone(offer)
        self.assertEqual(offer.object_key, self.identity.key())
        self.assertEqual(offer.content_digest, self.identity.archive_digest)
        self.assertEqual(offer.size_bytes, self.archive.stat().st_size)

        calls = []
        destination = Path(self.temp.name) / "peer-products"
        sources = [peer.PeerSource("https://peer-a.example")]

        def probe(source, object_key, token):
            calls.append(("probe", source.url, object_key, token))
            return offer

        def transfer(source, object_key, token, target, size):
            calls.append(("fetch", source.url, object_key, token, size))
            target.write_bytes(self.archive.read_bytes())

        result = peer.fetch_exact(
            self.identity,
            destination,
            sources,
            probe=probe,
            transfer=transfer,
            token_loader=lambda _: "read-token",
        )
        self.assertTrue(result["hit"], result)
        self.assertEqual(result["source"], "peer")
        self.assertEqual(result["bytes_transferred"], self.archive.stat().st_size)
        self.assertEqual(
            (destination / cache.ARCHIVE_NAME).read_bytes(),
            self.archive.read_bytes(),
        )
        self.assertEqual([call[0] for call in calls], ["probe", "fetch"])
        self.assertTrue(all(call[2] == self.identity.key() for call in calls))

    def test_corrupt_peer_object_becomes_a_miss_without_partial_destination(self):
        self.publish()
        offer = peer.local_availability(self.store, self.identity.key())
        destination = Path(self.temp.name) / "corrupt-peer-products"

        def transfer(_source, _key, _token, target, _size):
            target.write_bytes(b"corrupt")

        result = peer.fetch_exact(
            self.identity,
            destination,
            [peer.PeerSource("https://peer-a.example")],
            probe=lambda *_: offer,
            transfer=transfer,
            token_loader=lambda _: "read-token",
        )
        self.assertFalse(result["hit"], result)
        self.assertEqual(result["status"], "miss")
        self.assertFalse(destination.exists())

    def test_peer_death_mid_transfer_falls_through_to_later_peer(self):
        self.publish()
        offer = peer.local_availability(self.store, self.identity.key())
        destination = Path(self.temp.name) / "peer-failover"
        transfers = []

        def transfer(source, _key, _token, target, _size):
            transfers.append(source.url)
            if source.url.endswith("peer-a.example"):
                target.write_bytes(self.archive.read_bytes()[:64])
                raise TimeoutError("peer disappeared")
            target.write_bytes(self.archive.read_bytes())

        result = peer.fetch_exact(
            self.identity,
            destination,
            [
                peer.PeerSource("https://peer-a.example"),
                peer.PeerSource("https://peer-b.example"),
            ],
            probe=lambda *_: offer,
            transfer=transfer,
            token_loader=lambda _: "read-token",
        )
        self.assertTrue(result["hit"], result)
        self.assertEqual(result["source_index"], 1)
        self.assertEqual(
            transfers,
            ["https://peer-a.example", "https://peer-b.example"],
        )

    def test_peer_identity_mismatch_never_uses_filename_equivalence(self):
        self.publish()
        offer = peer.local_availability(self.store, self.identity.key())
        wrong = peer.PeerAvailability(
            object_key="f" * 64,
            schema_generation=offer.schema_generation,
            size_bytes=offer.size_bytes,
            content_digest=offer.content_digest,
        )
        destination = Path(self.temp.name) / "wrong-peer-products"
        result = peer.fetch_exact(
            self.identity,
            destination,
            [peer.PeerSource("https://peer-a.example")],
            probe=lambda *_: wrong,
            transfer=lambda *_: self.fail("identity mismatch must refuse before fetch"),
            token_loader=lambda _: "read-token",
        )
        self.assertFalse(result["hit"], result)
        self.assertFalse(destination.exists())

    def test_consumer_cancellation_cleans_partial_peer_transfer(self):
        self.publish()
        offer = peer.local_availability(self.store, self.identity.key())
        destination = Path(self.temp.name) / "cancelled-peer-products"

        def transfer(_source, _key, _token, target, _size):
            target.write_bytes(self.archive.read_bytes()[:64])
            raise KeyboardInterrupt()

        with self.assertRaises(KeyboardInterrupt):
            peer.fetch_exact(
                self.identity,
                destination,
                [peer.PeerSource("https://peer-a.example")],
                probe=lambda *_: offer,
                transfer=transfer,
                token_loader=lambda _: "read-token",
            )
        self.assertFalse(destination.exists())

    def test_source_drain_blocks_new_transfer_but_keeps_existing_lease_valid(self):
        self.publish()
        draining = {"value": False}
        with peer.open_local_object(
            self.store,
            self.identity.key(),
            draining=lambda: draining["value"],
        ) as opened:
            self.assertEqual(opened.path.read_bytes(), self.archive.read_bytes())
            draining["value"] = True
            self.assertTrue(opened.path.exists())
            with self.assertRaises(peer.PeerUnavailable):
                with peer.open_local_object(
                    self.store,
                    self.identity.key(),
                    draining=lambda: draining["value"],
                ):
                    pass
        result = cache.reclaim(self.store, 0)
        self.assertEqual(result["evicted_objects"], 1)

    def test_six_waiters_share_one_peer_fill_and_publish_one_object(self):
        owner_destination = Path(self.temp.name) / "peer-owner"
        owner = cache.acquire(self.store, self.identity, owner_destination, wait=1)
        self.assertTrue(owner["fill"])
        waiter_destinations = [
            Path(self.temp.name) / f"peer-waiter-{index}" for index in range(6)
        ]
        waiter_results = [None] * 6

        def waiter(index):
            waiter_results[index] = cache.acquire(
                self.store, self.identity, waiter_destinations[index], wait=3
            )

        registrations = 0
        registration_lock = threading.Lock()
        all_registered = threading.Event()
        register_waiter = cache._register_waiter_locked

        def tracked_register(*args, **kwargs):
            nonlocal registrations
            result = register_waiter(*args, **kwargs)
            if result is not None:
                with registration_lock:
                    registrations += 1
                    if registrations == len(waiter_destinations):
                        all_registered.set()
            return result

        threads = [threading.Thread(target=waiter, args=(index,)) for index in range(6)]
        with mock.patch.object(
            cache,
            "_register_waiter_locked",
            side_effect=tracked_register,
        ):
            for thread in threads:
                thread.start()
            self.assertTrue(
                all_registered.wait(3),
                "all waiter registrations must exist before peer publication",
            )

        peer_store = cache.Store(Path(self.temp.name) / "peer-source-store")
        token = cache.acquire(
            peer_store,
            self.identity,
            Path(self.temp.name) / "peer-source-owner",
            wait=0,
        )["token"]
        seeded = cache.finalize(
            peer_store,
            self.identity,
            self.archive,
            token=token,
            source_class="github",
            restore_succeeded=True,
            provider_metadata=lambda _: self.provider(),
        )
        self.assertEqual(seeded["status"], "published")
        offer = peer.local_availability(peer_store, self.identity.key())
        fetch_calls = []

        def transfer(_source, _key, _token, target, _size):
            fetch_calls.append(1)
            with peer.open_local_object(
                peer_store, self.identity.key(), draining=lambda: False
            ) as opened:
                target.write_bytes(opened.path.read_bytes())

        peer_result = peer.fetch_exact(
            self.identity,
            owner_destination,
            [peer.PeerSource("https://peer-a.example")],
            probe=lambda *_: offer,
            transfer=transfer,
            token_loader=lambda _: "read-token",
        )
        self.assertTrue(peer_result["hit"])
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_REPOSITORY": self.identity.repository,
                "GITHUB_RUN_ID": str(self.identity.producer_run_id),
                "GITHUB_RUN_ATTEMPT": str(self.identity.producer_run_attempt),
            },
            clear=False,
        ):
            published = cache.finalize(
                self.store,
                self.identity,
                owner_destination / cache.ARCHIVE_NAME,
                token=owner["token"],
                source_class="peer",
                restore_succeeded=True,
                provider_metadata=cache.same_run_provider_metadata,
            )
        self.assertEqual(published["status"], "published", published)

        for thread in threads:
            thread.join(3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(len(fetch_calls), 1)
        self.assertTrue(all(result["hit"] for result in waiter_results))
        self.assertEqual(
            len(list((self.root / "objects" / self.identity.key()[:2]).iterdir())),
            1,
        )

    def test_two_nodes_can_miss_and_install_the_same_peer_object_independently(self):
        source_store = cache.Store(Path(self.temp.name) / "peer-source-two-node")
        token = cache.acquire(
            source_store,
            self.identity,
            Path(self.temp.name) / "source-fill",
            wait=0,
        )["token"]
        cache.finalize(
            source_store,
            self.identity,
            self.archive,
            token=token,
            source_class="github",
            restore_succeeded=True,
            provider_metadata=lambda _: self.provider(),
        )
        offer = peer.local_availability(source_store, self.identity.key())
        roots = [
            cache.Store(Path(self.temp.name) / "node-a"),
            cache.Store(Path(self.temp.name) / "node-b"),
        ]
        results = []
        for index, store in enumerate(roots):
            destination = Path(self.temp.name) / f"node-{index}-product"
            owner = cache.acquire(store, self.identity, destination, wait=0)
            self.assertTrue(owner["fill"])
            fetched = peer.fetch_exact(
                self.identity,
                destination,
                [peer.PeerSource("https://peer-a.example")],
                probe=lambda *_: offer,
                transfer=lambda _source, _key, _token, target, _size: target.write_bytes(
                    self.archive.read_bytes()
                ),
                token_loader=lambda _: "read-token",
            )
            self.assertTrue(fetched["hit"])
            with mock.patch.dict(
                os.environ,
                {
                    "GITHUB_REPOSITORY": self.identity.repository,
                    "GITHUB_RUN_ID": str(self.identity.producer_run_id),
                    "GITHUB_RUN_ATTEMPT": str(self.identity.producer_run_attempt),
                },
                clear=False,
            ):
                results.append(
                    cache.finalize(
                        store,
                        self.identity,
                        destination / cache.ARCHIVE_NAME,
                        token=owner["token"],
                        source_class="peer",
                        restore_succeeded=True,
                        provider_metadata=cache.same_run_provider_metadata,
                    )
                )
        self.assertTrue(all(result["status"] == "published" for result in results))
        self.assertTrue(
            all(store.entry(self.identity.key()).exists() for store in roots)
        )


if __name__ == "__main__":
    unittest.main()
