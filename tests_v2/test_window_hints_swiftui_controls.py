#!/usr/bin/env python3
"""Regression: Cmd+J labels the titlebar's SwiftUI buttons and typing a label clicks one (cx-zjtn.7).

Hint mode (cx-zjtn.5) walked the window's accessibility tree in process, but a
SwiftUI host exposes only AXUnknown elements there, so the titlebar's buttons
(Toggle Sidebar, Notifications, New Workspace) got no label. Hint mode is off
by default (feature flag `window-hints-release`), so this test needs the local
override written before launch:
  defaults write <debug bundle id> cmux.flags.override.window-hints-release -bool true

Needs a key window, so run it where the app can be frontmost (a whole capture
mini or a local tagged build), never against the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_window_hints_swiftui_controls.py
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


def _hints(c: cmux) -> dict:
    try:
        return _call(c._call, "debug.window_hints", {}) or {}
    except cmuxError as error:
        return {"error": str(error)}


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    c.focus_window(c.current_window())
    time.sleep(1.0)

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    before = [wsid for _i, wsid, _t, _s in _call(c.list_workspaces)]
    c.simulate_shortcut("cmd+j")
    time.sleep(0.5)
    shown = _hints(c)
    hints = shown.get("hints") or []
    listing = str([(h.get("label"), h.get("role"), h.get("title")) for h in hints][:60]) if hints else str(shown)
    check("cmd+j shows labels", shown.get("active") is True, "" if shown.get("active") else str(shown))

    def titled(title: str):
        return next((h for h in hints if (h.get("title") or "") == title), None)

    for title in ("Toggle Sidebar", "Notifications", "New Workspace"):
        hint = titled(title)
        check(f"the titlebar's {title} button has a label", hint is not None, "" if hint else listing)

    new = titled("New Workspace")
    if new:
        for letter in new["label"]:
            c.simulate_shortcut(letter)
            time.sleep(0.2)
        time.sleep(1.0)
        after = [wsid for _i, wsid, _t, _s in _call(c.list_workspaces)]
        added = [wsid for wsid in after if wsid not in before]
        check("typing its label clicks New Workspace", len(added) == 1, f"before={len(before)} after={len(after)}")
        check("the labels hide after a pick", _hints(c).get("active") is False)
        for wsid in added:
            try:
                c.close_workspace(wsid)
            except cmuxError:
                pass
    else:
        c.simulate_shortcut("escape")
        check("typing its label clicks New Workspace", False)
        check("the labels hide after a pick", False)

    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
