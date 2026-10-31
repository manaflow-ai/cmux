#!/usr/bin/env python3
"""The agent chat in WebKit against Chromium (the `agent.chromium` Debug toggle spike).

Launches a tagged DEBUG app once per mode, with the mock agent host, and measures the chat:
  own       the pane's own WebKit host (what ships)
  page      the shared page host in WebKit (`agent.pageHost`), to separate the host from the engine
  chromium  the shared page host in Chromium (`agent.chromium`, `browser.defaultEngine: chromium`)

Per mode: the engine that showed the chat (`debug.agent_pane engine`); time from the open action to
the first text and to a visible composer, for the first chat and for each of `--chats` more; memory
(physical footprint of the app, its Chromium helpers and the WebKit processes it is responsible
for, bench_memory.py) at launch, with one chat and with `--chats`; flings over 5000 seeded rows; and
typing latency in the composer (keydown to the next frame and to its paint, the page's own
typingStats) for `--keys` keys sent with `debug.key`. With `--activate` the app runs active and the
report adds which window holds the keys once the chat is focused (a Chromium page is its own child
window). Runs on a fleet mini, never a laptop:
  agent-engine-bench.py --tag TAG --app BUNDLE [--modes own,page,chromium] [--chats 10] [--json FILE]
"""
import argparse, glob, json, os, signal, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory  # noqa: E402
from bench_launch import LaunchError, launch_app, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--modes", default="own,page,chromium")
parser.add_argument("--chats", type=int, default=10)
parser.add_argument("--keys", type=int, default=40)
parser.add_argument("--flings", type=int, default=3)
parser.add_argument("--settle", type=float, default=10)
parser.add_argument("--activate", action="store_true", help="run the app active, to see which window takes the keys")
parser.add_argument("--open", action="store_true",
                    help="launch through LaunchServices (`open -n`), for a shell outside the console's GUI session (ssh)")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
parser.add_argument("--shots", help="a folder: light and dark screen captures of the open session in each mode, with the window glass on")
opts = parser.parse_args()
# LaunchServices reports the real path (/private/tmp for /tmp), so match processes by it.
TAG, APP = opts.tag, os.path.realpath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
TUNABLES = {"own": {"agent.chromium": False}, "page": {"agent.pageHost": True, "agent.chromium": False}, "chromium": {"agent.chromium": True}}
app = None


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


def pane(action, timeout=30, **params):
    return rpc("debug.agent_pane", dict(params, action=action), timeout=timeout) or {}


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


def median(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 1) if values else None


def open_chat():
    """Opens a chat; ms from the action to the first text and to a visible composer, and its engine."""
    start = time.monotonic()
    reply = rpc("action.run", {"action": "palette.newAgentChat"})
    error = reply.get("error") if isinstance(reply, dict) else None
    # The socket answers after about 2 s; an action still running then goes on, so wait for the page.
    if error and not (isinstance(error, dict) and (error.get("data") or {}).get("state") == "in_progress"):
        return {"error": error}
    content = interactive = None
    deadline = start + 30
    while time.monotonic() < deadline and interactive is None:
        ready = pane("readiness", timeout=5)
        now = round((time.monotonic() - start) * 1000, 1)
        if content is None and (ready.get("body_text_length") or 0) > 0:
            content = now
        if ready.get("composer_visible") and ready.get("document_ready"):
            interactive = now
        time.sleep(0.02)  # test harness: poll the page about once a frame
    return {"content_ms": content, "interactive_ms": interactive, "engine": pane("engine").get("engine")}


def memory(label, chats):
    got = bench_memory.sample(app.pid, APP, label, chats)
    return {"total_footprint_mb": got["total_footprint_mb"], "kinds": got["kinds"]}


def open_session():
    """A fresh chat shows the start screen, not the composer: ms from opening a mock session to its composer."""
    start = time.monotonic()
    pane("select_session", session="mock-session")
    ready = wait(lambda: (lambda r: r if r.get("composer_visible") else None)(pane("readiness", timeout=5)), 30, step=0.02)
    return {"composer_ms": round((time.monotonic() - start) * 1000, 1) if ready else None,
            "transcript_rows": (ready or {}).get("transcript_rows")}


def typing():
    pane("reset_typing")
    focused = pane("focus_composer").get("focused")
    # The chat's pane, not the focused one: keys for a Chromium page go to that pane's page window.
    target = {"target": "page", "pane": pane("engine").get("pane")} if pane("engine").get("engine") == "cef" else {}
    letters = "abcdefghijklmnopqrstuvwxyz"
    replies = []
    for index in range(opts.keys):
        replies.append(rpc("debug.key", dict(target, key=letters[index % len(letters)])))
        time.sleep(0.08)  # test harness: about a fast typist's pace
    time.sleep(0.5)  # test harness: the last key's frame lands
    errors = [r.get("error") for r in replies if isinstance(r, dict) and r.get("error")]
    return {"composer_focused": focused, "first_key_reply": replies[0] if replies else None, "key_errors": len(errors),
            "composer_text_length": pane("readiness").get("composer_text_length"), **pane("typing_stats")}


def screen_shots(mode):
    """The screen with the chat's session open, light then dark: the screen, not the app's own snapshot,
    since only the window server composites a Chromium page window over the glass under it."""
    if not opts.shots:
        return None
    os.makedirs(opts.shots, exist_ok=True)
    taken = {}
    for look in ("light", "dark"):
        rpc("debug.appearance", {"mode": look})
        time.sleep(3)  # test harness: the theme reload and the page's repaint land
        # screencapture takes one file per display; a single-display mini writes only d1.
        names = [os.path.join(opts.shots, f"{mode}-{look}-d{n}.png") for n in (1, 2)]
        done = subprocess.run(["/usr/sbin/screencapture", "-x", "-o", *names], capture_output=True, text=True, timeout=30)
        taken[look] = {"files": [n for n in names if os.path.exists(n)], "error": done.stderr.strip() or None}
    rpc("debug.appearance", {"mode": "system"})
    taken["windows"] = rpc("debug.window_list")
    return taken


def focus_probe():
    if not opts.activate:
        return None
    subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to activate'], capture_output=True, timeout=30)
    time.sleep(1)  # test harness: activation settles
    focused = pane("focus_composer").get("focused")
    time.sleep(0.5)  # test harness: focus settles
    report = rpc("debug.focus") or {}
    windows = [w for w in report.get("windows", []) if isinstance(w, dict)]
    return {"composer_focused": focused, "app_active": report.get("app_active"), "key_window": report.get("key_window"),
            "shell_window_is_key": any(w.get("is_key") for w in windows),
            "first_responders": [(w.get("appkit") or {}).get("first_responder") for w in windows]}


class Launched:
    """An app LaunchServices started (`--open`): its pid, and a wait for it to exit."""

    def __init__(self, pid):
        self.pid = pid

    def wait(self, timeout):
        if not bench_memory.wait_gone(self.pid, timeout):
            raise subprocess.TimeoutExpired("open", timeout)


def launch(mode, scratch):
    global app, SOCKET
    config = os.path.join(scratch, "cmux.json")
    json.dump({"browser": {"defaultEngine": "chromium"}}, open(config, "w"))
    tunables = os.path.join(scratch, "debug-tunables.json")
    json.dump({"version": 1, "values": TUNABLES[mode]}, open(tunables, "w"))
    with open(os.path.join(scratch, "ghostty"), "w") as ghostty:
        if opts.shots:
            # The window glass (Liquid Glass under a 0.7 theme tint), so the captures show what a page does over it;
            # an empty config is an opaque window.
            ghostty.write("background-opacity = 0.7\nbackground-blur = macos-glass-regular\n")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local",
           "CMUX_NEXT_AGENT_PANE_MOCK": "1", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables,
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    if not opts.activate:
        env["CMUX_NEXT_NO_ACTIVATE"] = "1"
    log_path = os.path.join(opts.out, f"app-{TAG}-{mode}.log")
    if opts.open:
        # LaunchServices starts the app in the console user's GUI session, which a process
        # started over ssh is not in; the app gets this environment on top of the session's.
        pairs = [arg for key, value in env.items() if key not in ("HOME", "USER", "TMPDIR", "PATH")
                 for arg in ("--env", f"{key}={value}")]
        subprocess.run(["open", "-n", *([] if opts.activate else ["-g"]), "--stdout", log_path, "--stderr", log_path,
                        *pairs, APP], check=True, timeout=60)
        pid = wait(lambda: next((p for p, _, cmd in bench_memory.process_table() if bench_memory.is_binary(cmd, BINARY)), None), 60)
        if pid is None:
            return None
        app = Launched(pid)
    else:
        if opts.activate:
            env["CMUX_NEXT_NO_ACTIVATE"] = None  # bench_launch: not its default no-activate launch

        def started(process):
            global app
            app = process
        # One launch path (bench_launch.py): socket in the state folder, bench env, the reason when it does not come up.
        try:
            app, SOCKET = launch_app(APP, env, log_path, timeout=120, on_start=started)
        except LaunchError:
            return False
        return True
    return wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120)


def quit_app():
    global app
    if app is None:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    bench_memory.end_bundle(APP)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    app = None


def run_mode(mode):
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    if not launch(mode, tempfile.mkdtemp(prefix=f"agent-engine-{mode}-")):
        return {"error": "the tagged app did not come up"}
    time.sleep(opts.settle)  # test harness: launch settles before the baseline
    result = {"baseline": memory("baseline", 0)}
    first = open_chat()
    result["first_chat"] = first
    print(mode, "first chat", json.dumps(first), flush=True)
    time.sleep(opts.settle)  # test harness: the chat settles before it is measured
    result["one_chat"] = memory("one chat", 1)
    result["session"] = open_session()
    result["focus"] = focus_probe()
    result["shots"] = screen_shots(mode)
    result["typing"] = typing()
    pane("seed_rows", count=5000, timeout=60)
    time.sleep(3)  # test harness: the seeded transcript lays out
    pane("fling", seconds=3, wait=True, timeout=60)  # warms the transcript's layout, not reported
    result["flings"] = [pane("fling", seconds=3, wait=True, timeout=60) for _ in range(opts.flings)]
    more = [open_chat() for _ in range(opts.chats - 1)]
    result["more_chats"] = more
    time.sleep(opts.settle)  # test harness: the chats settle before they are measured
    result[f"chats_{opts.chats}"] = memory(f"{opts.chats} chats", opts.chats)
    base, one, many = (result[k]["total_footprint_mb"] for k in ("baseline", "one_chat", f"chats_{opts.chats}"))
    result["summary"] = {
        "engine": first.get("engine"), "engines_seen": sorted({c.get("engine") for c in [first] + more if c.get("engine")}),
        "first_content_ms": first.get("content_ms"), "first_interactive_ms": first.get("interactive_ms"),
        "next_content_ms_median": median(c.get("content_ms") for c in more),
        "next_interactive_ms_median": median(c.get("interactive_ms") for c in more),
        "first_chat_mb": round(one - base, 1), f"chats_{opts.chats}_mb": round(many - base, 1),
        "per_more_chat_mb": round((many - one) / max(1, opts.chats - 1), 1),
        "typing_to_frame": result["typing"].get("to_frame"), "typing_to_paint": result["typing"].get("to_paint"),
        "session_composer_ms": result["session"].get("composer_ms"),
        "typing_keys": result["typing"].get("keys"), "focus": result["focus"],
        "fling_dropped_frames": [f.get("dropped_frames") for f in result["flings"]],
        "fling_p95_ms": [f.get("p95_ms") for f in result["flings"]],
    }
    return result


def main():
    results = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "modes": {}}
    for mode in opts.modes.split(","):
        try:
            results["modes"][mode] = run_mode(mode)
        finally:
            quit_app()
        time.sleep(3)  # test harness: the last mode's processes leave
    print("\nSUMMARY", json.dumps({m: r.get("summary", r) for m, r in results["modes"].items()}, indent=1), flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        json.dump(results, open(opts.json, "w"), indent=1)
    return all("summary" in r for r in results["modes"].values())


ok = False
try:
    ok = main()
finally:
    quit_app()
sys.exit(0 if ok else 1)
