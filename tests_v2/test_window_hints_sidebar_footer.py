#!/usr/bin/env python3
"""Regression: Cmd+J labels the sidebar footer's SwiftUI buttons, and never the traffic lights (cx-zjtn.7).

In process a SwiftUI host shows its controls only as AXUnknown elements, so
hint mode labels a SwiftUI control only when it carries a marker view (#19484
marked the titlebar). The sidebar footer's Help button got no label. The
window's close, minimize and zoom buttons got unnamed labels, so a typo could
close the window. Hint mode is off
by default (feature flag `window-hints-release`), so this test needs the local
override written before launch:
  defaults write <debug bundle id> cmux.flags.override.window-hints-release -bool true

Needs a key window, so run it where the app can be frontmost (a whole capture
mini or a local tagged build), never against the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_window_hints_sidebar_footer.py
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

    c.simulate_shortcut("cmd+j")
    time.sleep(0.5)
    shown = _hints(c)
    hints = shown.get("hints") or []
    listing = str([(h.get("label"), h.get("role"), h.get("title")) for h in hints][:60]) if hints else str(shown)
    check("cmd+j shows labels", shown.get("active") is True, "" if shown.get("active") else str(shown))
    help_hint = next((h for h in hints if (h.get("title") or "") == "Help"), None)
    check("the sidebar footer's Help button has a label", help_hint is not None, "" if help_hint else listing)
    unnamed = [h.get("label") for h in hints if h.get("role") == "AXButton" and not (h.get("title") or "")]
    check("no label on an unnamed button (the traffic lights)", not unnamed, f"unnamed={unnamed} {listing}" if unnamed else "")
    c.simulate_shortcut("escape")
    time.sleep(0.3)
    check("escape hides the labels", _hints(c).get("active") is False)

    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
