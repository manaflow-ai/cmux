#!/usr/bin/env python3
"""Real-pointer check: a parked terminal tab (kept in its pane, out of sight) takes no pointer input.

  nx-remote --needs input --input-reason "parked hover" --app-from-fleet cmux --tag TAG --ref SHA -- \\
    'python3 scripts/cmux-next/parked-terminal-pointer-real.py --tag TAG --app "$NX_APP"'

Input host only (real mouse-moved, press, drag and release events through `pointer-probe.swift`, the
copy key through cua-driver). A pane holds two terminal tabs, A and B; each prints its own marker on
its first row. B opens last, so its parked view stays above A's in the pane (a switch moves no view,
cx-8w027.19). With A shown and B parked above it, then with B shown and A parked:

  1. the real pointer over the shown terminal shows the I-beam, also right after the switch with a
     still pointer;
  2. a real drag over the first row selects the shown terminal's text: the copied text holds its
     marker and not the parked terminal's;
  3. the app answers after every step.

Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="parked-pointer-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
MARKERS = {"A": "PARKA-aaaa-line", "B": "PARKB-bbbb-line"}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's or the window server's state
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    return None


def action(name, args=None):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"})


PROBE = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
subprocess.run(["xcrun", "swiftc", "-O", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pointer-probe.swift"),
                "-o", PROBE], check=True)


def probe(*args):
    return subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=20).stdout.strip()


def cua(tool, params):
    try:
        out = subprocess.run([opts.cua, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


SCREEN_H = float(probe("screen"))


def alive():
    return "error" not in (rpc("debug.focus") or {"error": 1})


def main_window():
    for entry in (rpc("debug.window_list") or {}).get("windows") or []:
        if entry.get("kind") == "main" and entry.get("visible"):
            return entry
    return None


def to_screen(point):
    """A window point from the top left to a screen point from the top left."""
    f = (main_window() or {}).get("frame") or {}
    return (f.get("x", 0) + point[0], SCREEN_H - (f.get("y", 0) + f.get("height", 0)) + point[1])


def activate():
    if not (rpc("debug.focus") or {}).get("app_active"):
        cua("bring_to_front", {"pid": app.pid})
        quiet_wait(lambda: (rpc("debug.focus") or {}).get("app_active"), 3)


def real_move(x, y):
    try:
        x0, y0 = map(float, probe("where").split())
    except ValueError:
        x0, y0 = x, y
    probe("path", x0, y0, x, y, 8)


def shown_terminal():
    """The focused pane's row (debug.surfaces) while it shows a terminal with a grid, and its text."""
    rows = [pane for win in (rpc("debug.surfaces", {"text": True}) or {}).get("windows") or [] for pane in win.get("panes") or []
            if pane.get("grid")]
    return next((pane for pane in rows if pane.get("focused")), rows[0] if len(rows) == 1 else None)


def cell(grid, column, row):
    return (grid["origin_x"] + (column + 0.5) * grid["cell_width"], grid["origin_y"] + (row + 0.5) * grid["cell_height"])


def marker_row(pane, marker):
    lines = (pane.get("text") or "").split("\n")
    return next((i for i, line in enumerate(lines) if line.startswith(marker)), None)


def pasteboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=10).stdout


def checks(shown, parked):
    pane = quiet_wait(lambda: (lambda p: p if p and marker_row(p, MARKERS[shown]) is not None else None)(shown_terminal()), 15)
    if not check(pane is not None, f"{shown} shown: its terminal shows its marker on a row of its own"):
        return
    grid, row = pane["grid"], marker_row(pane, MARKERS[shown])
    middle = cell(grid, 6, row + 3)
    x, y = to_screen(middle)
    got = quiet_wait(lambda: probe("cursor") == "iBeam", 2) or probe("cursor")
    check(got is True or got == "iBeam", f"{shown} shown, still pointer after the switch: I-beam (screen shows {got})")
    real_move(x - 3, y)
    real_move(x, y)
    got = quiet_wait(lambda: probe("cursor") == "iBeam", 2) or probe("cursor")
    check(got is True or got == "iBeam", f"{shown} shown, pointer moved over it: I-beam (screen shows {got}; window at the point: "
                                         f"{probe('owner', x, y)})")
    start, end = to_screen(cell(grid, 0, row)), to_screen(cell(grid, len(MARKERS[shown]) - 1, row))
    subprocess.run(["pbcopy"], input="", text=True, timeout=10)
    activate()
    real_move(*start)
    probe("drag", start[0], start[1], end[0], end[1], 30)
    reply = cua("hotkey", {"pid": app.pid, "keys": ["cmd", "c"]})
    copied = quiet_wait(lambda: pasteboard() or None, 3) or ""
    print(f"   {shown}: copy key {str(reply)[:120]}; copied {copied[:80]!r}", flush=True)
    check(MARKERS[shown] in copied and MARKERS[parked] not in copied,
          f"{shown} shown, {parked} parked over it: a real drag selects the shown terminal's text")
    real_move(*to_screen(middle))
    check(alive(), f"{shown} shown: the app answers after the pointer checks")


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"parked-pointer-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,680"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}, screen height {SCREEN_H}", flush=True)
try:
    quiet_wait(lambda: os.path.exists(SOCKET) and alive(), 180)
    if not (rpc("debug.focus") or {}).get("windows"):
        action("newWindow")
    window = ((quiet_wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60) or [{}])[0]).get("id")
    rpc("debug.window_frame", {"window": window, "frame": [40, 40, 1100, 680]})
    activate()
    quiet_wait(lambda: (rpc("debug.surfaces") or {}).get("windows"), 60)
    action("newTab")  # tab A: a terminal, whatever the first launch shows
    first = quiet_wait(lambda: shown_terminal(), 60)
    if not check(first is not None, "the first terminal shows"):
        print("debug.surfaces:", json.dumps(rpc("debug.surfaces"))[:3000], flush=True)
        raise RuntimeError("no terminal")
    print("pane row keys:", sorted(first.keys()), flush=True)
    action("terminal.sendText", {"text": f"clear; printf '{MARKERS['A']}\\n'\r"})
    quiet_wait(lambda: marker_row(shown_terminal() or {}, MARKERS["A"]) is not None, 15)
    action("newTab")
    quiet_wait(lambda: (lambda p: p and marker_row(p, MARKERS["A"]) is None and p)(shown_terminal()), 30)
    action("terminal.sendText", {"text": f"clear; printf '{MARKERS['B']}\\n'\r"})
    quiet_wait(lambda: marker_row(shown_terminal() or {}, MARKERS["B"]) is not None, 15)
    pane_b = shown_terminal() or {}
    if pane_b.get("grid"):  # the still-pointer check after the switch: the pointer rests over the pane
        real_move(*to_screen(cell(pane_b["grid"], 6, 3)))
    action("prevSurface")  # back to A (tabs: the launch's, A, B); B, opened last, stays parked above A
    checks("A", "B")
    action("nextSurface")
    checks("B", "A")
except RuntimeError as error:
    check(False, f"stopped: {error}")
finally:
    action("quitEndSessions")
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
