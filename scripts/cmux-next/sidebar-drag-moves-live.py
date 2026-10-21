#!/usr/bin/env python3
"""Live check that sidebar drags move workspaces, on a fleet-built tagged app.

Every drag goes through `debug.mouse` (press, held moves, release), never a
command: a workspace before another, after another, into a group, out of a
group, to the top and to the bottom of the list. Each step prints PASS/FAIL
with the list order (`debug.sidebar_rows`) and any refusal the drop showed
(`debug.toast` refusals; "The move did not finish" was the bug). Writes window
snapshots and app.log (the app's stdout and stderr) to --out. Exit 1 when a
step FAILs. Run it on cmux-lawrence-2, never the laptop:

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- 'python3 scripts/cmux-next/sidebar-drag-moves-live.py --out "$NX_ARTIFACTS"'
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--tab-rows", action="store_true", help="also show tabs under workspaces")
opts = parser.parse_args()
APP = os.environ.get("NX_APP")
TAG = os.environ.get("NX_APP_TAG", "")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
if not APP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP)")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"sidebar-drag-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    json.dump({"sidebar": {"showWorkspaceTabs": True}} if opts.tab_rows else {}, f)
os.makedirs(opts.out, exist_ok=True)
RESULTS = []


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


def cli(*args):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=env)
    return (out.stdout + out.stderr).strip()


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    return None


def window():
    value = rpc("debug.sidebar_rows") or {}
    return ((value if isinstance(value, dict) else {}).get("windows") or [{}])[0]


def listed():
    """(title, group) of each workspace row in list order."""
    return [(r["title"], r.get("group")) for r in window().get("rows", [])
            if r.get("title") and str(r.get("key", "")).startswith("workspace")]


def titles():
    return [t for t, _ in listed()]


def row(title):
    return next((r for r in window().get("rows", []) if r.get("title") == title and str(r.get("key", "")).startswith("workspace")), None)


def group_header():
    return next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("group")), None)


def refusals():
    return list((rpc("debug.toast") or {}).get("refusals") or [])


def shot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name + ".png")})


def record(step, ok, evidence):
    RESULTS.append((step, ok))
    print(f"{'PASS' if ok else 'FAIL'} {step}: {evidence}", flush=True)


def at(frame, fy):
    return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] * fy


def drag(frm, to, label):
    """One drag through debug.mouse; returns the refusals it raised."""
    before = refusals()
    rpc("debug.mouse", {"x": frm[0], "y": frm[1], "action": "drag", "to_x": to[0], "to_y": to[1], "steps": 20, "release": False})
    time.sleep(0.4)  # test harness: hold so the drop target settles
    shot(label + "-held")
    print(f"{label} held drop:", json.dumps(window().get("drop")), flush=True)
    rpc("debug.mouse", {"x": to[0], "y": to[1], "action": "up"})
    time.sleep(1.5)  # test harness: let the move land
    shot(label + "-dropped")
    return refusals()[len(before):]


def step(label, moving, target, fy, check):
    """Drags row `moving` to fraction `fy` of row `target`'s height (or a frame) and checks the order."""
    source = row(moving)
    frame = target if isinstance(target, dict) else (row(target) or {}).get("window_frame")
    if not source or not frame:
        return record(label, False, f"missing rows: moving={moving} target={target} list={listed()}")
    before = listed()
    raised = drag(at(source["window_frame"], 0.5), at(frame, fy), label)
    after = listed()
    record(label, check(after) and not raised, f"before={before} after={after} refusals={raised}")


app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,820",
    "ACPMUX_AGENT_LAUNCH": "deny"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
try:
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 180):
        sys.exit("FAIL the tagged app did not come up")
    time.sleep(2.0)  # test harness: let the window settle
    for name in ("Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot", "Golf"):
        print(cli("workspace", "create", "--name", name), flush=True)
    wait(lambda: {"Alpha", "Golf"} <= set(titles()), 30)
    print(cli("workspace", "group", "create", "--name", "Grp"), flush=True)
    for name in ("Echo", "Foxtrot"):
        print(cli("workspace", "group", "Grp", "add", "--workspace", name), flush=True)
    wait(lambda: group_header() and any(g for t, g in listed() if t == "Foxtrot"), 20)
    time.sleep(1.0)  # test harness: let the group show
    print("rows:", json.dumps(window().get("rows"))[:4000], flush=True)
    shot("0-start")

    def index(order, title):
        names = [t for t, _ in order]
        return names.index(title) if title in names else -1

    def group_of(order, title):
        return next((g for t, g in order if t == title), None)

    # A dragged row swaps by its edges (b334adfcf4d1): dragged up, it goes before a row once its top passes that
    # row's middle; dragged down, after a row once its bottom passes it. So "before" drags come from below and
    # "after" drags from above.
    ungrouped = [t for t, g in listed() if g is None]
    before_target, before_moving = ungrouped[1], ungrouped[-1]
    step(f"1 before a workspace: {before_moving} above {before_target}", before_moving, before_target, 0.3,
         lambda o: index(o, before_moving) == index(o, before_target) - 1)
    ungrouped = [t for t, g in listed() if g is None]
    after_moving, after_target = ungrouped[0], ungrouped[-2]
    step(f"2 after a workspace: {after_moving} below {after_target}", after_moving, after_target, 0.7,
         lambda o: index(o, after_moving) == index(o, after_target) + 1)
    header = group_header()
    joining = [t for t, g in listed() if g is None][0]
    step(f"3 into a group: {joining} onto the group header", joining, (header or {}).get("window_frame"), 0.5,
         lambda o: group_of(o, joining) is not None and group_of(o, joining) == group_of(o, "Foxtrot"))
    member = [t for t, g in listed() if g is not None][-1]
    first = titles()[0]
    step(f"4 out of a group and 5 to the top: {member} above {first}", member, first, 0.1,
         lambda o: group_of(o, member) is None and index(o, member) == 0)
    rows_now = [r for r in window().get("rows", []) if r.get("title") or str(r.get("key", "")).startswith("group")]
    last = max(rows_now, key=lambda r: r["window_frame"]["y"])["window_frame"]
    below = dict(last, y=last["y"] + last["height"] * 3)
    moving = [t for t, g in listed() if g is None][0]
    step(f"6 to the bottom: {moving} below every row", moving, below, 0.5, lambda o: index(o, moving) == len(o) - 1)
    shot("9-end")
finally:
    rpc("action.run", {"action": "quitEndSessions", "origin": "script"})  # also ends its daemons
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.terminate()

failed = [s for s, ok in RESULTS if not ok]
print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} PASS" + (f"; FAIL: {failed}" if failed else ""), flush=True)
sys.exit(1 if failed or not RESULTS else 0)
