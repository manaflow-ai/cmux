#!/usr/bin/env python3
"""
Regression test: CA layer detachment for inactive terminals.

When switching workspaces, inactive terminals' GhosttySurfaceScrollView is
removed from the view hierarchy to eliminate CA layer commit traversal cost.
This test verifies:
  1) Background workspace terminals remain responsive after switching back
  2) Newly created background workspace terminals start their PTY immediately
  3) No blank screen or focus loss after multiple workspace switch cycles
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
    return MARKER_DIR / f"cmux_cald_{name}_{os.getpid()}"


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


def test_switch_back_responsive(c: cmux) -> None:
    """
    Create workspace A, create workspace B (A goes background -> detached).
    Switch back to A. Verify terminal is responsive after reattach.
    """
    ws_a = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    # Create workspace B — workspace A's terminal gets detached from CA layer tree
    ws_b = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    # Switch back to workspace A — terminal must reattach and be responsive
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    m = _marker("switch_back")
    try:
        assert _verify_responsive(c, m, 0), \
            "Workspace A terminal not responsive after CA layer reattach"
    finally:
        _clear(m)

    # Cleanup
    c.close_workspace(ws_b)
    time.sleep(0.2)
    c.close_workspace(ws_a)
    time.sleep(0.2)


def test_background_created_terminal_starts(c: cmux) -> None:
    """
    Create workspace A (active), then create workspace B while A stays active.
    Switch to B. Verify terminal is responsive immediately (PTY started during
    bootstrap attach even though B was created in the background).
    """
    ws_a = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    # Create workspace B while A is active — B's terminal bootstraps and detaches
    ws_b = c.new_workspace()
    time.sleep(0.5)

    # B is now active — its terminal should already have a running PTY
    _wait_terminal_in_window(c, 0, timeout=5.0)

    m = _marker("bg_created")
    try:
        assert _verify_responsive(c, m, 0), \
            "Background-created terminal not responsive (PTY bootstrap failed)"
    finally:
        _clear(m)

    # Cleanup
    c.close_workspace(ws_b)
    time.sleep(0.2)
    c.close_workspace(ws_a)
    time.sleep(0.2)


def test_multi_cycle_no_blank(c: cmux) -> None:
    """
    Create 3 workspaces. Cycle through them (A->B->C->A->B->C). After each
    cycle, verify terminals are responsive and in_window for the active
    workspace. Ensures repeated detach/reattach cycles don't strand views.
    """
    ws_a = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    ws_b = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    ws_c = c.new_workspace()
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    workspaces = [ws_a, ws_b, ws_c]
    labels = ["A", "B", "C"]

    # Two full cycles: A->B->C->A->B->C
    for cycle in range(2):
        for i, ws in enumerate(workspaces):
            c.select_workspace(ws)
            time.sleep(0.5)
            assert _wait_terminal_in_window(c, 0, timeout=5.0), \
                f"Cycle {cycle+1} workspace {labels[i]}: terminal not in_window after switch"

    # Final check: settle on A and verify responsive
    c.select_workspace(ws_a)
    time.sleep(0.5)
    _wait_terminal_in_window(c, 0, timeout=5.0)

    m = _marker("multi_cycle")
    try:
        assert _verify_responsive(c, m, 0), \
            "Terminal not responsive after 2 full workspace cycles"
    finally:
        _clear(m)

    # Cleanup
    for ws in reversed(workspaces):
        c.close_workspace(ws)
        time.sleep(0.2)


def main() -> int:
    print("=" * 60)
    print("CA Layer Detach Regression Tests")
    print("=" * 60)
    print()

    tests = [
        ("Switch back responsive after detach", test_switch_back_responsive),
        ("Background-created terminal starts PTY", test_background_created_terminal_starts),
        ("Multi-cycle no blank (3 workspaces)", test_multi_cycle_no_blank),
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
        print("\nPASS: CA layer detach")
        return 0
    else:
        print(f"\nFAIL: {failed} test(s) failed")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
