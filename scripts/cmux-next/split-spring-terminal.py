#!/usr/bin/env python3
"""Rapid Cmd-D and Cmd-Shift-D on terminals, in a real window (Lawrence 2026-10-20: "when I do Command-D
multiple times, the animation is not perfectly fluid and smooth ... buttery, perfectly smooth").

Launches a tagged cmux-next app (scratch config, empty Ghostty config). Each round opens a fresh workspace
with one terminal filled with --scrollback lines (optionally streaming, --stream), then presses the split
--presses times, --interval ms apart, through the splitRight (or splitDown) action, and measures the whole
gesture until the panes rest:

  missed         display frames the main thread missed (`debug.frames`), and max / p99 frame interval
  layout_max_ms  the layout's longest main-thread work in one frame (`debug.motion` clock)
  grid_reports   terminal grid reports the views made (`debug.window_transition`); resizes_sent: grids
                 sent to the daemon, each a PTY resize, a shell redraw and a reflow at the owner
  hangs          main-thread hangs (`debug.hangs`)

Budget rows (printed; they fail the run with --gate): no missed frame beyond --missed-budget, and at most
one grid per terminal of the row (presses + 1) for the whole gesture.

With --suite=pane-perf it runs scripts/cmux-next/pane-perf-terminal.py instead (split, close, New Column, zoom
and a divider drag in 2, 8 and 30 pane layouts; the controller allowlists this entry, not pane-perf.sh yet).
With --suite=app-perf it runs scripts/cmux-next/app-perf.py the same way (app gestures at 10 and 50 workspaces).
With --suite=anim-perf it runs scripts/cmux-next/anim-perf-terminal.py (tab, workspace, sidebar, group, Home
and palette animations at a 120 Hz frame budget).

Usage: split-spring-terminal.py --tag <tag> --app PATH [--rounds 3] [--presses 5] [--interval 100]
       [--directions right,down] [--scrollback 20000] [--stream] [--json PATH] [--out DIR] [--gate]
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, time

# `--suite=pane-perf` (through the allowlisted fleet entry scripts/measure/split-spring.sh): the whole pane
# motion suite instead, scripts/cmux-next/pane-perf-terminal.py, with the same --tag/--app/--out/--json.
# `--suite=budgets`: every perf budget row, scripts/cmux-next/perf-budgets.py (one table, one gate).
if "--suite=plo" in sys.argv:
    os.execv(sys.executable, [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "pl_o_all_check.py")] + [a for a in sys.argv[1:] if a != "--suite=plo"])
if "--suite=budgets" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-budgets.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=budgets"])
if "--suite=pane-perf" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pane-perf-terminal.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=pane-perf"])
# `--suite=app-perf`, the same way: scripts/cmux-next/app-perf.py (Cmd-D, Cmd-Shift-D, the side pane, the sidebar, a new
# workspace at the top and workspace switches, at 10 and 50 workspaces; app-efficiency 2026-10-21).
if "--suite=app-perf" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app-perf.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=app-perf"])
# `--suite=anim-perf`: every other app animation (tabs, workspace switch, sidebars, groups, Home, palette),
# scripts/cmux-next/anim-perf-terminal.py, budgets in scripts/perf-bench/budgets.json (animations).
# `--suite=sidebar-churn`: terminal typing idle and while the sidebar rearranges, scripts/cmux-next/sidebar-churn-typing.py.
if "--suite=sidebar-churn" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sidebar-churn-typing.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=sidebar-churn"])
# `--suite=pane-bench`: the layout's own pane motion benches, no app window (PaneMotionBench: frame time of
# split/close/New Column/zoom at 2, 8 and 30 panes; PaneMotionWorkTests: panes touched per frame). Run
# yourself (perf lead, not a CI gate); --config=release|debug picks the build (default release).
if "--suite=pane-bench" in sys.argv:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or "."
    config = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--config=")), "release")
    env = dict(os.environ, CMUX_PANE_BENCH="1", CMUX_SWIFT_SUITE_CONFIGURATION=config)
    sys.exit(subprocess.run([os.path.join(root, "scripts/ci/package-test-lane.sh"), "suite", "Packages/macOS/CmuxNext",
                             "PaneMotionWorkTests,PaneMotionBench"], cwd=root, env=env).returncode)
if "--suite=anim-perf" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "anim-perf-terminal.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=anim-perf"])
# `--suite=perf-gate`: the perf counter gate, scripts/cmux-next/perf-gate.py, which the perf cron
# (scripts/cmux-next/perf-cron.py) runs on a fleet GUI host since it left the push and pull request CI
# (2026-10-23). perf-gate.py takes no --tag or --json: it reads the tag from the app and writes <out>/perf-gate.json.
# The step passes whenever that report was written (a broken counter budget is in the report, and a fleet step
# returns its artifact only when it passes); it fails only when the gate wrote no report.
if "--suite=perf-gate" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-gate.py")
    rest, skip, out = [], False, None
    for i, a in enumerate(sys.argv[1:], 1):
        if skip:
            skip = False
        elif a in ("--tag", "--json"):
            skip = True
        elif a != "--suite=perf-gate" and not a.startswith(("--tag=", "--json=")):
            rest.append(a)
            if a == "--out" and i + 1 < len(sys.argv):
                out = sys.argv[i + 1]
    code = subprocess.call([sys.executable, suite] + rest)
    report_path = os.path.join(out or "/tmp/cmux-next-perf-gate", "perf-gate.json")
    print(f"split-spring --suite=perf-gate: perf-gate.py exited {code}; report {report_path}"
          f"{'' if os.path.exists(report_path) else ' (missing)'}", flush=True)
    sys.exit(0 if os.path.exists(report_path) else (code or 1))
# `--suite=launch`: launch time, scripts/cmux-next/bench-startup.py (the launch-time budget that left the pull request
# CI, 2026-10-23). bench-startup.py takes the app's tag from --app, so --tag and --out are dropped; --json stays.
# The step passes whenever the JSON was written (an over-budget launch is in it).
if "--suite=launch" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-startup.py")
    rest, skip, report_path = [], False, None
    for i, a in enumerate(sys.argv[1:], 1):
        if skip:
            skip = False
        elif a in ("--tag", "--out"):
            skip = True
        elif a != "--suite=launch" and not a.startswith(("--tag=", "--out=")):
            rest.append(a)
            if a == "--json" and i + 1 < len(sys.argv):
                report_path = sys.argv[i + 1]
    code = subprocess.call([sys.executable, suite] + rest)
    ok = bool(report_path) and os.path.exists(report_path)
    print(f"split-spring --suite=launch: bench-startup.py exited {code}; report {report_path}{'' if ok else ' (missing)'}", flush=True)
    sys.exit(0 if ok else (code or 1))

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--presses", type=int, default=5)
parser.add_argument("--interval", type=int, default=100, help="ms between presses")
parser.add_argument("--directions", default="right,down")
parser.add_argument("--scrollback", type=int, default=20000)
parser.add_argument("--stream", action="store_true", help="keep output streaming in the first terminal")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--gate", action="store_true", help="fail on the budget rows")
parser.add_argument("--missed-budget", type=int, default=0)
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"split-spring-{TAG}-")
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


def fresh():
    """A fresh workspace with one fed terminal, focused."""
    action("workspace.newAtBottom", settle=1.5)
    text = f"seq 1 {opts.scrollback}\r" if opts.scrollback else ""
    if opts.stream:
        text += "while :; do echo \"$RANDOM $RANDOM $RANDOM streaming output line\"; sleep 0.004; done\r"
    if text:
        action("terminal.sendText", {"text": text})
    time.sleep(2.0 if opts.scrollback else 0.5)  # test harness: seq fills the scrollback


def measure(label, verb):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.window_transition", {"action": "start"})
    errors = []
    start = time.time()
    for press in range(opts.presses):
        # A person's rhythm: each press at its slot, however long the one before took to answer.
        delay = start + press * opts.interval / 1000 - time.time()
        if delay > 0:
            time.sleep(delay)  # test harness: presses opts.interval ms apart
        reply = rpc("action.run", {"action": verb, "args": {}, "focus": True, "origin": "script"}, timeout=30)
        if isinstance(reply, dict) and reply.get("error"):
            errors.append(str(reply.get("error")))
    time.sleep(1.5)  # test harness: the split spring lands (rest is under 0.5 s) and the PTY owner answers
    trace = rpc("debug.window_transition", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    work = (motion.get("work") or {}).get("clock", {}) if isinstance(motion, dict) else {}
    moving = sum(1 for s in (motion.get("samples") or []) if s.get("name") == "layout.travel" and (s.get("v") or 0) > 0) \
        if isinstance(motion, dict) else 0
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "label": label, "errors": errors,
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"), "frames_p99_ms": frames.get("p99_ms"),
        "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"), "frames": frames.get("frames"),
        "moving_frames": moving, "refresh_ms": frames.get("refresh_ms"),
        "layout_max_ms": work.get("max_ms"), "layout_p95_ms": work.get("p95_ms"), "layout_p50_ms": work.get("p50_ms"),
        "grid_reports": trace.get("terminal_grid_reports"), "resizes_sent": trace.get("terminal_resizes_sent"),
        "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count"),
    }
    print(f"  {label:<14} moved {moving} frames  frame p50 {result['frames_p50_ms']} p99 {result['frames_p99_ms']} "
          f"max {result['frames_max_ms']} ms missed {result['missed']} (refresh {result['refresh_ms']} ms)  "
          f"layout p95 {result['layout_p95_ms']} max {result['layout_max_ms']} ms  grids {result['grid_reports']}/"
          f"{result['resizes_sent']}  hangs {result['hangs']}  errors {errors}", flush=True)
    return result


def cleanup():
    if os.environ.get("SPLIT_SPRING_KEEP") or not LAUNCHED:
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
    report = {"tag": TAG, "stream": opts.stream, "scrollback": opts.scrollback, "presses": opts.presses,
              "interval_ms": opts.interval, "runs": []}
    for direction in opts.directions.split(","):
        verb = {"right": "splitRight", "down": "splitDown"}[direction]
        for index in range(opts.rounds):
            fresh()
            run = measure(f"{direction} #{index}", verb)
            run.update(direction=direction)
            report["runs"].append(run)
            if index == 0:
                rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{direction}-after.png")})
            row(f"{direction} #{index}: the splits animated (layout springs moved)", "> 0 frames",
                str(run["moving_frames"]), run["moving_frames"] > 0)
            row(f"{direction} #{index}: every press split", "no refusal", str(run["errors"]), not run["errors"])
            sent, budget = run["resizes_sent"], opts.presses + 1
            row(f"{direction} #{index}: grids sent to the PTY owner" + ("" if opts.gate else " (info)"),
                f"<= {budget}", str(sent), sent is not None and sent <= budget or not opts.gate)
            missed = run["missed"]
            row(f"{direction} #{index}: missed frames" + ("" if opts.gate else " (info)"),
                f"<= {opts.missed_budget}", str(missed), missed is not None and missed <= opts.missed_budget or not opts.gate)
            if opts.json:
                json.dump(report, open(opts.json, "w"), indent=1)
            time.sleep(0.5)  # test harness: idle between runs
    print("\n== summary (median over rounds)")
    for direction in opts.directions.split(","):
        runs = [r for r in report["runs"] if r["direction"] == direction]

        def med(key):
            values = sorted(v for v in (r.get(key) for r in runs) if v is not None)
            return values[len(values) // 2] if values else None
        print(f"  {direction:<5} x{opts.presses} moved {med('moving_frames')} frame p50 {med('frames_p50_ms')} p99 "
              f"{med('frames_p99_ms')} max {med('frames_max_ms')} ms missed {med('missed')}  layout p95 {med('layout_p95_ms')} "
              f"max {med('layout_max_ms')} ms  grids {med('grid_reports')}/{med('resizes_sent')}  hangs {med('hangs')}", flush=True)
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
