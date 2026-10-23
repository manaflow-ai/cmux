#!/usr/bin/env python3
"""Key to frame for the three typing surfaces of cmux NEXT (perf-lead.md issue 5; target p95 < 8 ms).

Launches the tagged DEBUG app itself on a GUI host (no activation, scratch cmux.json and Ghostty config, an
isolated Chief home, the mock agent host, the typing probe on, the hang watchdog at 8 ms) and types one key at a
time (`debug.key` with the client's send time as the event timestamp, so the wait for the main thread counts, as a
real key waits in the event queue) into:

  terminal   a zsh prompt (`zsh -f`): send to the frame whose layer contents show the echo (`contents_ms`)
  home       the native Home composer (the Home fixture: the same MessagesLab view and field over the mock
             owner): send to the end of the run-loop turn that committed the edit (`commit_ms`)
  dock       the docked Home the app opens at launch (the real Home owner), when it shows a conversation
  omnibar    the omnibar of a Chromium tab: send to the commit of the edit (`commit_ms`)

each in two phases:

  idle       nothing else runs
  load       --busy terminals print without pause (three of them visible next to the typed surface, the rest in
             other workspaces), --chats mock agent chats stream (debug.agent_pane stream), and for home the
             fixture's Chief streams a reply into the transcript at 30 tokens/s

Per surface and phase: key-to-frame p50/p95/p99/max, the probe's hop split (send to dispatch, dispatch, dispatch to
frame), main-thread hangs over 8 ms (`debug.hangs`), and with --sample a `/usr/bin/sample` of the app during the
load phase's keys (the main thread's heaviest frames). The display's refresh rate is in the report (judge drops in
frames). Exit 1 with --gate-p95-ms when any measured surface's p95 is over it.

  typing-frame-bench.py --app APP --tag TAG --out DIR [--json FILE] [--surfaces terminal,home,dock,omnibar]
      [--phases idle,load] [--samples 80] [--busy 20] [--chats 2] [--sample] [--gate-p95-ms 8]

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=typing-frame [--arg=--stress] [--arg=--sample] \\
    [--arg=--gate-p95-ms=8]
"""
import argparse, csv, glob, json, os, re, socket, statistics, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--surfaces", default="dock,terminal,home,omnibar")
parser.add_argument("--phases", default="idle,load")
parser.add_argument("--samples", type=int, default=80)
parser.add_argument("--interval", type=float, default=0.1, help="seconds between keys (one key in flight)")
parser.add_argument("--busy", type=int, default=20, help="busy terminals in the load phase")
parser.add_argument("--chats", type=int, default=2, help="streaming mock agent chats in the load phase")
parser.add_argument("--stress", action="store_true",
                    help="build the STRESS session first (perf-lead brief: 60 workspaces, the typed workspace a 4x3 grid with "
                         "6 tabs per pane, 10 workspaces with Chromium pages, 10 printing terminals); every phase runs in it. "
                         "Uses scripts/cmux-next/perf-stress-session.py when present, else the builder here")
parser.add_argument("--sessions", help="comma list of light,stress: one app launch each (default: light, or stress with --stress)")
parser.add_argument("--sample", action="store_true", help="/usr/bin/sample the app over each load phase")
parser.add_argument("--gate-p95-ms", type=float)
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"typing-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
PROBE = os.path.join(OUT, "typing.csv")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
WINDOW = (40, 40, 1400, 900)
BUSY = "while :; do printf '%s busy line %s %s\\n' $RANDOM $RANDOM $RANDOM; done"
results = {"tag": TAG, "host": os.uname().nodename, "opts": vars(opts), "log": [], "runs": []}
app = None
SESSION = "light"


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def rpc(method, params=None, timeout=30):
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def action(name, args=None, settle=0.0, focus=True, timeout=60):
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": focus, "origin": "script"}, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def cli(*args, timeout=60):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    try:
        return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


def probe_rows():
    try:
        with open(PROBE) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def refresh_hz():
    out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True, timeout=60).stdout
    rates = re.findall(r"@ ?([\d.]+) ?Hz", out) or re.findall(r"Refresh Rate: ?([\d.]+)", out)
    lines = [l.strip() for l in out.splitlines() if "Hz" in l or "Resolution" in l]
    return {"hz": [float(r) for r in rates] or None, "lines": lines[:6]}


# ---------------------------------------------------------------- load
class Streamer(threading.Thread):
    """Calls `step()` every `period` seconds until stopped (the Home fixture's reply, the agent chats' streams)."""

    def __init__(self, step, period):
        super().__init__(daemon=True)
        self.step, self.period, self.flag, self.calls = step, period, threading.Event(), 0

    def run(self):
        while not self.flag.is_set():
            t0 = time.perf_counter()
            self.step(self.calls)
            self.calls += 1
            rest = self.period - (time.perf_counter() - t0)
            if rest > 0:
                self.flag.wait(rest)  # the stream's pace

    def stop(self):
        self.flag.set()
        self.join(timeout=30)


LOAD = {"made": False, "workspaces": [], "chat_panes": []}


def make_load(surface_ws):
    """Busy terminals (three split beside the typed surface, the rest in other workspaces) and mock agent chats."""
    if LOAD["made"]:
        return
    LOAD["made"] = True
    if opts.stress:
        # STRESS has its printing terminals and agent chats already: stream up to --chats of its chats.
        listed = rpc("debug.agent_pane", {"action": "engine", "pane": "none"}) or {}
        LOAD["chat_panes"] = (listed.get("agent_panes") or [])[: opts.chats]
        note(f"load (stress): streaming chats {LOAD['chat_panes']}")
        return
    visible = min(3, opts.busy)
    for _ in range(visible):
        action("splitRight", settle=0.6)
        action("terminal.sendText", {"text": BUSY + "\r"})
    rest = opts.busy - visible
    per = 4
    for index in range((rest + per - 1) // per):
        count = min(per, rest - index * per)
        ref = cli("workspace", "create", "--name", f"busy {index}", "--shell", BUSY).stdout.strip()
        LOAD["workspaces"].append(ref)
        for _ in range(count - 1):
            cli("workspace", ref, "focus")
            action("splitDown", settle=0.4)
            action("terminal.sendText", {"text": BUSY + "\r"})
    for _ in range(opts.chats):
        reply = action("palette.newAgentChat", settle=3.0)
        engine = rpc("debug.agent_pane", {"action": "engine"}) or {}
        rpc("debug.agent_pane", {"action": "select_session", "session": "mock-session"})
        LOAD["chat_panes"].append(engine.get("pane"))
        note(f"load: agent chat {engine.get('pane')} ({engine.get('engine')}) {json.dumps(reply)[:120]}")
    if surface_ws:
        cli("workspace", surface_ws, "focus")
    note(f"load: {opts.busy} busy terminals ({visible} visible), {len(LOAD['chat_panes'])} agent chats")


def chat_streams():
    panes = [p for p in LOAD["chat_panes"] if p]
    if not panes:
        return None

    def step(_):
        for pane in panes:
            rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": 40, "seconds": 3, "chunk_ms": 30}, timeout=10)
    return Streamer(step, 3.0)


def home_stream(tab=None):
    words = ("the chief streams a reply into the transcript while you type in the composer, token by token, " * 40).split()

    def step(index):
        text = " ".join(words[: 1 + index % len(words)])
        params = {"action": "stream", "text": text, "done": index % len(words) == len(words) - 1}
        rpc("debug.home.drive", params, timeout=10)
    return Streamer(step, 1 / 30)


# ---------------------------------------------------------------- STRESS
def build_stress():
    """STRESS through the shared builder (scripts/cmux-next/perf-stress-session.py). The typed terminal is the
    selected terminal of the measured workspace's last pane (the first 10 panes' terminals print), at `zsh -f`.
    Returns the measured workspace's id."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                                       "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stress = module.Stress(rpc, log=note)
    summary = stress.build()
    note("STRESS-SESSION " + json.dumps(summary))
    results["stress"] = summary
    ws = summary.get("measured")
    panes = stress.panes(stress.workspace(ws))
    if panes:
        last = panes[-1]
        stress.focus_pane(last["id"])
        tab = next((t for t in reversed(last.get("tabs") or []) if t.get("kind") == "terminal"), None)
        if tab:
            stress.action("tab.focus", target=f"tab:{tab['id']}")
            action("terminal.sendText", {"text": "exec /bin/zsh -f\r"})
            time.sleep(1)  # the prompt draws
        LOAD["stress_pane"] = last["id"]
    return ws


def workspaces():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    return topo.get("workspaces") or []


# ---------------------------------------------------------------- typing
def type_keys(count, params, column):
    keys = "abcdefghijklmnopqrstuvwxyz"
    rows_before = len(probe_rows())
    trips = []
    for index in range(count):
        t0 = time.perf_counter()
        reply = rpc("debug.key", dict(params, key=keys[index % len(keys)], timestamp=time.clock_gettime(time.CLOCK_UPTIME_RAW)),
                    timeout=10)
        trips.append((time.perf_counter() - t0) * 1000)
        if isinstance(reply, dict) and reply.get("error"):
            note(f"key {index}: {reply.get('error')}")
        rest = opts.interval - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # one key in flight at a time
    time.sleep(0.5)  # the last frame lands
    rows = [r for r in probe_rows()[rows_before:] if r.get("complete") == "1" and r.get(column)]
    return rows, trips


def measure(surface, phase, params, column, pid, streams=()):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.frames", {"action": "start"})
    for s in streams:
        s.start()
    sampler = None
    if opts.sample and phase == "load":
        path = os.path.join(OUT, f"sample-{SESSION}-{surface}-{phase}.txt")
        seconds = max(3, int(opts.samples * opts.interval))
        sampler = (subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "1", "-file", path],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), path)
    if streams:
        time.sleep(1.0)  # the streams run before the first key
    rows, trips = type_keys(opts.samples, params, column)
    for s in streams:
        s.stop()
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    hangs = rpc("debug.hangs", {"limit": 12}, timeout=20)
    f = lambda key: [float(r[key]) for r in rows if r.get(key)]
    entry = {
        "session": SESSION, "surface": surface, "phase": phase, "keys": len(trips), "measured": len(rows),
        "key_to_frame_ms": pct(f(column)), "column": column,
        "send_to_dispatch_ms": pct(f("dispatch_start_ms")),
        "dispatch_ms": pct([float(r["dispatch_end_ms"]) - float(r["dispatch_start_ms"]) for r in rows
                            if r.get("dispatch_end_ms") and r.get("dispatch_start_ms")]),
        "dispatch_to_frame_ms": pct([float(r[column]) - float(r["dispatch_end_ms"]) for r in rows if r.get("dispatch_end_ms")]),
        "key_rpc_ms": pct(trips),
        "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms")}
        if isinstance(hangs, dict) else hangs,
        "hang_records": (hangs or {}).get("records") if isinstance(hangs, dict) else None,
        "frames": frames, "streams": [s.calls for s in streams],
    }
    if sampler:
        try:
            sampler[0].wait(timeout=opts.samples * opts.interval + 60)
        except subprocess.TimeoutExpired:
            sampler[0].terminate()
        entry["sample"] = os.path.basename(sampler[1])
        try:
            # The report is the fleet step's one artifact: keep the sample's call graph in it.
            text = open(sampler[1], errors="replace").read()
            start = text.find("Call graph:")
            entry["sample_text"] = text[start:start + 80000] if start >= 0 else text[:80000]
        except OSError:
            pass
    k = entry["key_to_frame_ms"] or {}
    note(f"{SESSION} {surface}.{phase}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} ms "
         f"(n={k.get('n')}/{len(trips)}); hangs {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}")
    results["runs"].append(entry)
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)
    return entry


def surface_terminal(phase, pid):
    ws = LOAD.get("terminal_ws")
    if not ws:
        ws = cli("workspace", "create", "--name", "typing", "--focus", "--shell", "exec /bin/zsh -f").stdout.strip()
        LOAD["terminal_ws"] = ws
        time.sleep(2)  # the prompt draws
    cli("workspace", ws, "focus")
    if LOAD.get("stress_pane"):
        rpc("action.run", {"action": "pane.focus", "target": f"pane:{LOAD['stress_pane']}", "focus": True, "origin": "script"})
    else:
        action("focusLeft", settle=0.3)
    streams = []
    if phase == "load":
        make_load(ws)
        cli("workspace", ws, "focus")
        if LOAD.get("stress_pane"):
            rpc("action.run", {"action": "pane.focus", "target": f"pane:{LOAD['stress_pane']}", "focus": True, "origin": "script"})
        else:
            for _ in range(4):
                action("focusLeft", settle=0.15)
        s = chat_streams()
        streams = [s] if s else []
    entry = measure("terminal", phase, {}, "contents_ms", pid, streams)
    action("terminal.sendText", {"text": "\x15"})  # clears the typed line (Ctrl-U)
    return entry


def surface_home(phase, pid):
    if not LOAD.get("home_open"):
        opened = rpc("debug.home_native_fixture.open", {"new": True})
        note(f"home fixture: {json.dumps(opened)[:160]}")
        LOAD["home_open"] = True
        time.sleep(2)  # the transcript lays out
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"home: no composer to focus ({json.dumps(focused)[:160]})")
        return None
    streams = [home_stream()] if phase == "load" else []
    if phase == "load":
        s = chat_streams()
        if s:
            streams.append(s)
    entry = measure("home", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.home.drive", {"action": "stream", "text": "done", "done": True})
    return entry


def surface_dock(phase, pid):
    # The docked Home the app opened at launch: the home workspace's page.
    homes = rpc("debug.home") or {}
    action("home.show", settle=1.5)
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"dock: no Home composer to focus ({json.dumps(focused)[:160]}; debug.home {json.dumps(homes)[:200]})")
        return None
    return measure("dock", phase, {"probe": "commit"}, "commit_ms", pid, [])


def surface_omnibar(phase, pid):
    if not LOAD.get("omnibar_open"):
        reply = action("openBrowser.chromium", {"url": "about:blank"}, settle=4.0, timeout=120)
        note(f"omnibar: chromium tab {json.dumps(reply)[:120]}")
        LOAD["omnibar_open"] = True
    action("focusBrowserAddressBar", settle=0.5)
    bar = rpc("debug.omnibar") or {}
    if not bar.get("field_editor_active"):
        note(f"omnibar: the field editor is not active ({json.dumps(bar)[:200]})")
    streams = []
    if phase == "load":
        s = chat_streams()
        streams = [s] if s else []
    entry = measure("omnibar", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.key", {"key": "escape"})
    return entry


SURFACES = {"terminal": surface_terminal, "home": surface_home, "dock": surface_dock, "omnibar": surface_omnibar}


def run_session(session):
    """One launch of the app: the light session, or STRESS (built first); every surface and phase in it."""
    global app, SESSION
    SESSION = session
    LOAD.clear()
    LOAD.update({"made": False, "workspaces": [], "chat_panes": []})
    global SOCKET
    # An explicit socket (CMUX_NEXT_SOCKET_PATH): the tag convention's path differs between a fleet step's HOME and
    # a person's, and a stale /tmp link from an earlier step points nowhere.
    SOCKET = os.path.join(tempfile.gettempdir(), f"cmux-typing-{os.getpid()}-{session}.sock")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    scratch = tempfile.mkdtemp(prefix=f"typing-{TAG}-{session}-")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local", "CMUX_NEXT_AGENT_PANE_MOCK": "1",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(scratch, "chief"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, WINDOW)), "CMUX_NEXT_TYPING_PROBE": PROBE,
           "CMUX_NEXT_HANG_THRESHOLD_MS": "8", "CMUX_NEXT_SOCKET_PATH": SOCKET}
    log_path = os.path.join(OUT, f"app-{session}.log")
    log = open(log_path, "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    note(f"{session}: launched pid {app.pid}")
    try:
        if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180):
            log.flush()
            note(f"{session}: socket {SOCKET} exists={os.path.exists(SOCKET)} debug.windows={json.dumps(rpc('debug.windows'))[:300]}")
            if app.poll() is None:
                stuck = os.path.join(OUT, f"sample-launch-{session}.txt")
                subprocess.run(["/usr/bin/sample", str(app.pid), "3", "-file", stuck], capture_output=True, timeout=60)
                try:
                    text = open(stuck, errors="replace").read()
                    graph = text.split("Call graph:", 1)[-1].splitlines()
                    # The main thread's heaviest path: its first block of the call graph, deepest frames kept.
                    main, started = [], False
                    for line in graph:
                        if "com.apple.main-thread" in line:
                            started = True
                        elif started and line.strip() and not line.lstrip().startswith(("+", "|", "!", ":")) and "Thread_" in line:
                            break
                        if started:
                            main.append(line.rstrip())
                    deep = [l for l in main if l.strip()][:400]
                    note("main thread while the app does not answer:\n" + "\n".join(l[-200:] for l in deep[:160]))
                    top = text.split("Sort by top of stack", 1)[-1].splitlines()[:25]
                    note("top of stack:\n" + "\n".join(l[:200] for l in top))
                except OSError:
                    pass
            note(f"{session}: the tagged app did not come up (exit={app.poll()}); log tail: "
                 f"{open(log_path, errors='replace').read()[-3000:]}")
            return
        time.sleep(5)  # launch work settles
        if session == "stress":
            LOAD["terminal_ws"] = build_stress()
            time.sleep(5)  # the grid settles
        surfaces = opts.surfaces.split(",")
        for phase in opts.phases.split(","):
            for surface in surfaces:
                if surface == "dock" and phase != "idle":
                    continue
                try:
                    SURFACES[surface](phase, app.pid)
                except Exception as error:  # one surface failing must not hide the others
                    note(f"{session} {surface}.{phase}: failed: {error!r}")
    finally:
        rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
        try:
            app.wait(timeout=25)
        except subprocess.TimeoutExpired:
            app.kill()
        subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)


def main():
    with open(CONFIG, "w") as f:
        json.dump({"browser": {"defaultEngine": "chromium"}}, f)
    open(os.path.join(SCRATCH, "ghostty"), "w").close()
    results["refresh_hz"] = refresh_hz()
    results["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    sessions = opts.sessions.split(",") if opts.sessions else (["stress"] if opts.stress else ["light"])
    try:
        for session in sessions:
            run_session(session)
    finally:
        summary = {f"{r['session']}.{r['surface']}.{r['phase']}": (r["key_to_frame_ms"] or {}).get("p95") for r in results["runs"]}
        results["summary_p95_ms"] = summary
        note(f"summary p95 ms: {json.dumps(summary)} refresh {results.get('refresh_hz')}")
        if opts.json:
            json.dump(results, open(opts.json, "w"), indent=1)
    if opts.gate_p95_ms is not None:
        over = {k: v for k, v in results["summary_p95_ms"].items() if v is not None and v > opts.gate_p95_ms}
        if over or not results["summary_p95_ms"]:
            print(f"FAIL key-to-frame p95 over {opts.gate_p95_ms} ms: {over or 'nothing measured'}", flush=True)
            sys.exit(1)
        print(f"PASS key-to-frame p95 within {opts.gate_p95_ms} ms", flush=True)


if __name__ == "__main__":
    main()
