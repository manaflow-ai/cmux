#!/usr/bin/env python3
"""Does every pane move as one? Per-pane frame timing of the layout motions, in a real window (one-motion,
Leo 2026-11-05: "the right pane shifts and then the main pane waits for the right pane to shift before it shifts.
Like, why are you waiting? If we had a proper animation system, everything moves as one").

Launches a tagged cmux-next app with the mock agent pane, opens an agent chat in a workspace's pane (the main pane)
and runs each motion below with `debug.motion` `trace_start` (every display frame: the sidebar's width, every pane
host's frame and its content view's laid-out frame, each terminal surface and each Chromium page) and, with
--record, `record_start` (the window as composited, a movie per motion):

  sidebar-hide / sidebar-show     toggleSidebar (Cmd-B)
  split-right / split-close       splitRight (Cmd-D) beside the chat, then closePane on the new pane
  b-then-d / b-then-d-undo        toggleSidebar then splitRight --gap ms later (Leo's Cmd-B, Cmd-D), then both undone
  right-open / right-close        toggleRightSidebar

Per motion and per mover (the sidebar, each pane's frame, each pane's laid-out content, each terminal surface, each
page), the report gives when it first moved and when it last moved, in ms from the action and in display frames, so
"all panes start and end together" is a row of numbers: `spread_start_ms` and `spread_end_ms` are the largest
difference between two movers. `lag_ms`: how long after its pane's frame landed the pane's content was still
changing (a held content laying out after the landing shows here). Written to --out/one-motion.json, with the
raw traces beside it (trace-<motion>.json), the movies (<motion>.mov) when recorded, and an SVG progress timeline per
motion (<motion>.svg, one_motion_plot.py). Everything goes to --out/one-motion/; --bundle packs it as one file.

Usage: one-motion-trace.py --tag <tag> --app PATH [--motions a,b] [--rounds 1] [--gap 120] [--content chat|terminal]
       [--record] [--bundle] [--out DIR] [--json PATH]
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA
       --arg=--suite=one-motion --arg=--record --arg=--bundle --artifact artifacts/split-spring/one-motion.tar.gz
"""
import argparse, glob, json, os, signal, subprocess, sys, tarfile, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import LaunchError, launch_app  # noqa: E402
import one_motion_plot  # noqa: E402
from one_motion_series import summarize  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--motions", default="")
parser.add_argument("--rounds", type=int, default=1)
parser.add_argument("--gap", type=int, default=120, help="ms between Cmd-B and Cmd-D in b-then-d")
parser.add_argument("--record", action="store_true", help="record each motion's window as a movie (debug.motion record_*)")
parser.add_argument("--rows", type=int, default=5000, help="transcript rows seeded into the chat (a long transcript)")
parser.add_argument("--frame-rounds", type=int, default=3, help="untraced repeats of each motion for frame drops and main-thread work")
parser.add_argument("--content", default="chat", choices=("chat", "terminal"), help="what the main pane shows")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--bundle", action="store_true", help="also pack the run's folder as --out/one-motion.tar.gz (a fleet step returns one file)")
opts, _unknown = parser.parse_known_args()
# The run's own folder: split-spring.sh's --out also holds the built app.
OUT = os.path.join(opts.out, "one-motion")
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix=f"one-motion-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
WINDOW = (80, 80, 1500, 900)
TARGETS = ["sidebar", "panes", "dividers", "terminal", "page", "window"]
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
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, settle=0.0, target=None):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    reply = rpc("action.run", params, timeout=60)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def error_of(reply):
    return str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None


def wait(check, seconds, step=0.2):
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


def topology():
    return (rpc("snapshot.get") or {}).get("topology") or {}


def shown_panes():
    """[(pane id, [tab kind, ...])] of the shown workspace."""
    top = topology()
    shown = (top.get("focus") or {}).get("workspace")
    for w in top.get("workspaces") or []:
        if w.get("id") == shown:
            return [(p.get("id"), [t.get("kind") or t.get("type") for t in p.get("tabs") or []])
                    for s in w.get("screens") or [] for p in s.get("panes") or []]
    return []


def setup():
    action("workspace.newAtBottom", settle=1.5)
    if opts.content == "chat":
        opened = action("palette.newAgentChat", settle=1.0)
        ready = wait(lambda: (lambda r: r if isinstance(r, dict) and "error" not in r else None)(
            rpc("debug.agent_pane", {"action": "readiness"}, timeout=30)), 30, 0.5)
        print(f"chat opened {json.dumps(opened)[:200]} ready {bool(ready)}", flush=True)
        # One pane showing the chat: a chat that opened in a column of its own leaves the terminal's pane beside it.
        for _ in range(3):
            panes = shown_panes()
            if len(panes) <= 1:
                break
            terminal = next((p for p, kinds in panes if kinds and all(k in ("pty", "terminal") for k in kinds)), None)
            if not terminal:
                break
            action("closePane", target=f"pane:{terminal}", settle=0.8)
        seeded = rpc("debug.agent_pane", {"action": "seed_rows", "count": opts.rows}, timeout=120)
        print(f"seeded {opts.rows} rows: {json.dumps(seeded)[:200]}", flush=True)
    else:
        action("terminal.sendText", {"text": "seq 1 3000\r"}, settle=0.5)
    time.sleep(1.5)  # test harness: setup work settles
    print(f"main pane: {shown_panes()}", flush=True)


def ensure_sidebar(shown):
    sample = rpc("debug.motion", {"action": "trace_start", "targets": ["sidebar"]})
    time.sleep(0.1)  # test harness: a few frames
    trace = rpc("debug.motion", {"action": "trace_stop"}) or {}
    widths = [s["sidebar"][0] for s in trace.get("samples") or [] if isinstance(s.get("sidebar"), list) and s["sidebar"]]
    is_shown = bool(widths) and widths[-1] > 1
    if error_of(sample) is None and is_shown != shown:
        action("toggleSidebar", settle=0.8)


def one_pane():
    while len(shown_panes()) > 1:
        panes = shown_panes()
        extra = next((p for p, kinds in reversed(panes) if "agent" not in kinds), panes[-1][0])
        action("closePane", target=f"pane:{extra}", settle=0.8)


def motions():
    toggle = lambda: action("toggleSidebar")  # noqa: E731
    split = lambda: action("splitRight")  # noqa: E731

    def close_new():
        panes = shown_panes()
        return action("closePane", target=f"pane:{panes[-1][0]}") if len(panes) > 1 else {"error": "one pane"}

    def b_then_d():
        first = toggle()
        time.sleep(opts.gap / 1000)  # the person's gap between the two keys
        return [first, split()]

    def undo_b_then_d():
        first = toggle()
        time.sleep(opts.gap / 1000)
        return [first, close_new()]

    right = lambda: action("toggleRightSidebar")  # noqa: E731
    return [
        ("sidebar-hide", lambda: (one_pane(), ensure_sidebar(True)), toggle),
        ("sidebar-show", None, toggle),
        ("split-right", lambda: (one_pane(), ensure_sidebar(True)), split),
        ("split-close", None, close_new),
        ("b-then-d", lambda: (one_pane(), ensure_sidebar(True)), b_then_d),
        ("b-then-d-undo", None, undo_b_then_d),
        ("right-open", lambda: (one_pane(), ensure_sidebar(True)), right),
        ("right-close", None, right),
    ]


def measure(name, perform):
    started = rpc("debug.motion", {"action": "trace_start", "targets": TARGETS})
    movie = os.path.join(OUT, f"{name}.mov")
    if opts.record:
        rpc("debug.motion", {"action": "record_start", "path": movie, "seconds": 4, "mbps": 40})
        wait(lambda: (rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 5, 0.1)
    time.sleep(0.15)  # test harness: frames at rest before the action
    clock = rpc("debug.motion", {"action": "trace_read"}) or {}
    acted_at = float(((clock.get("samples") or [{}])[-1]).get("t", 0))
    acted = perform()
    time.sleep(1.2)  # test harness: every spring lands (rest is under 0.6 s)
    trace = rpc("debug.motion", {"action": "trace_stop"}) or {}
    if opts.record:
        rpc("debug.motion", {"action": "record_stop"})
        wait(lambda: (rpc("debug.motion", {"action": "record_read"}) or {}).get("written"), 15, 0.2)
    trace["acted"] = acted
    trace["error"] = error_of(started)
    json.dump(trace, open(os.path.join(OUT, f"trace-{name}.json"), "w"))
    result = summarize(name, trace.get("samples") or [], acted_at, float(trace.get("refresh_ms") or 0))
    result["error"] = error_of(started) or (error_of(acted) if isinstance(acted, dict) else None)
    print(f"  {name:<14} spread start {result['spread_start_ms']} ms end {result['spread_end_ms']} ms  "
          f"content lag {result['content_lag_ms']}", flush=True)
    for key, moved in sorted(result["movers"].items(), key=lambda kv: kv[1]["start_ms"]):
        print(f"      {key:<24} {moved['start_ms']:>7.1f} -> {moved['end_ms']:>7.1f} ms  {moved['from']} -> {moved['to']}", flush=True)
    return result


def frames(perform):
    """Display frames around one untraced run of `perform` (no trace or recording on the main thread): missed frames,
    frame interval p95 and max, main-thread work per frame, hangs (`debug.frames`, `debug.main_cpu`, `debug.hangs`)."""
    rpc("debug.hangs", {"clear": True})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.main_cpu", {"action": "start"})
    time.sleep(0.1)  # test harness: frames at rest before the action
    acted = perform()
    time.sleep(1.0)  # test harness: every spring lands
    cpu = rpc("debug.main_cpu", {"action": "stop"}) or {}
    stats = rpc("debug.frames", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    if isinstance(cpu, dict) and not cpu.get("error"):
        stats = {**stats, **{k: v for k, v in cpu.items() if k != "frames"}}
    listed = hangs.get("hangs") if isinstance(hangs, dict) else None
    return {"missed": stats.get("missed"), "p95_ms": stats.get("p95_ms"), "max_ms": stats.get("max_ms"),
            "main_ms_p95": stats.get("main_ms_p95"), "main_ms_max": stats.get("main_ms_max"),
            "main_ms_total": stats.get("main_ms_total"), "refresh_ms": stats.get("refresh_ms"),
            "hangs": len(listed) if isinstance(listed, list) else hangs.get("count"),
            "error": error_of(acted) if isinstance(acted, dict) else None}


def median(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    return values[len(values) // 2] if values else None


def cleanup():
    if os.environ.get("ONE_MOTION_KEEP") or not app:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)  # the pid this script started
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_AGENT_PANE_MOCK": "1",
           "CMUX_NEXT_AGENT_PANE_FULL_RATE": "1", "CMUX_DEV_BACKEND_MODE": "local",
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW),
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief")}
    os.makedirs(OUT, exist_ok=True)
    log_path = os.path.join(OUT, f"app-{TAG}.log")

    def started(process):
        global app
        app = process
    try:
        app, SOCKET = launch_app(APP, env, log_path, timeout=120, on_start=started)
    except LaunchError as error:
        print(f"launch failed: {error}", flush=True)
        sys.exit(1)
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    print(f"launched pid {app.pid} macOS {macos} host {host}", flush=True)
    time.sleep(5)  # test harness: launch work settles
    rpc("debug.motion", {"action": "speed", "value": "fast"})
    rpc("debug.motion", {"action": "reduce", "value": False})
    setup()
    wanted = set(filter(None, opts.motions.split(",")))
    plan = [(n, p, f) for n, p, f in motions() if not wanted or n in wanted]
    report = {"tag": TAG, "macos": macos, "host": host, "content": opts.content, "gap_ms": opts.gap,
              "commit": os.environ.get("GITHUB_SHA") or subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True,
                                                                     text=True).stdout.strip(), "runs": []}
    for index in range(opts.rounds):
        for name, prepare, perform in plan:
            if prepare:
                prepare()
                time.sleep(0.6)  # test harness: the prepare's own motion lands before the traced one
            run = measure(name if index == 0 else f"{name}-{index}", perform)
            run["round"] = index
            plan_names = [n for n, _, _ in plan]
            undo = plan[plan_names.index(name) + 1] if prepare and plan_names.index(name) + 1 < len(plan) else None
            passes = []
            for _ in range(opts.frame_rounds if prepare and undo and undo[1] is None else 0):
                # Undo the traced motion, set up again, and time the same motion untraced.
                undo[2]()
                time.sleep(1.0)  # test harness: the undo lands
                prepare()
                time.sleep(0.6)  # test harness: the prepare lands
                passes.append(frames(perform))
            if passes:
                run["frames"] = {key: median([p[key] for p in passes]) for key in
                                 ("missed", "p95_ms", "max_ms", "main_ms_p95", "main_ms_max", "main_ms_total", "hangs")}
                run["frames"]["passes"] = passes
                print(f"      frames (median of {len(passes)}): {json.dumps(run['frames'] | {'passes': len(passes)})}", flush=True)
            report["runs"].append(run)
            for path in filter(None, (opts.json, os.path.join(OUT, "one-motion.json"))):
                json.dump(report, open(path, "w"), indent=1)
            time.sleep(0.3)  # test harness: idle between motions
    one_motion_plot.write_all(report, OUT)
    if opts.bundle:
        with tarfile.open(os.path.join(opts.out, "one-motion.tar.gz"), "w:gz") as bundle:
            bundle.add(OUT, arcname="one-motion")


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
