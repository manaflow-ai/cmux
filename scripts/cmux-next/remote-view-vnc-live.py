#!/usr/bin/env python3
"""Live check: the desktop pane streams from a VNC (RFB) compatibility host (remote-desktop.md 12).

  scripts/cmux-next/remote-view-vnc-live.py --app "<path>/cmux DEV <tag>.app" --tag <tag>
      [--url 'cmux://remote-view?host=mock&via=vnc'] [--user NAME --password-stdin] [--out DIR]

GUI host only (a fleet capture mini or the build host), never a developer laptop. The default
URL is the loopback VNC demo desktop (`host=mock&via=vnc`, CmuxVNCDemoServer in the app). For a
real host (macOS Screen Sharing or any VNC server on the tailnet), pass its record URL and, when
it needs a sign-in, --user plus the password on stdin: the script writes them to a 0600 file the
development build reads through CMUX_NEXT_VNC_DEBUG_CREDENTIALS_FILE (an SSH session cannot
unlock the login Keychain) and deletes it after the run.
The script launches the tagged app (no activation, automation socket), opens the URL through
`debug.remote_view open`, checks the tab asks first, presses Connect (`debug.remote_view
connect`), and passes only when the tab's session is a VNC session (`source: vnc`) that streams
and shows frame pixels, then saves the window. Ends with quitEndSessions and the tag teardown.
"""
import argparse, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--url", default="cmux://remote-view?host=mock&via=vnc&mode=control")
parser.add_argument("--user", default="")
parser.add_argument("--password-stdin", action="store_true")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="vnc-view-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = os.path.abspath(opts.app)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"


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


def tabs():
    reply = rpc("debug.remote_view", {"action": "state"})
    return (reply if isinstance(reply, dict) else {}).get("tabs") or []


def tab_where(test):
    return next((t for t in tabs() if test(t)), None)


report = {"steps": {}, "url": opts.url}
failures = []


def step(name, ok, evidence):
    report["steps"][name] = {"ok": bool(ok), "evidence": evidence}
    if not ok:
        failures.append(name)
    print(("PASS " if ok else "FAIL ") + name, json.dumps(evidence)[:600], flush=True)


credentials_file = None
if opts.password_stdin:
    password = sys.stdin.readline().rstrip("\n")
    descriptor, credentials_file = tempfile.mkstemp(prefix="vnc-credentials-", suffix=".json")
    with os.fdopen(descriptor, "w") as f:  # mkstemp creates it 0600
        json.dump({"username": opts.user or None, "password": password}, f)

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
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820"}
if credentials_file:
    env["CMUX_NEXT_VNC_DEBUG_CREDENTIALS_FILE"] = credentials_file
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120):
        sys.exit("app did not come up")
    before = {t.get("tab") for t in tabs()}
    for index in range(1, 10):
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        report["open"] = wait(lambda: (lambda r: r if "error" not in r else None)(
            rpc("debug.remote_view", {"action": "open", "url": opts.url})), 3)
        if report["open"]:
            break
    asked = wait(lambda: tab_where(lambda t: t.get("confirm") and t.get("tab") not in before), 30)
    step("an automation-opened VNC tab asks first", asked, {"open": report["open"], "tabs": tabs()})
    report["connect"] = rpc("debug.remote_view", {"action": "connect", "tab": (asked or {}).get("tab", "")})

    def streaming():
        row = tab_where(lambda t: t.get("tab") == (asked or {}).get("tab") and (t.get("session") or {}).get("source") == "vnc")
        session = (row or {}).get("session") or {}
        pixels = session.get("frame_pixels") or "0x0"
        return row if session.get("state") == "streaming" and pixels != "0x0" else None

    streamed = wait(streaming, 90)
    step("Connect streams the VNC host: frames show in the pane", streamed, {"connect": report["connect"], "tabs": tabs()})
    if streamed:
        time.sleep(2)  # let the animated demo advance a few frames before the capture
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "vnc-desktop.png")})
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
    if credentials_file:
        os.unlink(credentials_file)
    report["failures"] = failures
    with open(os.path.join(opts.out, "vnc-view-live.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({"failures": failures, "out": opts.out}))
sys.exit(1 if failures else 0)
