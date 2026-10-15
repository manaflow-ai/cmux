#!/usr/bin/env python3
"""Tagged-app check of the docked Home's two views (cx-ebm.59.5; Lawrence 2026-10-14: "bring imessage chief back
by default instead of slack", "easy way to open slack ... both must have parity").

Home is the home workspace with the `home-dock` tab in its left dock: a "Messages | Channels" switch at the top
left of its header, over the native Messages view (the default) or hq-ec's `home-channels` page. Through the app's
control socket (debug verbs and action.run; `debug.mouse` and `debug.key` post events to the app's own queue) it
checks:
- after home.show the dock shows the native Messages view, with the switch "Messages | Channels" at its top left
  and Messages selected; the native transcript shows the Chief conversation;
- a send in the native view (its own field and Return path, debug.home.drive) gets a Chief reply, and a tapback
  on that reply goes (skip with HOME_DOCK_SKIP_CHIEF=1 when no Chief harness is signed in);
- home.openConversation selects a conversation in the Messages view;
- a click on the switch's Channels segment shows the page at `#/conversation/<id>` (the same conversation);
- Ctrl-Option-Cmd-H (home.switchView) goes back to Messages with the same conversation, and again to Channels;
- home.switchView {view: messages} by action;
- a selection change inside the Channels page (another channel's row, then the keyboard's message), then
  Messages: the same conversation shows and the switch handed over the page's message (the native view has no
  message highlight yet, MessagesLab C4, so the message is checked in the hand-off);
- after a relaunch in Channels the dock opens Messages again.
Screenshots of each step. Runs on cmux-lawrence-2 through
`nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-dock-switch.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with quitEndSessions,
endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP, NX_ARTIFACTS.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG = os.environ["NX_APP"], os.environ["NX_APP_TAG"]
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-dock-switch"), os.environ.get("NX_APP_STOP", "")
SKIP_CHIEF = os.environ.get("HOME_DOCK_SKIP_CHIEF") == "1"
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h6ds-", dir="/tmp")
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


def dock():
    report = rpc("debug.home") or {}
    value = report.get("dock")
    return value if isinstance(value, dict) else {}


def shot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + ".png")}, 60)


def drive(action, **params):
    return rpc("debug.home.drive", dict(params, action=action)) or {}


def page_fragment():
    # The page's own location (debug.page), not the route the host asked for.
    state = rpc("debug.page", {"page": "cmux.home-channels", "action": "state"}) or {}
    return str(state.get("fragment") or state.get("hash") or state.get("route") or (state.get("url") or "").partition("#")[2])


def in_mode(mode, conversation=None):
    def ready():
        state = dock()
        if state.get("mode") != mode:
            return None
        if mode == "messages":
            ok = state.get("messages_visible") and (conversation is None or state.get("messages_shown") == conversation)
        else:
            ok = state.get("channels_visible") and (conversation is None or ("/conversation/" + conversation) in page_fragment())
        return state if ok else None
    return poll(ready, 30)


os.makedirs(os.path.join(CHIEF, "optchat"), exist_ok=True)
os.makedirs(HOME, exist_ok=True)
open(os.path.join(CHIEF, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(CHIEF, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
open(os.path.join(SCRATCH, "cmux.json"), "w").write("{}")
open(os.path.join(SCRATCH, "ghostty"), "w").write("")
env = {k: v for k, v in os.environ.items() if k in ("USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN")}
env.update({"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
            "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(SCRATCH, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1500,940", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
            "CMUX_NEXT_CHIEF_HOME": CHIEF})
if os.environ.get("HOME_DOCK_REAL_INPUT") == "1":
    env.pop("CMUX_NEXT_NO_ACTIVATE", None)
env.pop("CMUX_NEXT_CLASSIC_HOME", None)


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


app = launch(1)
try:
    shown = poll(lambda: (lambda r: None if refused(r) else r)(run("home.show")), 120)
    check("home.show is not refused", bool(shown), run("home.show"))
    state = in_mode("messages")
    check("the dock opens the native Messages view by default", bool(state), dock())
    state = state or dock()
    check("the switch reads Messages | Channels", state.get("switch_labels") == ["Messages", "Channels"], state)
    check("the switch has Messages selected", state.get("switch_selected") == 0, state)
    frame, box = state.get("switch_frame") or {}, state.get("dock_frame") or {}
    check("the switch is at the top left of the dock",
          frame.get("width", 0) > 0 and box.get("width", 0) > 0 and 0 <= frame["x"] - box["x"] <= 16 and 0 <= frame["y"] - box["y"] <= 16,
          {"switch": frame, "dock": box})
    chief = poll(lambda: dock().get("messages_shown"), 120)
    check("the Messages view shows the Chief conversation", bool(chief), dock())
    shot("1-messages-default")

    if SKIP_CHIEF:
        print("skip Chief reply (HOME_DOCK_SKIP_CHIEF=1)", flush=True)
    elif chief:
        stamp = str(int(time.time()))
        ask = "home dock check %s: reply with the single word pong" % stamp
        drive("focus")
        drive("type", text=ask)
        sent = drive("send")
        check("a send in the native view goes", not refused(sent), sent)
        mine = poll(lambda: ask in (dock().get("transcript_tail") or []), 60)
        check("the native view shows my message", bool(mine), dock())
        replied = poll(lambda: (lambda t: t if ask in t and t[-1] != ask else None)(dock().get("transcript_tail") or []), 300)
        check("the Chief replies in the native view", bool(replied), dock())
        if replied:
            tapback = drive("tapback")
            check("a tapback on the Chief's reply goes", tapback.get("ok") is True, tapback)
        shot("2-chief-reply")

    # A local channel through the Home data path, then open it from the action in the Messages view.
    stamp = str(int(time.time()))
    poll(lambda: "conversations" in (rpc("debug.home.api", {"call": "inbox"}) or {}), 180)
    created = rpc("debug.home.api", {"call": "submit", "op": {"kind": "create_group", "title": "switch-%s" % stamp, "participants": []}}) or {}
    conversation = created.get("conversation")
    if check("a local channel", bool(conversation), created):
        rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": conversation, "text": "switch check %s" % stamp}})
        poll(lambda: conversation in json.dumps(rpc("debug.home.api", {"call": "inbox"}) or {}), 30)
        reply = run("home.openConversation", {"conversation": conversation})
        check("home.openConversation is not refused", not refused(reply), reply)
        check("the Messages view selects the conversation", bool(in_mode("messages", conversation)), dock())

        # One click on the switch's Channels segment.
        frame = dock().get("switch_frame") or {}
        if frame:
            rpc("debug.mouse", {"action": "click", "x": frame["x"] + frame["width"] * 0.75, "y": frame["y"] + frame["height"] / 2})
        check("a click on Channels shows the page at the same conversation", bool(in_mode("channels", conversation)), dock())
        check("the switch has Channels selected", dock().get("switch_selected") == 1, dock())
        shot("3-channels-by-click")

        # The keyboard shortcut back and forth.
        rpc("debug.key", {"key": "h", "modifiers": ["control", "option", "cmd"]})
        check("Ctrl-Option-Cmd-H shows Messages at the same conversation", bool(in_mode("messages", conversation)), dock())
        shot("4-messages-by-shortcut")
        rpc("debug.key", {"key": "h", "modifiers": ["control", "option", "cmd"]})
        check("Ctrl-Option-Cmd-H again shows Channels at the same conversation", bool(in_mode("channels", conversation)), dock())

        reply = run("home.switchView", {"view": "messages"})
        check("home.switchView {view: messages} is not refused", not refused(reply), reply)
        check("home.switchView shows Messages at the same conversation", bool(in_mode("messages", conversation)), dock())
        reply = run("home.switchView")
        check("home.switchView with no view shows Channels", bool(in_mode("channels", conversation)), dock())
        shot("5-channels-by-action")

        # A selection change inside the Channels page (a click on another channel's row, then the keyboard's
        # message), then Messages: the switch hands over the page's conversation and message.
        other = (rpc("debug.home.api", {"call": "submit", "op": {"kind": "create_group", "title": "switch-b-%s" % stamp, "participants": []}}) or {}).get("conversation")
        if check("a second local channel", bool(other), other):
            for n in (1, 2):
                rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": other, "text": "switch b %s %d" % (stamp, n)}})
            row = '[data-list-row="%s"]' % other
            clicked = poll(lambda: (rpc("debug.page", {"page": "cmux.home-channels", "action": "click", "selector": row}) or {}).get("clicked"), 30)
            check("a click on the second channel's row in the page", bool(clicked), row)
            check("the page opens the second channel", bool(in_mode("channels", other)), page_fragment())
            # A real click on the timeline takes the keyboard off the composer; k then puts the page on the last message.
            box = dock().get("dock_frame") or {}
            if box:
                rpc("debug.mouse", {"action": "click", "x": box["x"] + box["width"] / 2, "y": box["y"] + box["height"] * 0.45})
            rpc("debug.key", {"key": "k"})
            messages = (rpc("debug.home.api", {"call": "snapshot", "conversation": other}) or {}).get("messages") or []
            last = messages[-1].get("id") if messages else None
            shot("6-channels-page-selection")
            frame = dock().get("switch_frame") or {}
            if frame:
                rpc("debug.mouse", {"action": "click", "x": frame["x"] + frame["width"] * 0.25, "y": frame["y"] + frame["height"] / 2})
            state = in_mode("messages", other)
            check("after a selection change in the page, Messages shows the same conversation", bool(state), dock())
            handoff = (state or dock()).get("handoff") or {}
            check("the switch hands over the page's conversation and message",
                  handoff.get("conversation") == other and bool(last) and handoff.get("message") == last, {"handoff": handoff, "last": last})
            shot("7-messages-after-page-selection")
finally:
    quit_app(app)

# Relaunch while Channels was shown: the dock opens Messages again.
app = launch(2)
try:
    run("home.show")
    check("after a relaunch the dock opens Messages", bool(in_mode("messages")), dock())
    shot("8-relaunch-messages")
finally:
    quit_app(app)
    rpc("action.run", {"id": "endAgents"}, timeout=10)
    for acp in (os.path.join(CHIEF, "acpmux"), os.path.join(HOME, ".acpmux")):
        if os.path.isdir(acp):
            subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env=dict(env, ACPMUX_HOME=acp), capture_output=True, timeout=30)
    if STOP:
        subprocess.run([STOP], capture_output=True, timeout=180)
    shutil.rmtree(SCRATCH, ignore_errors=True)

print("%d failed: %s" % (len(failures), failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
