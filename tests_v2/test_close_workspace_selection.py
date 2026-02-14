#!/usr/bin/env python3
"""
Regression tests for workspace selection behavior when closing workspaces.

Desired behavior:
- When closing the currently selected workspace, keep the focused *index* stable when possible.
  That means: prefer selecting the workspace that ends up at the same index (the one below),
  and only fall back to selecting the previous workspace when the closed workspace was last.

Usage:
    python3 tests/test_close_workspace_selection.py
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


WorkspaceTuple = Tuple[int, str, str, bool]  # (index, id, title, selected)


def _selected(workspaces: List[WorkspaceTuple]) -> Optional[WorkspaceTuple]:
    return next((w for w in workspaces if w[3]), None)


def _by_index(workspaces: List[WorkspaceTuple], index: int) -> Optional[WorkspaceTuple]:
    return next((w for w in workspaces if w[0] == index), None)


def _ensure_workspaces(client: cmux, count: int) -> List[str]:
    """
    Ensure at least `count` workspaces exist. Returns IDs of newly created workspaces.
    """
    created: List[str] = []
    ws = client.list_workspaces()
    while len(ws) < count:
        created.append(client.new_workspace())
        time.sleep(0.1)
        ws = client.list_workspaces()
    return created


def test_close_middle_selects_next(client: cmux) -> TestResult:
    result = TestResult("Close Selected Middle Workspace Selects Next")
    try:
        _ensure_workspaces(client, 3)

        client.select_workspace(1)
        time.sleep(0.15)

        before = client.list_workspaces()
        sel = _selected(before)
        below = _by_index(before, 2)
        if sel is None:
            result.failure("No selected workspace after selecting index 1")
            return result
        if sel[0] != 1:
            result.failure(f"Expected selected index 1, got {sel[0]}")
            return result
        if below is None:
            result.failure("Expected a workspace at index 2 for the test")
            return result

        client.close_workspace(sel[1])
        time.sleep(0.2)

        after = client.list_workspaces()
        sel_after = _selected(after)
        if sel_after is None:
            result.failure("No selected workspace after closing selected workspace")
            return result
        if sel_after[1] != below[1]:
            result.failure(f"Expected selection to move to next workspace (below). Expected {below[1]}, got {sel_after[1]}")
            return result
        if sel_after[0] != 1:
            result.failure(f"Expected focused index to remain 1, got {sel_after[0]}")
            return result

        result.success("Selection moved to the workspace below (same index after removal)")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_close_last_selects_previous(client: cmux) -> TestResult:
    result = TestResult("Close Selected Last Workspace Selects Previous")
    try:
        _ensure_workspaces(client, 3)

        before = client.list_workspaces()
        if len(before) < 2:
            result.failure("Expected at least 2 workspaces")
            return result

        last_index = len(before) - 1
        client.select_workspace(last_index)
        time.sleep(0.15)

        before = client.list_workspaces()
        sel = _selected(before)
        above = _by_index(before, last_index - 1)
        if sel is None:
            result.failure("No selected workspace after selecting last index")
            return result
        if sel[0] != last_index:
            result.failure(f"Expected selected index {last_index}, got {sel[0]}")
            return result
        if above is None:
            result.failure(f"Expected a workspace at index {last_index - 1} for the test")
            return result

        client.close_workspace(sel[1])
        time.sleep(0.2)

        after = client.list_workspaces()
        sel_after = _selected(after)
        if sel_after is None:
            result.failure("No selected workspace after closing last selected workspace")
            return result
        if sel_after[1] != above[1]:
            result.failure(f"Expected selection to move to previous workspace (above). Expected {above[1]}, got {sel_after[1]}")
            return result

        result.success("Selection moved to the previous workspace when closing the last")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def run_tests() -> int:
    results = []
    with cmux() as client:
        results.append(test_close_middle_selects_next(client))
        results.append(test_close_last_selects_previous(client))

    print("\nClose Workspace Selection Tests:")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        msg = f" - {r.message}" if r.message else ""
        print(f"{status}: {r.name}{msg}")

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    if passed == total:
        print("\nAll close workspace selection tests passed!")
        return 0
    print(f"\n{total - passed} test(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(run_tests())

