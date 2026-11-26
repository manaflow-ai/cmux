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
from state_wait import wait_stable, wait_until  # noqa: E402

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
    # Until the sidebar lists the new group and its rows hold still.
    rows = lambda: json.dumps((app.rpc("debug.sidebar_rows") or {}).get("rows"), sort_keys=True, default=str)  # noqa: E731
    if not wait_until(lambda: '"Bench"' in rows(), "the sidebar's Bench group row", timeout=15, interval=0.1,
                      raise_on_timeout=False):
        print("overlay-open: the sidebar never listed the Bench group in 15 s", flush=True)
    wait_stable(rows, "the sidebar rows after the new group", timeout=10, interval=0.1, reads=4, raise_on_timeout=False)
    return app


def app_cpu_pct(app, window=0.5):
    """The app's main process CPU % over `window` s."""
    import bench_memory
    before = bench_memory.usage(app.process.pid)
    time.sleep(window)  # sleep-ok: the CPU sampling window between the two rusage reads
    after = bench_memory.usage(app.process.pid)
    return None if before is None or after is None else 100 * (after[3] - before[3]) / 1e9 / window


def wait_quiet(app, what, timeout=30.0, limit_pct=10.0):
    """Until the app's main process idles (two 0.5 s windows under `limit_pct` CPU): its launch or page work ended."""
    quiet = [0]
    def idle():
        cpu = app_cpu_pct(app)
        quiet[0] = quiet[0] + 1 if cpu is not None and cpu < limit_pct else 0
        return quiet[0] >= 2
    if not wait_until(idle, what, timeout=timeout, interval=0.0, raise_on_timeout=False):
        print(f"overlay-open: {what}: the app never idled in {timeout:g} s", flush=True)


def page_processes(app):
    import bench_memory
    return sum(1 for kind, cmd in bench_memory.owned(app.process.pid, app.app).values() if "com.apple.WebKit." in cmd)


def wait_fewer_pages(app, than, what, timeout=30.0):
    """Until fewer WebKit processes than `than` are left (the freed pages' processes exited), then the app idles."""
    if not wait_until(lambda: page_processes(app) < than, what, timeout=timeout, interval=0.25, raise_on_timeout=False):
        print(f"overlay-open: {what}: still {page_processes(app)} WebKit processes after {timeout:g} s", flush=True)
    wait_quiet(app, what)


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
                wait_quiet(app, "the launch's work")
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
            # sleep-ok: --settle defines the at-rest memory row (that many s after launch, the same every run).
            time.sleep(opts.settle)
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
            # Until both pages' WebKit processes stop changing and the app idles.
            wait_stable(lambda: page_processes(app), "both pages' WebKit processes", timeout=20, interval=0.5, reads=4,
                        raise_on_timeout=False)
            wait_quiet(app, "both pages made")
            made = page_processes(app)
            report["memory"].append(memory(app, "both_pages_made"))
            app.rpc("debug.overlay_open_bench", {"release": True})
            wait_fewer_pages(app, made, "the released pages' processes to exit")
            report["memory"].append(memory(app, "after_release"))
            app.rpc("debug.overlay_open_bench", {"idle_limit_s": opts.idle_limit})
            bench(app, "icon_picker", "warm")
            bench(app, "group_editor", "warm")
            time.sleep(opts.idle_limit)  # sleep-ok: the app's own idle-limit timer (--idle-limit s) has to run out
            wait_fewer_pages(app, made, "the idle-limited pages' processes to exit")
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
