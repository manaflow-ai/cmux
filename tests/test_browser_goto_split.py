#!/usr/bin/env python3
"""
Regression test: Cmd+Option+Arrow (goto_split) must work when a browser panel
is focused and actively displaying a web page.

Requires:
  - cmuxterm running
  - Accessibility permissions for System Events (osascript)
"""

import os
import sys
import time
import subprocess
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def run_osascript(script: str) -> None:
    subprocess.run(["osascript", "-e", script], check=True)


def focused_pane_id(client: cmux) -> Optional[str]:
    """Return the pane_id of the currently focused pane, or None."""
    for _idx, pane_id, _count, is_focused in client.list_panes():
        if is_focused:
            return pane_id
    return None


def click_center_of_app() -> None:
    """Fallback: click the frontmost window to try to give the webview first responder."""
    run_osascript('''
        tell application "System Events"
            tell process "cmuxterm DEV"
                set frontWin to front window
                set {x, y, w, h} to {0, 0, 0, 0}
                set winPos to position of frontWin
                set winSize to size of frontWin
                set x to item 1 of winPos
                set y to item 2 of winPos
                set w to item 1 of winSize
                set h to item 2 of winSize
                -- Click right-center (browser pane is on the right half)
                click at {x + w * 3 / 4, y + h / 2}
            end tell
        end tell
    ''')


def test_goto_split_from_loaded_browser(client: cmux) -> tuple[bool, str]:
    """
    1. Create workspace with horizontal split: terminal (left) | browser with URL (right)
    2. Focus the browser pane and ensure WKWebView has first responder
    3. Send Cmd+Option+Left via osascript
    4. Verify focus moved to the terminal pane (left)
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    # Create a browser pane to the right, loading a real page
    browser_id = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
    time.sleep(2.0)  # Wait for page load

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

    # Ensure browser pane is focused
    client.focus_pane(browser_pane_id)
    time.sleep(0.3)

    # Activate app and force WKWebView first responder (socket-driven, no flakey clicking)
    run_osascript('tell application "cmuxterm DEV" to activate')
    time.sleep(0.3)
    try:
        client.focus_webview(browser_id)
    except Exception:
        # Fallback to click if socket focus fails for any reason.
        click_center_of_app()
    time.sleep(0.2)

    # Verify WebKit (not just the pane) has first responder.
    start = time.time()
    while time.time() - start < 2.0:
        if client.is_webview_focused(browser_id):
            break
        time.sleep(0.05)
    else:
        return False, "Browser pane is focused, but WKWebView is not first responder after click"

    # Verify browser pane is still focused after click
    pre_focus = focused_pane_id(client)
    if pre_focus != browser_pane_id:
        try:
            client.close_workspace(ws_id)
        except Exception:
            pass
        return False, f"Click changed focus away from browser pane (now {pre_focus})"

    # Send Cmd+Option+Left arrow (keyCode 123)
    run_osascript(
        'tell application "System Events" to key code 123 using {command down, option down}'
    )
    time.sleep(0.5)

    new_focused = focused_pane_id(client)

    try:
        client.close_workspace(ws_id)
    except Exception:
        pass

    if new_focused == terminal_pane_id:
        return True, "Cmd+Option+Left moved focus from loaded browser to terminal"
    else:
        return False, (
            f"Focus did NOT move. Expected terminal {terminal_pane_id}, "
            f"got {new_focused} (browser={browser_pane_id})"
        )


def test_goto_split_roundtrip_loaded_browser(client: cmux) -> tuple[bool, str]:
    """
    Round-trip: terminal → browser (Cmd+Opt+Right) → terminal (Cmd+Opt+Left)
    with a loaded page and webview focused.
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.5)

    browser_id = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
    time.sleep(2.0)

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

    # Focus terminal pane first
    client.focus_pane(terminal_pane_id)
    time.sleep(0.3)

    run_osascript('tell application "cmuxterm DEV" to activate')
    time.sleep(0.3)

    # Cmd+Option+Right to move to browser (keyCode 124)
    run_osascript(
        'tell application "System Events" to key code 124 using {command down, option down}'
    )
    time.sleep(0.5)

    mid_focused = focused_pane_id(client)
    if mid_focused != browser_pane_id:
        try:
            client.close_workspace(ws_id)
        except Exception:
            pass
        return False, (
            f"Cmd+Option+Right from terminal didn't reach browser. "
            f"Expected {browser_pane_id}, got {mid_focused}"
        )

    # Now browser is focused. Force WKWebView first responder.
    try:
        client.focus_webview(browser_id)
    except Exception:
        click_center_of_app()
    time.sleep(0.2)

    start = time.time()
    while time.time() - start < 2.0:
        if client.is_webview_focused(browser_id):
            break
        time.sleep(0.05)
    else:
        return False, "WKWebView did not become first responder after click in browser pane"

    # Cmd+Option+Left to go back to terminal (keyCode 123)
    run_osascript(
        'tell application "System Events" to key code 123 using {command down, option down}'
    )
    time.sleep(0.5)

    final_focused = focused_pane_id(client)

    try:
        client.close_workspace(ws_id)
    except Exception:
        pass

    if final_focused == terminal_pane_id:
        return True, "Round-trip through loaded browser with webview focus works"
    else:
        return False, (
            f"Return trip failed. Expected terminal {terminal_pane_id}, got {final_focused}"
        )


def run_tests() -> int:
    print("=" * 60)
    print("cmuxterm Browser goto_split Regression Test")
    print("=" * 60)
    print()

    probe = cmux()
    socket_path = probe.socket_path
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmuxterm is running.")
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
