#!/usr/bin/env python3
"""Tagged-app check: nested threads in the native Home (MessagesLab tree mode, cx-och3h).

Lawrence 2026-10-14: "we need to be able to make new channels and threads in imessage ui. infinitely nested
threads. with links to each message etc". The daemon owns the tree (conversation-tree-v1: `reply_to` = the
parent at any depth, `thread_root` = the top root); both Home views render it.

Launches the tagged app (classic Home, CMUX_NEXT_CLASSIC_HOME=1) with no activation. On the local owner (the
Chief home's cmux-tui session) it makes a conversation. Then, through the user's paths only:
1. types a root message R in Home's field and presses Return;
2. Reply... on R (the context menu of my newest bubble), types A, Return: A answers R;
3. Reply... on A, types B, Return: the owner stores B with reply_to = A and thread_root = R (depth 2);
4. Reply... on B, types C, Return: C has reply_to = B, thread_root = R (depth 3);
5. the owner's `conversation-link-resolve` of C's link gives the path [R, A, B, C];
6. opens each level: "N Replies" under R (the thread, path [R]); "N Replies" under A in the thread view
   (path [R, A]); under B (path [R, A, B]); a screenshot of each;
7. follows the permalink of C (the docked Home's hand-off route `#/conversation/<c>/message/<C>`): Home opens
   C's branch, path [R, A, B, C], the same path the owner resolves;
8. the Channels page (the React view of the same daemon data) at that route shows A, B and C at depth 1, 2, 3.
Then the thread view draws no header above its root (as in Messages, cmux#26686); Copy Link on C gives the permalink the owner resolves; and a
permalink to a nested message 130 messages older than the loaded window loads older pages and opens its branch.
No system input: socket only. Runs on cmux-lawrence-2 (nx-remote --needs gui --app-from-fleet); ends with the
DEBUG quit fixture, endAgents and the tag's `acpmux daemon shutdown`.

Usage: home-tree-thread-check.py --tag <tag> [--app APP] [--out DIR]
"""
import argparse, json, os, re, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app")
parser.add_argument("--out", default="/tmp/home-tree-thread-check")
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
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:700]}"), flush=True)
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


def shot(name):
    time.sleep(1)  # test harness: the view's motion settles before the screenshot
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name + ".png")})


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


def text_of(m):
    return " ".join(p.get("text", "") for p in m.get("parts") or [])


def owner_message(conversation, text):
    """The owner's stored message with this text (snapshot tail): id, reply_to, thread_root."""
    for m in (daemon(owner, "conversation-snapshot", conversation=conversation, tail=50).get("messages") or []):
        if text_of(m) == text:
            return {"id": m.get("id"), "reply_to": (m.get("reply_to") or {}).get("message_id"), "thread_root": m.get("thread_root")}
    return None


def send_from_field(text):
    drive("focus")
    drive("type", text=text)
    return drive("send")


# Channels on, in a config file of this run only (the host user's cmux.json stays untouched).
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write('{"home": {"channelsEnabled": true}}\n')
if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900", "CMUX_NEXT_CONFIG_FILE": config, **home_classic.ENV}
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
    created = daemon(owner, "conversation-create", idempotency_key=f"tree-thread-{stamp}", actor=me, title=f"Tree thread {stamp}",
                     participants=[{"id": me, "kind": "human", "display_name": "Me"},
                                   {"id": "agent_instinct", "kind": "agent", "display_name": "Maybe: Instinct"}])
    conversation = (created.get("conversation") or {}).get("id")
    if not check("a conversation", bool(conversation), created):
        sys.exit(1)
    result["conversation"] = conversation
    # One message so Home has something to show before the root goes out.
    first = f"Tree start {stamp}"
    daemon(owner, "conversation-op", conversation=conversation, idempotency_key=f"tree-start-{stamp}", actor=me,
           op={"kind": "message.send", "client_msg_id": f"tree-start-{stamp}", "parts": [{"type": "text", "text": first}]})

    def opened():
        if ((rpc("debug.home") or {}).get("page") or {}).get("shown") != conversation:
            rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation}, "focus": True})
            time.sleep(1)  # test harness: one request per second while Home starts
            return None
        return first in (drive("texts").get("texts") or [])
    check("Home shows the conversation", bool(poll(opened, timeout=180)), drive("texts"))

    texts = {k: f"{k} {stamp}" for k in ("R", "A", "B", "C")}
    ids = {}
    # 1: the root, from Home's field.
    sent = send_from_field(texts["R"])
    check("Return sends the root R", bool(sent.get("ok")), sent)
    root = poll(lambda: owner_message(conversation, texts["R"]))
    check("the owner stores R as a plain message", bool(root) and not root.get("thread_root"), root)
    if not root:
        sys.exit(1)
    ids["R"] = root["id"]
    shot("1-root")

    # 2-4: Reply... on my newest bubble (R, then A, then B), a reply from the thread view's field.
    for parent, child in (("R", "A"), ("A", "B"), ("B", "C")):
        state = drive("thread_state")
        if state.get("open_thread"):
            drive("escape"); drive("escape")
        state = drive("reply", mine=True)
        result[f"reply-{child}"] = state
        check(f"Reply... on {parent} opens a thread view", bool(state.get("open_thread")), state)
        sent = send_from_field(texts[child])
        check(f"Return in the thread view sends {child}", bool(sent.get("ok")), sent)
        stored = poll(lambda: owner_message(conversation, texts[child]))
        result[f"owner-{child}"] = stored
        check(f"the owner stores {child} with reply_to = {parent} (the message replied to)",
              bool(stored) and stored.get("reply_to") == ids[parent], {"stored": stored, "parent": ids[parent]})
        check(f"the owner stores {child} in R's thread (thread_root = R)", bool(stored) and stored.get("thread_root") == ids["R"], stored)
        if not stored:
            sys.exit(1)
        ids[child] = stored["id"]
        shot(f"2-reply-{child}")
    result["ids"] = ids

    thread = daemon(owner, "conversation-thread", conversation=conversation, root=ids["R"])
    count = (thread.get("thread") or {}).get("reply_count")
    check("the owner's thread of R counts every level (3 replies)", count == 3, thread)
    resolved = daemon(owner, "conversation-link-resolve", url=f"cmux://conversation/{conversation}/message/{ids['C']}")
    result["resolve"] = resolved
    want_path = [ids["R"], ids["A"], ids["B"], ids["C"]]
    check("the owner resolves C's link to the path [R, A, B, C] (depth 3)", resolved.get("path") == want_path, resolved)

    # 6: open each level.
    state = drive("thread_state")
    if state.get("open_thread"):
        drive("escape"); drive("escape")
    check("the thread view is closed", drive("thread_state").get("open_thread") is None, drive("thread_state"))
    state = drive("thread")
    result["level-0"] = state
    check("\"N Replies\" under R opens R's whole thread (path [R])", state.get("thread_path") == [ids["R"]], state)
    shot("3-level-0")
    state = drive("branch", text=texts["A"])
    result["level-1"] = state
    check("\"N Replies\" under A in the thread view opens A's branch (path [R, A])",
          state.get("thread_path") == [ids["R"], ids["A"]] and state.get("thread_message") == ids["A"], state)
    shot("4-level-1")
    state = drive("branch", text=texts["B"])
    result["level-2"] = state
    check("\"N Replies\" under B opens B's branch (path [R, A, B])",
          state.get("thread_path") == [ids["R"], ids["A"], ids["B"]] and state.get("thread_message") == ids["B"], state)
    shot("5-level-2")
    drive("escape"); drive("escape")
    check("Esc closes the thread view", drive("thread_state").get("open_thread") is None, drive("thread_state"))

    # 7: the permalink of the depth-3 message.
    route = f"#/conversation/{conversation}/message/{ids['C']}"
    opened_link = drive("permalink", url=route)
    check("Home takes C's permalink", bool(opened_link.get("ok")), opened_link)
    state = poll(lambda: (s := drive("thread_state")) and s.get("thread_path") == want_path and s, timeout=10) or drive("thread_state")
    result["permalink"] = state
    check("C's permalink opens C's branch, path [R, A, B, C] = the owner's resolved path",
          state.get("thread_path") == want_path and state.get("thread_message") == ids["C"], state)
    shot("6-permalink-C")

    # 9: no thread header (https://github.com/manaflow-ai/cmux/issues/26686): as in Messages, the root bubble is the
    # thread view's first row; the thread object stays on the owner and in Channels.
    head = drive("header")
    result["header"] = head
    check("the thread view is open and draws no header above the root", head.get("open") == "1" and head.get("header") == "", head)

    # 10: Copy Link on a message: the daemon's permalink form, which the owner resolves to its thread path.
    drive("escape"); drive("escape")
    copied = drive("copy_link", text=texts["C"])
    result["copy_link"] = copied
    link = copied.get("link") or ""
    check("Copy Link copies C's permalink (<scheme>://conversation/<c>/message/<C>)",
          link.startswith("cmux") and link.endswith(f"://conversation/{conversation}/message/{ids['C']}"), copied)
    check("the owner resolves the copied link to [R, A, B, C]",
          (daemon(owner, "conversation-link-resolve", url=link).get("path") if link else None) == want_path, link)

    # 11: a permalink to a nested message older than Home's loaded window (tail 60) loads older pages.
    created = daemon(owner, "conversation-create", idempotency_key=f"tree-old-{stamp}", actor=me, title=f"Tree old {stamp}",
                     participants=[{"id": me, "kind": "human", "display_name": "Me"},
                                   {"id": "agent_instinct", "kind": "agent", "display_name": "Maybe: Instinct"}])
    old_conv = (created.get("conversation") or {}).get("id")

    def seed(text, parent=None, root=None):
        key = f"seed-{abs(hash(text))}-{stamp}"
        op = {"kind": "message.send", "client_msg_id": key, "parts": [{"type": "text", "text": text}]}
        if parent:
            op["reply_to"] = {"message_id": parent, "part_index": 0}
        if root:
            op["thread_root"] = root
        r = daemon(owner, "conversation-op", conversation=old_conv, idempotency_key=key, actor=me, op=op)
        return ((r.get("change") or {}).get("message") or {}).get("id")
    o_r = seed(f"Old root {stamp}")
    o_a = seed(f"Old A {stamp}", o_r, o_r)
    o_b = seed(f"Old B {stamp}", o_a, o_r)
    for i in range(130):
        seed(f"Old filler {i} {stamp}")
    check("the owner holds an old nested reply (depth 2) under 130 newer messages", bool(o_r and o_a and o_b), [o_r, o_a, o_b])
    conversation = old_conv
    first = f"Old filler 129 {stamp}"
    check("Home shows the newest message of the old conversation", bool(poll(opened, timeout=120)), drive("texts"))
    check("the old reply is outside Home's loaded window", f"Old B {stamp}" not in (drive("texts", limit=500).get("texts") or []))
    drive("permalink", url=f"#/conversation/{old_conv}/message/{o_b}")
    state = poll(lambda: (s := drive("thread_state")) and s.get("thread_path") == [o_r, o_a, o_b] and s, timeout=40) or drive("thread_state")
    result["old_permalink"] = state
    check("its permalink loads older pages and opens its branch, path [root, A, B]",
          state.get("thread_path") == [o_r, o_a, o_b] and state.get("thread_message") == o_b, state)
    shot("10-old-permalink")
    conversation = result["conversation"]

    # 8: the same thread in Channels (the React view of the same daemon data).
    run = rpc("action.run", {"id": "home.channels", "focus": True})
    page = {"page": "cmux.home-channels"}
    ready = poll(lambda: (s := rpc("debug.page", dict(page, action="state"))) and s.get("painted") and s, timeout=60)
    check("the Channels page paints", bool(ready), {"run": run, "state": rpc("debug.page", dict(page, action="state"))})
    rpc("debug.page", dict(page, action="route", route=route))

    def depths():
        elements = (rpc("debug.page", dict(page, action="query", selector="article.hc-msg[data-depth]")) or {}).get("elements") or []
        found = {}
        for k in ("A", "B", "C"):
            hit = next((e for e in elements if texts[k] in (e.get("text") or "")), None)
            if hit:
                found[k] = (hit.get("data") or {}).get("depth")
        return found if len(found) == 3 else None
    shown = poll(depths, timeout=30)
    result["channels"] = shown
    check("Channels shows A, B and C in R's thread at depth 1, 2 and 3", shown == {"A": "1", "B": "2", "C": "3"},
          {"shown": shown, "elements": (rpc("debug.page", dict(page, action="query", selector="article.hc-msg")) or {}).get("elements")})
    rpc("debug.page", dict(page, action="snapshot", path=os.path.join(opts.out, "7-channels.png")))
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
