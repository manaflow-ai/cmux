#!/usr/bin/env python3
"""Behavior check of the Home data path (HomeService.homeRouter) on a tagged build.

Launches the tagged app with no activation, then drives `debug.home.api` over the
debug socket against the real local Chief owner: a local channel, a send, a thread
reply, reaction add and remove, edit, retract, and an unread count that skips my
own messages. Both Homes on one data path: the Swift Home shows the channel
(its HomeStore) while a second `homeRouter.events()` subscriber (`watch_start`,
as the React Home's provider subscribes) watches; a write through either one
must show in the other. Reads and writes only through the socket; no system input.
Runs on cmux-lawrence-2 (GUI host), never on the laptop. Quits the app with
quitEndSessions and shuts down the tag's acpmux.

Usage: home-api-live.py --tag <tag> [--out DIR] [--no-launch]
Exit 0 when every check passes, 1 otherwise.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-api-live")
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
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:400]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.5)  # test harness wait for an owner commit, not app code
    return None


def messages(conversation):
    return (api(call="snapshot", conversation=conversation, tail=50) or {}).get("messages") or []


def find(conversation, message_id):
    return next((m for m in messages(conversation) if m.get("id") == message_id), None)


def newest(conversation, text):
    return next((m for m in reversed(messages(conversation)) if m.get("text") == text), None)


def entry(conversation):
    inbox = api(call="inbox") or {}
    return next((c for c in inbox.get("conversations") or [] if c.get("id") == conversation), None)


pid = None
if not opts.no_launch:
    if os.path.exists(sock):
        os.unlink(sock)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
           "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local"}
    process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
    pid = process.pid
    print(f"launched pid {pid}", flush=True)

try:
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    me = inbox["me"]
    stamp = str(int(time.time()))
    watch = api(call="watch_start")
    check("a second events() subscriber starts", bool(watch.get("ok")), watch)


    def watched(text):
        return next((e for e in (api(call="watch_read") or {}).get("events") or [] if e.get("text") == text), None)


    def stored(predicate):
        return next((i for i in (api(call="store", conversation=channel) or {}).get("items") or [] if predicate(i)), None)

    created = submit(kind="create_group", title=f"api-check-{stamp}", participants=[])
    channel = created.get("conversation") if created.get("ok") else None
    check("createGroup with no cloud participant makes a local channel", bool(channel), created)
    if channel:
        listed = poll(lambda: entry(channel))
        check("the channel is in the inbox with the local owner", bool(listed) and listed.get("owner") == "local", listed)
    else:
        # Keep checking the other ops in an existing local conversation.
        local = [c for c in inbox["conversations"] if c.get("owner") == "local"]
        channel = local[0]["id"] if local else None
    if not channel:
        check("a local conversation exists for the other checks", False, inbox)
        sys.exit(1)

    opened = rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": channel}, "focus": True})
    shown = poll(lambda: (g := rpc("debug.home.drive", {"action": "geometry"})) and g.get("ok") and g, timeout=60)
    check("the Swift Home shows the channel", bool(shown), opened)

    root_text = f"root {stamp}"
    sent = submit(kind="send", conversation=channel, text=root_text)
    root = poll(lambda: newest(channel, root_text)) if sent.get("ok") else None
    check("sendMessage commits", bool(root), sent)
    check("the second subscriber gets the send", bool(poll(lambda: watched(root_text))), api(call="watch_read"))
    check("the Swift Home store shows the send", bool(poll(lambda: stored(lambda i: i.get("text") == root_text))),
          api(call="store", conversation=channel))
    unread = poll(lambda: (e := entry(channel)) and e.get("unread") == 0 and e) or entry(channel)
    check("unreadCount skips my own message", bool(unread) and unread.get("unread") == 0, unread)
    if root:
        reply_text = f"in thread {stamp}"
        threaded = submit(kind="send", conversation=channel, text=reply_text, thread_root=root["id"])
        reply = poll(lambda: newest(channel, reply_text)) if threaded.get("ok") else None
        check("sendMessage with threadRoot lands in the root's thread",
              bool(reply) and reply.get("thread_root") == root["id"], reply or threaded)

        added = submit(kind="react", conversation=channel, message=root["id"], emoji="👍")
        mine = lambda m: any(r.get("author") == me and r.get("kind") == "👍" for r in (m or {}).get("reactions", []))
        check("reaction.add shows my reaction", bool(added.get("ok")) and bool(poll(lambda: mine(find(channel, root["id"])))), added)
        check("the Swift Home store shows the reaction",
              bool(poll(lambda: stored(lambda i: i.get("id") == root["id"] and i.get("reactions", 0) > 0))),
              api(call="store", conversation=channel))
        removed = submit(kind="unreact", conversation=channel, message=root["id"], emoji="👍")
        check("reaction.remove takes my reaction back",
              bool(removed.get("ok")) and bool(poll(lambda: (m := find(channel, root["id"])) and not mine(m))), removed)

        edited = submit(kind="edit", conversation=channel, message=root["id"], text=root_text + " edited")
        after = poll(lambda: (m := find(channel, root["id"])) and m.get("edited") and m)
        check("message.edit changes the text and marks it edited",
              bool(edited.get("ok")) and bool(after) and after.get("text") == root_text + " edited", after or edited)
        check("the Swift Home store shows the edit",
              bool(poll(lambda: stored(lambda i: i.get("id") == root["id"] and i.get("edited")))),
              api(call="store", conversation=channel))
        if reply:
            retracted = submit(kind="retract", conversation=channel, message=reply["id"])
            gone = poll(lambda: (m := find(channel, reply["id"])) and m.get("retracted") and m)
            check("message.retract marks the message retracted", bool(retracted.get("ok")) and bool(gone), gone or retracted)
    if shown:
        swift_text = f"from the Swift Home {stamp}"
        rpc("debug.home.drive", {"action": "type", "text": swift_text})
        rpc("debug.home.drive", {"action": "send"})
        check("a Swift Home send reaches the second subscriber", bool(poll(lambda: watched(swift_text))),
              api(call="watch_read"))
        check("a Swift Home send is in the owner's snapshot", bool(poll(lambda: newest(channel, swift_text))))
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "swift-home.png")})
finally:
    if pid:
        rpc("action.run", {"id": "quitEndSessions"})
        poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
        acp = f"{home}/.acpmux/tags/{opts.tag}"
        subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                       env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
