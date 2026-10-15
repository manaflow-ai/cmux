#!/usr/bin/env python3
"""Tagged-app check: the native Messages list reads the daemon's Home rows (`home-inbox`, home-inbox-v1), so the
Messages and Channels views show one list (cx-ebm.59.5 parity; hq-ec PARITY.md gaps 1, 2, 9, 13).

Home is the home workspace with the `home-dock` tab (Messages by default, Channels as the sidebar's second entry,
enabled in this check's cmux.json). On the Chief
home's own daemon (its Unix socket, as the user) the check makes a second Chief (an agent of class mux with its own
name), a pinned channel and a plain channel, then checks through the app's control socket:
- the Messages list shows the daemon's rows in the daemon's order, with each Chief's own name and the daemon's pins;
- the Channels page lists the same conversations in the same order;
- a pin in Messages shows in Channels, an unpin in Channels shows in Messages, Mark as Unread in Messages shows in
  Channels, Mark as Read in Channels shows in Messages (each view through its own menu handler);
- a Chief's typing shows in the Messages transcript and ends when its reply posts (the owner sends no typing-off);
- the build's daemon (owners ["cloud"]) says the Cloud state; signed out or unavailable, the list keeps the local rows;
  unavailable shows one quiet line, signed out none (muted Cloud rows need a signed-in Cloud account, which this host
  has not).
Screenshots of each step. Runs on cmux-lawrence-2 through
`nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-inbox-parity.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with quitEndSessions,
endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP, NX_ARTIFACTS.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG = os.environ["NX_APP"], os.environ["NX_APP_TAG"]
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-inbox-parity"), os.environ.get("NX_APP_STOP", "")
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h6di-", dir="/tmp")
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
# Channels is off by default (cx-frn2y); this check uses both views.
open(os.path.join(SCRATCH, "cmux.json"), "w").write('{"home": {"channelsEnabled": true}}')
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
    """`<base>/cmux-tui-<uid>/<session>.sock` for the bases an owner can start with."""
    darwin = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    for base in [b for b in (darwin, os.environ.get("TMPDIR", ""), "/tmp", "/private/tmp") if b]:
        path = os.path.join(base, "cmux-tui-%d" % os.getuid(), "%s.sock" % session)
        try:
            if Line(path).request("identify").get("session") == session:
                return path
        except (OSError, RuntimeError, ValueError):
            continue
    return None


def native_list():
    return dock().get("messages_list") or []


def page_rows():
    reply = rpc("debug.page", {"page": "cmux.home-channels", "action": "query", "selector": "[data-list-row]"}) or {}
    return [{"id": e["data"].get("listRow"), "pinned": "pinned" in e["data"], "unread": "unread" in e.get("classes", []),
             "name": e["data"].get("name")} for e in reply.get("elements") or [] if isinstance(e, dict) and e.get("data")]


def page_menu(conversation, index):
    """Right-click the page's row, then its menu item at `index` (Pin or Unpin first, Read or Unread second)."""
    opened = rpc("debug.page", {"page": "cmux.home-channels", "action": "click", "context_menu": True,
                                "selector": '[data-list-row="%s"]' % conversation}) or {}
    item = '[role="menu"] > [role="none"]:nth-child(%d) > [role="menuitem"]' % index
    clicked = poll(lambda: (rpc("debug.page", {"page": "cmux.home-channels", "action": "click", "selector": item}) or {}).get("clicked"), 10)
    return bool(opened.get("clicked")) and bool(clicked)


def native_row(conversation):
    return next((r for r in native_list() if r.get("id") == conversation), {})


def page_row(conversation):
    return next((r for r in page_rows() if r.get("id") == conversation), {})


app = launch(1)
try:
    shown = poll(lambda: (lambda r: None if refused(r) else r)(run("home.show")), 120)
    check("home.show is not refused", bool(shown), run("home.show"))
    check("the dock opens the native Messages view", bool(in_mode("messages")), dock())
    session = poll(lambda: ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session"), 60)
    path = poll(lambda: chief_socket(session), 120) if session else None
    if not check("the Chief home's daemon socket answers", bool(path), session):
        raise SystemExit(1)
    owner = Line(path)
    caps = (owner.request("identify") or {}).get("capabilities") or []
    check("the Chief home's daemon serves home-inbox-v1", "home-inbox-v1" in caps, caps)
    inbox = lambda: owner.request("home-inbox") or {}
    me = inbox().get("me") or "user_local"
    stamp = str(int(time.time()))
    person = {"id": me, "kind": "human", "display_name": "Tester"}

    # A second Chief with its own name, a pinned channel and a plain channel, on the owner as the user.
    scout_id, scout_name = "agent_scout%s" % stamp, "Scout %s" % stamp
    scout = owner.request("conversation-create", idempotency_key="scout-%s" % stamp, title=scout_name, participants=[
        person, {"id": scout_id, "kind": "agent", "display_name": scout_name, "agent_class": "mux"}])["conversation"]["id"]
    pinned = owner.request("conversation-create", idempotency_key="pinned-%s" % stamp, title="pinned-%s" % stamp,
                           participants=[person])["conversation"]["id"]
    plain = owner.request("conversation-create", idempotency_key="plain-%s" % stamp, title="plain-%s" % stamp,
                          participants=[person])["conversation"]["id"]
    owner.request("conversation-op", conversation=plain, idempotency_key="plain-1-%s" % stamp,
                  op={"kind": "message.send", "client_msg_id": "plain-1-%s" % stamp, "parts": [{"type": "text", "text": "plain %s" % stamp}]})
    owner.request("conversation-inbox-op", conversation=pinned, op={"kind": "inbox.pin", "pinned": True, "position": int(time.time() * 1000)})
    made = {scout, pinned, plain}

    def same_order():
        rows = inbox().get("rows") or []
        want = [r["id"] for r in rows]
        have = [r.get("id") for r in native_list()]
        return (want, rows) if made <= set(have) and want == have else None
    found = poll(same_order, 60)
    rows = (found or (None, inbox().get("rows") or []))[1]
    check("the Messages list shows the daemon's rows in the daemon's order", bool(found),
          {"daemon": [r["id"] for r in rows], "messages": [r.get("id") for r in native_list()]})
    for row in rows:
        mine = native_row(row["id"])
        if row["kind"] == "chief":
            check("the Messages list names the Chief %s as the daemon does (%s)" % (row["id"], row["name"]),
                  mine.get("title") == row["name"], mine)
        check("the Messages list pins %s as the daemon does" % row["id"], mine.get("pinned") == row["pinned"], {"daemon": row, "messages": mine})
    check("two Chiefs with different names", len({r["name"] for r in rows if r["kind"] == "chief"}) >= 2, rows)
    check("the second Chief is named %s in Messages" % scout_name, native_row(scout).get("title") == scout_name, native_row(scout))
    check("the pinned channel is first in Messages", (native_list() or [{}])[0].get("id") == pinned, native_list())
    shot("1-messages-list")

    # Cloud rows come from the build's own daemon (its Cloud lease), asked by the app with owners ["cloud"]. Signed
    # out here: the local rows stay and the list says so in one quiet line. The state is the app's own answer.
    app_path = chief_socket("cmux-app-%s" % TAG)
    if check("the build's daemon socket answers", bool(app_path), TAG):
        try:
            Line(app_path).request("home-inbox", owners=["cloud"])
            check("the build's daemon serves home-inbox with owners", True)
        except (OSError, RuntimeError, ValueError) as error:
            check("the build's daemon serves home-inbox with owners", False, str(error))
        cloud = poll(lambda: dock().get("messages_cloud"), 30)
        check("the app has the Cloud state from the build's daemon", cloud in ("included", "signed_out", "unavailable"), dock().get("messages_cloud"))
        note = poll(lambda: dock().get("messages_note"), 15) if cloud == "unavailable" else None
        if cloud == "unavailable":
            check("Messages shows the quiet unavailable note", note == "Cloud conversations are not available right now.", dock().get("messages_note"))
        else:
            check("Messages shows no Cloud note while %s" % cloud, not dock().get("messages_note"), dock().get("messages_note"))
        check("the local rows stay with the Cloud state %s" % cloud, made <= {r.get("id") for r in native_list()}, native_list())

    # The same list in Channels.
    run("home.switchView", {"view": "channels"})
    check("Channels shows", bool(in_mode("channels")), dock())
    want = [r.get("id") for r in native_list()]
    same = poll(lambda: [r["id"] for r in page_rows()] == want, 30)
    check("Channels lists the same conversations in the same order", bool(same), {"messages": want, "channels": [r["id"] for r in page_rows()]})
    check("Channels names the second Chief %s" % scout_name, scout_name in (page_row(scout).get("name") or ""), page_row(scout))
    shot("2-channels-list")

    # A pin in Messages shows in Channels.
    run("home.switchView", {"view": "messages"})
    in_mode("messages")
    reply = drive("list", op="pin", conversation=plain)
    check("Pin in the Messages list", reply.get("ok") is True, reply)
    check("the Messages list shows the pin", bool(poll(lambda: native_row(plain).get("pinned"), 15)), native_row(plain))
    check("the daemon has the pin", bool(poll(lambda: any(r["id"] == plain and r["pinned"] for r in inbox().get("rows") or []), 15)), inbox())
    run("home.switchView", {"view": "channels"})
    in_mode("channels")
    check("Channels shows the pin made in Messages", bool(poll(lambda: page_row(plain).get("pinned"), 15)), page_row(plain))
    shot("3-channels-after-messages-pin")

    # An unpin in Channels shows in Messages.
    check("Unpin in the Channels row menu", page_menu(plain, 1), page_row(plain))
    check("Channels shows the unpin", bool(poll(lambda: page_row(plain) and not page_row(plain).get("pinned"), 15)), page_row(plain))
    run("home.switchView", {"view": "messages"})
    in_mode("messages")
    check("Messages shows the unpin made in Channels", bool(poll(lambda: native_row(plain) and not native_row(plain).get("pinned"), 15)), native_row(plain))

    # Mark as Unread in Messages shows in Channels; Mark as Read in Channels shows in Messages.
    reply = drive("list", op="unread", conversation=plain)
    check("Mark as Unread in the Messages list", reply.get("ok") is True, reply)
    check("the Messages list shows plain unread", bool(poll(lambda: native_row(plain).get("unread"), 15)), native_row(plain))
    run("home.switchView", {"view": "channels"})
    in_mode("channels")
    check("Channels shows the mark made in Messages", bool(poll(lambda: page_row(plain).get("unread"), 15)), page_row(plain))
    check("Mark as Read in the Channels row menu", page_menu(plain, 2), page_row(plain))
    check("Channels shows plain read", bool(poll(lambda: page_row(plain) and not page_row(plain).get("unread"), 15)), page_row(plain))
    run("home.switchView", {"view": "messages"})
    in_mode("messages")
    check("Messages shows the read made in Channels", bool(poll(lambda: native_row(plain) and not native_row(plain).get("unread"), 15)), native_row(plain))
    shot("4-messages-after-channels-read")

    # The second Chief types, then posts its reply with no typing-off: the typing bubble ends on the reply.
    run("home.openConversation", {"conversation": scout})
    check("Messages shows the second Chief", bool(in_mode("messages", scout)), dock())
    token = owner.request("conversation-agent-token", participant=scout_id)["token"]
    agent = Line(path)
    agent.request("conversation-bind", participant=scout_id, token=token)
    agent.request("conversation-typing", conversation=scout, on=True)
    check("the second Chief's typing shows", bool(poll(lambda: drive("typing").get("ok"), 15)), drive("typing"))
    shot("5-typing")
    reply_text = "scout reply %s" % stamp
    agent.request("conversation-op", conversation=scout, idempotency_key="scout-1-%s" % stamp,
                  op={"kind": "message.send", "client_msg_id": "scout-1-%s" % stamp, "parts": [{"type": "text", "text": reply_text}]})
    check("the reply shows", bool(poll(lambda: reply_text in (dock().get("transcript_tail") or []), 15)), dock())
    check("typing ends on the reply", bool(poll(lambda: drive("typing").get("ok") is False, 10)), drive("typing"))
    shot("6-reply-no-typing")
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
