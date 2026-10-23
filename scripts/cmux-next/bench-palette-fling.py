#!/usr/bin/env python3
"""Palette fling bench (perf-lead row 23 (2a): every scroll at full refresh). Test harness only.

Launches the tagged build the way bench-stalls.py does (no activation, windows on the last screen),
optionally builds the STRESS session (perf-stress-session.py), opens Cmd-Shift-P (`commandPalette`),
puts the real pointer over the palette's list and keeps it still, then posts real trackpad flings at
the window server (palette-fling-input.swift: a continuous gesture at the display's rate, then its
momentum). Around each fling `debug.frames` records the app's display-link intervals, the main
thread's busy time per frame, and the view layouts and window layout passes per frame.

Hover follows the pointer: the list re-hit-tests hover on every scroll tick. After each fling the
bench writes `debug.palette.capture` PNGs (before and after) so a reviewer can see the hovered row is
the row under the pointer (the pointer's offset in the panel is in the report), and the two images
must differ (the list moved: the input reached the app).

Per fling: refresh_ms, frames, missed (intervals over 1.5 refreshes), p50/p95/max, main_p95_ms,
view_layouts (sum and max per frame), window_layouts. A run is invalid when the capture did not
change (no scroll reached the app) or the display reports no refresh.

  scripts/cmux-next/bench-palette-fling.py --tag mytag [--flings 6] [--stress] [--out DIR] [--json out.json]

Kills only the app it launched. Exit 1 when no fling is valid.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
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


def palette_window(run):
    listing = run.result("debug.window_list") or {}
    windows = [w for w in listing.get("windows") or [] if w.get("visible")]
    for w in windows:
        text = f"{w.get('kind')} {w.get('class')}".lower()
        if "palette" in text:
            return w
    return None


def capture(run, path):
    reply = run.result("debug.palette.capture", {"path": path})
    if not isinstance(reply, dict) or "error" in reply:
        return None, reply
    with open(path, "rb") as image:
        return hashlib.sha256(image.read()).hexdigest()[:16], reply


def compile_input(out):
    binary = os.path.join(out, "palette-fling-input")
    source = os.path.join(HERE, "palette-fling-input.swift")
    subprocess.run(["swiftc", "-O", "-o", binary, source], check=True)
    return binary


def fling(binary, x, y, dy, hz, move_only=False):
    cmd = [binary, "--x", str(x), "--y", str(y), "--appkit-y", "--dy", str(dy), "--hz", str(hz)]
    if move_only:
        cmd.append("--move-only")
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(done.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": done.stdout[-300:] + done.stderr[-300:]}


def one_run(tag, opts, binary):
    scratch = tempfile.mkdtemp(prefix=f"bench-palette-fling-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        json.dump({}, config)
    run = bench.Run(tag, opts.threshold_ms, scratch)
    run.launch()
    session = "STRESS" if opts.stress else "light"
    report = {"tag": tag, "session": session, "flings": []}
    try:
        run.wait_launch_settled()
        if opts.stress:
            module = load("perf_stress_session", "perf-stress-session.py")
            stress = module.Stress(module.socket_rpc(run.socket)).build()
            print(f"STRESS-SESSION {json.dumps(stress)}", flush=True)
            report["stress"] = stress
        report["cef"] = run.result("debug.cef")
        run.call("action.run", {"action": "commandPalette", "focus": True})
        panel = poll(lambda: palette_window(run))
        if not panel:
            report["error"] = "the palette never showed"
            return report
        time.sleep(0.5)  # the palette's open motion and first ranking finish before input
        frame = panel["frame"]
        # The pointer: horizontally centered, 60 % down the panel (the list, below the search bar).
        px = frame["x"] + frame["width"] / 2
        py = frame["y"] + frame["height"] * 0.4
        report["panel"] = panel
        report["pointer_in_panel_from_top"] = [round(frame["width"] / 2, 1), round(frame["height"] * 0.6, 1)]
        report["move"] = fling(binary, px, py, 0, opts.hz, move_only=True)
        time.sleep(0.3)
        for index in range(opts.flings):
            dy = -opts.dy if index % 2 == 0 else opts.dy  # down, then back up
            before_path = os.path.join(opts.out, f"{tag}-{session}-fling{index + 1}-before.png")
            after_path = os.path.join(opts.out, f"{tag}-{session}-fling{index + 1}-after.png")
            before, before_reply = capture(run, before_path)
            time.sleep(0.2)  # the capture's own layout and display finish before the frames window
            run.result("debug.frames", {"action": "start"})
            sent = fling(binary, px, py, dy, opts.hz)
            time.sleep(0.3)  # the momentum's last frames land in the window
            stats = run.result("debug.frames", {"action": "stop", "raw": True})
            after, after_reply = capture(run, after_path)
            entry = {"fling": index + 1, "dy": dy, "input": sent}
            keep = ("refresh_ms", "frames", "missed", "missed_at_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms",
                    "main_p50_ms", "main_p95_ms", "main_max_ms", "main_over_8_3_ms", "view_layouts", "view_layouts_max",
                    "window_layouts")
            entry.update({k: stats.get(k) for k in keep} if isinstance(stats, dict) else {"frames_error": stats})
            if isinstance(stats, dict):
                per = stats.get("view_layouts_per_frame") or []
                entry["frames_with_view_layouts"] = sum(1 for v in per if v)
            entry["captures"] = {"before": before_path if before else before_reply,
                                 "after": after_path if after else after_reply,
                                 "selected_after": after_reply.get("selected") if isinstance(after_reply, dict) else None}
            if not before or not after:
                entry["error"] = "no palette capture"
            elif before == after:
                entry["error"] = "the palette did not change: the fling never reached the app"
            elif not (isinstance(stats, dict) and stats.get("refresh_ms")):
                entry["error"] = "no refresh_ms: drops cannot be judged"
            report["flings"].append(entry)
            print(f"{tag} {session} fling {index + 1}: {json.dumps(entry)}", flush=True)
            time.sleep(0.3)
        return report
    finally:
        bench.stop_tag(tag, run.pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--flings", type=int, default=6)
    parser.add_argument("--dy", type=float, default=40, help="points per gesture event before momentum")
    parser.add_argument("--hz", type=float, default=120, help="input event rate (the display's rate)")
    parser.add_argument("--stress", action="store_true")
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--out", default=tempfile.mkdtemp(prefix="bench-palette-fling-"))
    parser.add_argument("--json")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    binary = compile_input(opts.out)
    print(f"load average {os.getloadavg()}", flush=True)
    reports = [one_run(tag, opts, binary) for tag in opts.tag]
    failed = False
    for report in reports:
        valid = [f for f in report["flings"] if "error" not in f]
        failed = failed or not valid
        print(f"\n{report['tag']} ({report['session']}): {len(valid)} of {len(report['flings'])} flings valid"
              f"{'; ' + report['error'] if report.get('error') else ''}")
        for f in valid:
            print(f"  fling {f['fling']}: refresh {f['refresh_ms']:.2f} ms  frames {f['frames']}  missed {f['missed']}"
                  f"  p95 {f['p95_ms']:.2f}  max {f['max_ms']:.2f}  main_p95 {f['main_p95_ms']:.2f}"
                  f"  view_layouts {f['view_layouts']} (max {f['view_layouts_max']}/frame)  window_layouts {f['window_layouts']}")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(reports, out, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
