#!/usr/bin/env python3
"""Window live-resize feel: films of a window corner drag over a chat transcript (Leo 2026-11-22, #50940:
"chat bubbles lag behind the edge and re-wrap late").

  window-resize-feel.py --app "/path/cmux DEV x.app" --out DIR [--mode window|pane|both] [--rounds 1]
                        [--steps 150] [--chats 2] [--prompts 12] [--fake-agent PATH]

Launches the app (no activation, automation socket, own config, a fake ACP harness), opens `--chats` agent chat
panes beside a terminal, each with `--prompts` markdown prompts echoed back by the fake agent, then drags one
`debug.mouse` event per 120 Hz frame (`--steps` events a drag), out and back twice a round:
  window: the bottom-right corner, out by 300 x 150 points (AppKit's own live resize reads the events).
  pane:   the first pane divider, by `--pane-delta` (150) points sideways.
Each round is filmed by the app's own recorder (`debug.motion` record_start, filter display) as feel-<mode>-<n>.mov,
with `debug.frames` display-link intervals and the CEF tracker's fence/commit deltas in report.json. Every
CMUX_CEF_* variable of this process's environment reaches the app (the resize-sync deadline arms of
window-resize-feel.sh). Judges nothing: the films are read by a person or a frame analysis. Kills only its own app.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time
# cmux NEXT's config folder: `cmux-next` on macOS (cmux-config NEXT_DIR, location.rs; #53567).
NEXT_DIR = "cmux-next" if sys.platform == "darwin" else "cmux"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)
except ImportError:
    def safe_print(*args, **kwargs):
        try:
            print(*args, **kwargs)
        except (BrokenPipeError, OSError, ValueError):
            pass

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
parser.add_argument("--app", help="the .app to run (default: the tagged DerivedData build)")
parser.add_argument("--out", required=True)
parser.add_argument("--mode", choices=["window", "pane", "both"], default="both")
parser.add_argument("--rounds", type=int, default=1)
parser.add_argument("--steps", type=int, default=150)
parser.add_argument("--sample", action="store_true")
parser.add_argument("--chats", type=int, default=2)
parser.add_argument("--prompts", type=int, default=12)
parser.add_argument("--page", action="store_true", help="also a New Tab page (web view) pane")
parser.add_argument("--pane-delta", type=int, default=150)
parser.add_argument("--start", default="20,30,1100,680", help="window x,y,w,h in points")
parser.add_argument("--fake-agent", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                         "../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
parser.add_argument("--summarize", metavar="REPORT", help="only print the summary of a report.json")
opts = parser.parse_args()
opts.out = os.path.abspath(opts.out)  # ACPMUX_SOCKET and the config are read relative to the app, so they are absolute
os.makedirs(opts.out, exist_ok=True)
APP = opts.app or next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV*.app"))), None)
if not APP or not os.path.isdir(APP):
    sys.exit(f"no app for tag {opts.tag} (pass --app)")
TAG = opts.tag or os.path.basename(APP.rstrip("/"))[len("cmux DEV "):-len(".app")]
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    plist = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", plist["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
START = [int(v) for v in opts.start.split(",")]
FAKE_AGENT = os.path.abspath(opts.fake_agent)
MODES = ["window", "pane"] if opts.mode == "both" else [opts.mode]


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


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def pct(values, p):
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))], 2) if ordered else None


def focused_pane():
    windows = (rpc("debug.focus") or {}).get("windows") or [{}]
    return windows[0].get("layout_focused_pane")


def target(pane):
    return f"pane:{pane}" if pane else None


PROMPT = ("Transcript line @N@: the quick brown fox jumps over the lazy dog.\n\n"
          "- a list item with `inline code` and **bold** text\n- another item with a [link](https://example.com)\n\n"
          "```swift\nfunc layout(_ width: Double) -> Double { width * 0.5 + @N@ }\n```\n\n"
          "A longer paragraph so the message wraps at several widths and the transcript has real text to reflow: "
          "pane resize and window resize both change the width this paragraph is laid out in. " * 2)


CHAT_PANES = []


def chat_pane(term):
    """Opens an agent chat (the React transcript page): the action opens its own pane beside `term`. It runs on the
    fake harness and is filled with prompts."""
    def opened():
        st = rpc("debug.agent_pane", {"action": "chat_state"}, timeout=40)  # the focused agent pane's page
        found = st.get("pane") if isinstance(st, dict) and "error" not in st else None
        return found if found and found not in CHAT_PANES else None
    pane = None
    for _ in range(3):  # a first chat under load can take the action without opening: ask again
        report.setdefault("chat_open_replies", []).append(str(rpc("action.run", {"action": "palette.newAgentChat", "target": target(term), "focus": True}))[:200])
        pane = wait(opened, 45, 1)
        if pane:
            break
    CHAT_PANES.append(pane)
    def ready():
        st = rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, timeout=40)
        return isinstance(st, dict) and "error" not in st
    wait(ready, 90, 1)

    replies = []

    def new_chat():
        reply = rpc("debug.agent_pane", {"action": "new_chat", "pane": pane, "harness": "fake"}, timeout=60)
        replies.append(reply)
        return isinstance(reply, dict) and "error" not in reply and reply
    chat = wait(new_chat, 90, 2)
    time.sleep(2)
    sent = 0
    if chat:
        rpc("debug.mouse", {"pane": pane, "action": "click"})
        for n in range(opts.prompts):
            reply = rpc("debug.agent_pane", {"action": "send_prompt", "pane": pane, "text": PROMPT.replace("@N@", str(n))}, timeout=60)
            sent += 0 if isinstance(reply, dict) and reply.get("error") else 1
            time.sleep(1.0)  # the fake agent echoes it back (harness wait)
    def settled():  # the fake agent has echoed every prompt back
        st = rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, timeout=40)
        return isinstance(st, dict) and not st.get("isWorking") and not any(p.get("pending") for p in st.get("prompts") or [])
    wait(settled, 60, 2)
    state = rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, timeout=40)
    shown = {k: state.get(k) for k in ("harness", "connection", "sessionId", "rows", "isWorking")} | {"prompts_pending": sum(1 for p in state.get("prompts") or [] if p.get("pending"))} if isinstance(state, dict) else state
    return {"pane": pane, "chat": bool(chat), "prompts_sent": sent, "state": shown, "new_chat_replies": [str(r)[:300] for r in replies[-2:]]}


def summarize(rep):
    """One line per mode: each round's number, then the mean over rounds, for the app's own frame report and the event round trip."""
    keys = [("p50_ms", "frame p50"), ("p95_ms", "frame p95"), ("p99_ms", "frame p99"), ("max_ms", "frame max"),
            ("missed", "missed vsyncs"), ("over_16_7_ms", "frames >16.7ms"), ("main_p95_ms", "main p95"), ("main_max_ms", "main max")]
    lines = []
    for mode in ("window", "pane"):
        rows = [r for r in rep.get("results", []) if r["mode"] == mode]
        if not rows:
            continue
        lines.append(f"{mode} ({len(rows)} rounds, {rows[0]['events']} events each, frames recorded: {[r['frames'].get('frames') for r in rows]})")
        for key, label in keys:
            vals = [r["frames"].get(key) for r in rows]
            if all(isinstance(v, (int, float)) for v in vals):
                lines.append(f"  {label:15s} {[round(v, 2) for v in vals]} mean {round(sum(vals) / len(vals), 2)}")
        for key in ("p50", "p95"):
            vals = [r["event_rpc_ms"][key] for r in rows]
            lines.append(f"  event rtt {key:5s} {vals} mean {round(sum(vals) / len(vals), 2)}")
    safe_print("\n".join(lines), flush=True)
    rep["summary"] = lines


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
for tag_state in (os.path.expanduser(f"~/Library/Application Support/cmux-next/tags/{TAG}"),
                  os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")):
    if os.path.isdir(tag_state) and not os.path.islink(tag_state):  # a clean start; the old state is kept aside
        os.rename(tag_state, f"{tag_state}.old-{int(time.time())}")
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
acp_home = os.path.join(opts.out, "acpmux")
xdg = os.path.join(opts.out, "xdg")
os.makedirs(os.path.join(xdg, NEXT_DIR, "harnesses"), exist_ok=True)
os.makedirs(acp_home, exist_ok=True)
profile = os.path.join(xdg, NEXT_DIR, "harnesses", "fake.toml")
with open(profile, "w") as f:
    f.write(f'id = "fake"\nname = "Fake"\ncommand = "/usr/bin/python3"\nargs = [{json.dumps(FAKE_AGENT)}]\n')
os.chmod(profile, 0o600)
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, START)),
       "ACPMUX_HOME": acp_home, "ACPMUX_SOCKET": os.path.join(tempfile.mkdtemp(prefix="rfl-", dir="/tmp"), "acpmux.sock"), "XDG_CONFIG_HOME": xdg}
env.update({k: v for k, v in os.environ.items() if k.startswith("CMUX_CEF_")})
report_env = {k: v for k, v in env.items() if k.startswith("CMUX_CEF_")}
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"cef_env": report_env, "tag": TAG, "app": APP, "pid": app.pid, "mode": opts.mode, "rounds": opts.rounds, "steps": opts.steps,
          "loadavg_start": os.getloadavg(), "bundle_version": plist.get("CFBundleVersion"),
          "commit": plist.get("CMUXCommit") or plist.get("CmuxCommit")}
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180):
        sys.exit("app did not come up")
    time.sleep(2)
    report["identify"] = rpc("system.identify")
    report["screens"] = rpc("debug.screens")
    # Sidebar shown; terminal | chat x N | New Tab page, side by side in one workspace.
    report["setup"] = [rpc("action.run", {"action": "newTab", "focus": True})]
    time.sleep(2)
    report["chats"] = []
    term = focused_pane()  # an agent chat pane cannot be split: every new pane comes off the terminal's
    for _ in range(opts.chats):
        report["chats"].append(chat_pane(term))
    if opts.page:
        report["setup"].append(rpc("action.run", {"action": "splitRight", "focus": True, "target": target(term)}))
        time.sleep(1.5)
        report["setup"].append(rpc("action.run", {"action": "newTab.page", "focus": True, "target": target(focused_pane())}))
    time.sleep(5)
    if not all(c["chat"] and c["prompts_sent"] for c in report["chats"]):
        sys.exit(f"an agent chat did not open: {report['chats']}")
    cef0 = rpc("debug.cef") or {}
    print("cef", json.dumps({k: v for k, v in cef0.items() if k not in ("tracker",)})[:3000], flush=True)
    print("cef_tracker", json.dumps(cef0.get("tracker"))[:1500], flush=True)
    if os.environ.get("CEF_ONLY"):
        sys.exit(0)
    layers = rpc("debug.layers")
    with open(os.path.join(opts.out, "layers.json"), "w") as f:
        json.dump(layers, f, indent=1)

    def divider():
        layer = ((rpc("debug.layers") or {}).get("windows") or [{}])[0]
        areas = layer.get("divider_areas_in_window") or []
        return areas[0] if areas else None

    def size():
        return (((rpc("debug.layers") or {}).get("windows") or [{}])[0]).get("frame")

    period = 1 / 120

    def drag_pass(mode, latencies):
        """Four drags (out, back, out, back) at 120 Hz; returns each one's window size before and after."""
        rounds = []
        for out in (True, False, True, False):
            before = size()
            div_before = divider()
            w, h = before[2], before[3]
            if mode == "window":
                x0, y0 = w - 1, h - 1
                dx, dy = (300, 150) if out else (-300, -150)
            else:
                hover = rpc("debug.mouse", {"divider": "first", "action": "hover"}) or {}
                if hover.get("x") is None:
                    sys.exit(f"no pane divider: {hover}")
                x0, y0 = hover["x"], hover["y"]
                dx, dy = (opts.pane_delta if out else -opts.pane_delta), 0
            rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
            started = time.monotonic()
            for step in range(1, opts.steps + 1):
                t = step / opts.steps
                x, y = x0 + dx * t, y0 + dy * t
                t0 = time.monotonic()
                rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
                latencies.append((time.monotonic() - t0) * 1000)
                next_at = started + step * period
                if next_at > time.monotonic():
                    time.sleep(max(0.0, next_at - time.monotonic()))
            rpc("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
            time.sleep(0.5)
            rounds.append({"before": before, "after": size(), "wall_s": round(time.monotonic() - started, 2),
                           "divider_before": div_before, "divider_after": divider()})
        return rounds

    report["results"] = []
    schedule = [(m, r) for r in range(1, opts.rounds + 1) for m in MODES]
    for mode, rnd in schedule:
        latencies = []
        movie = os.path.abspath(os.path.join(opts.out, f"feel-{mode}-{rnd}.mov"))
        print("record", json.dumps(rpc("debug.motion", {"action": "record_start", "path": movie, "seconds": 40, "filter": "display"}))[:300], flush=True)
        for _ in range(40):
            st = rpc("debug.motion", {"action": "record_read"}) or {}
            if "capturing" in json.dumps(st) or "error" in json.dumps(st):
                break
            time.sleep(0.25)
        print("read", json.dumps(st)[:300], flush=True)
        time.sleep(0.5)
        rpc("debug.frames", {"action": "start"})
        tracker0 = (rpc("debug.cef") or {}).get("tracker") or {}
        drags = drag_pass(mode, latencies)
        frames = rpc("debug.frames", {"action": "stop"})
        tracker1 = (rpc("debug.cef") or {}).get("tracker") or {}
        fence = {k: round(tracker1.get(k, 0) - tracker0.get(k, 0), 2) for k in tracker1 if k.startswith("fence") or k.startswith("commit") or k in ("detaches", "attaches", "geometry_posts")}
        print("fence", mode, json.dumps(fence), flush=True)
        rpc("debug.motion", {"action": "record_stop"})
        for _ in range(40):
            st = rpc("debug.motion", {"action": "record_read"}) or {}
            if "written" in json.dumps(st) or "error" in json.dumps(st):
                break
            time.sleep(0.25)
        print("stopped", json.dumps(st)[:400], flush=True)
        resized = all(d["before"] and d["after"] and (d["before"][2] != d["after"][2]) == (mode == "window")
                       and (mode == "window" or d["divider_before"] != d["divider_after"]) for d in drags)
        result = {"fence": fence, "mode": mode, "round": rnd, "drags": drags, "frames": frames, "resized_as_expected": resized,
                  "events": len(latencies),
                  "event_rpc_ms": {"p50": pct(latencies, 0.5), "p95": pct(latencies, 0.95), "p99": pct(latencies, 0.99),
                                   "max": round(max(latencies), 2) if latencies else None}}
        report["results"].append(result)
        safe_print(json.dumps({k: result[k] for k in ("mode", "round", "frames", "event_rpc_ms", "resized_as_expected")}), flush=True)
    if opts.sample:
        for mode in MODES:
            seconds = int(4 * (opts.steps / 120 + 0.7)) + 3
            sampler = subprocess.Popen(["/usr/bin/sample", str(app.pid), str(seconds), "1",
                                        "-file", os.path.join(opts.out, f"sample-{mode}.txt")],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(1.0)
            drag_pass(mode, [])
            sampler.wait(120)
    summarize(report)
finally:
    report["loadavg_end"] = os.getloadavg()
    app.send_signal(signal.SIGTERM)
    try:
        app.wait(15)
    except subprocess.TimeoutExpired:
        app.kill()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    # The app's helpers (acpmux daemon, chief host, files host) outlive it: stop the ones this run's app started.
    left = subprocess.run(["/usr/bin/pgrep", "-f", APP], capture_output=True, text=True).stdout.split()
    for pid in left:
        if int(pid) not in (os.getpid(), os.getppid()):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except OSError:
                pass
