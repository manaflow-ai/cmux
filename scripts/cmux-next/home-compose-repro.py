#!/usr/bin/env python3
"""Repro for the Swift Home compose field past ComposeView.maxLines (8 lines).

Lawrence: "multi-line text entry doesnt work, if i have too many lines, it
doesnt scroll down properly". Launches the tagged app with no activation,
shows a local channel, and through the debug socket only: types 15 lines with
Shift-Return (`debug.key`), pastes 30 lines (`debug.home.drive type`, the
field's text system), moves the caret to the middle and to the end. After each
step it saves a window snapshot (`debug.window_snapshot`) and the field height
(`debug.home.drive geometry`). The caret line must be visible in every shot.
Runs on cmux-lawrence-2 (GUI host), never on the laptop.

Usage: home-compose-repro.py --tag <tag> --out DIR
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
home = os.environ["HOME"]
app = f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
log = []


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


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.5)  # harness wait, not app code
    return None


def step(name):
    time.sleep(0.6)  # let the field's height animation finish before the shot
    path = os.path.join(opts.out, f"{name}.png")
    snap = rpc("debug.window_snapshot", {"path": path})
    geometry = rpc("debug.home.drive", {"action": "geometry"})
    entry = {"step": name, "png": path if os.path.exists(path) else None, "snapshot": snap, "geometry": geometry}
    log.append(entry)
    print(json.dumps(entry)[:300], flush=True)


env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local"}
if os.path.exists(sock):
    os.unlink(sock)
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
try:
    if not poll(lambda: "conversations" in (rpc("debug.home.api", {"call": "inbox"}) or {}), timeout=180):
        sys.exit("FAIL the local owner never answered")
    rpc("debug.window.ax_set_frame", {"frames": [[120, 120, 1100, 760]]})
    created = rpc("debug.home.api", {"call": "submit", "op": {"kind": "create_group", "title": "compose-repro", "participants": []}})
    channel = created.get("conversation")
    rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": channel, "text": "compose repro"}})
    rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": channel}, "focus": True})
    if not poll(lambda: (g := rpc("debug.home.drive", {"action": "geometry"})) and g.get("ok")):
        sys.exit("FAIL the channel is not shown")
    rpc("debug.home.drive", {"action": "focus"})
    step("0-empty")
    for index in range(15):
        for char in f"line {index + 1}":
            rpc("debug.key", {"key": char})
        if index < 14:
            rpc("debug.key", {"key": "return", "modifiers": ["shift"]})
        if index + 1 in (8, 9, 15):
            step(f"1-shift-return-{index + 1}-lines")
    for _ in range(7):
        rpc("debug.key", {"key": "up"})
    step("2-caret-middle-after-15")
    rpc("debug.key", {"key": "down", "modifiers": ["command"]})
    step("3-caret-end-after-15")
    rpc("debug.key", {"key": "a", "modifiers": ["command"]})
    rpc("debug.key", {"key": "delete"})
    rpc("debug.home.drive", {"action": "type", "text": "\n".join(f"pasted {i + 1}" for i in range(30))})
    step("4-paste-30-lines")
    for _ in range(15):
        rpc("debug.key", {"key": "up"})
    step("5-caret-middle-after-paste")
    rpc("debug.key", {"key": "down", "modifiers": ["command"]})
    step("6-caret-end-after-paste")
finally:
    rpc("action.run", {"id": "quitEndSessions"})
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = f"{home}/.acpmux/tags/{opts.tag}"
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
    with open(os.path.join(opts.out, "steps.json"), "w") as handle:
        json.dump(log, handle, indent=1)
