#!/usr/bin/env python3
"""NEVER MERGE (SWITCH FRAMES SF-2): what one warm hidden terminal costs in the app's physical footprint, on the
display and at the window size it runs on, to size WarmSetBudget.terminalCostBytes from a measurement.

Launches the app (bench_memory.launch, direct) with its window at --window (x,y,w,h points; the display's visible
frame by default), then opens terminal workspaces one at a time; each is shown (selected) once, so the warm set keeps
the most recent ones and evicts the rest. At each count in --counts, after --settle s, it samples the app's
footprint and the app's own counts (debug.surfaces: live_terminals, warm_terminal_capacity, last_frames). At the
end it feeds memory pressure (debug.hibernation.pressure: warning, then critical, then normal) and samples after
each, so the warm set's eviction under pressure is measured too.

Prints WARMCOST lines and one WARMCOST-REPORT line (JSON): the display (scale, points, pixels), the window frame,
every sample, and the fit: footprint per live (warm or shown) terminal and per evicted terminal, from a least
squares fit of footprint = a + b * live + c * evicted over the samples.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402
import bench_power as bp  # noqa: E402


def surfaces(sock: str) -> dict:
    got = bp.rpc(sock, "debug.surfaces", {})
    keys = ("live_terminals", "warm_terminal_capacity", "last_frames", "parked_workspaces", "blank_panes")
    return {k: got.get(k) for k in keys} if isinstance(got, dict) and "error" not in got else {"error": str(got)[:200]}


def app_footprint(pid: int, bundle: str) -> dict:
    s = bm.sample(pid, bundle, "x", 0)
    app = s["kinds"].get("app", {})
    return {"app_footprint_mb": app.get("footprint_mb"), "app_rss_mb": app.get("rss_mb"),
            "total_footprint_mb": s["total_footprint_mb"]}


def fit(rows):
    """Least squares footprint = a + b * live + c * evicted. Returns (a, b, c) or None."""
    pts = [(1.0, r["live"], r["evicted"], r["app_footprint_mb"]) for r in rows
           if r.get("app_footprint_mb") is not None and r.get("live") is not None]
    if len(pts) < 4:
        return None
    # Normal equations, 3x3, solved by Gaussian elimination.
    m = [[sum(p[i] * p[j] for p in pts) for j in range(3)] + [sum(p[i] * p[3] for p in pts)] for i in range(3)]
    for col in range(3):
        piv = max(range(col, 3), key=lambda r: abs(m[r][col]))
        if abs(m[piv][col]) < 1e-9:
            return None
        m[col], m[piv] = m[piv], m[col]
        for r in range(3):
            if r != col:
                f = m[r][col] / m[col][col]
                m[r] = [a - f * b for a, b in zip(m[r], m[col])]
    return tuple(round(m[i][3] / m[i][i], 2) for i in range(3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--window", default="", help="x,y,w,h in points inside the main screen's visible frame, from its top-left")
    ap.add_argument("--display", default="{}", help="the virtual display's facts (JSON), copied into the report")
    ap.add_argument("--counts", default="1,2,4,6,8,10,12,16,20,24,32")
    ap.add_argument("--settle", type=float, default=12)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    display = json.loads(a.display or "{}")
    # Screen 0 is the menu-bar (main) screen: the virtual display, made main before the launch.
    extra = {"CMUX_NEXT_TEST_WINDOW_SCREEN": "0", **({"CMUX_NEXT_TEST_WINDOW_FRAME": a.window} if a.window else {})}
    pid, sock, scratch = bm.launch(a.app, {}, extra_env=extra, direct=True)
    report = {"display": display, "samples": [], "pressure": []}
    try:
        app = bm.App(a.app, sock)
        time.sleep(5)  # test script: the launched app's first window settles before the frame is read
        frame = bp.rpc(sock, "debug.window_frame", {})
        report["window"] = frame
        print("WARMCOST window", json.dumps(frame)[:400], flush=True)
        counts = sorted({int(c) for c in a.counts.split(",") if c.strip()})
        made = 0
        for count in counts:
            while made < count:
                if bm.open_workspace(app, "terminal", "about:blank", made) is None:
                    raise SystemExit(f"warm-set-cost: workspace {made + 1} did not open")
                made += 1
                time.sleep(0.8)  # test script: the shown terminal draws its first frame before the next one hides it
            time.sleep(a.settle)  # test script: settle before the sample
            info = surfaces(sock)
            live = info.get("live_terminals")
            row = {"workspaces": made, "live": live, "evicted": (made - live) if isinstance(live, int) else None,
                   **info, **app_footprint(pid, a.app)}
            report["samples"].append(row)
            print("WARMCOST sample", json.dumps(row), flush=True)
        for level in ("warning", "critical", "normal"):
            got = bp.rpc(sock, "debug.hibernation.pressure", {"level": level})
            at = time.monotonic()
            first = surfaces(sock)  # read at once: the warm set must shrink in the pressure event's own turn
            time.sleep(a.settle)  # test script: settle before the footprint sample
            row = {"level": level, "reply": str(got)[:200], "at_once": first,
                   "seconds_to_read": round(time.monotonic() - at, 3), **surfaces(sock), **app_footprint(pid, a.app)}
            report["pressure"].append(row)
            print("WARMCOST pressure", json.dumps(row), flush=True)
        f = fit(report["samples"])
        if f:
            report["fit"] = {"base_mb": f[0], "per_live_terminal_mb": f[1], "per_evicted_terminal_mb": f[2],
                             "warm_minus_evicted_mb": round(f[1] - f[2], 2)}
    finally:
        bm.end_bundle(a.app)
    with open(a.out, "w") as handle:
        json.dump(report, handle, indent=1)
    print("WARMCOST-REPORT " + json.dumps({k: report.get(k) for k in ("display", "window", "fit")}), flush=True)


if __name__ == "__main__":
    main()
