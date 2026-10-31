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

Usage: pane-zoom-terminal.py --tag <tag> --app PATH [--layouts 1x2,2x2,2x4] [--rounds 3] [--scrollback 20000]
       [--stream] [--json PATH] [--out DIR] [--gate]
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, time

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
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"pane-zoom-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ROWS, LAUNCHED = [], []
app = None


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


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


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
    frames = rpc("debug.frames", {"action": "stop"}) or {}
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
    if os.environ.get("PANE_ZOOM_KEEP") or not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "80,80,1600,1000"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    print(f"launched pid {app.pid} macOS {subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}",
          flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        # The step log is stdout only: say why here, with the app's own log.
        print(f"the tagged app did not come up: socket {SOCKET} exists={os.path.exists(SOCKET)} "
              f"debug.windows={rpc('debug.windows')} alive={app.poll() is None}", flush=True)
        log.flush()
        print(open(os.path.join(opts.out, f"app-{TAG}.log"), errors="replace").read()[-6000:], flush=True)
        sys.exit(1)
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

            def med(key):
                values = sorted(v for v in (r.get(key) for r in runs) if v is not None)
                return values[len(values) // 2] if values else None
            print(f"  {name:<4} {direction:<6} moved {med('moving_frames')} frame p50 {med('frames_p50_ms')} "
                  f"p95 {med('frames_p95_ms')} ms  tick p50 {med('layout_p50_ms')} p95 {med('layout_p95_ms')} ms")
            print(f"  {name:<4} {direction:<6} missed {med('missed')} max {med('frames_max_ms')} p99 {med('frames_p99_ms')} ms  "
                  f"layout max {med('layout_max_ms')} ms  grids {med('grid_reports')}/{med('resizes_sent')}  "
                  f"hangs {med('hangs')}", flush=True)
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
