#!/usr/bin/env python3
"""Tagged-app check: Home's rows follow a backing scale change (MessagesLab 82ccac1 snap-followup).

Launches the tagged app with no activation, opens the DEBUG Home fixture (the real transcript view over a
HomeStore over the mock owner) and sends a message, so outgoing and incoming rows show. Moves the transcript by
0.25 pt (half a device pixel at 2x) and reads the rows as drawn (`debug.home.drive {action: rows}`): each text
row's anchored side (incoming left, my rows right) and top on whole device pixels at 2x. Then it makes a 1x
virtual display (MessagesLab's tools/interactions/vdisplay.m, hidpi 0; the display ends by itself after 240 s)
and moves the window onto it (`debug.window_frame {screen: last}`): the window's backing scale changes to 1, Home's
host calls MessagesWindowView.setRenderScale (HostView.viewDidChangeBackingProperties ->
ChatController.displayScaleChanged), and the rows must snap again: read right after the move (no other move
of the transcript, so only setRenderScale can have re-snapped them), then again with the transcript on half a
point (half a device pixel at 1x): every text row's anchored side and top must be on whole points. The move back
to 2x is UNVERIFIED on the GUI host (the virtual display becomes screen 0); the script reports what it measured. Snapshots at each scale.
Socket only, no system input. Runs on cmux-lawrence-2 (nx-remote --needs gui); ends with the DEBUG quit fixture,
the tag's `acpmux daemon shutdown`, and the virtual display's own process (its pid, started here).

Usage: home-scale-change.py --tag <tag> --ml <MessagesLab source dir with tools/interactions/vdisplay.m> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time

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
UNVERIFIED = []


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


vd = None
if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
print(f"launched pid {pid}", flush=True)
try:
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
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "scale-2x.png")})

    # A 1x virtual display, and the window onto it.
    vdbin = os.path.join(opts.out, "vdisplay")
    build = subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "AppKit",
                            os.path.join(opts.ml, "tools/interactions/vdisplay.m"), "-o", vdbin], capture_output=True, text=True)
    if not check("the virtual display tool builds", build.returncode == 0, build.stderr[-400:]):
        sys.exit(1)
    vdlog = os.path.join(opts.out, "vdisplay.log")
    vd = subprocess.Popen([vdbin, "1600", "1000", "60", "240", "0"], stdout=open(vdlog, "w"), stderr=subprocess.STDOUT,
                          stdin=subprocess.DEVNULL, start_new_session=True)
    up = poll(lambda: "origin" in open(vdlog).read(), timeout=20)
    check("a 1x virtual display exists", bool(up), open(vdlog).read()[-300:])
    moved = rpc("debug.window_frame", {"screen": "last"}) or {}
    check("the window moves onto the virtual display", moved.get("screen") == "MessagesLab Rig", moved)
    r1 = poll(lambda: (r := rows_report()) and r.get("scale") == 1 and r, timeout=10) or rows_report()
    check("the window's backing scale is 1 on the virtual display", r1.get("scale") == 1, {k: r1.get(k) for k in ("scale", "error")})
    # Before any move of the transcript: only setRenderScale re-snaps the rows here (the transcript sits 0.25 pt off
    # the grid, a quarter pixel at 1x; rows still on the 2x snap would sit half a point off).
    time.sleep(0.3)  # test harness: display frames after the move
    r1 = rows_report()
    if r1.get("scale") == 1:
        rows_on_grid("1x right after the scale change (no other move)", r1, 1)
    # Half a point is half a device pixel at 1x (the 0.25 pt move made it a quarter).
    rpc("debug.home.drive", {"action": "nudge", "dx": 0.25, "dy": 0.25})
    time.sleep(0.3)  # test harness: display frames for the move to show
    r1 = rows_report()
    check("1x: the transcript sits on half a device pixel", all(abs((r1.get(k, 0) % 1) - 0.5) < 0.01 for k in ("hostX", "hostY")),
          {k: r1.get(k) for k in ("hostX", "hostY")})
    if r1.get("scale") == 1:
        rows_on_grid("1x after the scale change, half a pixel", r1, 1)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "scale-1x.png")})

    # Back to 2x: UNVERIFIED on the GUI host (decision hq-6d after gate runs on 024e48d and e87fffa). The rig cannot
    # move the window off the virtual display: with it attached, NSScreen.screens[0] (the menu-bar screen) is the
    # virtual display itself (screen 0 centres the window at 1512,74, inside it), and the frame from before lies in
    # its desktop area too. The step still runs and reports what it measured; it never passes or fails the check.
    back = rpc("debug.window_frame", {"screen": 0}) or {}
    rb = poll(lambda: (r := rows_report()) and r.get("scale") == 2 and r, timeout=5) or rows_report()
    if rb.get("scale") == 2:
        time.sleep(0.3)  # test harness: display frames after the move
        rows_on_grid("2x right after the scale change back (no other move)", rows_report(), 2)
    else:
        print(f"UNVERIFIED return to 2x: the window stayed on {back.get('screen')!r} at {back.get('frame')},"
              f" backing scale {rb.get('scale')}", flush=True)
        UNVERIFIED.append("return to 2x")
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "scale-back.png")})
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = f"{home}/.acpmux/tags/{opts.tag}"
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
    if vd is not None and vd.poll() is None:
        vd.terminate()  # the virtual display this script started (its own pid)

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
if UNVERIFIED:
    print(f"{len(UNVERIFIED)} step(s) UNVERIFIED (not passed): {UNVERIFIED}", flush=True)
sys.exit(1 if failures else 0)
