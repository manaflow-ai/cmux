#!/usr/bin/env python3
"""Regression: Ctrl+Cmd+1…9 focuses a pane by its spatial number (cx-zjtn.5).

cmux-next jumps straight to pane N with Ctrl+Cmd+N; classic could only cycle
or move one pane at a time. Panes number in the same spatial order that
Focus Next Pane walks, and 9 always picks the last pane, as Cmd+9 does for
workspaces.

Run against a TAGGED build only (never the user's default socket):
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_focus_pane_by_number.py

simulate_shortcut routes through AppDelegate.debugHandleCustomShortcut, the
same matcher and dispatch order as real keystrokes from the app-level monitor.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _panes(c: cmux) -> list:
    # The socket rate-limits tight polling; back off and retry.
    for _ in range(20):
        try:
            return c.list_panes()
        except cmuxError as error:
            if "rate_limited" not in str(error):
                raise
            time.sleep(0.3)
    return c.list_panes()


def _pane_ids(c: cmux) -> list:
    return [pid for _i, pid, _n, _f in _panes(c)]


def _focused(c: cmux) -> str:
    for _i, pid, _n, focused in _panes(c):
        if focused:
            return pid
    return ""


def _split_new_pane(c: cmux, direction: str) -> str:
    before = set(_pane_ids(c))
    c.new_split(direction)
    deadline = time.time() + 5.0
    while time.time() < deadline:
        added = [pid for pid in _pane_ids(c) if pid not in before]
        if added:
            return added[0]
        time.sleep(0.3)
    raise cmuxError(f"split {direction} made no pane")


def _press(c: cmux, combo: str, expected: str, timeout: float = 3.0) -> str:
    c.simulate_shortcut(combo)
    deadline = time.time() + timeout
    current = _focused(c)
    while time.time() < deadline:
        current = _focused(c)
        if current == expected:
            break
        time.sleep(0.3)
    return current


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    time.sleep(0.3)

    workspace = c.new_workspace()
    c.select_workspace(workspace)
    time.sleep(0.5)

    # Layout: left | (top-right / bottom-right); spatial order left, top, bottom.
    left = _pane_ids(c)[0]
    top_right = _split_new_pane(c, "right")
    c.focus_pane(top_right)
    bottom_right = _split_new_pane(c, "down")
    c.focus_pane(left)
    time.sleep(0.3)

    cases = [
        ("ctrl+cmd+3", bottom_right, "3 focuses the third pane"),
        ("ctrl+cmd+2", top_right, "2 focuses the second pane"),
        ("ctrl+cmd+1", left, "1 focuses the first pane"),
        ("ctrl+cmd+9", bottom_right, "9 focuses the last pane"),
    ]
    failures = 0
    for combo, expected, name in cases:
        got = _press(c, combo, expected)
        ok = got == expected
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}: {combo} -> {got} (want {expected})")

    c.close_workspace(workspace)
    print(f"RESULT {len(cases) - failures}/{len(cases)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
