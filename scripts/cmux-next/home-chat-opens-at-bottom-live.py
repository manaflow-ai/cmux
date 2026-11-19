#!/usr/bin/env python3
"""Live check that every Home chat opens at its newest message (https://github.com/manaflow-ai/cmux/issues/26397),
in a tagged app on the GUI lane (`nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA`).

On a scratch Chief home: `cmux chief new` makes a second Chief; both Chiefs' conversations get
MESSAGES long messages (debug.home.api submit, the owner's own send path). Then Home opens the
default Chief, the second Chief (home.openConversation: the path a list row's click takes), the
default Chief again and the second Chief again. Each open is followed by a window snapshot and the
transcript's scroll state (debug.home.drive geometry: `scrollOffset`, `scrollBottom`, `scrollTop`,
`pinned` when the build reports them; the snapshots otherwise).

Exit: 0 every open rested at the newest message (or the snapshots are the evidence, see the log);
1 an open did not; 2 the app or a conversation did not come up.
Usage: home-chat-opens-at-bottom-live.py --tag TAG --app APP [--out DIR] [--messages N]
"""
import argparse, json, os, random, shutil, socket, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
ap.add_argument("--app", default=os.environ.get("NX_APP"))
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
ap.add_argument("--messages", type=int, default=40)
opts = ap.parse_args()
if not opts.tag or not opts.app:
    sys.exit("home-chat-opens-at-bottom-live.py: --tag and --app (or NX_APP_TAG and NX_APP) are required")

TAG, APP = opts.tag, opts.app
macos = os.path.join(APP, "Contents/MacOS")
BINARY = next((os.path.join(macos, n) for n in sorted(os.listdir(macos)) if n.startswith("cmux")), os.path.join(macos, "cmux DEV"))
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCK = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix="cob-", dir="/tmp")
HOME_DIR = os.path.join(SCRATCH, "h")
RUN = "%04d" % random.randint(0, 9999)
os.makedirs(opts.out, exist_ok=True)
ROWS = []


def say(*parts):
    print(*parts, flush=True)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCK)
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


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness poll, not app code
    return None


def cli(*args, timeout=120):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_", "ACPMUX_"))}
    env["NO_COLOR"] = "1"
    p = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)
    return {"args": list(args), "exit": p.returncode, "stdout": p.stdout[-3000:], "stderr": p.stderr[-1500:]}


def home():
    return rpc("debug.home") or {}


def conversation_with(participant):
    return next((c for c in home().get("conversations", []) if participant in c.get("participants", [])), None)


def geometry():
    return (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("geometry") or {}


def shot(name):
    path = os.path.join(opts.out, f"{name}.png")
    say("snapshot", name, (rpc("debug.window_snapshot", {"path": path}) or {}).get("ok"))


def fill(conv_id, label):
    line = f"{label} message line that wraps across the bubble so the chat is much taller than the window."
    for i in range(opts.messages):
        text = f"{label} {RUN} #{i + 1}\n" + "\n".join([line] * 4)
        rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": conv_id, "text": text}}, timeout=60)


def open_and_check(conv_id, step):
    rpc("action.run", {"id": "home.openConversation", "args": {"conversation": conv_id}, "focus": True})
    shown = wait(lambda: (home().get("page") or {}).get("shown") == conv_id or geometry(), 30)
    # Pictures, statuses and the first page settle; the transcript must rest at the bottom after it.
    time.sleep(3)  # test harness: let the open settle before the snapshot
    g = geometry()
    shot(step)
    rest = None
    if "scrollOffset" in g and "scrollBottom" in g:
        rest = abs(g["scrollOffset"] - g["scrollBottom"]) < 1 and g.get("pinned", 1) == 1
    ROWS.append({"step": step, "conversation": conv_id, "shown": bool(shown), "at_newest": rest, "geometry": g})
    say("PASS" if rest else ("SEE-SNAPSHOT" if rest is None else "FAIL"), step, json.dumps(g)[:400])


def app_env():
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    return {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_CHIEF_HOME": HOME_DIR,
            "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
            "ACPMUX_AGENT_LAUNCH": "deny"}


if os.path.exists(SOCK):
    sys.exit(f"{SOCK} exists: another {TAG} app runs")
os.makedirs(os.path.join(HOME_DIR, "optchat"), exist_ok=True)
open(os.path.join(HOME_DIR, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(HOME_DIR, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
app = subprocess.Popen([BINARY], env=app_env(), stdout=log, stderr=log, stdin=subprocess.DEVNULL)
code = 2
try:
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300):
        say("FAIL: the app did not come up")
        raise SystemExit
    rpc("action.run", {"id": "home.show"})
    default = wait(lambda: conversation_with("agent_mux"), 180, step=1)
    if not default:
        say("FAIL: no default Chief conversation", json.dumps(home())[:800])
        raise SystemExit
    made = cli("chief", "new", "--name", f"Chief Two {RUN}", "--role", "second chief for the scroll check", "--chief-home", HOME_DIR, "--json")
    try:
        chief = json.loads(made["stdout"].strip().splitlines()[-1])["id"]
    except (ValueError, KeyError, IndexError):
        say("FAIL: chief new", json.dumps(made))
        raise SystemExit
    second = wait(lambda: conversation_with(chief), 120, step=1)
    if not second:
        say("FAIL: Home does not list the second Chief")
        raise SystemExit
    fill(default["id"], "Default")
    fill(second["id"], "Second")
    say("pins", json.dumps(((home().get("page") or {}).get("sidebar") or {}).get("pinned")))
    open_and_check(default["id"], "01-default-chief")
    open_and_check(second["id"], "02-second-chief-from-list")
    open_and_check(default["id"], "03-default-chief-again")
    open_and_check(second["id"], "04-second-chief-again")
    code = 1 if any(r["at_newest"] is False for r in ROWS) else 0
except SystemExit:
    pass
finally:
    json.dump({"rows": ROWS}, open(os.path.join(opts.out, "chat-opens-at-bottom.json"), "w"), indent=1)
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"app {app.pid} did not quit within 60 s; NX_APP_STOP ends it at job end")
    cli("chief", "shutdown", "--chief-home", HOME_DIR, timeout=150)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if code == 0 else f"FAIL {code}")
sys.exit(code)
