#!/usr/bin/env python3
"""Regression: Cmd+J labels a browser panel's page elements and typing a label clicks one (cx-zjtn.7).

Hint mode (cx-zjtn.5) skipped web views: a page's accessibility tree lives in
its web content process, so a browser panel's links and buttons got no label.
Hint mode is off by default (feature flag `window-hints-release`), so this test
needs the local override written before launch:
  defaults write <debug bundle id> cmux.flags.override.window-hints-release -bool true

Needs a key window, so run it where the app can be frontmost (a whole capture
mini or a local tagged build), never against the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_window_hints_web_page.py
"""

import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

PAGE = (
    "<!doctype html><html><body style='margin:40px'>"
    "<button id='zebra' onclick='window.hintClicked = (window.hintClicked || 0) + 1'>hintzebra</button>"
    "</body></html>"
)


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


def _eval(c: cmux, surface: str, script: str):
    return (_call(c._call, "browser.eval", {"surface_id": surface, "script": script}) or {}).get("value")


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    c.focus_window(c.current_window())
    time.sleep(0.5)

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    url = "data:text/html;charset=utf-8," + urllib.parse.quote(PAGE)
    opened = _call(c._call, "browser.open_split", {"url": url}) or {}
    surface = str(opened.get("surface_id") or "")
    check("a browser panel opens", bool(surface), str(opened))
    deadline = time.time() + 15
    while surface and time.time() < deadline:
        try:
            if _eval(c, surface, "document.readyState === 'complete' && !!document.getElementById('zebra')"):
                break
        except cmuxError:
            pass
        time.sleep(0.2)
    c.focus_window(c.current_window())
    time.sleep(1.0)

    c.simulate_shortcut("cmd+j")
    shown = {}
    for _ in range(10):
        time.sleep(0.3)
        shown = _hints(c)
        if shown.get("active"):
            break
    hints = shown.get("hints") or []
    check("cmd+j shows labels", shown.get("active") is True, "" if shown.get("active") else str(shown))
    # Exactly the button's name: the panel's tab and address bar show the data URL, which contains it.
    button = next((h for h in hints if (h.get("title") or "") == "hintzebra"), None)
    listing = str([(h.get("label"), h.get("role"), h.get("title")) for h in hints][:60]) if hints else str(shown)
    check("the page's button has a label", button is not None, "" if button else listing)

    if button:
        for letter in button["label"]:
            c.simulate_shortcut(letter)
            time.sleep(0.2)
        time.sleep(1.0)
        clicked = _eval(c, surface, "window.hintClicked || 0")
        check("typing its label clicks the button once", clicked == 1, f"clicks={clicked}")
        check("the labels hide after a pick", _hints(c).get("active") is False)
    else:
        c.simulate_shortcut("escape")
        check("typing its label clicks the button once", False)
        check("the labels hide after a pick", False)

    if surface:
        try:
            _call(c._call, "surface.close", {"surface_id": surface})
        except cmuxError:
            pass
    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
