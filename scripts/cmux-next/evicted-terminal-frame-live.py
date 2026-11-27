#!/usr/bin/env python3
"""An evicted terminal shows its last frame at once when it is shown again (cx-8w027.10 b).

  evicted-terminal-frame-live.py --tag <tag> [--app APP] --out DIR

Launches the tagged app (no activation, automation socket, own config), prints a long output in
the first terminal tab, opens more terminal tabs than the warm set keeps (`warm_terminal_capacity`
in `debug.surfaces`), so the first tab's surface is evicted and closed, then selects the first tab
again (Go to Tab) and samples its pane in `debug.surfaces` as fast as the socket
answers. Pass: the first sample of the new session already shows the held last frame
(`frame_held`, `last_frame_holds` 1), the hold ends, and the terminal then shows the output
again (its text). Stops only the app it started (by its PID) and the tag's daemons.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/evicted-terminal-frame")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
MARK = "evicted-frame-mark"


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
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


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def surfaces(text=False):
    return rpc("debug.surfaces", {"text": True} if text else {}) or {}


def focused_pane(report):
    for window in report.get("windows") or []:
        for pane in window.get("panes") or []:
            if pane.get("focused"):
                return pane
    return None


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,760"}
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"pid": app.pid, "samples": []}
ok = False
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("app did not come up")
    report["new_workspace"] = rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: focused_pane(surfaces()), 30)
    cli_env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    written = subprocess.run([CLI, "--app-socket", SOCKET, "--json", "terminal", "current", "write", "--text",
                              f"clear; seq 1 60; echo {MARK}\r"],
                             capture_output=True, text=True, timeout=60, env=cli_env, stdin=subprocess.DEVNULL)
    report["write"] = {"exit": written.returncode, "err": written.stderr[-400:]}
    if not wait(lambda: MARK in str((focused_pane(surfaces(text=True)) or {}).get("text") or ""), 30):
        sys.exit("the first terminal never showed its output")
    first = focused_pane(surfaces())
    capacity = int(surfaces().get("warm_terminal_capacity") or 0)
    report["capacity"] = capacity
    report["first_tab"] = first.get("selected_tab")
    for index in range(capacity + 2):
        before = (focused_pane(surfaces()) or {}).get("selected_tab")
        rpc("action.run", {"action": "newSurface", "focus": True})
        wait(lambda: (focused_pane(surfaces()) or {}).get("selected_tab") not in (None, before), 30, 0.1)
        time.sleep(0.3)  # test harness: the new terminal draws before the next one hides it
    report["live_before"] = surfaces().get("live_terminals")
    report["last_frames_before"] = surfaces().get("last_frames")
    # Go to Tab on the first tab: the evicted terminal.
    report["select"] = rpc("action.run", {"action": "tab.search", "target": f"tab:{report['first_tab']}", "focus": True})
    start = time.monotonic()
    while time.monotonic() - start < 5:  # test harness: sample the pane as fast as the socket answers
        pane = focused_pane(surfaces()) or {}
        report["samples"].append({"ms": round((time.monotonic() - start) * 1000, 1), "tab": pane.get("selected_tab"),
                                  "held": pane.get("frame_held"), "holds": pane.get("last_frame_holds"),
                                  "phase": pane.get("phase"), "attach": pane.get("attach")})
        if pane.get("selected_tab") == report["first_tab"] and pane.get("frame_held") is False and pane.get("last_frame_holds"):
            break
    report["last_frames_after"] = surfaces().get("last_frames")
    shown = focused_pane(surfaces(text=True)) or {}
    report["text_back"] = MARK in str(shown.get("text") or "")
    # The pane's fields follow the content it presents: the first sample of the new session
    # (holds counted) must already hold the last frame, and the hold must end.
    session = [s for s in report["samples"] if s["tab"] == report["first_tab"] and s["holds"]]
    report["first_sample"] = session[0] if session else None
    ok = bool(session) and session[0]["held"] is True and session[0]["holds"] == 1 \
        and session[-1]["held"] is False and report["text_back"]
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    teardown.end()
    with open(os.path.join(opts.out, "samples.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({k: report.get(k) for k in ("write", "capacity", "first_tab", "live_before", "last_frames_before",
                                              "select", "last_frames_after", "first_sample", "text_back")}))
print("samples:", json.dumps(report["samples"][:12]), "...", json.dumps(report["samples"][-3:]))
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
