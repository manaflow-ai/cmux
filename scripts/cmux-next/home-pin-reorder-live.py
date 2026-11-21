#!/usr/bin/env python3
"""Live proof that a pinned tile dragged in Home's conversation list lands where it was dropped
(the user, 2026-11-05: "reordering pinned stuff in imessage doesnt work"), on a tagged DEBUG app
already running on a capture slot (`capture-host launch`), through its control socket.

  home-pin-reorder-live.py --socket SOCK --out DIR --mode light|dark [--reduce-motion] [--record]
  home-pin-reorder-live.py --socket SOCK --out DIR --expect ID,ID,...   (after a relaunch)

Lists five fixture conversations with three pinned beside the window's own Chief
(`debug.home.sidebar_fixture`), then drags with `debug.mouse` events (one request per pointer
step, so the list's own tracking loop gets a real drag): the first tile to the last slot, then
the last tile to the first slot. Each drop must leave the grid in the drawn order with that one
tile moved. Writes DIR/<mode>-before.png, -after-1.png, -after-2.png (`debug.window_snapshot`),
DIR/<mode>-frames (`--record`: the first drag, one JPEG per display frame) and DIR/<mode>.json
(the grid before and after each drop). `--expect` only reads the grid and checks it (the order
after a relaunch). Exit 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--mode", default="dark", choices=["light", "dark"])
parser.add_argument("--reduce-motion", action="store_true")
parser.add_argument("--record", action="store_true")
parser.add_argument("--expect", help="comma-separated pinned ids the grid must show (a relaunch check)")
parser.add_argument("--hz", type=float, default=120)
parser.add_argument("--tiles", help="x,y;x,y;... tile centers in window points, for a build whose debug.home has no sidebar "
                    "(before the docked Home was reported): the order is then read from the stills only")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def wait(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)  # harness wait for the app's socket, not app code
    return False


def sidebar():
    home = rpc("debug.home") or {}
    return ((home.get("page") or {}).get("sidebar") or {})


def tiles():
    """The drawn tiles' centers in window points, in grid order."""
    if opts.tiles:
        return [tuple(float(v) for v in pair.split(",")) for pair in opts.tiles.split(";")]
    items = sidebar().get("items") or []
    return [center(i) for i in items if i.get("pinned")]


def grid():
    """The grid's conversation ids in drawn order; None when the build does not report them."""
    side = sidebar()
    return side.get("pinned") if side else None


def center(item):
    f = item["frame"]
    x, y, w, h = (f["x"], f["y"], f["width"], f["height"]) if isinstance(f, dict) else tuple(f)
    return (x + w / 2, y + h / 2)


def pin_chief():
    """Pins this window's Chief conversation with its owner (the main Chief): the grid then holds it."""
    home = rpc("debug.home") or {}
    rows = [c for c in (home.get("conversations") or []) + ((home.get("page") or {}).get("lines") or []) if isinstance(c, dict)]
    chiefs = [c for c in rows if c.get("id") and (c.get("kind") == "chief" or any(p.get("chief") if isinstance(p, dict) else str(p).startswith("agent_") for p in c.get("participants") or []))]
    if not chiefs:
        return {"error": "no Chief conversation", "keys": list(home.keys())}
    return rpc("action.run", {"action": "home.togglePin", "args": {"conversation": chiefs[0]["id"], "pinned": True}})


def shot(name):
    return rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{opts.mode}-{name}.png")})


results = []


def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    print("%s %s %s" % ("PASS" if ok else "FAIL", name, str(detail)[:600]), flush=True)


def drag(src, dst, record=None):
    """Presses tile `src` of the drawn grid, drags it over tile `dst` and lets go."""
    shown = tiles()
    a, b = shown[src], shown[dst]
    path = []
    for (p, q, seconds) in [(a, b, 0.6), (b, b, 0.25)]:
        n = max(1, int(seconds * opts.hz))
        for k in range(1, n + 1):
            t = k / n
            e = t * t * (3 - 2 * t)
            path.append((p[0] + (q[0] - p[0]) * e, p[1] + (q[1] - p[1]) * e))
    if record:
        print("record", rpc("debug.window_record", {"dir": record, "seconds": 3}), flush=True)
        time.sleep(0.3)  # the recording's first frames show the grid at rest
    rpc("debug.mouse", {"x": a[0], "y": a[1], "action": "down"})
    t0 = time.monotonic()
    for k, (x, y) in enumerate(path):
        rpc("debug.mouse", {"x": x, "y": y, "action": "drag", "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
        delay = t0 + (k + 1) / opts.hz - time.monotonic()
        if delay > 0:
            time.sleep(delay)  # pointer pacing at --hz (the drag's own speed), not a settle wait
    rpc("debug.mouse", {"x": b[0], "y": b[1], "action": "up"})
    time.sleep(0.6)  # the owner's write and reread, then the list redraws


if not wait(lambda: os.path.exists(opts.socket) and (rpc("debug.windows") or {}).get("windows"), 180):
    sys.exit(f"the app did not come up on {opts.socket}")
print("home.show", rpc("action.run", {"action": "home.show", "focus": True}), flush=True)
rpc("debug.appearance", {"mode": opts.mode})
time.sleep(2)  # Home's first frame after the switch
report = {"mode": opts.mode, "reduce_motion": opts.reduce_motion}

if opts.expect:
    # The fixture rows live in memory only: list them again (already pinned ones keep their pins and places).
    rpc("debug.home.sidebar_fixture", {"count": 5, "pinned": 3, "width": 340})
    wait(lambda: len(grid()) >= len(opts.expect.split(",")), 20)
    now = grid()
    check("relaunch keeps the order", now == opts.expect.split(","), {"grid": now, "expected": opts.expect.split(",")})
    shot("relaunched")
else:
    if opts.reduce_motion:
        print("reduce motion", rpc("debug.motion", {"action": "reduce", "value": True}), flush=True)
    print("fixture", json.dumps(rpc("debug.home.sidebar_fixture", {"count": 5, "pinned": 3, "width": 340}))[:300], flush=True)
    print("pin chief", json.dumps(pin_chief())[:300], flush=True)
    wait(lambda: len(tiles()) >= 4, 20)
    time.sleep(1)  # the owner's pin write and reread
    before = grid()
    report["before"] = before
    shot("before")
    n = len(tiles())
    check("four pinned tiles (the Chief and three)", n >= 4, before)
    # The first row's three tiles: the leading tile (the main Chief) dropped on the third slot,
    # then the second tile dropped on the first slot.
    drag(0, 2, record=os.path.join(opts.out, f"{opts.mode}-frames") if opts.record else None)
    first = grid()
    report["after_1"] = first
    shot("after-1")
    if before is not None:
        expected = before[1:3] + before[:1] + before[3:]
        check("the first tile dropped on the third slot lands third", first == expected, {"grid": first, "expected": expected})
    drag(1, 0)
    second = grid()
    report["after_2"] = second
    shot("after-2")
    if first is not None:
        expected = first[1:2] + first[:1] + first[2:]
        check("the second tile dropped on the first slot lands first", second == expected, {"grid": second, "expected": expected})
report["results"] = results
json.dump(report, open(os.path.join(opts.out, f"{opts.mode}{'-relaunch' if opts.expect else ''}.json"), "w"), indent=1)
sys.exit(0 if results and all(r["ok"] for r in results) else 1)
