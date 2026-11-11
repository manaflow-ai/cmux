#!/usr/bin/env python3
"""Behavior check: every committed message shows in the Swift Home (cx-7nf0).

Launches the tagged app with no activation and drives the real Home data path
(`debug.home.api`) against the local Chief owner. For each case it compares
three views of one conversation: the owner's snapshot (what the daemon
committed), the Swift Home's HomeStore transcript (`store`), and the texts the
transcript view itself holds (`debug.home.drive` `texts`, its MessagesLab
store). A message the owner and HomeStore have but the view does not is
hidden: the check fails.

Cases:
- few: a conversation with 2 messages, opened in Home for the first time (its
  transcript page loads after the view is made), then a live message.
- thread: the thread proof's order (before, root, 2 replies), opened, a plain
  message right away, then a live thread reply (its root's text preview shows
  above it). Then the transcript moves by half a device pixel: the text rows
  under the preview rest on whole device pixels with no partial pixels on their
  straight edges where the app draws them (MessagesLab c1457e5 row-snap, 2281879
  balloon; home_pixels.check_rows).

Reads and writes only through the debug socket; no system input. Runs on
cmux-lawrence-2 (GUI host), never on the laptop. Ends with quitEndSessions and
the tag's `acpmux daemon shutdown`.

Usage: home-hidden-messages.py --tag <tag> [--out DIR] [--no-launch]
Exit 0 when every check passes, 1 otherwise.
"""
import argparse, json, os, socket, subprocess, sys, time
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from home_pixels import SKIPPED, check_rows  # noqa: E402
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-hidden-messages")
parser.add_argument("--no-launch", action="store_true", help="use an app already running for the tag")
opts = parser.parse_args()
home = os.environ["HOME"]
app = f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:  # the socket is not up yet, or the app quit
        return {"ok": False, "error": f"socket: {error}"}


def api(**params):
    return rpc("debug.home.api", params)


def submit(**op):
    return api(call="submit", op=op)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:600]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait for an owner commit or a view update, not app code
    return None


def owner_texts(conversation):
    return [m.get("text") for m in (api(call="snapshot", conversation=conversation, tail=50) or {}).get("messages") or []]


def store_texts(conversation):
    return [i.get("text") for i in (api(call="store", conversation=conversation) or {}).get("items") or []]


def view_texts():
    return (rpc("debug.home.drive", {"action": "texts", "limit": 50}) or {}).get("texts")


def shown():
    return ((rpc("debug.home") or {}).get("page") or {}).get("shown")


def send(conversation, text, thread_root=None):
    op = {"kind": "send", "conversation": conversation, "text": text}
    if thread_root:
        op["thread_root"] = thread_root
    return submit(**op)


def message_id(conversation, text):
    return next((m.get("id") for m in (api(call="snapshot", conversation=conversation, tail=50) or {}).get("messages") or []
                 if m.get("text") == text), None)


def new_group(title):
    created = submit(kind="create_group", title=title, participants=[])
    return created.get("conversation") if created.get("ok") else None


last_open = {}


def open_in_home(conversation):
    # The first run after launch can come before the window's Home page takes it: ask again until it shows.
    def opened():
        if shown() != conversation:
            # Home first (a window still starting can take the conversation and stay on its new tab), then the conversation.
            rpc("action.run", {"id": "home.show", "focus": True})
            last_open["reply"] = rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation},
                                                    "focus": True})
            time.sleep(1)  # test harness: one request per second while Home starts, not app code
            return None
        return view_texts() is not None
    ok = poll(opened, timeout=180)
    if not ok:
        print(f"     last home.openConversation reply: {json.dumps(last_open.get('reply'))[:300]}", flush=True)
    return ok


def compare(name, conversation, expected, shot):
    """Every expected text is in the owner's log and HomeStore; the view must show them all, in order."""
    owner = poll(lambda: (t := owner_texts(conversation)) and all(e in t for e in expected) and t, timeout=20) or owner_texts(conversation)
    check(f"{name}: the owner committed every message", all(e in owner for e in expected), owner)
    store = poll(lambda: (t := store_texts(conversation)) and all(e in t for e in expected) and t, timeout=20) or store_texts(conversation)
    check(f"{name}: HomeStore has every message", all(e in store for e in expected), store)
    check(f"{name}: Home still shows this conversation", shown() == conversation, shown())
    view = poll(lambda: (t := view_texts()) and [x for x in t if x in expected] == expected and t, timeout=10) or view_texts()
    hidden = [e for e in expected if e not in (view or [])]
    check(f"{name}: the Home view shows every message in order", bool(view) and [x for x in view if x in expected] == expected,
          {"hidden": hidden, "view": view, "store": store})
    time.sleep(1.0)  # test harness: let the newest row's arrival settle before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, shot)})


# A root longer than one line: the live reply's root preview wraps it (MessagesLab a4a0edb).
ROOT = "Q4 plan: who takes the migration, the backfill and the cleanup of the old tables after next week's cutover?"

pid = None
if not opts.no_launch:
    if os.path.exists(sock):
        os.unlink(sock)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
           "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", **home_classic.ENV}
    process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
    pid = process.pid
    print(f"launched pid {pid}", flush=True)

try:
    # Classic Home or stop at once (cx-h0kds): these checks drive the native classic Home transcript.
    if not home_classic.require(rpc):
        sys.exit(2)
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    stamp = str(int(time.time()))

    # few: 2 messages, then the first open (the view is made before its first page loads).
    few = new_group(f"few-{stamp}")
    if check("few: a local channel", bool(few)):
        for text in ("First of two.", "Second of two."):
            send(few, text)
        poll(lambda: len(owner_texts(few)) >= 2)
        poll(lambda: ((e := next((c for c in (api(call="inbox") or {}).get("conversations") or [] if c.get("id") == few), None))
                      and e.get("last_seq", 0) >= 2))
        check("few: Home shows the channel", bool(open_in_home(few)), rpc("debug.home"))
        compare("few, opened", few, ["First of two.", "Second of two."], "few-opened.png")
        send(few, "Live after the open.")
        compare("few, live", few, ["First of two.", "Second of two.", "Live after the open."], "few-live.png")

    # thread: the thread proof's order.
    thread = new_group(f"thread-{stamp}")
    if check("thread: a local channel", bool(thread)):
        send(thread, "Before the thread")
        send(thread, ROOT)
        root = poll(lambda: message_id(thread, ROOT))
        send(thread, "I can take the schema part.", root)
        send(thread, "I will do the backfill after it.", root)
        poll(lambda: len(owner_texts(thread)) >= 4)
        check("thread: Home shows the channel", bool(open_in_home(thread)), rpc("debug.home"))
        send(thread, "After the thread")
        compare("thread, after", thread, ["Before the thread", ROOT, "I can take the schema part.",
                                          "I will do the backfill after it.", "After the thread"], "thread-after.png")
        send(thread, "Third reply, arriving live.", root)
        compare("thread, live reply", thread, ["Before the thread", ROOT, "I can take the schema part.",
                                               "I will do the backfill after it.", "After the thread", "Third reply, arriving live."],
                "thread-live.png")
        # The live reply's root preview (ROOT wraps to several lines: a 100.5 pt row on the pixel grid since
        # MessagesLab c1457e5, measured at d5f924a; 100.65 pt of parts before) sits above the reply. With the transcript on half a device pixel
        # (both axes), the text rows under the preview rest on whole device pixels with crisp straight edges.
        rows = (rpc("debug.home.drive", {"action": "rows"}) or {}).get("rows") or []
        kinds = [r["kind"] for r in rows]
        has_preview = "preview" in kinds and "text" in kinds[kinds.index("preview") + 1:]
        check("thread, live reply: a thread preview shows above a text row", has_preview, kinds)
        rpc("debug.home.drive", {"action": "nudge", "dx": 0.25, "dy": 0.25})
        # The pane's right edge on half a device pixel too (82ccac1: my rows, here the live reply, snap their right edge).
        rpc("debug.home.drive", {"action": "resize", "trims": [0.5]})
        time.sleep(0.2)  # test harness: one display frame for the move to show
        half = rpc("debug.home.drive", {"action": "rows"}) or {}
        half_shot = os.path.join(opts.out, "thread-half-pixel.png")
        rpc("debug.window_snapshot", {"path": half_shot})
        check("thread, half pixel: the transcript sits on half a device pixel (both axes)", bool(half.get("ok"))
              and all(abs(((half.get(k, 0) * 2) % 1) - 0.5) < 0.01 for k in ("hostX", "hostY")),
              {k: half.get(k) for k in ("hostX", "hostY", "error")})
        check("thread, half pixel: the transcript's right edge sits on half a device pixel",
              abs(((half.get("hostRight", 0) * 2) % 1) - 0.5) < 0.01, {k: half.get(k) for k in ("hostRight", "trim")})
        if has_preview and half.get("ok") and os.path.exists(half_shot):
            hk = [r["kind"] for r in half["rows"]]
            below = {r["key"] for r in half["rows"][hk.index("preview") + 1:]} if "preview" in hk else set()
            preview = next((r for r in half["rows"] if r["kind"] == "preview"), None)
            if preview:
                print(f"     thread preview row: {preview['height']} pt", flush=True)
            check_rows(check, "thread, half pixel, under the preview", half, half_shot, keys=below, min_rows=1)
finally:
    if pid:
        reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
        if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
            rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
        acp = "%s/.acpmux/builds/com.cmuxterm.app.debug.%s" % (home, re.sub(r"[^a-z0-9]+", ".", opts.tag.lower()).strip("."))
        subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown", "--end-agents"], capture_output=True,
                       env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
if SKIPPED:
    print(f"{len(SKIPPED)} proof(s) skipped (not passed): {SKIPPED}", flush=True)
sys.exit(1 if failures else 0)
