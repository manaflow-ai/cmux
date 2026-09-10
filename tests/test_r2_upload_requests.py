#!/usr/bin/env python3
"""Exercise the uploader CLI and headers received after urllib processing."""

import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


UPLOADER = Path(__file__).resolve().parents[1] / "scripts/ci/upload-r2-object.py"
APPCASTS = ("appcast-arm64.xml", "appcast-x86_64.xml", "appcast-universal.xml", "appcast.xml")
BODY = b'<?xml version="1.0"?><rss><channel><title>Nightly</title></channel></rss>\n'
CACHE_CONTROL = "no-cache, no-store, must-revalidate"


class R2UploadRequestsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
        self.env.update(
            AWS_ACCESS_KEY_ID="AKIDEXAMPLE",
            AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            AWS_DEFAULT_REGION="auto",
            CMUX_R2_UPLOAD_AMZ_DATE="20260102T030405Z",
            NO_PROXY="127.0.0.1",
            no_proxy="127.0.0.1",
        )

    def upload(self, name="appcast.xml", *flags, endpoint="https://example.invalid", body=BODY):
        path = self.root / name
        path.write_bytes(body)
        return subprocess.run(
            [sys.executable, str(UPLOADER), "--file", str(path),
             "--endpoint-url", endpoint, "--bucket", "cmux-binaries",
             "--key", f"nightly/{name}", "--cache-control", CACHE_CONTROL, *flags],
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def dry_run(self, name, *flags):
        result = self.upload(name, "--dry-run-json", *flags)
        self.assertEqual(result.returncode, 0, result.stderr)
        request = json.loads(result.stdout)
        return request, {k.lower(): v for k, v in request["headers"].items()}

    def assert_upload_headers(self, headers, content_type):
        self.assertEqual(headers.get("content-type"), content_type)
        self.assertEqual(headers["cache-control"], CACHE_CONTROL)
        signed = headers["authorization"].split("SignedHeaders=", 1)[1].split(",", 1)[0].split(";")
        self.assertIn("content-type", signed)
        self.assertEqual(signed, sorted(signed))

    def start_endpoint(self, existing=False):
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def record(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                requests.append((self.command, self.path, dict(self.headers.items()), body))
                status = 404 if self.command == "HEAD" and not existing else 200
                response = BODY if self.command == "GET" else b""
                self.send_response(status)
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            do_PUT = do_GET = do_HEAD = record

            def log_message(self, *_args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            thread.join()
            server.server_close()

        self.addCleanup(stop)
        return f"http://127.0.0.1:{server.server_port}", requests

    def test_all_nightly_appcasts_explicit_xml_dry_run(self):
        for name in APPCASTS:
            with self.subTest(name=name):
                request, headers = self.dry_run(name, "--content-type", "application/xml")
                self.assert_upload_headers(headers, "application/xml")
                self.assertEqual(request["url"], f"https://example.invalid/cmux-binaries/nightly/{name}")
                self.assertEqual(request["body_sha256"], hashlib.sha256(BODY).hexdigest())
                self.assertEqual(headers["x-amz-content-sha256"], request["body_sha256"])

    def test_inferred_xml_is_sent_and_signed_on_the_wire(self):
        endpoint, requests = self.start_endpoint()
        result = self.upload(endpoint=endpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 1)
        method, path, headers, body = requests[0]
        self.assertEqual((method, path, body), ("PUT", "/cmux-binaries/nightly/appcast.xml", BODY))
        headers = {k.lower(): v for k, v in headers.items()}
        self.assertIn(headers.get("content-type"), {"application/xml", "text/xml"})
        self.assert_upload_headers(headers, headers["content-type"])

    def test_explicit_type_overrides_extension_on_the_wire(self):
        endpoint, requests = self.start_endpoint()
        result = self.upload("appcast.xml", "--content-type", "application/rss+xml; charset=utf-8", endpoint=endpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 1)
        headers = {k.lower(): v for k, v in requests[0][2].items()}
        self.assert_upload_headers(headers, "application/rss+xml; charset=utf-8")

    def test_non_xml_defaults(self):
        for name, expected in (("manifest.json", "application/json"),
                               ("cmux-tui-darwin-arm64", "application/octet-stream"),
                               ("appcast.xml.gz", "application/octet-stream")):
            with self.subTest(name=name):
                _, headers = self.dry_run(name)
                self.assert_upload_headers(headers, expected)

    def test_explicit_non_xml_type_and_signature(self):
        _, binary = self.dry_run("artifact", "--content-type", "application/octet-stream")
        _, archive = self.dry_run("artifact", "--content-type", "application/gzip")
        self.assert_upload_headers(binary, "application/octet-stream")
        self.assert_upload_headers(archive, "application/gzip")
        self.assertNotEqual(binary["authorization"], archive["authorization"])

    def test_write_once_put_keeps_condition_and_content_type_signed(self):
        endpoint, requests = self.start_endpoint()
        result = self.upload("manifest.json", "--write-once", endpoint=endpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r[0] for r in requests], ["HEAD", "PUT"])
        headers = {k.lower(): v for k, v in requests[1][2].items()}
        self.assert_upload_headers(headers, "application/json")
        self.assertEqual(headers["if-none-match"], "*")
        self.assertIn(";if-none-match;", headers["authorization"])

    def test_write_once_existing_object_still_uses_bodyless_reads(self):
        endpoint, requests = self.start_endpoint(existing=True)
        result = self.upload("manifest.json", "--write-once", endpoint=endpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r[0] for r in requests], ["HEAD", "GET"])
        for _, _, headers, body in requests:
            headers = {k.lower(): v for k, v in headers.items()}
            self.assertEqual(body, b"")
            self.assertNotIn("content-type", headers)
            self.assertNotIn("content-type", headers["authorization"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
