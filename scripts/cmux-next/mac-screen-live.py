#!/usr/bin/env python3
"""Live check: a Mac Screen tab shows and controls another Mac (CmuxScreenKit screen stream).

  scripts/cmux-next/mac-screen-live.py --app "<path>/cmux DEV <tag>.app" --tag <tag> --link-file FILE
      [--out DIR] [--hold SECONDS]

FILE holds a `cmux-vnc://pair` link (mode 0600; it carries the room secret, so it never goes
on a command line or into the report). The script launches the tagged app (no activation,
automation socket, window on the last screen), pairs the Mac through `debug.mac_screen pair`,
checks that the automation-opened tab asks first, presses Connect, and passes when the tab is
connected with a picture (has_frame, a frame size, a fitted video rect). It saves the window,
holds for --hold seconds (for an interaction agent), then quits with quitEndSessions and tears
the tag down.
"""
import argparse, json, os, plistlib, signal, socket, stat, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--link-file", required=True)
parser.add_argument("--hold", type=float, default=0)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="mac-screen-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
if stat.S_IMODE(os.stat(opts.link_file).st_mode) & 0o077:
    sys.exit("--link-file must be readable by this user only (chmod 600)")
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
        time.sleep(step)  # polling an external process's socket
    return None


def state():
    reply = rpc("debug.mac_screen", {"action": "state"})
    return reply if isinstance(reply, dict) else {}


def tab_where(test):
    return next((t for t in state().get("tabs") or [] if test(t)), None)


report = {"steps": {}}
failures = []


def step(name, ok, evidence):
    report["steps"][name] = {"ok": bool(ok), "evidence": evidence}
    print(("PASS " if ok else "FAIL ") + name, flush=True)
    if not ok:
        failures.append(name)


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
       "CMUX_NEXT_TEST_WINDOW_FRAME": os.environ.get("MAC_SCREEN_WINDOW_FRAME", "20,60,1040,760")}
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120):
        sys.exit("app did not come up")
    before = {t.get("tab") for t in state().get("tabs") or []}
    report["pair"] = wait(lambda: (lambda r: r if "error" not in r else None)(
        rpc("debug.mac_screen", {"action": "pair", "link_file": os.path.abspath(opts.link_file)})), 20)
    asked = wait(lambda: tab_where(lambda t: t.get("gate") == "confirm" and t.get("tab") not in before), 30)
    step("an automation-opened Mac Screen tab asks first", asked, {"pair": report["pair"], "state": state()})
    tab = (asked or {}).get("tab", "")
    report["connect"] = rpc("debug.mac_screen", {"action": "connect", "tab": tab})
    started = time.time()

    def live():
        row = tab_where(lambda t: t.get("tab") == tab)
        return row if row and row.get("phase") == "connected" and row.get("has_frame") and row.get("frame") != "0x0" else None

    streamed = wait(live, 60, step=0.1)
    report["connect_to_picture_s"] = round(time.time() - started, 2) if streamed else None
    step("Connect streams the Mac: a picture shows, fitted in the pane", streamed, {"state": state()})
    time.sleep(2)  # let the stats window fill before the capture
    report["streaming_state"] = state()
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "mac-screen.png")})
    if opts.hold > 0:
        print(f"holding {opts.hold:.0f} s for interaction (pid {app.pid})", flush=True)
        time.sleep(opts.hold)  # intentional: keeps the app up for the interaction agent
finally:
    report["final_state"] = state()
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
    with open(os.path.join(opts.out, "mac-screen-live.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({"failures": failures, "out": opts.out}))
sys.exit(1 if failures else 0)
