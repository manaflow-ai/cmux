#!/usr/bin/env python3
"""Cmd-N and Cmd-T paint stable on a running tagged build (bd cx-8g3sn).

A new workspace (Cmd-N) or tab (Cmd-T) opens on the New Tab page, the prewarmed spare handed
over (no page loads for it), with no blank or intermediate frame: the window as the window
server composited it, read frame after frame around the key (`debug.new_tab` frame_strip),
changes outside the pane's content area and its tab strip (whose tabs slide) in one step (each frame equals the one before the key
or the settled one), the content area too (Leo 2026-10-13: the New Tab frame drawn under the
adopted page showed one frame on another background), and the content area never turns one flat
color it was not before the key.
Fails on any such frame and prints where the frame strips are.

`--split N` (Leo 2026-10-20: "the layout shifts" when a new workspace opens from a split one): the
workspace is split into N panes first (Cmd-D, then Cmd-Shift-D), so the prewarmed page waits at a
split pane's size and Cmd-N's new workspace, one pane over the whole area, must still show it in
one step: no frame of the page laid out at the old pane's size.

`--cold` (bd cx-ec99): the first Cmd-N goes the moment the app answers on its socket after launch,
with no wait for a ready spare, and its content area must never turn flat (the person sees the
New Tab page's frame, never an empty pane, while its page loads). Start this script before the app.

The app runs already (a capture slot: `capture-host launch`), with its debug socket; or `--app` and
`--tag` launch a tagged DEV build here (no activation, scratch config, as instant-new-surfaces-bench.py
does) and quit it at the end, for CI's GUI runners (cmux-next-frame-pacing.yml, `instant`).

Usage: cmd-n-paint-e2e.py (--socket <path> | --app PATH --tag TAG) [--runs 3] [--keys n,t] [--out DIR] [--cold] [--split N]
"""
import argparse, atexit, glob, json, os, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket")
parser.add_argument("--app", help="a tagged DEV app to launch (with --tag) instead of one already running")
parser.add_argument("--tag")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--keys", default="n,t", help="Command-<key> openings to check, comma separated")
parser.add_argument("--out", default="/tmp/cmd-n-paint", help="where the app writes each run's frames")
parser.add_argument("--duration-ms", type=float, default=700)
parser.add_argument("--cold", action="store_true", help="the first Cmd-N right after launch: no ready spare, no blank frame")
parser.add_argument("--split", type=int, default=1, help="split the workspace into this many panes before the openings")
opts = parser.parse_args()
if bool(opts.app) != bool(opts.tag) or bool(opts.socket) == bool(opts.app):
    parser.error("pass --socket, or --app with --tag")
if opts.app:
    opts.socket = f"/tmp/cmux-debug-{opts.tag}.sock"


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)")


def spare_ready():
    # No-activate slots have no key window: park the spare in window 0 as a key change does.
    rpc("debug.new_tab", {"action": "retarget"})
    state = rpc("debug.new_tab", {"action": "state"}) or {}
    return any(s.get("ready") for s in state.get("spares") or [])


def launch(app_path, tag):
    """Starts the tagged app on its debug socket with a scratch config; it quits at exit."""
    app_path = os.path.abspath(app_path.rstrip("/"))
    binary = next((p for p in sorted(glob.glob(os.path.join(app_path, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
    if not binary:
        sys.exit(f"no executable in {app_path}")
    if os.path.exists(opts.socket):
        os.remove(opts.socket)
    scratch = tempfile.mkdtemp(prefix=f"cmd-n-paint-{tag}-")
    open(os.path.join(scratch, "ghostty"), "w").close()
    config = os.path.join(scratch, "cmux.json")
    open(config, "w").write("{}\n")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{tag}.log"), "a")
    process = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)

    def quit_app():
        rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(process.pid, signal.SIGKILL)
        cli = os.path.join(app_path, "Contents/Resources/bin/cmux")
        subprocess.run([cli, "server", "stop", "--session", f"cmux-app-{tag}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
        if os.path.exists(opts.socket):
            os.remove(opts.socket)
    atexit.register(quit_app)
    wait("the tagged app's socket", lambda: os.path.exists(opts.socket) and (rpc("debug.windows") or {}).get("windows"), 120)
    time.sleep(2)  # test harness wait: the first workspace settles


if opts.app:
    launch(opts.app, opts.tag)
failures = []
if opts.split > 1:
    wait("a ready spare before the splits", spare_ready, 60)
    for index in range(opts.split - 1):
        # Split Right, then Split Down: each opens a New Tab page in the new pane (NewTabPage.split).
        rpc("debug.key", {"key": "d", "modifiers": ["command"] + (["shift"] if index else [])})
        time.sleep(1.0)  # test harness wait: the split's pane shows
    # The spare follows the focused pane's size once that settles (NewTabSparePool.fitSettle).
    time.sleep(1.0)  # test harness wait
for run in range(opts.runs):
    for key in opts.keys.split(","):
        if key == "t":
            # Cmd-T on a New Tab page only focuses it: open from a terminal tab (Control-`).
            rpc("debug.key", {"key": "`", "modifiers": ["control"]})
            time.sleep(1.0)  # test harness wait: the terminal tab shows
        cold = opts.cold and run == 0
        if cold:
            wait("the app's socket", lambda: "error" not in (rpc("debug.new_tab", {"action": "state"}, timeout=5) or {"error": "no reply"}), 60)
            rpc("debug.new_tab", {"action": "retarget"})
        else:
            wait(f"a ready spare before Cmd-{key.upper()}", spare_ready, 30)
            time.sleep(0.5)  # test harness wait: the window settles (caret, hover) before the strip
        openings = len((rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or [])
        out = f"{opts.out}/cmd-{key}-{run}"
        reply = rpc("debug.new_tab", {"action": "frame_strip", "key": key, "dir": out, "duration_ms": opts.duration_ms}) or {}
        if "error" in reply:
            sys.exit(f"FAIL frame_strip Cmd-{key.upper()}: {reply}")
        # Right after launch the sidebar may lead the content by a frame; the pane must never be empty.
        bad = [f for f in reply["frames"] if f["blank"] or ((f["intermediate"] or f.get("content_intermediate")) and not cold)]
        # The page is the prewarmed spare, handed over, not a page loaded for this opening.
        recorded = (rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or []
        opening = recorded[-1] if len(recorded) > openings else {}
        if not opening.get("spare") and not cold:
            failures.append(f"Cmd-{key.upper()} run {run} (no spare adopted: {opening or 'no opening'})")
        print(f"Cmd-{key.upper()} run {run}{' (cold)' if cold else ''}: spare={bool(opening.get('spare'))} {reply['frame_count']} frames every {reply['mean_interval_ms']:.1f} ms, "
              f"intermediate={reply['intermediate']:.0f} content_intermediate={reply.get('content_intermediate', 0):.0f} "
              f"strip_motion={reply.get('strip_intermediate', 0):.0f} "
              f"blank={reply['blank']:.0f} strip={out}/strip.png", flush=True)
        if reply.get("spans"):
            print("  marks: " + ", ".join(f"{span['name']} {span['ms']:+.0f} ms" for span in reply["spans"]), flush=True)
        for frame in bad:
            print(f"  {frame['file']} at {frame['ms']:+.0f} ms: outside differs {frame['outside_vs_before']:.3f} from before, "
                  f"{frame['outside_vs_final']:.3f} from final, content between={frame.get('content_intermediate')}, blank={frame['blank']}", flush=True)
        if bad:
            failures.append(f"Cmd-{key.upper()} run {run}")
        # Back to one workspace and tab: Cmd-W closes the new tab (and with it a new workspace).
        rpc("debug.key", {"key": "w", "modifiers": ["command"]})
        time.sleep(0.5)  # test harness wait

if failures:
    sys.exit(f"FAIL blank or intermediate frames: {', '.join(failures)}")
print("PASS no blank or intermediate frame")
