#!/usr/bin/env python3
"""Window order e2e (cx-8w027.25): the app keeps its window order without the window server.

The app records its window order (front first) in the window registry's recency, from key-window
changes and from every window it orders in (WindowActivation), and saves it as each window's
restore order; a save never asks the window server (NSApp.orderedWindows). This run proves the
record matches the real stacking and that a relaunch restores it:

  1. Three windows (New Window twice), then two re-orders that take no key under no-activate
     (Select Previous / Next Window order a window front without making it key).
  2. After each step: the open windows' recency equals the window server's z-order of the shown
     windows (debug.windows z_order, a debug read).
  3. Quit and relaunch on the same tag: the three windows come back in the same z-order, and the
     recency equals it again.

Usage (GUI host, fleet app): python3 scripts/cmux-next/window-order-e2e.py --app "$NX_APP" --out "$NX_ARTIFACTS"
"""
import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_gate", os.path.join(HERE, "perf-gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def windows(app):
    report = app.rpc("debug.windows") or {}
    rows = [w for w in report.get("windows") or [] if w.get("open")]
    open_ids = {w["id"] for w in rows}
    return {"rows": rows, "z": report.get("z_order") or [],
            "recency": [i for i in report.get("recency") or [] if i in open_ids],
            "visible": [w["id"] for w in rows if w.get("visible")]}


def order_matches(app, what, want=None):
    state = gate.wait(lambda: (lambda s: s if len(s["visible"]) == 3 and s["z"] == s["recency"]
                               and (want is None or s["z"] == want) else None)(windows(app)), 20) or windows(app)
    gate.check(len(state["visible"]) == 3 and state["z"] == state["recency"] and (want is None or state["z"] == want),
               f"{what}: z-order {state['z']}, recency {state['recency']}" + (f", want {want}" if want else ""), "windows")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="path to a `cmux DEV <tag>.app` Debug bundle")
    parser.add_argument("--out", required=True)
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    app = gate.App(os.path.abspath(opts.app), opts.out)
    try:
        run(app)
    finally:
        app.stop()
        with open(os.path.join(opts.out, "window-order.json"), "w") as f:
            json.dump({"ok": not gate.failures, "failures": gate.failures, "checks": gate.report["checks"]}, f, indent=1)
    print(f"window order e2e: {'PASS' if not gate.failures else 'FAIL'} ({len(gate.report['checks'])} checks)", flush=True)
    sys.exit(1 if gate.failures or not gate.report["checks"] else 0)


def run(app):
    app.launch()
    for _ in range(2):
        app.action("newWindow")
    if not gate.check(bool(gate.wait(lambda: len(windows(app)["visible"]) == 3, 60)),
                      f"three windows show ({windows(app)['visible']})", "windows"):
        return
    state = order_matches(app, "three new windows")
    # Select Previous Window raises the back window, Select Next Window the second one: under no-activate
    # each orders a window front without making it key (WindowActivation .focus).
    for action, pick in (("selectPreviousWindow", -1), ("selectNextWindow", 1)):
        raised = windows(app)["z"][pick]
        app.action(action)
        state = order_matches(app, f"{action} raised {raised}")
        gate.check(state["z"][0] == raised, f"{raised} is in front after {action} ({state['z']})", "windows")
    before = state["z"]
    app.relaunch()
    order_matches(app, "after the relaunch", want=before)


if __name__ == "__main__":
    main()
