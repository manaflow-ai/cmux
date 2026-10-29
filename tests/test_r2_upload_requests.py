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
import time
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

    def start_endpoint(self, existing=False, *, tls=True, redirects=None, put_status=200):
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
                if self.command == "PUT":
                    status = put_status
                response = BODY if self.command == "GET" else b""
                self.send_response(status)
                self.send_header("ETag", '"etag-1"')
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

    def start_flaky_endpoint(self, failures):
        """A bucket whose first PUTs fail: "503", "drop" (the connection closes
        with no answer, as a stalled write that timed out), or "lost" (the
        object is stored, then the connection closes before the answer)."""
        requests, stored, pending = [], {}, list(failures)

        class Handler(http.server.BaseHTTPRequestHandler):
            def record(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                requests.append((self.command, self.path))
                if self.command == "PUT" and pending:
                    failure = pending.pop(0)
                    if failure == "lost":
                        stored[self.path] = body
                    if failure == "other":
                        # Another publisher's bytes land, and this PUT's answer is lost.
                        stored[self.path] = b"other publisher\n"
                    if failure in ("drop", "lost", "other"):
                        self.close_connection = True
                        self.connection.close()
                        return
                    status, response = int(failure), b""
                elif self.command == "PUT":
                    if self.headers.get("If-None-Match") == "*" and self.path in stored:
                        status, response = 412, b""
                    else:
                        stored[self.path] = body
                        status, response = 200, b""
                elif self.path in stored:
                    status, response = 200, stored[self.path] if self.command == "GET" else b""
                else:
                    status, response = 404, b""
                self.send_response(status)
                self.send_header("ETag", '"etag-1"')
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            do_PUT = do_GET = do_HEAD = record

            def log_message(self, *_args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        server.socket = self.tls_context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            thread.join()
            server.server_close()

        self.addCleanup(stop)
        return f"https://127.0.0.1:{server.server_port}", requests, stored

    def test_transient_failures_are_retried(self):
        # Run 40629788539: one PUT's "write operation timed out" failed the
        # whole cmux-tui tree publication.
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        for failures in (["503"], ["drop"], ["drop", "503", "429"]):
            for flags in ((), ("--write-once",)):
                with self.subTest(failures=failures, flags=flags):
                    endpoint, requests, stored = self.start_flaky_endpoint(failures)
                    result = self.upload("appcast.xml", *flags, endpoint=endpoint)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Uploaded", result.stdout)
                    self.assertEqual(stored, {"/cmux-binaries/nightly/appcast.xml": BODY})
                    self.assertEqual([r[0] for r in requests].count("PUT"), len(failures) + 1)
                    self.assertIn(f"attempt 1 of 4 failed", result.stderr)

    def test_a_write_once_put_that_landed_unanswered_reads_as_present(self):
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        endpoint, requests, stored = self.start_flaky_endpoint(["lost"])
        result = self.upload("appcast.xml", "--write-once", endpoint=endpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Already present with matching digest", result.stdout)
        self.assertEqual([r[0] for r in requests], ["HEAD", "PUT", "HEAD", "GET"])

    def test_a_write_once_retry_never_accepts_another_publishers_bytes(self):
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        for flags, code in (((), 1), (("--conflict-exit-code", "75"), 75)):
            with self.subTest(flags=flags):
                endpoint, requests, stored = self.start_flaky_endpoint(["other"])
                result = self.upload("appcast.xml", "--write-once", *flags, endpoint=endpoint)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(stored, {"/cmux-binaries/nightly/appcast.xml": b"other publisher\n"})
                self.assertEqual([r[0] for r in requests].count("PUT"), 1)
                if not flags:
                    self.assertIn("immutable-r2-conflict", result.stdout)

    def test_a_download_that_trickles_is_cut_at_its_deadline(self):
        # Never idle long enough for the socket timeout, never done.
        self.env.update(CMUX_R2_UPLOAD_RETRY_DELAY="0", CMUX_R2_UPLOAD_ATTEMPTS="2",
                        CMUX_R2_DOWNLOAD_ATTEMPT_SECONDS="1")

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", str(1 << 30))
                self.end_headers()
                try:
                    # Under one 64 KiB chunk in all, a byte at a time.
                    for _ in range(100):
                        self.wfile.write(b"x")
                        self.wfile.flush()
                        time.sleep(0.05)
                except OSError:
                    pass

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.socket = self.tls_context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), thread.join(), server.server_close()))
        started = time.monotonic()
        result, target = self.download(f"https://127.0.0.1:{server.server_port}")
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 8)
        self.assertIn("too slow", result.stderr)
        self.assertFalse(target.exists())
        self.assertFalse(target.with_name("downloaded.partial").exists())

    def test_a_download_whose_answer_never_starts_is_cut_at_its_deadline(self):
        # The deadline covers the request too, not only the body.
        self.env.update(CMUX_R2_UPLOAD_RETRY_DELAY="0", CMUX_R2_UPLOAD_ATTEMPTS="2",
                        CMUX_R2_DOWNLOAD_ATTEMPT_SECONDS="1")

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                time.sleep(5)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server.socket = self.tls_context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), thread.join(), server.server_close()))
        started = time.monotonic()
        result, target = self.download(f"https://127.0.0.1:{server.server_port}")
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("too slow", result.stderr)

    def test_the_deadline_is_not_swallowed_by_a_connect_over_several_addresses(self):
        # socket.create_connection tries each resolved address and catches
        # OSError between them: a deadline raised as one would be lost there.
        import importlib.util
        import socket
        import unittest.mock

        spec = importlib.util.spec_from_file_location("upload_r2_object", UPLOADER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertFalse(issubclass(module.DownloadDeadline, OSError))
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 1))] * 2
        tried = []

        def connect(_self, _address):
            tried.append(_address)
            raise module.DownloadDeadline("deadline")

        with unittest.mock.patch("socket.getaddrinfo", return_value=addresses), \
                unittest.mock.patch("socket.socket.connect", connect):
            with self.assertRaises(module.DownloadDeadline):
                socket.create_connection(("r2.invalid", 443), timeout=1)
        self.assertEqual(len(tried), 1, "the deadline stops the connect at the first address")

    def test_a_failed_download_keeps_the_destination(self):
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        endpoint, requests, stored = self.start_flaky_endpoint([])
        target = self.root / "downloaded"
        target.write_bytes(b"earlier\n")
        result, _ = self.download(endpoint, key="nightly/missing.xml")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b"earlier\n")

    def test_retries_are_bounded_and_permanent_errors_are_not_retried(self):
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        endpoint, requests, stored = self.start_flaky_endpoint(["503"] * 6)
        result = self.upload("appcast.xml", endpoint=endpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([r[0] for r in requests].count("PUT"), 4)
        self.assertIn("R2 upload failed: HTTP 503", result.stderr)
        endpoint, requests, stored = self.start_flaky_endpoint(["403"])
        result = self.upload("appcast.xml", endpoint=endpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([r[0] for r in requests].count("PUT"), 1)
        self.assertIn("R2 upload failed: HTTP 403", result.stderr)

    def download(self, endpoint, key="nightly/appcast.xml"):
        target = self.root / "downloaded"
        result = subprocess.run(
            [sys.executable, str(UPLOADER), "--endpoint-url", endpoint, "--bucket", "cmux-binaries",
             "--key", key, "--download-to", str(target)],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        return result, target

    def test_download_reads_the_object_from_r2_whole_or_not_at_all(self):
        # Run 40637082673: files.cmux.com served a kept publication's 31 MB
        # binary at 4-35 KB/s and the publish job failed after 20 minutes.
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        endpoint, requests, stored = self.start_flaky_endpoint([])
        stored["/cmux-binaries/nightly/appcast.xml"] = BODY
        result, target = self.download(endpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), BODY)
        self.assertEqual([r[0] for r in requests], ["GET"])
        result, target = self.download(endpoint, key="nightly/missing.xml")
        self.assertEqual(result.returncode, 22, "a missing object exits like curl --fail")
        self.assertFalse(target.with_name("downloaded.partial").exists())
        self.assertEqual([r[0] for r in requests], ["GET", "GET"], "a 404 is not retried")

    def test_download_retries_a_dropped_read(self):
        self.env["CMUX_R2_UPLOAD_RETRY_DELAY"] = "0"
        drops = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                drops.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", str(len(BODY)))
                self.end_headers()
                # The first answer stops halfway, as a stalled transfer does.
                self.wfile.write(BODY if len(drops) > 1 else BODY[: len(BODY) // 2])
                if len(drops) == 1:
                    self.close_connection = True

            def log_message(self, *_args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        server.socket = self.tls_context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), thread.join(), server.server_close()))
        result, target = self.download(f"https://127.0.0.1:{server.server_port}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), BODY)
        self.assertEqual(len(drops), 2)
        self.assertIn("attempt 1 of 4 failed", result.stderr)

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

    def test_write_once_conflict_is_a_named_hard_failure(self):
        # A different immutable object is never retried: the run's retry
        # workflow reads this annotation title and leaves the run red.
        endpoint, requests = self.start_endpoint(existing=True)
        result = self.upload("manifest.json", "--write-once", endpoint=endpoint, body=BODY + b"changed")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([r[0] for r in requests], ["HEAD", "GET"])
        self.assertIn("::error title=immutable-r2-conflict::", result.stdout)
        self.assertIn("nightly/manifest.json", result.stdout)
        self.assertIn("immutable R2 object already exists with a different SHA-256", result.stderr)

    def test_write_once_conflict_with_a_conflict_exit_code_is_quiet(self):
        # A caller that waits for the other publisher's upload and keeps it
        # (two runs of one commit at once, cx-a1q4d) asks for its own exit
        # code: no annotation, so the run's retry workflow is not told to
        # leave it red, and the existing object is never overwritten.
        endpoint, requests = self.start_endpoint(existing=True)
        result = self.upload("manifest.json", "--write-once", "--conflict-exit-code", "75",
                             endpoint=endpoint, body=BODY + b"changed")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual([r[0] for r in requests], ["HEAD", "GET"])
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertIn("another publisher wrote it first", result.stderr)

    def test_replace_writes_with_if_match_on_the_planned_object(self):
        # nightly-next-rollback.yml: the feed is written only while it still
        # holds the bytes the pull was planned from.
        endpoint, requests = self.start_endpoint(existing=True)
        planned = hashlib.sha256(BODY).hexdigest()
        result = self.upload("appcast-arm64.xml", "--replace-sha256", planned, endpoint=endpoint, body=b"<rss/>")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r[0] for r in requests], ["GET", "PUT"])
        headers = {k.lower(): v for k, v in requests[1][2].items()}
        self.assertEqual(headers["if-match"], '"etag-1"')
        self.assertIn(";if-match;", headers["authorization"])
        self.assertEqual(requests[1][3], b"<rss/>")

    def test_replace_refuses_an_object_that_changed_before_the_read(self):
        endpoint, requests = self.start_endpoint(existing=True)
        result = self.upload("appcast-arm64.xml", "--replace-sha256", "0" * 64, "--conflict-exit-code", "3",
                             endpoint=endpoint, body=b"<rss/>")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual([r[0] for r in requests], ["GET"])
        self.assertIn("changed since it was read", result.stderr)

    def test_replace_refuses_an_object_that_changed_before_the_write(self):
        endpoint, requests = self.start_endpoint(existing=True, put_status=412)
        planned = hashlib.sha256(BODY).hexdigest()
        result = self.upload("appcast-arm64.xml", "--replace-sha256", planned, "--conflict-exit-code", "3",
                             endpoint=endpoint, body=b"<rss/>")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual([r[0] for r in requests], ["GET", "PUT"])
        self.assertIn("changed before the write", result.stderr)

    def test_replace_and_write_once_are_exclusive(self):
        result = self.upload("appcast-arm64.xml", "--replace-sha256", "0" * 64, "--write-once")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
