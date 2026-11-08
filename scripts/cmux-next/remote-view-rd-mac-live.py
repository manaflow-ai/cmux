#!/usr/bin/env python3
"""Live check: the cmux-next desktop pane streams a macOS `cmux-rd host` on the same Mac.

  remote-view-rd-mac-live.py --app "<path>/cmux DEV <tag>.app" --rig ROOT [--out DIR]
                             [--flags "--max-width 2560 --max-fps 120"] [--seconds 20]

The host Mac runs cmux-tui/crates/cmux-rd-host/scripts/mac-rig.sh (started from a terminal
that holds Screen Recording and Accessibility). This script asks the rig for a loopback-only
host with FLAGS, launches the tagged app without activating it (automation socket), opens
`cmux://remote-view?host=local&target=virtual&mode=view` through `debug.remote_view open` in a
new workspace, quits keeping the layout and launches again (a tab opened in a run keeps its
pending key, which Connect cannot resolve until a relaunch), presses Connect
(`debug.remote_view connect`), and passes when the session is a real rd session that streams
with no decode errors. While it streams it saves the main window
(`debug.window_snapshot`) about twice a second for SECONDS, then quits the app
(quitEndSessions) and stops the host.
"""
import argparse, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--rig", required=True, help="the running mac-rig.sh ROOT")
parser.add_argument("--flags", default="--max-width 2560 --max-fps 120")
parser.add_argument("--seconds", type=float, default=20)
parser.add_argument("--out", default=tempfile.mkdtemp(prefix="rd-mac-view-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(opts.app, "Contents/MacOS", info["CFBundleExecutable"])
TAG = info["CFBundleIdentifier"].rsplit(".", 1)[-1]
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
URL = "cmux://remote-view?host=local&target=virtual&mode=view"
state_dir = os.path.join(opts.rig, "state")


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
        time.sleep(step)  # bounded wait for an app or host state (test driver only)
    return None


def tabs():
    reply = rpc("debug.remote_view", {"action": "state"})
    return (reply if isinstance(reply, dict) else {}).get("tabs") or []


report, failures = {"steps": {}}, []


def step(name, ok, evidence):
    report["steps"][name] = {"ok": bool(ok), "evidence": evidence}
    if not ok:
        failures.append(name)
    print(("PASS " if ok else "FAIL ") + name, json.dumps(evidence)[:600], flush=True)


# The host: loopback only, through the rig (fresh logs, then its listening line).
for name in ("host.log", "marker.log"):
    try:
        os.unlink(os.path.join(state_dir, name))
    except FileNotFoundError:
        pass
with open(os.path.join(state_dir, "host-flags"), "w") as f:
    f.write(opts.flags + " --loopback 1\n")
with open(os.path.join(opts.rig, "ctl"), "w") as f:
    f.write("rd\n")
listening = wait(lambda: "listening on 127.0.0.1" in open(os.path.join(state_dir, "host.log")).read()
                 if os.path.exists(os.path.join(state_dir, "host.log")) else None, 15, 0.1)
os.unlink(os.path.join(state_dir, "host-flags"))
step("the rig started a loopback host", listening, {"flags": opts.flags})

config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,60,1280,860",
       "CMUX_NEXT_RD_DEBUG_PORT": "4103", "CMUX_NEXT_RD_DEBUG_TOKEN_FILE": os.path.join(state_dir, "token"),
       "CMUX_NEXT_RD_DEBUG_USER": "owner"}
log = open(os.path.join(opts.out, "app.log"), "a")


def launch():
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120):
        quit_app(app)
        sys.exit("app did not come up")
    return app


def quit_app(app):
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


def row():
    # Connect reopens the URL as a connecting tab: any tab with a session counts.
    return next((t for t in tabs() if t.get("session")), {}) or {}


app = None
try:
    # Launch 1: a workspace with the desktop tab, quit keeping the layout. A tab opened in a
    # run keeps its pending key until a relaunch, and Connect looks the tab up by that key.
    app = launch()
    report["workspace"] = rpc("action.run", {"id": "newTab", "args": {"name": "rd mac host", "focus": True}})
    report["select"] = rpc("action.run", {"id": "workspace.selectLast"})
    report["open"] = rpc("debug.remote_view", {"action": "open", "url": URL})
    asked = wait(lambda: next((t for t in tabs() if t.get("confirm")), None), 30)
    step("an automation-opened desktop tab asks first", asked, {"open": report["open"]})
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "asks-first.png")})
    quit_app(app)
    # Launch 2: the restored tab, in the last workspace, then Connect (the button's closure).
    app = launch()
    report["select2"] = rpc("action.run", {"id": "workspace.selectLast"})
    report["connect"] = rpc("debug.remote_view", {"action": "connect"})
    streamed = wait(lambda: (lambda s: s if s.get("source") == "rd" and s.get("state") == "streaming"
                             and (s.get("decoded") or 0) >= 30 else None)(row().get("session") or {}), 60)
    step("Connect streams the macOS rd host: frames decode in the pane",
         streamed and not (row().get("session") or {}).get("decode_errors"),
         {"session": row().get("session"), "state": rpc("debug.remote_view", {"action": "state"})})
    frames, deadline, index = [], time.time() + opts.seconds, 0
    first = (row().get("session") or {}).get("decoded") or 0
    started = time.time()
    while time.time() < deadline:
        path = os.path.join(opts.out, "pane-%03d.png" % index)
        rpc("debug.window_snapshot", {"kind": "main", "path": path})
        if os.path.exists(path):
            frames.append(path)
        index += 1
        time.sleep(0.5)  # snapshot cadence for the proof stills
    last = row().get("session") or {}
    report["pane_fps"] = ((last.get("decoded") or 0) - first) / (time.time() - started)
    report["final_session"] = last
    step("the pane keeps streaming with no decode errors",
         frames and report["pane_fps"] > 0 and not last.get("decode_errors"),
         {"snapshots": len(frames), "pane_decoded_fps": round(report["pane_fps"], 1), "session": last})
finally:
    if app is not None and app.poll() is None:
        quit_app(app)
    with open(os.path.join(opts.rig, "ctl"), "w") as f:
        f.write("stop\n")
    report["failures"] = failures
    with open(os.path.join(opts.out, "rd-mac-view-live.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({"failures": failures, "out": opts.out}))
sys.exit(1 if failures else 0)
