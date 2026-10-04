#!/usr/bin/env python3
"""Live check of the sidebar in-place reorder (R77, nxdog30) on a no-activate tagged build.

Names three workspaces Alpha, Beta, Gamma, drags Gamma onto Alpha through
`debug.mouse` (held open), snapshots the window during the hold, drops, prints
the owning daemon's order and the personal placements, relaunches the app and
snapshots again. Run on cmux-lawrence-2, never the laptop.

Usage: sidebar-reorder-e2e.py --tag <tag> [--out DIR]
"""
import argparse, glob, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--app", help="the tagged app (default: the tag's DerivedData build)")
parser.add_argument("--spaces", action="store_true", help="also record the R99 space slide and swipe")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/*.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix=f"reorder-{opts.tag}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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


SESSION = []


def find_session():
    """The tagged app's session socket (the CLI's default is the release app's)."""
    roots = glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-tui-*")) + glob.glob("/tmp/cmux-tui-*")
    socks = [p for root in roots for p in glob.glob(os.path.join(root, "*.sock"))]
    print("session sockets:", socks, flush=True)
    tagged = [p for p in socks if opts.tag in os.path.basename(p)]
    if tagged:
        SESSION[:] = ["--socket", tagged[0]]


def cli(*args):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    out = subprocess.run([CLI, *SESSION, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=env)
    return (out.stdout + out.stderr).strip()


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    sys.exit(f"FAIL {label}")


def shot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name + ".png")})
    report = rpc("debug.sidebar_rows") or {}
    for window in report.get("windows", []) if isinstance(report, dict) else []:
        print(f"{name}: selection={window.get('selection')} dragging={window.get('dragging')}", flush=True)
        for row in window.get("rows", []):
            if row.get("title"):
                print(f"  {row['title']}: frame.y={row['frame']['y']} view={row.get('view_frame') and row['view_frame']['y']} "
                      f"alpha={row.get('view_alpha')} in_list={row.get('in_list')} suppressed={row.get('suppressed')}", flush=True)


FRAME = [0]


def frames(prefix, seconds):
    """Snapshots as fast as the socket allows for `seconds` (a frame sequence:
    no Screen Recording permission is needed)."""
    end = time.time() + seconds
    while time.time() < end:
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "r99", f"{FRAME[0]:04d}-{prefix}.png")})
        FRAME[0] += 1


def record_spaces():
    os.makedirs(os.path.join(opts.out, "r99"), exist_ok=True)
    made = cli("--json", "workspace", "create", "--name", "Delta")
    delta = json.loads(made.splitlines()[-1]).get("value", {}).get("workspace_id") if made else None
    print("room:", cli("room", "create", "--name", "Work"), flush=True)
    print("pin:", cli("room", "Work", "pin", "--workspace", str(delta)), flush=True)
    time.sleep(1)  # test harness: let the rooms settle
    print("space.next:", cli("action", "run", "space.next"), flush=True)
    frames("next", 1.0)
    print("space.previous:", cli("action", "run", "space.previous"), flush=True)
    frames("previous", 1.0)
    # A two-finger swipe toward the next space, 1:1, then a flick release.
    rpc("debug.mouse", {"x": 100, "y": 260, "action": "scroll", "dx": -10, "phase": "began"})
    for _ in range(8):
        rpc("debug.mouse", {"x": 100, "y": 260, "action": "scroll", "dx": -18, "phase": "changed"})
        frames("swipe", 0.05)
    rpc("debug.mouse", {"x": 100, "y": 260, "action": "scroll", "dx": 0, "phase": "ended"})
    frames("release", 1.2)
    report = rpc("debug.sidebar_rows") or {}
    print("after the swipe:", [(r.get("title"), r["frame"]["y"]) for w in report.get("windows", []) for r in w.get("rows", []) if r.get("title")], flush=True)


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90)
    time.sleep(2)  # test harness: let the window settle
    print(f"launched pid {app.pid}", flush=True)
    return app


app = launch()
find_session()
try:
    raw = cli("--json", "workspace", "list")
    print("raw list:", raw[:800], flush=True)
    try:
        listed = json.loads(raw.splitlines()[-1]) if raw else {}
    except ValueError:
        listed = {}
    if not listed:
        print("plain list:", cli("workspace", "list")[:800], flush=True)
    print("workspaces before:", json.dumps(listed)[:600], flush=True)
    # A clean list: close every workspace but Home (state survives runs on one tag).
    for item in listed if isinstance(listed, list) else []:
        if (item.get("extra") or {}).get("kind") != "home":
            cli("workspace", item["id"], "close")
    time.sleep(1)  # test harness: let the closes land
    for name in ("Alpha", "Beta", "Gamma"):
        print(cli("workspace", "create", "--name", name), flush=True)
    time.sleep(2)  # test harness: let the rows appear
    shot("r77-0-start")
    rows = {r["title"]: r["window_frame"] for w in (rpc("debug.sidebar_rows") or {}).get("windows", []) for r in w["rows"] if r.get("title")}
    gamma, alpha = rows["Gamma"], rows["Alpha"]
    gx, gy = gamma["x"] + 40, gamma["y"] + gamma["height"] / 2
    ty = alpha["y"] + alpha["height"] / 2 + 2.5  # just below Alpha's middle, as nxdog30 held it
    rpc("debug.mouse", {"x": gx, "y": gy, "action": "drag", "to_x": gx, "to_y": ty, "steps": 12, "release": False})
    for delay, name in ((0.05, "r77-1-held-50ms"), (0.45, "r77-2-held-500ms"), (1.5, "r77-3-held-2s")):
        time.sleep(delay)  # test harness: snapshot points during the hold
        shot(name)
    rpc("debug.mouse", {"x": gx, "y": ty, "action": "up"})
    time.sleep(1.5)  # test harness: let the drop land
    shot("r77-4-dropped")
    print("daemon order after drop:", cli("workspace", "list"), flush=True)
    print("personal placements after drop:", cli("workspace", "placement", "list"), flush=True)
    if opts.spaces:
        record_spaces()
    app.terminate()
    app.wait(timeout=30)
    app = launch()
    shot("r77-5-relaunched")
    print("personal placements after relaunch:", cli("workspace", "placement", "list"), flush=True)
finally:
    if app and app.poll() is None:
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
