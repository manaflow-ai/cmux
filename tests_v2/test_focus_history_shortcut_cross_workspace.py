#!/usr/bin/env python3
"""Regression: Cmd+[ / Cmd+] traverse the GLOBAL workspace focus history.

Ghostty's macOS defaults bind goto_split:previous/next to cmd+[ / cmd+], the
same keys as cmux's Focus Back/Forward defaults. The app-level dispatch mirrors
those Ghostty triggers to cycle pane focus and used to run that mirror BEFORE
the focus-history branch, so cmd+[ / cmd+] cycled panes within the current
workspace (or did nothing) while the titlebar arrow buttons navigated across
workspaces. The mirror must yield the keys to a bound Focus Back/Forward
shortcut.

Run against a TAGGED build only (never the user's default socket):
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_focus_history_shortcut_cross_workspace.py

simulate_shortcut routes through AppDelegate.debugHandleCustomShortcut, the
same matcher and dispatch order as real keystrokes from the app-level monitor.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _selected_workspace(c: cmux) -> str:
    for _idx, wsid, _title, selected in c.list_workspaces():
        if selected:
            return wsid
    raise cmuxError("no selected workspace")


def _press_and_wait(c: cmux, combo: str, expected_ws: str, timeout: float = 5.0) -> str:
    c.simulate_shortcut(combo)
    deadline = time.time() + timeout
    current = _selected_workspace(c)
    while time.time() < deadline:
        current = _selected_workspace(c)
        if current == expected_ws:
            return current
        time.sleep(0.1)
    return current


def _wait_selected(c: cmux, wsid: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _selected_workspace(c) == wsid:
            return
        time.sleep(0.1)
    raise cmuxError(f"workspace {wsid} never became selected")


def _wait_closed(c: cmux, wsid: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if all(listed != wsid for _i, listed, _t, _s in c.list_workspaces()):
            return
        time.sleep(0.1)
    raise cmuxError(f"workspace {wsid} still listed after close")


def main() -> int:
    c = cmux()
    c.connect()
    _must(c.ping(), "socket ping failed")
    c.activate_app()
    time.sleep(0.3)

    created = []
    for index in range(3):
        wsid = c.new_workspace()
        c.select_workspace(wsid)
        c.rename_workspace(f"fhist-ws{index + 1}", wsid)
        created.append(wsid)
        _wait_selected(c, wsid)

    # Visit ws1 -> ws2 -> ws3 so the focus-history stack is deterministic.
    for wsid in created:
        c.select_workspace(wsid)
        _wait_selected(c, wsid)
    _must(_selected_workspace(c) == created[2], "expected focus on ws3 before navigating")

    # Back across workspaces: ws3 -> ws2 -> ws1.
    got = _press_and_wait(c, "cmd+[", created[1])
    _must(got == created[1], f"cmd+[ should land on ws2, got {got}")
    got = _press_and_wait(c, "cmd+[", created[0])
    _must(got == created[0], f"second cmd+[ should land on ws1, got {got}")

    # Forward again: ws1 -> ws2 -> ws3.
    got = _press_and_wait(c, "cmd+]", created[1])
    _must(got == created[1], f"cmd+] should land on ws2, got {got}")
    got = _press_and_wait(c, "cmd+]", created[2])
    _must(got == created[2], f"second cmd+] should land on ws3, got {got}")

    # Closed workspaces are skipped, matching the arrow buttons' pruning.
    c.close_workspace(created[1])
    _wait_closed(c, created[1])
    got = _press_and_wait(c, "cmd+[", created[0])
    _must(got == created[0], f"cmd+[ should skip closed ws2 and land on ws1, got {got}")

    # Cleanup the workspaces this test created.
    for wsid in (created[0], created[2]):
        try:
            c.close_workspace(wsid)
        except cmuxError:
            pass

    print("PASS: cmd+[ / cmd+] traverse global workspace focus history")
    return 0


if __name__ == "__main__":
    sys.exit(main())
