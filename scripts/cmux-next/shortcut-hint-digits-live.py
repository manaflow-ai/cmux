#!/usr/bin/env python3
"""Live behavior proof of the workspace digit chips (modifier-hold shortcut hints), through a
tagged app's own socket: with Cmd held, every workspace row's chip shows the digit whose
Cmd-digit (`selectWorkspaceByNumber`) selects that same row. Home and the App Store are sidebar
items that Cmd-1 and Cmd-2 select (sidebar.numbering allItems), so a chip that counts only
workspace rows names the wrong row (found by the GPUI port, cmux2-0b).
Run on cmux-lawrence-2 through `nx-remote --needs gui --app-from-fleet cmux`, never the laptop.
Usage: shortcut-hint-digits-live.py TAG APP OUT_DIR
"""
import json, os, socket, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
SESSION = "cmux-app-%s" % TAG
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


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or [{}]
    return windows[0]


def selected_title():
    selection = sidebar().get("selection") or []
    return selection[0] if len(selection) == 1 else None


def title_of(workspace_id):
    for row in sidebar().get("rows") or []:
        if workspace_id in str(row.get("key")):
            return row.get("title")
    return None


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="hint-digits-")
CONFIG, GHOSTTY = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
# The defaults under proof, written out: every sidebar item is numbered, Cmd-9 is the last one.
open(CONFIG, "w").write(json.dumps({"sidebar": {"numbering": "allItems", "cmd9": "last"},
                                    "shortcuts": {"showModifierHoldHints": True}}))
open(GHOSTTY, "w").write("")
# Launched like a person's launch (no CMUX_NEXT_NO_ACTIVATE): the hint monitor needs the app active and its window key.
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
       "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,430,1200,800"}
# Through LaunchServices (`open -n`, build-host README): an app a script spawns directly may not activate.
log = os.path.join(OUT, "app-%s.log" % TAG)
launch = ["open", "-n", "--stdout", log, "--stderr", log] + [a for k, v in env.items() for a in ("--env", "%s=%s" % (k, v))]
print("open:", subprocess.run(launch + [APP], capture_output=True, text=True).returncode, flush=True)
try:
    check("launch", wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180, 0.5))
    for name in ("hint-alpha", "hint-bravo", "hint-charlie"):
        cli("workspace", "create", "--name", name, "--json")
    check("rows", wait(lambda: sum(1 for r in sidebar().get("rows") or [] if r.get("title", "").startswith("hint-")) == 3, 20),
          [r.get("title") for r in sidebar().get("rows") or []])
    top = [i.get("ref") for i in sidebar().get("items") or [] if i.get("region") == "top"]
    print("top items:", top, flush=True)
    window = ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")
    print("focus:", json.dumps(rpc("debug.window.focus", {"window": window})), flush=True)
    held = rpc("debug.shortcut_hints", {"modifier": "cmd"})
    shown = wait(lambda: [h for h in (rpc("debug.shortcut_hints", {"modifier": "cmd"}) or {}).get("hints") or []
                          if str(h.get("target") or "").startswith("workspace:")], 10)
    rpc("debug.shortcut_hints", {"modifier": "release"})
    print("hold:", json.dumps(held)[:300], flush=True)
    check("chips-shown", len(shown) >= 3, shown)
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "hints.png")}, timeout=60)
    for hint in shown:
        workspace = hint["target"].split(":", 1)[1]
        digits = [c for c in hint["text"] if c.isdigit()]
        title = title_of(workspace)
        if not digits:
            check("chip-digit %s" % title, False, hint)
            continue
        digit = int(digits[-1])
        rpc("action.run", {"id": "selectWorkspaceByNumber", "args": {"index": digit}})
        got = wait(lambda: selected_title() == title and title, 5)
        check("chip %s on %s selects it" % (hint["text"], title), got, "selected %r" % selected_title())
finally:
    print("teardown quit:", json.dumps(rpc("action.run", {"id": "quit", "args": {"endSessions": True}}, timeout=10))[:200])
    gone = wait(lambda: not os.path.exists(SOCKET) or "error" in (rpc("debug.windows", timeout=2) or {}), 60, 0.5)
    stop = os.environ.get("NX_APP_STOP")
    if not gone and stop:
        print("app did not quit; NX_APP_STOP", flush=True)
        subprocess.run([stop], timeout=60)
    subprocess.run([CLI, "server", "stop", "--session", SESSION, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
failed = [name for name, ok in results if not ok]
print("RESULT pass=%d fail=%d %s" % (len(results) - len(failed), len(failed), " ".join(failed)), flush=True)
sys.exit(1 if failed else 0)
