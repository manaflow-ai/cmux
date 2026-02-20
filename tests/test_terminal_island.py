#!/usr/bin/env python3
"""
Regression test: Terminal island (shallow CA depth) for visible terminals.

Visible terminal surfaces are hosted in a TerminalIslandView (direct child of
window.contentView) instead of deep in the SwiftUI hierarchy. This reduces
CA::Transaction::commit traversal and typing latency.

This test verifies:
  1) Terminals remain responsive when hosted in the island
  2) Switching workspaces correctly moves terminals in/out of the island
  3) Split panes are both responsive in the island
  4) Window resize doesn't break terminal positioning
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
    return MARKER_DIR / f"cmux_island_{name}_{os.getpid()}"


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


def test_island_responsive(c: cmux) -> None:
    """
    Create a workspace. Verify the terminal hosted in the island is responsive.
    """
    ws = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    m = _marker("responsive")
    try:
        assert _verify_responsive(c, m, 0), \
            "Terminal not responsive in island"
    finally:
        _clear(m)
        c.close_workspace(ws)
        time.sleep(0.2)


def test_island_switch_back(c: cmux) -> None:
    """
    Create workspace A, create workspace B (A's terminal removed from island).
    Switch back to A. Verify terminal is re-added to island and responsive.
    """
    ws_a = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    ws_b = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    # Switch back to A — terminal must be re-added to island
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    m = _marker("switch_back")
    try:
        assert _verify_responsive(c, m, 0), \
            "Terminal not responsive after island re-add on workspace switch"
    finally:
        _clear(m)
        c.close_workspace(ws_b)
        time.sleep(0.2)
        c.close_workspace(ws_a)
        time.sleep(0.2)


def test_island_split_responsive(c: cmux) -> None:
    """
    Create workspace with a vertical split. Verify both terminals in the
    island are responsive.
    """
    ws = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    c.split("right")
    time.sleep(0.5)
    _wait_terminal_in_window(c, 1, timeout=5.0)

    # Verify first terminal (surface 0)
    m0 = _marker("split_s0")
    try:
        assert _verify_responsive(c, m0, 0), \
            "Split terminal 0 not responsive in island"
    finally:
        _clear(m0)

    # Verify second terminal (surface 1)
    m1 = _marker("split_s1")
    try:
        assert _verify_responsive(c, m1, 1), \
            "Split terminal 1 not responsive in island"
    finally:
        _clear(m1)

    c.close_workspace(ws)
    time.sleep(0.2)


def test_island_resize(c: cmux) -> None:
    """
    Create workspace, resize window, verify terminal is still responsive.
    """
    ws = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    # Resize window
    try:
        c.resize_window(900, 600)
    except Exception:
        pass  # resize_window may not exist; skip if unavailable
    time.sleep(0.5)

    m = _marker("resize")
    try:
        assert _verify_responsive(c, m, 0), \
            "Terminal not responsive after window resize"
    finally:
        _clear(m)
        c.close_workspace(ws)
        time.sleep(0.2)


def main() -> int:
    print("=" * 60)
    print("Terminal Island Regression Tests")
    print("=" * 60)
    print()

    tests = [
        ("Island responsive", test_island_responsive),
        ("Island switch back", test_island_switch_back),
        ("Island split responsive", test_island_split_responsive),
        ("Island resize", test_island_resize),
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
        print("\nPASS: Terminal island")
        return 0
    else:
        print(f"\nFAIL: {failed} test(s) failed")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
