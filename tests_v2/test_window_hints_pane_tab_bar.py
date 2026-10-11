#!/usr/bin/env python3
"""Regression: Cmd+J labels a pane's tabs and its tab bar buttons (cx-zjtn.7).

In process a SwiftUI host shows its controls only as AXUnknown elements, so
hint mode labels a SwiftUI control only when it carries a marker view. The
pane tab bar (Bonsplit) had none: its tabs and its New Terminal, New Browser,
Split Right and Split Down buttons got no label. Hint mode is off
by default (feature flag `window-hints-release`), so this test needs the local
override written before launch:
  defaults write <debug bundle id> cmux.flags.override.window-hints-release -bool true

Needs a key window, so run it where the app can be frontmost (a whole capture
mini or a local tagged build), never against the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_window_hints_pane_tab_bar.py
"""

import sys
import time
import urllib.parse
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


def _show(c: cmux) -> list:
    c.simulate_shortcut("cmd+j")
    time.sleep(0.8)
    return _hints(c).get("hints") or []


def _type(c: cmux, label: str) -> None:
    for letter in label:
        c.simulate_shortcut(letter)
        time.sleep(0.2)
    time.sleep(1.0)


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

    # A second tab in the pane, a page whose title names it.
    first = next(sid for _i, sid, _t, selected in _call(c.list_pane_surfaces) if selected)
    page = "data:text/html;charset=utf-8," + urllib.parse.quote("<title>hinttab</title><p>tab")
    browser = _call(c.new_surface, None, "browser", page)
    time.sleep(2.0)
    _call(c.focus_surface_by_panel, first)
    time.sleep(1.0)
    c.focus_window(c.current_window())
    time.sleep(0.5)

    hints = _show(c)
    listing = str([(h.get("label"), h.get("role"), h.get("title")) for h in hints][:60])
    tab = next((h for h in hints if (h.get("title") or "") == "hinttab"), None)
    check("the pane's browser tab has a label", tab is not None, "" if tab else listing)
    for name in ("New Terminal", "New Browser", "Split Right", "Split Down"):
        button = next((h for h in hints if (h.get("title") or "").startswith(name)), None)
        check(f"the tab bar's {name} button has a label", button is not None, "" if button else listing)

    if tab:
        _type(c, tab["label"])
        selected = next((sid for _i, sid, _t, sel in _call(c.list_pane_surfaces) if sel), "")
        check("typing the tab's label selects it", selected == browser, f"selected={selected} want={browser}")
    else:
        c.simulate_shortcut("escape")
        check("typing the tab's label selects it", False)

    panes = len(_call(c.list_panes))
    hints = _show(c)
    split = next((h for h in hints if (h.get("title") or "").startswith("Split Right")), None)
    if split:
        _type(c, split["label"])
        check("typing Split Right's label splits the pane", len(_call(c.list_panes)) == panes + 1,
              f"panes {panes} -> {len(_call(c.list_panes))}")
    else:
        c.simulate_shortcut("escape")
        check("typing Split Right's label splits the pane", False)

    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
