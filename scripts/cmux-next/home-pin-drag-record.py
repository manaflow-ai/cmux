#!/usr/bin/env python3
"""Records a pin drag in Home's conversation list (the user's 2026-10-20 recording: a row
dragged up to the pinned avatars, then down the list, then back up and dropped there).

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \
    python3 scripts/cmux-next/home-pin-drag-record.py --app "$NX_APP" --out "$NX_ARTIFACTS/rec"

Launches the tagged app (classic Home, automation socket), lists six fixture conversations
with one pinned (`debug.home.sidebar_fixture`), starts `debug.window_record` (one JPEG per
display frame) and drags with `debug.mouse` events at --hz, one request per pointer step, so
the list's own tracking loop gets them as a real drag. --reduce-motion pins Reduce Motion
(`debug.motion`) first. Writes OUT/frames (the recording), OUT/drag.json (the path and the
item frames) and OUT/home.json.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the tagged .app")
parser.add_argument("--out", required=True)
parser.add_argument("--hz", type=float, default=120)
parser.add_argument("--reduce-motion", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app
TAG = os.environ.get("NX_APP_TAG") or os.path.basename(APP).removesuffix(".app").split(" ")[-1]
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
STOP = os.environ.get("NX_APP_STOP")


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


def wait(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)  # harness wait for the app's socket, not app code
    return False


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
config.write("{}")
config.close()
pairs = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
         f"CMUX_NEXT_CONFIG_FILE={config.name}", "ACPMUX_AGENT_LAUNCH=deny", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,900,820",
         "CMUX_NEXT_CLASSIC_HOME=1", "NX_REMOTE=1"]
# `open` (Launch Services), as the other nx-remote scripts: a direct exec of the bundle is refused its sandbox extension.
subprocess.run(["open", "-n", APP, *[arg for pair in pairs for arg in ("--env", pair)]], check=True)
code = 1
try:
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180):
        sys.exit(f"the tagged app did not come up (socket {SOCKET} exists: {os.path.exists(SOCKET)}; "
                 f"debug.windows: {json.dumps(rpc('debug.windows'))[:300]})")
    print("home.show", rpc("action.run", {"action": "home.show", "focus": True}), flush=True)
    time.sleep(3)
    rpc("debug.appearance", {"mode": "dark"})
    if opts.reduce_motion:
        print("reduce motion", rpc("debug.motion", {"action": "reduce", "value": True}), flush=True)
    print("fixture", json.dumps(rpc("debug.home.sidebar_fixture", {"count": 6, "pinned": 1, "width": 320}))[:300], flush=True)
    time.sleep(2)
    home = rpc("debug.home")
    json.dump(home, open(os.path.join(opts.out, "home.json"), "w"), indent=1, default=str)
    items = (((home or {}).get("page") or {}).get("sidebar") or {}).get("items") or []
    tiles = [i for i in items if i["pinned"]]
    rows = [i for i in items if not i["pinned"]]
    if not tiles or len(rows) < 5:
        sys.exit(f"no fixture list: {json.dumps(items)[:400]}")

    def box(i):
        f = i["frame"]
        return (f["x"], f["y"], f["width"], f["height"]) if isinstance(f, dict) else tuple(f)

    rx, ry, rw, rh = box(rows[1])  # a fixture row under the Chief
    tx, ty, tw, th = box(tiles[0])
    press = (rx + 150, ry + rh / 2)
    grid = (tx + tw * 1.5, ty + th / 2)          # the slot right of the pinned tile
    lower = (rx + 150, box(rows[-1])[1] + rh / 2)  # down the list
    legs = [(press, grid, 0.7), (grid, grid, 0.35), (grid, lower, 0.8), (lower, lower, 0.35), (lower, grid, 0.7), (grid, grid, 0.3)]
    path = []
    for (a, b, seconds) in legs:
        n = max(1, int(seconds * opts.hz))
        for k in range(1, n + 1):
            t = k / n
            e = t * t * (3 - 2 * t)
            path.append((a[0] + (b[0] - a[0]) * e, a[1] + (b[1] - a[1]) * e))
    json.dump({"press": press, "grid": grid, "lower": lower, "items": items, "steps": len(path)},
              open(os.path.join(opts.out, "drag.json"), "w"), indent=1)
    print("record", rpc("debug.window_record", {"dir": os.path.join(opts.out, "frames"), "seconds": 6}), flush=True)
    time.sleep(0.4)
    rpc("debug.mouse", {"x": press[0], "y": press[1], "action": "down"})
    t0 = time.monotonic()
    for k, (x, y) in enumerate(path):
        rpc("debug.mouse", {"x": x, "y": y, "action": "drag", "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
        delay = t0 + (k + 1) / opts.hz - time.monotonic()
        if delay > 0:
            time.sleep(delay)  # pointer pacing at --hz (the drag's own speed), not a settle wait
    rpc("debug.mouse", {"x": grid[0], "y": grid[1], "action": "up"})
    time.sleep(6)  # the 6 s recording ends on its own
    after = rpc("debug.home")
    pinned = (((after or {}).get("page") or {}).get("sidebar") or {}).get("pinned")
    print("pinned after the drop:", pinned, flush=True)
    frames = [n for n in os.listdir(os.path.join(opts.out, "frames")) if n.endswith(".jpg")] if os.path.isdir(os.path.join(opts.out, "frames")) else []
    print("frames:", len(frames), flush=True)
    code = 0 if frames else 1
finally:
    if STOP:
        subprocess.run(["/bin/sh", "-c", STOP], check=False)
sys.exit(code)
