#!/usr/bin/env python3
"""Tests of scripts/cmux-next/browser-auth-flows-fixture/provider.py, the pages the live login-flow
checks (browser-auth-flows-live.py) click through: every inline handler must reach the browser whole.

A json.dumps'd string inside a double-quoted onclick ended the attribute early, so the COOP and
custom-scheme buttons ran a syntax error and opened nothing; the live run read that as an engine
failing COOP ({} from the popup that never opened). This parses each page as the browser does and
checks every event handler is one balanced script, with no stray attributes left behind it."""

from __future__ import annotations

import html.parser
import importlib.util
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/browser-auth-flows-fixture/provider.py"
spec = importlib.util.spec_from_file_location("auth_fixture_provider", SCRIPT)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)

KNOWN_ATTRS = {"id", "onclick", "target", "rel", "href", "src", "type"}
PAGES = ["/rp", "/auto", "/links", "/iframeopen", "/iframeopen_inner", "/openerrp", "/dlflow", "/embed", "/iframe",
         "/coopopener?k=coopA&coop=same-origin", "/coopopener?k=coopC&popupcoop=same-origin", "/coopopener?k=coopD",
         "/schemeopen?via=js", "/schemeopen?via=302&to=vscode%3A%2F%2Fauth%3Fcode%3D1"]


class Tags(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.attrs: list[tuple[str, str, str | None]] = []

    def handle_starttag(self, tag, attrs):
        self.attrs += [(tag, name, value) for name, value in attrs]


def balanced(js: str) -> bool:
    """Brackets balance and every string literal closes (enough to catch a cut-off handler)."""
    stack, quote, i = [], None, 0
    pairs = {")": "(", "]": "[", "}": "{"}
    while i < len(js):
        c = js[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c in "([{":
            stack.append(c)
        elif c in pairs:
            if not stack or stack.pop() != pairs[c]:
                return False
        i += 1
    return not stack and quote is None


class FixturePages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), provider.H)
        provider.PORT = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def page(self, path: str) -> list[tuple[str, str, str | None]]:
        with urllib.request.urlopen(f"http://127.0.0.1:{provider.PORT}{path}", timeout=5) as reply:
            parser = Tags()
            parser.feed(reply.read().decode())
            return parser.attrs

    def test_every_handler_is_whole(self):
        for path in PAGES:
            for tag, name, value in self.page(path):
                with self.subTest(path=path, tag=tag, attr=name):
                    self.assertIn(name, KNOWN_ATTRS, f"stray attribute: a handler on {path} ended early")
                    if name.startswith("on"):
                        self.assertTrue(value and balanced(value), f"cut-off handler on {path}: {value!r}")

    def test_coop_button_opens_the_probe_with_its_key_and_policy(self):
        handler = [v for _, n, v in self.page("/coopopener?k=coopC&popupcoop=same-origin") if n == "onclick"][0]
        self.assertIn(f'window.open("http://127.0.0.1:{provider.PORT}/probe?k=coopC&coop=same-origin",', handler)

    def test_coop_header_is_sent_on_the_opener(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{provider.PORT}/coopopener?k=x&coop=same-origin", timeout=5) as reply:
            self.assertEqual(reply.headers.get("Cross-Origin-Opener-Policy"), "same-origin")

    def test_scheme_button_keeps_the_target_url(self):
        handler = [v for _, n, v in self.page("/schemeopen?via=302&to=myapp%3A%2F%2Fcb") if n == "onclick"][0]
        self.assertIn('encodeURIComponent("myapp://cb")', handler)
        self.assertTrue(balanced(handler))


if __name__ == "__main__":
    unittest.main()
