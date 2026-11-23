#!/usr/bin/env python3
"""Icon picker and group editor: open to first drawn frame, warm vs cold vs after a sign of intent, and memory at rest.

CMUX-571 (ram-baseline): the two WebKit overlay pages cost about 100 to 200 MB of WebKit processes once made. This
bench says what a cold open costs against a warm one, and what making them on a sign of intent (a menu or palette
open) buys back, through `debug.overlay_open_bench` (DebugOverlayOpenBench.swift) on a tagged DEV app:

  launch   the first open of a fresh launch (no overlay page or WebContent process yet), `--launches` launches,
           alternating the icon picker and the group editor
  cold     the page freed first (release), so the open makes it, `--rounds` times
  warm     the page made and loaded first, so the open reuses it, `--rounds` times
  intent   the page freed, made as a menu or palette open makes it, and the open `lead` ms later, for each of
           `--leads`, `--rounds` times each; also the sign of intent to page loaded (`intent_ready_ms`)

Each row: drawn_ms (the open to the first display frame with the card on screen and the page drawn) p50/p95/max,
shown_ms (the card on screen at all). Memory (bench_memory.sample, the memory-agents bench's sampler, the app's
processes and the WebKit processes it owns): the empty app at rest after launch, with both pages made, after a
release, and after the idle limit freed them (`--idle-limit` s).

Usage: overlay-open-bench.py --app APP --out DIR [--json PATH] [--rounds 12] [--launches 10] [--leads 0,150,300,600]
Fleet: scripts/measure/split-spring.sh --suite=overlay-open [--rounds=N] [--launches=N]
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

KINDS = ("icon_picker", "group_editor")


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--launches", type=int, default=10)
    parser.add_argument("--leads", default="0,150,300,600")
    parser.add_argument("--settle", type=float, default=20.0, help="seconds after launch before the at-rest sample")
    parser.add_argument("--idle-limit", type=float, default=5.0)
    opts, _unknown = parser.parse_known_args(argv)
    return opts


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 1)


def summary(runs, key):
    values = [r.get(key) for r in runs]
    return {"n": sum(isinstance(v, (int, float)) for v in values), "p50": pct(values, 0.5), "p95": pct(values, 0.95),
            "max": pct(values, 1.0)}


def launch(opts):
    import bench_memory
    # The app starts as this script's child, so macOS holds this script responsible for its WebKit processes: they count
    # as the app's when they did not run before the launch (bench_memory.launch does the same).
    bench_memory._direct_launch = True
    bench_memory._webkit_before.update(p for p, _, cmd in bench_memory.process_table() if "com.apple.WebKit." in cmd)
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1440, 900))
    app.launch(timeout=180)
    # The group editor opens on the shown workspace's group (made by a script: no editor opens for it).
    app.rpc("action.run", {"action": "newWorkspaceGroup", "args": {"name": "Bench"}})
    time.sleep(2)  # bench pacing: the sidebar shows the new group
    return app


def bench(app, kind, mode, **extra):
    reply = app.rpc("debug.overlay_open_bench", {"kind": kind, "mode": mode, **extra}, timeout=60) or {}
    print(f"  {kind:<12} {mode:<6} {json.dumps(reply)}", flush=True)
    return reply


def memory(app, label):
    import bench_memory
    got = bench_memory.sample(app.process.pid, app.app, label, 1)
    row = {"label": label, "total_footprint_mb": got["total_footprint_mb"],
           "kinds": {k: v["footprint_mb"] for k, v in got["kinds"].items()}, "processes": len(got["processes"])}
    print("OVERLAY-MEMORY " + json.dumps(row), flush=True)
    return row


def row(report, kind, arm, runs, **extra):
    entry = {"kind": kind, "arm": arm, **extra, "drawn_ms": summary(runs, "drawn_ms"), "shown_ms": summary(runs, "shown_ms"),
             "errors": [r.get("error") for r in runs if r.get("error")]}
    if arm == "intent":
        entry["intent_ready_ms"] = summary(runs, "intent_ready_ms")
        entry["warm_by_open"] = sum(1 for r in runs if r.get("page_ready_before"))
    report["summary"].append(entry)
    print("OVERLAY-OPEN " + json.dumps(entry), flush=True)


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    report = {"runs": [], "summary": [], "memory": []}
    leads = [float(x) for x in opts.leads.split(",") if x]
    try:
        # The first open of a fresh launch: nothing of either page made yet.
        launch_runs = {kind: [] for kind in KINDS}
        for index in range(opts.launches):
            kind = KINDS[index % 2]
            app = launch(opts)
            try:
                time.sleep(5)  # bench pacing: past the launch settle
                reply = bench(app, kind, "as_is")
                reply["arm"] = "launch"
                launch_runs[kind].append(reply)
                report["runs"].append(reply)
            finally:
                app.stop()
        for kind in KINDS:
            row(report, kind, "launch", launch_runs[kind])

        app = launch(opts)
        try:
            time.sleep(opts.settle)  # bench pacing: past the launch settle and its transient
            report["memory"].append(memory(app, "empty_at_rest"))
            for kind in KINDS:
                for arm in ("cold", "warm"):
                    runs = [bench(app, kind, arm) for _ in range(opts.rounds)]
                    for r in runs:
                        r["arm"] = arm
                    report["runs"].extend(runs)
                    row(report, kind, arm, runs)
                for lead in leads:
                    runs = [bench(app, kind, "intent", lead_ms=lead) for _ in range(opts.rounds)]
                    for r in runs:
                        r["arm"] = "intent"
                    report["runs"].extend(runs)
                    row(report, kind, "intent", runs, lead_ms=lead)
            # Memory: both pages made, then freed by a release, then made and freed by the idle limit.
            bench(app, "icon_picker", "warm")
            bench(app, "group_editor", "warm")
            time.sleep(5)
            report["memory"].append(memory(app, "both_pages_made"))
            app.rpc("debug.overlay_open_bench", {"release": True})
            time.sleep(10)  # bench pacing: the freed pages' processes wind down
            report["memory"].append(memory(app, "after_release"))
            app.rpc("debug.overlay_open_bench", {"idle_limit_s": opts.idle_limit})
            bench(app, "icon_picker", "warm")
            bench(app, "group_editor", "warm")
            time.sleep(opts.idle_limit + 10)  # bench pacing: past the idle limit and the processes' wind-down
            report["memory"].append(memory(app, "after_idle_limit"))
        finally:
            app.stop()
    finally:
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
    return 0 if report["summary"] and not any(r.get("error") for r in report["runs"]) else 1


if __name__ == "__main__":
    sys.exit(main())
