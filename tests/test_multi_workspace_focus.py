#!/usr/bin/env python3
"""
Regression test: multi-workspace terminal and browser focus.

Bug 1 (isHidden): When multiple workspaces exist in a ZStack, inactive workspaces'
AppKit NSViews (NSSplitView, NSHostingController containers) remain in the window's
view hierarchy and intercept events (drags, clicks) even when SwiftUI sets
.allowsHitTesting(false). Fix: set isHidden=true on NSView containers for inactive
workspaces via bonsplit's isInteractive flag.

Bug 2 (webview click focus): Clicking inside a WKWebView didn't focus the browser
tab because AppKit delivers the click to WKWebView, not to the SwiftUI Color.clear
overlay used for focus tracking. Fix: CmuxWebView.mouseDown posts a notification
that BrowserPanelView listens for to call onRequestPanelFocus().

This test validates:
  1) Terminals in non-active workspaces remain responsive after switching back.
  2) Terminals in workspaces with splits remain responsive after cycling through
     multiple workspaces (the isHidden toggle doesn't break view attachment).
  3) Browser panel can receive focus and the terminal can reclaim focus afterward.
"""

import os
import sys
import time
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


MARKER_DIR = Path(tempfile.gettempdir())


def _marker(name: str) -> Path:
    return MARKER_DIR / f"cmux_mwf_{name}_{os.getpid()}"


def _clear(marker: Path):
    marker.unlink(missing_ok=True)


def _wait_marker(marker: Path, timeout: float = 5.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        if marker.exists():
            return True
        time.sleep(0.1)
    return False


def _verify_responsive(c: cmux, marker: Path, surface_idx: int, retries: int = 3) -> bool:
    """Send a touch command to a specific terminal surface and check the marker appears."""
    for attempt in range(retries):
        _clear(marker)
        try:
            c.send_key_surface(surface_idx, "ctrl-c")
        except Exception:
            time.sleep(0.5)
            continue
        time.sleep(0.3)
        try:
            c.send_surface(surface_idx, f"touch {marker}\n")
        except Exception:
            time.sleep(0.5)
            continue
        if _wait_marker(marker, timeout=3.0):
            return True
        time.sleep(0.5)
    return False


def _wait_terminal_in_window(c: cmux, surface_idx: int, timeout: float = 5.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            health = c.surface_health()
        except Exception:
            health = []
        for h in health:
            if h.get("index") == surface_idx and h.get("type") == "terminal" and h.get("in_window"):
                return True
        time.sleep(0.2)
    return False


def test_multi_workspace_terminal_responsive(c: cmux) -> None:
    """
    Create two workspaces with splits, cycle between them, and verify all terminals
    in each workspace remain responsive. Before the isHidden fix, terminals in
    workspace A would lose input when workspace B's NSViews sat on top in the
    view hierarchy.
    """
    # Workspace A
    ws_a = c.new_workspace()
    time.sleep(0.3)
    c.new_split("right")
    time.sleep(0.8)
    _wait_terminal_in_window(c, 0, timeout=5.0)
    _wait_terminal_in_window(c, 1, timeout=5.0)

    # Workspace B
    ws_b = c.new_workspace()
    time.sleep(0.3)
    c.new_split("right")
    time.sleep(0.8)
    _wait_terminal_in_window(c, 0, timeout=5.0)
    _wait_terminal_in_window(c, 1, timeout=5.0)

    # Verify workspace B terminals work (this is the "last" workspace)
    m_b0 = _marker("wsb_0")
    m_b1 = _marker("wsb_1")
    try:
        assert _verify_responsive(c, m_b0, 0), "Workspace B surface 0 not responsive"
        assert _verify_responsive(c, m_b1, 1), "Workspace B surface 1 not responsive"
    finally:
        _clear(m_b0)
        _clear(m_b1)

    # Switch back to workspace A
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)
    _wait_terminal_in_window(c, 1, timeout=5.0)

    # Verify workspace A terminals work (this was the bug: non-last workspace lost input)
    m_a0 = _marker("wsa_0")
    m_a1 = _marker("wsa_1")
    try:
        assert _verify_responsive(c, m_a0, 0), \
            "Workspace A surface 0 not responsive after switching back (isHidden regression)"
        assert _verify_responsive(c, m_a1, 1), \
            "Workspace A surface 1 not responsive after switching back (isHidden regression)"
    finally:
        _clear(m_a0)
        _clear(m_a1)

    # Cycle back to B and verify
    c.select_workspace(ws_b)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)
    m_b0_2 = _marker("wsb_0_2")
    try:
        assert _verify_responsive(c, m_b0_2, 0), \
            "Workspace B surface 0 not responsive after cycling"
    finally:
        _clear(m_b0_2)

    # Cleanup
    c.close_workspace(ws_b)
    time.sleep(0.3)
    c.close_workspace(ws_a)
    time.sleep(0.3)


def test_three_workspaces_non_last_responsive(c: cmux) -> None:
    """
    Three workspaces: verify the FIRST workspace (furthest back in ZStack) is still
    responsive. This is the worst case for the old bug since it has two inactive
    workspaces' NSViews stacked above it.
    """
    ws_a = c.new_workspace()
    time.sleep(0.3)
    c.new_split("down")
    time.sleep(0.8)

    ws_b = c.new_workspace()
    time.sleep(0.3)

    ws_c = c.new_workspace()
    time.sleep(0.3)

    # Switch back to workspace A (furthest back in ZStack)
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)
    _wait_terminal_in_window(c, 1, timeout=5.0)

    m0 = _marker("3ws_0")
    m1 = _marker("3ws_1")
    try:
        assert _verify_responsive(c, m0, 0), \
            "First workspace surface 0 not responsive with 2 workspaces stacked above"
        assert _verify_responsive(c, m1, 1), \
            "First workspace surface 1 not responsive with 2 workspaces stacked above"
    finally:
        _clear(m0)
        _clear(m1)

    # Cleanup
    c.close_workspace(ws_c)
    time.sleep(0.2)
    c.close_workspace(ws_b)
    time.sleep(0.2)
    c.close_workspace(ws_a)
    time.sleep(0.2)


def test_rapid_workspace_switching_preserves_focus(c: cmux) -> None:
    """
    Rapidly switch between workspaces and verify terminals remain responsive.
    The isHidden toggle must not break view attachment or cause blank terminals.
    """
    ws_a = c.new_workspace()
    time.sleep(0.3)
    c.new_split("right")
    time.sleep(0.8)

    ws_b = c.new_workspace()
    time.sleep(0.3)

    # Rapid switching
    for _ in range(5):
        c.select_workspace(ws_a)
        time.sleep(0.15)
        c.select_workspace(ws_b)
        time.sleep(0.15)

    # Settle on workspace A and verify
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)
    _wait_terminal_in_window(c, 1, timeout=5.0)

    m0 = _marker("rapid_0")
    m1 = _marker("rapid_1")
    try:
        assert _verify_responsive(c, m0, 0), \
            "Surface 0 not responsive after rapid workspace switching"
        assert _verify_responsive(c, m1, 1), \
            "Surface 1 not responsive after rapid workspace switching"
    finally:
        _clear(m0)
        _clear(m1)

    # Cleanup
    c.close_workspace(ws_b)
    time.sleep(0.2)
    c.close_workspace(ws_a)
    time.sleep(0.2)


def test_browser_panel_focus_and_return(c: cmux) -> None:
    """
    Create a terminal and a browser surface in the same pane, focus the browser,
    then switch back to the terminal. Verifies focus routing works correctly for
    browser panels.
    """
    ws = c.new_workspace()
    time.sleep(0.3)

    # Get the terminal panel ID
    surfaces = c.list_pane_surfaces()
    if not surfaces:
        raise cmuxError("No surfaces after new_workspace")
    term_panel_id = surfaces[0][1]

    # Create a browser surface in the same pane
    browser_panel_id = c.new_surface(panel_type="browser", url="about:blank")
    time.sleep(0.5)

    # Focus the browser and verify
    c.focus_webview(browser_panel_id)
    time.sleep(0.3)
    assert c.is_webview_focused(browser_panel_id), \
        "Browser panel should have focus after focus_webview"

    # Switch back to terminal and verify it's responsive
    c.focus_surface_by_panel(term_panel_id)
    time.sleep(0.3)

    m = _marker("browser_return")
    try:
        # Use the focused terminal
        _clear(m)
        c.send_key("ctrl-c")
        time.sleep(0.2)
        c.send(f"touch {m}\n")
        assert _wait_marker(m, timeout=3.0), \
            "Terminal not responsive after switching back from browser"
    finally:
        _clear(m)

    # Cleanup
    c.close_workspace(ws)
    time.sleep(0.2)


def test_browser_focus_across_workspaces(c: cmux) -> None:
    """
    Workspace A has a terminal, workspace B has a browser. Switching between them
    should correctly route focus to each panel type.
    """
    ws_a = c.new_workspace()
    time.sleep(0.3)

    ws_b = c.new_workspace()
    time.sleep(0.3)
    # Create a browser in workspace B
    browser_panel_id = c.new_surface(panel_type="browser", url="about:blank")
    time.sleep(0.5)

    # Focus browser in workspace B
    c.focus_webview(browser_panel_id)
    time.sleep(0.3)
    assert c.is_webview_focused(browser_panel_id), \
        "Browser should have focus in workspace B"

    # Switch to workspace A (terminal)
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    m = _marker("cross_ws_term")
    try:
        assert _verify_responsive(c, m, 0), \
            "Terminal in workspace A not responsive after switching from browser workspace"
    finally:
        _clear(m)

    # Switch back to workspace B and verify browser still works
    c.select_workspace(ws_b)
    time.sleep(0.5)
    c.focus_webview(browser_panel_id)
    time.sleep(0.3)
    assert c.is_webview_focused(browser_panel_id), \
        "Browser should regain focus after switching back to workspace B"

    # Cleanup
    c.close_workspace(ws_b)
    time.sleep(0.2)
    c.close_workspace(ws_a)
    time.sleep(0.2)


def main() -> int:
    print("=" * 60)
    print("Multi-Workspace Focus Regression Tests")
    print("=" * 60)
    print()

    tests = [
        ("Multi-workspace terminal responsive (isHidden regression)", test_multi_workspace_terminal_responsive),
        ("Three workspaces non-last responsive", test_three_workspaces_non_last_responsive),
        ("Rapid workspace switching preserves focus", test_rapid_workspace_switching_preserves_focus),
        ("Browser panel focus and return", test_browser_panel_focus_and_return),
        ("Browser focus across workspaces", test_browser_focus_across_workspaces),
    ]

    with cmux() as c:
        c.activate_app()
        time.sleep(0.2)

        passed = 0
        failed = 0

        for name, test_fn in tests:
            print(f"  {name}...", end=" ", flush=True)
            try:
                test_fn(c)
                print("PASS")
                passed += 1
            except (AssertionError, cmuxError) as e:
                print(f"FAIL: {e}")
                failed += 1
            except Exception as e:
                print(f"ERROR: {type(e).__name__}: {e}")
                failed += 1

    print()
    print(f"Results: {passed} passed, {failed} failed out of {passed + failed}")

    if failed == 0:
        print("\nPASS: multi-workspace focus")
        return 0
    else:
        print(f"\nFAIL: {failed} test(s) failed")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
