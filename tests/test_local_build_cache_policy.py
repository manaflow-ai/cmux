"""Executable local-only reload and compressed explicit-warmup contracts."""
import fcntl
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import unittest

import test_local_build_cache_preflight as fixtures


class CachePolicyTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.PreflightTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.root = self.fixture.root
        self.repo = self.fixture.repo
        self.cache = self.fixture.cache
        self.destination = self.fixture.destination
        # Preserve a real workspace output: no Ghostty download is needed here.
        (self.repo / "GhosttyKit.xcframework").mkdir()
        (self.repo / "GhosttyKit.xcframework/Info.plist").write_text("existing")
        arch = {"arm64": "ARM64", "x86_64": "X64"}.get(fixtures.preflight.platform.machine(), "unsupported")
        self.namespace = "macOS-" + arch
        self.public = self.root / "public"
        objects = self.public / "v1" / self.namespace / "objects"
        objects.mkdir(parents=True)
        self.remote_archive = objects / (self.fixture.key + ".tar.gz")
        shutil.copyfile(self.fixture.archive, self.remote_archive)
        self.requests = []
        requests = self.requests

        class Handler(SimpleHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                return super().do_GET()

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(self.public)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.url = "http://127.0.0.1:" + str(self.server.server_port)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def invoke(self, *, warm=False, timeout=10):
        receipt = self.root / ("warm.json" if warm else "local.json")
        command = [sys.executable, str(fixtures.ROOT / "scripts/local-build-cache-preflight.py"),
                   "--repo", str(self.repo), "--cache-root", str(self.cache),
                   "--receipt", str(receipt), "--timeout", "30"]
        if warm:
            command += ["--warm"]
        else:
            command += ["--source-packages-dir", str(self.destination)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                    env=dict(os.environ, CI_CACHE_R2_PUBLIC_URL=self.url))
        except subprocess.TimeoutExpired:
            self.fail("Local cache lookup blocked behind work it should skip")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(receipt.read_text())

    def test_default_miss_never_contacts_cache_server(self):
        receipt = self.invoke()
        self.assertEqual(self.requests, [])
        self.assertEqual(receipt["swiftpm"]["status"], "miss")
        self.assertFalse(self.destination.exists())

    def test_explicit_compressed_warmup_then_network_free_local_reuse(self):
        receipt = self.invoke(warm=True)
        self.assertEqual(receipt["swiftpm"]["status"], "warmed")
        self.assertFalse(self.destination.exists())
        object_requests = [path for path in self.requests if "/objects/" in path]
        self.assertTrue(object_requests)
        self.assertTrue(all(path.endswith((".tar.gz", ".tar.zst")) for path in object_requests))
        self.assertEqual((self.repo / "GhosttyKit.xcframework/Info.plist").read_text(), "existing")
        self.requests.clear()
        receipt = self.invoke()
        self.assertEqual(receipt["swiftpm"]["status"], "hit")
        self.assertEqual(self.requests, [])
        self.assertEqual((self.destination / "checkouts/package/file.swift").read_text(), "source")
        self.assertFalse((self.destination / "workspace-state.json").exists())

    def test_second_warmup_does_not_download_the_same_seed(self):
        self.invoke(warm=True)
        self.requests.clear()
        receipt = self.invoke(warm=True)
        self.assertEqual(receipt["swiftpm"]["status"], "warmed")
        self.assertEqual(self.requests, [])

    def test_changed_lockfile_can_reuse_a_local_prefix_seed_without_download(self):
        self.invoke(warm=True)
        (self.repo / fixtures.preflight.LOCKFILE).write_bytes(b"different resolved dependencies")
        self.requests.clear()
        receipt = self.invoke()
        self.assertEqual(receipt["swiftpm"]["status"], "hit")
        self.assertEqual(receipt["swiftpm"]["match"], "prefix")
        self.assertEqual(receipt["swiftpm"]["matched_key"], self.fixture.key)
        self.assertEqual(self.requests, [])

    def test_local_miss_does_not_wait_for_shared_download_lock(self):
        origin = hashlib.sha256(self.url.encode()).hexdigest()[:16]
        lock = self.cache / "spm" / origin / self.namespace / (self.fixture.key + ".lock")
        lock.parent.mkdir(parents=True)
        with lock.open("w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            receipt = self.invoke(timeout=3)
        self.assertEqual(receipt["swiftpm"]["status"], "miss")
        self.assertEqual(self.requests, [])

    def test_uncompressed_response_is_not_published_as_a_seed(self):
        # A compressed suffix is insufficient: the payload must really decode.
        self.remote_archive.write_bytes(b"uncompressed cache payload")
        receipt = self.invoke(warm=True)
        self.assertEqual(receipt["swiftpm"]["status"], "miss")
        self.assertEqual(list(self.cache.rglob("SourcePackages")), [])
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
