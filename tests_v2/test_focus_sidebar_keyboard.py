#!/usr/bin/env python3
"""Regression: Ctrl+Cmd+E focuses the workspace sidebar for keyboard use (cx-zjtn.5).

cmux-next's Focus Sidebar hands the workspace list the keyboard: Down/Up
select the next/previous workspace while the list keeps focus, and Return
goes back to the selected workspace's terminal. Classic had no way to reach
the sidebar without the mouse.

Needs a key window, so run it where the app can be frontmost (a whole capture
mini or a local tagged build), never against the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_focus_sidebar_keyboard.py

simulate_shortcut routes through AppDelegate.debugHandleCustomShortcut; keys no
shortcut claims (the arrows, Return) go to the key window's first responder.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _call(c: cmux, fn, *args):
    # The socket rate-limits tight polling; back off and retry.
    for _ in range(20):
        try:
            return fn(*args)
        except cmuxError as error:
            if "rate_limited" not in str(error):
                raise
            time.sleep(0.3)
    return fn(*args)


def _selected(c: cmux) -> str:
    for _i, wsid, _t, selected in _call(c, c.list_workspaces):
        if selected:
            return wsid
    return ""


def _focused_terminal(c: cmux) -> bool:
    surfaces = _call(c, c.list_pane_surfaces)
    selected = [sid for _i, sid, _t, sel in surfaces if sel]
    return bool(selected) and _call(c, c.is_terminal_focused, selected[0])


def _settle(check, timeout: float = 3.0):
    deadline = time.time() + timeout
    value = check()
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.3)
    return value


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    time.sleep(0.3)

    for _ in range(3):
        c.new_workspace()
        time.sleep(0.3)
    order = [wsid for _i, wsid, _t, _s in c.list_workspaces()]
    if len(order) < 3:
        raise cmuxError(f"expected three workspaces, got {order}")
    created = order[-3:]
    ws1, ws2, ws3 = created
    print("workspaces", order)
    c.select_workspace(ws2)
    time.sleep(1.0)
    _settle(lambda: _focused_terminal(c))

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    check("terminal starts focused", _focused_terminal(c))

    c.simulate_shortcut("ctrl+cmd+e")
    time.sleep(0.5)
    check("ctrl+cmd+e moves focus off the terminal", bool(_settle(lambda: not _focused_terminal(c))))

    c.simulate_shortcut("down")
    _settle(lambda: _selected(c) == ws3)
    check("down selects the next workspace", _selected(c) == ws3, f"got={_selected(c)} want={ws3}")
    time.sleep(0.5)
    check("the sidebar keeps focus after down", not _focused_terminal(c))

    c.simulate_shortcut("up")
    time.sleep(0.4)
    c.simulate_shortcut("up")
    _settle(lambda: _selected(c) == ws1)
    check("up twice selects two workspaces back", _selected(c) == ws1, f"got={_selected(c)} want={ws1}")

    c.simulate_shortcut("return")
    check("return focuses the selected workspace's terminal", bool(_settle(lambda: _focused_terminal(c))))
    check("return keeps the selection", _selected(c) == ws1)

    for wsid in created:
        try:
            c.close_workspace(wsid)
        except cmuxError:
            pass
    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
