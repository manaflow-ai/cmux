#!/usr/bin/env python3
"""Tagged-app check of the docked Home's actions (cx-ebm.59.5, classic Home off).

Home is the home workspace with the `home-dock` tab in a left dock (Messages by default; this check switches it
to Channels first with home.switchView, home-channels-entry.py checks the two entries). Through the app's
control socket only (`action.run`, no system input) it checks:
- home.show shows Home and the sidebar's Home item is the selected item;
- home.openConversation {conversation} is not refused: the docked page goes to
  `#/conversation/<id>` (the page's own route) and the dock pane has the keyboard;
- home.newMessage, home.newChief and home.invite without arguments are not refused: the page goes
  to `#/new/message`, `#/new/chief`, `#/new/invite` (the page draws its own sheet there);
- openSettings with the keyboard in the dock opens the Settings tab beside the dock, not in it.
Screenshots of each step. Runs on cmux-lawrence-2 through
`nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-dock-actions.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with
quitEndSessions, endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP,
NX_ARTIFACTS.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG = os.environ["NX_APP"], os.environ["NX_APP_TAG"]
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-dock-actions"), os.environ.get("NX_APP_STOP", "")
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h6da-", dir="/tmp")
HOME, CHIEF = os.path.join(SCRATCH, "home"), os.path.join(SCRATCH, "chief")
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


def run(action, arguments=None):
    params = {"id": action, "focus": True}
    if arguments:
        params["arguments"] = arguments
    return rpc("action.run", params) or {}


def refused(reply):
    text = json.dumps(reply)
    return "error" in reply or "not ready" in text or '"refused"' in text or reply.get("ok") is False


def page():
    return rpc("debug.page", {"page": "cmux.home-channels", "action": "state"}) or {}


def fragment():
    state = page()
    return state.get("fragment") or state.get("hash") or state.get("route") or (state.get("url") or "").partition("#")[2]


def at_route(route):
    return poll(lambda: ("#" + route) in ("#" + str(fragment()).lstrip("#")) and fragment(), 20)


def shot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + ".png")}, 60)


def panes():
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    return sorted((windows[0] if windows else {}).get("panes") or [], key=lambda p: (p.get("cell") or [0])[0])


def focused_pane():
    windows = (rpc("debug.focus") or {}).get("windows") or [{}]
    return (windows[0].get("model") or {}).get("resolved_pane")


os.makedirs(os.path.join(CHIEF, "optchat"), exist_ok=True)
os.makedirs(HOME, exist_ok=True)
open(os.path.join(CHIEF, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(CHIEF, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
# Channels is off by default (cx-frn2y); this check uses both views.
open(os.path.join(SCRATCH, "cmux.json"), "w").write('{"home": {"channelsEnabled": true}}')
open(os.path.join(SCRATCH, "ghostty"), "w").write("")
env = {k: v for k, v in os.environ.items() if k in ("USER", "LOGNAME", "TMPDIR", "SHELL", "LANG")}
env.update({"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
            "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(SCRATCH, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1500,940", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
            "CMUX_NEXT_CHIEF_HOME": CHIEF})
env.pop("CMUX_NEXT_CLASSIC_HOME", None)
if os.path.exists(SOCK):
    os.unlink(SOCK)
app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, cwd=OUT, stdin=subprocess.DEVNULL,
                       stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
print("launched pid %d" % app.pid, flush=True)
try:
    poll(lambda: os.path.exists(SOCK) and (rpc("debug.windows") or {}).get("windows"), 240)
    shown = poll(lambda: (lambda r: None if refused(r) else r)(run("home.show")), 120)
    check("home.show is not refused", bool(shown), run("home.show"))
    switched = poll(lambda: (lambda r: None if refused(r) else r)(run("home.switchView", {"view": "channels"})), 60)
    check("home.switchView {view: channels} is not refused", bool(switched), run("home.switchView", {"view": "channels"}))
    painted = poll(lambda: page().get("painted"), 120)
    check("the docked home-channels page paints", bool(painted), page())
    items = lambda: [i for w in (rpc("debug.sidebar_rows") or {}).get("windows") or [] for i in w.get("items") or []]
    home_item = poll(lambda: [i for i in items() if "home" in (str(i.get("ref")) + str(i.get("id"))).lower() and i.get("active")], 20)
    check("the sidebar Home item is selected after home.show", bool(home_item), items())
    shot("1-home")

    # A local channel through the Home data path, then open it from the action.
    stamp = str(int(time.time()))
    poll(lambda: "conversations" in (rpc("debug.home.api", {"call": "inbox"}) or {}), 180)
    created = rpc("debug.home.api", {"call": "submit", "op": {"kind": "create_group", "title": "dock-%s" % stamp, "participants": []}}) or {}
    conversation = created.get("conversation")
    if check("a local channel", bool(conversation), created):
        rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": conversation, "text": "dock check %s" % stamp}})
        reply = run("home.openConversation", {"conversation": conversation})
        check("home.openConversation is not refused", not refused(reply), reply)
        check("the docked page opens the conversation route", bool(at_route("/conversation/" + conversation)), page())
        dock = (panes() or [{}])[0].get("pane")
        check("the dock pane has the keyboard after home.openConversation", focused_pane() == dock and dock is not None,
              {"dock": dock, "focused": focused_pane()})
        # The same conversation again after the person moved on: the route opens it again.
        again = run("home.openConversation", {"conversation": conversation})
        check("home.openConversation again is not refused", not refused(again), again)
        shot("2-open-conversation")

    for action, route in (("home.newMessage", "/new/message"), ("home.newChief", "/new/chief"), ("home.invite", "/new/invite")):
        reply = run(action)
        check("%s without arguments is not refused" % action, not refused(reply), reply)
        check("%s opens the page route %s" % (action, route), bool(at_route(route)), page())
        shot("3-" + action.split(".")[1])

    # P2: a page tab opened with the keyboard in the dock opens beside the dock.
    dock = (panes() or [{}])[0].get("pane")
    rpc("debug.mouse", {"pane": dock, "action": "click"})
    check("the keyboard is in the dock before openSettings", focused_pane() == dock, {"dock": dock, "focused": focused_pane()})
    run("openSettings")
    # The Settings tab takes the keyboard where it opened: a pane that is not the dock.
    moved = poll(lambda: (lambda f: f if f and f != dock else None)(focused_pane()), 30)
    check("Settings opens beside the dock, not in it", bool(moved) and moved in [p.get("pane") for p in panes()],
          {"dock": dock, "focused": moved, "panes": [p.get("pane") for p in panes()]})
    shot("4-settings-beside-dock")
finally:
    reply = rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print("app pid %d did not quit within 60 s" % app.pid, flush=True)
    rpc("action.run", {"id": "endAgents"}, timeout=10)
    for acp in (os.path.join(CHIEF, "acpmux"), os.path.join(HOME, ".acpmux")):
        if os.path.isdir(acp):
            subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env=dict(env, ACPMUX_HOME=acp), capture_output=True, timeout=30)
    if STOP:
        subprocess.run([STOP], capture_output=True, timeout=180)
    shutil.rmtree(SCRATCH, ignore_errors=True)

print("%d failed: %s" % (len(failures), failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
