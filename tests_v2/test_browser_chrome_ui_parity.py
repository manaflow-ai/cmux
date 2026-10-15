#!/usr/bin/env python3
"""Browser chrome parity: what the panel chrome shows is the same on both engines.

Runs against a running tagged DEBUG build (its debug socket). Set
CMUX_BROWSER_TEST_ENGINE=webkit|chromium to pin the engine (tests_v2/cmux.py asks
browser-creating calls for it and fails a result on another engine); unset, the
build's default engine runs. Chromium-only expectations are skipped on WebKit.

Legs:
  title-favicon  The pane tab gets the page title and the site's favicon (Chromium
                 fetches it through the page's own request context).
  navigation     Back and Forward move through the page's history and the chrome's
                 URL follows.
  address-bar    Cmd-L moves the keyboard to the panel's address bar, also while a
                 Chromium page window had the keyboard.

Usage: CMUX_SOCKET_PATH=<tagged socket> [CMUX_BROWSER_TEST_ENGINE=chromium] \\
       python3 tests_v2/test_browser_chrome_ui_parity.py
"""

from __future__ import annotations

import struct
import functools
import http.server
import os
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
ENGINE = os.environ.get("CMUX_BROWSER_TEST_ENGINE", "").strip().lower()

def _png(size: int = 16) -> bytes:
    """An opaque red square PNG, built here so the fixture needs no binary file."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + b"\xe4\x44\x44" * size for _ in range(size))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


FAVICON_PNG = _png()
HOME = """<!doctype html><html><head><title>Chrome UI Home</title><link rel="icon" href="fav.png"></head>
<body><h1>Chrome UI Home</h1><p><a id="next" href="page2.html">Next page</a></p></body></html>"""
PAGE2 = """<!doctype html><html><head><title>Chrome UI Page 2</title></head><body><h1>Page 2</h1></body></html>"""


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred, timeout_s: float, label: str):
    """Polls the live app under test (test harness only) until `pred` returns a truthy value."""
    deadline = time.time() + timeout_s
    last_exc = None
    while time.time() < deadline:
        try:
            value = pred()
            if value:
                return value
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {label}" + (f": {last_exc}" if last_exc else ""))


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:  # noqa: D401
        pass


def _serve(directory: str) -> tuple[http.server.ThreadingHTTPServer, str]:
    handler = functools.partial(_QuietHandler, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def _title(client: cmux, sid: str) -> str:
    res = client._call("browser.get.title", {"surface_id": sid}) or {}
    return str(res.get("title") or res.get("value") or "")


def leg_title_favicon(client: cmux, base: str) -> str:
    sid = client.open_browser(f"{base}/index.html")
    _wait_for(lambda: _title(client, sid) == "Chrome UI Home", 20, "page title")
    favicon = _wait_for(
        lambda: (client._call("debug.browser.favicon", {"surface_id": sid}) or {}).get("has_favicon"),
        20,
        "favicon in the pane tab",
    )
    _must(bool(favicon), "pane tab has no favicon")
    return sid


def leg_navigation(client: cmux, sid: str, base: str) -> None:
    client.navigate(sid, f"{base}/page2.html")
    _wait_for(lambda: client.get_url(sid).endswith("/page2.html"), 20, "page2 URL in the chrome")
    _wait_for(lambda: _title(client, sid) == "Chrome UI Page 2", 20, "page2 title")
    client.browser_back(sid)
    _wait_for(lambda: client.get_url(sid).endswith("/index.html"), 20, "Back to index")
    # The chrome's Forward is enabled once the back navigation commits; until
    # then Forward is a no-op on either engine, so ask again until it moves.
    # page2 is the last entry, so a repeated Forward cannot overshoot.
    def forwarded() -> bool:
        if client.get_url(sid).endswith("/page2.html"):
            return True
        client.browser_forward(sid)
        return False

    _wait_for(forwarded, 20, "Forward to page2")


def leg_address_bar(client: cmux, sid: str) -> None:
    client.focus_surface(sid)
    client._call("debug.shortcut.simulate", {"combo": "cmd+l"})
    focused = _wait_for(
        lambda: (client._call("debug.browser.address_bar_focused", {}) or {}).get("focused_surface_id"),
        10,
        "address bar focus after Cmd-L",
    )
    _must(str(focused).lower() == sid.lower(), f"Cmd-L focused {focused}, expected {sid}")
    client._call("debug.shortcut.simulate", {"combo": "escape"})


def main() -> int:
    with tempfile.TemporaryDirectory() as root:
        Path(root, "index.html").write_text(HOME)
        Path(root, "page2.html").write_text(PAGE2)
        Path(root, "fav.png").write_bytes(FAVICON_PNG)
        server, base = _serve(root)
        try:
            with cmux(SOCKET_PATH) as client:
                sid = leg_title_favicon(client, base)
                try:
                    print(f"PASS title-favicon engine={ENGINE or 'default'}")
                    leg_navigation(client, sid, base)
                    print(f"PASS navigation engine={ENGINE or 'default'}")
                    leg_address_bar(client, sid)
                    print(f"PASS address-bar engine={ENGINE or 'default'}")
                finally:
                    client.close_surface(sid)
        finally:
            server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
