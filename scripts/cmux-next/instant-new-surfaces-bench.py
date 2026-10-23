#!/usr/bin/env python3
"""Every create on the key: Cmd-N, Cmd-T, Ctrl-`, Cmd-D, Cmd-Shift-D, Ctrl-Cmd-D (New Column) and Cmd-I
(New Agent Chat): key to visible, idle and under load (instant-new-surfaces, perf-lead issue 11).

Launches the tagged app itself (no activation, scratch config), makes a terminal workspace, then
runs `debug.new_tab {action: bench_create, command}` for each command `--runs` times: the key goes
through the real key path (`debug.key`) and the app reports, per run, the key's main-thread ms,
the display frame at which the result shows (`visible_ms`, `frames_to_visible`), when the
daemon's object replaced the provisional one (`confirmed_ms`) and its BenchSpans marks.

Two phases: `idle`, then `load` (every core busy with `yes`, plus `--storm` workers looping the
tag's CLI against its daemon). With `--budget-frames N` the run fails when any command's p95
display frame of visibility (1 = the first frame drawn after the key) is above N or a key's main-thread time is above `--budget-key-ms`.
`--budget-key-p95-ms X` also fails a command whose p95 key main-thread time is above X (perf-lead target: 4 ms).

`--browser-tabs N` first opens N browser tabs (6 per workspace, in workspaces of their own) on pages a
local HTTP server serves, each with its own title and favicon, so every visit is a history entry with
an icon: the New Tab page that Cmd-N and Cmd-T build then lists N open tabs and up to 40 history pages
with favicons, as a working session does. `--icon-px` (default 180, a touch icon's size) sets each icon's
size: the page inlines every listed icon, so a site's full-size icon is what each create encodes and sends. Without it the session holds only the bench's terminals.
`--browser-engine` (default chromium) picks the engine. Only Chromium tabs get these icons: a WebKit
tab fetches its icon through BrowserFaviconLoader, which refuses loopback hosts, so with webkit the
pages and history are there but without icons. Check `debug.cef` first (perf-lead-brief measurement
validity): a build without the Chromium artifact silently opens WebKit tabs.

`--sessions light,stress` runs every phase in the light session first, then builds the standard STRESS
session (scripts/cmux-next/perf-stress-session.py: 60 workspaces, the measured one 4 x 3 panes plus nested
splits, 6 tabs per pane, 10 busy terminals, 10 workspaces with Chromium pages) in the same app and runs
every phase again in its measured workspace (phase names end in `@stress`), so light and STRESS numbers come
from one build side by side. It prints the STRESS-SESSION line the builder reports.

Create-on-the-key guard (red before the fix, green after), light and STRESS:
  instant-new-surfaces-bench.py --tag T --app APP --phases idle --browser-tabs 60 --sessions light,stress \
    --commands new_workspace,new_tab,new_terminal,split_right,split_down,new_chat \
    --budget-frames 1 --budget-key-p95-ms 4

`--commands` picks the commands (default all but new_column, which PL-motion-core owns); `--workspaces 10,100` runs every phase again at
each workspace count (the app holds that many terminal workspaces; the bench's is the shown one).

Each phase records the host's 1-minute load before it starts (`load_avg`): an `idle` phase on a
loaded host is not idle. A phase whose bench terminal is lost ends there and is listed in `aborts`
(a budget run fails, the other phases still run), and the JSON is written after every phase. The
tag's daemon session is stopped before the launch, so a reused tag starts from a fresh session.

Usage: instant-new-surfaces-bench.py --tag TAG --app PATH [--runs 12] [--commands new_terminal]
       [--workspaces 10,100] [--browser-tabs 60] [--sessions light,stress] [--budget-key-p95-ms 4]
       [--out DIR] [--json FILE]
"""
import argparse, glob, http.server, json, os, re, signal, socket, struct, subprocess, sys, tempfile, threading, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=12)
parser.add_argument("--storm", type=int, default=8)
parser.add_argument("--phases", default="idle,load")
# new_column is PL-motion-core's (New Column end to end): pass it with --commands to time it here.
parser.add_argument("--commands", default="split_right,split_down,new_tab,new_terminal,new_workspace,new_chat")
parser.add_argument("--workspaces", default="", help="comma-separated workspace counts to run every phase at (empty: as launched)")
parser.add_argument("--budget-frames", type=float, default=0, help="fail when a command's p95 display frame of visibility is above this (1: the first frame; 0: report only)")
parser.add_argument("--budget-key-ms", type=float, default=16.7)
parser.add_argument("--budget-key-p95-ms", type=float, default=0, help="fail when a command's p95 key main-thread ms is above this (0: off)")
parser.add_argument("--browser-tabs", type=int, default=0, help="open this many browser tabs with favicons (and history) before the bench")
parser.add_argument("--browser-engine", choices=["chromium", "webkit"], default="chromium")
parser.add_argument("--sessions", default="light", help="light, stress, or light,stress (STRESS built after the light runs)")
parser.add_argument("--icon-px", type=int, default=180, help="pixel size of each --browser-tabs page's favicon (sites serve 16 to 256)")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"instant-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{TAG}", "CMUX_BUNDLED_CLI_PATH": CLI}
LAUNCHED, LOAD = [], []
# Phases a lost bench terminal ended early (the rest of the run goes on; a budget run fails).
ABORTS = []
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


def undo(command, window, before_panes, result=None):
    """Back to one terminal pane in the bench workspace."""
    if command == "new_chat":
        # The chat the run added, by id: Cmd-W would close the focused tab, which is the bench's
        # terminal when the placement opened the chat unfocused in another pane. A chat the
        # placement opened in a new workspace takes that workspace with it.
        if (result or {}).get("workspace_changed"):
            rpc("action.run", {"action": "closeWorkspace"})
        else:
            for tab in (result or {}).get("added_tabs") or []:
                rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}", "origin": "script", "wait": True})
        wait(lambda: len(panes()) <= before_panes and (focused() or {}).get("kind") == "terminal", 10)
        return
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


def abort(phase, where):
    """The bench lost its terminal: this phase ends here and says so; the rows so far stay."""
    print(f"ABORT {phase} at {where}: no focused terminal: " + json.dumps(panes())[:400], flush=True)
    ABORTS.append(f"{phase}/{where}")


def bench(phase, window):
    rows = []
    if not ensure_terminal():
        abort(phase, "start")
        return rows
    for command in COMMANDS:
        for index in range(opts.runs):
            if command != "new_workspace" and not ensure_terminal():
                abort(phase, f"{command}#{index}")
                return rows
            before = len(panes())
            result = rpc("debug.new_tab", {"action": "bench_create", "command": command}, timeout=20) or {}
            result.update({"phase": phase, "run": index})
            rows.append(result)
            # Marks (ms 0) by time after the key, spans by their main-thread ms: the streamed log
            # keeps the breakdown even when the run dies before it writes its JSON.
            marks = {s["name"]: round(s["at"], 1) for s in result.get("spans") or [] if s.get("ms", 0) == 0}
            spans = {s["name"]: round(s["ms"], 2) for s in result.get("spans") or [] if s.get("ms", 0) > 0}
            print(f"{phase} {command} #{index}: key={result.get('key_ms')} visible={result.get('visible_ms')} "
                  f"frame={frame_of(result)} confirmed={result.get('confirmed_ms')} spans={spans} marks={marks} "
                  f"err={result.get('error')}", flush=True)
            time.sleep(0.4)  # test harness: let the creation's shell start before closing it
            undo(command, window, before, result)
            time.sleep(0.3)
    return rows


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
                "key_p50": pct([r.get("key_ms") for r in sel], .5), "key_p95": pct([r.get("key_ms") for r in sel], .95),
                "key_max": pct([r.get("key_ms") for r in sel], 1),
                "visible_p50": pct(vis, .5), "visible_p95": pct(vis, .95), "visible_max": pct(vis, 1),
                "frames_p50": pct([frame_of(r) for r in sel], .5),
                "frames_p95": pct([frame_of(r) for r in sel], .95),
                "frames_max": pct([frame_of(r) for r in sel], 1),
                "first_frame_ms_p50": pct([(r.get("frames") or {}).get("first_tick_ms") for r in sel], .5),
                "confirmed_p50": pct([r.get("confirmed_ms") for r in sel], .5),
                "confirmed_p95": pct([r.get("confirmed_ms") for r in sel], .95),
            }
    return out


def png(seed, size):
    """A `size` px square PNG of color blocks whose base color follows `seed`: each page gets its
    own favicon image, at the size sites serve (`--icon-px`: a 180 px touch icon is common; a 16 px
    one hides what a full-size icon costs every New Tab page that lists it)."""
    r, g, b = (seed * 67) % 256, (seed * 131) % 256, (seed * 29 + 90) % 256
    raw = b"".join(b"\x00" + b"".join(bytes(((r + x // 6 * 9) % 256, (g + y // 6 * 9) % 256, (b + ((x // 12) ^ (y // 12)) * 16) % 256)) for x in range(size))
                   for y in range(size))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


class PageHandler(http.server.BaseHTTPRequestHandler):
    """/p/N: a page titled "Bench page N" whose icon is /icon/N.png."""

    def do_GET(self):
        match = re.fullmatch(r"/(p|icon)/(\d+)(?:\.png)?", self.path)
        if not match:
            self.send_error(404)
            return
        n = int(match.group(2))
        if match.group(1) == "p":
            body, kind = f'<!doctype html><title>Bench page {n}</title><link rel="icon" href="/icon/{n}.png"><p>page {n}'.encode(), "text/html"
        else:
            body, kind = png(n, opts.icon_px), "image/png"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def seed_browser_tabs(count):
    """`count` browser tabs, 6 per workspace of their own, each on its own page with its own favicon."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), PageHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    for index in range(count):
        if index % 6 == 0:
            rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": f"bench-web-{index // 6}"}, "wait": True})
            wait(lambda: (focused() or {}).get("kind") == "terminal", 30)
        rpc("action.run", {"action": f"openBrowser.{opts.browser_engine}", "args": {"url": f"{base}/p/{index}"}, "focus": True})
    listed = lambda: sum(str(t.get("title", "")).startswith("Bench page") for t in (rpc("debug.new_tab") or {}).get("omnibar_tabs") or [])
    seen = wait(lambda: listed() >= count and listed(), 120, step=1)
    time.sleep(3)  # test harness: the pages' favicons land after their titles
    print(f"browser tabs ({opts.browser_engine}): {listed()} of {count} listed by the New Tab bar ({seen}); "
          f"debug.cef: {json.dumps(rpc('debug.cef'))[:400]}", flush=True)
    return server


def build_stress():
    """The standard STRESS session in this app (perf-stress-session.py), its measured workspace shown."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    shape = module.Stress(rpc).build()
    print("STRESS-SESSION", json.dumps(shape), flush=True)
    return shape


app = None


def stop_session():
    """Ends the tag's daemon session and its terminals. The app reattaches to a session its tag
    left running, so a reused tag would measure the last run's workspaces and STRESS content."""
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)


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
    stop_session()
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
    global app
    if os.path.exists(SOCKET):
        ps = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
        if any(line.startswith(APP + "/Contents/MacOS/") for line in ps.splitlines()):
            sys.exit(f"{SOCKET} exists and a {TAG} app runs; pick a fresh tag")
        os.remove(SOCKET)
    stop_session()
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    time.sleep(2)  # test harness: shell prompt
    window = window_key()
    start_workspaces = workspace_count()
    print(f"workspaces at launch: {start_workspaces}", flush=True)
    server = seed_browser_tabs(opts.browser_tabs) if opts.browser_tabs else None
    rows, stress, loads = [], None, {}

    def write(final):
        """The JSON so far: after each phase (`partial`), so a run that dies keeps every phase it ran."""
        result = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "partial": not final,
                  "workspaces_at_launch": start_workspaces,
                  "aborts": ABORTS, "load_avg": loads, "stress_session": stress, "summary": summary(rows), "runs": rows}
        if opts.json:
            open(opts.json, "w").write(json.dumps(result, indent=1))
        return result
    counts = [int(c) for c in opts.workspaces.split(",") if c] or [None]
    for session in [s for s in opts.sessions.split(",") if s]:
        if session == "stress":
            stress = build_stress()
        for count in counts:
            suffix = "@stress" if session == "stress" else ""
            if count is not None:
                ensure_terminal()
                suffix += f"@{grow_workspaces(count)}ws"
            for phase in opts.phases.split(","):
                # Measurement validity: the host's 1-minute load before the phase (and before its
                # own load starts). An `idle` phase on a host whose load is near its core count is
                # not idle; the number says so next to the rows.
                loads[phase + suffix] = round(os.getloadavg()[0], 1)
                print(f"phase {phase + suffix}: host load {loads[phase + suffix]} on {os.cpu_count()} cores", flush=True)
                if phase == "load":
                    start_load()
                try:
                    rows += bench(phase + suffix, window)
                finally:
                    stop_load()
                write(final=False)
    result = write(final=True)
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    if ABORTS:
        print("ABORTS", ", ".join(ABORTS), flush=True)
    if server:
        server.shutdown()
    if opts.budget_frames or opts.budget_key_p95_ms:
        bad = [k for k, v in result["summary"].items()
               if v["missed"] or (opts.budget_frames and (v["frames_p95"] or 99) > opts.budget_frames)
               or (opts.budget_frames and (v["key_max"] or 0) > opts.budget_key_ms)
               or (opts.budget_key_p95_ms and (v["key_p95"] or 99) > opts.budget_key_p95_ms)]
        bad += [f"aborted {where}" for where in ABORTS]
        for k, v in result["summary"].items():
            print(f"BUDGET {k}: key p50/p95/max {v['key_p50']}/{v['key_p95']}/{v['key_max']} ms, "
                  f"frame p95 {v['frames_p95']}, missed {v['missed']}", flush=True)
        print("BUDGET", "FAIL " + ", ".join(bad) if bad else "PASS", flush=True)
        return not bad
    return not ABORTS


ok = False
try:
    ok = main()
finally:
    cleanup()
sys.exit(0 if ok else 1)
