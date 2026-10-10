#!/usr/bin/env python3
"""Layout loop and pane ring stress on a tagged cmux DEV (behavior proof).

Launches the tagged app (no activation, bounded window, isolated config),
then over its debug socket: opens a browser split (Chromium pages move the
overlay plane into the overlay panel), makes 20 splits and columns, toggles
the sidebar (moves the layout root without a layout of the root) and steps
the window size 50 times. After every step it reads `debug.layers` and
fails when:

- one view was laid out more than LayoutPassGuard.bound times in one
  run-loop turn (`layout_passes.max_in_one_turn`), or the guard caught a loop;
- a plane is out of sync with its home (`planes[].in_sync`: the plane's
  frame vs the root's rect in window coordinates; this is the ring offset
  an ancestor move caused), a ring is off its rounded content rect, or the
  window counted ring lag passes;
- no step ran with a plane in the overlay panel, or an action failed.

The app crashing (AppKit layout-pass exception) fails the run too.

Usage: layout-loop-stress-live.py TAG APP OUT_DIR
Exit 0 = all steps clean. Writes OUT_DIR/layout-loop-stress.json.
"""
import json, os, pwd, signal, socket, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
ACCOUNT_HOME = pwd.getpwuid(os.getuid()).pw_dir
ACPMUX_HOME = os.path.join(ACCOUNT_HOME, ".cmux/chief/isolated", TAG, "acpmux")
RESIZE_STEPS = 50
SPLITS = 20
os.makedirs(OUT, exist_ok=True)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def check(step, app, results):
    """Reads debug.layers after a step; returns a list of failures."""
    if app.poll() is not None:
        return ["app exited %s during %s" % (app.returncode, step)]
    layers = rpc("debug.layers") or {}
    if "error" in layers:
        return ["debug.layers failed after %s: %s" % (step, layers["error"])]
    failures = []
    passes = layers.get("layout_passes") or {}
    if not passes.get("installed"):
        failures.append("LayoutPassGuard not installed")
    bound = passes.get("bound", 16)
    worst = passes.get("max_in_one_turn", 0)
    if worst > bound:
        failures.append("%s: a view was laid out %s times in one turn (bound %s)" % (step, worst, bound))
    for loop in passes.get("loops") or []:
        failures.append("%s: layout loop in %s (%s)" % (step, loop.get("view_class"), " < ".join(loop.get("ancestry") or [])))
    rings = 0
    for window in layers.get("windows") or []:
        if (window.get("ring_lag_passes") or 0) > 0:
            failures.append("%s: ring lag passes %s (%s)" % (step, window.get("ring_lag_passes"), window.get("last_ring_lag")))
        for plane in window.get("planes") or []:
            if not plane.get("in_sync"):
                failures.append("%s: plane (%s) out of sync with its home" % (step, plane.get("host")))
            for ring in plane.get("rings") or []:
                rings += 1
                if not ring.get("ring_in_sync"):
                    failures.append("%s: pane %s ring %s != content %s (plane in %s)" % (
                        step, ring.get("pane"), ring.get("ring_in_window"), ring.get("content_in_window"), plane.get("host")))
    results.append({"step": step, "max_in_one_turn": worst, "rings": rings, "failures": failures,
                    "placement": [p.get("host") for w in layers.get("windows") or [] for p in w.get("planes") or []]})
    return failures


def quit_end_sessions():
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        reply = rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    return reply


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="layout-loop-stress-")
open(os.path.join(scratch, "cmux.json"), "w").write("{}")
open(os.path.join(scratch, "ghostty"), "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
       "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
print("launched pid %d" % app.pid, flush=True)
results, failures = [], []
try:
    deadline = time.time() + 180
    wins = None
    while time.time() < deadline and app.poll() is None:
        if os.path.exists(SOCKET):
            wins = (rpc("debug.windows") or {}).get("windows")
            if wins:
                break
        time.sleep(0.5)  # launch wait only (no runtime sync)
    if not wins:
        failures.append("no window within 180 s")
    else:
        rpc("debug.layers", {"reset_layout_passes": True})
        failures += check("launch", app, results)
        steps = [("splitBrowserRight", "action")] + [
            (("newColumn" if i % 3 == 0 else "splitRight" if i % 3 == 1 else "splitDown"), "action") for i in range(SPLITS)]
        steps.insert(8, ("toggleSidebar", "action"))
        steps.insert(15, ("toggleSidebar", "action"))
        for name, _ in steps:
            reply = rpc("action.run", {"id": name})
            if isinstance(reply, dict) and reply.get("error"):
                failures.append("action %s failed: %s" % (name, json.dumps(reply)[:200]))
            failures += check("action %s -> %s" % (name, json.dumps(reply)[:80]), app, results)
            if app.poll() is not None:
                break
        frame = rpc("debug.window_frame", {}) or {}
        base = frame.get("frame") or [40, 40, 1400, 900]
        x, y, w, h = [float(v) for v in (base if isinstance(base, list) else [40, 40, 1400, 900])]
        for i in range(RESIZE_STEPS):
            if app.poll() is not None:
                break
            dw = (i % 10) * 37 - 160
            dh = ((i * 7) % 10) * 23 - 100
            target = [x, y, max(700, w + dw), max(500, h + dh)]
            rpc("debug.window_frame", {"frame": target})
            failures += check("resize %d %s" % (i, target), app, results)
            if i == 25:
                rpc("action.run", {"id": "toggleSidebar"})
                failures += check("toggleSidebar mid-resize", app, results)
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "after-stress.png")}, timeout=60)
finally:
    print("quit:", json.dumps(quit_end_sessions())[:200], flush=True)
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([ACPMUX, "daemon", "shutdown"], env={**os.environ, "ACPMUX_HOME": ACPMUX_HOME,
                   "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}, capture_output=True, timeout=30)
    subprocess.run([CLI, "server", "stop", "--session", "cmux-app-%s" % TAG, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)

# The browser split must have moved a plane into the overlay panel (the
# path the deferral and the ancestor-move resync change); a run that never
# left the root proves nothing about it.
if results and not any("overlay_panel" in r["placement"] for r in results):
    failures.append("no step ran with the plane in the overlay panel (browser page window never showed)")
summary = {"tag": TAG, "steps": len(results), "failures": failures,
           "max_in_one_turn": max([r["max_in_one_turn"] for r in results] or [0]),
           "rings_checked": sum(r["rings"] for r in results), "results": results}
json.dump(summary, open(os.path.join(OUT, "layout-loop-stress.json"), "w"), indent=1)
print("steps=%d rings_checked=%d max_in_one_turn=%d failures=%d" % (
    summary["steps"], summary["rings_checked"], summary["max_in_one_turn"], len(failures)), flush=True)
for f in failures[:40]:
    print("FAIL " + f, flush=True)
sys.exit(0 if not failures and results else 1)
