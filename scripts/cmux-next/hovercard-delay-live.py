#!/usr/bin/env python3
"""Live check: hover cards of sidebar workspace rows and tabs wait Chrome's delay, switch at once
while warm, and can be turned off (cx-23e1f, Lawrence 2026-10-14: "dont show the card on hover for
workspaces/tabs until XYZ seconds (see how long google chrome takes for this) make sure user can
just turn it off as well").

  nx-remote --needs input --input-reason "real pointer moves over sidebar rows and tabs" \\
    --app-from-fleet cmux --tag TAG --ref SHA -- \\
    'python3 scripts/cmux-next/hovercard-delay-live.py --tag TAG --app "$NX_APP" --input real'

It launches the tagged app itself (scratch cmux.json, its own window) and ends it and its daemons
after. `--input real` moves the real pointer with posted mouse-moved events and drags with a real
press (`pointer-probe.swift`; needs the input host's Accessibility grant). `--input synthetic`
moves a synthetic pointer through the windows' tracking areas (`debug.pointer_hover`) and skips
the mouse-button check. The state is read from `debug.hover_cards`. Checks, for a workspace row
and for a tab:

  1. the default delay is 250 ms (HoverCardTiming.showDelay): no card at 0.11 s, the card at 0.21-1.75 s;
  2. warm: with a card shown, the next row's (tab's) card shows at once (under 0.35 s);
  3. leaving a row before the delay cancels its card;
  4. quick return: a hover just after the card went shows at once;
  5. a held mouse button (a terminal selection dragged onto a row) shows no card (real input only);
  6. `sidebar.hoverCards.delay` 1000 holds the card until about 1 s;
  7. `sidebar.hoverCards.enabled` false: no card after 2.5 s, and a shown card goes at once.

With $NX_CAPTURE and --shots it writes PNGs of the window with the card and without it.
Exits 1 when a check fails.
"""
DEFAULT_DELAY_MS = 250  # HoverCardTiming.showDelay
OTHER_DELAY_MS = 1000

import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True, help="the tagged .app ($NX_APP)")
parser.add_argument("--input", choices=("real", "synthetic"), default="real")
parser.add_argument("--shots", default=os.environ.get("NX_ARTIFACTS"), help="write window captures here")
parser.add_argument("--capture", default=os.environ.get("NX_CAPTURE"), help="the host capture script ($NX_CAPTURE)")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
HERE = os.path.dirname(os.path.abspath(__file__))
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
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
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": {"code": "socket", "message": str(error)}}


def rpc(method, params=None):
    reply = call(method, params)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait on the app's state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def cards():
    reply = rpc("debug.hover_cards") or {}
    return reply if isinstance(reply, dict) else {}


def showing():
    """The shown card's target id, or None."""
    report = cards()
    return report.get("shown_target") if report.get("card_showing") == "true" and report.get("shown_target") not in (None, "-") else None


def main_window():
    for entry in (rpc("debug.window_list") or {}).get("windows") or []:
        if entry.get("kind") == "main" and entry.get("visible"):
            return entry
    return None


# --- pointer ------------------------------------------------------------------------------------
PROBE = None
SCREEN_H = 0.0
if opts.input == "real":
    PROBE = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
    subprocess.run(["xcrun", "swiftc", "-O", os.path.join(HERE, "pointer-probe.swift"), "-o", PROBE], check=True)


def probe(*args, timeout=20):
    return subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=timeout).stdout.strip()


def to_screen(point):
    """A window point from the top left to a screen point from the top left."""
    f = (main_window() or {}).get("frame") or {}
    return (f.get("x", 0) + point[0], SCREEN_H - (f.get("y", 0) + f.get("height", 0)) + point[1])


def move(point):
    """Moves the pointer to `point` (window, top left); None: off every target (the window's
    content far from the sidebar and the tab strips' tabs)."""
    target = point or OFF
    if opts.input == "synthetic":
        height = ((main_window() or {}).get("frame") or {}).get("height", 0)
        rpc("debug.pointer_hover", {"point": [target[0], height - target[1]]})
        return
    x, y = to_screen(target)
    try:
        x0, y0 = map(float, probe("where").split())
    except ValueError:
        x0, y0 = x - 3, y
    probe("path", x0, y0, x, y, 6)


CUA = os.path.expanduser("~/.local/bin/cua-driver")


def app_active():
    return bool((rpc("debug.focus") or {}).get("app_active"))


def activate():
    """Cards show only while the app is active, and real input reaches its window only while it
    is in front: bring it to the front (cua-driver, by pid; the input job has the session alone)."""
    if app_active():
        return
    subprocess.run([CUA, "call", "bring_to_front", json.dumps({"pid": APP_PID})], capture_output=True, text=True, timeout=60)
    quiet_wait(app_active, 3)


def shot(name):
    if not (opts.shots and opts.capture and APP_PID):
        return
    out = os.path.join(opts.shots, f"hovercard-delay-{opts.input}-{name}.png")
    run = subprocess.run(["bash", opts.capture, "shot", "--pid", str(APP_PID), "--with-popups", "--out", out],
                         capture_output=True, text=True, timeout=60)
    print(f"   capture {name}: exit {run.returncode} {out}", flush=True)


# --- targets ------------------------------------------------------------------------------------
def xywh(f):
    """A frame as [x, y, w, h]: debug.sidebar_rows gives objects, debug.tab_drag arrays."""
    return [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)


def row_points():
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    points = []
    for row in rows:
        if not str(row.get("key", "")).startswith("workspace") or not row.get("in_list"):
            continue
        f = xywh(row["window_frame"])
        points.append((row.get("title") or row["key"], [f[0] + f[2] / 2, f[1] + f[3] / 2]))
    return points


def tab_points():
    strips = (rpc("debug.tab_drag") or {}).get("strips") or []
    for strip in strips:
        tabs = strip.get("tabs") or []
        # A New Tab page has no card (it would repeat its title): terminal tabs only.
        tabs = [t for t in tabs if t.get("label") != "New Tab"]
        if len(tabs) >= 2:
            return [(t.get("label"), (lambda f: [f[0] + f[2] * 0.35, f[1] + f[3] / 2])(xywh(t["frame"]))) for t in tabs]
    return []


def settle():
    """Off every target until no card is pending or shown and the quick-reshow window passed."""
    activate()
    move(None)
    quiet_wait(lambda: cards().get("phase") == "idle", 3)
    time.sleep(0.4)


def cold(kind, point, delay_ms):
    settle()
    start = time.monotonic()
    move(point)
    early = 0.45 * delay_ms / 1000
    time.sleep(max(0.0, early - (time.monotonic() - start)))
    before = showing()
    report = cards()
    check(before is None, f"{kind}: no card {early:.2f} s after the hover (phase {report.get('phase', '')[:60]})")
    shown = quiet_wait(showing, delay_ms / 1000 + 1.5, step=0.02)
    took = time.monotonic() - start
    check(bool(shown) and took >= delay_ms / 1000 * 0.85,
          f"{kind}: the card shows after {took:.2f} s (delay {delay_ms} ms; target {shown})")
    return shown


def warm(kind, point, previous):
    start = time.monotonic()
    move(point)
    shown = quiet_wait(lambda: (lambda s: s if s and s != previous else None)(showing()), 1.0, step=0.02)
    took = time.monotonic() - start
    check(bool(shown) and took < 0.35, f"{kind}: warm switch shows the next card at once ({took:.2f} s, {previous} -> {shown})")
    return shown


def cancel(kind, point, delay_ms):
    settle()
    move(point)
    time.sleep(0.27 * delay_ms / 1000)
    move(None)
    seen = quiet_wait(showing, delay_ms / 1000 + 0.8, step=0.05)
    check(seen is None, f"{kind}: leaving before the delay cancels the card (shown: {seen})")


def quick_return(kind, first, second, delay_ms, away):
    shown = cold(kind + " quick return", first, delay_ms)
    if not shown:
        return
    # The card lingers 200 ms after the pointer leaves (cardGrace), then hides; for 300 ms after
    # that (HoverCardTiming.reshowWindow 500 ms) a new hover shows at once. `away` leaves away
    # from the card (a path toward the card would hold it: the safe triangle). Return as soon as
    # the card has gone.
    move(away)
    phase = quiet_wait(lambda: (lambda p: p if p.startswith("grace") else None)(cards().get("phase", "")), 1.0, step=0.01) \
        or cards().get("phase", "")
    start = time.monotonic()
    move(second)
    back = quiet_wait(showing, 1.0, step=0.02)
    took = time.monotonic() - start
    check(phase.startswith("grace") and bool(back) and took < 0.35,
          f"{kind}: a hover just after the card went shows at once ({took:.2f} s; phase before {phase[:24]}, shown {back})")


def held_button(row_point):
    """A real press in the terminal (a text selection, not a row drag), held while the pointer
    moves onto a workspace row and slowly across it for longer than the delay: no card."""
    if opts.input != "real":
        print("skip held mouse button (synthetic input)", flush=True)
        return
    settle()
    left = 4.0
    rows_frame = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    for row in rows_frame:
        if str(row.get("key", "")).startswith("workspace"):
            left = xywh(row["window_frame"])[0] + 4
            break
    (x0, y0), (x1, y1) = to_screen([OFF[0], row_point[1]]), to_screen([left, row_point[1]])
    # 900 drag events at ~120 Hz (about 7.5 s); the pointer is over the row for about 2 s of it.
    drag = subprocess.Popen([PROBE, "drag", str(x0), str(y0), str(x1), str(y1), "900"], stdout=subprocess.DEVNULL)
    seen = None
    while drag.poll() is None:  # bounded by the probe's own drag
        seen = seen or showing()
        time.sleep(0.05)
    check(seen is None, f"rows: no card while a mouse button is held over a row for ~2 s (shown: {seen})")


def set_setting(path, value):
    reply = call("settings.set", {"path": path, "value": value})
    ok = reply.get("ok")
    print(f"   settings.set {path} = {json.dumps(value)}: {'ok' if ok else reply.get('error')}", flush=True)
    return ok


# --- run ----------------------------------------------------------------------------------------
APP = opts.app.rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"hovercard-delay-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
log_dir = opts.shots or SCRATCH
os.makedirs(log_dir, exist_ok=True)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
    stdout=open(os.path.join(log_dir, f"hovercard-delay-{opts.input}-app.log"), "w"), stderr=subprocess.STDOUT,
    stdin=subprocess.DEVNULL)
APP_PID = app.pid
OFF = [700, 500]
try:
    if PROBE:
        SCREEN_H = float(probe("screen"))
    quiet_wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180, step=0.2)
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    window = ((quiet_wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60, step=0.2) or [{}])[0]).get("id")
    rpc("debug.window_frame", {"window": window, "frame": [40, 40, 1100, 700]})
    activate()
    print(f"app pid {APP_PID}, input {opts.input}, window {window}: {(main_window() or {}).get('frame')}, active {app_active()}",
          flush=True)
    # Two workspaces and two tabs in the selected one.
    for attempt in range(3):
        if len(row_points()) >= 3:
            break
        run = subprocess.run([os.path.join(HERE, "..", "cmux-debug-cli.sh"), "--app-socket", SOCKET, "workspace", "create",
                              "--name", f"hover-{attempt + 2}", "--json"], env=dict(os.environ, CMUX_TAG=opts.tag),
                             capture_output=True, text=True, timeout=60)
        print(f"   cmux workspace create: exit {run.returncode} {(run.stdout + run.stderr).strip()[-160:]}", flush=True)
        quiet_wait(lambda: len(row_points()) >= attempt + 2, 10, step=0.2)
    for attempt in range(3):
        if len(tab_points()) >= 2:
            break
        print("   newSurface:", (rpc("action.run", {"action": "newSurface", "origin": "script"}) or {}), flush=True)
        quiet_wait(lambda: len(tab_points()) >= 2, 10, step=0.2)
    rows, tabs = row_points(), tab_points()
    print(f"rows {rows}\ntabs {tabs}", flush=True)
    check(len(rows) >= 2, f"two workspace rows to hover ({len(rows)})")
    check(len(tabs) >= 2, f"two tabs to hover ({len(tabs)})")
    report = cards()
    check(report.get("enabled") == "true" and report.get("delay_ms") == str(DEFAULT_DELAY_MS),
          f"defaults: hover cards on, delay {DEFAULT_DELAY_MS} ms (enabled {report.get('enabled')}, delay {report.get('delay_ms')})")

    for kind in ("rows", "tabs"):
        # Fresh frames: tabs settle their widths a moment after they are added.
        points = row_points() if kind == "rows" else tab_points()
        print(f"{kind} now {points}", flush=True)
        if len(points) < 2:
            continue
        first = cold(kind, points[0][1], DEFAULT_DELAY_MS)
        if kind == "rows":
            shot("row-card")
        else:
            shot("tab-card")
        warm(kind, points[1][1], first)
        points = row_points() if kind == "rows" else tab_points()
        cancel(kind, points[0][1], DEFAULT_DELAY_MS)
        # Away from the card (it opens right of a row and below a tab): up and left, to the
        # titlebar over the sidebar, which is no row and no tab.
        away = [60, 8]
        quick_return(kind, points[0][1], points[1][1], DEFAULT_DELAY_MS, away)

    if rows:
        set_setting("sidebar.hoverCards.delay", OTHER_DELAY_MS)
        quiet_wait(lambda: cards().get("delay_ms") == str(OTHER_DELAY_MS), 5)
        cold(f"rows (delay {OTHER_DELAY_MS})", rows[0][1], OTHER_DELAY_MS)
        set_setting("sidebar.hoverCards.delay", DEFAULT_DELAY_MS)
        quiet_wait(lambda: cards().get("delay_ms") == str(DEFAULT_DELAY_MS), 5)

        # A shown card goes at once when cards are turned off.
        shown = cold("rows (before off)", rows[0][1], DEFAULT_DELAY_MS)
        set_setting("sidebar.hoverCards.enabled", False)
        gone = quiet_wait(lambda: showing() is None, 1.0, step=0.02)
        check(bool(shown) and bool(gone), "off: the shown card goes within 1 s of the settings write (file write + reload)")
        for kind, points in (("rows", rows), ("tabs", tabs)):
            if not points:
                continue
            settle()
            move(points[0][1])
            seen = quiet_wait(showing, 2.5, step=0.05)
            check(seen is None, f"{kind} off: no card after 2.5 s on a {kind[:-1]} (shown: {seen}; enabled {cards().get('enabled')})")
        shot("off-no-card")
        set_setting("sidebar.hoverCards.enabled", True)
        cold("rows (on again)", rows[0][1], DEFAULT_DELAY_MS)
        # Last: a held press, then the press ends (a click elsewhere) and cards work again.
        held_button(rows[0][1])
        if opts.input == "real":
            x, y = to_screen(OFF)
            probe("click", x, y)
            cold("rows (after the held press ends)", rows[0][1], DEFAULT_DELAY_MS)
    move(None)
finally:
    rpc("action.run", {"action": "quitEndSessions", "origin": "script"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
