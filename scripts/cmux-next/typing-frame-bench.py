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
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402

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
parser.add_argument("--rounds", type=int, default=3, help="every phase this many times per launch (the noise shows)")
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
WINDOW = (40, 40, 1400, 900)
BUSY = "while :; do printf '%s busy line %s %s\\n' $RANDOM $RANDOM $RANDOM; done"
results = {"tag": TAG, "host": os.uname().nodename, "opts": vars(opts), "log": [], "runs": []}
app = None
SESSION = "light"
ROUND = 0


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
    if SESSION == "stress":
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
        reply = action("palette.newAgentChat", settle=1.0)
        # The action answers after ~2 s while the chat still opens: wait for its page, then its composer.
        ready = wait(lambda: (lambda r: r if r.get("document_ready") else None)(
            rpc("debug.agent_pane", {"action": "readiness"}, timeout=5) or {}), 30, step=0.5)
        engine = rpc("debug.agent_pane", {"action": "engine"}) or {}
        LOAD["chat_panes"].append(engine.get("pane"))
        note(f"load: agent chat {engine.get('pane')} ({engine.get('engine')}) ready={bool(ready)} {json.dumps(reply)[:120]}")
    if surface_ws:
        cli("workspace", surface_ws, "focus")
    note(f"load: {opts.busy} busy terminals ({visible} visible), {len(LOAD['chat_panes'])} agent chats")


def chat_streams():
    panes = [p for p in LOAD["chat_panes"] if p]
    if not panes:
        return None

    replies = LOAD.setdefault("stream_replies", [])

    def step(_):
        for pane in panes:
            reply = rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": 40, "seconds": 3, "chunk_ms": 30}, timeout=10)
            if len(replies) < 4 or (isinstance(reply, dict) and reply.get("error")):
                replies.append(json.dumps(reply)[:200])
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


GENERIC = ("start", "main", "NSApplicationMain", "_DPSNextEvent", "_DPSBlockUntilNextEventMatchingListInMode", "ReceiveNextEventCommon",
           "_BlockUntilNextEventMatchingListInMode", "RunCurrentEventLoopInMode", "__CFRunLoopRun", "_CFRunLoopRunSpecificWithOptions",
           "CFRunLoopRunSpecific", "__CFRunLoopDoObservers", "__CFRunLoopDoSources0", "__CFRunLoopDoSource1", "__CFRUNLOOP_IS_CALLING_OUT",
           "_dispatch_main_queue_drain", "_dispatch_main_queue_callback_4CF", "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__",
           "_dispatch_client_callout", "-[NSApplication run]", "withExtendedLifetime", "__debug_main_executable_dylib_entry_point",
           "CmuxNextApp.main()", "partial apply for closure #1 in CmuxNextApp.main()", "closure #1 in CmuxNextApp.main()",
           "-[NSApplication(NSEventRouting) nextEventMatchingMask", "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask")


def digest_sample(text):
    """The main thread of a `sample` report: busy share, and the heaviest frames inclusive (each counted once per
    path), all and ours (the cmux dylib), and leaves. Percent of all main-thread samples (idle included)."""
    graph = text.split("Call graph:", 1)[-1].splitlines()
    lines, started = [], False
    for line in graph:
        if "com.apple.main-thread" in line:
            started = True
            continue
        if started and re.match(r"^\s{4}\d+ Thread_", line):
            break
        if started:
            lines.append(line)
    inclusive, ours, leaf, stack = {}, {}, {}, []
    total = idle = 0
    for i, line in enumerate(lines):
        m = re.match(r"^([\s+!:|]*)(\d+)\s+(.+?)\s+\(in ([^)]+)\)", line)
        if not m:
            continue
        depth, count, name, image = len(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        total = max(total, count)
        if name not in {n for _, n in stack}:
            inclusive[name] = inclusive.get(name, 0) + count
            if "cmux DEV" in image and not name.startswith(("closure", "thunk", "partial apply", "reabstraction")):
                ours[name] = ours.get(name, 0) + count
        stack.append((depth, name))
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        nm = re.match(r"^([\s+!:|]*)\d+\s", nxt)
        if not nm or len(nm.group(1)) <= depth:
            leaf[name] = leaf.get(name, 0) + count
            if name in ("mach_msg2_trap", "__workq_kernreturn"):
                idle += count
    pct_of = lambda c: round(100.0 * c / total, 1) if total else 0
    top = lambda d, n: [{"frame": k[:200], "pct": pct_of(v)} for k, v in sorted(d.items(), key=lambda kv: -kv[1])
                        if not k.startswith(GENERIC)][:n]
    return {"samples": total, "busy_pct": pct_of(total - idle), "top": top(inclusive, 60), "ours": top(ours, 40), "leaves": top(leaf, 25)}


def measure(surface, phase, params, column, pid, streams=()):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.timings", {"clear": True})
    rows_before = len(probe_rows())
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
    # debug.view_churn (which views ask for display or layout while the keys are typed) exists only in a probe
    # build (scratch branch pl-typing-view-churn, never landed: a DEBUG swizzle of NSView); elsewhere this records the error.
    rpc("debug.view_churn", {"action": "start"})
    rows, trips = type_keys(opts.samples, params, column)
    churn = rpc("debug.view_churn", {"action": "stop", "limit": 15}, timeout=20)
    for s in streams:
        s.stop()
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    timings = rpc("debug.timings", timeout=20) or {}
    publishes = [p.get("ms") for p in (timings.get("control_publishes") or []) if isinstance(p, dict)]
    every = probe_rows()[rows_before:]
    marks = ["dispatch_start_ms", "dispatch_end_ms", "io_write_ms", "socket_submit_ms", "output_decoded_ms",
             "output_received_ms", "output_parsed_ms", "contents_ms", "commit_ms"]
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
        "frames": frames, "streams": [s.calls for s in streams], "round": ROUND, "focus": LOAD.get("focus"),
        "view_churn": churn, "control_publishes": {"count": len(publishes), "ms": pct(publishes),
                                                   "total_ms": round(sum(publishes), 1)},
        "probe_rows": {"all": len(every), "complete": sum(r.get("complete") == "1" for r in every),
                       "marks": {m: sum(bool(r.get(m)) for r in every) for m in marks}},
        "stream_replies": LOAD.get("stream_replies", [])[:4],
    }
    if sampler:
        try:
            sampler[0].wait(timeout=opts.samples * opts.interval + 60)
        except subprocess.TimeoutExpired:
            sampler[0].terminate()
        entry["sample"] = os.path.basename(sampler[1])
        try:
            # The report is the fleet step's one artifact: keep the main thread's digest in it.
            entry["main_profile"] = digest_sample(open(sampler[1], errors="replace").read())
        except OSError:
            pass
    k = entry["key_to_frame_ms"] or {}
    note(f"{SESSION} {surface}.{phase}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} ms "
         f"(n={k.get('n')}/{len(trips)}); hangs {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}")
    results["runs"].append(entry)
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)
    return entry


def named_workspace(name):
    """The id of the workspace named `name`, and its panes (snapshot.get)."""
    for w in workspaces():
        if (w.get("name") or w.get("title")) == name:
            panes = [p for sc in w.get("screens") or [] for p in sc.get("panes") or [] if not p.get("dock")]
            return w.get("id"), panes
    return None, []


def focus_terminal():
    """Shows the typed terminal's workspace and gives its pane the keyboard; returns what has it (debug.focus)."""
    ws, pane = LOAD["terminal_ws"], LOAD.get("stress_pane") or LOAD.get("terminal_pane")
    rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": ws}, "focus": True, "origin": "script"})
    if pane:
        rpc("action.run", {"action": "pane.focus", "target": f"pane:{pane}", "focus": True, "origin": "script"})
    time.sleep(0.5)  # focus settles
    return focus_report()


def focus_report():
    report = rpc("debug.focus") or {}
    windows = [w for w in report.get("windows") or [] if isinstance(w, dict)]
    return {"resolved": report.get("resolved") or report.get("focus"),
            "first_responders": [(w.get("appkit") or {}).get("first_responder") for w in windows][:3]}


def surface_terminal(phase, pid):
    if not LOAD.get("terminal_ws"):
        cli("workspace", "create", "--name", "typing", "--focus", "--shell", "exec /bin/zsh -f")
        ws, panes = wait(lambda: (lambda r: r if r[0] else None)(named_workspace("typing")), 20) or (None, [])
        LOAD["terminal_ws"], LOAD["terminal_pane"] = ws, (panes[0].get("id") if panes else None)
        time.sleep(2)  # the prompt draws
    streams = []
    if phase == "load":
        make_load(LOAD["terminal_ws"])
        s = chat_streams()
        streams = [s] if s else []
    LOAD["focus"] = focus_terminal()
    entry = measure("terminal", phase, {}, "contents_ms", pid, streams)
    action("terminal.sendText", {"text": "\x15"})  # clears the typed line (Ctrl-U)
    return entry


def surface_home(phase, pid):
    # The Home fixture in a workspace of its own (a whole content area, in the light session and in STRESS).
    if not LOAD.get("home_ws"):
        cli("workspace", "create", "--name", "home typing", "--focus")
        ws, _ = wait(lambda: (lambda r: r if r[0] else None)(named_workspace("home typing")), 20) or (None, [])
        LOAD["home_ws"] = ws
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": ws}, "focus": True, "origin": "script"})
        time.sleep(1)  # the workspace shows
        opened = rpc("debug.home_native_fixture.open", {"new": True})
        note(f"home fixture in {ws}: {json.dumps(opened)[:160]}")
        time.sleep(2)  # the transcript lays out
    rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": LOAD["home_ws"]}, "focus": True, "origin": "script"})
    time.sleep(0.5)  # the workspace shows
    if phase == "load":
        make_load(None)
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"home: no composer to focus ({json.dumps(focused)[:160]})")
        return None
    streams = [home_stream()] if phase == "load" else []
    if phase == "load":
        s = chat_streams()
        if s:
            streams.append(s)
    LOAD["focus"] = focus_report()
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
    if phase == "load":
        make_load(None)
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
    LOAD["focus"] = focus_report()
    entry = measure("omnibar", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.key", {"key": "escape"})
    return entry


SURFACES = {"terminal": surface_terminal, "home": surface_home, "dock": surface_dock, "omnibar": surface_omnibar}


def run_session(session):
    """One launch of the app (scripts/cmux-next/bench_launch.py): the light session, or STRESS (built first); every
    surface and phase in it, --rounds times."""
    global app, SESSION, SOCKET, CONFIG
    SESSION = session
    LOAD.clear()
    LOAD.update({"made": False, "workspaces": [], "chat_panes": []})
    bench = BenchApp(APP, out=OUT, config={"browser": {"defaultEngine": "chromium"}}, window=WINDOW,
                     log_name=f"app-{session}.log",
                     env={"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"})
    try:
        try:
            bench.launch(timeout=180, settle=5.0)
        except LaunchError as error:
            note(f"{session}: the app did not come up: {error.reason}")
            results.setdefault("launch_failures", []).append({"session": session, "reason": error.reason,
                                                              "detail": error.report.get("detail")})
            return
        app, SOCKET, CONFIG = bench.process, bench.socket, os.path.join(bench.scratch, "cmux.json")
        if session == "stress":
            LOAD["terminal_ws"] = build_stress()
            time.sleep(5)  # the grid settles
        surfaces = opts.surfaces.split(",")
        global ROUND
        for ROUND in range(opts.rounds):
            for phase in opts.phases.split(","):
                for surface in surfaces:
                    if surface == "dock" and phase != "idle":
                        continue
                    try:
                        SURFACES[surface](phase, app.pid)
                    except Exception as error:  # one surface failing must not hide the others
                        note(f"{session} {surface}.{phase}: failed: {error!r}")
    finally:
        bench.stop()


def main():
    results["refresh_hz"] = refresh_hz()
    results["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    sessions = opts.sessions.split(",") if opts.sessions else (["stress"] if opts.stress else ["light"])
    try:
        for session in sessions:
            run_session(session)
    finally:
        summary = {}
        for r in results["runs"]:
            summary.setdefault(f"{r['session']}.{r['surface']}.{r['phase']}", []).append((r["key_to_frame_ms"] or {}).get("p95"))
        results["summary_p95_ms"] = summary
        note(f"summary p95 ms: {json.dumps(summary)} refresh {results.get('refresh_hz')}")
        if opts.json:
            json.dump(results, open(opts.json, "w"), indent=1)
    if opts.gate_p95_ms is not None:
        over = {k: v for k, v in results["summary_p95_ms"].items() if any(x is not None and x > opts.gate_p95_ms for x in v)}
        if over or not results["summary_p95_ms"]:
            print(f"FAIL key-to-frame p95 over {opts.gate_p95_ms} ms: {over or 'nothing measured'}", flush=True)
            sys.exit(1)
        print(f"PASS key-to-frame p95 within {opts.gate_p95_ms} ms", flush=True)


if __name__ == "__main__":
    main()
