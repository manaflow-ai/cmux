#!/usr/bin/env python3
"""Cmd-Shift-Enter zoom on terminals, in a real window (Lawrence 2026-10-20: "laggy and buggy").

Launches a tagged cmux-next app (scratch config, empty Ghostty config) and, for each layout in --layouts
(1x2, 2x2, 2x4: columns x rows of terminals), fills every terminal with --scrollback lines, optionally
keeps output streaming in all of them (--stream), then zooms and unzooms the focused pane --rounds times
through the toggleSplitZoom action. Each zoom and unzoom is measured with:

  missed         display frames the main thread missed (`debug.frames`), and max / p99 frame interval
  layout_max_ms  the layout's longest main-thread work in one frame (`debug.motion` work.layout)
  grid_reports   terminal grid reports the views made (`debug.window_transition`); resizes_sent: grids
                 sent to the daemon, each a PTY resize, a shell redraw and a reflow at the owner
  hangs          main-thread hangs (`debug.hangs`)

Budget rows (always printed; they fail the run with --gate): a zoom or unzoom sends at most one grid per
terminal that changed size (the zoomed pane: 1), and misses no more than --missed-budget frames.

The app launches through bench_launch.BenchApp (the bench env and config, a fresh saved session, the GUI-session
check, the tag teardown); the app activates and its window is key, as before. The summary is the median over rounds
(scripts/perf-lab/perf_stats.py through motion_bench_report.median). With --story ID (stories.d pane-zoom) the run also
writes cmux-perf-result/v1 into --out through BenchApp.record: `panes.<zoom|unzoom>.<layout>.frame` (every frame
interval of the gesture, all rounds together), `.missed` and `.resizes_sent` (one value per gesture); a --story run
that writes no series fails.

Usage: pane-zoom-terminal.py --tag <tag> --app PATH [--layouts 1x2,2x2,2x4] [--rounds 3] [--scrollback 20000]
       [--stream] [--json PATH] [--out DIR] [--gate] [--story ID]
"""
import argparse, json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402  the shared GUI launch (session check, failure report)
import motion_bench_report  # noqa: E402  medians (perf_stats) and the result-v1 series

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--layouts", default="1x2,2x2,2x4")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--scrollback", type=int, default=20000)
parser.add_argument("--stream", action="store_true", help="keep output streaming in every terminal while zooming")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--gate", action="store_true", help="fail on the budget rows")
parser.add_argument("--missed-budget", type=int, default=2)
parser.add_argument("--story", help="the lab story (stories.d/<id>.json) to record result-v1 for; none: no result-v1")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"  # the launch's own socket once it answered (BenchApp.socket)
STORY = None
if opts.story:
    try:
        STORY = motion_bench_report.Story.load(opts.story, "none")  # terminals only
        STORY.check_sessions({"light"})
    except motion_bench_report.StoryError as error:
        parser.error(str(error))
ROWS = []
BENCH = None  # the BenchApp of this run


def rpc(method, params=None, timeout=30):
    import socket
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, settle=0.0, timeout=60):
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def feed():
    """Scrollback, then (with --stream) output that keeps coming, in the focused terminal."""
    text = f"seq 1 {opts.scrollback}\r" if opts.scrollback else ""
    if opts.stream:
        text += "while :; do echo \"$RANDOM $RANDOM $RANDOM streaming output line\"; sleep 0.004; done\r"
    if text:
        action("terminal.sendText", {"text": text})


def layout(columns, rows):
    """A fresh workspace of columns x rows terminals, each fed; ends focused on the top-left one."""
    action("workspace.newAtBottom", settle=1.5)
    feed()
    for _ in range(columns - 1):
        action("splitRight", settle=0.8)
        feed()
    for column in range(columns):
        for _ in range(rows - 1):
            action("splitDown", settle=0.8)
            feed()
        for _ in range(rows - 1):
            action("focusUp", settle=0.3)
        if column < columns - 1:
            action("focusLeft", settle=0.3)
    action("equalizeSplits", settle=0.8)
    for _ in range(columns):
        action("focusLeft", settle=0.2)
    time.sleep(2.0 if opts.scrollback else 0.5)  # test harness: seq fills the scrollback


def measure(label):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.window_transition", {"action": "start"})
    reply = action("toggleSplitZoom")
    time.sleep(1.2)  # test harness: the zoom spring lands (rest is under 0.5 s) and the PTY owner answers
    trace = rpc("debug.window_transition", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    # The display-link tick is the per-frame work MotionTrace measures ("clock"); layout.travel samples
    # above zero are the frames the layout springs moved in (no moving frame: the zoom never ran).
    work = (motion.get("work") or {}).get("clock", {}) if isinstance(motion, dict) else {}
    moving = sum(1 for s in (motion.get("samples") or []) if s.get("name") == "layout.travel" and (s.get("v") or 0) > 0) \
        if isinstance(motion, dict) else 0
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "label": label, "reply_error": reply.get("error") if isinstance(reply, dict) else None,
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"), "frames_p99_ms": frames.get("p99_ms"),
        "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"), "frames": frames.get("frames"),
        "moving_frames": moving,
        "refresh_ms": frames.get("refresh_ms"),
        "layout_max_ms": work.get("max_ms"), "layout_p95_ms": work.get("p95_ms"), "layout_p50_ms": work.get("p50_ms"),
        "layout_frames": work.get("frames"),
        "grid_reports": trace.get("terminal_grid_reports"), "resizes_sent": trace.get("terminal_resizes_sent"),
        "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count"),
        "frame_intervals_ms": motion_bench_report.frame_intervals(frames),  # result-v1's raw frame samples
    }
    print(f"  {label:<18} moved {moving} frames  frame p50 {result['frames_p50_ms']} p95 {result['frames_p95_ms']} "
          f"p99 {result['frames_p99_ms']} max {result['frames_max_ms']} ms missed {result['missed']}  "
          f"tick p50 {work.get('p50_ms')} p95 {work.get('p95_ms')} ms  grids {result['grid_reports']}/{result['resizes_sent']}  "
          f"err {result['reply_error']}", flush=True)
    print(f"  {label:<18} missed {result['missed']} max {result['frames_max_ms']} p99 {result['frames_p99_ms']} ms  "
          f"layout max {result['layout_max_ms']} p95 {result['layout_p95_ms']} ms  grids {result['grid_reports']}/"
          f"{result['resizes_sent']}  hangs {result['hangs']}", flush=True)
    return result


def cleanup():
    if os.environ.get("PANE_ZOOM_KEEP") or BENCH is None:
        return
    BENCH.stop()  # debug.quit with the sessions ended, then only this tag's processes and daemons (tag_teardown.py)


def main():
    global BENCH, SOCKET
    os.makedirs(opts.out, exist_ok=True)
    # The shared launch (bench_launch.py): the bench env and config, the session check, the state-folder socket and a
    # BENCH-LAUNCH report (crash, sample, log tail) on failure. CMUX_NEXT_NO_ACTIVATE stays unset, as this bench
    # always launched: the app activates and its window is key (an inactive app's terminals are unfocused).
    BENCH = BenchApp(APP, out=opts.out, config={}, env={"CMUX_NEXT_NO_ACTIVATE": None}, window=(80, 80, 1600, 1000),
                     screen=None, log_name=f"app-{TAG}.log")
    try:
        BENCH.launch(timeout=120)
    except LaunchError as error:
        print(str(error), flush=True)
        row("the tagged app came up", "its socket answers with a window", error.reason, False)
        return
    SOCKET = BENCH.socket
    print(f"launched pid {BENCH.process.pid} macOS "
          f"{subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}", flush=True)
    time.sleep(5)  # test harness: launch work settles
    report = {"tag": TAG, "stream": opts.stream, "scrollback": opts.scrollback, "runs": []}
    for name in opts.layouts.split(","):
        columns, rows = (int(v) for v in name.split("x"))
        layout(columns, rows)
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-before.png")})
        for index in range(opts.rounds):
            for direction in ("zoom", "unzoom"):
                run = measure(f"{name} {direction} #{index}")
                run.update(layout=name, direction=direction)
                report["runs"].append(run)
                if index == 0 and direction == "zoom":
                    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-zoomed.png")})
                row(f"{name} {direction} #{index}: the zoom animated (layout springs moved)", "> 0 frames",
                    str(run["moving_frames"]), run["moving_frames"] > 0)
                sent = run["resizes_sent"]
                row(f"{name} {direction} #{index}: grids sent to the PTY owner" + ("" if opts.gate else " (info)"),
                    "<= 1", str(sent), sent is not None and sent <= 1 or not opts.gate)
                missed = run["missed"]
                row(f"{name} {direction} #{index}: missed frames" + ("" if opts.gate else " (info)"),
                    f"<= {opts.missed_budget}", str(missed), missed is not None and missed <= opts.missed_budget or not opts.gate)
                time.sleep(0.5)  # test harness: idle between runs
        if opts.json:
            json.dump(report, open(opts.json, "w"), indent=1)
    print("\n== summary (median over rounds)")
    for name in opts.layouts.split(","):
        for direction in ("zoom", "unzoom"):
            runs = [r for r in report["runs"] if r["layout"] == name and r["direction"] == direction]

            def over_rounds(key):
                return motion_bench_report.median(r.get(key) for r in runs)
            print(f"  {name:<4} {direction:<6} moved {over_rounds('moving_frames')} frame p50 {over_rounds('frames_p50_ms')} "
                  f"p95 {over_rounds('frames_p95_ms')} ms  tick p50 {over_rounds('layout_p50_ms')} "
                  f"p95 {over_rounds('layout_p95_ms')} ms")
            print(f"  {name:<4} {direction:<6} missed {over_rounds('missed')} max {over_rounds('frames_max_ms')} "
                  f"p99 {over_rounds('frames_p99_ms')} ms  layout max {over_rounds('layout_max_ms')} ms  "
                  f"grids {over_rounds('grid_reports')}/{over_rounds('resizes_sent')}  hangs {over_rounds('hangs')}", flush=True)
    if STORY and report["runs"]:
        series, skipped = motion_bench_report.zoom_series(report["runs"], STORY)
        report["result_v1"] = motion_bench_report.record(BENCH, series, skipped)
        written = motion_bench_report.written_count(report["result_v1"])
        row(f"result-v1 written under story {STORY.id}", ">= 1 series", f"{written} series", written > 0)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


try:
    main()
except Exception:  # the step log is stdout only
    import traceback
    traceback.print_exc(file=sys.stdout)
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
