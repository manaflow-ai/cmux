#!/usr/bin/env python3
"""Tagged-app check: Return on an empty Home field sends nothing (MessagesLab d0017ba, Reducer.canSend).

Launches the tagged app with no activation, makes a local channel with one message of mine through
the Home data path (debug.home.api), opens it, then presses Return through the field's own send path
(debug.home.drive send) with an empty field and with only spaces and new lines. Each must be refused
(empty_draft) and change nothing: the view's texts, HomeStore's transcript and the owner's log
stay as they were. A real send after it still goes. Screenshots before and after.
Socket only, no system input. Runs on cmux-lawrence-2; ends with the DEBUG quit fixture and the tag's
`acpmux daemon shutdown`.

Usage: home-empty-send.py --tag <tag> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-empty-send")
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
    stamp = str(int(time.time()))
    created = api(call="submit", op={"kind": "create_group", "title": f"empty-send-{stamp}", "participants": []})
    conversation = created.get("conversation")
    if not check("a local channel", bool(conversation), created):
        sys.exit(1)
    first = f"Only message {stamp}"
    api(call="submit", op={"kind": "send", "conversation": conversation, "text": first})

    def opened():
        if shown() != conversation:
            rpc("action.run", {"id": "home.show", "focus": True})
            rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation}, "focus": True})
            time.sleep(1)  # test harness: one request per second while Home starts
            return None
        return first in ((rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts") or [])
    check("Home shows my message", bool(poll(opened, timeout=180)), rpc("debug.home.drive", {"action": "texts"}))

    def state():
        view = (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")
        store = [i.get("text") for i in (api(call="store", conversation=conversation) or {}).get("items") or []]
        owner = [m.get("text") for m in (api(call="snapshot", conversation=conversation, tail=20) or {}).get("messages") or []]
        return {"view": view, "store": store, "owner": owner}
    before = state()
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "before.png")})
    for label, typed in (("an empty field", ""), ("only spaces and new lines", "   \n  ")):
        if typed:
            rpc("debug.home.drive", {"action": "focus"})
            rpc("debug.home.drive", {"action": "type", "text": typed})
        reply = rpc("debug.home.drive", {"action": "send"}) or {}
        check(f"Return on {label} is refused", "empty_draft" in str(reply.get("refused", "")), reply)
        time.sleep(1.0)  # test harness: give a wrong send time to reach the owner before comparing
        check(f"Return on {label} changes nothing (view, HomeStore, owner)", state() == before, {"before": before, "after": state()})
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "after-empty-returns.png")})
    real = f"Real send {stamp}"
    rpc("debug.home.drive", {"action": "type", "text": real})
    sent = rpc("debug.home.drive", {"action": "send"}) or {}
    check("a real send still goes", bool(sent.get("ok")), sent)
    check("the owner has the real send",
          bool(poll(lambda: real in [m.get("text").strip() for m in (api(call="snapshot", conversation=conversation, tail=20) or {}).get("messages") or []])),
          api(call="snapshot", conversation=conversation, tail=5))
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
