#!/usr/bin/env python3
"""Exercise the uploader CLI and headers received after urllib processing."""

import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
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
    @classmethod
    def setUpClass(cls):
        tls = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tls.cleanup)
        root = Path(tls.name)
        cls.cert = root / "localhost.pem"
        key = root / "localhost.key"
        config = root / "openssl.cnf"
        config.write_text(
            "[req]\nprompt = no\ndistinguished_name = dn\nx509_extensions = ext\n"
            "[dn]\nCN = 127.0.0.1\n[ext]\nsubjectAltName = IP:127.0.0.1\n"
            "basicConstraints = critical,CA:TRUE\n"
            "keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign\n"
            "extendedKeyUsage = serverAuth\nsubjectKeyIdentifier = hash\n"
            "authorityKeyIdentifier = keyid:always\n"
        )
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
             "-days", "1", "-keyout", str(key), "-out", str(cls.cert), "-config", str(config)],
            check=True, capture_output=True, timeout=30,
        )
        cls.tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.tls_context.load_cert_chain(cls.cert, key)

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
            SSL_CERT_FILE=str(self.cert),
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

    def start_endpoint(self, existing=False, *, tls=True, redirects=None):
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def record(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                requests.append((self.command, self.path, dict(self.headers.items()), body))
                if redirects and self.command in redirects and self.path != "/redirect-target":
                    code, target = redirects[self.command]
                    self.send_response(code)
                    self.send_header("Location", target)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
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
        if tls:
            server.socket = self.tls_context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            thread.join()
            server.server_close()

        self.addCleanup(stop)
        scheme = "https" if tls else "http"
        return f"{scheme}://127.0.0.1:{server.server_port}", requests

    def test_plaintext_endpoints_are_rejected_before_sending_credentials(self):
        endpoint, requests = self.start_endpoint(tls=False)
        self.env["AWS_SESSION_TOKEN"] = "example-session-token"
        for flags in ((), ("--write-once",), ("--dry-run-json",)):
            with self.subTest(flags=flags):
                result = self.upload("appcast.xml", *flags, endpoint=endpoint)
                self.assertEqual(requests, [], "No signed request may reach a plaintext endpoint")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("HTTPS", result.stderr)

    def test_signed_requests_never_follow_redirects(self):
        self.env["AWS_SESSION_TOKEN"] = "example-session-token"
        for target_kind in ("https", "http", "same-origin"):
            collector, collected = self.start_endpoint(existing=True, tls=target_kind != "http")
            target = "/redirect-target" if target_kind == "same-origin" else collector + "/redirect-target"
            for method in ("HEAD", "GET", "PUT"):
                for code in (301, 302, 303, 307, 308):
                    with self.subTest(target=target_kind, method=method, code=code):
                        collected.clear()
                        endpoint, requests = self.start_endpoint(existing=True, redirects={method: (code, target)})
                        flags = () if method == "PUT" else ("--write-once",)
                        result = self.upload("appcast.xml", *flags, endpoint=endpoint)
                        expected = ["HEAD", "GET"] if method == "GET" else [method]
                        self.assertEqual(collected, [], "Redirect must not forward signed headers to another origin")
                        self.assertEqual([r[0] for r in requests], expected)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(f"HTTP {code}", result.stderr)
                        headers = {k.lower(): v for k, v in requests[-1][2].items()}
                        self.assertIn("authorization", headers)
                        self.assertEqual(headers["x-amz-security-token"], self.env["AWS_SESSION_TOKEN"])

    def test_repair_reader_rejects_plaintext_and_redirects(self):
        self.env["AWS_SESSION_TOKEN"] = "example-session-token"
        collector, collected = self.start_endpoint(tls=False)
        endpoint, requests = self.start_endpoint(redirects={"GET": (302, collector)})
        for url, expected in ((collector, []), (endpoint, ["GET"])):
            with self.subTest(endpoint=url):
                result = subprocess.run(
                    [sys.executable, str(UPLOADER.with_name("repair-nightly-appcast-content-types.py")),
                     "--endpoint-url", url],
                    env=self.env, capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(collected, [])
                self.assertEqual([r[0] for r in requests], expected)
                self.assertIn("HTTPS" if url == collector else "HTTP Error 302", result.stderr)

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
