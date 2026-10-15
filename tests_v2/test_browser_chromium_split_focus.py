#!/usr/bin/env python3
"""Chromium: a split next to a page must not move the page's focus.

EXPECTED FAIL until the CEF fork is patched (fork-patch proposal F1 in the
cef-embed status notes: show the page widget inactive when its parent view is
re-added, or skip SetInitialFocus for cmux windows). Today, splitting a pane
next to a Chromium page re-shows the page widget, Chromium restores focus on
activation, finds no stored focus and advances into the page: the first link
(`#next`) becomes document.activeElement and Chromium's status bubble shows its
URL. WebKit panes keep BODY.

Exit codes: 0 when the bug is still present (expected failure, printed XFAIL)
or the build has no Chromium engine (SKIP); 1 when focus stays put (XPASS:
the fork is fixed, drop the expected-fail marker) or on harness errors.
Set CMUX_CHROMIUM_SPLIT_FOCUS_STRICT=1 to fail on the bug instead.

Usage: CMUX_SOCKET_PATH=<tagged socket> python3 tests_v2/test_browser_chromium_split_focus.py
"""

from __future__ import annotations

import http.server
import os
import socketserver
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
STRICT = os.environ.get("CMUX_CHROMIUM_SPLIT_FOCUS_STRICT") == "1"
PAGE = (
    "<!doctype html><title>split-focus</title>"
    "<p id='alive'>alive</p><a id='next' href='#n'>next</a> <a href='#m'>more</a>"
)


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        body = PAGE.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def _wait_for(pred, timeout_s: float, label: str):
    """Polls a live app (test harness only) until `pred` returns a truthy value."""
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


def _active(c: cmux, sid: str) -> str:
    reply = c._call("browser.eval", {
        "surface_id": sid,
        "script": "document.activeElement.tagName + ' ' + (document.activeElement.id || '')",
    }) or {}
    return str(reply.get("value") or "").strip()


def main() -> int:
    server = socketserver.TCPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    try:
        with cmux(SOCKET_PATH) as c:
            try:
                opened = c._call("browser.open_split", {"url": url, "engine": "chromium", "focus": False}) or {}
            except cmuxError as exc:
                print(f"SKIP: no Chromium engine ({exc})")
                return 0
            if opened.get("engine") not in (None, "chromium"):
                print(f"SKIP: the pane opened in {opened.get('engine')} (Chromium unavailable)")
                return 0
            sid = str(opened.get("surface_id") or "")
            if not sid:
                raise cmuxError(f"browser.open_split returned no surface_id: {opened}")
            _wait_for(lambda: _active(c, sid).startswith("BODY"), 30, "Chromium page load")
            before = _active(c, sid)
            c._call("surface.split", {"direction": "down", "surface_id": sid})
            # The focus move lands while the split re-parents the page: watch
            # for it for a bounded time instead of reading once.
            try:
                after = _wait_for(lambda: (lambda a: a if a != before else None)(_active(c, sid)), 3,
                                  "a focus change")
            except cmuxError:
                after = _active(c, sid)
    finally:
        server.shutdown()
        server.server_close()

    moved = after != before
    if moved and not STRICT:
        print(f"XFAIL: split moved Chromium focus {before!r} -> {after!r} (needs CEF fork patch F1)")
        return 0
    if moved:
        print(f"FAIL: split moved Chromium focus {before!r} -> {after!r}")
        return 1
    print(f"XPASS: focus stayed {after!r}; the fork is fixed, remove the expected-fail marker")
    return 1


if __name__ == "__main__":
    sys.exit(main())
