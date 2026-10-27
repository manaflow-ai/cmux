#!/usr/bin/env python3
"""Tests of webfixture.py (p15-oracle-222). Stdlib unittest, run as a script, not in CI.

    python3 -I scripts/cmux-next/oracle/webfixture_test.py
"""

from __future__ import annotations

import json
import re
import shutil
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import normalize  # noqa: E402
import webfixture  # noqa: E402

CORPUS = webfixture.REPO / "tests" / "oracle" / "corpus"
WEB_URL = re.compile(re.escape(webfixture.TOKEN) + r"(/[^\s\"']*)")


def head_and_body(raw: bytes):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    status = int(lines[0].split()[1])
    headers = dict(line.split(": ", 1) for line in lines[1:])
    return status, headers, body


class ServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.web = webfixture.WebFixture()
        self.web.start()
        self.addCleanup(self.web.stop)

    def get(self, target: str, method: str = "GET"):
        return head_and_body(webfixture.fetch_raw(self.web.origin, method, target))

    def test_listens_on_loopback_only_with_an_os_port(self) -> None:
        host, port = self.web._running().server_address[:2]
        self.assertEqual(host, "127.0.0.1")
        self.assertNotEqual(port, 0)
        self.assertEqual(self.web.origin, f"http://127.0.0.1:{port}")

    def test_routes(self) -> None:
        expected = {
            "/": (200, "text/html; charset=utf-8"),
            "/load.html": (200, "text/html; charset=utf-8"),
            "/popup.html?auto": (200, "text/html; charset=utf-8"),
            "/status/404": (404, "text/html; charset=utf-8"),
            "/status/500": (500, "text/html; charset=utf-8"),
            "/status/418": (404, "text/html; charset=utf-8"),
            "/missing.html": (404, "text/html; charset=utf-8"),
            "/slow.html?ms=nope": (400, "text/html; charset=utf-8"),
            "/slow.html?ms=30001": (400, "text/html; charset=utf-8"),
            "/long-dom.html?n=-1": (400, "text/html; charset=utf-8"),
            "/download/fixture.bin": (200, "application/octet-stream"),
            "/favicon.ico": (204, None),
        }
        for target, (status, content_type) in expected.items():
            with self.subTest(target):
                got_status, headers, _ = self.get(target)
                self.assertEqual(got_status, status)
                self.assertEqual(headers.get("Content-Type"), content_type)
                self.assertNotIn("Date", headers)
                self.assertNotIn("Server", headers)

    def test_index_is_the_root(self) -> None:
        self.assertEqual(self.get("/"), self.get("/index.html"))

    def test_head_has_no_body(self) -> None:
        status, headers, body = self.get("/load.html", "HEAD")
        self.assertEqual((status, body), (200, b""))
        self.assertEqual(headers["Content-Length"], str(len(self.get("/load.html")[2])))

    def test_no_file_outside_the_fixture_directory(self) -> None:
        for target in ("/../oracle.py", "/%2e%2e/oracle.py", "/..%2fREADME.md", "/.hidden.html",
                       "/sub%2fload.html", "/responses.json", "/index.html/"):
            with self.subTest(target):
                self.assertEqual(self.get(target)[0], 404)

    def test_download_is_an_attachment_of_fixed_bytes(self) -> None:
        _, headers, body = self.get("/download/fixture.bin")
        self.assertEqual(headers["Content-Disposition"], 'attachment; filename="fixture.bin"')
        self.assertEqual(body, webfixture.DOWNLOAD_BYTES)
        self.assertEqual(len(body), 65536)

    def test_long_dom_has_the_asked_item_count(self) -> None:
        body = self.get("/long-dom.html?n=3")[2].decode()
        self.assertEqual(body.count("<li "), 3)
        self.assertIn('id="item-2"', body)
        self.assertEqual(self.get("/long-dom.html")[2].decode().count("<li "), webfixture.DEFAULT_LONG_DOM_ITEMS)

    def test_slow_waits_before_the_headers(self) -> None:
        start = time.monotonic()
        status, _, body = self.get("/slow.html?ms=300")
        self.assertGreaterEqual(time.monotonic() - start, 0.3)
        self.assertEqual(status, 200)
        self.assertIn(b"loaded after 300 ms", body)

    def test_stop_ends_a_slow_request_at_once(self) -> None:
        web = webfixture.WebFixture()
        web.start()
        thread = threading.Thread(target=lambda: webfixture.fetch_raw(web.origin, "GET", "/slow.html?ms=30000"))
        thread.start()
        deadline = time.monotonic() + 5
        while not web.requests and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(web.requests, ("GET /slow.html?ms=30000",))
        start = time.monotonic()
        web.stop()
        thread.join(5)
        self.assertLess(time.monotonic() - start, 5)
        self.assertFalse(thread.is_alive())

    def test_requests_are_logged_in_order(self) -> None:
        self.get("/load.html")
        self.get("/other.html", "HEAD")
        self.assertEqual(self.web.requests, ("GET /load.html", "HEAD /other.html"))


class StabilityTest(unittest.TestCase):
    def test_two_servers_on_two_ports_give_the_checked_in_bytes(self) -> None:
        with webfixture.WebFixture() as first, webfixture.WebFixture() as second:
            self.assertNotEqual(first.port, second.port)
            one, two = webfixture.digests(first), webfixture.digests(second)
        self.assertEqual(one, two)
        checked_in = json.loads(webfixture.DIGESTS_FILE.read_text(encoding="utf-8"))
        self.assertEqual(one, checked_in, "run `webfixture.py digests --write` after a reviewed page change")

    def test_respond_is_pure(self) -> None:
        for _, target in webfixture.ROUTES:
            with self.subTest(target):
                self.assertEqual(webfixture.respond(target), webfixture.respond(target))


class LoopbackTest(unittest.TestCase):
    def test_pages_name_no_remote_url(self) -> None:
        self.assertEqual(webfixture.check(), [])

    def test_check_refuses_a_remote_url_in_a_page(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="o-web-"))
        self.addCleanup(shutil.rmtree, root, True)
        (root / "bad.html").write_text('<a href="https://example.com/x">x</a>\n<img src="//cdn.example">\n',
                                       encoding="utf-8")
        findings = webfixture.check(root)
        self.assertEqual(len(findings), 2, findings)

    def test_remote_url_rule(self) -> None:
        for text in ("https://example.com", "http:example.com", "ws://10.0.0.1:80/", "file://host/x"):
            with self.subTest(text):
                self.assertTrue(webfixture.remote_urls(text))
        for text in ("http://127.0.0.1:4321/load.html", "http://localhost/", "chrome://crash", "file:///tmp/x",
                     "$WEB/load.html", "load.html"):
            with self.subTest(text):
                self.assertEqual(webfixture.remote_urls(text), [])


class TokenTest(unittest.TestCase):
    def test_expand_at_any_depth_and_only_the_token(self) -> None:
        origin = "http://127.0.0.1:4321"
        case = {"steps": [{"args": {"params": {"url": "$WEB/load.html"}}}, "$WEB", "$WEBSITE", 3, None]}
        self.assertEqual(webfixture.expand(case, origin),
                         {"steps": [{"args": {"params": {"url": f"{origin}/load.html"}}}, origin, "$WEBSITE", 3,
                                    None]})

    def test_normalize_rewrites_the_origin_back(self) -> None:
        with webfixture.WebFixture() as web:
            args = web.normalize_args()
            url = web.expand("$WEB/popup.html?auto")
        self.assertEqual(args[0], "--web")
        rewriter = normalize._Rewriter(normalize.Context(web=(args[1],)))
        self.assertEqual(rewriter.apply("url", url)[0], "$WEB/popup.html?auto")

    def test_known_marks_only_the_unknown_path_fallback(self) -> None:
        # A journey may open an error route on purpose; only a path the fixture does not serve is a corpus mistake.
        for target, status in (("/status/404", 404), ("/status/500", 500), ("/favicon.ico", 204), ("/load.html", 200),
                               ("/slow.html?ms=0", 200), ("/long-dom.html?n=3", 200), ("/download/fixture.bin", 200)):
            with self.subTest(target):
                response = webfixture.respond(target)
                self.assertEqual(response.status, status)
                self.assertTrue(response.known)
        for target in ("/no-such.html", "/status/418", "/nested/load.html", "/.hidden.html"):
            with self.subTest(target):
                response = webfixture.respond(target)
                self.assertEqual(response.status, 404)
                self.assertFalse(response.known)

    def test_every_corpus_url_is_served(self) -> None:
        targets = set()
        for path in sorted(CORPUS.rglob("*.json")):
            targets.update(WEB_URL.findall(path.read_text(encoding="utf-8")))
        self.assertIn("/load.html", targets, "the tabs-and-browser journey opens $WEB/load.html")
        for target in sorted(targets):
            with self.subTest(target):
                self.assertTrue(webfixture.respond(target).known, f"$WEB{target} is not a route of webfixture.py")


if __name__ == "__main__":
    unittest.main()
