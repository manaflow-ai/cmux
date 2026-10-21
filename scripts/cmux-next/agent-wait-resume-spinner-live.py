#!/usr/bin/env python3
"""Live behavior proof of #22995 (a working agent's sidebar row showed no spinner), through a
tagged app's own sockets: real Claude hook events (`cmux agent hook emit`) into one terminal of
the app's daemon, and the row the sidebar draws (`debug.sidebar_rows` `shows_working`).

A prompt spins the row; an approval, a question and a plan review each wait (no spinner); the
next tool hook after the answer spins it again; a failed tool call keeps it spinning; the turn's
end stops it. Before the fix the row stayed waiting after every answer and a failed tool call
stopped the spinner. Run on cmux-lawrence-2 (GUI host), never the laptop:

    nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA -- \
      'python3 scripts/cmux-next/agent-wait-resume-spinner-live.py "$NX_APP_TAG" "$NX_APP" "$NX_ARTIFACTS"'

Usage: agent-wait-resume-spinner-live.py TAG APP OUT_DIR
"""
import json, os, socket, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
SESSION = "cmux-app-%s" % TAG
CAPTURE = os.environ.get("NX_CAPTURE")
NAME = "spin-22995"
os.makedirs(OUT, exist_ok=True)
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print("%s %s %s" % ("PASS" if ok else "FAIL", name, str(detail)[:600]), flush=True)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def cli(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    r = subprocess.run([CLI, "--session", SESSION, *args], env=env, capture_output=True, text=True, timeout=60)
    return r.stdout.strip() or r.stderr.strip()


def wait(predicate, seconds, step=0.25):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def row():
    for window in (rpc("debug.sidebar_rows") or {}).get("windows") or []:
        for r in window.get("rows") or []:
            if r.get("title") == NAME:
                return r
    return None


def value(out):
    try:
        reply = json.loads(out)
    except ValueError:
        return {}
    return reply.get("value", reply) if isinstance(reply, dict) else reply


def hook(event, **payload):
    payload["session_id"] = "claude-22995"
    out = cli("agent", "hook", "emit", "--source", "claude", "--event", event, "--terminal", TERMINAL,
              "--payload-json", json.dumps(payload))
    print("hook %s %s: %s" % (event, payload.get("tool_name", ""), out[:200]), flush=True)


def expect(label, working):
    """The row settles to `working` (spinner) or not; the store maps a row once per frame."""
    got = wait(lambda: (r := row()) is not None and bool(r.get("shows_working")) == working and r, 10)
    check(label, got, json.dumps(row()))


def shot(label):
    if not CAPTURE:
        return
    path = os.path.join(OUT, "%s.png" % label)
    p = subprocess.run(["bash", CAPTURE, "shot", "--pid", str(app.pid), "--out", path],
                       capture_output=True, text=True, timeout=60)
    print("shot %s: %s" % (path, (p.stdout or p.stderr).strip()[:200]), flush=True)


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="spin-22995-")
CONFIG, GHOSTTY = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
       "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
try:
    wins = wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180, 0.5)
    check("launch", wins, json.dumps(wins)[:200])
    made = value(cli("workspace", "create", "--name", NAME, "--json"))
    terminals = value(cli("terminal", "list", "--workspace", str(made.get("workspace_id", NAME)), "--json"))
    terminals = terminals if isinstance(terminals, list) else terminals.get("terminals", [])
    TERMINAL = next((t.get("id") or t.get("terminal_id") for t in terminals if isinstance(t, dict)), None)
    check("terminal", TERMINAL, json.dumps(made)[:300])
    check("row", wait(row, 20), json.dumps(rpc("debug.sidebar_rows"))[:300])

    hook("SessionStart")
    hook("UserPromptSubmit", prompt="ship it")
    expect("prompt-spins", True)

    for tool, ask in (("Bash", "PermissionRequest"), ("AskUserQuestion", "PreToolUse"), ("ExitPlanMode", "PreToolUse")):
        hook(ask, tool_name=tool)
        expect("%s-waits" % tool, False)
        if tool == "Bash":
            shot("waiting")
        hook("PostToolUse", tool_name=tool)
        expect("%s-answered-spins" % tool, True)
    shot("working-after-answer")

    hook("PreToolUse", tool_name="Bash")
    hook("PostToolUseFailure", tool_name="Bash")
    expect("failed-tool-keeps-spinning", True)

    hook("Stop")
    expect("turn-end-stops", False)
    shot("idle")
finally:
    # Never kill the app (REPAIR.md): nx-remote's stop, else the quit verb that ends the
    # tag's terminals and stops its daemon without a sheet.
    if os.environ.get("NX_APP_STOP"):
        subprocess.run([os.environ["NX_APP_STOP"]], timeout=120)
    else:
        print("quit:", json.dumps(rpc("action.run", {"id": "quitEndSessions"}))[:200], flush=True)
    try:
        app.wait(60)
    except subprocess.TimeoutExpired:
        check("app-quit", False, "the app still runs: stop it with action.run quitEndSessions")

failed = [name for name, ok in results if not ok]
print("RESULT %s (%d checks, %d failed: %s)" % ("PASS" if not failed else "FAIL", len(results), len(failed), failed), flush=True)
sys.exit(1 if failed else 0)
