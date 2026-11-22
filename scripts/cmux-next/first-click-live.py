#!/usr/bin/env python3
"""One click is enough: native controls act on the first press while a Chromium page holds the key.

User 2026-10-30: "a lot of buttons, i feel like i have to click twice for it to actually work". A Chromium page
(Home, the agent chat, New Tab, every browser tab) is a child window that takes the key, and AppKit spends the
first press in a window that is not key on making it key unless the view under it accepts the first mouse.
`FirstClickPolicy` (CmuxNextDesign) makes the main window key first, so the press acts.

Launches a tagged DEV app (bench_launch.py) as the active app (NO_ACTIVATE off: the case is a person using cmux),
opens a Chromium tab, and per round makes the page window key (`debug.first_click make_key: page`), then:

  audit        every click target of the window (`debug.first_click`): class, label, whether a press at its center
               reaches it (`hit`), its own acceptsFirstMouse answer and the window policy's; FIRST-CLICK-AUDIT rows
  new-workspace  one posted click (`debug.mouse`, the app's event queue: CmuxApplication.sendEvent, the window's
               sendEvent, AppKit's first-mouse rule, hit testing) on the sidebar's New Workspace button; it must
               make exactly one workspace. click_ms: the click sent to the new row in `debug.sidebar_rows`.
  toggle-sidebar one click on the titlebar's sidebar toggle; `sidebar_hidden` (debug.windows) must flip.

The audit also runs after `debug.window.focus` on the main window; a Chromium page that takes the key back shows
as `key: page` there. Prints FIRST-CLICK rows and a FIRST-CLICK-RESULT
line; exit 0 when every one-click check acted. Not a CI gate: an agent runs it on the fleet before and after a fix.

Usage: first-click-live.py --app APP --out DIR [--json PATH] [--rounds 5]
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
         --ref SHA --arg=--suite=first-click --artifact artifacts/split-spring/report.json
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
    parser.add_argument("--rounds", type=int, default=5)
    opts, _unknown = parser.parse_known_args(argv)
    return opts


def workspace_count(rpc):
    """Workspace rows in the first window's sidebar (`debug.sidebar_rows`); None when the app does not answer."""
    reply = rpc("debug.sidebar_rows") or {}
    windows = reply.get("windows")
    if not isinstance(windows, list) or not windows:
        return None
    return sum(1 for row in windows[0].get("rows") or [] if str(row.get("key", "")).startswith("workspace("))


def wait(predicate, seconds, step=0.005):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 1) if values else None


class Run:
    def __init__(self, app, report):
        self.app, self.report = app, report

    def rpc(self, method, params=None, timeout=30):
        return self.app.rpc(method, params, timeout) or {}

    def window_id(self):
        windows = self.rpc("debug.windows").get("windows") or []
        return windows[0].get("id") if windows else None

    def sidebar_hidden(self):
        windows = self.rpc("debug.windows").get("windows") or []
        return windows[0].get("sidebar_hidden") if windows else None

    def key(self, mode):
        """Puts the key where the case wants it: `page` (the Chromium page window) or `self` (the main window)."""
        if mode == "page":
            return self.rpc("debug.first_click", {"make_key": "page"})
        self.rpc("debug.window.focus", {"window": self.window_id()})
        return self.rpc("debug.first_click")

    def target(self, state, label):
        hits = [t for t in state.get("targets") or [] if label in (t.get("label") or "").lower() and t.get("hit") and t.get("enabled")]
        return hits[0] if hits else None

    def click(self, target):
        return self.rpc("debug.mouse", {"x": target["x"], "y": target["y"], "action": "click"})

    def new_workspace(self, mode, rnd):
        state = self.key(mode)
        row = {"case": "new-workspace", "key_mode": mode, "round": rnd, "key": state.get("key"), "app_active": state.get("app_active")}
        target = self.target(state, "new workspace")
        if not target:
            row["error"] = "no New Workspace button with a hit at its center"
            return row
        before = workspace_count(self.rpc)
        if before is None:
            row["error"] = "the app gave no sidebar rows"
            return row
        start = time.monotonic()
        self.click(target)
        first = wait(lambda: (lambda n: n if n is not None and n > before else None)(workspace_count(self.rpc)), 3)
        click_ms = round((time.monotonic() - start) * 1000, 1) if first else None
        time.sleep(0.5)  # settle: a second workspace from a double delivery shows by now
        after = workspace_count(self.rpc) if first else before
        row.update(before=before, after=after, acted=bool(first) and after == before + 1, target=target["class"], click_ms=click_ms)
        if first:
            self.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}})
            wait(lambda: workspace_count(self.rpc) == before, 3, 0.02)
        return row

    def toggle_sidebar(self, mode, rnd):
        state = self.key(mode)
        row = {"case": "toggle-sidebar", "key_mode": mode, "round": rnd, "key": state.get("key"), "app_active": state.get("app_active")}
        # The titlebar's toggle: a "sidebar" control in the window's top band.
        target = next((t for t in state.get("targets") or [] if "sidebar" in (t.get("label") or "").lower() and t.get("hit")
                       and t.get("enabled") and t["y"] < 60), None)
        if not target:
            row["error"] = "no titlebar sidebar toggle with a hit at its center"
            return row
        before = self.sidebar_hidden()
        start = time.monotonic()
        self.click(target)
        flipped = wait(lambda: self.sidebar_hidden() != before, 3, 0.01)
        row.update(acted=bool(flipped), target=target["class"], label=target.get("label"),
                   click_ms=round((time.monotonic() - start) * 1000, 1) if flipped else None)
        if flipped:
            self.rpc("action.run", {"action": "toggleSidebar"})
            wait(lambda: self.sidebar_hidden() == before, 3, 0.02)
        return row

    def audit(self, mode):
        state = self.key(mode)
        targets = state.get("targets") or []
        dropped = [t for t in targets if t.get("hit") and not t.get("first_click")]
        # Without the window's policy only the view's own acceptsFirstMouse decides (the build before the fix).
        own = [t for t in targets if t.get("hit") and t.get("enabled") and not t.get("accepts")]
        unreachable = [t for t in targets if not t.get("hit")]
        row = {"key_mode": mode, "key": state.get("key"), "app_active": state.get("app_active"), "policy": state.get("policy"),
               "targets": len(targets), "first_click_dropped": len(dropped), "own_answer_drops": len(own),
               "own_answer_drop_classes": sorted({t["class"] for t in own}), "unreachable_center": len(unreachable),
               "dropped_classes": sorted({t["class"] for t in dropped}), "unreachable_classes": sorted({t["class"] for t in unreachable})}
        self.report["audit"].append({**row, "rows": targets})
        print("FIRST-CLICK-AUDIT " + json.dumps(row), flush=True)


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    report = {"rows": [], "audit": [], "summary": []}
    page = os.path.join(opts.out, "first-click-page.html")
    with open(page, "w") as f:
        f.write("<!doctype html><title>first click</title><body style='font:16px sans-serif'>first click page</body>")
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1440, 900), env={"CMUX_NEXT_NO_ACTIVATE": None})
    ok = False
    try:
        app.launch(timeout=180)
        run = Run(app, report)
        run.rpc("action.run", {"action": "openBrowser", "args": {"url": "file://" + page}, "focus": True})
        if not wait(lambda: not run.rpc("debug.first_click", {"make_key": "page"}).get("error"), 60, 0.25):
            report["error"] = "no Chromium page window took the key"
            print("FIRST-CLICK-RESULT " + json.dumps({"ok": False, "error": report["error"]}), flush=True)
            return 1
        for mode in ("page", "self"):
            run.audit(mode)
        for mode in ("page",):
            for case in (run.new_workspace, run.toggle_sidebar):
                for rnd in range(opts.rounds):
                    row = case(mode, rnd)
                    report["rows"].append(row)
                    print("FIRST-CLICK " + json.dumps(row), flush=True)
        for case in ("new-workspace", "toggle-sidebar"):
            for mode in ("page",):
                rows = [r for r in report["rows"] if r["case"] == case and r["key_mode"] == mode]
                acted = [r for r in rows if r.get("acted")]
                ms = [r.get("click_ms") for r in acted]
                row = {"case": case, "key_mode": mode, "rounds": len(rows), "acted": len(acted),
                       "click_ms": {"p50": pct(ms, 0.5), "p95": pct(ms, 0.95), "max": pct(ms, 1.0)},
                       "errors": sorted({r["error"] for r in rows if r.get("error")})}
                report["summary"].append(row)
                print("FIRST-CLICK-SUMMARY " + json.dumps(row), flush=True)
        ok = bool(report["summary"]) and all(r["acted"] == r["rounds"] and r["rounds"] for r in report["summary"])
        print("FIRST-CLICK-RESULT " + json.dumps({"ok": ok}), flush=True)
    finally:
        app.stop()
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
