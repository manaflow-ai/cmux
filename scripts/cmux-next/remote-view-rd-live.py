#!/usr/bin/env python3
"""Live check: the desktop pane streams from a real Linux `cmux-rd host` (cx-wb5.75).

  scripts/cmux-next/remote-view-rd-live.py --tag <tag> --port <loopback port> --token-file <file>
                                           --user <host owner> [--out DIR] [--min-frames 30]

GUI host only (cmux-lawrence-2 or the M1 Max through nx-remote), never a developer laptop.
The host side runs elsewhere: a Linux `cmux-rd host --owner USER --token-fd N` (Xvfb plus
`cmux-rd testapp --workload motion`) reached through an SSH tunnel on this Mac's loopback
`--port`; `--token-file` holds the host's 64-hex token (mode 0600). The script launches the
tagged app (no activation, automation socket) with CMUX_RD_DEBUG_PORT, CMUX_RD_DEBUG_TOKEN_FILE
and CMUX_RD_DEBUG_USER, opens `cmux://remote-view?host=local&target=virtual&mode=view` through
`debug.remote_view open`, presses Connect (`debug.remote_view connect`, the button's closure),
and passes only when the tab's session is a real rd session (`source: rd`) that streams and
decoded at least --min-frames frames with no decode errors. Without the opt-in environment the
same tab shows "not available" (the red). Ends with quitEndSessions and the tag teardown.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--token-file", required=True)
parser.add_argument("--user", required=True, help="the Linux host's --owner")
parser.add_argument("--min-frames", type=int, default=30)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="rd-view-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
URL = "cmux://remote-view?host=local&target=virtual&mode=view"


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def state():
    reply = rpc("debug.remote_view", {"action": "state"})
    return reply if isinstance(reply, dict) else {}


def tabs():
    return state().get("tabs") or []


def tab_where(test):
    return next((t for t in tabs() if test(t)), None)


report = {"steps": {}}
failures = []


def step(name, ok, evidence):
    report["steps"][name] = {"ok": bool(ok), "evidence": evidence}
    if not ok:
        failures.append(name)
    print(("PASS " if ok else "FAIL ") + name, json.dumps(evidence)[:600], flush=True)


if os.path.exists(SOCKET):
    if "error" not in rpc("debug.focus"):
        sys.exit(f"an app with tag {opts.tag} is running; use another tag")
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820",
       "CMUX_RD_DEBUG_PORT": str(opts.port), "CMUX_RD_DEBUG_TOKEN_FILE": os.path.abspath(opts.token_file),
       "CMUX_RD_DEBUG_USER": opts.user}
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120):
        sys.exit("app did not come up")
    # A fresh app shows Home, which has no pane: select workspaces by number until one has a pane.
    for index in range(1, 10):
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        report["open"] = wait(lambda: (lambda r: r if "error" not in r else None)(
            rpc("debug.remote_view", {"action": "open", "url": URL})), 3)
        if report["open"]:
            break
    asked = wait(lambda: tab_where(lambda t: t.get("confirm")), 30)
    step("an automation-opened desktop tab asks first", asked, {"open": report["open"], "tabs": tabs()})
    report["connect"] = rpc("debug.remote_view", {"action": "connect", "tab": (asked or {}).get("tab", "")})

    def streaming():
        row = tab_where(lambda t: (t.get("session") or {}).get("source") == "rd")
        session = (row or {}).get("session") or {}
        return row if session.get("state") == "streaming" and (session.get("decoded") or 0) >= opts.min_frames else None

    streamed = wait(streaming, 60)
    final = tab_where(lambda t: (t.get("session") or {}).get("source") == "rd") or {}
    step("Connect streams the real rd host: frames decode in the pane",
         streamed and not (final.get("session") or {}).get("decode_errors"),
         {"connect": report["connect"], "state": state()})
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "desktop.png")})
finally:
    report["final_state"] = tabs()
    print("quit", rpc("action.run", {"id": "quitEndSessions"}), flush=True)
    try:
        app.wait(30)
    except subprocess.TimeoutExpired:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    teardown.end()
    report["failures"] = failures
    with open(os.path.join(opts.out, "rd-view-live.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({"failures": failures, "out": opts.out}))
sys.exit(1 if failures else 0)
