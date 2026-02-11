#!/usr/bin/env python3
"""
Regression tests for Bonsplit surface (tab) selection behavior when closing surfaces.

Desired behavior:
- When closing the currently focused surface at index i (and another surface exists at index i),
  keep the focused index stable by focusing the surface that moves into index i (the "next" one).
- When closing the last focused surface, focus the previous surface.

Usage:
    python3 tests/test_close_surface_selection.py
"""

import os
import sys
import time
from typing import List, Optional, Tuple

# Add the directory containing cmux.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


SurfaceTuple = Tuple[int, str, bool]  # (index, id, is_focused)


def _focused(surfaces: List[SurfaceTuple]) -> Optional[SurfaceTuple]:
    return next((s for s in surfaces if s[2]), None)


def _wait_focused_index(client: cmux, index: int, timeout: float = 4.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        surfaces = client.list_surfaces()
        focused = _focused(surfaces)
        if focused is not None and focused[0] == index:
            return True
        time.sleep(0.05)
    return False


def _ensure_surfaces(client: cmux, count: int) -> None:
    surfaces = client.list_surfaces()
    while len(surfaces) < count:
        client.new_surface(panel_type="terminal")
        time.sleep(0.15)
        surfaces = client.list_surfaces()


def test_close_middle_keeps_index(client: cmux) -> TestResult:
    result = TestResult("Close Focused Middle Surface Keeps Index")
    try:
        # Isolate from developer state: use a fresh workspace.
        ws_id = client.new_workspace()
        client.select_workspace(ws_id)
        time.sleep(0.25)
        client.activate_app()
        time.sleep(0.15)

        _ensure_surfaces(client, 3)

        # Focus index 1.
        client.focus_surface(1)
        if not _wait_focused_index(client, 1, timeout=4.0):
            result.failure("Failed to focus surface index 1")
            return result

        before = client.list_surfaces()
        if len(before) < 3:
            result.failure(f"Expected >= 3 surfaces, got {len(before)}")
            return result
        expected_next_id = before[2][1]

        client.close_surface()  # closes focused surface
        time.sleep(0.25)

        after = client.list_surfaces()
        focused = _focused(after)
        if focused is None:
            result.failure("No focused surface after close")
            return result
        if focused[1] != expected_next_id:
            result.failure(f"Expected focus to move to next surface id={expected_next_id}, got id={focused[1]}")
            return result
        if focused[0] != 1:
            result.failure(f"Expected focused index to remain 1, got {focused[0]}")
            return result

        result.success("Focused index stayed stable (selected the surface that moved into the closed slot)")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_close_last_selects_previous(client: cmux) -> TestResult:
    result = TestResult("Close Focused Last Surface Selects Previous")
    try:
        ws_id = client.new_workspace()
        client.select_workspace(ws_id)
        time.sleep(0.25)
        client.activate_app()
        time.sleep(0.15)

        _ensure_surfaces(client, 3)

        before = client.list_surfaces()
        last_index = len(before) - 1
        expected_prev_id = before[last_index - 1][1]

        client.focus_surface(last_index)
        if not _wait_focused_index(client, last_index, timeout=4.0):
            result.failure(f"Failed to focus surface index {last_index}")
            return result

        client.close_surface()
        time.sleep(0.25)

        after = client.list_surfaces()
        focused = _focused(after)
        if focused is None:
            result.failure("No focused surface after close")
            return result
        if focused[1] != expected_prev_id:
            result.failure(f"Expected focus to move to previous surface id={expected_prev_id}, got id={focused[1]}")
            return result

        result.success("Focused moved to previous when closing the last surface")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def run_tests() -> int:
    results = []
    with cmux() as client:
        results.append(test_close_middle_keeps_index(client))
        results.append(test_close_last_selects_previous(client))

    print("\nClose Surface Selection Tests:")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        msg = f" - {r.message}" if r.message else ""
        print(f"{status}: {r.name}{msg}")

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    if passed == total:
        print("\nAll close surface selection tests passed!")
        return 0
    print(f"\n{total - passed} test(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(run_tests())
