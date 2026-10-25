#!/usr/bin/env python3
"""Cmd-N, Cmd-T, Ctrl-`, Cmd-D and Cmd-Shift-D: key to visible, idle and under load (instant-new-surfaces).

Launches the tagged app itself (no activation, scratch config), makes a terminal workspace, then
runs `debug.new_tab {action: bench_create, command}` for each command `--runs` times: the key goes
through the real key path (`debug.key`) and the app reports, per run, the key's main-thread ms,
the display frame at which the result shows (`visible_ms`, `frames_to_visible`), when the
daemon's object replaced the provisional one (`confirmed_ms`), when the new object shows its
content (`content_ms`: a terminal's prompt) and its BenchSpans marks.

Two phases: `idle`, then `load` (every core busy with `yes`, plus `--storm` workers looping the
tag's CLI against its daemon). With `--budget-frames N` the run fails when any command's p95
display frame of visibility (1 = the first frame drawn after the key) is above N or a key's main-thread time is above `--budget-key-ms`.

`--commands` picks the commands (default all; Shift-Cmd-L is `cef-tab-bench.py`); `--workspaces 10,100` runs every phase again at
each workspace count (the app holds that many terminal workspaces; the bench's is the shown one).

Usage: instant-new-surfaces-bench.py --tag TAG --app PATH [--runs 12] [--commands new_terminal]
       [--workspaces 10,100] [--out DIR] [--json FILE]
"""
import argparse, glob, json, os, re, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=12)
parser.add_argument("--storm", type=int, default=8)
parser.add_argument("--phases", default="idle,load")
parser.add_argument("--commands", default="split_right,split_down,new_tab,new_terminal,new_workspace")
parser.add_argument("--workspaces", default="", help="comma-separated workspace counts to run every phase at (empty: as launched)")
parser.add_argument("--budget-frames", type=float, default=0, help="fail when a command's p95 display frame of visibility is above this (1: the first frame; 0: report only)")
parser.add_argument("--budget-key-ms", type=float, default=16.7)
parser.add_argument("--hang-stacks", action="store_true",
                    help="as the every-action sweep: hang watchdog at 8 ms, the agent pane mock (Cmd-N opens its New Tab page), "
                         "and each run's longest main-thread stall with its whole stack (64 frames) in the row and the log")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"instant-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
LAUNCHED, LOAD = [], []
COMMANDS = [c for c in opts.commands.split(",") if c]


def run(*args, timeout=30):
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None, timeout=30):
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


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def panes():
    return [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]


def window_key():
    return ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")


def pct(values, q):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def start_load():
    for _ in range(os.cpu_count() or 8):
        LOAD.append(subprocess.Popen(["yes"], stdout=subprocess.DEVNULL))
    loop = f'while :; do "{CLI}" workspace list >/dev/null 2>&1; "{CLI}" tree >/dev/null 2>&1; done'
    for _ in range(opts.storm):
        LOAD.append(subprocess.Popen(["/bin/sh", "-c", loop], env=CLI_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(3)  # test harness: let the load ramp


def stop_load():
    for proc in LOAD:
        try:
            proc.terminate()
        except OSError:
            pass
    LOAD.clear()


def undo(command, window, before_panes):
    """Back to one terminal pane in the bench workspace."""
    if command == "new_workspace":
        rpc("action.run", {"action": "closeWorkspace"})
        wait(lambda: (focused() or {}).get("kind") == "terminal", 10)
        return
    rpc("debug.key", {"key": "w", "modifiers": ["command"], "window": window})
    wait(lambda: len(panes()) <= before_panes and (focused() or {}).get("kind") == "terminal", 10)


def focused():
    return next((p for p in panes() if p.get("focused")), None)


def ensure_terminal():
    """A shown terminal workspace: `newTab` from a script makes one terminal; focus: true shows it."""
    if (focused() or {}).get("kind") == "terminal":
        return True
    reply = rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "instant-bench"}, "wait": True})
    print("newTab:", json.dumps(reply)[:300], flush=True)
    ok = wait(lambda: (focused() or {}).get("kind") == "terminal", 30)
    time.sleep(1)  # test harness: shell prompt
    return ok


def bench(phase, window):
    rows = []
    if not ensure_terminal():
        sys.exit("no focused terminal: " + json.dumps(panes())[:800])
    for command in COMMANDS:
        for index in range(opts.runs):
            if command != "new_workspace" and not ensure_terminal():
                sys.exit("no focused terminal: " + json.dumps(panes())[:800])
            before = len(panes())
            if opts.hang_stacks:
                rpc("debug.hangs", {"clear": True})
            result = rpc("debug.new_tab", {"action": "bench_create", "command": command}, timeout=20) or {}
            result.update({"phase": phase, "run": index})
            rows.append(result)
            marks = {s["name"]: round(s["at"], 1) for s in result.get("spans") or [] if s.get("ms", 0) == 0}
            print(f"{phase} {command} #{index}: key={result.get('key_ms')} visible={result.get('visible_ms')} "
                  f"frame={frame_of(result)} confirmed={result.get('confirmed_ms')} content={result.get('content_ms')} marks={marks} "
                  f"err={result.get('error')}", flush=True)
            time.sleep(0.4)  # test harness: let the creation's shell start before closing it
            if opts.hang_stacks:
                result["hangs"] = longest_stall(rpc("debug.hangs", {"limit": 8}) or {})
                stall = result["hangs"].get("stack") or {}
                print(f"  stalls={result['hangs'].get('count')} longest={stall.get('ms')} cpu={stall.get('cpu_ms')}", flush=True)
                for frame in stall.get("frames") or []:
                    print("    " + frame, flush=True)
            undo(command, window, before)
            time.sleep(0.3)
    return rows


def longest_stall(hangs):
    """debug.hangs: the stall count and the longest stall with its whole main-thread stack (bounded), as the
    every-action sweep's `hang_summary`: a window-server wait shows its AppKit and app callers only there."""
    records = [r for r in (hangs.get("records") or []) if r.get("kind", "stall") == "stall"] if isinstance(hangs, dict) else []
    longest = max(records, key=lambda r: r.get("duration_ms") or 0, default=None)
    out = {"count": hangs.get("count") if isinstance(hangs, dict) else None}
    if longest:
        out["stack"] = {"ms": round(longest.get("duration_ms") or 0, 2), "cpu_ms": round(longest.get("cpu_ms") or 0, 2),
                        "frames": (longest.get("frames") or [])[:64]}
    return out


def workspace_count():
    snap = rpc("snapshot.get") or {}
    topology = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
    return len(topology.get("workspaces") or [])


def grow_workspaces(count):
    """At least `count` terminal workspaces, the bench's still shown (scripts make them unfocused)."""
    have = workspace_count()
    for index in range(have, count):
        rpc("action.run", {"action": "newTab", "args": {"name": f"bench-{index}"}, "wait": True})
    now = workspace_count()
    print(f"workspaces: {have} -> {now}", flush=True)
    if now < count:
        sys.exit(f"could not reach {count} workspaces (have {now})")
    return now


def frame_of(row, key="visible_ms"):
    """Which display frame after the key showed it (1 = the first frame the display link drew).
    The app's `frames_to_visible` divides by the refresh period, which counts a late first frame
    (main thread busy, display link start) as several; this walks the frames actually drawn."""
    frames = row.get("frames") or {}
    at, seen = frames.get("first_tick_ms"), row.get(key)
    if at is None or seen is None:
        return None
    index, intervals = 1, frames.get("intervals_ms") or []
    while seen > at + 0.5 and index - 1 < len(intervals):
        at += intervals[index - 1]
        index += 1
    return index


def summary(rows):
    out = {}
    for phase in sorted({r["phase"] for r in rows}):
        for command in COMMANDS:
            sel = [r for r in rows if r["phase"] == phase and r.get("command") == command]
            vis = [r.get("visible_ms") for r in sel]
            out[f"{phase}/{command}"] = {
                "n": len(sel), "missed": sum(v is None for v in vis),
                "key_p50": pct([r.get("key_ms") for r in sel], .5), "key_max": pct([r.get("key_ms") for r in sel], 1),
                "visible_p50": pct(vis, .5), "visible_p95": pct(vis, .95), "visible_max": pct(vis, 1),
                "frames_p50": pct([frame_of(r) for r in sel], .5),
                "frames_p95": pct([frame_of(r) for r in sel], .95),
                "frames_max": pct([frame_of(r) for r in sel], 1),
                "first_frame_ms_p50": pct([(r.get("frames") or {}).get("first_tick_ms") for r in sel], .5),
                "confirmed_p50": pct([r.get("confirmed_ms") for r in sel], .5),
                "confirmed_p95": pct([r.get("confirmed_ms") for r in sel], .95),
                "content_p50": pct([r.get("content_ms") for r in sel], .5),
                "content_p95": pct([r.get("content_ms") for r in sel], .95),
            }
    return out


app = None


def cleanup():
    stop_load()
    if not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except OSError:
                pass
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    # No socket check here: BenchApp.launch() refuses a live same-tag app (any bundle path) and unlinks only a
    # socket nothing accepts on.
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    if opts.hang_stacks:
        env.update({"CMUX_NEXT_HANG_THRESHOLD_MS": "8", "CMUX_NEXT_AGENT_PANE_MOCK": "1", "ACPMUX_AGENT_LAUNCH": "deny"})
    # One launch path (bench_launch.py): socket in the state folder, bench env, a clear reason when it does not come up.
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False, env=env)
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    CLI_ENV["CMUX_SOCKET_PATH"] = SOCKET
    time.sleep(2)  # test harness: shell prompt
    window = window_key()
    rows = []
    counts = [int(c) for c in opts.workspaces.split(",") if c] or [None]
    for count in counts:
        suffix = ""
        if count is not None:
            ensure_terminal()
            suffix = f"@{grow_workspaces(count)}ws"
        for phase in opts.phases.split(","):
            if phase == "load":
                start_load()
            try:
                rows += bench(phase + suffix, window)
            finally:
                stop_load()
    result = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "summary": summary(rows), "runs": rows}
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))
    if opts.budget_frames:
        bad = [k for k, v in result["summary"].items()
               if v["missed"] or (v["frames_p95"] or 99) > opts.budget_frames or (v["key_max"] or 0) > opts.budget_key_ms]
        print("BUDGET", "FAIL " + ", ".join(bad) if bad else "PASS", flush=True)
        return not bad
    return True


ok = False
try:
    ok = main()
finally:
    cleanup()
sys.exit(0 if ok else 1)
