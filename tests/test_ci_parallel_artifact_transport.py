#!/usr/bin/env python3
"""Contract checks for the parallel GitHub artifact transport.

The transport only changes how the pinned exact-ID ZIP is read. Identity,
provider digest, and the inner archive SHA-256 stay mandatory, and every miss
must leave the canonical actions/download-artifact step enabled.
"""

import hashlib
import importlib.util
import io
import json
import lzma
import os
import sys
import tempfile
import unittest
import zipfile
import zlib

import yaml
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
spec = importlib.util.spec_from_file_location(
    "parallel_artifact_download", ROOT / "scripts/ci/parallel_artifact_download.py"
)
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)

WORKFLOW = (ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
CONSUMERS = ("app-host-unit-tests", "tests-build-and-lag")
SOURCE_ORDER = (
    "Try node-local compiled product cache",
    "Try trusted fleet peer artifact source",
    "Restore selective app-host product layers",
    "Try shared R2 artifact transport",
    "Try parallel GitHub artifact transport",
    "Download compiled app-host test product",
)


def job_block(name: str) -> str:
    start = WORKFLOW.index(f"\n  {name}:\n")
    end = WORKFLOW.find("\n  ", WORKFLOW.index("\n    steps:", start))
    while end != -1 and WORKFLOW[end + 3:end + 4] in (" ", "\n", "#"):
        end = WORKFLOW.find("\n  ", end + 1)
    return WORKFLOW[start:end if end != -1 else len(WORKFLOW)]


def step_block(block: str, name: str) -> str:
    start = block.index(f"      - name: {name}\n")
    rest = block[start:]
    following = rest.find("\n      - name:", 1)
    return rest if following == -1 else rest[:following]


def make_zip(member: str, payload: bytes) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_STORED) as zipped:
        zipped.writestr(member, payload)
    return buffer.getvalue()


class WorkflowWiringTests(unittest.TestCase):
    def test_parallel_transport_runs_after_every_cheaper_source(self):
        for job in CONSUMERS:
            block = job_block(job)
            positions = [block.index(f"- name: {name}") for name in SOURCE_ORDER]
            self.assertEqual(positions, sorted(positions), job)

    def test_parallel_transport_is_optional_and_run_scoped(self):
        for job in CONSUMERS:
            step = step_block(job_block(job), "Try parallel GitHub artifact transport")
            self.assertIn("id: parallel-products", step)
            self.assertIn("continue-on-error: true", step)
            self.assertIn("run: python3 scripts/ci/parallel_artifact_download.py", step)
            self.assertIn("ARTIFACT_ID: ${{ needs.macos-compile-admission.outputs.artifact_id }}", step)
            self.assertIn(
                "ARTIFACT_PROVIDER_DIGEST: ${{ needs.macos-compile-admission.outputs.artifact_digest }}", step
            )
            for guard in (
                "steps.node-products.outputs.hit != 'true'",
                "steps.peer-products.outputs.hit != 'true'",
                "steps.restore-layers.outputs.hit != 'true'",
                "steps.r2-products.outputs.hit != 'true'",
            ):
                self.assertIn(guard, step, job)

    def test_restore_step_records_the_transport_it_used(self):
        for job in CONSUMERS:
            step = step_block(job_block(job), "Restore compiled app-host test product")
            self.assertIn("CMUX_PARALLEL_PRODUCT_HIT: ${{ steps.parallel-products.outputs.hit }}", step)
        script = (ROOT / "scripts/ci/restore-app-host-test-product.sh").read_text(encoding="utf-8")
        self.assertIn('"github-parallel" if parallel_hit else', script)
        self.assertIn('echo "$EXPECTED_SHA256  $archive" | shasum -a 256 -c -', script)

    def test_cli_product_lane_keeps_the_consumer_transport_chain(self):
        # cli-product-tests restores the same compiled product without layers,
        # so it must keep the same fast sources, route check and cache finalize.
        block = job_block("cli-product-tests")
        order = (
            "Verify GitHub-hosted route",
            "Checkout",
            "Try node-local compiled product cache",
            "Try trusted fleet peer artifact source",
            "Try shared R2 artifact transport",
            "Try parallel GitHub artifact transport",
            "Download compiled test product",
            "Restore compiled test product",
            "Finalize node-local compiled product cache",
        )
        positions = [block.index(f"- name: {name}\n") for name in order]
        self.assertEqual(positions, sorted(positions))
        parallel = step_block(block, "Try parallel GitHub artifact transport")
        self.assertIn("steps.r2-products.outputs.hit != 'true'", parallel)
        download = step_block(block, "Download compiled test product")
        self.assertIn("steps.parallel-products.outputs.hit != 'true'", download)
        restore = step_block(block, "Restore compiled test product")
        for key in ("CMUX_R2_PRODUCT_HIT", "CMUX_PARALLEL_PRODUCT_HIT", "CMUX_ARTIFACT_R2_RESULT"):
            self.assertIn(f"{key}: ", restore)
        finalize = step_block(block, "Finalize node-local compiled product cache")
        self.assertIn("if: always()", finalize)
        self.assertIn("CMUX_NODE_PRODUCT_CACHE_LEASE: ${{ steps.node-products.outputs.lease }}", finalize)
        self.assertIn("node_product_cache.py finalize", finalize)
        jobs = yaml.safe_load(WORKFLOW)["jobs"]
        # Same permissions: the R2 transport needs id-token to mint its token.
        self.assertEqual(jobs["cli-product-tests"]["permissions"], jobs["app-host-unit-tests"]["permissions"])
        # The two routes differ only by the job's owned_jobs key (#14318) and
        # the shards' pr_shard_runner branch (pr_runner_pool.spread_shards).
        shard_route = step_block(job_block("app-host-unit-tests"), "Verify GitHub-hosted route")
        self.assertIn("inputs.pr_shard_runner || ", shard_route)
        self.assertEqual(
            step_block(block, "Verify GitHub-hosted route").replace("' cli-product '", "KEY").replace("'cli-product'", "LATE"),
            shard_route.replace("format(' shard-{0} ', matrix.shard)", "KEY").replace("format('shard-{0}', matrix.shard)", "LATE")
            .replace("inputs.pr_shard_runner || ", ""),
        )

    def test_layer_transport_prefers_parallel_reads_and_keeps_the_stream_fallback(self):
        source = (ROOT / "scripts/ci/app_host_layer_transport.py").read_text(encoding="utf-8")
        self.assertIn("import parallel_artifact_download", source)
        self.assertIn("parallel_artifact_download.download_zip(", source)
        self.assertIn("self.download_stream(artifact_id, target, limit)", source)


class RangeAssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-parallel-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_ranges_reassemble_the_exact_payload(self):
        payload = os.urandom(70_000)
        target = self.root / "out.bin"

        def fetch(url, start, end, fd, deadline):
            os.pwrite(fd, payload[start:end + 1], start)

        transport.download_ranges(lambda: "https://blob.example/x", target, len(payload),
                                  connections=4, chunk_bytes=4096, fetch=fetch)
        self.assertEqual(target.read_bytes(), payload)

    def test_a_failing_range_fails_the_transfer(self):
        target = self.root / "out.bin"

        def fetch(url, start, end, fd, deadline):
            if start:
                raise transport.TransportError("boom")
            os.pwrite(fd, b"\0" * (end + 1 - start), start)

        with self.assertRaises(transport.TransportError):
            transport.download_ranges(lambda: "https://blob.example/x", target, 8192,
                                      connections=2, chunk_bytes=4096, deadline_seconds=1, fetch=fetch)

    def test_oversized_artifacts_are_refused(self):
        with self.assertRaises(transport.TransportError):
            transport.download_ranges(lambda: "https://blob.example/x", self.root / "out.bin",
                                      transport.MAX_BYTES + 1, fetch=lambda *a: None)


class AggregateRestoreTests(unittest.TestCase):
    ARCHIVE = b"compiled products" * 1000

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-parallel-restore-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.zip_bytes = make_zip("app-host-products.tar.gz", self.ARCHIVE)
        self.digest = hashlib.sha256(self.zip_bytes).hexdigest()

    def metadata(self, **overrides):
        item = {"id": 77, "expired": False, "digest": "sha256:" + self.digest,
                "size_in_bytes": len(self.zip_bytes), "workflow_run": {"id": 9}}
        item.update(overrides)
        return lambda repository, artifact_id, token: item

    def fetch(self, payload=None):
        body = self.zip_bytes if payload is None else payload

        def download(repository, artifact_id, target, size, token):
            Path(target).write_bytes(body)

        return download

    def restore(self, *, metadata=None, fetch=None, destination="app-host-products", **kwargs):
        return transport.restore_aggregate(
            "manaflow-ai/cmux", "77", "9", self.digest, self.root / destination,
            token="t", metadata=metadata or self.metadata(), fetch_zip=fetch or self.fetch(), **kwargs
        )

    def test_verified_product_is_published(self):
        record = self.restore()
        self.assertEqual((self.root / "app-host-products/app-host-products.tar.gz").read_bytes(), self.ARCHIVE)
        self.assertEqual(record["zip_bytes"], len(self.zip_bytes))

    def test_foreign_run_is_rejected(self):
        with self.assertRaises(transport.TransportError):
            self.restore(metadata=self.metadata(workflow_run={"id": 10}))
        self.assertFalse((self.root / "app-host-products").exists())

    def test_provider_digest_mismatch_in_metadata_is_rejected(self):
        with self.assertRaises(transport.TransportError):
            self.restore(metadata=self.metadata(digest="sha256:" + "0" * 64))

    def test_expired_artifact_is_rejected(self):
        with self.assertRaises(transport.TransportError):
            self.restore(metadata=self.metadata(expired=True))

    def test_bytes_that_do_not_match_the_pinned_digest_are_discarded(self):
        tampered = make_zip("app-host-products.tar.gz", self.ARCHIVE + b"x")
        with self.assertRaises(transport.TransportError):
            self.restore(fetch=self.fetch(tampered))
        self.assertFalse((self.root / "app-host-products").exists())

    def test_multi_member_archive_is_rejected(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_STORED) as zipped:
            zipped.writestr("app-host-products.tar.gz", self.ARCHIVE)
            zipped.writestr("extra", b"nope")
        payload = buffer.getvalue()
        digest = hashlib.sha256(payload).hexdigest()
        with self.assertRaises(transport.TransportError):
            transport.restore_aggregate(
                "manaflow-ai/cmux", "77", "9", digest, self.root / "app-host-products", token="t",
                metadata=lambda *a: {"id": 77, "expired": False, "digest": "sha256:" + digest,
                                     "size_in_bytes": len(payload), "workflow_run": {"id": 9}},
                fetch_zip=self.fetch(payload),
            )
        self.assertFalse((self.root / "app-host-products").exists())

    def test_missing_expected_digest_is_rejected(self):
        with self.assertRaises(transport.TransportError):
            transport.restore_aggregate("manaflow-ai/cmux", "77", "9", "", self.root / "app-host-products",
                                        token="t", metadata=self.metadata(), fetch_zip=self.fetch())


class EntryPointTests(unittest.TestCase):
    def test_archive_decoder_errors_are_clean_misses(self):
        for error in (EOFError("truncated member"), zlib.error("bad deflate"),
                      lzma.LZMAError("bad lzma"), NotImplementedError("unsupported codec")):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "github-output"
                with mock.patch.dict(os.environ, {"RUNNER_TEMP": temp, "GITHUB_OUTPUT": str(output)}), \
                        mock.patch.object(transport, "restore_aggregate", side_effect=error):
                    self.assertEqual(transport.main(), 0)
                self.assertEqual(output.read_text().strip(), "hit=false")
                self.assertFalse((Path(temp) / "app-host-products").exists())

    def test_a_miss_reports_no_hit_and_never_fails_the_job(self):
        with tempfile.TemporaryDirectory(prefix="cmux-parallel-main-") as temp:
            output = Path(temp) / "github-output"
            environment = {"GITHUB_OUTPUT": str(output), "RUNNER_TEMP": temp,
                           "GITHUB_REPOSITORY": "manaflow-ai/cmux", "ARTIFACT_ID": "77",
                           "GITHUB_RUN_ID": "9", "ARTIFACT_PROVIDER_DIGEST": "", "GH_TOKEN": ""}
            previous = {key: os.environ.get(key) for key in environment}
            os.environ.update(environment)
            try:
                self.assertEqual(transport.main(), 0)
            finally:
                for key, value in previous.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
            self.assertEqual(output.read_text(encoding="utf-8").strip(), "hit=false")
            self.assertFalse((Path(temp) / "app-host-products").exists())


class RegistrationTests(unittest.TestCase):
    def test_transport_files_run_in_the_artifact_transport_workflow(self):
        workflow = (ROOT / ".github/workflows/ci-artifact-transport.yml").read_text(encoding="utf-8")
        for path in ("scripts/ci/parallel_artifact_download.py", "tests/test_ci_parallel_artifact_transport.py"):
            self.assertIn(f"- {path}\n", workflow)
        self.assertIn("python3 tests/test_ci_parallel_artifact_transport.py", workflow)

    def test_test_is_registered_in_the_execution_registry(self):
        registry = (ROOT / "tests/test-execution.toml").read_text(encoding="utf-8")
        self.assertIn('path = "tests/test_ci_parallel_artifact_transport.py"', registry)


class IOSProductTransportTests(unittest.TestCase):
    """Exercise the same downloader against a real ranged HTTP response."""

    def setUp(self):
        import http.server
        import threading

        self.temp = tempfile.TemporaryDirectory(prefix="cmux-ios-transport-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = os.urandom(70_000)
        self.payload = make_zip("ios-test-product.tar.gz", self.archive)
        self.ranges = []
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()
        self.first_pair = threading.Barrier(2)
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                start, end = map(int, self.headers["Range"].removeprefix("bytes=").split("-"))
                with owner.lock:
                    owner.ranges.append((start, end, self.headers.get("Authorization")))
                    index = len(owner.ranges)
                    owner.active += 1
                    owner.max_active = max(owner.max_active, owner.active)
                try:
                    if index <= 2:
                        owner.first_pair.wait(timeout=5)
                    body = owner.payload[start:end + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(owner.payload)}")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                finally:
                    with owner.lock:
                        owner.active -= 1

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}/artifact.zip"

    def metadata(self, **overrides):
        item = {"id": 77, "expired": False,
                "digest": "sha256:" + hashlib.sha256(self.payload).hexdigest(),
                "size_in_bytes": len(self.payload), "workflow_run": {"id": 9}}
        item.update(overrides)
        return lambda *args: item

    def fetch(self, repository, artifact_id, target, size, token):
        transport.download_ranges(lambda: self.url, target, size, connections=4, chunk_bytes=4096)

    def restore(self, *, kind="ios", digest=None, metadata=None):
        kwargs = {} if kind is None else {"product_kind": kind}
        return transport.restore_aggregate(
            "manaflow-ai/cmux", "77", "9",
            digest or hashlib.sha256(self.payload).hexdigest(), self.root / "product",
            token="must-not-reach-blob", metadata=metadata or self.metadata(),
            fetch_zip=self.fetch, **kwargs,
        )

    def test_ios_archive_is_downloaded_in_parallel_and_published_exactly(self):
        record = self.restore()
        self.assertEqual((self.root / "product/ios-test-product.tar.gz").read_bytes(), self.archive)
        self.assertEqual(record["zip_bytes"], len(self.payload))
        self.assertGreaterEqual(self.max_active, 2)
        self.assertTrue(all(auth is None for _, _, auth in self.ranges))

    def test_ios_member_is_rejected_by_unchanged_macos_default(self):
        with self.assertRaisesRegex(transport.TransportError, "unexpected artifact contents"):
            self.restore(kind=None)
        self.assertFalse((self.root / "product").exists())

    def test_ios_selector_rejects_macos_member_and_path_aliases(self):
        for member in ("app-host-products.tar.gz", "../ios-test-product.tar.gz",
                       "nested/ios-test-product.tar.gz"):
            with self.subTest(member=member):
                self.payload = make_zip(member, self.archive)
                with self.assertRaisesRegex(transport.TransportError, "unexpected artifact contents"):
                    self.restore()
                self.assertFalse((self.root / "product").exists())

    def test_ios_bad_digest_or_size_never_publishes(self):
        digest = hashlib.sha256(self.payload).hexdigest()
        metadata = self.metadata()
        self.payload = make_zip("ios-test-product.tar.gz", self.archive[:-1] + bytes([self.archive[-1] ^ 1]))
        with self.assertRaisesRegex(transport.TransportError, "provider ZIP digest mismatch"):
            self.restore(digest=digest, metadata=metadata)
        self.assertFalse((self.root / "product").exists())
        with self.assertRaisesRegex(transport.TransportError, "provider ZIP digest mismatch"):
            self.restore(metadata=self.metadata(size_in_bytes=len(self.payload) - 1))
        self.assertFalse((self.root / "product").exists())

    def test_ios_foreign_run_or_unpinned_digest_does_not_download(self):
        for override in ({"workflow_run": {"id": 10}}, {"digest": "sha256:" + "0" * 64}):
            with self.subTest(override=override):
                with self.assertRaises(transport.TransportError):
                    self.restore(metadata=self.metadata(**override))
                self.assertEqual(self.ranges, [])
                self.assertFalse((self.root / "product").exists())

    def test_ios_entrypoint_uses_fixed_destination_and_reports_hit_only_after_verification(self):
        output = self.root / "output"
        real_restore = transport.restore_aggregate

        def restore(*args, **kwargs):
            return real_restore(*args, **kwargs, metadata=self.metadata(), fetch_zip=self.fetch)

        env = {"RUNNER_TEMP": str(self.root), "GITHUB_OUTPUT": str(output),
               "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "9",
               "ARTIFACT_ID": "77", "ARTIFACT_PROVIDER_DIGEST": hashlib.sha256(self.payload).hexdigest(),
               "ARTIFACT_PRODUCT_KIND": "ios", "GH_TOKEN": "must-not-reach-blob"}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(transport, "restore_aggregate", side_effect=restore):
            self.assertEqual(transport.main(), 0)
        self.assertEqual((self.root / "ios-test-product/ios-test-product.tar.gz").read_bytes(), self.archive)
        self.assertFalse((self.root / "app-host-products").exists())
        self.assertIn("hit=true", output.read_text())

    def test_ios_entrypoint_integrity_miss_enables_canonical_fallback(self):
        output = self.root / "output"
        real_restore = transport.restore_aggregate

        def restore(*args, **kwargs):
            return real_restore(*args, **kwargs, metadata=self.metadata(), fetch_zip=self.fetch)

        env = {"RUNNER_TEMP": str(self.root), "GITHUB_OUTPUT": str(output),
               "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "10",
               "ARTIFACT_ID": "77", "ARTIFACT_PROVIDER_DIGEST": hashlib.sha256(self.payload).hexdigest(),
               "ARTIFACT_PRODUCT_KIND": "ios", "GH_TOKEN": "must-not-reach-blob"}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(transport, "restore_aggregate", side_effect=restore):
            self.assertEqual(transport.main(), 0)
        self.assertEqual(output.read_text().strip(), "hit=false")
        self.assertFalse((self.root / "ios-test-product").exists())
        self.assertEqual(self.ranges, [])

    def test_unknown_kind_cannot_choose_a_destination(self):
        output = self.root / "output"
        with mock.patch.dict(os.environ, {"RUNNER_TEMP": str(self.root),
                             "GITHUB_OUTPUT": str(output),
                             "ARTIFACT_PRODUCT_KIND": "../elsewhere"}, clear=True):
            self.assertEqual(transport.main(), 0)
        self.assertEqual(output.read_text().strip(), "hit=false")
        self.assertEqual(list(self.root.iterdir()), [output])


if __name__ == "__main__":
    unittest.main(verbosity=2)
