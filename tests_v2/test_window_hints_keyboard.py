#!/usr/bin/env python3
"""Regression: Cmd+J labels the window's controls and typing a label clicks one (cx-zjtn.5).

cmux-next's hint mode gives every clickable control in the window a one or two
letter label; typing a whole label clicks that control. Classic had no way to
reach a sidebar row or button without the mouse. Hint mode is off by default
(feature flag `window-hints-release`) until it is styled, so this test needs
the local override written before launch:
  defaults write <debug bundle id> cmux.flags.override.window-hints-release -bool true

Needs a key window, so run it where the app can be frontmost (a whole capture
mini or a local tagged build), never against the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_window_hints_keyboard.py
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _call(fn, *args):
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
    for _i, wsid, _t, selected in _call(c.list_workspaces):
        if selected:
            return wsid
    return ""


def _hints(c: cmux) -> dict:
    return _call(c._call, "debug.window_hints", {}) or {}


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    time.sleep(0.3)

    for _ in range(2):
        c.new_workspace()
        time.sleep(0.3)
    order = [wsid for _i, wsid, _t, _s in c.list_workspaces()]
    first, target = order[-2:]
    c.rename_workspace("hintzebra", target)
    c.select_workspace(first)
    time.sleep(1.0)

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    try:
        before = _hints(c)
    except cmuxError as error:
        before = {"error": str(error)}
    check("no labels before cmd+j", before.get("active") is False, str(before))

    c.simulate_shortcut("cmd+j")
    time.sleep(0.5)
    shown = {}
    try:
        shown = _hints(c)
    except cmuxError as error:
        shown = {"error": str(error)}
    hints = shown.get("hints") or []
    check("cmd+j labels the window's controls", shown.get("active") is True and len(hints) > 1,
          f"count={len(hints)}" if hints else str(shown))
    row = next((h for h in hints if "hintzebra" in (h.get("title") or "")), None)
    check("the renamed workspace's row has a label", row is not None,
          "" if row else str([(h.get("label"), h.get("role"), h.get("title")) for h in hints][:40]))

    if row:
        for letter in row["label"]:
            c.simulate_shortcut(letter)
            time.sleep(0.2)
        time.sleep(0.5)
        check("typing the label clicks the row", _selected(c) == target, f"got={_selected(c)} want={target}")
        check("the labels hide after a pick", _hints(c).get("active") is False)
    else:
        check("typing the label clicks the row", False)
        check("the labels hide after a pick", False)

    c.simulate_shortcut("cmd+j")
    time.sleep(0.5)
    c.simulate_shortcut("escape")
    time.sleep(0.3)
    try:
        after = _hints(c)
    except cmuxError as error:
        after = {"error": str(error)}
    check("escape hides the labels", after.get("active") is False, str(after) if after.get("active") is not False else "")

    for wsid in (first, target):
        try:
            c.close_workspace(wsid)
        except cmuxError:
            pass
    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
