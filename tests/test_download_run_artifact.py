#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/download-run-artifact.py's ranged download.

A local HTTP server serves one blob by byte range and can stall, reset or
throttle chosen requests, so the tests check that a stalled range fails within
the read timeout, resumes from the byte it reached against a fresh URL, backs
off connections on throttling, and gives up on a round with no progress.
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import socket
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "download-run-artifact.py"
spec = importlib.util.spec_from_file_location("download_run_artifact", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

BLOB = os.urandom(3 * 1024 * 1024 + 17)


class BlobServer:
    """Serves BLOB by range. `behave(request_index, lo)` picks each answer."""

    def __init__(self, behave) -> None:
        self.behave = behave
        self.requests: list[tuple[str, int, int]] = []
        self.lock = threading.Lock()
        self.release = threading.Event()
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:  # noqa: D102
                pass

            def do_GET(self) -> None:  # noqa: N802
                lo, hi = (int(x) for x in self.headers["Range"].removeprefix("bytes=").split("-"))
                with server.lock:
                    index = len(server.requests)
                    server.requests.append((self.path, lo, hi))
                action = server.behave(index, lo)
                if action == "429":
                    self.send_response(429)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                body = BLOB[lo:hi + 1]
                self.send_response(206)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if action in ("stall", "reset"):
                    half = len(body) // 2
                    self.wfile.write(body[:half])
                    self.wfile.flush()
                    if action == "stall":
                        server.release.wait(30)
                    else:
                        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
                    self.connection.close()
                    return
                self.wfile.write(body)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.resolved = 0

    def resolve(self, artifact, token, timeout=60) -> str:
        self.resolved += 1
        return f"http://127.0.0.1:{self.httpd.server_address[1]}/blob?sig={self.resolved}"

    def close(self) -> None:
        self.release.set()
        self.httpd.shutdown()
        self.httpd.server_close()


class DownloadTests(unittest.TestCase):
    def run_download(self, behave, connections=4, read_timeout=5.0, deadline=60.0, piece=256 * 1024):
        server = BlobServer(behave)
        self.addCleanup(server.close)
        tmp = tempfile.mkdtemp()
        dest = os.path.join(tmp, "artifact.zip")
        artifact = {"size_in_bytes": len(BLOB), "archive_download_url": "unused"}
        started = time.monotonic()
        error = None
        try:
            module.download(artifact, "token", dest, connections, read_timeout, deadline,
                            resolve_url=server.resolve, piece=piece)
        except SystemExit as exit_error:
            error = exit_error
        elapsed = time.monotonic() - started
        data = Path(dest).read_bytes()
        return server, data, elapsed, error

    def test_plan_ranges_covers_blob_with_pieces_and_one_per_connection(self) -> None:
        for size, connections, piece in [(len(BLOB), 4, 256 * 1024), (12_058_211, 16, 8 << 20), (1, 32, 8 << 20)]:
            ranges = module.plan_ranges(size, connections, piece)
            self.assertEqual(ranges[0][0], 0)
            self.assertEqual(ranges[-1][1], size - 1)
            for (_, hi), (lo, _) in zip(ranges, ranges[1:]):
                self.assertEqual(lo, hi + 1)
            self.assertTrue(all(hi - lo + 1 <= piece for lo, hi in ranges))
            self.assertGreaterEqual(len(ranges), min(connections, size))
        # A large archive gets many small pieces, not one range per connection.
        self.assertEqual(len(module.plan_ranges(293_091_186, 32, 8 << 20)), 35)

    def test_clean_download_matches_blob(self) -> None:
        server, data, _, error = self.run_download(lambda index, lo: "ok")
        self.assertIsNone(error)
        self.assertEqual(hashlib.sha256(data).digest(), hashlib.sha256(BLOB).digest())
        self.assertEqual(server.resolved, 1)

    def test_stalled_range_times_out_fast_and_resumes_with_fresh_url(self) -> None:
        server, data, elapsed, error = self.run_download(
            lambda index, lo: "stall" if index == 0 else "ok", read_timeout=1.0)
        self.assertIsNone(error)
        self.assertEqual(data, BLOB)
        self.assertLess(elapsed, 10, "a stalled range must fail within the read timeout, not minutes")
        self.assertEqual(server.resolved, 2, "the retry must use a freshly signed URL")
        first = server.requests[0]
        retry = [r for r in server.requests if r[0].endswith("sig=2")]
        self.assertEqual(len(retry), 1)
        self.assertGreater(retry[0][1], first[1], "the retry must resume from the byte reached")
        self.assertEqual(retry[0][2], first[2])

    def test_reset_and_throttle_halve_connections(self) -> None:
        calls = {"n": 0}
        sizes: list[int] = []
        real_pool = module.concurrent.futures.ThreadPoolExecutor

        def recording_pool(workers):
            sizes.append(workers)
            return real_pool(workers)

        module.concurrent.futures.ThreadPoolExecutor = recording_pool
        self.addCleanup(setattr, module.concurrent.futures, "ThreadPoolExecutor", real_pool)

        def behave(index, lo):
            calls["n"] += 1
            if index == 0:
                return "reset"
            if index == 1:
                return "429"
            return "ok"

        server, data, _, error = self.run_download(behave, connections=8)
        self.assertIsNone(error)
        self.assertEqual(data, BLOB)
        self.assertEqual(sizes[0], 8)
        self.assertEqual(sizes[1], 2, "two failed ranges retried on half of eight workers, capped by the ranges")
        self.assertTrue(module.is_throttle(ConnectionResetError()))
        self.assertTrue(module.is_throttle(socket.timeout()))
        self.assertFalse(module.is_throttle(OSError("range 0-1: HTTP 200, expected 206")))

    def test_round_without_progress_gives_up_quickly(self) -> None:
        server, _, elapsed, error = self.run_download(lambda index, lo: "429", read_timeout=1.0)
        self.assertIsNotNone(error)
        self.assertIn("unfinished after 1 round", str(error))
        self.assertLess(elapsed, 5)

    def test_deadline_ends_a_slow_download(self) -> None:
        server, _, elapsed, error = self.run_download(
            lambda index, lo: "stall", read_timeout=30.0, deadline=2.0)
        self.assertIsNotNone(error)
        self.assertLess(elapsed, 8, "no read may outlive the deadline")


if __name__ == "__main__":
    unittest.main()
