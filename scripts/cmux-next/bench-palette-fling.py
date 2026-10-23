#!/usr/bin/env python3
"""Command Palette fling bench (perf-lead row 23 test plan step 5: hover follows the pointer, no
dropped frames), with no real input.

A fleet worker has no Post Event (Accessibility) grant, so a harness that moves the real pointer
and posts wheel events measures nothing (cmux20, 2026-10-23: the pointer never moved, 0 of 12
flings valid). This bench asks the app to fling its own list instead: `debug.palette.fling`
scrolls the open palette's list a fixed distance on every display refresh, through the clip view
as a wheel scroll does, under a stand-in pointer that the list's hover hit test reads, and checks
on every frame that hover is on the row under that pointer.

Each run launches the tagged build the way bench-stalls.py does, from an empty session (the tag's
saved daemon session is removed first), optionally builds STRESS (perf-stress-session.py, in a
1600 x 1000 window), opens the Command Palette (Cmd-Shift-P's action) and runs --flings flings of
--frames refreshes at each --px speed.

Per session and speed:
  p50_ms / p95_ms / max_ms   main-thread frame intervals while the list scrolls
  long_frames                intervals over 1.5 refreshes (each one a refresh the list did not move)
  hover_misses               frames whose hovered row was not the row under the pointer (target 0)
  palette_renders            whole-palette renders the flings caused (target 0: a hover change
                             touches only the rows it moves between)
  work_p95_ms                the synchronous scroll + hit test + hover work per frame

A fling counts only when the list really moved and the reply names the display's rate. Judge
drops in frames at the reported refresh rate: a 60 Hz mini says nothing about 120 Hz.

  scripts/cmux-next/bench-palette-fling.py --tag mytag [--tag base] --runs 3 [--stress] [--json out.json]

Kills only the apps it launched. Exit 1 when a tag and speed has no valid fling.
"""
import argparse
import importlib.util
import json
import os
import shutil
import statistics
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STRESS_WINDOW_FRAME = "0,0,1600,1000"


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


def fling(run, frames, px, pointer):
    message = run.call("debug.palette.fling", {"frames": frames, "px": px, "pointer": pointer})
    error = message.get("error") if isinstance(message, dict) else repr(message)
    if error:
        return {"error": f"debug.palette.fling: {error}"}
    reply = message.get("result") or {}
    if "error" in reply:
        return {"error": reply["error"]}
    if not reply.get("scrolled_pt"):
        return {"error": "the list did not move (too few results to scroll)"}
    if not isinstance(reply.get("display_fps"), (int, float)):
        return {"error": "no display_fps: drops cannot be judged"}
    reply.pop("intervals_ms", None)
    return reply


def palette_open(run):
    reply = run.call("debug.palette.fling", {"frames": 1, "px": 0})
    result = reply.get("result") if isinstance(reply, dict) else None
    return isinstance(result, dict) and "error" not in result


def one_run(tag, opts):
    scratch = tempfile.mkdtemp(prefix=f"bench-palette-fling-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        json.dump({}, config)
    shutil.rmtree(os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui"), ignore_errors=True)
    extra_env = {"CMUX_NEXT_TEST_WINDOW_FRAME": STRESS_WINDOW_FRAME} if opts.stress else {}
    run = bench.Run(tag, opts.threshold_ms, scratch, extra_env=extra_env)
    run.launch()
    session = {"session": "STRESS" if opts.stress else "light"}
    try:
        run.wait_launch_settled()
        if opts.stress:
            module = load("perf_stress_session", "perf-stress-session.py")
            stress = module.Stress(module.socket_rpc(run.socket)).build()
            print(f"STRESS-SESSION {json.dumps(stress)}", flush=True)
            session["stress_standard"] = (stress.get("workspaces") == 60 and (stress.get("measured_panes") or 0) >= 12
                                          and not stress.get("refusals"))
        run.action("app command-palette")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not palette_open(run):
            time.sleep(0.1)  # bench poll for the panel, not app code
        results = []
        for px in opts.px:
            for index in range(opts.flings):
                reply = fling(run, opts.frames, px, opts.pointer)
                reply.update(session, px=px, fling=index + 1)
                results.append(reply)
        return results
    finally:
        bench.stop_tag(tag, run.pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--flings", type=int, default=4, help="flings per speed per launch")
    parser.add_argument("--frames", type=int, default=120, help="refreshes per fling (at most 180)")
    parser.add_argument("--px", type=float, action="append", help="points per refresh (default 24 and 60)")
    parser.add_argument("--pointer", type=float, default=0.5, help="pointer place, fraction of the list's height")
    parser.add_argument("--stress", action="store_true", help="build the STRESS session before opening the palette")
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    opts = parser.parse_args()
    opts.px = opts.px or [24.0, 60.0]
    print(f"load average {os.getloadavg()}", flush=True)
    results = {tag: [] for tag in opts.tag}
    for index in range(opts.runs):
        for tag in opts.tag:  # interleaved, so machine load affects every tag alike
            for reply in one_run(tag, opts):
                results[tag].append(reply)
                print(f"run {index + 1} {tag}: {json.dumps(reply)}", flush=True)
    failed = False
    session = "STRESS" if opts.stress else "light"
    for tag, replies in results.items():
        for px in opts.px:
            runs = [r for r in replies if r.get("px") == px]
            valid = [r for r in runs if "error" not in r]
            failed = failed or not valid
            print(f"\n{tag} px {px:g} ({session}): {len(valid)} of {len(runs)} flings valid")
            if not valid:
                continue
            print(f"  display_fps {sorted({r['display_fps'] for r in valid})}")
            if opts.stress and not all(r.get("stress_standard") for r in valid):
                print("  STRESS not the standard shape in some runs: see the STRESS-SESSION lines")
            for key in ("p50_ms", "p95_ms", "max_ms", "long_frames", "hover_misses", "palette_renders",
                        "hover_changes", "work_p95_ms", "scrolled_pt"):
                values = [r[key] for r in valid if isinstance(r.get(key), (int, float))]
                if values:
                    print(f"  {key:16} median {statistics.median(values):8.2f}  min {min(values):8.2f}  "
                          f"max {max(values):8.2f}  sum {sum(values):8.1f}")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(results, out, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
