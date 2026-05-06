#!/usr/bin/env python3
"""
Regression tests for browser-focused keybind handling.

Why this exists:
  - When WKWebView is first responder, some shortcuts still need to work
    (pane navigation, etc).
  - Control-key combos can produce control characters (e.g. Ctrl+H => backspace),
    so matching must use keyCode fallbacks.

Requires:
  - cmux running
  - Debug socket commands enabled (`set_shortcut`, `simulate_shortcut`)
"""

import json
import os
import sys
import time
from typing import Any, Dict, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux import cmux


def v2_call(
    client: cmux,
    method: str,
    params: Optional[Dict[str, Any]] = None,
    request_id: str = "1",
) -> Any:
    payload = {
        "id": request_id,
        "method": method,
        "params": params if params is not None else {},
    }
    raw = client._send_command(json.dumps(payload))
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid v2 JSON response for {method}: {raw}") from exc

    if not parsed.get("ok"):
        raise RuntimeError(f"v2 {method} failed: {parsed.get('error')}")

    return parsed.get("result")


def browser_eval(client: cmux, surface_id: str, script: str, request_id: str) -> Any:
    result = v2_call(
        client,
        "browser.eval",
        {"surface_id": surface_id, "script": script},
        request_id=request_id,
    )
    if not isinstance(result, dict):
        return None
    return result.get("value")


def focused_pane_id(client: cmux) -> Optional[str]:
    for _idx, pane_id, _count, is_focused in client.list_panes():
        if is_focused:
            return pane_id
    return None


def wait_url_contains(client: cmux, panel_id: str, needle: str, timeout_s: float = 10.0) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        url = client._send_command(f"get_url {panel_id}").strip()
        if url and not url.startswith("ERROR") and needle in url:
            return
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for url to contain '{needle}': {url!r}")


def wait_for_selection(
    client: cmux,
    surface_id: str,
    expected: int,
    timeout_s: float = 2.0,
) -> Optional[int]:
    start = time.time()
    attempt = 0
    last: Optional[int] = None
    while time.time() - start < timeout_s:
        attempt += 1
        value = browser_eval(
            client,
            surface_id,
            """
            (() => {
              const el = document.querySelector('#cmux-arrow-probe');
              if (!el) return null;
              return el.selectionStart;
            })()
            """,
            request_id=f"selection-{expected}-{attempt}",
        )
        last = value if isinstance(value, int) else None
        if last == expected:
            return last
        time.sleep(0.05)
    return last


def test_cmd_ctrl_h_goto_split_left_from_webview(client: cmux) -> tuple[bool, str]:
    """
    Verifies: Cmd+Ctrl+H moves pane focus left while WKWebView is first responder.
    This uses the app shortcut override path so the test is hermetic.
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    # Override focus-left shortcut to Cmd+Ctrl+H for this test.
    client.set_shortcut("focus_left", "cmd+ctrl+h")

    try:
        # Create a browser pane to the right, loading a real page.
        browser_id = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout_s=15.0)

        panes = client.list_panes()
        if len(panes) != 2:
            return False, f"Expected 2 panes, got {len(panes)}: {panes}"

        browser_pane_id = focused_pane_id(client)
        terminal_pane_id = next((pid for _i, pid, _n, _f in panes if pid != browser_pane_id), None)
        if not browser_pane_id or not terminal_pane_id:
            return False, f"Could not identify terminal/browser pane IDs: {panes}"

        # Force WKWebView first responder (socket-driven; avoids flaky clicking).
        client.focus_webview(browser_id)
        client.wait_for_webview_focus(browser_id, timeout_s=3.0)

        pre = focused_pane_id(client)
        if pre != browser_pane_id:
            return False, f"Expected browser pane focused before keypress, got {pre}"

        # Send Cmd+Ctrl+H via socket event injection.
        client.simulate_shortcut("cmd+ctrl+h")
        time.sleep(0.4)

        post = focused_pane_id(client)
        if post != terminal_pane_id:
            return False, f"Expected focus to move left to {terminal_pane_id}, got {post}"

        return True, "Cmd+Ctrl+H moved focus left while webview focused"
    finally:
        # Restore defaults for subsequent tests.
        try:
            client.set_shortcut("focus_left", "clear")
        except Exception:
            pass


def test_cmd_opt_left_arrow_goto_split_left_from_webview(client: cmux) -> tuple[bool, str]:
    """
    Baseline: default pane navigation (Cmd+Option+Left Arrow) moves pane focus
    left while WKWebView is first responder.
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    # Ensure we use the default arrow shortcut.
    client.set_shortcut("focus_left", "clear")

    browser_id = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
    wait_url_contains(client, browser_id, "example.com", timeout_s=15.0)

    panes = client.list_panes()
    if len(panes) != 2:
        return False, f"Expected 2 panes, got {len(panes)}: {panes}"

    browser_pane_id = focused_pane_id(client)
    terminal_pane_id = next((pid for _i, pid, _n, _f in panes if pid != browser_pane_id), None)
    if not browser_pane_id or not terminal_pane_id:
        return False, f"Could not identify terminal/browser pane IDs: {panes}"

    client.focus_webview(browser_id)
    client.wait_for_webview_focus(browser_id, timeout_s=3.0)

    pre = focused_pane_id(client)
    if pre != browser_pane_id:
        return False, f"Expected browser pane focused before keypress, got {pre}"

    client.simulate_shortcut("cmd+opt+left")
    time.sleep(0.4)

    post = focused_pane_id(client)
    if post != terminal_pane_id:
        return False, f"Expected focus to move left to {terminal_pane_id}, got {post}"
    return True, "Cmd+Option+Left moved focus left while webview focused"


def test_plain_horizontal_arrows_move_caret_in_browser_input(client: cmux) -> tuple[bool, str]:
    """
    Plain Left/Right arrows should reach WebKit text inputs while WKWebView is
    first responder. AppKit can otherwise consume them via performKeyEquivalent.
    """
    previous_workspace_id = next(
        (
            workspace_id
            for _idx, workspace_id, _title, selected in client.list_workspaces()
            if selected
        ),
        None,
    )
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    try:
        browser_id = client.new_pane(
            direction="right",
            panel_type="browser",
            url="about:blank",
        )
        v2_call(
            client,
            "browser.wait",
            {"surface_id": browser_id, "load_state": "complete", "timeout_ms": 5000},
            request_id="blank-load",
        )

        client.focus_webview(browser_id)
        client.wait_for_webview_focus(browser_id, timeout_s=3.0)

        initial = browser_eval(
            client,
            browser_id,
            """
            (() => {
              document.body.innerHTML = '<input id="cmux-arrow-probe" value="abcd" />';
              const el = document.querySelector('#cmux-arrow-probe');
              el.focus();
              el.setSelectionRange(2, 2);
              return {
                active: document.activeElement === el,
                start: el.selectionStart,
                end: el.selectionEnd,
                value: el.value
              };
            })()
            """,
            request_id="setup-horizontal-arrows",
        )
        if (
            not isinstance(initial, dict)
            or initial.get("active") is not True
            or initial.get("start") != 2
        ):
            return False, f"Failed to prepare focused input selection: {initial!r}"

        client.simulate_shortcut("left")
        after_left = wait_for_selection(client, browser_id, 1)
        if after_left != 1:
            return False, f"Expected Left arrow to move caret from 2 to 1, got {after_left!r}"

        client.simulate_shortcut("right")
        after_right = wait_for_selection(client, browser_id, 2)
        if after_right != 2:
            return False, f"Expected Right arrow to move caret from 1 to 2, got {after_right!r}"

        return True, "Plain Left/Right arrows moved caret in focused browser input"
    finally:
        try:
            if previous_workspace_id:
                client.select_workspace(previous_workspace_id)
        except Exception:
            pass
        try:
            client.close_workspace(ws_id)
        except Exception:
            pass


def main() -> int:
    print("cmux Browser Custom Keybind Tests")
    print("=" * 50)
    client = cmux()
    client.connect()

    tests = [
        ("Cmd+Opt+Left goto_split:left from webview focus", test_cmd_opt_left_arrow_goto_split_left_from_webview),
        ("Cmd+Ctrl+H goto_split:left from webview focus", test_cmd_ctrl_h_goto_split_left_from_webview),
        (
            "Plain Left/Right arrows move caret in browser input",
            test_plain_horizontal_arrows_move_caret_in_browser_input,
        ),
    ]

    failed = 0
    for name, fn in tests:
        try:
            ok, msg = fn(client)
        except Exception as e:
            ok, msg = False, str(e)
        status = "PASS" if ok else "FAIL"
        print(f"{status}: {name} - {msg}")
        if not ok:
            failed += 1

    if failed == 0:
        print("\nAll tests passed.")
        return 0
    print(f"\n{failed} test(s) failed.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
