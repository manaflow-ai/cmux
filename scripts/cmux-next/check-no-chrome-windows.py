#!/usr/bin/env python3
"""Live check: no source opens a Chromium window of its own on a tagged build.

Usage: check-no-chrome-windows.py <tag> [--socket PATH] [--settle S] [--only NAME...]

Opens a Chromium tab in the tagged app, then runs each source that would
open a Chromium window (links from chrome:// pages, target=_blank,
window.open with and without features, form targets, Cmd- and middle-click,
Chrome shortcuts). After each it reads debug.cef "windows":
chromium_windows (top-level Chromium windows with a title bar on screen)
must be empty. It also reports guard_blocked (windows the app's last-resort
guard hid after they appeared; with fork API 8 this should stay 0),
fork_foreign_browsers and the cmux tab count change.

Page actions run in the tab through the in-process DevTools protocol
(debug.cef.devtools), keys through debug.key: nothing reaches other apps.
Exits 1 when a source leaves a Chromium window on screen, 2 on setup errors.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402

PAGE = (
    "data:text/html,<title>nochw</title>"
    "<a id=blank href='https://example.com/?blank' target=_blank>blank</a><br>"
    "<a id=plain href='https://example.com/?plain'>plain</a><br>"
    "<form id=form action='https://example.com/' target=_blank><input name=q value=form></form>"
)


class App:
    def __init__(self, path):
        self.path = path

    def call(self, method, params=None):
        return Client(self.path, timeout=20).call(method, params or {})

    def cdp(self, method, params=None):
        response = self.call("debug.cef.devtools", {"method": method, "params": params or {}})
        result = response.get("result") or {}
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return json.loads(result.get("result") or "{}")

    def js(self, expression):
        value = self.cdp("Runtime.evaluate", {"expression": expression, "returnByValue": True,
                                              "awaitPromise": True, "userGesture": True})
        return (value.get("result") or {}).get("value")

    def shown_urls(self):
        report = self.call("debug.cef").get("result") or {}
        return [entry.get("url") for entry in report.get("devtools") or []]

    def windows(self):
        return (self.call("debug.cef").get("result") or {}).get("windows") or {}

    def tabs(self):
        focus = self.call("debug.focus").get("result") or {}
        return [tab for window in focus.get("windows", []) for pane in window.get("topology", [])
                for tab in pane.get("tabs", [])]

    def navigate(self, url, settle=1.5):
        self.cdp("Page.navigate", {"url": url})
        time.sleep(settle)

    def click(self, selector, modifiers=0, button="left"):
        box = self.js(f"(()=>{{const r=document.querySelector('{selector}').getBoundingClientRect();"
                      "return [r.x+r.width/2, r.y+r.height/2]})()")
        x, y = box
        for kind in ("mousePressed", "mouseReleased"):
            self.cdp("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": button,
                                                  "clickCount": 1, "modifiers": modifiers})

    def key(self, key, *modifiers):
        # To the Chromium page window: the chord first meets cmux's key
        # routing, then Chromium's accelerators.
        return self.call("debug.key", {"key": key, "modifiers": list(modifiers), "target": "page"})


def web_store_link(app):
    app.navigate("chrome://extensions", 2.0)
    return app.js("""(()=>{let hit=null;const walk=(root)=>{root.querySelectorAll('a').forEach(e=>{
        if(!hit&&e.target==='_blank'&&e.href.includes('chromewebstore'))hit=e});
        root.querySelectorAll('*').forEach(e=>{if(e.shadowRoot)walk(e.shadowRoot)})};
        walk(document);if(!hit)return 'no link';hit.click();return hit.href})()""")


def fresh(action):
    """Runs `action` in a new Chromium tab showing PAGE (the previous source
    may have moved focus to another tab, pane or window)."""
    def run(app):
        app.call("action.run", {"action": "tab new-chromium", "args": {"url": PAGE}})
        time.sleep(2.0)
        return action(app)
    return run


def on_page(action):
    def run(app):
        app.navigate(PAGE, 1.0)
        return action(app)
    return run


SOURCES = [
    ("chrome://extensions Chrome Web Store link", web_store_link),
    ("target=_blank link (click)", on_page(lambda app: app.click("#blank"))),
    ("window.open(url)", on_page(lambda app: app.js("!!window.open('https://example.com/?open')"))),
    ("window.open with features (popup)", on_page(
        lambda app: app.js("!!window.open('https://example.com/?popup','p','popup,width=400,height=300')"))),
    ("window.open noopener", on_page(
        lambda app: app.js("window.open('https://example.com/?noopener','_blank','noopener'); true"))),
    ("form target=_blank", on_page(lambda app: app.js("document.getElementById('form').submit(); true"))),
    ("Cmd-click link", on_page(lambda app: app.click("#plain", modifiers=4))),
    ("Shift-click link (new window)", on_page(lambda app: app.click("#plain", modifiers=8))),
    ("middle-click link", on_page(lambda app: app.click("#plain", button="middle"))),
    ("Cmd-N in page", fresh(lambda app: app.key("n", "cmd"))),
    ("Cmd-Shift-N in page", fresh(lambda app: app.key("n", "cmd", "shift"))),
    ("Cmd-T in page", fresh(lambda app: app.key("t", "cmd"))),
    ("Cmd-Shift-T in page", fresh(lambda app: app.key("t", "cmd", "shift"))),
    ("Cmd-Shift-B in page", fresh(lambda app: app.key("b", "cmd", "shift"))),
    ("chrome://newtab", fresh(lambda app: app.navigate("chrome://newtab", 1.5))),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tag")
    parser.add_argument("--socket")
    parser.add_argument("--settle", type=float, default=2.5)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    path = args.socket or f"/tmp/cmux-debug-{args.tag}.sock"
    if os.path.realpath(path) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
        print("refusing the default socket", file=sys.stderr)
        return 2
    app = App(path)
    try:
        app.call("action.run", {"action": "tab new-chromium", "args": {"url": "about:blank"}})
    except (OSError, ConnectionError) as error:
        print(f"cannot reach {path}: {error}", file=sys.stderr)
        return 2
    deadline = time.monotonic() + 30
    while (app.call("debug.cef").get("result") or {}).get("state") != "ready":
        if time.monotonic() > deadline:
            print("Chromium did not start", file=sys.stderr)
            return 2
        time.sleep(0.5)
    time.sleep(1.5)
    failures = 0
    for name, run in SOURCES:
        if args.only and not any(part.lower() in name.lower() for part in args.only):
            continue
        before = app.windows()
        tabs_before = len(app.tabs())
        try:
            detail = run(app)
        except Exception as error:  # noqa: BLE001 - report and continue
            detail = f"error: {error}"
        time.sleep(args.settle)
        after = app.windows()
        offending = after.get("chromium_windows") or []
        blocked = (after.get("guard_blocked") or 0) - (before.get("guard_blocked") or 0)
        foreign = (after.get("fork_foreign_browsers") or 0) - (before.get("fork_foreign_browsers") or 0)
        tabs = len(app.tabs()) - tabs_before
        ok = not offending
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name}: tabs {tabs:+d}, guard_blocked +{blocked}, "
              f"fork_foreign +{foreign}, windows {offending}, shown {app.shown_urls()} ({detail})")
    print(json.dumps(app.windows(), indent=1))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
