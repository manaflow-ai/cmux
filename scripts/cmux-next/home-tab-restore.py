#!/usr/bin/env python3
"""Tagged-app relaunch check: Home tabs the daemon restores after a relaunch show their transcript.

Launch 1 (no activation): a channel with 3 messages on the local owner; a native Home tab (`home.tab`) shows it
(`home.openConversation`); then the DEBUG Home fixture tab (`debug.home_native_fixture.open`), and the Home tab
selected again (`home.tab` is not reused: the Home tab is selected by opening the conversation once more). Quit with
the DEBUG quit fixture (end-sessions); the tag's daemon keeps the panes' tabs.
Launch 2, with no open request first: the restored native Home tab must show the same conversation with its
messages in its own transcript view (`debug.home` page.tabs: shown, transcript_tail), and the restored fixture tab
must show its transcript when selected through the default open (pages.show: before the fix its provider was
registered only on the first open, after the pane had shown the tab blank).
Socket only, no system input. Runs on cmux-lawrence-2 (nx-remote --needs gui); each launch ends with the DEBUG quit
fixture; the tag's `acpmux daemon shutdown` at the end.

Usage: home-tab-restore.py --tag <tag> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-tab-restore")
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


def submit(**op):
    return api(call="submit", op=op) or {}


def launch(n):
    if os.path.exists(sock):
        os.unlink(sock)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
           "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    p = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                         stdout=open(os.path.join(opts.out, f"app-{n}.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
    print(f"launch {n}: pid {p.pid}", flush=True)
    return p.pid


def quit_app(pid):
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    return poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)


def home_tabs():
    return ((rpc("debug.home") or {}).get("page") or {}).get("tabs") or []


TEXTS = ["Restore one.", "Restore two.", "Restore three."]
pid = launch(1)
try:
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("launch 1: the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    created = submit(kind="create_group", title=f"restore-{int(time.time())}", participants=[])
    conv = created.get("conversation") if created.get("ok") else None
    check("launch 1: a local channel", bool(conv), created)
    for t in TEXTS:
        submit(kind="send", conversation=conv, text=t)
    rpc("action.run", {"id": "home.tab", "focus": True})
    def shows_conv():
        rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conv}, "focus": True})
        time.sleep(1)  # test harness: one request per second while the tab starts, not app code
        tabs = [t for t in home_tabs() if t.get("shown") == conv and all(x in (t.get("transcript_tail") or []) for x in TEXTS)]
        return tabs or None
    before = poll(shows_conv, timeout=90)
    check("launch 1: a native Home tab shows the channel with its messages", bool(before), home_tabs())
    fixture = rpc("debug.home_native_fixture.open", {"new": True}) or {}
    check("launch 1: the fixture tab opens", bool(fixture.get("ok")), fixture)
    fx = poll(lambda: (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts"), timeout=30)
    check("launch 1: the fixture shows its transcript", bool(fx), rpc("debug.home.drive", {"action": "texts"}))
    # The Home tab selected again (it is the tab the window shows when it comes back).
    again = poll(shows_conv, timeout=30)
    check("launch 1: the Home tab is shown again", bool(again), home_tabs())
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "launch-1.png")})
finally:
    check("launch 1: the app quits", bool(quit_app(pid)))

pid = launch(2)
try:
    poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    # No open request: what the restored window shows by itself.
    restored = poll(lambda: [t for t in home_tabs() if t.get("visible") and t.get("shown") == conv
                             and all(x in (t.get("transcript_tail") or []) for x in TEXTS)] or None, timeout=60)
    print("     restored Home tabs: " + json.dumps(home_tabs())[:800], flush=True)
    check("launch 2: the restored native Home tab shows the same channel with its messages", bool(restored), home_tabs())
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "launch-2-home.png")})
    # The restored fixture tab, selected through the default open (it finds the restored tab).
    reply = rpc("debug.home_native_fixture.open") or {}
    fx = poll(lambda: (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts"), timeout=30)
    check("launch 2: the restored fixture tab shows its transcript", bool(fx), {"open": reply, "texts": rpc("debug.home.drive", {"action": "texts"})})
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "launch-2-fixture.png")})
finally:
    quit_app(pid)
    acp = f"{home}/.acpmux/tags/{opts.tag}"
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
