#!/usr/bin/env python3
"""Tagged-app check: Home's rows follow a backing scale change, 2x -> 1x -> 2x (MessagesLab 82ccac1 snap-followup,
258b385 per-view render scale).

Launches the tagged app with no activation, opens the DEBUG Home fixture (the real transcript view over a
HomeStore over the mock owner) and sends a message, so outgoing and incoming rows show. Moves the transcript by
0.25 pt (half a device pixel at 2x) and reads the rows as drawn (`debug.home.drive {action: rows}`): each text
row's anchored side (incoming left, my rows right) and top on whole device pixels at 2x, and the snapshot's
balloon edges (home_pixels.check_rows, check_crisp). Then it makes a 1x virtual display (the rig's
~/messageslab-rig/bin/vdisplay --detach --owner, hidpi 0; it ends with this script, by its pid, or by itself after
240 s) and moves the window onto it (`debug.window_frame {screen: last}`): the window's backing scale changes to 1,
Home's host calls MessagesWindowView.setRenderScale (HostView.viewDidChangeBackingProperties ->
ChatController.followWindowScale), and the rows must snap again: read right after the move (no other move of the
transcript, so only setRenderScale can have re-snapped them), then again with the transcript on half a point (half
a device pixel at 1x): every text row's anchored side and top must be on whole points, and the incoming balloons'
straight edges crisp in the 1x snapshot. Back to 2x: the virtual display ends (its own pid), and the window goes
back to the 2x display (the rig cannot move it there by frame: with the virtual display attached, screen 0 is the
virtual display). Then the same reads at 2x, right after the return and with the transcript on half a device pixel.
At each scale, one display frame after the change: the view renders at the window's scale (`debug.home.drive
{action: geometry}`: renderScale, cells, compose bar, header) and no visible row shows a bitmap of the old scale. Both
directions use the same one-frame rule (hq-6d, 2026-10-14; the 0.5 s bound of the move to 1x is gone: with the
colour-space change keeping the bitmap cache, 258b385, no old-scale bitmap showed after one frame in 5 rounds).
Socket only, no system input. Runs on cmux-lawrence-2 (nx-remote --needs gui); ends with the DEBUG quit fixture,
endAgents, the tag's `acpmux daemon shutdown`, and the virtual display's own process (its pid, started here).

Usage: home-scale-change.py --tag <tag> --ml <MessagesLab source dir with tools/interactions/vdisplay.m> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from home_pixels import check_crisp, check_rows  # noqa: E402
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--ml", required=True)
parser.add_argument("--out", default="/tmp/home-scale-change")
opts = parser.parse_args()
home = os.environ["HOME"]
app = f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def api(**params):
    return rpc("debug.home.api", params)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:500]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait, not app code
    return None


def rows_on_grid(name, report, scale):
    """Every text row's anchored side (incoming left, outgoing right) and top on whole device pixels at `scale`."""
    wh = report.get("windowHeight", 0)
    rows = [r for r in report.get("rows") or [] if r["kind"] == "text" and r["y"] >= 64 and r["y"] + r["height"] <= wh - 90]
    off = []
    for r in rows:
        side = (r["x"] + r["width"] if r["outgoing"] else r["x"]) * scale
        top = (wh - r["y"] - r["height"]) * scale
        if abs(side - round(side)) > 0.01 or abs(top - round(top)) > 0.01:
            off.append({r["key"]: [round(side, 3), round(top, 3)], "out": r["outgoing"]})
    mine = sum(1 for r in rows if r["outgoing"])
    print(f"     {name}: {len(rows)} text rows ({mine} mine), off the grid {off}", flush=True)
    check(f"{name}: text rows to measure, mine among them", len(rows) >= 3 and mine >= 1, report.get("rows", [])[:6])
    check(f"{name}: every text row's anchored side and top are on whole device pixels at {scale:g}x", not off, off)


def rows_report():
    return rpc("debug.home.drive", {"action": "rows"}) or {}


def geometry():
    return (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("geometry") or {}


def scale_state(name, want):
    """One display frame after a scale change, in both directions (2x -> 1x and 1x -> 2x): the view renders at the
    window's scale and no visible row shows a bitmap of the old scale. On a failure, how long the old-scale bitmaps
    stayed (read every 20 ms, up to 2 s) is printed for the cause."""
    t0 = time.time()
    time.sleep(1 / 60)  # test harness: one display frame after the change
    g = geometry()
    print(f"     {name}: " + json.dumps({k: g.get(k) for k in ("windowScale", "renderScale", "rowBitmaps", "rowBitmapsOffScale",
                                                             "cellsOffScale", "composeScale", "headerScale", "bitmapPxPerPtMin",
                                                             "bitmapPxPerPtMax", "viewInactive", "windowKey", "appActive",
                                                             "lightAppearance", "colorSpaceIsScreen")}), flush=True)
    check(f"{name}: the window, the transcript view, its cells, compose bar and header are at {want:g}x",
          all(g.get(k) == want for k in ("windowScale", "renderScale", "composeScale", "headerScale")) and g.get("cellsOffScale") == 0, g)
    check(f"{name}: rows with a bitmap to read ({g.get('rowBitmaps')} row bitmaps)", g.get("rowBitmaps", 0) >= 3, g)
    if not check(f"{name}: no visible row shows a bitmap of the old scale", g.get("rowBitmapsOffScale") == 0, g):
        last = g
        while time.time() - t0 < 2 and last.get("rowBitmapsOffScale"):
            time.sleep(0.02)  # test harness: the next read
            last = geometry()
        print(f"     {name}: old-scale bitmaps " + (f"gone after {time.time() - t0:.3f} s" if not last.get("rowBitmapsOffScale")
                                                   else "still there after 2 s"), flush=True)


def snapshot_checks(name, file, report, full):
    """The window snapshot: crisp incoming balloon edges at any scale; at 2x also check_rows (every balloon edge where
    the app draws it)."""
    path = os.path.join(opts.out, file)
    rpc("debug.window_snapshot", {"path": path})
    if not os.path.exists(path):
        check(f"{name}: the window snapshot is written", False, path)
        return
    check_crisp(check, name, report, path)
    if full:
        check_rows(check, name, report, path)


vd = None
if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", **home_classic.ENV}
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
print(f"launched pid {pid}", flush=True)
try:
    # Classic Home or stop at once (cx-h0kds): these checks drive the native classic Home transcript.
    if not home_classic.require(rpc):
        sys.exit(2)
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    # A new fixture tab: a fixture tab restored from the gate's earlier script (same tag; the daemon keeps the pane's
    # tabs) shows no transcript. Up to 3 tries, 30 s each (the first open can come before the window settles).
    def texts():
        return (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")
    shown = None
    for _ in range(3):
        rpc("debug.home_native_fixture.open", {"new": True})
        shown = poll(texts, timeout=30)
        if shown:
            break
    if not check("the Home fixture opens and shows its transcript", bool(shown),
                 rpc("debug.home.drive", {"action": "texts"})):
        # Which windows and pages show (for the failure's cause).
        print("     windows: " + json.dumps(rpc("debug.window_list"))[:1500], flush=True)
        print("     home: " + json.dumps(rpc("debug.home"))[:800], flush=True)
    rpc("debug.home.drive", {"action": "focus"})
    rpc("debug.home.drive", {"action": "type", "text": "Scale change check"})
    sent = rpc("debug.home.drive", {"action": "send"}) or {}
    check("the send goes", bool(sent.get("ok")), sent)
    time.sleep(4.0)  # test harness: the mock Chief's typing and answer end (1.5 s + 1.5 s after the send)

    # 2x, the transcript on half a device pixel.
    rpc("debug.home.drive", {"action": "nudge", "dx": 0.25, "dy": 0.25})
    time.sleep(0.2)  # test harness: one display frame for the move to show
    r2 = rows_report()
    check("the window starts at 2x", r2.get("scale") == 2, {k: r2.get(k) for k in ("scale", "error")})
    if r2.get("scale") == 2:
        rows_on_grid("2x, half a pixel", r2, 2)
        scale_state("2x at the start", 2)
        snapshot_checks("2x, half a pixel", "scale-2x.png", rows_report(), full=True)

    # A 1x virtual display, and the window onto it: the rig's vdisplay (hq-34, ~/messageslab-rig/bin/vdisplay; a unique
    # serial per display, so a display another run leaked no longer blocks this one). `--detach` prints one line and
    # exits: `ready id=.. origin=X,Y size=WxH pixels=.. scale=.. hz=.. serial=N pid=N` or `failed reason=.. displays=..`.
    # `--owner` ends the display with this script; the display's pid= is stopped at the end too (exact pid).
    vdbin = os.path.expanduser("~/messageslab-rig/bin/vdisplay")
    vdlog = os.path.join(opts.out, "vdisplay.log")
    run = subprocess.run([vdbin, "1600", "1000", "60", "240", "0", "--detach", "--owner", str(os.getpid()), "--log", vdlog],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    line = (run.stdout.strip().splitlines() or [""])[-1]
    fields = dict(f.split("=", 1) for f in line.split()[1:] if "=" in f) if line.startswith("ready") else {}
    vd = int(fields["pid"]) if fields.get("pid", "").isdigit() else None
    if not check("a 1x virtual display exists", run.returncode == 0 and line.startswith("ready") and vd is not None,
                 line or (run.stderr or "")[-300:]):
        print(f"     vdisplay: {line or run.stderr.strip()[-300:]}", flush=True)
        sys.exit(1)
    print(f"     vdisplay: {line}", flush=True)
    moved = rpc("debug.window_frame", {"screen": "last"}) or {}
    check("the window moves onto the virtual display", moved.get("screen") == "MessagesLab Rig", moved)
    r1 = poll(lambda: (r := rows_report()) and r.get("scale") == 1 and r, timeout=10) or rows_report()
    check("the window's backing scale is 1 on the virtual display", r1.get("scale") == 1, {k: r1.get(k) for k in ("scale", "error")})
    if r1.get("scale") == 1:
        scale_state("1x, one frame after the change", 1)
    # Before any move of the transcript: only setRenderScale re-snaps the rows here (the transcript sits 0.25 pt off
    # the grid, a quarter pixel at 1x; rows still on the 2x snap would sit half a point off).
    time.sleep(0.3)  # test harness: display frames after the move
    r1 = rows_report()
    if r1.get("scale") == 1:
        rows_on_grid("1x right after the scale change (no other move)", r1, 1)
        snapshot_checks("1x right after the scale change", "scale-1x-change.png", r1, full=False)
    # Half a point is half a device pixel at 1x (the 0.25 pt move made it a quarter).
    rpc("debug.home.drive", {"action": "nudge", "dx": 0.25, "dy": 0.25})
    time.sleep(0.3)  # test harness: display frames for the move to show
    r1 = rows_report()
    check("1x: the transcript sits on half a device pixel", all(abs((r1.get(k, 0) % 1) - 0.5) < 0.01 for k in ("hostX", "hostY")),
          {k: r1.get(k) for k in ("hostX", "hostY")})
    if r1.get("scale") == 1:
        rows_on_grid("1x after the scale change, half a pixel", r1, 1)
        snapshot_checks("1x, half a pixel", "scale-1x.png", r1, full=False)

    # Back to 2x: the virtual display ends (its own pid) and the window goes back to the 2x display. (A move by frame
    # cannot: with the virtual display attached, NSScreen.screens[0] is the virtual display itself, and the frame from
    # before lies in its desktop area too; gate runs on 024e48d and e87fffa.)
    subprocess.run(["kill", str(vd)], capture_output=True)  # the virtual display this script started (its pid=)
    gone = poll(lambda: subprocess.run(["kill", "-0", str(vd)], capture_output=True).returncode != 0, timeout=15)
    vd = None if gone else vd
    check("the virtual display ends", bool(gone))
    rb = poll(lambda: (r := rows_report()) and r.get("scale") == 2 and r, timeout=15) or rows_report()
    check("the window's backing scale is 2 again (back on the 2x display)", rb.get("scale") == 2,
          {k: rb.get(k) for k in ("scale", "error")})
    if rb.get("scale") == 2:
        scale_state("2x, one frame after the return", 2)
        time.sleep(0.3)  # test harness: display frames after the move
        rb = rows_report()
        rows_on_grid("2x right after the scale change back (no other move)", rb, 2)
        # The transcript sits 0.5 pt off whole points: rows still on the 1x snap sit on whole points (whole pixels at
        # 2x too, so the grid check above cannot tell); rows on the 2x snap keep the half point.
        wh = rb.get("windowHeight", 0)
        tops = [(wh - r["y"] - r["height"]) for r in rb.get("rows") or [] if r["kind"] == "text" and r["y"] >= 64
                and r["y"] + r["height"] <= wh - 90]
        half = [t for t in tops if abs((t % 1) - 0.5) < 0.01]
        check("2x right after the return: rows follow the 2x snap (some text rows on half points, not the 1x snap)",
              bool(half), {"tops": [round(t, 3) for t in tops]})
        snapshot_checks("2x right after the return", "scale-back.png", rb, full=True)
        # The transcript sits 0.5 pt off (one device pixel at 2x): 0.25 pt more is half a device pixel at 2x.
        rpc("debug.home.drive", {"action": "nudge", "dx": 0.25, "dy": 0.25})
        time.sleep(0.3)  # test harness: display frames for the move to show
        rb = rows_report()
        check("2x after the return: the transcript sits on half a device pixel",
              all(abs(((rb.get(k, 0) * 2) % 1) - 0.5) < 0.02 for k in ("hostX", "hostY")), {k: rb.get(k) for k in ("hostX", "hostY")})
        rows_on_grid("2x after the return, half a pixel", rb, 2)
        snapshot_checks("2x after the return, half a pixel", "scale-back-half.png", rb, full=True)
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    rpc("action.run", {"id": "endAgents"}, timeout=5)
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = "%s/.acpmux/builds/com.cmuxterm.app.debug.%s" % (home, re.sub(r"[^a-z0-9]+", ".", opts.tag.lower()).strip("."))
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown", "--end-agents"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
    if vd is not None:
        subprocess.run(["kill", str(vd)], capture_output=True)  # the virtual display this script started (its pid=)

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
