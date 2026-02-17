#!/usr/bin/env python3
"""
Stability regression test: browser panels should not crash cmux when:
  1) Creating a browser surface then immediately creating a new terminal surface
  2) Rapidly switching focus between panes when one pane is a loaded browser

This test uses the control socket only (no osascript / Accessibility required).

Requires:
  - cmux running
"""

import os
import sys
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def wait_for_socket(path: str, timeout_s: float = 5.0) -> None:
    start = time.time()
    while not os.path.exists(path):
        if time.time() - start >= timeout_s:
            raise RuntimeError(f"Socket not found at {path}")
        time.sleep(0.1)


def ensure_webview_focused(client: cmux, panel_id: str, timeout_s: float = 2.0) -> None:
    """
    Best-effort: focus the surface, then force WKWebView first responder, and verify it stuck.
    This is important because the crash regression only reproduces when WebKit is actually first responder.
    """
    start = time.time()
    last_error: Optional[Exception] = None
    while time.time() - start < timeout_s:
        try:
            client.focus_surface(panel_id)
            client.focus_webview(panel_id)
            if client.is_webview_focused(panel_id):
                return
        except Exception as e:
            last_error = e
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for webview focus (panel={panel_id}): {last_error}")


def test_open_browser_then_new_surface_loop(client: cmux) -> tuple[bool, str]:
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    # Keep one "base" terminal surface around so close_surface never hits the last-surface guard.
    for i in range(10):
        browser_id = client.new_surface(panel_type="browser", url="https://example.com")
        time.sleep(0.8)
        ensure_webview_focused(client, browser_id, timeout_s=2.0)

        terminal_id = client.new_surface(panel_type="terminal")
        time.sleep(0.2)

        # Rapid focus flipping to stress first-responder + view lifecycle.
        for _ in range(10):
            client.focus_surface(browser_id)
            try:
                client.focus_webview(browser_id)
            except Exception:
                # If focus is transient during bonsplit reshuffles, retry once with a short delay.
                time.sleep(0.05)
                ensure_webview_focused(client, browser_id, timeout_s=0.8)
            if not client.is_webview_focused(browser_id):
                return False, "Browser surface is focused, but WKWebView is not first responder"
            client.focus_surface(terminal_id)
            time.sleep(0.05)

        # If the app crashed/restarted, the socket command would error before this point.
        if not client.ping():
            return False, f"Ping failed after iteration {i}"

        # Clean up the two surfaces created in this iteration.
        try:
            client.close_surface(browser_id)
        except Exception:
            # If close fails due to ordering, keep going; the workspace close at end will clean up.
            pass
        time.sleep(0.1)

        try:
            client.close_surface(terminal_id)
        except Exception:
            pass
        time.sleep(0.2)

    try:
        client.close_workspace(ws_id)
    except Exception:
        pass

    return True, "Repeated open browser + new surface did not crash"


def test_focus_panes_with_loaded_browser(client: cmux) -> tuple[bool, str]:
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    # Create a browser pane (split). This should leave us with at least 2 panes.
    browser_id = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
    time.sleep(1.5)
    ensure_webview_focused(client, browser_id, timeout_s=2.0)

    panes = client.list_panes()
    if len(panes) < 2:
        try:
            client.close_workspace(ws_id)
        except Exception:
            pass
        return False, f"Expected >=2 panes, got {len(panes)}: {panes}"

    pane_ids = [pid for _idx, pid, _count, _is_focused in panes]
    browser_pane_id = None
    for _idx, pid, _count, is_focused in panes:
        if is_focused:
            browser_pane_id = pid
            break

    if not browser_pane_id:
        return False, f"Could not determine focused pane after creating browser: {panes}"

    # Rapidly cycle focus between panes.
    saw_webview_focus = False
    for i in range(60):
        for pid in pane_ids:
            client.focus_pane(pid)
            time.sleep(0.03)
            if pid == browser_pane_id:
                # Make sure we actually focus into WebKit before switching away.
                ensure_webview_focused(client, browser_id, timeout_s=0.8)
                saw_webview_focus = True
        if i % 10 == 0 and not client.ping():
            return False, f"Ping failed during pane focus loop (i={i})"

    if not saw_webview_focus:
        return False, "Never observed WKWebView first responder during pane focus loop"

    try:
        client.close_workspace(ws_id)
    except Exception:
        pass

    return True, "Rapid focus_pane loop with loaded browser did not crash"


def run_tests() -> int:
    print("=" * 60)
    print("cmux Browser Panel Stability Test")
    print("=" * 60)
    print()

    probe = cmux()
    wait_for_socket(probe.socket_path, timeout_s=5.0)

    tests = [
        ("open_browser then new_surface loop", test_open_browser_then_new_surface_loop),
        ("focus panes with loaded browser", test_focus_panes_with_loaded_browser),
    ]

    passed = 0
    failed = 0

    try:
        with cmux(socket_path=probe.socket_path) as client:
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
    raise SystemExit(run_tests())
