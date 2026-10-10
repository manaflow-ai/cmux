#!/usr/bin/env python3
"""Live check of All chats click-to-visible (cx-tr0w) on a tagged fleet build, on the GUI host only.

It writes Claude Code transcripts (a short one and a long one) into a scratch CLAUDE_CONFIG_DIR, starts
the build of `--job` with that directory, its own ACPMUX_HOME and config, opens All chats, and clicks
each chat's row through `debug.mouse` (a real mouse down and up on the row). After each click it
times, from the click:

- `pane_ms`: an agent pane in the focused pane shows its composer (`debug.agent_pane readiness`);
- `transcript_ms`: that pane shows transcript rows;
- the app's own phases (`debug.timings` `chat_opens`): the daemon's plan, the route, the outcome.

It also checks each row leads with its harness mark (`icon_shown`, `brand`). It fails when a click
shows no pane within `--budget-ms` (default 1000), or a row draws no mark. On exit (also a failure,
Ctrl-C or SIGTERM) it ends the tag's daemons (tag_teardown.py), by exact PID only.

Usage: chats-open-live.py --job <cmux-ci job id> --tag <the build's tag> [--budget-ms N] [--long-turns N]
Output: NX_ARTIFACTS (or /tmp/chats-open-live): live.log, report.json, app.log.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time, uuid

parser = argparse.ArgumentParser()
parser.add_argument("--job", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--budget-ms", type=float, default=1000)
parser.add_argument("--long-turns", type=int, default=1500)
opts = parser.parse_args()
OUT = os.environ.get("NX_ARTIFACTS") or "/tmp/chats-open-live"
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


# 1. The fleet build.
zip_path = os.path.join(OUT, "app.zip")
if not os.path.exists(zip_path):
    subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True)
app_dir = os.path.join(OUT, "app")
if not os.path.isdir(app_dir):
    subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
if not APP:
    sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
HOME_ACP = os.path.join(OUT, "acpmux-home")
ACP_SOCKET = f"/tmp/chats-open-acp-{os.getpid()}.sock"


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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


# 2. Transcripts: one short chat and one long one, each in its own real folder.
CLAUDE = os.path.join(OUT, "claude-config")
WORK = os.path.realpath(os.path.join(OUT, "work"))
os.makedirs(WORK, exist_ok=True)


def transcript(title, turns):
    session = str(uuid.uuid4())
    folder = os.path.join(CLAUDE, "projects", WORK.replace("/", "-"))
    os.makedirs(folder, exist_ok=True)
    parent = None
    with open(os.path.join(folder, session + ".jsonl"), "w") as f:
        for turn in range(turns):
            for kind in ("user", "assistant"):
                record_id = str(uuid.uuid4())
                text = title if turn == 0 and kind == "user" else f"{kind} line {turn}: " + "lorem ipsum " * 20
                content = text if kind == "user" else [{"type": "text", "text": text}]
                f.write(json.dumps({
                    "type": kind, "uuid": record_id, "parentUuid": parent, "sessionId": session, "cwd": WORK,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - 600 + turn)),
                    "message": {"role": kind, "content": content},
                }) + "\n")
                parent = record_id
    return session


SESSIONS = {transcript("chats-open-live short chat", 3): "short",
            transcript("chats-open-live long chat", opts.long_turns): "long"}
say("sessions", SESSIONS)

# 3. The app, with its own state, config, acpmux home and Claude directory.
TAG_STATE = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{opts.tag}")
if os.path.isdir(TAG_STATE) and not os.path.islink(TAG_STATE):
    os.rename(TAG_STATE, TAG_STATE + ".old-" + str(int(time.time())))
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
os.makedirs(HOME_ACP, exist_ok=True)
config = os.path.join(OUT, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = dict(os.environ)
env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800",
            "ACPMUX_HOME": HOME_ACP, "ACPMUX_SOCKET": ACP_SOCKET, "CLAUDE_CONFIG_DIR": CLAUDE})
TEARDOWN = TagTeardown(APP, acpmux_home=HOME_ACP, acpmux_socket=ACP_SOCKET, log=say)
TEARDOWN.install()
app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(OUT, "app.log"), "a"),
                       stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
say("started app pid", app.pid)
report = {"app_pid": app.pid, "budget_ms": opts.budget_ms, "clicks": []}
failures = []


def chats():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return (windows[0].get("chats"), windows[0].get("window")) if windows else (None, None)


def click(frame, window):
    return rpc("debug.mouse", {"window": window, "x": frame["x"] + frame["width"] / 2,
                               "y": frame["y"] + frame["height"] / 2})


def readiness():
    state = rpc("debug.agent_pane", {"action": "readiness"}, timeout=10) or {}
    return None if "error" in state else state


try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        raise SystemExit("the app did not come up")
    section, window = wait(lambda: (lambda c: c if c[0] else None)(chats()), 30) or (None, None)
    if not section:
        raise SystemExit("no All chats section in the sidebar")
    if not section["expanded"]:
        say("open All chats", click(section["header_frame"], window))
    rows = wait(lambda: (lambda c: c[0]["rows"] if c[0] and len([r for r in c[0]["rows"]
                if r["id"].split(":", 1)[-1] in SESSIONS]) == len(SESSIONS) else None)(chats()), 60, 0.5)
    if not rows:
        raise SystemExit(f"All chats never listed the seeded chats: {json.dumps(chats())[:1500]}")
    for row in rows:
        if row["id"].split(":", 1)[-1] in SESSIONS and not (row["icon_shown"] and row["brand"]):
            failures.append(f"row {row['title']!r} draws no harness mark: {row}")
    say("rows", json.dumps(rows)[:2000])
    for session, name in SESSIONS.items():
        _, window = chats()
        row = next(r for r in chats()[0]["rows"] if r["id"].split(":", 1)[-1] == session)
        rpc("debug.timings", {"clear": True})
        before = (readiness() or {}).get("pane")
        clicked = time.monotonic()
        reply = click(row["window_frame"], window)
        pane_ms = transcript_ms = None
        deadline = clicked + max(10, opts.budget_ms / 1000 * 5)
        while time.monotonic() < deadline and transcript_ms is None:
            state = readiness()
            now = (time.monotonic() - clicked) * 1000
            if state and state.get("pane") == before:
                state = None  # the pane shown before the click, not the chat's
            if state and state.get("composer_visible") and pane_ms is None:
                pane_ms = now
            if state and pane_ms is not None and (state.get("transcript_rows") or 0) > 0:
                transcript_ms = now
            time.sleep(0.02)
        chat_state = rpc("debug.agent_pane", {"action": "chat_state"}, timeout=10)
        timings = rpc("debug.timings") or {}
        opens = timings.get("chat_opens") if "error" not in timings else timings
        result = {"chat": name, "session": session, "click": reply, "pane_ms": pane_ms, "transcript_ms": transcript_ms,
                  "app": opens, "session_shown": session in json.dumps(chat_state), "readiness": readiness()}
        say("CLICK", json.dumps(result)[:2500])
        report["clicks"].append(result)
        if pane_ms is None or pane_ms > opts.budget_ms:
            failures.append(f"{name}: no agent pane within {opts.budget_ms:.0f} ms (pane_ms={pane_ms}, app={opens})")
    rpc("action.run", {"action": "quit", "wait": False}, timeout=10)
    wait(lambda: app.poll() is not None, 30, 0.5)
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)  # the PID launched here
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    TEARDOWN.end()
    report["failures"] = failures
    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
for failure in failures:
    say("FAIL", failure)
say("PASS" if not failures else f"FAILED ({len(failures)})")
sys.exit(1 if failures else 0)
