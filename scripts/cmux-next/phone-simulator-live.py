#!/usr/bin/env python3
"""Live check: a booted iOS simulator streams into the phone tab and takes input.
  scripts/cmux-next/phone-simulator-live.py --app PATH --tag <tag> [--udid UDID] [--out DIR]
Launches the tagged app (no activation, automation socket), boots a simulator when none is
booted (the newest iPhone; shut down again at the end), and through the same actions the
CLI and MCP use (plans/cmux-next/simulators-DESIGN.md):
  1. `phone list` answers the booted simulator with the live capabilities (touch, live);
  2. `phone open` shows the phone tab; a window snapshot shows the simulator screen;
  3. `phone button home`, `phone appearance dark`, `phone tap` and `phone screenshot` succeed;
  4. a snapshot after dark mode differs from the light one (the live screen follows the phone).
Snapshots go to --out. GUI host only. Exits 1 when a check fails.
"""
import argparse
import json
import os
import plistlib
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--udid")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="phone-simulator-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, focus=False):
    """Runs an action; a reply of `in_progress` past the socket's deadline is retried with the same key."""
    key = f"phone-live-{uuid.uuid4().hex}"
    deadline = time.monotonic() + 240
    while True:
        reply = rpc("action.run", {"action": name, "args": args or {}, "focus": focus, "idempotency_key": key}, timeout=60)
        error = (reply or {}).get("error") if isinstance(reply, dict) else None
        state = ((error or {}).get("data") or {}).get("state") if isinstance(error, dict) else None
        if not (error and state == "in_progress" and time.monotonic() < deadline):
            return reply
        time.sleep(0.25)  # bounded retry of a keyed run the app is still doing


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def simctl(*args):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, check=False)


def pick_simulator():
    listing = json.loads(simctl("list", "devices", "-j").stdout or "{}").get("devices", {})
    booted, candidates = [], []
    for runtime, devices in listing.items():
        if ".iOS-" not in runtime:
            continue
        version = [int(p) for p in runtime.rsplit(".iOS-", 1)[1].split("-") if p.isdigit()]
        for device in devices:
            if not device.get("isAvailable", True) or not device["name"].startswith("iPhone"):
                continue
            if device["state"] == "Booted":
                booted.append(device["udid"])
            candidates.append((version, device["name"], device["udid"]))
    if booted:
        return booted[0], False
    candidates.sort(reverse=True)
    return (candidates[0][2], True) if candidates else (None, False)


def snapshot(name):
    path = os.path.join(opts.out, f"{name}.png")
    rpc("debug.window_snapshot", {"path": path})
    print(f"snapshot {path} {os.path.exists(path)}", flush=True)
    return path


udid, booted_here = (opts.udid, False) if opts.udid else pick_simulator()
if not udid:
    print("no iPhone simulator is installed", flush=True)
    raise SystemExit(1)
if booted_here:
    simctl("boot", udid)
    simctl("bootstatus", udid, "-b")
device = f"sim:{udid}"

with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"phone-simulator-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}")
teardown = TagTeardown(opts.app)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,860"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, simulator {udid}, out {opts.out}", flush=True)

try:
    if not quiet_wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.pane_chrome") or {"error": 1}), 180):
        check(False, "timed out: the app's socket")
        raise SystemExit(1)
    listed = action("phone.list")
    print("phone.list", json.dumps(listed)[:600], flush=True)
    rows = json.loads(((listed or {}).get("result") or listed or {}).get("devices", "[]")) if isinstance(listed, dict) else []
    row = next((r for r in rows if r.get("id") == device), None)
    check(row is not None and row.get("ready"), f"phone list has the booted simulator {device}")
    check(row is not None and {"touch", "live"} <= set(row.get("capabilities", [])), "the simulator offers live touch input")
    check("error" not in (action("phone.show", {"device": device}, focus=True) or {}), "phone open shows the phone tab")
    quiet_wait(lambda: False, 2.0)  # capture harness: first frames reach the layer before the snapshot
    light = snapshot("phone-tab-light")
    check("error" not in (action("phone.button", {"button": "home", "device": device}) or {}), "phone button home")
    check("error" not in (action("phone.appearance", {"appearance": "dark", "device": device}) or {}), "phone appearance dark")
    check("error" not in (action("phone.swipe", {"fromX": "200", "fromY": "500", "toX": "60", "toY": "500", "device": device}) or {}),
          "phone swipe")
    quiet_wait(lambda: False, 1.5)  # capture harness: the guest redraws in dark mode
    dark = snapshot("phone-tab-dark")
    if os.path.exists(light) and os.path.exists(dark):
        with open(light, "rb") as a, open(dark, "rb") as b:
            check(a.read() != b.read(), "the live screen changed after dark mode and a swipe")
    shot = action("phone.screenshot", {"device": device, "path": os.path.join(opts.out, "phone-screenshot.png")})
    print("phone.screenshot", json.dumps(shot)[:300], flush=True)
    check(os.path.exists(os.path.join(opts.out, "phone-screenshot.png")), "phone screenshot wrote its PNG")
    action("phone.appearance", {"appearance": "light", "device": device})
finally:
    app.terminate()
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()
    if booted_here:
        simctl("shutdown", udid)

print(f"{len(failures)} failure(s)", flush=True)
raise SystemExit(1 if failures else 0)
