#!/usr/bin/env python3
"""The sidebar's Updated card while the sidebar edge is dragged wide, narrow, wide, recorded (Leo 2026-11-27, on the
"Updated to Nightly" card: "this thing is just too weird there's a glass back that shouldnt be there").

  python3 -I scripts/cmux-next/update-card-resize-drag.py --app APP --tag TAG --arm NAME --out DIR --probe PROBE

Launches the tagged DEBUG app (scratch config), shows the Updated card (`debug.updater {action: updated}`, relaunching
once if this launch does not show it), then moves the sidebar's right edge through fixed widths in 20 pt legs. After
each leg it prints one UCD-STEP line: the sidebar width (`debug.windows`), the card's page frame and height
(`debug.update_surfaces state`) right after the leg and 0.6 s later; `settle_dh` is how far the card's height still
moved after the edge stopped (a spring). The card's native glass is not in the debug socket's reply: the video shows it.

The edge: a real press, drag and release along each leg (pointer-probe.swift `drag`) when this session may post events
and the first leg moves the sidebar; else CuaDriver's `move_cursor` (desktop scope, foreground delivery, through the
recording's own `cua-driver mcp` session) warps the real cursor along the leg and `debug.mouse drag` presses, drags
and releases there. A trial leg must land the cursor (`where`) and move the sidebar 20 pt, else the run fails with
UCD-FAIL: a run whose cursor never moves records a video of nothing being dragged (the `cua-driver call` CLI finds no
daemon under a fleet step's HOME; titlebar step e6593cccbd30b9f99bce2a04 went flat that way). `--socket-width`
drives `debug.update_surfaces {action: sidebar-width}` in 4 pt steps at about 60 Hz instead, no cursor at all.
The mode prints as UCD-MODE. The display is recorded through CuaDriver (tab_switch_capture.CuaSession) into DIR when
it can; UCD-VIDEO names it. Quits the app with its own quit; signals only the PID it started.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

p = argparse.ArgumentParser()
p.add_argument("--app", required=True)
p.add_argument("--tag", required=True)
p.add_argument("--arm", required=True)
p.add_argument("--out", required=True)
p.add_argument("--probe", required=True, help="the built pointer-probe binary")
p.add_argument("--socket-width", action="store_true", help="set the width over the socket; no cursor, no drag")
o = p.parse_args()
SOCK = f"/tmp/cmux-debug-{o.tag}.sock"
FRAME = (40, 40, 1100, 760)


def rpc(method, params=None, timeout=30):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(SOCK)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    c.close()
    r = json.loads(buf or b"{}")
    return r.get("result") if r.get("ok") else {"error": r.get("error")}


def wait(check, seconds, step=0.2):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait on the app's state
        try:
            v = check()
        except OSError:
            v = None
        if v:
            return v
        time.sleep(step)
    return None


def width():
    w = ((rpc("debug.windows") or {}).get("windows") or [{}])[0]
    return w.get("sidebar_width")


def card():
    s = rpc("debug.update_surfaces", {"action": "state"}) or {}
    return s.get("updatedCard") == "true", s.get("updatedFrame"), float(s.get("updatedHeight") or 0)


def probe(*args):
    r = subprocess.run([o.probe, *map(str, args)], capture_output=True, text=True, timeout=30)
    return r.stdout.strip()


def where():
    """The real cursor, global top-left points, or None."""
    try:
        x, y = (float(v) for v in probe("where").split()[:2])
    except ValueError:
        return None
    return x, y


def landed(target, tolerance=2.0):
    at = where()
    return at is not None and abs(at[0] - target[0]) < tolerance and abs(at[1] - target[1]) < tolerance, at


APP = o.app.rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BIN = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
cfg = os.path.join(tempfile.mkdtemp(prefix=f"ucd-{o.tag}-"), "cmux.json")
with open(cfg, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCK):
    os.unlink(SOCK)
os.makedirs(o.out, exist_ok=True)


def launch():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    proc = subprocess.Popen([BIN], env={
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": cfg,
        "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, FRAME))},
        stdout=open(os.path.join(o.out, "app.log"), "a"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    wait(lambda: os.path.exists(SOCK) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60)
    time.sleep(2)
    return proc


def quit_app(proc):
    try:
        rpc("action.run", {"action": "quit", "origin": "script"}, timeout=5)
    except OSError:
        pass
    try:
        proc.wait(15)
    except subprocess.TimeoutExpired:
        proc.terminate()  # the PID this script started


app = launch()
session = None
try:
    print(f"UCD-UPDATED {o.arm} {rpc('debug.updater', {'action': 'updated'})}", flush=True)
    if not wait(lambda: card()[0] and card()[2] > 0, 8):
        # The card reads the last seen version at launch: the next launch shows it.
        quit_app(app)
        app = launch()
    if not wait(lambda: card()[0] and card()[2] > 0, 20):
        raise SystemExit(f"update-card-resize-drag: no Updated card ({card()})")
    if (width() or 0) <= 0 or ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("sidebar_hidden"):
        rpc("action.run", {"action": "toggleSidebar", "origin": "script"})
        wait(lambda: (width() or 0) > 0, 10)
    rpc("debug.update_surfaces", {"action": "sidebar-width", "width": 300})
    time.sleep(1.0)
    targets = [300, 420, 180, 420, 260]
    print(f"UCD-START {o.arm} width={width()} card={card()}", flush=True)

    windows = probe("windows", app.pid).splitlines()
    import re
    nums = [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", windows[0])] if windows else []
    wx, wy = (nums[1], nums[2]) if len(nums) >= 3 else (FRAME[0], FRAME[1])
    edge_y = FRAME[3] / 2  # window-local from the top: the sidebar's middle, over its edge

    # One `cua-driver mcp` session warps the cursor and records (the `cua-driver call` CLI finds no daemon under the
    # step's HOME: tab_switch_capture.driver_env).
    try:
        from tab_switch_capture import CuaSession
        session = CuaSession()
        session.open()
    except Exception as error:  # noqa: BLE001 - posted drags still work without it
        print(f"UCD-CUA {o.arm} none ({error})", flush=True)
        session = None
    scale = 2.0
    if session is not None:
        try:
            scale = float(session.tool("get_screen_size", {}).get("scale_factor") or 2.0)
        except Exception as error:  # noqa: BLE001
            print(f"UCD-CUA {o.arm} get_screen_size failed ({error})", flush=True)

    def cua_move(tx, ty):
        session.tool("move_cursor", {"scope": "desktop", "delivery_mode": "foreground",
                                     "x": round(tx * scale), "y": round(ty * scale)})

    def warp_drag(a, b, steps):
        """The real cursor along the leg (CuaDriver), the press, drags and release through `debug.mouse`."""
        cua_move(wx + a, wy + edge_y)
        rpc("debug.mouse", {"action": "drag", "x": a, "y": edge_y, "to_x": b, "to_y": edge_y, "steps": steps})
        cua_move(wx + b, wy + edge_y)

    def trial(drag, label):
        """One 20 pt leg: the cursor must end on the edge and the sidebar must follow it."""
        before = width() or 300
        try:
            drag(before, before + 20)
        except Exception as error:  # noqa: BLE001
            return False, f"{label} failed ({error})"
        time.sleep(0.4)
        ok_cursor, at = landed((wx + before + 20, wy + edge_y))
        after = width() or before
        rpc("debug.update_surfaces", {"action": "sidebar-width", "width": 300})
        time.sleep(0.6)
        return ok_cursor and abs(after - before - 20) < 6, f"{label}: cursor {at}, width {before}->{after}"

    mode, why = "socket-width", "--socket-width"
    if not o.socket_width:
        ok, why = trial(lambda a, b: probe("drag", wx + a, wy + edge_y, wx + b, wy + edge_y, 12), "posted drag")
        mode = "real-drag" if ok else "none"
        if not ok and session is not None:
            ok, more = trial(lambda a, b: warp_drag(a, b, 12), "cua warp+debug drag")
            why += f"; {more}"
            mode = "warp+debug-drag" if ok else "none"
    print(f"UCD-MODE {o.arm} {mode} window_at={wx},{wy} scale={scale} ({why})", flush=True)
    if mode == "none":
        raise SystemExit(f"UCD-FAIL {o.arm} no route drags the edge with the real cursor ({why}); "
                         "--socket-width sets the width with no cursor")

    if session is not None:
        try:
            session.start(o.out)
        except Exception as error:  # noqa: BLE001 - a run with no recording still prints its steps
            print(f"UCD-VIDEO {o.arm} none ({error})", flush=True)
            if mode == "warp+debug-drag":
                session.close()
                session = None
                raise SystemExit(f"UCD-FAIL {o.arm} the CuaDriver session closed ({error})")
    time.sleep(0.8)
    misses = []
    rows, at = [], 300.0
    for target in targets[1:]:
        while abs(target - at) > 0.5:
            to = at + max(-20.0, min(20.0, target - at))
            if mode == "real-drag":
                probe("drag", wx + at, wy + edge_y, wx + to, wy + edge_y, 24)
            elif mode == "warp+debug-drag":
                warp_drag(at, to, 24)
            else:
                step = 4 if to > at else -4
                for w in range(int(at) + step, int(to) + step, step):
                    rpc("debug.update_surfaces", {"action": "sidebar-width", "width": w})
                    time.sleep(1 / 60)
            at = to
            time.sleep(0.05)
            ok = True
            if mode != "socket-width":
                ok, cursor = landed((wx + at, wy + edge_y))
                if not ok:
                    misses.append(at)
                    print(f"UCD-FAIL {o.arm} leg to {at}: cursor at {cursor}", flush=True)
            shown, frame, height = card()
            time.sleep(0.6)
            _, settled_frame, settled_height = card()
            row = {"arm": o.arm, "target": target, "edge": round(at, 1), "sidebar_width": width(), "card": shown,
                   "frame": frame, "height": height, "settled_frame": settled_frame, "settle_dh": round(settled_height - height, 1),
                   "cursor_ok": ok, "glass": "unreported"}
            rows.append(row)
            print("UCD-STEP " + " ".join(f"{k}={v}" for k, v in row.items()), flush=True)
    with open(os.path.join(o.out, "steps.json"), "w") as f:
        json.dump(rows, f, indent=1)
    if session is not None:
        try:
            print(f"UCD-VIDEO {o.arm} {session.stop(o.out)}", flush=True)
        except Exception as error:  # noqa: BLE001
            print(f"UCD-VIDEO {o.arm} none ({error})", flush=True)
    if misses:
        raise SystemExit(f"UCD-FAIL {o.arm} the cursor missed {len(misses)} leg(s)")
finally:
    if session is not None:
        session.close()
    quit_app(app)
