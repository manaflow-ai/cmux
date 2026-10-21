#!/usr/bin/env python3
"""Tagged-app check of the Swift Home's message menu and my tapback (cx-frd9).

Launches the tagged app with no activation, makes a local channel with one
message of mine through the real Home data path (`debug.home.api`), opens it,
builds the context menu at my bubble through the right-click's path
(`debug.home.drive menu`: the tapback palettes and the icon items), then reacts
with love through the picker's path (`debug.home.drive tapback`,
`ChatIntents.react`) and checks the owner and HomeStore have it. The tapback
comes back as my own (MessagesLab's badge pop); screenshots before and after. No system input: socket only.
Runs on cmux-lawrence-2; ends with the DEBUG quit fixture and the tag's
`acpmux daemon shutdown`.

Usage: home-menu-tapback-smoke.py --tag <tag> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-menu-tapback-smoke")
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
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def api(**params):
    return rpc("debug.home.api", params)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:500]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait, not app code
    return None


def shown():
    return ((rpc("debug.home") or {}).get("page") or {}).get("shown")


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
    me = inbox["me"]
    stamp = str(int(time.time()))
    created = api(call="submit", op={"kind": "create_group", "title": f"tapback-{stamp}", "participants": []})
    conversation = created.get("conversation")
    if not check("a local channel", bool(conversation), created):
        sys.exit(1)
    text = f"Tapback me {stamp}"
    api(call="submit", op={"kind": "send", "conversation": conversation, "text": text})
    message = poll(lambda: next((m for m in (api(call="snapshot", conversation=conversation, tail=10) or {}).get("messages") or []
                                  if m.get("text") == text), None))
    check("the owner committed my message", bool(message))

    def opened():
        if shown() != conversation:
            rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation}, "focus": True})
            time.sleep(1)  # test harness: one request per second while Home starts
            return None
        return text in ((rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts") or [])
    check("Home shows my message", bool(poll(opened, timeout=180)), rpc("debug.home.drive", {"action": "texts"}))

    menu = rpc("debug.home.drive", {"action": "menu", "mine": True}) or {}
    items = menu.get("items") or []
    check("the menu at my bubble has both tapback palettes", items[:2] == ["[palette]", "[palette]"], menu)
    check("the menu has its other items (Tapback Details, Attach Sticker, Copy)",
          len([i for i in items if i not in ("[palette]", "-")]) >= 3, menu)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "before.png")})
    tap = rpc("debug.home.drive", {"action": "tapback", "mine": True}) or {}
    check("my tapback goes to HomeStore", bool(tap.get("ok")), tap)
    mine = lambda m: any(r.get("author") == me for r in (m or {}).get("reactions", []))
    owner = poll(lambda: next((m for m in (api(call="snapshot", conversation=conversation, tail=10) or {}).get("messages") or []
                                if m.get("text") == text and mine(m)), None))
    check("the owner has my tapback", bool(owner), api(call="snapshot", conversation=conversation, tail=5))
    stored = poll(lambda: next((i for i in (api(call="store", conversation=conversation) or {}).get("items") or []
                                 if i.get("text") == text and i.get("reactions", 0) > 0), None))
    check("HomeStore has my tapback", bool(stored), api(call="store", conversation=conversation))
    time.sleep(1.5)  # test harness: let the badge's pop settle before the screenshot
    check("Home still shows my message", text in ((rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts") or []))
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "tapback.png")})
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = "%s/.acpmux/builds/com.cmuxterm.app.debug.%s" % (home, re.sub(r"[^a-z0-9]+", ".", opts.tag.lower()).strip("."))
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown", "--end-agents"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
