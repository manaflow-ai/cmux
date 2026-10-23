#!/usr/bin/env python3
"""Click to file picker: how long the open panel takes to show, and what of it holds the main thread.

Launches a tagged DEV app (bench_launch.py), then times file-picker opens through `debug.open_panel_bench`
(DebugOpenPanelBench.swift) in three modes, each `--rounds` times, light (one window) and STRESS
(perf-stress-session.py):

  made    the panel made ahead (MadeAheadOpenPanel), as Home's "+" and an agent composer's Attach take it
  fresh   a new NSOpenPanel() per open: the on-demand path when none was made ahead
  window  begin(completionHandler:): a separate panel window instead of a sheet

Per open: init_ms (getting the panel), begin_ms (beginSheetModal / begin), sync_ms (their sum: the click's
main-thread time), visible_ms (the first display frame with the panel on screen) and the longest display
frame interval from the click until 300 ms after it showed (frames.max_ms) with the refresh rate.

Usage: open-panel-bench.py --app APP --out DIR [--json PATH] [--sessions light,stress] [--rounds 5]
Fleet: scripts/measure/split-spring.sh --suite=open-panel [--sessions=...] [--rounds=N]
"""
import argparse, importlib.util, json, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--rounds", type=int, default=5)
parser.add_argument("--modes", default="made,fresh,window")
opts, _unknown = parser.parse_known_args()


def load_stress():
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


def summary(runs, key):
    values = [r.get(key) for r in runs]
    return {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}


def measure(app, session, report):
    for mode in opts.modes.split(","):
        runs = []
        for index in range(opts.rounds):
            reply = app.rpc("debug.open_panel_bench", {"mode": mode}, timeout=40) or {}
            frames = reply.get("frames") or {}
            run = {k: reply.get(k) for k in ("mode", "made_ahead_before", "init_ms", "begin_ms", "sync_ms", "visible_ms", "error")}
            run.update(frame_max_ms=frames.get("max_ms"), missed=frames.get("missed"), refresh_ms=frames.get("refresh_ms"),
                       session=session, round=index)
            runs.append(run)
            print(f"  {session:<6} {mode:<6} #{index}: init {run['init_ms']} begin {run['begin_ms']} sync {run['sync_ms']} "
                  f"visible {run['visible_ms']} ms, longest frame {run['frame_max_ms']} ms (refresh {run['refresh_ms']} ms) "
                  f"made_before {run['made_ahead_before']} {run['error'] or ''}", flush=True)
        report["runs"].extend(runs)
        row = {"session": session, "mode": mode, **{k: summary(runs, k) for k in ("init_ms", "begin_ms", "sync_ms", "visible_ms", "frame_max_ms")}}
        report["summary"].append(row)
        print("OPEN-PANEL " + json.dumps(row), flush=True)


def main():
    os.makedirs(opts.out, exist_ok=True)
    report = {"runs": [], "summary": []}
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1600, 1000))
    try:
        app.launch(timeout=180, settle=3)
        for session in opts.sessions.split(","):
            if session == "stress":
                built = load_stress().Stress(lambda m, p=None, timeout=60: app.rpc(m, p, timeout)).build()
                report["stress_session"] = built
            measure(app, session, report)
    finally:
        app.stop()
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
    return 0 if report["summary"] and all(not r.get("error") for r in report["runs"]) else 1


if __name__ == "__main__":
    sys.exit(main())
