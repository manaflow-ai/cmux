#!/usr/bin/env python3
"""WebKit page frame cadence bench (perf-lead row 23: every scroll at full refresh).

Each run launches the tagged build the way bench-stalls.py does (no activation, windows on the last
screen, a scratch cmux.json with `browser.defaultEngine: webkit`: a default build opens Settings,
History and Cloud in Chromium, where row 23 changes nothing), optionally builds the STRESS session
(perf-stress-session.py; its Chromium tabs name their engine, so STRESS keeps its shape), opens
the page, then reads the page's
own requestAnimationFrame intervals through `debug.page {action: frames}` while the page scrolls its
scroller a few pixels per frame:

  p50_ms / p95_ms / max_ms   rAF intervals pooled over every window of the run
  observed_fps               frames per second the page rendered
  long_frames                intervals over 1.5 display refreshes (each one a refresh not rendered)

A run counts only when the page reports engine webkit; the summary prints render_rate (`full` or
`near60`) and display_fps beside the numbers. On a 60 Hz display both rates read the same: judge
row 23 on a 120 Hz host (expected before: about 16.7 ms and long_frames on every interval; after:
about 8.3 ms and 0 long frames). Several tags run interleaved, so machine load affects them alike:

  scripts/cmux-next/bench-page-cadence.py --tag before --tag after --runs 3 [--stress] [--json out.json]

Kills only the apps it launched. Exit 1 when a tag never shows the page in WebKit.
"""
import argparse
import importlib.util
import json
import math
import os
import statistics
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    argv = sys.argv
    sys.argv = argv[:1]
    try:
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
    return module


bench = load("bench_stalls", "bench-stalls.py")


def poll(predicate, seconds=20, step=0.05):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench poll, not app code
    return None


def page_shown(run, page):
    state = run.result("debug.page", {"page": page})
    if isinstance(state, dict) and "error" not in state and state.get("painted"):
        return state
    return None


def nearest_rank(values, fraction):
    ordered = sorted(values)
    rank = max(1, min(len(ordered), math.ceil(fraction * len(ordered))))
    return ordered[rank - 1]


def one_run(tag, opts):
    scratch = tempfile.mkdtemp(prefix=f"bench-page-cadence-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        # From launch, so the pool's spare (Settings, History and Cloud open on it) is WebKit too.
        json.dump({"browser": {"defaultEngine": "webkit"}}, config)
    run = bench.Run(tag, opts.threshold_ms, scratch)
    run.launch()
    try:
        run.wait_launch_settled()
        stress = None
        if opts.stress:
            module = load("perf_stress_session", "perf-stress-session.py")
            stress = module.Stress(module.socket_rpc(run.socket)).build()
            print(f"STRESS-SESSION {json.dumps(stress)}", flush=True)
        run.call("action.run", {"action": opts.open_action, "focus": True})
        state = poll(lambda: page_shown(run, opts.page))
        if not state:
            return {"error": f"{opts.page} never painted"}
        time.sleep(1.0)  # let the page's first frames and pool refills finish before the windows
        intervals, replies = [], []
        for _ in range(opts.windows):
            params = {"page": opts.page, "action": "frames", "window_ms": opts.window_ms, "scroll_px": opts.scroll_px}
            if opts.selector:
                params["selector"] = opts.selector
            reply = run.result("debug.page", params)
            if not isinstance(reply, dict) or "error" in reply:
                return {"error": f"frames: {reply}"}
            replies.append(reply)
            intervals.extend(v for v in reply.get("intervals_ms") or [] if isinstance(v, (int, float)))
        first = replies[0]
        fps = first.get("display_fps")
        limit = 1.5 * 1000 / fps if fps else None
        metrics = {
            "engine": first.get("engine"), "render_rate": first.get("render_rate"), "display_fps": fps,
            "session": "STRESS" if stress else "light", "frames": len(intervals),
            "observed_fps": round(len(intervals) * 1000 / sum(intervals), 1) if intervals else None,
            "p50_ms": round(nearest_rank(intervals, 0.5), 2) if intervals else None,
            "p95_ms": round(nearest_rank(intervals, 0.95), 2) if intervals else None,
            "max_ms": round(max(intervals), 2) if intervals else None,
            "long_frames": sum(1 for v in intervals if limit and v > limit),
        }
        if metrics["engine"] != "webkit":
            metrics["error"] = "the page is not WebKit: this run measures nothing for row 23"
        return metrics
    finally:
        bench.stop_tag(tag, run.pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--page", default="cmux.settings")
    parser.add_argument("--open-action", default="openSettings")
    parser.add_argument("--selector", help="the CSS selector of the scroller (default: the document's)")
    parser.add_argument("--scroll-px", type=float, default=4)
    parser.add_argument("--window-ms", type=float, default=1000)
    parser.add_argument("--windows", type=int, default=5)
    parser.add_argument("--stress", action="store_true", help="build the STRESS session before opening the page")
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    opts = parser.parse_args()
    print(f"load average {os.getloadavg()}", flush=True)
    results = {tag: [] for tag in opts.tag}
    for index in range(opts.runs):
        for tag in opts.tag:  # interleaved, so machine load affects every tag alike
            metrics = one_run(tag, opts)
            results[tag].append(metrics)
            print(f"run {index + 1} {tag}: {json.dumps(metrics)}", flush=True)
    failed = False
    for tag, runs in results.items():
        valid = [r for r in runs if "error" not in r]
        failed = failed or not valid
        print(f"\n{tag} ({opts.page}, {'STRESS' if opts.stress else 'light'}): {len(valid)} of {len(runs)} runs valid")
        if valid:
            print(f"  render_rate {sorted({r['render_rate'] for r in valid})}  display_fps {sorted({r['display_fps'] for r in valid})}")
        for key in ("p50_ms", "p95_ms", "max_ms", "observed_fps", "long_frames"):
            values = [r[key] for r in valid if isinstance(r.get(key), (int, float))]
            if values:
                print(f"  {key:14} median {statistics.median(values):8.2f}  min {min(values):8.2f}  max {max(values):8.2f}")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(results, out, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
