#!/usr/bin/env python3
"""Hidden-sidebar title bar reveal along a fixed pointer path, recorded (cmux#60461, Leo 2026-11-27: "if you've
revealed those leftmost buttons, they should stay until you move out of the top tab area / and maybe the hoverable
situatoin would be like... should only be around the sidebar toggle + maybe its constituent padding?").

  python3 -I scripts/cmux-next/titlebar-hover-reveal.py --app APP --tag TAG --arm NAME --out DIR

Launches the tagged DEBUG app (scratch config), reads where the open toolbar band sits (sidebar shown), hides the
sidebar, then walks the pointer: content, the gap after the traffic lights, the toggle, Back, Forward, the middle and
far right of the tab bar, down into the content, up to Back from below (at rest), the toggle. At each stop it dwells
0.7 s and prints one TRH-STEP line from `debug.pane_chrome` (pointer inside, revealed, band presence, button alphas).

The pointer: real mouse-moved events along each leg (pointer-probe.swift `path`) when this session may post them (the
cursor arrives); else cua-driver warps the real cursor there (the reveal's own pointer read sees it) and
`debug.mouse hover` gives the tracking areas the entered and exited events a real move would. The mode prints as
TRH-MODE. The display is recorded through CuaDriver (tab_switch_capture.CuaSession) into DIR/recording.mp4 when it
can; TRH-VIDEO names it. Quits the app with its own quit; signals only the PID it started.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

p = argparse.ArgumentParser()
p.add_argument("--app", required=True)
p.add_argument("--tag", required=True)
p.add_argument("--arm", required=True)
p.add_argument("--out", required=True)
p.add_argument("--probe", required=True, help="the built pointer-probe binary")
o = p.parse_args()
SOCK = f"/tmp/cmux-debug-{o.tag}.sock"
FRAME = (40, 40, 1100, 760)
CUA = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"


def rpc(method, params=None, timeout=30):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(SOCK)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    c.close()
    r = json.loads(buf or b"{}")
    return r.get("result") if r.get("ok") else {"error": r.get("error")}


def wait(check, seconds, step=0.2):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait on the app's state
        try:
            v = check()
        except OSError:
            v = None
        if v:
            return v
        time.sleep(step)
    return None


def chrome():
    w = ((rpc("debug.pane_chrome") or {}).get("windows") or [{}])[0]
    return w.get("window_controls") or {}, w.get("titlebar_buttons") or {}


def probe(*args):
    r = subprocess.run([o.probe, *map(str, args)], capture_output=True, text=True, timeout=30)
    return r.stdout.strip()


def cua(tool, params):
    try:
        out = subprocess.run([CUA, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=30).stdout
        return json.loads(out or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


APP = o.app.rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BIN = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
cfg = os.path.join(tempfile.mkdtemp(prefix=f"trh-{o.tag}-"), "cmux.json")
with open(cfg, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCK):
    os.unlink(SOCK)
os.makedirs(o.out, exist_ok=True)
app = subprocess.Popen([BIN], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": cfg,
    "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, FRAME))},
    stdout=open(os.path.join(o.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
session = None
try:
    wait(lambda: os.path.exists(SOCK) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60)
    time.sleep(2)
    # The open band's place: with the sidebar shown it is fully present, where the hover opens it over a hidden one.
    controls, _ = chrome()
    if controls.get("sidebar_hidden"):
        rpc("action.run", {"action": "toggleSidebar", "origin": "script"})
        wait(lambda: not chrome()[0].get("sidebar_hidden") and chrome()[0].get("band_presence", 0) >= 1, 10)
    controls, _ = chrome()
    bx, by, bw, bh = controls["band_frame"]
    rpc("action.run", {"action": "toggleSidebar", "origin": "script"})
    if not wait(lambda: chrome()[0].get("sidebar_hidden") and chrome()[0].get("band_presence", 1) == 0, 10):
        raise SystemExit("titlebar-hover-reveal: the sidebar did not hide")
    height = FRAME[3]
    row_y = height - (by + bh / 2)  # window-local, from the top
    print(f"TRH-BAND {o.arm} open_band_frame={[bx, by, bw, bh]} row_y={row_y}", flush=True)
    toggle, back, forward = bx + bw / 6, bx + bw / 2, bx + bw * 5 / 6
    content_y = 320
    path = [("content", 560, content_y), ("lights_gap", bx - 4, row_y), ("toggle", toggle, row_y),
            ("back", back, row_y), ("forward", forward, row_y), ("tab_mid", FRAME[2] / 2, row_y),
            ("tab_right", FRAME[2] - 40, row_y), ("content_below", FRAME[2] - 40, content_y),
            ("below_back", back, content_y), ("back_from_below", back, row_y), ("toggle_again", toggle, row_y)]

    windows = probe("windows", app.pid).splitlines()
    import re
    nums = [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", windows[0])] if windows else []
    wx, wy = (nums[1], nums[2]) if len(nums) >= 3 else (FRAME[0], FRAME[1])
    scale = float(cua("get_screen_size", {}).get("scale_factor") or 2.0)

    def screen(x, y):
        return wx + x, wy + y

    # Real moves when posting works: the cursor arrives where the event put it.
    sx, sy = screen(560, content_y)
    probe("move", sx, sy)
    time.sleep(0.2)
    where = probe("where").split()
    real = len(where) >= 2 and where[0].replace(".", "", 1).lstrip("-").isdigit() and abs(float(where[0]) - sx) < 2 and abs(float(where[1]) - sy) < 2
    print(f"TRH-MODE {o.arm} {'real-events' if real else 'warp+debug-hover'} window_at={wx},{wy} scale={scale}", flush=True)

    try:
        from tab_switch_capture import CuaSession, CaptureError
        session = CuaSession()
        session.open()
        session.start(o.out)
    except Exception as error:  # noqa: BLE001 - a run with no recording still prints its steps
        print(f"TRH-VIDEO {o.arm} none ({error})", flush=True)
        session = None
    time.sleep(0.5)
    last = (560, content_y)
    rows = []
    for name, x, y in path:
        if real:
            (ax, ay), (tx, ty) = screen(*last), screen(x, y)
            probe("path", ax, ay, tx, ty, 24)
        else:
            tx, ty = screen(x, y)
            cua("move_cursor", {"x": round(tx * scale), "y": round(ty * scale), "scope": "desktop"})
            rpc("debug.mouse", {"action": "hover", "x": x, "y": y})
        last = (x, y)
        time.sleep(0.7)
        controls, buttons = chrome()
        row = {"arm": o.arm, "step": name, "x": round(x, 1), "y": round(y, 1),
               "pointer_inside": buttons.get("pointer_inside"), "revealed": buttons.get("revealed"),
               "band_presence": round(controls.get("band_presence", -1), 3),
               "toggle_alpha": round(buttons.get("toggle_alpha", -1), 2), "back_alpha": round(buttons.get("back_alpha", -1), 2)}
        rows.append(row)
        print("TRH-STEP " + " ".join(f"{k}={v}" for k, v in row.items()), flush=True)
    with open(os.path.join(o.out, "steps.json"), "w") as f:
        json.dump(rows, f, indent=1)
    if session is not None:
        try:
            print(f"TRH-VIDEO {o.arm} {session.stop(o.out)}", flush=True)
        except Exception as error:  # noqa: BLE001
            print(f"TRH-VIDEO {o.arm} none ({error})", flush=True)
finally:
    if session is not None:
        session.close()
    try:
        rpc("action.run", {"action": "quit", "origin": "script"}, timeout=5)
    except OSError:
        pass
    try:
        app.wait(15)
    except subprocess.TimeoutExpired:
        app.terminate()  # the PID this script started
