#!/usr/bin/env python3
"""
Regression test: Cmd+Option+Arrow (goto_split) must work when a browser panel
is focused and actively displaying a web page.

Requires:
  - cmux running
  - Debug socket commands enabled (`simulate_shortcut`)
"""

import contextlib
import http.server
import os
import socketserver
import sys
import threading
import time
from typing import Iterator, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def focused_pane_id(client: cmux) -> Optional[str]:
    """Return the pane_id of the currently focused pane, or None."""
    for _idx, pane_id, _count, is_focused in client.list_panes():
        if is_focused:
            return pane_id
    return None


@contextlib.contextmanager
def _local_test_server() -> Iterator[str]:
    """Serve a tiny static page from an ephemeral 127.0.0.1 port.

    Avoids depending on external network (https://example.com), which makes the
    blind page-load wait flaky in CI without/with throttled network access.
    """
    html = (
        "<!DOCTYPE html><html><head><title>goto-split</title></head>"
        "<body><h1 id=\"hello\">goto split test</h1></body></html>"
    )

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return

    class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = ThreadedTCPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}/"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1.0)


def _wait_focused(client: cmux, expected_pane_id: str, timeout_s: float = 6.0) -> Optional[str]:
    """Poll until the focused pane equals expected_pane_id, or the deadline.

    Pane-focus change after a synthesized shortcut is asynchronous (event
    injection -> first-responder handoff -> focus-state propagation), so a fixed
    sleep races under load. Returns the last-observed focused pane id.
    """
    deadline = time.time() + timeout_s
    focused = focused_pane_id(client)
    while time.time() < deadline:
        focused = focused_pane_id(client)
        if focused == expected_pane_id:
            return focused
        time.sleep(0.05)
    return focused


def _wait_url_loaded(client: cmux, browser_id: str, timeout_s: float = 10.0) -> str:
    """Poll the browser surface until it reports a non-blank loaded URL.

    Replaces a blind time.sleep page-load wait; returns as soon as the page URL
    is observable, and only spends the full deadline on the failure path. Raises
    AssertionError if the page never leaves about:blank within the deadline, so a
    browser that fails to load fails the test loudly instead of passing silently.
    """
    deadline = time.time() + timeout_s
    last_error: Optional[Exception] = None
    while time.time() < deadline:
        try:
            url = client.get_url(browser_id)
        except Exception as err:
            last_error = err
            url = ""
        if url and url not in ("about:blank", "about:blank#blocked"):
            return url
        time.sleep(0.1)
    detail = f"; last_error={last_error}" if last_error is not None else ""
    raise AssertionError(
        f"Browser {browser_id} did not report a loaded URL within {timeout_s:.1f}s{detail}"
    )


def test_goto_split_from_loaded_browser(client: cmux) -> tuple[bool, str]:
    """
    1. Create workspace with horizontal split: terminal (left) | browser with URL (right)
    2. Focus the browser pane and ensure WKWebView has first responder
    3. Send Cmd+Option+Left via debug socket simulate_shortcut
    4. Verify focus moved to the terminal pane (left)
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    # Ensure we use the default Cmd+Option+Arrow shortcuts for this regression test.
    client.set_shortcut("focus_left", "clear")
    client.set_shortcut("focus_right", "clear")

    # Create a browser pane to the right, loading a local ephemeral page
    # (avoids depending on external network for a deterministic load signal).
    # The `with` block guarantees the server thread/socket are torn down even if
    # setup throws before the cleanup path.
    with _local_test_server() as page_url:
        browser_id = client.new_pane(direction="right", panel_type="browser", url=page_url)
        _wait_url_loaded(client, browser_id)  # Wait on a real load signal, not a fixed sleep

        try:
            # Identify the two panes
            panes = client.list_panes()
            if len(panes) < 2:
                return False, f"Expected 2 panes, got {len(panes)}"

            browser_pane_id = focused_pane_id(client)
            terminal_pane_id = None
            for _idx, pid, _count, is_focused in panes:
                if pid != browser_pane_id:
                    terminal_pane_id = pid
                    break

            if not terminal_pane_id or not browser_pane_id:
                return False, f"Could not identify terminal/browser panes: {panes}"

            # Ensure browser pane is focused (poll for the async focus to land).
            client.focus_pane(browser_pane_id)
            _wait_focused(client, browser_pane_id)

            # Force WKWebView first responder (socket-driven; avoids flakey clicking).
            client.focus_webview(browser_id)
            client.wait_for_webview_focus(browser_id, timeout_s=10.0)

            # Verify WebKit (not just the pane) has first responder.
            if not client.is_webview_focused(browser_id):
                return False, "Browser pane is focused, but WKWebView is not first responder"

            # Verify browser pane is still focused after webview focus
            pre_focus = focused_pane_id(client)
            if pre_focus != browser_pane_id:
                return False, f"Click changed focus away from browser pane (now {pre_focus})"

            # Send Cmd+Option+Left arrow; poll for the focus change to propagate.
            client.simulate_shortcut("cmd+opt+left")
            new_focused = _wait_focused(client, terminal_pane_id)

            if new_focused == terminal_pane_id:
                return True, "Cmd+Option+Left moved focus from loaded browser to terminal"
            else:
                return False, (
                    f"Focus did NOT move. Expected terminal {terminal_pane_id}, "
                    f"got {new_focused} (browser={browser_pane_id})"
                )
        finally:
            try:
                client.close_workspace(ws_id)
            except Exception:
                pass


def test_goto_split_roundtrip_loaded_browser(client: cmux) -> tuple[bool, str]:
    """
    Round-trip: terminal → browser (Cmd+Opt+Right) → terminal (Cmd+Opt+Left)
    with a loaded page and webview focused.
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    client.set_shortcut("focus_left", "clear")
    client.set_shortcut("focus_right", "clear")

    with _local_test_server() as page_url:
        browser_id = client.new_pane(direction="right", panel_type="browser", url=page_url)
        _wait_url_loaded(client, browser_id)

        try:
            panes = client.list_panes()
            if len(panes) < 2:
                return False, f"Expected 2 panes, got {len(panes)}"

            browser_pane_id = focused_pane_id(client)
            terminal_pane_id = None
            for _idx, pid, _count, is_focused in panes:
                if pid != browser_pane_id:
                    terminal_pane_id = pid
                    break

            if not terminal_pane_id or not browser_pane_id:
                return False, f"Could not identify panes: {panes}"

            # Focus terminal pane first (poll for the async focus to land).
            client.focus_pane(terminal_pane_id)
            _wait_focused(client, terminal_pane_id)

            # Cmd+Option+Right to move to browser; poll for the focus change.
            client.simulate_shortcut("cmd+opt+right")
            mid_focused = _wait_focused(client, browser_pane_id)
            if mid_focused != browser_pane_id:
                return False, (
                    f"Cmd+Option+Right from terminal didn't reach browser. "
                    f"Expected {browser_pane_id}, got {mid_focused}"
                )

            # Now browser is focused. Force WKWebView first responder.
            client.focus_webview(browser_id)
            client.wait_for_webview_focus(browser_id, timeout_s=10.0)
            if not client.is_webview_focused(browser_id):
                return False, "WKWebView did not become first responder in browser pane"

            # Cmd+Option+Left to go back to terminal; poll for the focus change.
            client.simulate_shortcut("cmd+opt+left")
            final_focused = _wait_focused(client, terminal_pane_id)

            if final_focused == terminal_pane_id:
                return True, "Round-trip through loaded browser with webview focus works"
            else:
                return False, (
                    f"Return trip failed. Expected terminal {terminal_pane_id}, got {final_focused}"
                )
        finally:
            try:
                client.close_workspace(ws_id)
            except Exception:
                pass


def run_tests() -> int:
    print("=" * 60)
    print("cmux Browser goto_split Regression Test")
    print("=" * 60)
    print()

    probe = cmux()
    socket_path = probe.socket_path
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmux is running.")
        return 1

    tests = [
        ("goto_split LEFT from loaded browser", test_goto_split_from_loaded_browser),
        ("goto_split round-trip with webview focus", test_goto_split_roundtrip_loaded_browser),
    ]

    passed = 0
    failed = 0

    try:
        with cmux(socket_path=socket_path) as client:
            for name, fn in tests:
                print(f"  Running: {name} ... ", end="", flush=True)
                try:
                    ok, msg = fn(client)
                except Exception as e:
                    ok, msg = False, str(e)
                status = "PASS" if ok else "FAIL"
                print(f"{status}: {msg}")
                if ok:
                    passed += 1
                else:
                    failed += 1
    except cmuxError as e:
        print(f"Error: {e}")
        return 1

    print()
    print(f"Results: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(run_tests())
