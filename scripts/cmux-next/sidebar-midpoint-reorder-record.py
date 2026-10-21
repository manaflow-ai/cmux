#!/usr/bin/env python3
"""Records the sidebar's midpoint reorder (Lawrence 2026-10-20): a dragged row
goes above the row over it once its top edge passes that row's middle, and
below the row under it once its bottom edge passes that row's middle.

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \
    python3 scripts/cmux-next/sidebar-midpoint-reorder-record.py --out "$NX_ARTIFACTS/rec"

Launches the tagged app, makes five loose workspaces and a group of two, then
for each scenario starts `debug.window_record` (one JPEG per display frame) and
drags with `debug.mouse` events at --hz: the card moves --past points beyond
the neighbour's middle (well short of where its centre would pass it), holds,
and drops. Writes OUT/<scenario>/ (frames) and OUT/orders.json (the sidebar
order before and after each drop), and prints whether each drop reordered.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--hz", type=float, default=120)
parser.add_argument("--past", type=float, default=3, help="points the leading edge goes past the neighbour's middle")
opts = parser.parse_args()
APP, TAG, STOP = os.environ.get("NX_APP"), os.environ.get("NX_APP_TAG", ""), os.environ.get("NX_APP_STOP")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
if not APP or not STOP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP, NX_APP_STOP)")
SCRATCH = tempfile.mkdtemp(prefix=f"midpoint-rec-{TAG}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)


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


def cli(*args):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=60, env=env)
    return (out.stdout + out.stderr).strip()


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    return None


def listed():
    value = rpc("debug.sidebar_rows") or {}
    window = ((value.get("windows") if isinstance(value, dict) else None) or [{}])[0]
    return [r for r in window.get("rows", []) if r.get("title") and r.get("in_list") and r.get("window_frame")]


def order():
    return [r["title"] for r in listed()]


def row(title):
    return next(r for r in listed() if r["title"] == title)


def mouse(action, x, y):
    if action == "drag":
        rpc("debug.mouse", {"x": x, "y": y, "action": "drag", "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
    else:
        rpc("debug.mouse", {"x": x, "y": y, "action": action})


def drag(start, dy, seconds=0.9, hold=0.6):
    x, y = start
    mouse("down", x, y)
    steps = max(2, int(seconds * opts.hz))
    began = time.monotonic()
    for index in range(1, steps + 1):
        mouse("drag", x, y + dy * index / steps)
        delay = began + index / opts.hz - time.monotonic()
        if delay > 0:
            time.sleep(delay)  # test harness pacing: a person's 120 Hz pointer
    time.sleep(hold)  # test harness: the card held still at the end, as a person holds before letting go
    mouse("up", x, y + dy)


ORDERS = {}


def scenario(name, mover, neighbour, down):
    m, n = row(mover)["window_frame"], row(neighbour)["window_frame"]
    middle = n["y"] + n["height"] / 2
    dy = (middle + opts.past) - (m["y"] + m["height"]) if down else (middle - opts.past) - m["y"]
    before = order()
    folder = os.path.join(opts.out, name)
    rpc("debug.window_record", {"dir": folder, "seconds": 3.5})
    drag((m["x"] + m["width"] / 2, m["y"] + m["height"] / 2), dy)
    time.sleep(1.5)  # test harness: let the drop settle on screen
    after = order()
    moved = before.index(mover) != after.index(mover)
    ORDERS[name] = {"mover": mover, "neighbour": neighbour, "dy": dy, "before": before, "after": after, "reordered": moved}
    print(f"{name}: {mover} {'down' if down else 'up'} {dy:+.1f} pt past {neighbour}'s middle by {opts.past} pt -> "
          f"{'REORDERED' if moved else 'stayed'}; {before} -> {after}", flush=True)


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,900,620",
           "ACPMUX_AGENT_LAUNCH=deny", "NX_REMOTE=1"]
    subprocess.run(["open", "-n", APP, *[arg for pair in env for arg in ("--env", pair)]], check=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("FAIL the tagged app did not come up")
    time.sleep(1.5)  # test harness: let the window settle


launch()
try:
    for name in ("Alpha", "Beta", "Gamma", "Delta", "Echo", "Member One", "Member Two"):
        cli("workspace", "create", "--name", name)
    wait(lambda: {"Alpha", "Member Two"} <= set(order()), 20)
    cli("workspace", "group", "create", "--name", "Group")
    for name in ("Member One", "Member Two"):
        cli("workspace", "group", "Group", "add", "--workspace", name)
    time.sleep(1.0)  # test harness: let the group show
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "setup.png"), "webviews": False}, timeout=60)
    print("setup order:", order(), flush=True)
    loose = [t for t in order() if t in ("Alpha", "Beta", "Gamma", "Delta", "Echo")]
    scenario("1-up", loose[2], loose[1], down=False)
    loose = [t for t in order() if t in ("Alpha", "Beta", "Gamma", "Delta", "Echo")]
    scenario("2-down", loose[0], loose[1], down=True)
    members = [t for t in order() if t.startswith("Member")]
    if len(members) == 2:
        scenario("3-member-up", members[1], members[0], down=False)
finally:
    json.dump(ORDERS, open(os.path.join(opts.out, "orders.json"), "w"), indent=1)
    subprocess.run([STOP], check=False)
    stopper = os.path.expanduser("~/.local/bin/stop_tag_daemon.py")
    if os.path.exists(stopper):
        subprocess.run(["python3", stopper, "bundle", APP], check=False)
