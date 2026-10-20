#!/usr/bin/env python3
"""Tagged-app check of Home and Channels as two sidebar entries (hq-6d cx-frn2y; Lawrence 2026-10-15: "toggle between
messages/channels should be via cmd shift p (in fact should just be 2 diff things in section like Home and Channels,
where u have to cmd shift p to enable channels in the first place").

Home is the home workspace with the `home-dock` tab in its left dock. Its Messages view (native) is the sidebar's Home
entry; its Channels view (hq-ec's React page) is a second entry right after Home, shown only while `home.channelsEnabled`
is on (off by default). The dock has no header switch and no Ctrl-Option-Cmd-H any more. Real input (cua-driver: the
window server's pointer and key events to the app's pid) drives the palette and the sidebar; the app's control socket
reads the state. It checks:
- launch 1, nothing set: no Channels entry, no switch in the dock, home.switchView {view: channels} refused;
- the Cloud note: signed out shows nothing (only `unavailable` has the quiet line);
- Cmd-Shift-P, "enable channels", Return: cmux.json has home.channelsEnabled true and the Channels entry shows right
  after Home in Home's section;
- a click on Channels shows the page at the conversation Messages showed (hand-off), and Channels is the active entry;
- a selection change in the page, then a click on Home: Messages shows the page's conversation, Home is active;
- Ctrl-Option-Cmd-H changes nothing;
- with Channels shown, Cmd-Shift-P, "disable channels", Return: the entry goes and Home is selected (Messages);
- the CLI path (`action.run` by CLI name with origin cli, as `cmux home enable-channels` sends it) and the action list
  (CLI and MCP offered) for enable, disable and switch-view;
- this Mac's old Messages-list pins (seeded through debug.home.drive legacy_pins) move into the daemon once, at the
  next launch, in their order; an unpin in the daemon afterwards stays (the move does not run again).
Screenshots of each step. Runs on cmux-lawrence-2 through
`nx-remote --needs input --input-reason "..." --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-channels-entry.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with quitEndSessions,
endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP, NX_ARTIFACTS, NX_CAPTURE.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG = os.environ["NX_APP"], os.environ["NX_APP_TAG"]
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-channels-entry"), os.environ.get("NX_APP_STOP", "")
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser("~/.local/bin/cua-driver"))
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CHANNELS_ITEM = "client.channels"
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h6dc-", dir="/tmp")
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


# Real input through cua-driver (window-server events posted to the app's pid).
def cua(tool, args):
    try:
        r = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60)
        return json.loads(r.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)}


def windows(pid):
    return cua("list_windows", {"pid": pid}).get("windows") or []


def main_window(pid):
    size = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
    shown = windows(pid)
    return max(shown, key=size) if shown else None


def click_item(pid, entry, label):
    """A real left click in the middle of a sidebar item (its window_frame: window points from the top-left)."""
    main, frame = main_window(pid), (entry or {}).get("window_frame") or {}
    if not main or not frame:
        return check("%s: the item and the window are known" % label, False, {"item": entry, "window": main})
    state = cua("get_window_state", {"pid": pid, "window_id": main["window_id"], "include_accessibility_tree": False})
    scale = state.get("screenshot_scale") or 1
    x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
    args = {"pid": pid, "window_id": main["window_id"], "x": round(x * scale), "y": round(y * scale)}
    if state.get("capture_id"):
        args["capture_id"] = state["capture_id"]
    reply = cua("click", args)
    print("%s: cua click at %.0f,%.0f pt (scale %s): %s" % (label, x, y, scale, json.dumps(reply)[:200]), flush=True)
    if "error" in reply or "code" in reply:
        # No pixel context for cua (job 1015-063229-fa032f: screenshot_context_missing): the app's own mouse event path.
        print("%s: click path: in-app mouse event (debug.mouse); cua state keys %s" % (label, sorted(state)[:12]), flush=True)
        rpc("debug.mouse", {"action": "click", "x": x, "y": y})
    else:
        print("%s: click path: real click (cua-driver)" % label, flush=True)
    return True


def palette_window(pid, main_id):
    for w in windows(pid):
        if w.get("window_id") != main_id:
            tree = cua("get_window_state", {"pid": pid, "window_id": w["window_id"], "include_screenshot": False}).get("tree_markdown") or ""
            if "AXTextField" in tree or "AXTextArea" in tree:
                return w, tree
    return None


def palette_run(pid, text, title, shot_name):
    """Cmd-Shift-P, `text` typed key by key, then Return only when the palette lists `title` (else Escape)."""
    main = main_window(pid)
    if not check("the app's window is known to cua-driver", bool(main), windows(pid)):
        return False
    cua("hotkey", {"pid": pid, "window_id": main["window_id"], "keys": ["cmd", "shift", "p"]})
    opened = poll(lambda: "error" not in (rpc("debug.palette.capture", {"path": os.path.join(OUT, shot_name + "-open.png")}) or {"error": 1}), 5)
    if not opened:
        cua("hotkey", {"pid": pid, "window_id": main["window_id"], "keys": ["cmd", "shift", "p"], "delivery_mode": "foreground"})
        opened = poll(lambda: "error" not in (rpc("debug.palette.capture", {"path": os.path.join(OUT, shot_name + "-open.png")}) or {"error": 1}), 5)
    if not check("Cmd-Shift-P opens the command palette", bool(opened)):
        return False
    # The palette's own answer (debug.palette.capture: query and selected row) decides; Return runs only `title`.
    state = lambda: rpc("debug.palette.capture", {"path": os.path.join(OUT, shot_name + ".png")}) or {}
    # Real typing: cua-driver types into the front app's focused field (the palette's), through AX insertion
    # with its CGEvent fallback. A key post to the pid did not reach the palette panel (job 1015-060437-3b4e3b) and a
    # foreground key to the main window closed the palette (job 1015-060719-5afd4d). Only if the query still misses
    # do the app's own key events type it; the proof prints which path typed.
    cua("type_text", {"text": text, "scope": "desktop"})
    if poll(lambda: state().get("query") == text, 5):
        print("typing path: real input (cua-driver type_text into the front app)", flush=True)
    else:
        print("typing path: in-app key events (debug.key target palette); cua query was %r" % state().get("query"), flush=True)
        if "error" in state():  # the attempt closed the palette: open it again with the real chord
            cua("hotkey", {"pid": pid, "window_id": main["window_id"], "keys": ["cmd", "shift", "p"]})
            poll(lambda: "error" not in state(), 5)
        # Clear what the attempt typed with Delete (Cmd-A in the palette opens its Tabs page, job 1015-062807-e251cc).
        for _ in range(len(state().get("query") or "")):
            rpc("debug.key", {"target": "palette", "key": "delete"})
        for ch in text:
            rpc("debug.key", {"target": "palette", "key": "space" if ch == " " else ch})
    found = poll(lambda: state().get("selected") == title, 10)
    if not check("the palette selects %r after typing %r" % (title, text), bool(found), {"palette": state(), "ax": bool(palette_window(pid, main["window_id"]))}):
        cua("press_key", {"pid": pid, "key": "escape"})
        return False
    cua("press_key", {"pid": pid, "key": "return"})
    if poll(lambda: "error" in state(), 3):
        print("return path: real key (cua-driver)", flush=True)
    else:
        print("return path: in-app key event (debug.key target palette)", flush=True)
        rpc("debug.key", {"target": "palette", "key": "return"})
    return True


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


class Line:
    """A JSON-lines connection to the Chief home's daemon (the v1 protocol)."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(15)
        self.sock.connect(path)
        self.buf, self.next = b"", 1

    def request(self, cmd, **params):
        rid = self.next
        self.next += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 16)
                if not chunk:
                    raise RuntimeError("%s: the daemon closed the connection" % cmd)
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            value = json.loads(line)
            if value.get("id") == rid and "event" not in value:
                if value.get("ok") is not True:
                    raise RuntimeError("%s refused: %s" % (cmd, value))
                return value.get("data")


def chief_socket(session):
    darwin = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    for base in [b for b in (darwin, os.environ.get("TMPDIR", ""), "/tmp", "/private/tmp") if b]:
        path = os.path.join(base, "cmux-tui-%d" % os.getuid(), "%s.sock" % session)
        try:
            if Line(path).request("identify").get("session") == session:
                return path
        except (OSError, RuntimeError, ValueError):
            continue
    return None


def owner_line():
    session = poll(lambda: ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session"), 60)
    path = poll(lambda: chief_socket(session), 120) if session else None
    return Line(path) if path else None


def native_row(conversation):
    return next((r for r in dock().get("messages_list") or [] if r.get("id") == conversation), {})


def action_surfaces(action_id):
    listed = (rpc("action.list") or {}).get("actions") or []
    entry = next((a for a in listed if a.get("id") == action_id), {}) or {}
    return entry.get("surfaces") or {}, entry.get("cli_name")


stamp = str(int(time.time()))
pins = []
app = launch(1)
try:
    pid = app.pid
    shown = poll(lambda: (lambda r: None if refused(r) else r)(run("home.show")), 120)
    check("home.show is not refused", bool(shown), run("home.show"))
    check("the dock opens the native Messages view", bool(in_mode("messages")), dock())
    check("Channels is off by default (no Channels entry)", poll(home_item, 30) is not None and channels_item() is None, items())
    check("the Home entry is the active entry", bool(poll(lambda: (home_item() or {}).get("active"), 15)), home_item())
    check("the dock draws no Messages | Channels switch", not any(k in dock() for k in ("switch_frame", "switch_labels", "switch_selected")), dock())
    reply = run("home.switchView", {"view": "channels"})
    check("home.switchView {view: channels} is refused while Channels is off", refused(reply), reply)
    check("the dock stays on Messages", dock().get("mode") == "messages", dock())

    # The Cloud note: signed out shows nothing; only `unavailable` has its quiet line.
    cloud = poll(lambda: dock().get("messages_cloud"), 30)
    if cloud == "unavailable":
        check("Cloud unavailable shows its quiet note", dock().get("messages_note") == "Cloud conversations are not available right now.", dock())
    else:
        time.sleep(1)  # test harness wait: let a late note draw before the negative check
        check("Cloud %s shows no note" % cloud, not dock().get("messages_note"), {"cloud": cloud, "note": dock().get("messages_note")})

    # This Mac's old Messages-list pins, for the move at the next launch.
    owner = owner_line()
    if check("the Chief home's daemon socket answers", owner is not None):
        me = (owner.request("home-inbox") or {}).get("me") or "user_local"
        person = {"id": me, "kind": "human", "display_name": "Tester"}
        for n in range(3):
            conv = owner.request("conversation-create", idempotency_key="pin%d-%s" % (n, stamp), title="pin%d-%s" % (n, stamp),
                                 participants=[person])["conversation"]["id"]
            owner.request("conversation-op", conversation=conv, idempotency_key="pin%d-m-%s" % (n, stamp),
                          op={"kind": "message.send", "client_msg_id": "pin%d-m-%s" % (n, stamp), "parts": [{"type": "text", "text": "pin %d" % n}]})
            pins.append(conv)
        poll(lambda: all(native_row(c) for c in pins), 30)

    # Enable Channels from the palette with real keys.
    run("home.openConversation", {"conversation": pins[1]}) if pins else None
    conversation = pins[1] if pins else None
    check("Messages shows a conversation", bool(in_mode("messages", conversation)), dock())
    shot("1-home-only")
    if palette_run(pid, "enable channels", "Enable Channels", "2-palette-enable"):
        check("cmux.json has home.channelsEnabled true", bool(poll(lambda: config_value() is True, 15)), config_value())
        entry = poll(channels_item, 15)
        check("the Channels entry shows", bool(entry), items())
        home = home_item() or {}
        listed = items()
        index = {i.get("id"): n for n, i in enumerate(listed)}
        check("Channels is right after Home in Home's section",
              bool(entry) and entry.get("section") == home.get("section") and index.get(CHANNELS_ITEM) == index.get(home.get("id"), -9) + 1, listed)
        check("Home stays the active entry", bool((home_item() or {}).get("active")) and not (channels_item() or {}).get("active"), listed)
        shot("3-channels-entry")

        # A real click on Channels: the page at the same conversation, Channels active.
        click_item(pid, channels_item(), "Channels")
        check("a click on Channels shows the Channels page at Messages' conversation", bool(in_mode("channels", conversation)), dock())
        check("Channels is the active entry", bool(poll(lambda: (channels_item() or {}).get("active"), 10)), items())
        check("Home is not active while Channels shows", not (home_item() or {}).get("active"), items())
        shot("4-channels-by-click")

        # Another conversation in the page, then a real click on Home: Messages shows it.
        other = pins[0] if pins else None
        if other:
            row = '[data-list-row="%s"]' % other
            clicked = poll(lambda: (rpc("debug.page", {"page": "cmux.home-channels", "action": "click", "selector": row}) or {}).get("clicked"), 30)
            check("the page opens another conversation", bool(clicked) and bool(in_mode("channels", other)), page_fragment())
        click_item(pid, home_item(), "Home")
        check("a click on Home shows Messages at the page's conversation", bool(in_mode("messages", other)), dock())
        check("Home is the active entry again", bool(poll(lambda: (home_item() or {}).get("active"), 10)), items())
        shot("5-home-by-click")

        # The old toggle shortcut does nothing.
        main = main_window(pid)
        if main:
            cua("hotkey", {"pid": pid, "window_id": main["window_id"], "keys": ["ctrl", "option", "cmd", "h"]})
        time.sleep(1.5)  # test harness wait: a removed shortcut has no event to wait for
        check("Ctrl-Option-Cmd-H changes nothing", dock().get("mode") == "messages", dock())

        # Disable Channels while Channels shows: the entry goes and Home is selected.
        click_item(pid, channels_item(), "Channels again")
        check("Channels shows again", bool(in_mode("channels")), dock())
        if palette_run(pid, "disable channels", "Disable Channels", "6-palette-disable"):
            check("cmux.json has home.channelsEnabled false", bool(poll(lambda: config_value() is False, 15)), config_value())
            check("the Channels entry is gone", bool(poll(lambda: channels_item() is None, 15)), items())
            check("disabling Channels while it shows selects Home (Messages)", bool(in_mode("messages")), dock())
            check("Home is the active entry after Disable", bool(poll(lambda: (home_item() or {}).get("active"), 10)), items())
            shot("7-disabled-home")

    # CLI and MCP: the same actions by CLI name (what `cmux home enable-channels` sends) and in the action list.
    for action_id, name in (("home.enableChannels", "home enable-channels"), ("home.disableChannels", "home disable-channels"),
                            ("home.switchView", "home switch-view")):
        surfaces, cli_name = action_surfaces(action_id)
        check("%s is offered to the CLI as %r and to MCP" % (action_id, name),
              surfaces.get("cli") == "offered" and surfaces.get("mcp") == "offered" and cli_name == name, {"surfaces": surfaces, "cli_name": cli_name})
    reply = rpc("action.run", {"action": "home enable-channels", "cli": True, "origin": "cli", "wait": True}) or {}
    check("the CLI's home enable-channels runs", not refused(reply), reply)
    check("the CLI's enable shows the Channels entry", bool(poll(channels_item, 15)) and config_value() is True, {"items": items(), "config": config_value()})
    reply = rpc("action.run", {"action": "home switch-view", "cli": True, "origin": "cli", "wait": True, "focus": True,
                               "args": {"view": "channels"}}) or {}
    check("the CLI's home switch-view channels selects Channels", not refused(reply) and bool(in_mode("channels")), {"reply": reply, "dock": dock()})
    reply = rpc("action.run", {"action": "home disable-channels", "cli": True, "origin": "cli", "wait": True}) or {}
    check("the CLI's home disable-channels runs", not refused(reply), reply)
    check("the CLI's disable hides the entry and selects Home", bool(poll(lambda: channels_item() is None, 15)) and bool(in_mode("messages")),
          {"items": items(), "dock": dock()})

    # Last in launch 1, right before the quit (no owner change in between): this Mac's old Messages-list pins, which the
    # next launch moves into the daemon.
    if pins:
        seeded = drive("legacy_pins", pins=[pins[2], pins[0]])
        check("the old per-Mac pins are seeded (pin2, pin0)", seeded.get("ok") is True and seeded.get("pins") == [pins[2], pins[0]], seeded)
finally:
    quit_app(app)

# Launch 2: the old pins are in the daemon, once.
app = launch(2)
try:
    run("home.show")
    check("after a relaunch Channels stays off", poll(home_item, 30) is not None and channels_item() is None, items())
    owner = owner_line() if pins else None
    if owner and pins:
        inbox = lambda: owner.request("home-inbox").get("rows") or []
        def migrated():
            rows = {r["id"]: r for r in inbox()}
            two, zero, one = rows.get(pins[2], {}), rows.get(pins[0], {}), rows.get(pins[1], {})
            return two.get("pinned") and zero.get("pinned") and not one.get("pinned") and (two.get("pinPosition") or two.get("pin_position") or 0) < (zero.get("pinPosition") or zero.get("pin_position") or 0)
        check("the old pins are in the daemon in their order (pin2 before pin0; pin1 unpinned)", bool(poll(migrated, 60)),
              [r for r in inbox() if r["id"] in pins])
        check("Messages shows the moved pins", bool(poll(lambda: native_row(pins[2]).get("pinned") and native_row(pins[0]).get("pinned"), 30)),
              [native_row(c) for c in pins])
        left = drive("legacy_pins")
        check("this Mac keeps none of the moved pins", left.get("ok") is True and not (set(left.get("pins") or []) & set(pins)), left)
        shot("8-pins-moved")
        owner.request("conversation-inbox-op", conversation=pins[0], op={"kind": "inbox.pin", "pinned": False})
        check("an unpin in the daemon shows in Messages", bool(poll(lambda: native_row(pins[0]) and not native_row(pins[0]).get("pinned"), 15)), native_row(pins[0]))
        owner.request("conversation-op", conversation=pins[1], idempotency_key="pin1-n-%s" % stamp,
                      op={"kind": "message.send", "client_msg_id": "pin1-n-%s" % stamp, "parts": [{"type": "text", "text": "another reply"}]})
        time.sleep(3)  # test harness wait: the rows are read again after this change; a second move would pin pin0 again
        check("the move does not run again (pin0 stays unpinned)", not any(r["id"] == pins[0] and r.get("pinned") for r in inbox()),
              [r for r in inbox() if r["id"] in pins])
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
