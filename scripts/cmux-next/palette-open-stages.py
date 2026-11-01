#!/usr/bin/env python3
"""Key-down to first painted frame of the Command Palette (Cmd-Shift-P) and Go to Workspace (Cmd-P), per focused
surface, on a tagged cmux-next build (palette-open-latency).

Launches the tagged app itself (no activation, scratch config, empty Ghostty config), makes one pane with a
terminal, a Chromium page, a WebKit page, a Markdown file and Home, then for each tab (selected by a click on the
tab strip) presses Cmd-Shift-P and Cmd-P through `debug.key` (the key router's real path; for Chromium also with
the page window as the key window, `target: page`), and closes the palette with Escape. Per open,
`debug.timings` reports (ms):
  input    the key-down's age when the palette began to open (key router, action dispatch)
  model    the page's items and first results;  panel  creating the panel (zero once made)
  present  placing, ordering in and focusing the panel;  commit  layout, display and the Core Animation commit
  key      input + model + panel + present + commit: key-down to the committed first frame
plus rpc_ms, the synchronous `debug.key` round trip (the main thread's whole key handling), and the longest
main-thread stall during the open (`debug.hangs`). Builds without the input stage report key = ms + 0.

The budget: a warm open commits within one 60 Hz frame (key p90 <= 16 ms).

--search-keys WORD times typed keys on Search instead (palette-key, PaletteModel.search): from the terminal tab it
opens Search (Cmd-Shift-A) --rounds times and types WORD one key at a time through `debug.key` (target palette).
Per key: rpc_ms, the synchronous `debug.key` round trip (the main thread's whole handling of the key, its search()
turn included); the always-on signposts key.palette_query_rows (the query's edit to the commit of the frame that
first shows its final ranked rows) and key.palette_query_answer (to the frame that first shows the agent chats'
answer for it, with its row count), read with perf-signposts.py's `log stream` recording (a Release or bench build
has them too); and the longest main-thread stall while the word is typed (`debug.hangs`). Each as p50/p95/p99/max.
The key p95 <= 4 ms budget (`// perf-hot: 4ms palette-key`) is reported, never gated.
--seed-chats N writes N Claude Code transcripts where acpmux's chat index reads them: the app runs with a HOME of its
own under /tmp, and the transcripts go in its `.claude/projects` (a default root of cmux-chat-index's roots table;
acpmux's own session store is not indexed, and the daemon gets HOME but not CLAUDE_CONFIG_DIR). The account's own
~/.claude is never read or written; the app's control socket stays in the account's state folder.
Each chat's first prompt is "Idle cost chat <i>: tidy the build scripts", so type a word they match ("idle"). Before
typing, the bench asks the app's acpmux for the word until its index answers with rows (window_total > 0), and
refuses to measure otherwise.
--stress builds the STRESS session (perf-stress-session.py) before typing. STRESS needs a 1600 x 1000 pt window, which a
1920 x 1080 display under the menu bar and Dock cannot hold: --vdisplay HZ first makes a 1920 x 1200 virtual main
display (scripts/ci/frame-pacing/vdisplay.m, as split-spring.sh --vdisplay) for the run.

Usage: palette-open-stages.py --tag <tag> --app PATH [--rounds 10] [--interval 0.35] [--out DIR] [--json PATH]
                              [--search-keys WORD] [--seed-chats N] [--stress]
"""
import argparse, glob, importlib.util, json, os, re, signal, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True, help="the tagged .app bundle")
parser.add_argument("--rounds", type=int, default=10, help="opens per surface and key")
parser.add_argument("--interval", type=float, default=0.35, help="seconds between an open and its close")
parser.add_argument("--budget-ms", type=float, default=16.0)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json", help="write the samples here")
parser.add_argument("--no-gate", action="store_true", help="report only; exit 0 when every open was timed")
parser.add_argument("--search-keys", help="time typed keys of this word on Search (Cmd-Shift-A), not palette opens")
parser.add_argument("--seed-chats", type=int, default=0, help="stored chats in the app's acpmux store (--search-keys)")
parser.add_argument("--stress", action="store_true", help="build the STRESS session before typing (--search-keys)")
parser.add_argument("--vdisplay", type=float, help="run on a 1920x1200 virtual main display at this refresh rate (Hz)")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"paletteopen-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
STAGES = ["input", "model", "panel", "present", "commit", "key", "rpc"]
KEYS = [("Cmd-Shift-P", {"key": "p", "modifiers": ["command", "shift"]}), ("Cmd-P", {"key": "p", "modifiers": ["command"]})]
ROWS, LAUNCHED = [], []
app = None


def run(*args, timeout=30):
    env = {**ENV, "CMUX_TAG": TAG, "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


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


def action(name, args=None, timeout=60):
    # origin script: the control socket refuses origin user (dc82dca5497), so every setup open failed.
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)


def wait(check, seconds, step=0.25):
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


def panes():
    return [p for w in ((rpc("debug.surfaces") or {}).get("windows") or []) for p in w.get("panes", [])]


def focused_pane():
    return next((p for p in panes() if p.get("focused")), None)


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def strip_tabs(minimum):
    """The focused strip's tabs as (id-or-label, center point in window coordinates)."""
    for strip in (rpc("debug.tab_drag") or {}).get("strips") or []:
        tabs = strip.get("tabs") or []
        if len(tabs) >= minimum:
            out = []
            for tab in tabs:
                f = tab["frame"]
                f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)
                out.append((tab.get("id") or tab.get("label"), [f[0] + f[2] * 0.4, f[1] + f[3] / 2]))
            return out
    return []


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def one_open(params):
    """One open and close: the open's timing row, or None when the palette did not report an open."""
    rpc("debug.timings", {"clear": True})
    rpc("debug.hangs", {"clear": True})
    started = time.monotonic()
    reply = rpc("debug.key", params)
    rpc_ms = (time.monotonic() - started) * 1000
    time.sleep(opts.interval)  # test harness: the open's commit lands
    opens = (rpc("debug.timings") or {}).get("palette_opens") or []
    hangs = rpc("debug.hangs") or {}
    closed = rpc("debug.key", {"key": "escape", "target": "palette"})
    if isinstance(closed, dict) and closed.get("error"):
        rpc("debug.key", {"key": "escape"})
    time.sleep(0.25)  # test harness: the close animation ends before the next open
    if not opens:
        return None, reply
    o = opens[-1]
    sample = {s: o.get(f"{s}_ms") for s in ["input", "model", "panel", "present", "commit"]}
    sample["input"] = sample["input"] or 0.0
    sample["key"] = o.get("key_to_frame_ms") or (o.get("ms", 0) + sample["input"])
    sample["rpc"] = round(rpc_ms, 2)
    sample["created_panel"] = o.get("created_panel")
    sample["stall_max_ms"] = hangs.get("max_ms")
    sample["stalls"] = [{"ms": r.get("duration_ms"), "frames": [f for f in r.get("frames", []) if "Cmux" in f or "cmux" in f][:14]}
                        for r in (hangs.get("records") or [])[-2:]]
    return sample, reply


def search_typing(word):
    """Opens Search and types WORD a key at a time: each key's debug.key round trip (ms), the query frames
    (the signposts are recorded around all rounds) and the typing's longest stall."""
    rpc("debug.key", {"key": "a", "modifiers": ["command", "shift"]})
    time.sleep(opts.interval)  # test harness: Search opens and its first rows land
    rpc("debug.hangs", {"clear": True})
    keys = []
    for char in word:
        started = time.monotonic()
        rpc("debug.key", {"key": "space" if char == " " else char, "target": "palette"})
        keys.append(round((time.monotonic() - started) * 1000, 3))
        time.sleep(0.12)  # test harness: a typing pace; the key's rank and answers land between keys
        # The chat rows on screen for this key (Search's Agent Chats section; at the base, ranked chat rows).
        shown = (rpc("debug.palette.capture", {"rows": True}) or {}).get("rows") or []
        CHAT_ROWS.append(sum(1 for row in shown if str(row).startswith("chat:")))
    time.sleep(0.4)  # test harness: the last key's answer lands
    hangs = rpc("debug.hangs") or {}
    closed = rpc("debug.key", {"key": "escape", "target": "palette"})
    if isinstance(closed, dict) and closed.get("error"):
        rpc("debug.key", {"key": "escape"})
    rpc("debug.key", {"key": "escape", "target": "palette"})
    time.sleep(0.25)  # test harness: the close animation ends before the next open
    return keys, hangs.get("max_ms")


def distribution(values):
    return {"n": len(values), "p50": round(pct(values, 0.5), 3), "p95": round(pct(values, 0.95), 3),
            "p99": round(pct(values, 0.99), 3), "max": round(max(values), 3)} if values else {"n": 0}


def load_signposts():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-signposts.py")
    spec = importlib.util.spec_from_file_location("perf_signposts", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def search_report(word):
    print(f"\n== Search typed keys: {word!r}, {opts.rounds} rounds", flush=True)
    search_typing(word)  # warm
    signposts = load_signposts()
    recording = signposts.Recording(app.pid, ["key"])
    keys, stalls = [], []
    try:
        for _ in range(opts.rounds):
            times, stall = search_typing(word)
            keys += times
            if stall is not None:
                stalls.append(stall)
    finally:
        parsed = signposts.parse(recording.stop(), None)
    intervals = [i for i in parsed["intervals"] if not i.get("missed")]
    rows = [i["ms"] for i in intervals if i["name"] == "key.palette_query_rows"]
    answered = [i for i in intervals if i["name"] == "key.palette_query_answer"]
    answers = [i["ms"] for i in answered]
    answer_rows = [int((i.get("end_fields") or {}).get("rows") or 0) for i in answered]
    print(f"  signposts: {len(parsed['intervals'])} paired, {parsed['unpaired']} unpaired (queries typed past), "
          f"{parsed['lost']} lost", flush=True)
    diagnosis = acpmux_diagnosis(word)
    print(f"  acpmux for {word!r}: {json.dumps(diagnosis)[:400]}", flush=True)
    measured_chats = CHAT_ROWS[-len(keys):] if keys else []
    with_chats = sum(1 for n in measured_chats if n > 0)
    print(f"  chat rows on screen per key: {with_chats}/{len(measured_chats)} keys showed chats "
          f"(mean {round(sum(measured_chats) / len(measured_chats), 1) if measured_chats else 0})", flush=True)
    if not keys:
        row("Search typed keys", "keys timed", "none", False)
        return {}
    table = {"key_rpc": distribution(keys), "key_to_rows_frame": distribution(rows),
             "key_to_answer_frame": distribution(answers), "stall_max_ms": max(stalls) if stalls else None,
             "answers": len(answers), "answer_rows_mean": round(sum(answer_rows) / len(answer_rows), 1) if answer_rows else 0}
    for name in ("key_rpc", "key_to_rows_frame", "key_to_answer_frame"):
        d = table[name]
        cells = " ".join(f"{k}={d[k]}" for k in ("n", "p50", "p95", "p99", "max") if k in d)
        print(f"  Search {name} ms: {cells}", flush=True)
    print(f"  answers landed: {table['answers']} (mean {table['answer_rows_mean']} chat rows); "
          f"stall_max={table['stall_max_ms']}", flush=True)
    row("Search typed keys", "key rpc p95 <= 4 ms (report only)",
        f"p95 {table['key_rpc'].get('p95')} ms, {len(keys)} keys", True)
    if opts.seed_chats:
        # The base has no answer path (its chats are ranked rows): chats on screen is the check that holds for both.
        row("Search chats shown", "chat rows on screen after typed keys", f"{with_chats}/{len(measured_chats)} keys",
            with_chats > 0)
    table["keys_with_chat_rows"] = with_chats
    table["chat_rows_mean"] = round(sum(measured_chats) / len(measured_chats), 1) if measured_chats else 0
    return {"table": table, "samples": keys, "rows": rows, "answers": answers, "stalls": stalls, "acpmux": diagnosis,
            "chat_rows": measured_chats}


def acpmux_diagnosis(word):
    """What the app's own acpmux holds for `word`, asked on its socket like the app (report only): its daemon's
    ACPMUX_HOME, whether its index is ready, and the rows its window gives the query."""
    import bench_memory as bm  # noqa: E402  (FakeChats.acpmux_socket: the bundle's daemon socket)
    try:
        sock_path = bm.FakeChats.acpmux_socket(APP)
    except SystemExit as error:
        return {"error": f"no acpmux daemon of this bundle: {error}"}
    homes = [cmd for _, _, cmd in bm.process_table() if "/bin/acpmux daemon run" in cmd and cmd.startswith(APP)]
    out = {"socket": sock_path, "daemons": len(homes)}
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(20)
        conn.connect(sock_path)
        request = {"jsonrpc": "2.0", "id": 7, "method": "_acpmux/chats_window",
                   "params": {"window": "bench.diag", "gen": 1, "limit": 5, "topLevel": True, "query": word, "count": True}}
        conn.sendall((json.dumps(request) + "\n").encode())
        buf, deadline = b"", time.monotonic() + 20
        while time.monotonic() < deadline and not ("answer" in out and "window_rows" in out):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == 7:
                    out["answer"] = message.get("result") or message.get("error")
                elif message.get("method") == "_acpmux/chats_window_changed":
                    params = message.get("params") or {}
                    out["window_rows"] = len(params.get("keys") or [])
                    out["window_total"] = params.get("total")
            if (out.get("answer") or {}).get("ready") is False and "window_rows" not in out:
                break
        conn.close()
    except OSError as error:
        out["error"] = str(error)
    return out


def seed_chats(count):
    """`count` Claude Code transcripts in a HOME of the bench's own (`<home>/.claude/projects`); that HOME.

    Under /tmp, not the step's temp dir: a worker's temp dir may be on another volume, where no chat root is listed
    (cmux-tui/crates/acpmux/tests/chats_window.rs). One second apart, a day ago, so acpmux's newest-first order is
    known. Each is the one user record Claude Code writes first (cmux-chat-index's claude adapter reads its prompt)."""
    home = tempfile.mkdtemp(prefix="palbench-home-", dir="/tmp")
    projects = os.path.join(home, ".claude", "projects")
    day_ago = time.time() - 86_400
    for i in range(count):
        session = f"00000000-0000-4000-8000-{i:012d}"
        folder = os.path.join(projects, f"-work-p{i % 40}")
        os.makedirs(folder, exist_ok=True)
        record = {"type": "user", "isSidechain": False, "cwd": f"/work/p{i % 40}", "sessionId": session,
                  "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(day_ago + i)),
                  "message": {"role": "user", "content": f"Idle cost chat {i}: tidy the build scripts"}}
        path = os.path.join(folder, f"{session}.jsonl")
        with open(path, "w") as handle:
            handle.write(json.dumps(record) + "\n")
        os.utime(path, (day_ago + i, day_ago + i))
    print(f"seeded chats: {count} Claude Code transcripts under {projects}", flush=True)
    return home


def wait_for_index(word, seconds=180):
    """Asks the app's acpmux for `word` until its index answers with rows; the last diagnosis."""
    deadline = time.monotonic() + seconds
    diagnosis = {}
    while time.monotonic() < deadline:
        diagnosis = acpmux_diagnosis(word)
        if (diagnosis.get("window_total") or diagnosis.get("window_rows") or 0) > 0:
            break
        time.sleep(3)  # test harness: the index scans the seeded transcripts in the background
    print(f"acpmux index for {word!r}: {json.dumps(diagnosis)[:400]}", flush=True)
    return diagnosis


def summarize(label, samples):
    line = {}
    for stage in STAGES:
        values = [s[stage] for s in samples if s.get(stage) is not None]
        if values:
            line[stage] = {"p50": round(pct(values, 0.5), 2), "p90": round(pct(values, 0.9), 2), "max": round(max(values), 2)}
    cells = " ".join(f"{st}={line[st]['p50']}/{line[st]['p90']}" for st in STAGES if st in line)
    print(f"  {label:<26} n={len(samples):<3} p50/p90 ms: {cells}", flush=True)
    worst = max(samples, key=lambda s: s.get("key") or 0, default=None)
    if worst and worst.get("stalls"):
        for stall in worst["stalls"]:
            print(f"    stall {stall['ms']} ms: " + " < ".join(str(f)[:70] for f in stall["frames"]), flush=True)
    return line


def cleanup():
    print("cleanup", flush=True)
    if VDISPLAY is not None and VDISPLAY.poll() is None:
        VDISPLAY.terminate()  # the helper this script started; its display arrangement goes with it
    if os.environ.get("PALETTEOPEN_KEEP") or not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    for _ in range(2):
        ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[2].startswith(APP + "/") and int(parts[0]) != os.getpid():
                print("leftover", line[:160], flush=True)
                try:
                    os.kill(int(parts[0]), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(3)  # test harness: let them exit
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


VDISPLAY = None
CHAT_ROWS = []  # chat rows on screen after each typed key (search_typing)


def start_vdisplay(hz):
    """A 1920x1200 virtual main display at `hz` (split-spring.sh's helper), for STRESS's 1600x1000 window."""
    global VDISPLAY
    repo = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    folder = os.path.join(SCRATCH, "vdisplay", "VDisplay.app", "Contents")
    os.makedirs(os.path.join(folder, "MacOS"), exist_ok=True)
    binary = os.path.join(folder, "MacOS", "VDisplay")
    built = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wno-deprecated-declarations", "-framework", "AppKit",
                            "-framework", "CoreVideo", os.path.join(repo, "scripts/ci/frame-pacing/vdisplay.m"), "-o", binary],
                           capture_output=True, text=True)
    if built.returncode != 0:
        raise SystemExit(f"palette-open: the virtual display helper did not compile: {built.stderr[-600:]}")
    with open(os.path.join(repo, "scripts/ci/frame-pacing/VDisplay-Info.plist")) as src, open(os.path.join(folder, "Info.plist"), "w") as dst:
        dst.write(src.read())
    subprocess.run(["codesign", "-s", "-", "--force", os.path.dirname(folder)], capture_output=True)
    out = open(os.path.join(SCRATCH, "vdisplay", "out"), "w+")
    VDISPLAY = subprocess.Popen([binary, str(hz), "3600", "main", "1920x1200"], stdout=out, stderr=subprocess.DEVNULL)
    line = ""
    for _ in range(20):
        out.seek(0)
        line = next((l for l in out.read().splitlines() if l.startswith(("ready", "error"))), "")
        if line or VDISPLAY.poll() is not None:
            break
        time.sleep(1)  # test harness: a bounded wait for the helper's own ready line
    if not line.startswith("ready"):
        raise SystemExit(f"palette-open: no virtual display ({line or 'no line'})")
    print(f"vdisplay: {line}", flush=True)
    time.sleep(2)  # test harness: WindowServer settles the new main display before the app opens on it


def main():
    global app, SOCKET
    if opts.vdisplay:
        start_vdisplay(opts.vdisplay)
    # No socket check here: BenchApp.launch() refuses a live same-tag app (any bundle path) and unlinks only a
    # socket nothing accepts on.
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    if opts.search_keys and opts.seed_chats:
        env["HOME"] = seed_chats(opts.seed_chats)
    # One launch path (bench_launch.py): socket in the state folder, bench env, a clear reason when it does not come up.
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False, env=env)
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    ENV["CMUX_SOCKET_PATH"] = SOCKET
    print(f"launched pid {app.pid}", flush=True)
    made = run("workspace", "create", "--name", "paletteopen-e2e")
    tab = re.search(r"value\.tab_id\s+(tab_\S+)", made.stdout)
    workspace = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
    if workspace:
        run("workspace", workspace.group(1), "focus")
    for index in range(1, 10):
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        if wait(lambda: any(tab and p.get("selected_tab") == tab.group(1) for p in panes()), 3):
            break
    if not wait(lambda: (focused_pane() or {}).get("kind") == "terminal", 30):
        row("setup", "a focused terminal", json.dumps(panes())[:400], False)
        return
    time.sleep(2)  # test harness: shell prompt
    if opts.search_keys:
        if opts.stress:
            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-stress-session.py")
            spec = importlib.util.spec_from_file_location("perf_stress_session", path)
            stress = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(stress)
            summary = stress.Stress(rpc, log=lambda message: print(message, flush=True)).build()
            print("STRESS-SESSION", json.dumps(summary)[:600], flush=True)
        if opts.seed_chats:
            index = wait_for_index(opts.search_keys.split()[0])
            if not ((index.get("window_total") or index.get("window_rows") or 0) > 0) and not str(index.get("error") or "").startswith("no acpmux"):
                row("acpmux index", f"rows for {opts.search_keys!r} before typing", json.dumps(index)[:300], False)
        report = {"tag": TAG, "stress": opts.stress, "seed_chats": opts.seed_chats, "search_keys": search_report(opts.search_keys)}
        if opts.json:
            with open(opts.json, "w") as handle:
                json.dump(report, handle, indent=1)
        return
    page = os.path.join(SCRATCH, "page.html")
    open(page, "w").write("<!doctype html><title>palette page</title><body style='background:#2980b9;color:white;font:40px "
                          "-apple-system'><input autofocus>" + "<p>palette page row</p>" * 60)
    markdown = os.path.join(SCRATCH, "notes.md")
    open(markdown, "w").write("# Palette open\n\n" + "\n".join(f"- item {i} with `code` and **bold**" for i in range(200)) + "\n")
    kinds = ["terminal"]
    steps = [("chromium", lambda: action("openBrowser.chromium", {"url": "file://" + page}, timeout=120)),
             ("webkit", lambda: action("openBrowser.webkit", {"url": "file://" + page})),
             ("markdown", lambda: action("openMarkdownFile", {"path": markdown})),
             ("home", lambda: action("home.tab"))]
    for name, make in steps:
        before = len(strip_tabs(1))
        reply = make()
        print(f"open {name}: {json.dumps(reply)[:200]}", flush=True)
        if not wait(lambda: len(strip_tabs(1)) > before, 60):
            row(f"setup: {name}", f"{before + 1} tabs", f"{len(strip_tabs(1))}", False)
            continue
        kinds.append(name)
        time.sleep(1.5)  # test harness: the page loads before the next tab
    tabs = strip_tabs(len(kinds))
    print("tabs:", [t[0] for t in tabs], "kinds:", kinds, flush=True)
    # Warm: one open and close of each palette, as after launch idle.
    for _, params in KEYS:
        one_open(params)
    report = {"tag": TAG, "kinds": kinds, "surfaces": {}}
    print("\n== palette opens", flush=True)
    for index, kind in enumerate(kinds):
        if index >= len(tabs):
            break
        rpc("debug.mouse", {"action": "click", "x": tabs[index][1][0], "y": tabs[index][1][1]})
        time.sleep(1.0)  # test harness: the tab shows and takes focus
        if kind in ("chromium", "webkit"):
            # The page has the keyboard, as after a click into it.
            rpc("debug.key", {"key": "tab"}, timeout=10)
            time.sleep(0.3)  # test harness: focus moves into the page
        targets = [(kind, {})] + ([("chromium page window", {"target": "page"})] if kind == "chromium" else [])
        for label, extra in targets:
            for key_label, params in KEYS:
                samples, missed, last_reply = [], 0, None
                for _ in range(opts.rounds):
                    sample, reply = one_open({**params, **extra})
                    if sample is None:
                        missed += 1
                        last_reply = reply
                    else:
                        samples.append(sample)
                name = f"{label} {key_label}"
                if not samples:
                    row(name, "palette opened", f"no open timed: {json.dumps(last_reply)[:200]}", False)
                    continue
                line = summarize(name, samples)
                report["surfaces"][name] = {"table": line, "samples": samples, "missed": missed}
                key_p90 = line.get("key", {}).get("p90", 1e9)
                row(name, f"key-down to frame p90 <= {opts.budget_ms} ms, {opts.rounds} opens",
                    f"p90 {key_p90} ms, {len(samples)} timed", (opts.no_gate or key_p90 <= opts.budget_ms) and missed == 0)
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(report, handle, indent=1)
        print("wrote", opts.json, flush=True)


try:
    main()
except Exception as error:  # noqa: BLE001  (a bench step: print why, the finally block exits with the rows)
    import traceback
    traceback.print_exc()
    sys.stdout.flush()
    row("bench", "ran to the end", f"{type(error).__name__}: {str(error)[:300]}", False)
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
