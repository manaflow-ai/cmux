#!/usr/bin/env python3
"""
Tests for browser back/forward via Cmd+[/] keyboard shortcuts.

Verifies that:
  1. Cmd+[ triggers browser goBack when a browser panel is focused
  2. Cmd+] triggers browser goForward when a browser panel is focused
  3. Cmd+[/] are no-ops when a terminal panel is focused

Requires:
  - cmux running
  - Debug socket commands enabled (`simulate_shortcut`)
"""

import os
import sys
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def focused_pane_id(client: cmux) -> Optional[str]:
    """Return the pane_id of the currently focused pane, or None."""
    for _idx, pane_id, _count, is_focused in client.list_panes():
        if is_focused:
            return pane_id
    return None


def get_browser_url(client: cmux, panel_id: str) -> str:
    """Get the current URL of a browser panel."""
    return client._send_command(f"get_url {panel_id}").strip()


def navigate_browser(client: cmux, panel_id: str, url: str) -> None:
    """Navigate a browser panel to a URL."""
    response = client._send_command(f"navigate {panel_id} {url}")
    if not response.startswith("OK"):
        raise cmuxError(response)


def wait_for_url(client: cmux, panel_id: str, expected_url: str,
                 timeout_s: float = 5.0, contains: bool = False) -> bool:
    """Poll until the browser panel's URL matches the expected value."""
    start = time.time()
    while time.time() - start < timeout_s:
        url = get_browser_url(client, panel_id)
        if contains:
            if expected_url in url:
                return True
        else:
            if url == expected_url:
                return True
        time.sleep(0.2)
    return False


def test_cmd_bracket_back_forward(client: cmux) -> tuple[bool, str]:
    """
    1. Create workspace with a browser pane
    2. Navigate to page A, then page B
    3. Cmd+[ should go back to page A
    4. Cmd+] should go forward to page B
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(1.0)

    # Create a browser surface
    browser_id = client.new_surface(panel_type="browser", url="https://example.com")
    time.sleep(3.0)  # Wait for page load

    # Verify initial URL
    if not wait_for_url(client, browser_id, "https://example.com/", timeout_s=5.0):
        url = get_browser_url(client, browser_id)
        # example.com might redirect or have trailing slash differences
        if "example.com" not in url:
            client.close_workspace(ws_id)
            return False, f"Initial URL not example.com, got: {url}"

    page_a_url = get_browser_url(client, browser_id)

    # Navigate to a second page
    navigate_browser(client, browser_id, "https://example.org")
    time.sleep(2.0)

    if not wait_for_url(client, browser_id, "example.org", timeout_s=5.0, contains=True):
        url = get_browser_url(client, browser_id)
        client.close_workspace(ws_id)
        return False, f"Navigation to page B failed, URL: {url}"

    page_b_url = get_browser_url(client, browser_id)

    # Focus the webview so Cmd+[ routes through the browser
    client.focus_webview(browser_id)
    client.wait_for_webview_focus(browser_id, timeout_s=3.0)

    # Cmd+[ (back) — should go back to page A
    client.simulate_shortcut("cmd+[")
    time.sleep(1.5)

    url_after_back = get_browser_url(client, browser_id)
    if "example.com" not in url_after_back:
        client.close_workspace(ws_id)
        return False, f"Cmd+[ did not go back. Expected example.com, got: {url_after_back}"

    # Cmd+] (forward) — should go forward to page B
    client.simulate_shortcut("cmd+]")
    time.sleep(1.5)

    url_after_forward = get_browser_url(client, browser_id)
    if "example.org" not in url_after_forward:
        client.close_workspace(ws_id)
        return False, f"Cmd+] did not go forward. Expected example.org, got: {url_after_forward}"

    client.close_workspace(ws_id)
    return True, "Cmd+[/] back/forward works correctly"


def test_cmd_bracket_noop_on_terminal(client: cmux) -> tuple[bool, str]:
    """
    Verify that Cmd+[/] are no-ops when focused on a terminal (no browser panel focused).
    The workspace should not change.
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(1.0)

    current_ws = client.current_workspace()

    # Cmd+[ on terminal should be a no-op (no crash, no workspace change)
    client.simulate_shortcut("cmd+[")
    time.sleep(0.3)

    # Verify we're still on the same workspace
    after_ws = client.current_workspace()
    if current_ws != after_ws:
        client.close_workspace(ws_id)
        return False, f"Cmd+[ on terminal changed workspace from {current_ws} to {after_ws}"

    # Cmd+] should also be a no-op
    client.simulate_shortcut("cmd+]")
    time.sleep(0.3)

    after_ws2 = client.current_workspace()
    if current_ws != after_ws2:
        client.close_workspace(ws_id)
        return False, f"Cmd+] on terminal changed workspace from {current_ws} to {after_ws2}"

    client.close_workspace(ws_id)
    return True, "Cmd+[/] are no-ops on terminal"


def test_browser_back_forward_socket_commands(client: cmux) -> tuple[bool, str]:
    """
    Test that browser_back and browser_forward socket commands work correctly.
    This verifies the underlying goBack()/goForward() methods independently
    of keyboard shortcuts.
    """
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(1.0)

    # Create browser and navigate to two pages
    browser_id = client.new_surface(panel_type="browser", url="https://example.com")
    time.sleep(3.0)

    if not wait_for_url(client, browser_id, "example.com", timeout_s=5.0, contains=True):
        url = get_browser_url(client, browser_id)
        client.close_workspace(ws_id)
        return False, f"Initial navigation failed, URL: {url}"

    navigate_browser(client, browser_id, "https://example.org")
    time.sleep(2.0)

    if not wait_for_url(client, browser_id, "example.org", timeout_s=5.0, contains=True):
        url = get_browser_url(client, browser_id)
        client.close_workspace(ws_id)
        return False, f"Second navigation failed, URL: {url}"

    # browser_back
    resp = client._send_command(f"browser_back {browser_id}")
    if not resp.startswith("OK"):
        client.close_workspace(ws_id)
        return False, f"browser_back command failed: {resp}"
    time.sleep(1.5)

    url_after_back = get_browser_url(client, browser_id)
    if "example.com" not in url_after_back:
        client.close_workspace(ws_id)
        return False, f"browser_back did not go back. Got: {url_after_back}"

    # browser_forward
    resp = client._send_command(f"browser_forward {browser_id}")
    if not resp.startswith("OK"):
        client.close_workspace(ws_id)
        return False, f"browser_forward command failed: {resp}"
    time.sleep(1.5)

    url_after_forward = get_browser_url(client, browser_id)
    if "example.org" not in url_after_forward:
        client.close_workspace(ws_id)
        return False, f"browser_forward did not go forward. Got: {url_after_forward}"

    client.close_workspace(ws_id)
    return True, "browser_back/browser_forward socket commands work correctly"


def main():
    client = cmux()
    client.connect()

    tests = [
        ("browser_back_forward_socket", test_browser_back_forward_socket_commands),
        ("cmd_bracket_back_forward", test_cmd_bracket_back_forward),
        ("cmd_bracket_noop_on_terminal", test_cmd_bracket_noop_on_terminal),
    ]

    results = []
    for name, test_fn in tests:
        print(f"  Running {name}...", end=" ", flush=True)
        try:
            passed, msg = test_fn(client)
            status = "PASS" if passed else "FAIL"
            print(f"{status}: {msg}")
            results.append((name, passed, msg))
        except Exception as e:
            print(f"ERROR: {e}")
            results.append((name, False, str(e)))

    client.close()

    print()
    passed = sum(1 for _, p, _ in results if p)
    total = len(results)
    print(f"Results: {passed}/{total} passed")

    if passed < total:
        for name, p, msg in results:
            if not p:
                print(f"  FAILED: {name}: {msg}")
        sys.exit(1)


if __name__ == "__main__":
    main()
