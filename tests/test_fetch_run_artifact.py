#!/usr/bin/env python3
"""scripts/ci/fetch_run_artifact.py against a local fake GitHub API and blob host.

Run 41478567483: signer-dmg-image's two 5-minute download-artifact attempts both ran out on a
nightly Mac and that tip never published. The ranged fetch drops a range that stalls and asks
for the rest again, checks the zip digest, keeps the token off the blob host, and leaves the
destination empty on failure so download-artifact takes over.
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fetch_run_artifact", ROOT / "scripts/ci/fetch_run_artifact.py")
fra = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fra)

TOKEN = "test-token"


def make_zip(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_STORED) as zf:
        for name, data in files.items():
            zf.writestr(name, data)
    return buffer.getvalue()


class Fake:
    def __init__(self, blob: bytes, digest: str | None = None):
        self.blob = blob
        self.digest = digest if digest is not None else "sha256:" + hashlib.sha256(blob).hexdigest()
        self.stall_once: set[int] = set()  # range starts whose first request hangs mid-body
        self.blob_auth: list[str] = []
        self.blob_requests: list[str] = []
        self.url_mints = 0
        self.lock = threading.Lock()
        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):  # noqa: N802
                base = f"http://127.0.0.1:{self.server.server_address[1]}"
                if self.path.startswith("/repos/o/r/actions/runs/7/artifacts"):
                    assert self.headers.get("Authorization") == f"Bearer {TOKEN}"
                    body = json.dumps({"artifacts": [
                        {"id": 1, "name": "art", "expired": True, "archive_download_url": f"{base}/old"},
                        {"id": 5, "name": "art", "expired": False, "digest": fake.digest,
                         "archive_download_url": f"{base}/repos/o/r/actions/artifacts/5/zip"},
                    ]}).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if self.path == "/repos/o/r/actions/artifacts/5/zip":
                    with fake.lock:
                        fake.url_mints += 1
                        mint = fake.url_mints
                    self.send_response(302)
                    self.send_header("Location", f"{base}/blob?sig={mint}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path.startswith("/blob"):
                    with fake.lock:
                        fake.blob_auth.append(self.headers.get("Authorization") or "")
                        fake.blob_requests.append(self.headers.get("Range") or "")
                    spec = (self.headers.get("Range") or "").removeprefix("bytes=")
                    start, end = (int(x) for x in spec.split("-"))
                    end = min(end, len(fake.blob) - 1)
                    data = fake.blob[start:end + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(fake.blob)}")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    with fake.lock:
                        hang = start in fake.stall_once
                        fake.stall_once.discard(start)
                    if hang:
                        self.wfile.write(data[: len(data) // 2])
                        self.wfile.flush()
                        time.sleep(3)
                        self.close_connection = True
                        return
                    self.wfile.write(data)
                    return
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FetchRunArtifact(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.payload = os.urandom(3 * fra.MIN_PART + 12345)
        self.blob = make_zip({"signed-app.tar": self.payload, "appcast-arm64.xml": b"<rss/>"})

    def fake(self, **kwargs) -> Fake:
        fake = Fake(self.blob, **kwargs)
        self.addCleanup(fake.close)
        return fake

    def run_fetch(self, fake: Fake, **kwargs) -> Path:
        dest = self.tmp / "signer-app"
        options = dict(parts=8, stall=1.0, attempts=3, budget=30.0) | kwargs
        fra.fetch(fra.Api(fake.base, TOKEN, "o/r"), "7", "art", dest, **options)
        return dest

    def test_reads_the_artifact_in_ranges_and_unpacks_it(self):
        fake = self.fake()
        dest = self.run_fetch(fake)
        self.assertEqual((dest / "signed-app.tar").read_bytes(), self.payload)
        self.assertEqual((dest / "appcast-arm64.xml").read_bytes(), b"<rss/>")
        self.assertEqual(sorted(p.name for p in dest.parent.iterdir()), ["signer-app"])  # the zip is gone
        # One probe for the size, then one request per range: 4 ranges of at least 16 MiB.
        self.assertEqual(len(fake.blob_requests), 1 + 4)
        self.assertEqual(fake.blob_auth, [""] * len(fake.blob_auth), "the token never goes to the blob host")

    def test_a_stalled_range_resumes_where_it_stopped_with_a_fresh_url(self):
        fake = self.fake()
        size = -(-len(self.blob) // 4)
        fake.stall_once.add(size)
        dest = self.run_fetch(fake)
        self.assertEqual((dest / "signed-app.tar").read_bytes(), self.payload)
        resumed = [r for r in fake.blob_requests if r.startswith("bytes=") and size < int(r[6:].split("-")[0]) < 2 * size]
        self.assertEqual(len(resumed), 1, fake.blob_requests)
        self.assertGreaterEqual(fake.url_mints, 2)

    def test_a_digest_mismatch_fails_and_leaves_nothing_for_download_artifact_to_trip_on(self):
        fake = self.fake(digest="sha256:" + "0" * 64)
        with self.assertRaises(fra.Failed):
            self.run_fetch(fake)
        os.environ["GH_TOKEN"] = TOKEN
        os.environ["GITHUB_API_URL"] = fake.base
        self.addCleanup(os.environ.pop, "GH_TOKEN", None)
        self.addCleanup(os.environ.pop, "GITHUB_API_URL", None)
        dest = self.tmp / "out"
        rc = fra.main(["--name", "art", "--dest", str(dest), "--run-id", "7", "--repo", "o/r", "--stall", "1"])
        self.assertEqual(rc, 1)
        self.assertFalse(dest.exists())

    def test_a_range_that_never_finishes_fails_within_the_budget(self):
        fake = self.fake()
        size = -(-len(self.blob) // 4)
        fake.stall_once.update({size, 2 * size, 3 * size})
        started = time.monotonic()
        with self.assertRaises(fra.Failed):
            self.run_fetch(fake, attempts=1, budget=10.0)
        self.assertLess(time.monotonic() - started, 15)

    def test_refuses_members_that_leave_the_destination(self):
        archive = self.tmp / "evil.zip"
        archive.write_bytes(make_zip({"../escape": b"x"}))
        with self.assertRaises(fra.Failed):
            fra.extract(archive, self.tmp / "dest")
        self.assertFalse((self.tmp / "escape").exists())


if __name__ == "__main__":
    unittest.main()
