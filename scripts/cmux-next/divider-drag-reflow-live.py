#!/usr/bin/env python3
"""Divider drag reflow proof on the GUI host (perf cx-8w027.6/.8, Lawrence 2026-10-17:
everything in a drag is real time).

  divider-drag-reflow-live.py --tag <tag> [--app APP] --out DIR [--steps 40]

Launches the tagged app (no activation, automation socket, own config), splits a
terminal right, prints one long line (`seq -s. 900`) in a terminal, then
while `debug.window_record` records every display frame and `debug.frames`
records display-link intervals, drags the split divider left and right, one
`debug.mouse` event per 60 Hz frame. After each step it reads both terminals
from `debug.surfaces`: the columns each frame fits (`fit_grid`), the grid Ghostty's
last frame drew (`drawn_grid`: the reflow preview while the owner has not
announced the new grid, cx-8w027.13) and the owner's grid (`grid`). Pass: at
every step the drawn columns equal the fitted columns (0 steps of lag), with
samples drawn by the preview before the owner answered, the owner's grid changes
during the drag, after the drag all three agree, and no frame interval is over
--hitch-ms. Owner-grid samples more than --lag steps behind are reported
(`owner_lagged`, the PTY size a full-screen program sees), not failed: the text
does not wait for them. Writes frames/, samples.json and app.log to
DIR. Stops only the app it started (by its PID) and the tag's daemons
(tag_teardown).
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/divider-drag-reflow")
parser.add_argument("--steps", type=int, default=40)
parser.add_argument("--step-pt", type=float, default=6.0)
parser.add_argument("--lag", type=int, default=3, help="steps the owner's grid may trail the edge")
parser.add_argument("--hitch-ms", type=float, default=50.0)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"


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


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def layer():
    result = rpc("debug.layers")
    return ((result or {}).get("windows") or [{}])[0] if isinstance(result, dict) else {}


def vertical_dividers(window):
    """Vertical divider areas as (x_mid, y_mid from the top), left to right."""
    height = (window.get("frame") or [0, 0, 0, 720])[3]
    return sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in window.get("divider_areas_in_window") or [] if h > w)


def cols(value):
    """Columns of a "COLSxROWS" grid; None when the grid is missing (no frame drawn yet)."""
    if value is None:
        return None
    try:
        return int(str(value).split("x")[0])
    except ValueError:
        return None


def terminals():
    """Terminal panes left to right: (frame x, columns the view fits, owner's columns, drawn columns).
    `surface.grid` is the owner's grid the mirror is locked to; `fit_grid` what the view fits;
    `drawn_grid` what Ghostty's last frame drew (PaneController+Diagnostics)."""
    result = rpc("debug.surfaces") or {}
    rows = []
    for window in result.get("windows") or []:
        for pane in window.get("panes") or []:
            surface, grid = pane.get("surface") or {}, pane.get("grid") or {}
            if not surface.get("fit_grid"):
                continue
            rows.append((grid.get("frame_x", 0), cols(surface.get("fit_grid")), cols(surface.get("grid")),
                         cols(surface.get("drawn_grid"))))
    return sorted(rows)


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,760"}
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"pid": app.pid, "steps": [], "notes": []}
ok = False
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("app did not come up")
    report["new_workspace"] = rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: terminals(), 30)
    report["split"] = rpc("action.run", {"action": "splitRight", "focus": False})
    wait(lambda: len(terminals()) >= 2 and vertical_dividers(layer()), 30)
    # One long line in the left terminal (the focused one before the split).
    cli_env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    written = subprocess.run([CLI, "--app-socket", SOCKET, "--json", "terminal", "current", "write", "--text", "clear; seq -s. 900\r"],
                             capture_output=True, text=True, timeout=60, env=cli_env, stdin=subprocess.DEVNULL)
    report["write"] = {"exit": written.returncode, "out": written.stdout[-400:], "err": written.stderr[-400:]}
    time.sleep(1.0)
    dividers = vertical_dividers(layer())
    if not dividers:
        sys.exit("no vertical divider")
    x0, y0 = dividers[0]
    report["before"] = terminals()
    frames_dir = os.path.join(opts.out, "frames")
    path = [-opts.step_pt] * opts.steps + [opts.step_pt] * (2 * opts.steps) + [-opts.step_pt] * opts.steps

    def drag(sample):
        rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
        x = x0
        for delta in path:
            rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": x + delta, "to_y": y0, "steps": 1,
                                "press": False, "release": False})
            x += delta
            time.sleep(1 / 60)
            if sample:
                panes = terminals()
                report["steps"].append({"pointer_x": round(x, 1), "fit": [p[1] for p in panes], "grid": [p[2] for p in panes],
                                        "drawn": [p[3] for p in panes]})
        rpc("debug.mouse", {"action": "up", "x": x, "y": y0})
        time.sleep(0.8)

    # Baseline: display-link intervals of the idle window for 2 s.
    rpc("debug.frames", {"action": "start"})
    time.sleep(2)
    report["frames_idle"] = rpc("debug.frames", {"action": "stop"})
    # Pass A: frame intervals of the drag alone (no debug reads or recording between events).
    rpc("debug.frames", {"action": "start"})
    time.sleep(0.3)
    report["drag_started_ms"] = 300
    drag(sample=False)
    report["frames"] = rpc("debug.frames", {"action": "stop"})
    # Pass B, recorded frame by frame: the grid each terminal renders against what its frame fits.
    report["record"] = rpc("debug.window_record", {"dir": frames_dir, "seconds": 10})
    drag(sample=True)
    report["after"] = terminals()
    # Pass rule, per terminal: the drawn columns equal what its frame fits at the same step (the text
    # fits the pane on the same frame); the owner's grid equals a fit of that step or one of the --lag
    # steps before it (one grid in flight and its echo) and changes during the drag; after the drag
    # drawn, fit and owner grids agree.
    misses, lagged, distinct, previews, undrawn = [], [], [], [], []
    for pane in range(min(len(s["fit"]) for s in report["steps"])):
        fits = [s["fit"][pane] for s in report["steps"]]
        grids = [s["grid"][pane] for s in report["steps"]]
        drawn = [s["drawn"][pane] for s in report["steps"]]
        for i, (fit, shown) in enumerate(zip(fits, drawn)):
            if shown is None:
                undrawn.append({"pane": pane, "step": i})
            elif shown != fit:
                misses.append({"pane": pane, "step": i, "drawn": shown, "fit": fit, "grid": grids[i]})
        # Samples where the owner had not answered yet and the frame still fit: the preview drew them.
        previews.append(sum(1 for fit, grid, shown in zip(fits, grids, drawn) if grid != fit and shown == fit))
        for i, grid in enumerate(grids):
            # The grid sent can be a fit between two samples: within the range of the recent fits.
            recent = fits[max(0, i - opts.lag):i + 1]
            if grid is None or None in recent or not min(recent) <= grid <= max(recent):
                lagged.append({"pane": pane, "step": i, "grid": grid, "recent_fits": recent})
        distinct.append(len(set(grids)))
    settled = [p for p in report["after"] if not p[1] == p[2] == p[3]]
    report["misses"] = misses
    report["undrawn"] = undrawn
    report["preview_steps"] = previews
    report["owner_lagged"] = lagged
    report["unsettled_after"] = settled
    report["distinct_grids"] = distinct
    stats = report["frames"] or {}
    report["worst_frame_ms"] = stats.get("max_ms") or 0
    frames_ok = isinstance(stats, dict) and "error" not in stats and (stats.get("frames") or 0) > 0 \
        and report["worst_frame_ms"] <= opts.hitch_ms
    ok = bool(distinct) and not misses and not undrawn and not settled \
        and len(report["after"]) >= 2 and min(distinct) > 5 and min(previews) > 0 and frames_ok
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    teardown.end()
    with open(os.path.join(opts.out, "samples.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({k: report.get(k) for k in ("write", "before", "after", "misses", "undrawn", "preview_steps",
                                              "owner_lagged", "unsettled_after",
                                              "distinct_grids", "worst_frame_ms", "record", "notes")})[:3000])
print("frames idle:", json.dumps(report.get("frames_idle"))[:600])
print("frames drag:", json.dumps(report.get("frames"))[:600])
print("steps:", json.dumps(report["steps"][:4]), "...", json.dumps(report["steps"][-3:]))
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
