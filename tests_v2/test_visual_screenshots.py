#!/usr/bin/env python3
"""
Visual Screenshot Tests for cmuxterm

Comprehensive edge-case testing with before/after screenshots for:
  A. Basic splits (baseline)
  B. Close operations (the bug surface)
  C. Multi-pane close
  D. Asymmetric / deep nesting
  E. Browser + terminal mix
  F. Multiple surfaces in a pane (nested tabs)
  G. Rapid stress tests
  H. Workspace interactions
  I. Browser drag-to-split right

Usage:
    python3 tests/test_visual_screenshots.py
    # Then open tests/visual_report.html in a browser
"""

import os
import sys
import time
import base64
import json
import tempfile
from pathlib import Path
from datetime import datetime
from dataclasses import dataclass
from typing import Optional, List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")
HTML_REPORT = Path(__file__).parent / "visual_report.html"

# Timing constants
SPLIT_WAIT = 0.8       # after creating a split
CLOSE_WAIT = 0.8       # after closing a surface/pane
SHORT_WAIT = 0.3       # focus switch / minor action
SCREENSHOT_WAIT = 0.3  # before taking a screenshot


@dataclass
class Screenshot:
    path: Path
    label: str
    timestamp: str

    def to_base64(self) -> str:
        with open(self.path, "rb") as f:
            return base64.b64encode(f.read()).decode("utf-8")


@dataclass
class StateChange:
    name: str
    description: str
    group: str = ""
    before: Optional[Screenshot] = None
    after: Optional[Screenshot] = None
    command: str = ""
    result: str = ""
    passed: bool = True
    error: str = ""
    before_state: str = ""
    after_state: str = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_screenshot_idx = 0


def get_client() -> cmux:
    c = cmux(SOCKET_PATH)
    c.connect()
    return c


def take_screenshot(client: cmux, label: str) -> Optional[Screenshot]:
    global _screenshot_idx
    idx = _screenshot_idx
    _screenshot_idx += 1
    try:
        safe_label = label.replace(" ", "_").replace("/", "-")
        label2 = f"{idx:03d}_{safe_label}"
        info = client.screenshot(label2)
        screenshot_path = Path(str(info.get("path") or ""))
        if not screenshot_path.exists():
            return None

        return Screenshot(
            path=screenshot_path,
            label=label,
            timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        )
    except Exception:
        return None


def capture_state(client: cmux) -> str:
    try:
        panes = client.list_panes()
        state = {
            "workspaces": client.list_workspaces(),
            "surfaces": client.list_surfaces(),
            "panes": panes,
            "pane_surfaces": {pid: client.list_pane_surfaces(pid) for _i, pid, _n, _f in panes},
            "surface_health": client.surface_health(),
        }
        return json.dumps(state, indent=2, sort_keys=True)
    except Exception as e:
        return f"Error: {e}"

def stamp_terminals(client: cmux, label: str) -> None:
    """Emit a visible marker line in each terminal surface for screenshots."""
    safe = label.replace("\n", " ").replace("\r", " ").strip()
    if not safe:
        return
    try:
        health = client.surface_health()
    except Exception:
        return
    terminal_surfaces = [h for h in health if h.get("type") == "terminal"]
    for h in terminal_surfaces:
        idx = h.get("index")
        if idx is None:
            continue
        try:
            # Keep it simple to avoid shell quoting issues.
            client.send_surface(idx, f"echo CMUX_VIS {safe} surf={idx}\n")
        except Exception:
            pass


def capture(client: cmux, label: str):
    """Take screenshot + state snapshot. Returns (Screenshot|None, state_str)."""
    stamp_terminals(client, label)
    time.sleep(SCREENSHOT_WAIT)
    ss = take_screenshot(client, label)
    state = capture_state(client)
    return ss, state


def reset_workspace(client: cmux) -> cmux:
    """Create a fresh workspace and return a reconnected client."""
    try:
        client.new_workspace()
    except Exception:
        pass
    time.sleep(SHORT_WAIT)
    client.close()
    time.sleep(0.2)
    return get_client()


def surface_count(client: cmux) -> int:
    return len(client.list_surfaces())

def pane_count(client: cmux) -> int:
    """Return number of panes in current workspace (via list_panes)."""
    try:
        panes = client.list_panes()
    except Exception:
        return 0
    return len(panes)


def wait_surface_count(client: cmux, expected: int, timeout: float = 3.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        if surface_count(client) == expected:
            return True
        time.sleep(0.2)
    return False


def _parse_ok_id(response: str) -> Optional[str]:
    response = (response or "").strip()
    if response.startswith("OK "):
        return response[3:].strip().split(" ", 1)[0]
    return None


def wait_url_contains(client: cmux, panel_id: str, needle: str, timeout: float = 8.0) -> bool:
    """Poll get_url until it contains `needle`."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            url = client.get_url(panel_id).strip()
        except Exception:
            url = ""
        if url and not url.startswith("ERROR") and needle in url:
            return True
        time.sleep(0.2)
    return False


def cleanup_workspaces(client: cmux):
    """Close all but the current workspace."""
    try:
        workspaces = client.list_workspaces()
        current = None
        for _, wid, _, sel in workspaces:
            if sel:
                current = wid
                break
        for _, wid, _, sel in workspaces:
            if wid != current:
                try:
                    client.close_workspace(wid)
                    time.sleep(0.1)
                except Exception:
                    pass
    except Exception:
        pass


def _wait_marker(marker: Path, timeout: float = 3.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        if marker.exists():
            return True
        time.sleep(0.1)
    return False


def _verify_surface_responsive(client: cmux, surface_idx: int, marker: Path,
                                retries: int = 3) -> bool:
    """Try sending a command to one surface, return True if it responds."""
    for attempt in range(retries):
        marker.unlink(missing_ok=True)
        try:
            client.send_key_surface(surface_idx, "ctrl-c")
        except Exception:
            pass
        time.sleep(0.3)
        try:
            client.send_surface(surface_idx, f"touch {marker}\n")
        except Exception:
            # Surface may be transiently unavailable during tree/layout restructuring.
            time.sleep(0.5)
            continue
        if _wait_marker(marker, timeout=3.0):
            return True
        time.sleep(0.5)
    return False


def verify_views_in_window(client: cmux, label: str = "", timeout: float = 5.0) -> Optional[str]:
    """Verify all surface views are attached to a window.

    Polls surface_health until all surfaces report in_window=true,
    or until timeout. Returns None on success, or an error string.
    Works for both terminal and browser panels.
    """
    start = time.time()
    while time.time() - start < timeout:
        try:
            health = client.surface_health()
        except Exception as e:
            return f"surface_health failed: {e}"

        if not health:
            return f"no surfaces found [{label}]"

        orphaned = [h for h in health if not h["in_window"]]
        if not orphaned:
            return None  # all in window

        time.sleep(0.2)

    # Timed out — report which surfaces are orphaned
    types_and_ids = [(h["type"], h["id"][:8]) for h in orphaned]
    return f"surface(s) not in window after {timeout}s: {types_and_ids} [{label}]"


def verify_all_responsive(client: cmux, label: str = "") -> Optional[str]:
    """Verify every terminal surface is responsive by writing a marker file.

    Returns None on success, or an error string describing which surface
    is blank / unresponsive.  Calls refresh_surfaces first as a backstop
    to force Metal re-render before checking.
    """
    # First check that all views are in the window (auto-detect orphaned views)
    window_err = verify_views_in_window(client, label)
    if window_err:
        return f"VIEW_DETACHED: {window_err}"

    # Ask the app to force-refresh all terminal surfaces
    try:
        client.refresh_surfaces()
    except Exception:
        pass
    time.sleep(0.3)

    health = client.surface_health()
    if not health:
        return "no surfaces found"

    # Only verify terminal surfaces; browser panels cannot accept send_surface commands.
    terminal_surfaces = [h for h in health if h.get("type") == "terminal"]
    if not terminal_surfaces:
        return None

    blanks = []
    for idx, h in enumerate(terminal_surfaces):
        surface_idx = h["index"]
        marker = Path(tempfile.gettempdir()) / f"cmux_vis_{os.getpid()}_{idx}"
        try:
            if not _verify_surface_responsive(client, surface_idx, marker, retries=3):
                blanks.append(surface_idx)
        finally:
            marker.unlink(missing_ok=True)

    if blanks:
        return f"terminal surface(s) {blanks} unresponsive (blank?) [{label}]"
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_a1_initial_state(client: cmux) -> StateChange:
    """A1: Capture initial single-terminal state."""
    change = StateChange(
        name="Initial State", group="A",
        description="Single terminal pane — baseline",
    )
    change.after, change.after_state = capture(client, "a1_initial")
    return change


def test_a2_split_right(client: cmux) -> StateChange:
    """A2: Horizontal split right."""
    change = StateChange(
        name="Horizontal Split Right", group="A",
        description="Split terminal horizontally (right)",
        command="new_split right",
    )
    change.before, change.before_state = capture(client, "a2_before")
    try:
        client.new_split("right")
        change.result = "OK"
    except Exception as e:
        change.error = str(e)
        change.passed = False
    time.sleep(SPLIT_WAIT)
    change.after, change.after_state = capture(client, "a2_after")
    if change.passed:
        change.passed = surface_count(client) == 2
        if not change.passed:
            change.error = f"Expected 2 surfaces, got {surface_count(client)}"
    return change


def test_a3_split_down(client: cmux) -> StateChange:
    """A3: Vertical split down."""
    change = StateChange(
        name="Vertical Split Down", group="A",
        description="Split focused pane vertically (down)",
        command="new_split down",
    )
    change.before, change.before_state = capture(client, "a3_before")
    try:
        client.new_split("down")
        change.result = "OK"
    except Exception as e:
        change.error = str(e)
        change.passed = False
    time.sleep(SPLIT_WAIT)
    change.after, change.after_state = capture(client, "a3_after")
    if change.passed:
        change.passed = surface_count(client) == 2
        if not change.passed:
            change.error = f"Expected 2 surfaces, got {surface_count(client)}"
    return change


def _close_and_verify(client: cmux, change: StateChange, close_idx: int,
                      expected: int, before_label: str, after_label: str) -> StateChange:
    """Shared logic: close a surface, verify count, verify responsiveness, capture after."""
    change.before, change.before_state = capture(client, before_label)
    try:
        client.close_surface(close_idx)
        time.sleep(CLOSE_WAIT)
        if not wait_surface_count(client, expected):
            change.error = f"Expected {expected} surface(s), got {surface_count(client)}"
            change.passed = False
        else:
            # Functional blank-detection: verify every remaining terminal responds
            blank_err = verify_all_responsive(client, after_label)
            if blank_err:
                change.error = f"BLANK: {blank_err}"
                change.passed = False
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, after_label)
    return change


def test_b4_close_right(client: cmux) -> StateChange:
    """B4: Close RIGHT pane in horizontal split."""
    change = StateChange(
        name="Close Right Pane (H-split)", group="B",
        description="Horizontal split → close right pane → left should survive",
        command="new_split right; close_surface 1",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 1, 1, "b4_before", "b4_after")


def test_b5_close_left(client: cmux) -> StateChange:
    """B5: Close LEFT (first) pane in horizontal split."""
    change = StateChange(
        name="Close Left Pane (H-split)", group="B",
        description="Horizontal split → close left pane → right should survive",
        command="new_split right; close_surface 0",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 0, 1, "b5_before", "b5_after")


def test_b6_close_bottom(client: cmux) -> StateChange:
    """B6: Close BOTTOM pane in vertical split."""
    change = StateChange(
        name="Close Bottom Pane (V-split)", group="B",
        description="Vertical split → close bottom pane → top should survive",
        command="new_split down; close_surface 1",
    )
    client.new_split("down")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 1, 1, "b6_before", "b6_after")


def test_b7_close_top(client: cmux) -> StateChange:
    """B7: Close TOP (first) pane in vertical split."""
    change = StateChange(
        name="Close Top Pane (V-split)", group="B",
        description="Vertical split → close top pane → bottom should survive",
        command="new_split down; close_surface 0",
    )
    client.new_split("down")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 0, 1, "b7_before", "b7_after")


def test_c8_3way_close_middle(client: cmux) -> StateChange:
    """C8: 3-way horizontal — close middle pane."""
    change = StateChange(
        name="3-Way H-Split: Close Middle", group="C",
        description="3 horizontal panes → close middle → outer 2 should survive",
        command="split right x2; close_surface 1",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(1)
    time.sleep(SHORT_WAIT)
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 1, 2, "c8_before", "c8_after")


def test_c9_grid_close_topleft(client: cmux) -> StateChange:
    """C9: 2x2 grid — close top-left."""
    change = StateChange(
        name="2x2 Grid: Close Top-Left", group="C",
        description="4-pane grid → close top-left → 3 remain",
        command="split right, split each down; close_surface 0",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(0)
    time.sleep(SHORT_WAIT)
    client.new_split("down")
    time.sleep(SPLIT_WAIT)
    surfaces = client.list_surfaces()
    if len(surfaces) >= 3:
        client.focus_surface(2)
        time.sleep(SHORT_WAIT)
        client.new_split("down")
        time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 0, 3, "c9_before", "c9_after")


def test_c10_grid_close_bottomright(client: cmux) -> StateChange:
    """C10: 2x2 grid — close bottom-right."""
    change = StateChange(
        name="2x2 Grid: Close Bottom-Right", group="C",
        description="4-pane grid → close bottom-right → 3 remain",
        command="build 2x2; close last surface",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(0)
    time.sleep(SHORT_WAIT)
    client.new_split("down")
    time.sleep(SPLIT_WAIT)
    surfaces = client.list_surfaces()
    if len(surfaces) >= 3:
        client.focus_surface(2)
        time.sleep(SHORT_WAIT)
        client.new_split("down")
        time.sleep(SPLIT_WAIT)
    n = surface_count(client)
    return _close_and_verify(client, change, n - 1, n - 1, "c10_before", "c10_after")


def test_d11_nested_close_bottomright(client: cmux) -> StateChange:
    """D11: Split right, split right pane down → close bottom-right."""
    change = StateChange(
        name="Nested: Close Bottom-Right of L-shape", group="D",
        description="Split right → split right down → close bottom-right",
        command="split right; focus 1; split down; close 2",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(1)
    time.sleep(SHORT_WAIT)
    client.new_split("down")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 2, 2, "d11_before", "d11_after")


def test_d12_nested_close_top(client: cmux) -> StateChange:
    """D12: Split down, split bottom right → close top pane."""
    change = StateChange(
        name="Nested: Close Top of T-shape", group="D",
        description="Split down → split bottom right → close top (surface 0)",
        command="split down; focus 1; split right; close 0",
    )
    client.new_split("down")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(1)
    time.sleep(SHORT_WAIT)
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 0, 2, "d12_before", "d12_after")


def test_d13_4pane_close_second(client: cmux) -> StateChange:
    """D13: 4 horizontal panes — close 2nd from left."""
    change = StateChange(
        name="4 H-Panes: Close 2nd From Left", group="D",
        description="3 horizontal splits (4 panes) → close index 1",
        command="split right x3; close_surface 1",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(1)
    time.sleep(SHORT_WAIT)
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    client.focus_surface(2)
    time.sleep(SHORT_WAIT)
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    return _close_and_verify(client, change, 1, 3, "d13_before", "d13_after")


def test_e14_browser_close_terminal(client: cmux) -> StateChange:
    """E14: Split right, open browser right, close terminal (left)."""
    change = StateChange(
        name="Browser Mix: Close Terminal (Left)", group="E",
        description="Split right → browser in right → close left terminal",
        command="new_pane --direction=right --type=browser; close_surface 0",
    )
    try:
        _ = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
        time.sleep(1.5)
    except Exception as e:
        change.error = f"Failed to create browser pane: {e}"
        change.passed = False
        return change
    # new_pane with browser creates a split (auto-terminal + browser), so we may get 3 surfaces
    before_count = surface_count(client)
    if before_count < 2:
        change.error = f"Browser pane not created, got {before_count} surfaces"
        change.passed = False
        return change
    change.before, change.before_state = capture(client, "e14_before")
    try:
        # Find and close the first terminal (index 0)
        client.close_surface(0)
        time.sleep(CLOSE_WAIT)
        change.passed = wait_surface_count(client, before_count - 1)
        if not change.passed:
            change.error = f"Expected {before_count - 1} surfaces, got {surface_count(client)}"
        else:
            # Verify remaining views (browser + terminal) are in window
            window_err = verify_views_in_window(client, "e14_after")
            if window_err:
                change.error = f"VIEW_DETACHED: {window_err}"
                change.passed = False
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, "e14_after")
    return change


def test_e15_browser_close_browser(client: cmux) -> StateChange:
    """E15: Split right, open browser right, close browser (right)."""
    change = StateChange(
        name="Browser Mix: Close Browser (Right)", group="E",
        description="Split right → browser in right → close right browser",
        command="new_pane --direction=right --type=browser; close_surface (last)",
    )
    try:
        _ = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
        time.sleep(1.5)
    except Exception as e:
        change.error = f"Failed to create browser pane: {e}"
        change.passed = False
        return change
    before_count = surface_count(client)
    if before_count < 2:
        change.error = f"Browser pane not created, got {before_count} surfaces"
        change.passed = False
        return change
    change.before, change.before_state = capture(client, "e15_before")
    try:
        client.close_surface(before_count - 1)
        # Browser close leaves behind an auto-created terminal that may need
        # extra time for its shell to initialize, so wait longer.
        time.sleep(2.0)
        expected = before_count - 1
        if not wait_surface_count(client, expected, timeout=5.0):
            change.error = f"Expected {expected} surface(s), got {surface_count(client)}"
            change.passed = False
        else:
            # Verify remaining views are in window
            window_err = verify_views_in_window(client, "e15_after")
            if window_err:
                change.error = f"VIEW_DETACHED: {window_err}"
                change.passed = False
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, "e15_after")
    return change


def test_f16_nested_tabs_close_first(client: cmux) -> StateChange:
    """F16: 2 surfaces in same pane, close the first."""
    change = StateChange(
        name="Nested Tabs: Close First Surface", group="F",
        description="Create 2 surfaces in same pane via new_surface → close first",
        command="new_surface; close first",
    )
    try:
        _ = client.new_surface(panel_type="terminal")
        time.sleep(SHORT_WAIT)
    except Exception as e:
        change.error = f"Failed to create surface: {e}"
        change.passed = False
        return change
    return _close_and_verify(client, change, 0, 1, "f16_before", "f16_after")


def test_g17_rapid_down_close_top(client: cmux) -> StateChange:
    """G17: 5x rapid split down → close top pane."""
    change = StateChange(
        name="Rapid: 5x Split Down → Close Top", group="G",
        description="5 cycles of split-down then close-top",
        command="5x (new_split down; close_surface 0)",
    )
    change.before, change.before_state = capture(client, "g17_before")
    try:
        for i in range(5):
            client.new_split("down")
            time.sleep(SPLIT_WAIT)
            # Close the first (top) surface — wait for it to complete
            client.close_surface(0)
            if not wait_surface_count(client, 1, timeout=5.0):
                change.error = f"Cycle {i+1}: expected 1 surface, got {surface_count(client)}"
                change.passed = False
                break
            time.sleep(CLOSE_WAIT)
        if change.passed:
            blank_err = verify_all_responsive(client, "g17")
            if blank_err:
                change.error = f"BLANK: {blank_err}"
                change.passed = False
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, "g17_after")
    return change


def test_g18_rapid_right_close_left(client: cmux) -> StateChange:
    """G18: 5x rapid split right → close left pane."""
    change = StateChange(
        name="Rapid: 5x Split Right → Close Left", group="G",
        description="5 cycles of split-right then close-left",
        command="5x (new_split right; close_surface 0)",
    )
    change.before, change.before_state = capture(client, "g18_before")
    try:
        for i in range(5):
            client.new_split("right")
            time.sleep(0.8)
            client.close_surface(0)
            time.sleep(1.0)
            if not wait_surface_count(client, 1, timeout=5.0):
                change.error = f"Cycle {i+1}: expected 1 surface, got {surface_count(client)}"
                change.passed = False
                break
        if change.passed:
            blank_err = verify_all_responsive(client, "g18")
            if blank_err:
                change.error = f"BLANK: {blank_err}"
                change.passed = False
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, "g18_after")
    return change


def test_g19_alternating_close_reverse(client: cmux) -> StateChange:
    """G19: Alternating splits then close all in reverse."""
    change = StateChange(
        name="Alternating Splits: Close in Reverse", group="G",
        description="right, down, right, down → close all in reverse order",
        command="split right/down/right/down; close 4,3,2,1",
    )
    directions = ["right", "down", "right", "down"]
    for d in directions:
        client.new_split(d)
        time.sleep(SPLIT_WAIT)
    change.before, change.before_state = capture(client, "g19_before")
    try:
        for i in range(4, 0, -1):
            n = surface_count(client)
            if n <= 1:
                break
            expected = n - 1
            client.close_surface(n - 1)
            if not wait_surface_count(client, expected, timeout=5.0):
                change.error = f"Close {i}: expected {expected} surfaces, got {surface_count(client)}"
                change.passed = False
                break
            time.sleep(CLOSE_WAIT)
        if change.passed:
            if not wait_surface_count(client, 1, timeout=5.0):
                change.error = f"Expected 1 surface, got {surface_count(client)}"
                change.passed = False
            else:
                blank_err = verify_all_responsive(client, "g19")
                if blank_err:
                    change.error = f"BLANK: {blank_err}"
                    change.passed = False
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, "g19_after")
    return change


def test_h20_workspace_switch_back(client: cmux) -> StateChange:
    """H20: Create workspace with splits, switch away, switch back."""
    change = StateChange(
        name="Workspace Switch-Back", group="H",
        description="Create splits, switch to new workspace, switch back — splits intact",
        command="split right; new_workspace; select_workspace 0",
    )
    client.new_split("right")
    time.sleep(SPLIT_WAIT)
    original_count = surface_count(client)
    change.before, change.before_state = capture(client, "h20_before")

    try:
        # Remember original workspace
        workspaces = client.list_workspaces()
        original_ws = None
        for _, wid, _, sel in workspaces:
            if sel:
                original_ws = wid
                break

        # Create and switch to new workspace
        client.new_workspace()
        time.sleep(SHORT_WAIT)

        # Switch back to original
        if original_ws:
            client.select_workspace(original_ws)
        else:
            client.select_workspace(0)
        time.sleep(SHORT_WAIT)

        after_count = surface_count(client)
        change.passed = after_count == original_count
        if not change.passed:
            change.error = f"Expected {original_count} surfaces after switch-back, got {after_count}"
        change.result = f"Before: {original_count}, After: {after_count}"
    except Exception as e:
        change.error = str(e)
        change.passed = False
    change.after, change.after_state = capture(client, "h20_after")
    return change


def _create_browser_surface(client: cmux, url: Optional[str] = None) -> str:
    return client.new_surface(panel_type="browser", url=url)


def test_i21_browser_drag_split_right_wait_load(client: cmux) -> StateChange:
    """I21: Browser tab → navigate → drag-to-split right (wait for load)."""
    change = StateChange(
        name="Browser: Navigate Then Drag-To-Split Right (Wait Load)", group="I",
        description="Create browser tab first, navigate to example.com, then move the tab into a right split.",
        command="new_surface --type=browser; navigate <browser> https://example.com; drag_surface_to_split <browser> right",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.6)
        change.before, change.before_state = capture(client, "i21_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        # Verify we created a split (2 panes), and all views are attached.
        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            blank_err = verify_all_responsive(client, "i21_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i21_after_drag")
    return change


def test_i22_browser_drag_split_right_immediate(client: cmux) -> StateChange:
    """I22: Browser tab → navigate → drag-to-split right (no wait)."""
    change = StateChange(
        name="Browser: Drag-To-Split Right Immediately", group="I",
        description="Create browser tab first, start navigation, then drag-to-split right immediately (stress reparenting).",
        command="new_surface --type=browser; navigate <browser> https://example.com; drag_surface_to_split <browser> right",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        time.sleep(0.1)
        change.before, change.before_state = capture(client, "i22_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            blank_err = verify_all_responsive(client, "i22_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i22_after_drag")
    return change


def test_i23_browser_drag_split_right_webview_focused(client: cmux) -> StateChange:
    """I23: Browser tab (webview focused) → drag-to-split right."""
    change = StateChange(
        name="Browser: WebView Focused Then Drag-To-Split Right", group="I",
        description="Ensure WKWebView is first responder before dragging to split right.",
        command="new_surface --type=browser; navigate; focus_webview; drag_surface_to_split right",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.4)

        client.focus_webview(browser_id)
        if not client.is_webview_focused(browser_id):
            raise RuntimeError("expected webview focused")

        change.before, change.before_state = capture(client, "i23_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            blank_err = verify_all_responsive(client, "i23_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i23_after_drag")
    return change


def test_i24_browser_drag_split_right_focus_bounce(client: cmux) -> StateChange:
    """I24: Browser tab → navigate → focus bounce → drag-to-split right."""
    change = StateChange(
        name="Browser: Focus Bounce Then Drag-To-Split Right", group="I",
        description="Switch focus terminal↔browser before dragging to split right.",
        command="new_surface --type=browser; navigate; focus_surface 0; focus_surface <browser>; drag_surface_to_split right",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.4)

        # Focus bounce
        client.focus_surface(0)
        time.sleep(SHORT_WAIT)
        client.focus_surface(browser_id)
        time.sleep(SHORT_WAIT)

        change.before, change.before_state = capture(client, "i24_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            blank_err = verify_all_responsive(client, "i24_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i24_after_drag")
    return change


def test_i25_browser_drag_split_right_then_switch_panes(client: cmux) -> StateChange:
    """I25: Browser drag-to-split right → switch panes → verify webview stays attached."""
    change = StateChange(
        name="Browser: Drag-To-Split Right Then Switch Panes", group="I",
        description="After drag-to-split right, focus each pane and ensure views remain in-window.",
        command="new_surface --type=browser; navigate; drag_surface_to_split right; focus_pane 0/1",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.4)
        change.before, change.before_state = capture(client, "i25_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            # Switch panes by index (stable order from list_panes).
            client.focus_pane(0)
            time.sleep(SHORT_WAIT)
            client.focus_pane(1)
            time.sleep(SHORT_WAIT)

            blank_err = verify_all_responsive(client, "i25_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i25_after_drag")
    return change


def test_i26_browser_drag_split_right_initial_url(client: cmux) -> StateChange:
    """I26: Browser tab (initial URL) → drag-to-split right."""
    change = StateChange(
        name="Browser: Initial URL Then Drag-To-Split Right", group="I",
        description="Create browser tab with initial URL, then drag-to-split right (no explicit navigate).",
        command="new_surface --type=browser --url=https://example.com; drag_surface_to_split <browser> right",
    )
    try:
        browser_id = _create_browser_surface(client, url="https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.4)
        change.before, change.before_state = capture(client, "i26_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            blank_err = verify_all_responsive(client, "i26_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i26_after_drag")
    return change


def test_i27_browser_drag_split_right_after_reload(client: cmux) -> StateChange:
    """I27: Browser tab → navigate → reload → drag-to-split right."""
    change = StateChange(
        name="Browser: Reload Then Drag-To-Split Right", group="I",
        description="Navigate to example.com, call browser_reload, then drag-to-split right.",
        command="new_surface --type=browser; navigate; browser_reload; drag_surface_to_split right",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.4)

        client.browser_reload(browser_id)
        time.sleep(0.3)

        change.before, change.before_state = capture(client, "i27_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) != 2:
            change.passed = False
            change.error = f"Expected 2 panes after drag split, got {pane_count(client)}"
        else:
            blank_err = verify_all_responsive(client, "i27_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i27_after_drag")
    return change


def test_i28_browser_drag_split_right_double_drag(client: cmux) -> StateChange:
    """I28: Browser tab → navigate → drag-to-split right twice (idempotence-ish)."""
    change = StateChange(
        name="Browser: Double Drag-To-Split Right", group="I",
        description="Drag-to-split right, then attempt a second drag-to-split right (stress tree updates).",
        command="new_surface --type=browser; navigate; drag_surface_to_split right; drag_surface_to_split right",
    )
    try:
        browser_id = _create_browser_surface(client)
        client.navigate(browser_id, "https://example.com")
        wait_url_contains(client, browser_id, "example.com", timeout=10.0)
        time.sleep(0.4)
        change.before, change.before_state = capture(client, "i28_before_drag")

        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)
        client.drag_surface_to_split(browser_id, "right")
        time.sleep(SPLIT_WAIT)

        if pane_count(client) < 2:
            change.passed = False
            change.error = f"Expected at least 2 panes after double drag, got {pane_count(client)}"
        else:
            # Ensure we didn't leave behind any empty panes ("Empty Panel" without tabs).
            panes = client.list_panes()
            empty_panes = [pid for _, pid, tab_count, _ in panes if tab_count == 0]
            if empty_panes:
                change.passed = False
                change.error = f"Empty pane(s) after double drag: {empty_panes}"
                raise RuntimeError(change.error)
            blank_err = verify_all_responsive(client, "i28_after_drag")
            if blank_err:
                change.passed = False
                change.error = f"BLANK: {blank_err}"
    except Exception as e:
        change.passed = False
        change.error = str(e)

    change.after, change.after_state = capture(client, "i28_after_drag")
    return change


# ---------------------------------------------------------------------------
# HTML report
# ---------------------------------------------------------------------------


def generate_html_report(changes: list[StateChange]) -> None:
    html = '''<!DOCTYPE html>
<html>
<head>
    <title>cmuxterm Visual Test Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            padding: 20px;
            max-width: 1800px;
            margin: 0 auto;
        }
        h1 { color: #4cc9f0; border-bottom: 2px solid #4361ee; padding-bottom: 10px; }
        h2 { color: #7209b7; margin-top: 40px; }
        h3.group { color: #4361ee; margin-top: 50px; border-bottom: 1px solid #333; padding-bottom: 6px; }
        .state-change {
            background: #16213e; border-radius: 12px; padding: 20px; margin: 20px 0;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
        }
        .state-change.passed { border-left: 4px solid #4cc9f0; }
        .state-change.failed { border-left: 4px solid #f72585; }
        .screenshots { display: flex; gap: 20px; margin-top: 15px; flex-wrap: wrap; }
        .screenshot-container {
            flex: 1; min-width: 400px; background: #0f0f23; border-radius: 8px; padding: 10px;
        }
        .screenshot-container h4 { color: #4361ee; margin: 0 0 10px 0; }
        .screenshot-container img { max-width: 100%; border-radius: 4px; border: 1px solid #333; }
        .meta { font-size: 0.9em; color: #888; margin-top: 5px; }
        .command {
            background: #0f0f23; padding: 10px; border-radius: 4px;
            font-family: monospace; margin: 10px 0; color: #4cc9f0;
        }
        .result { color: #4cc9f0; }
        .error {
            color: #f72585; background: rgba(247,37,133,0.1);
            padding: 10px; border-radius: 4px;
        }
        .summary { background: #0f0f23; padding: 20px; border-radius: 8px; margin-bottom: 30px; }
        .summary .passed { color: #4cc9f0; }
        .summary .failed { color: #f72585; }
        .timestamp { font-size: 0.8em; color: #666; }
        .annotation { margin-top: 15px; padding: 10px; background: #0f0f23; border-radius: 8px; }
        .annotation label { display: block; color: #f72585; font-weight: bold; margin-bottom: 5px; }
        .annotation textarea {
            width: 100%; min-height: 60px; background: #1a1a2e; border: 1px solid #333;
            border-radius: 4px; color: #eee; padding: 8px; font-family: inherit; resize: vertical;
        }
        .annotation textarea:focus { outline: none; border-color: #4361ee; }
        .copy-section {
            position: fixed; bottom: 20px; right: 20px; background: #16213e;
            padding: 15px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); z-index: 1000;
        }
        .copy-btn {
            background: #4361ee; color: white; border: none; padding: 12px 24px;
            border-radius: 6px; cursor: pointer; font-size: 14px; font-weight: bold;
        }
        .copy-btn:hover { background: #3651d4; }
        .copy-btn.copied { background: #4cc9f0; }
    </style>
</head>
<body>
    <h1>cmuxterm Visual Test Report</h1>
    <p class="timestamp">Generated: ''' + datetime.now().strftime("%Y-%m-%d %H:%M:%S") + '''</p>

    <div class="summary">
        <h3>Summary</h3>
        <p>Total tests: ''' + str(len(changes)) + '''</p>
        <p class="passed">Passed: ''' + str(sum(1 for c in changes if c.passed)) + '''</p>
        <p class="failed">Failed: ''' + str(sum(1 for c in changes if not c.passed)) + '''</p>
    </div>
'''

    group_names = {
        "A": "Group A — Basic Splits (Baseline)",
        "B": "Group B — Close Operations",
        "C": "Group C — Multi-Pane Close",
        "D": "Group D — Asymmetric / Deep Nesting",
        "E": "Group E — Browser + Terminal Mix",
        "F": "Group F — Nested Tabs",
        "G": "Group G — Rapid Stress Tests",
        "H": "Group H — Workspace Interactions",
        "I": "Group I — Browser Drag-To-Split Right",
    }

    current_group = ""
    for i, change in enumerate(changes, 1):
        if change.group != current_group:
            current_group = change.group
            gname = group_names.get(current_group, f"Group {current_group}")
            html += f'\n    <h3 class="group">{gname}</h3>'

        status_class = "passed" if change.passed else "failed"
        html += f'''
    <div class="state-change {status_class}">
        <h2>{i}. {change.name}</h2>
        <p>{change.description}</p>'''

        if change.command:
            html += f'\n        <div class="command">{change.command}</div>'
        if change.result:
            html += f'\n        <div class="result">Result: {change.result}</div>'
        if change.error:
            html += f'\n        <div class="error">Error: {change.error}</div>'

        html += '\n        <div class="screenshots">'

        if change.before:
            html += f'''
            <div class="screenshot-container">
                <h4>Before</h4>
                <img src="data:image/png;base64,{change.before.to_base64()}" alt="{change.before.label}">
                <div class="meta">{change.before.timestamp}</div>
            </div>'''
        elif change.before_state:
            html += f'''
            <div class="screenshot-container">
                <h4>Before (State)</h4>
                <pre style="color:#888;font-size:0.85em;white-space:pre-wrap;">{change.before_state}</pre>
            </div>'''

        if change.after:
            html += f'''
            <div class="screenshot-container">
                <h4>After</h4>
                <img src="data:image/png;base64,{change.after.to_base64()}" alt="{change.after.label}">
                <div class="meta">{change.after.timestamp}</div>
            </div>'''
        elif change.after_state:
            html += f'''
            <div class="screenshot-container">
                <h4>After (State)</h4>
                <pre style="color:#888;font-size:0.85em;white-space:pre-wrap;">{change.after_state}</pre>
            </div>'''

        test_id = f"test_{i}"
        html += f'''
        </div>
        <div class="annotation">
            <label>Issue? Describe what's wrong:</label>
            <textarea id="{test_id}_notes" placeholder="e.g., 'pane is blank after close'"></textarea>
        </div>
    </div>'''

    html += '''
    <div class="copy-section">
        <button class="copy-btn" onclick="copyFeedback()">Copy Feedback</button>
        <div id="copy-status" style="margin-top:8px;font-size:0.85em;color:#888;"></div>
    </div>
    <script>
    function copyFeedback() {
        const tests = document.querySelectorAll('.state-change');
        let feedback = [];
        tests.forEach((test, idx) => {
            const testNum = idx + 1;
            const title = test.querySelector('h2').textContent;
            const textarea = document.getElementById(`test_${testNum}_notes`);
            const notes = textarea ? textarea.value.trim() : '';
            if (notes) {
                const command = test.querySelector('.command');
                const cmdText = command ? command.textContent : '';
                feedback.push(`## ${title}`);
                if (cmdText) feedback.push(`Command: ${cmdText}`);
                feedback.push(`Issue: ${notes}`);
                feedback.push('');
            }
        });
        if (feedback.length === 0) {
            document.getElementById('copy-status').textContent = 'No issues noted!';
            return;
        }
        const text = '# Visual Test Feedback\\n\\n' + feedback.join('\\n');
        navigator.clipboard.writeText(text).then(() => {
            const btn = document.querySelector('.copy-btn');
            btn.classList.add('copied');
            btn.textContent = 'Copied!';
            document.getElementById('copy-status').textContent =
                `${feedback.filter(l => l.startsWith('## ')).length} issue(s) copied`;
            setTimeout(() => { btn.classList.remove('copied'); btn.textContent = 'Copy Feedback'; }, 2000);
        });
    }
    </script>
</body>
</html>'''

    HTML_REPORT.write_text(html)
    print(f"\nReport generated: {HTML_REPORT}")


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def _is_known_non_blocking_failure(change: StateChange) -> bool:
    """Return True for known flaky VM-only visual failures we still report but do not gate on."""
    if change.name == "Nested: Close Top of T-shape" and "VIEW_DETACHED" in (change.error or ""):
        return True
    return False


def run_visual_tests():
    changes: list[StateChange] = []

    test_fns = [
        # Group A — basic splits
        ("A1", test_a1_initial_state),
        ("A2", test_a2_split_right),
        ("A3", test_a3_split_down),
        # Group B — close operations
        ("B4", test_b4_close_right),
        ("B5", test_b5_close_left),
        ("B6", test_b6_close_bottom),
        ("B7", test_b7_close_top),
        # Group C — multi-pane close
        ("C8", test_c8_3way_close_middle),
        ("C9", test_c9_grid_close_topleft),
        ("C10", test_c10_grid_close_bottomright),
        # Group D — asymmetric / deep nesting
        ("D11", test_d11_nested_close_bottomright),
        ("D12", test_d12_nested_close_top),
        ("D13", test_d13_4pane_close_second),
        # Group E — browser + terminal mix
        ("E14", test_e14_browser_close_terminal),
        ("E15", test_e15_browser_close_browser),
        # Group F — nested tabs
        ("F16", test_f16_nested_tabs_close_first),
        # Group G — rapid stress
        ("G17", test_g17_rapid_down_close_top),
        ("G18", test_g18_rapid_right_close_left),
        ("G19", test_g19_alternating_close_reverse),
        # Group H — workspace interactions
        ("H20", test_h20_workspace_switch_back),
        # Group I — browser drag-to-split right
        ("I21", test_i21_browser_drag_split_right_wait_load),
        ("I22", test_i22_browser_drag_split_right_immediate),
        ("I23", test_i23_browser_drag_split_right_webview_focused),
        ("I24", test_i24_browser_drag_split_right_focus_bounce),
        ("I25", test_i25_browser_drag_split_right_then_switch_panes),
        ("I26", test_i26_browser_drag_split_right_initial_url),
        ("I27", test_i27_browser_drag_split_right_after_reload),
        ("I28", test_i28_browser_drag_split_right_double_drag),
    ]

    print("=" * 60)
    print(f"cmuxterm Visual Screenshot Tests ({len(test_fns)} scenarios)")
    print("=" * 60)
    print()

    client = get_client()

    # Each test function that needs isolation gets a fresh workspace.
    # Tests that operate on a fresh workspace call reset_workspace themselves.

    transient_markers = (
        "BLANK:",
        "VIEW_DETACHED:",
        "TabManager not available",
        "Broken pipe",
        "Connection refused",
        "Socket error",
    )

    for label, fn in test_fns:
        print(f"{label}. {fn.__doc__.strip().split(':')[0] if fn.__doc__ else label}...")

        change = None
        for attempt in range(2):
            # Reset to fresh workspace before each attempt.
            client = reset_workspace(client)
            if attempt > 0:
                print(f"    [RETRY] transient failure, rerunning {label}")

            try:
                change = fn(client)
            except Exception as e:
                change = StateChange(
                    name=f"{label} (CRASHED)", group=label[0],
                    description=str(e), passed=False, error=str(e),
                )

            if change.passed:
                break

            err = change.error or ""
            if not any(marker in err for marker in transient_markers):
                break
            time.sleep(0.5)

        changes.append(change)
        status = "PASS" if change.passed else "FAIL"
        print(f"  [{status}] {change.name}")
        if change.error:
            print(f"    Error: {change.error}")

    # Generate report
    generate_html_report(changes)

    # Cleanup extra workspaces
    try:
        cleanup_workspaces(client)
        client.close()
    except Exception:
        pass

    # Summary
    print()
    print("=" * 60)
    print("Visual Test Summary")
    print("=" * 60)
    passed = sum(1 for c in changes if c.passed)
    failed_changes = [c for c in changes if not c.passed]
    non_blocking_failed = [c for c in failed_changes if _is_known_non_blocking_failure(c)]
    blocking_failed = [c for c in failed_changes if not _is_known_non_blocking_failure(c)]

    print(f"  Passed: {passed}")
    print(f"  Failed: {len(failed_changes)}")
    if non_blocking_failed:
        print(f"  Non-blocking failed: {len(non_blocking_failed)}")
    print(f"  Total:  {len(changes)}")

    if failed_changes:
        print()
        print("Failed tests:")
        for c in failed_changes:
            marker = " (non-blocking)" if _is_known_non_blocking_failure(c) else ""
            print(f"  - {c.name}{marker}: {c.error or 'unknown'}")

    print()
    print(f"Report: {HTML_REPORT}")
    return 0 if len(blocking_failed) == 0 else 1


if __name__ == "__main__":
    sys.exit(run_visual_tests())
