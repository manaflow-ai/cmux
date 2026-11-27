#!/usr/bin/env python3
"""cx-ohle live proof: after a tab drop the drop ring is gone and stays gone.

  drop-ring-e2e.py --tag <tag> --out DIR [--app PATH]

Launches the tagged app (no activation, automation socket, own config), opens a
workspace with two terminal tabs in one pane, then drags the second tab with
real mouse events (`debug.mouse`) to the right edge of the pane body and
releases: the drop splits the pane. Then a new column animates the strip.
Through both it reads the drop overlay (`debug.drop_highlight` `report`) every
50 ms. It fails if the ring is drawn again after the drop (the layout's frames
used to show the hidden ring at its last target, and it stayed), or if the
drop did not split.
Writes samples.json, after-drop.png and app.log to DIR. Quits only the app it
started.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--app", help="the tagged app bundle (a fleet-built artifact); default: the tag's DerivedData build")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = opts.app or next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"


def rpc(method, params=None, timeout=60):
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
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def strips():
    result = rpc("debug.tab_drag")
    return (result or {}).get("strips") or [] if isinstance(result, dict) else []


def focused_pane():
    windows = (rpc("debug.focus") or {}).get("windows") or [{}]
    return windows[0].get("layout_focused_pane")


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,760"}
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"pid": app.pid, "samples": []}
failure = None
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("app did not come up")
    time.sleep(2)
    report["new_workspace"] = rpc("action.run", {"action": "newTab", "focus": True})
    time.sleep(3)
    # A second terminal tab beside the focused one.
    report["new_terminal_tab"] = rpc("action.run", {"action": "newSurface", "focus": True})
    two = wait(lambda: [s for s in strips() if len(s.get("tabs") or []) >= 2], 15)
    if not two:
        raise RuntimeError(f"no strip with two tabs: {json.dumps(report['new_terminal_tab'])} {json.dumps(strips())[:1500]}")
    time.sleep(1.5)
    strip = two[0]
    report["strips_before"] = len(strips())
    tab = strip["tabs"][-1]["frame"]
    sx, sy, sw, sh = strip["frame"]
    start = (tab[0] + tab[2] / 2, tab[1] + tab[3] / 2)
    # The right edge band of the pane body, well inside it (the band is 28% of the width).
    drop = (sx + sw * 0.9, sy + sh + 220)
    report["drag"] = {"from": start, "to": drop}
    report["drop_reply"] = rpc("debug.mouse", {"action": "drag", "x": start[0], "y": start[1],
                                               "to_x": drop[0], "to_y": drop[1], "steps": 24})
    report["strips_after"] = len(wait(lambda: len(strips()) > report["strips_before"] and strips(), 3) or strips())
    began = time.time()
    while time.time() - began < 2.0:
        sample = rpc("debug.drop_highlight", {"report": True}) or {}
        sample["t"] = round(time.time() - began, 3)
        report["samples"].append(sample)
        time.sleep(0.05)  # test harness sampling interval
    # Any later layout animation runs the layout's frames: a new column
    # scrolls the strip. The hidden ring must not come back with them.
    report["new_column"] = rpc("action.run", {"action": "newColumn", "focus": True})
    began = time.time()
    while time.time() - began < 2.0:
        sample = rpc("debug.drop_highlight", {"report": True}) or {}
        sample["t"] = round(2.0 + time.time() - began, 3)
        report["samples"].append(sample)
        time.sleep(0.05)  # test harness sampling interval
    report["after"] = rpc("debug.drop_highlight", {"report": True})
    report["snapshot"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "after-drop.png")})
    # The ring may still be fading out right after the release; from 0.4 s on it must be gone.
    shown = [s for s in report["samples"] if s["t"] >= 0.4 and (s.get("showing") or (s.get("ring_opacity") or 0) > 0)]
    if report["strips_after"] <= report["strips_before"]:
        failure = f"the drop did not split the pane ({report['strips_before']} -> {report['strips_after']} strips)"
    elif shown:
        failure = f"the drop ring is drawn after the drop: {len(shown)} samples, first {json.dumps(shown[0])}"
except RuntimeError as error:
    failure = str(error)
finally:
    if app.poll() is None:
        rpc("action.run", {"action": "quit"}, timeout=10)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(20)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
    with open(os.path.join(opts.out, "samples.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({k: report.get(k) for k in ("drag", "strips_before", "strips_after", "after")}))
if failure:
    sys.exit(f"FAIL {failure}")
print("PASS the ring is gone after the drop and the pane split")
