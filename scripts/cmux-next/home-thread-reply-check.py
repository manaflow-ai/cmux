#!/usr/bin/env python3
"""Tagged-app check: a reply sent from a thread in the Swift Home (cx-6ida).

Launches the tagged app with no activation. On the local conversation owner
(the Chief home's cmux-tui session) it makes a conversation with a root
message and two thread replies (`conversation-op` with `thread_root`; MessagesLab
shows "N Replies" under a root from 2 replies). Opens it
in Home, then, through the user's paths only: clicks the thread's "2 Replies"
(`debug.home.drive thread`, the click's path), types and presses Return in the
thread view's field (`type`, `send`). The owner's `conversation-thread` read
must then hold the new reply with `thread_root` = the root, and the reply
count goes from 2 to 3. A real Esc with the key focus outside the pane leaves the view
open; Esc in the pane closes it. Then Reply… on a reply whose root is out of Home's window
must still send to that root. Screenshots before, in the thread, after.
No system input: socket only. Runs on cmux-lawrence-2 (nx-remote --needs gui
--app-from-fleet); ends with the DEBUG quit fixture, endAgents and the tag's
`acpmux daemon shutdown`.

Usage: home-thread-reply-check.py --tag <tag> [--app APP] [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time
import re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app")
parser.add_argument("--out", default="/tmp/home-thread-reply-check")
opts = parser.parse_args()
home = os.environ["HOME"]
app = opts.app or os.environ.get("NX_APP") or \
    f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
failures = []
result = {"tag": opts.tag, "checks": []}


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
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def api(**params):
    return rpc("debug.home.api", params)


def drive(action, **params):
    return rpc("debug.home.drive", {"action": action, **params}) or {}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:600]}"), flush=True)
    result["checks"].append({"name": name, "ok": bool(ok), "detail": detail if not ok else None})
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait on an external process, not app code
    return None


def snapshot(conversation):
    return (api(call="snapshot", conversation=conversation, tail=20) or {}).get("messages") or []


def component(raw):
    out = ""
    for ch in raw:
        if ch.isascii() and (ch.isalnum() or ch in "._"):
            out += ch
        elif not out.endswith("-"):
            out += "-"
    return out.strip("-.")


def owner_socket():
    """The Chief home's cmux-tui session socket (ChiefHome.swift), from its client.log."""
    root_dir = os.path.join(home, ".cmux/chief/isolated", component(opts.tag))
    h = 0x811C9DC5
    for b in root_dir.encode():
        h ^= b; h = (h * 0x01000193) & 0xFFFFFFFF
    name = f"cmux-chief-{h:08x}.sock"
    try:
        lines = [l for l in open(os.path.join(root_dir, "client.log")) if "control socket at " in l]
    except OSError:
        return None
    path = lines[-1].split("control socket at ", 1)[1].strip() if lines else None
    return path if path and path.endswith(name) and os.path.exists(path) else None


def daemon(path, cmd, **fields):
    c = socket.socket(socket.AF_UNIX); c.settimeout(20); c.connect(path)
    f = c.makefile("rwb")
    f.write((json.dumps({"id": 7, "cmd": cmd, **fields}) + "\n").encode()); f.flush()
    for line in f:
        r = json.loads(line)
        if r.get("id") == 7:
            c.close(); return r.get("data") or r
    c.close(); return {"ok": False, "error": "closed"}


def thread_read(conversation, root):
    """The owner's `conversation-thread` read: the reply count and each reply's text and thread_root."""
    r = daemon(owner, "conversation-thread", conversation=conversation, root=root)
    return {"count": (r.get("thread") or {}).get("reply_count"), "raw_ok": "replies" in r,
            "replies": [{"id": m.get("id"), "thread_root": m.get("thread_root"),
                         "text": " ".join(p.get("text", "") for p in m.get("parts") or [])} for m in r.get("replies") or []]}


if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900", **home_classic.ENV}
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
print(f"launched pid {process.pid}", flush=True)
try:
    if not home_classic.require(rpc):  # classic Home: these checks drive the native transcript
        sys.exit(2)
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    me = inbox["me"]; me = me["id"] if isinstance(me, dict) else me
    owner = poll(owner_socket, timeout=90)
    if not check("the local owner's socket", bool(owner)):
        sys.exit(1)
    stamp = str(int(time.time()))
    created = daemon(owner, "conversation-create", idempotency_key=f"thread-reply-{stamp}", actor=me, title=f"Thread reply {stamp}",
                     participants=[{"id": me, "kind": "human", "display_name": "Me"},
                                   {"id": "agent_instinct", "kind": "agent", "display_name": "Maybe: Instinct"}])
    conversation = (created.get("conversation") or {}).get("id")
    if not check("a conversation", bool(conversation), created):
        sys.exit(1)

    def seed(text, root=None):
        key = f"seed-{abs(hash(text))}-{stamp}"
        op = {"kind": "message.send", "client_msg_id": key, "parts": [{"type": "text", "text": text}]}
        if root:
            op["thread_root"] = root
        r = daemon(owner, "conversation-op", conversation=conversation, idempotency_key=key, actor=me, op=op)
        return ((r.get("change") or {}).get("message") or {}).get("id")
    root_text, reply_text = f"Thread root {stamp}", f"Reply from the thread view {stamp}"
    root = seed(root_text)
    if not check("the owner committed the root", bool(root)):
        sys.exit(1)
    check("the owner committed two replies", bool(seed(f"First reply {stamp}", root)) and bool(seed(f"Second reply {stamp}", root)))
    seed(f"After the thread {stamp}")
    before = poll(lambda: (t := thread_read(conversation, root)) and t["count"] == 2 and t)
    check("the owner holds two replies in the thread", bool(before), thread_read(conversation, root))
    result.update(conversation=conversation, root=root, before=before)

    def opened():
        if ((rpc("debug.home") or {}).get("page") or {}).get("shown") != conversation:
            rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation}, "focus": True})
            time.sleep(1)  # test harness: one request per second while Home starts
            return None
        return root_text in (drive("texts").get("texts") or [])
    check("Home shows the root", bool(poll(opened, timeout=180)), drive("texts"))
    time.sleep(1)  # test harness: let the rows settle before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "before.png")})

    opened_thread = drive("thread")
    result["open"] = opened_thread
    check("a click on \"2 Replies\" opens the thread view", bool(opened_thread.get("open_thread")), opened_thread)
    time.sleep(1)  # test harness: the view's fly-in, before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "thread-open.png")})
    drive("type", text=reply_text)
    sent = drive("send")
    check("Return in the thread view's field sends", bool(sent.get("ok")), sent)

    def landed():
        t = thread_read(conversation, root)
        return t if t["count"] == 3 and any(reply_text in (r.get("text") or "") for r in t["replies"]) else None
    after = poll(landed, timeout=20)
    result["after"] = after or thread_read(conversation, root)
    check("the owner's thread holds the reply (reply count 2 -> 3)", bool(after), result["after"])
    mine = next((m for m in snapshot(conversation) if m.get("text") == reply_text), None)
    result["reply"] = mine
    check("the reply went out with thread_root = the root", bool(mine) and mine.get("thread_root") == root, mine)
    time.sleep(1)  # test harness: the reply's arrival animation, before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "thread-after.png")})
    # A real Esc while the key focus is outside the pane (a terminal split, the sidebar, the
    # palette) is theirs: the thread stays open (cx-6ida review P2).
    drive("post_escape", outside=True)
    time.sleep(0.5)  # test harness: the posted key press goes through the app's event queue
    state = drive("thread_state")
    check("Esc with the key focus outside the pane leaves the thread open", bool(state.get("open_thread")), state)
    drive("escape")
    closed = drive("escape")
    check("Esc closes the thread view", closed.get("open_thread") is None, closed)
    time.sleep(1)  # test harness: the view's fly-out, before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "after.png")})
    check("Home still shows the root", root_text in (drive("texts").get("texts") or []))

    # Reply… on a reply whose root is out of Home's loaded window (HomeStore tail 60): the send
    # still names the thread's root, not the reply (cx-6ida review P2).
    created = daemon(owner, "conversation-create", idempotency_key=f"late-reply-{stamp}", actor=me, title=f"Late reply {stamp}",
                     participants=[{"id": me, "kind": "human", "display_name": "Me"},
                                   {"id": "agent_instinct", "kind": "agent", "display_name": "Maybe: Instinct"}])
    conversation = (created.get("conversation") or {}).get("id")
    if not check("a second conversation", bool(conversation), created):
        sys.exit(1)
    old_root = seed(f"Old root {stamp}")
    seed(f"Old reply {stamp}", old_root)
    for i in range(65):
        seed(f"Filler {i} {stamp}")
    root_text = f"Late reply {stamp}"
    check("the owner committed a late reply", bool(seed(root_text, old_root)))
    check("the old thread has two replies", bool(poll(lambda: thread_read(conversation, old_root)["count"] == 2)),
          thread_read(conversation, old_root))
    check("Home shows the late reply", bool(poll(opened, timeout=120)), drive("texts"))
    check("the old root is out of Home's loaded window", f"Old root {stamp}" not in (drive("texts", limit=500).get("texts") or []))
    state = drive("reply", mine=True)
    result["late_open"] = state
    check("Reply… on the late reply opens a thread view", bool(state.get("open_thread")), state)
    # Esc in the view's focused field first only unfocuses it (the transcript takes the focus);
    # a second, real Esc then reaches the pane's monitor and closes the view.
    drive("focus")
    state = drive("escape")
    check("the first Esc in the field keeps the view open", bool(state.get("open_thread")), state)
    drive("post_escape")
    time.sleep(0.5)  # test harness: the posted key press goes through the app's event queue
    state = drive("thread_state")
    check("a second, real Esc closes the view", state.get("open_thread") is None, state)
    state = drive("reply", mine=True)
    check("Reply… opens the view again", bool(state.get("open_thread")), state)
    late_text = f"Reply to the late reply {stamp}"
    drive("type", text=late_text)
    sent = drive("send")
    check("Return in that view sends", bool(sent.get("ok")), sent)
    late_after = poll(lambda: (t := thread_read(conversation, old_root)) and t["count"] == 3 and t, timeout=20)
    result["late_after"] = late_after or thread_read(conversation, old_root)
    check("the old root's thread holds the reply (reply count 2 -> 3)", bool(late_after), result["late_after"])
    late = next((m for m in snapshot(conversation) if m.get("text") == late_text), None)
    result["late_reply"] = late
    check("the reply names the old root, not the late reply", bool(late) and late.get("thread_root") == old_root, late)
    time.sleep(1)  # test harness: the reply's arrival animation, before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "late-reply.png")})
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    rpc("action.run", {"id": "endAgents"}, timeout=5)
    exited = poll(lambda: process.poll() is not None, timeout=30)
    print("app exited" if exited else "app STILL RUNNING", flush=True)
    if not exited:
        process.terminate()
    acp = "%s/.acpmux/builds/com.cmuxterm.app.debug.%s" % (home, re.sub(r"[^a-z0-9]+", ".", opts.tag.lower()).strip("."))
    if os.path.isdir(acp):
        subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown", "--end-agents"], capture_output=True,
                       env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
    result["failures"] = failures
    json.dump(result, open(os.path.join(opts.out, "result.json"), "w"), indent=1, default=str)

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
