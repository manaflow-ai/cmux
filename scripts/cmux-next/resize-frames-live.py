#!/usr/bin/env python3
"""Live-resize frame-time bench on the GUI host (Leo, cosmic-gray 2026-10-13).

  resize-frames-live.py --app APP|--tag <tag> --out DIR [--steps 150] [--sample] [--story window-live-resize]

Launches the tagged app through bench_launch.BenchApp (the bench env: no activation, automation socket, an empty
cmux.json, a fresh saved session, the tag's daemons ended after), opens a layout with the sidebar, a terminal and a
New Tab page (a web view) side by side, then live-resizes the window: the bottom-right corner pressed and dragged
one `debug.mouse` event per 120 Hz frame (`--steps` events per drag), out by 300 x 150 points and back, twice.
AppKit's own resize tracking reads the events (`inLiveResize` holds) and the user's pointer never moves.
`debug.frames` records display-link intervals throughout. Reports frame intervals (p50, p95, p99, max, missed
vsyncs) and each event's round trip, which waits for the main thread; `--sample` also runs `sample` on the app
(sample.txt). With --story it also writes the raw samples as cmux-perf-result/v1 (resize_bench_report.py).
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import BenchApp  # noqa: E402
import resize_bench_report as results  # noqa: E402

START = (80, 80, 1100, 720)


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app bundle (default $NX_APP)")
    parser.add_argument("--tag", help="find the app of this tag in DerivedData when --app is not given")
    parser.add_argument("--out", required=True)
    parser.add_argument("--steps", type=int, default=150)
    parser.add_argument("--sample", action="store_true")
    parser.add_argument("--story", help=f"write result-v1 under this story ({results.WINDOW_STORY})")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    opts = parser.parse_args(argv)
    opts.app = results.tagged_app(opts.app, opts.tag)
    if not opts.app:
        parser.error("name the tagged app with --app (or $NX_APP), or a --tag a tagged reload built")
    problem = opts.story and results.story_problem(opts.story, "webkit", "light")
    if problem:
        parser.error(problem)
    return opts


def measure(bench, opts, report, samples):
    """The setup and the four drags; fills `report` (the report keys) and `samples` (the raw values for result-v1)."""
    rpc = bench.rpc

    def focused_pane():
        windows = (rpc("debug.focus") or {}).get("windows") or [{}]
        return windows[0].get("layout_focused_pane")

    def size():
        layers = ((rpc("debug.layers") or {}).get("windows") or [{}])[0]
        return layers.get("frame")

    time.sleep(2)  # bench script: the first window settles
    report["identify"] = rpc("system.identify")
    # Sidebar shown, a terminal workspace, and a New Tab page (a web view) split beside it.
    report["setup"] = [rpc("action.run", {"action": "newTab", "focus": True})]
    time.sleep(2)  # bench script: the workspace's terminal starts
    pane = focused_pane()
    report["setup"].append(rpc("action.run", {"action": "splitRight", "focus": True,
                                              "target": f"pane:{pane}" if pane else None}))
    time.sleep(1.5)  # bench script: the split lands
    pane = focused_pane()
    report["setup"].append(rpc("action.run", {"action": "newTab.page", "focus": True,
                                              "target": f"pane:{pane}" if pane else None}))
    time.sleep(4)  # bench script: the page loads

    sampler = None
    if opts.sample:
        sampler = subprocess.Popen(["/usr/bin/sample", str(bench.process.pid), "8", "1",
                                    "-file", os.path.join(opts.out, "sample.txt")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)  # bench script: sample attaches before the drags

    rpc("debug.frames", {"action": "start"})
    # A live resize at the pace of a real drag: the bottom-right corner pressed once, then one
    # `debug.mouse` drag event per 120 Hz frame (press and release held open), out by 300 x 150
    # points and back, twice. AppKit's own resize tracking reads them (inLiveResize); the top-left
    # corner stays put, so window-local points from the top-left are the pointer's screen offsets.
    rounds, latencies, period = samples["rounds"], samples["latencies"], 1 / 120
    for out in (True, False, True, False):
        before = size()
        if not before:
            break  # no window frame: nothing to drag (a not-resized round in the results)
        w, h = before[2], before[3]
        dx, dy = (300, 150) if out else (-300, -150)
        x0, y0 = w - 1, h - 1
        rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
        started = time.monotonic()
        for step in range(1, opts.steps + 1):
            t = step / opts.steps
            x, y = x0 + dx * t, y0 + dy * t
            t0 = time.monotonic()
            rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False,
                                "release": False})
            latencies.append((time.monotonic() - t0) * 1000)
            next_at = started + step * period
            if next_at > time.monotonic():
                time.sleep(next_at - time.monotonic())  # bench script: one drag event per 120 Hz frame
        rpc("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
        time.sleep(0.5)  # bench script: the resize ends
        rounds.append({"before": before, "after": size(), "wall_s": round(time.monotonic() - started, 2)})
    report["frames"], samples["frames"] = results.split_raw_frames(rpc("debug.frames", {"action": "stop", "raw": True}))
    if sampler:
        sampler.wait(60)
    resized = bool(rounds) and all(r["before"] and r["after"] and r["before"][2] != r["after"][2] for r in rounds)
    report["steps"] = {"rounds": rounds, "resized": resized, "events": len(latencies),
                       "event_rpc_ms": results.event_rpc_block(latencies)}
    print(json.dumps({"steps": report["steps"], "frames": report["frames"]}, indent=1), flush=True)


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    bench = BenchApp(opts.app, out=opts.out, config={}, window=START, screen="last", log_name="app.log",
                     build_config=opts.build_config)
    report = {"tag": bench.tag, "pid": None}
    samples = {"rounds": [], "latencies": [], "frames": {}}
    try:
        bench.launch(timeout=120)  # ready once debug.windows lists a window
        report["pid"] = bench.process.pid
        measure(bench, opts, report, samples)
    finally:
        bench.stop()
        with open(os.path.join(opts.out, "report.json"), "w") as f:
            json.dump(report, f, indent=1)
    if not opts.story:
        return 0
    problems = results.record(bench, results.window_resize_series(
        opts.story, samples["frames"], samples["latencies"], samples["rounds"], report["frames"].get("missed")))
    for problem in problems:
        print(f"RESULT-V1 FAIL {problem}", flush=True)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
