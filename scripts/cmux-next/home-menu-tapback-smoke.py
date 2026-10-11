#!/usr/bin/env python3
"""Tagged-app check of the Swift Home's message menu and my tapback (cx-frd9).

Launches the tagged app with no activation, opens the DEBUG Home fixture (the
real transcript view over a HomeStore over the mock owner), builds the context
menu at the newest incoming bubble through the right-click's path
(`debug.home.drive menu`: the tapback palettes and the icon items), then reacts
with love through the picker's path (`debug.home.drive tapback`,
`ChatIntents.react`). Screenshots before and after show my badge. No system input: socket only.
Runs on cmux-lawrence-2; ends with the DEBUG quit fixture and the tag's
`acpmux daemon shutdown`.

Usage: home-menu-tapback-smoke.py --tag <tag> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time

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
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
print(f"launched pid {pid}", flush=True)
try:
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    # The DEBUG Home fixture: the real HomeNativeTranscriptView over a HomeStore over the mock owner,
    # its Chief conversation with incoming messages (the isolated daemon's conversations may have none).
    opened = rpc("debug.home_native_fixture.open") or {}
    check("the Home fixture opens", bool(opened.get("ok")), opened)
    texts = poll(lambda: (t := (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")) and t, timeout=60)
    check("the fixture's transcript shows messages", bool(texts), rpc("debug.home.drive", {"action": "texts"}))

    menu = rpc("debug.home.drive", {"action": "menu"}) or {}
    items = menu.get("items") or []
    check("the menu at the incoming bubble has both tapback palettes", items[:2] == ["[palette]", "[palette]"], menu)
    check("the menu has its other items (Tapback Details, Attach Sticker, Copy)",
          len([i for i in items if i not in ("[palette]", "-")]) >= 3, menu)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "before.png")})
    tap = rpc("debug.home.drive", {"action": "tapback"}) or {}
    check("my tapback goes to HomeStore", bool(tap.get("ok")), tap)
    time.sleep(1.5)  # test harness: the mock owner commits and the badge's pop settles before the screenshot
    after = (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")
    check("the transcript keeps its messages", after == texts or bool(after), after)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "tapback.png")})
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = f"{home}/.acpmux/tags/{opts.tag}"
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
