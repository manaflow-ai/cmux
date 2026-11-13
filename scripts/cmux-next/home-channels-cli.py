#!/usr/bin/env python3
"""Tagged-app check at the CLI/action boundary (hq-6d cx-frn2y follow-up, 2026-10-15):
- `home enable-channels` and `home disable-channels` by CLI name (what `cmux home ...` sends: action.run with cli
  true, origin cli, wait) succeed when nothing changes: disable while Channels is off, enable twice; the setting
  stays as it is (cmux.json);
- "Open Channels" (home.channels) is hidden while Channels is off: the palette's root list has no such row and the
  CLI's `home channels` is refused; with Channels on, the palette lists it and the CLI runs it.
Runs on cmux-lawrence-2 through
`nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-channels-cli.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with quitEndSessions,
endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP, NX_ARTIFACTS.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG = os.environ["NX_APP"], os.environ["NX_APP_TAG"]
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-channels-cli"), os.environ.get("NX_APP_STOP", "")
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser("~/.local/bin/cua-driver"))
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CHANNELS_ITEM = "client.channels"
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h6dk-", dir="/tmp")
HOME, CHIEF = os.path.join(SCRATCH, "home"), os.path.join(SCRATCH, "chief")
CONFIG = os.path.join(SCRATCH, "cmux.json")
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(SOCK)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": "socket: %s" % error}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + json.dumps(detail)[:800]), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    value = predicate()
    while not value and time.time() < deadline:
        time.sleep(0.25)  # test harness wait, not app code
        value = predicate()
    return value


def run(action, arguments=None, **extra):
    params = dict({"id": action, "focus": True}, **extra)
    if arguments:
        params["arguments"] = arguments
    return rpc("action.run", params) or {}


def refused(reply):
    text = json.dumps(reply)
    return "error" in reply or "not ready" in text or '"refused"' in text or reply.get("ok") is False


def dock():
    value = (rpc("debug.home") or {}).get("dock")
    return value if isinstance(value, dict) else {}


def shot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + ".png")}, 60)


def drive(action, **params):
    return rpc("debug.home.drive", dict(params, action=action)) or {}


def config_value():
    try:
        return (json.load(open(CONFIG)).get("home") or {}).get("channelsEnabled")
    except (OSError, ValueError):
        return None


def items():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return (windows[0].get("items") or []) if windows else []


def item(predicate):
    return next((i for i in items() if predicate(i)), None)


def home_item():
    return item(lambda i: (i.get("ref_kind") == "app" and i.get("ref") == "cmux/home") or (i.get("ref_kind") == "built_in" and i.get("ref") == "home"))


def channels_item():
    return item(lambda i: i.get("id") == CHANNELS_ITEM)


def page_fragment():
    state = rpc("debug.page", {"page": "cmux.home-channels", "action": "state"}) or {}
    return str(state.get("fragment") or state.get("hash") or state.get("route") or (state.get("url") or "").partition("#")[2])


def in_mode(mode, conversation=None, timeout=30):
    def ready():
        state = dock()
        if state.get("mode") != mode:
            return None
        if mode == "messages":
            ok = state.get("messages_visible") and (conversation is None or state.get("messages_shown") == conversation)
        else:
            ok = state.get("channels_visible") and (conversation is None or ("/conversation/" + conversation) in page_fragment())
        return state if ok else None
    return poll(ready, timeout)


os.makedirs(os.path.join(CHIEF, "optchat"), exist_ok=True)
os.makedirs(HOME, exist_ok=True)
open(os.path.join(CHIEF, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(CHIEF, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
open(CONFIG, "w").write("{}")
open(os.path.join(SCRATCH, "ghostty"), "w").write("")
env = {k: v for k, v in os.environ.items() if k in ("USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN")}
env.update({"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
            "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1500,940", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
            "CMUX_NEXT_CHIEF_HOME": CHIEF})
env.pop("CMUX_NEXT_CLASSIC_HOME", None)
env["CMUX_NEXT_NO_ACTIVATE"] = "1"  # socket-only check: the app never takes the front


def launch(n):
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, cwd=OUT, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
    print("launch %d: pid %d" % (n, app.pid), flush=True)
    poll(lambda: os.path.exists(SOCK) and (rpc("debug.windows") or {}).get("windows"), 240)
    return app


def quit_app(app):
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print("app pid %d did not quit within 60 s" % app.pid, flush=True)




def cli(name, **extra):
    return rpc("action.run", dict({"action": name, "cli": True, "origin": "cli", "wait": True}, **extra)) or {}


def palette_lists(title):
    path = os.path.join(SCRATCH, "palette-root.json")
    reply = rpc("debug.palette.entries", {"path": path}) or {}
    try:
        return title in open(path).read()
    except OSError:
        return {"error": reply}


app = launch(1)
try:
    poll(lambda: (lambda r: None if refused(r) else r)(run("home.show")), 120)
    check("Channels is off at launch", config_value() is None, config_value())
    reply = cli("home disable-channels")
    check("home disable-channels while off succeeds (nothing to change)", not refused(reply), reply)
    check("the setting stays unset after a no-op disable", config_value() is None, config_value())
    check("the palette has no Open Channels while Channels is off", palette_lists("Open Channels") is False, palette_lists("Open Channels"))
    reply = cli("home channels")
    check("the CLI's home channels is refused while Channels is off", refused(reply), reply)
    reply = cli("home enable-channels")
    check("home enable-channels runs", not refused(reply), reply)
    check("cmux.json has home.channelsEnabled true", bool(poll(lambda: config_value() is True, 15)), config_value())
    reply = cli("home enable-channels")
    check("home enable-channels again succeeds (nothing to change)", not refused(reply), reply)
    check("the setting stays true", config_value() is True, config_value())
    check("the palette lists Open Channels while Channels is on", bool(poll(lambda: palette_lists("Open Channels") is True, 10)), palette_lists("Open Channels"))
    reply = cli("home channels")
    check("the CLI's home channels runs while Channels is on", not refused(reply), reply)
    reply = cli("home disable-channels")
    check("home disable-channels runs", not refused(reply), reply)
    check("cmux.json has home.channelsEnabled false", bool(poll(lambda: config_value() is False, 15)), config_value())
    check("the palette has no Open Channels again", bool(poll(lambda: palette_lists("Open Channels") is False, 10)), palette_lists("Open Channels"))
finally:
    quit_app(app)
    rpc("action.run", {"id": "endAgents"}, timeout=10)
    for acp in (os.path.join(CHIEF, "acpmux"), os.path.join(HOME, ".acpmux")):
        if os.path.isdir(acp):
            subprocess.run([ACPMUX, "daemon", "shutdown"], env=dict(env, ACPMUX_HOME=acp), capture_output=True, timeout=30)
    if STOP:
        subprocess.run([STOP], capture_output=True, timeout=180)
    shutil.rmtree(SCRATCH, ignore_errors=True)

print("%d failed: %s" % (len(failures), failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
