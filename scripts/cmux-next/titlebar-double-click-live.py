#!/usr/bin/env python3
"""Titlebar double-click live check on the GUI host (Leo, cosmic-gray 2026-10-13).

  titlebar-double-click-live.py --tag <tag> --out DIR [--mode zoom|minimize|none|all]

For each mode, launches the tagged app (no activation, automation socket, own
config) with the titlebar setting in its argument domain
(`-AppleActionOnDoubleClick Maximize|Minimize|None`; the user's global setting
is never touched), double-clicks empty titlebar space with `debug.mouse` (the
real `sendEvent` path; the user's pointer never moves) and reads the window
frame right after and 1.5 s later:

  zoom      the frame changes and stays changed (a window that zooms twice
            ends where it started: the bug)
  minimize  the window stops being visible
  none      the frame stays put

Points come from `debug.layers` with `titlebar_band` (DEBUG builds): the sidebar header (top
left, beside the traffic lights), empty tab-strip space, and a split divider's
handle in the top row, where a double-click is the divider's and the window
stays put whatever the setting. Zoom mode first runs the Window > Zoom action
as a control. Writes report.json and app.log to DIR and exits 1 when a check
fails. Kills only the app it started.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--mode", default="all", choices=["zoom", "minimize", "none", "all"])
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV*.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SETTING = {"zoom": "Maximize", "minimize": "Minimize", "none": "None"}
START = [80, 80, 1100, 720]


def rpc(method, params=None, timeout=30):
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


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def frame():
    """The window frame, read only (debug.window_frame would set it again and stop a zoom in flight)."""
    windows = (rpc("debug.layers") or {}).get("windows") or [{}]
    return windows[0].get("frame")


def visible():
    windows = (rpc("debug.windows") or {}).get("windows") or [{}]
    return windows[0].get("visible")


def same(a, b, tolerance=1.0):
    return a is not None and b is not None and all(abs(x - y) <= tolerance for x, y in zip(a, b))


def launch(mode):
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    config = os.path.join(opts.out, f"cmux-{mode}.json")
    with open(config, "w") as f:
        f.write("{}\n")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, START))}
    log = open(os.path.join(opts.out, "app.log"), "a")
    return subprocess.Popen([BINARY, "-AppleActionOnDoubleClick", SETTING[mode]], env=env, stdout=log, stderr=log,
                            stdin=subprocess.DEVNULL)


def points():
    """From `debug.layers` `titlebar_band` at y 12: the middle of the sidebar header's widest window-moving
    run, of the main area's widest one (empty tab-strip space), and a split divider's handle (a
    press there is the divider's: the window must stay put whatever the setting)."""
    rpc("debug.window_frame", {"frame": START})
    time.sleep(0.8)
    band = rpc("debug.layers", {"titlebar_band": True})["titlebar_band"]
    row = min(band["rows"], key=lambda r: abs(r["y"] - 12))
    report["band_row"] = row
    moving = [r for r in row["runs"] if r["moves"] and r["hit"] not in ("DividerHandleView", "SidebarResizeHandle")]
    def widest(runs):
        run = max(runs, key=lambda r: r["x"][1] - r["x"][0])
        return (run["x"][0] + run["x"][1]) / 2
    found = [("sidebar_header", widest([r for r in moving if r["x"][1] <= 210]), row["y"], True),
             ("strip_empty_space", widest([r for r in moving if r["x"][0] >= 210 and r["hit"] != "WindowRootView"]), row["y"], True)]
    handles = [r for r in row["runs"] if r["hit"] == "DividerHandleView"]
    if handles:
        found.append(("divider_handle", (handles[0]["x"][0] + handles[0]["x"][1]) / 2, row["y"], False))
    return found


def check(mode, name, x, y):
    """Double-clicks window point (x, y) from a fresh window frame; returns the case record."""
    rpc("debug.window_frame", {"frame": START})
    time.sleep(0.8)
    before = frame()
    clicked = rpc("debug.mouse", {"action": "double_click", "x": x, "y": y})
    time.sleep(0.6)
    soon, shown_soon = frame(), visible()
    time.sleep(1.5)
    late, shown_late = frame(), visible()
    if mode == "zoom":
        ok = not same(before, late, 4) and same(soon, late) and shown_late
    elif mode == "minimize":
        ok = shown_late is False
    else:
        ok = same(before, late) and shown_late
    record = {"mode": mode, "point": name, "x": x, "y": y, "before": before, "after_0_6s": soon, "after_2_1s": late,
              "visible": [shown_soon, shown_late], "debug_mouse": clicked, "pass": bool(ok)}
    print(json.dumps(record), flush=True)
    return record


report = {"tag": opts.tag, "cases": []}
modes = ["zoom", "minimize", "none"] if opts.mode == "all" else [opts.mode]
for mode in modes:
    app = launch(mode)
    try:
        if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
            sys.exit("app did not come up")
        time.sleep(3)
        report["identify"] = rpc("system.identify")
        # Top left: the sidebar header beside the traffic lights. Right: the empty top-row band.
        if mode == "zoom":
            # Control: the Window > Zoom action, no titlebar press involved.
            rpc("debug.window_frame", {"frame": START})
            time.sleep(0.8)
            control = {"before": frame(), "reply": rpc("action.run", {"action": "zoomWindow"})}
            time.sleep(1.5)
            control["after"] = frame()
            report["zoom_action_control"] = control
            print(json.dumps({"zoom_action_control": control}), flush=True)
        for name, x, y, moves in points():
            report["cases"].append(check(mode if moves else "none", name, x, y))
            if mode == "minimize":
                break  # a minimized window takes no second click
    finally:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(15)
        except subprocess.TimeoutExpired:
            app.kill()
with open(os.path.join(opts.out, "report.json"), "w") as f:
    json.dump(report, f, indent=1)
failed = [c for c in report["cases"] if not c["pass"]]
print(f"{len(report['cases']) - len(failed)}/{len(report['cases'])} pass")
sys.exit(1 if failed else 0)
