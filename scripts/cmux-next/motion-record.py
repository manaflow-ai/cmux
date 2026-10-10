#!/usr/bin/env python3
"""Record chrome motion on a running tagged cmux-next build (cx-f6i7).

The motion pass's recorder for surfaces other than the sidebar rows (those
are `sidebar-motion-record.py`). Each scenario starts `debug.window_record`
(the window as composited, one JPEG per display frame plus frames.json), runs
one change through the control socket, and keeps the frames in
OUT/<surface>/<scenario>/. `layout.json` in each surface folder holds
`debug.pane_chrome` before the first scenario, for cropping. The script
attaches to an app already running (a capture slot's `capture-host launch`,
or a tagged build) through its debug socket and never launches or quits it.

Surfaces:
  tabs   tab open, close, move right and left, a drag reorder
  panes  split right, split down, close, equalize, zoom
  focus  focus moves between panes (left, right)

Usage: motion-record.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock --out DIR
       [--surface NAME ...] [--only SCENARIO ...]
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", required=True)
parser.add_argument("--surface", action="append", default=[])
parser.add_argument("--only", action="append", default=[])
parser.add_argument("--seconds", type=float, default=1.5)
opts = parser.parse_args()


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
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


def action(name, **params):
    return rpc("action.run", {"action": name, **params})


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def record(surface, name, trigger):
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, surface, name)
    os.makedirs(directory, exist_ok=True)
    started = rpc("debug.window_record", {"dir": directory, "seconds": opts.seconds})
    time.sleep(0.15)  # test harness: a few still frames before the change
    reply = trigger()
    time.sleep(opts.seconds + 0.6)  # test harness: the recording stops by itself
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    print(f"{surface}/{name}: {frames} frames; record={json.dumps(started)[:100]} reply={json.dumps(reply)[:160]}", flush=True)
    time.sleep(0.4)  # test harness: settle before the next scenario


def save_layout(surface):
    os.makedirs(os.path.join(opts.out, surface), exist_ok=True)
    with open(os.path.join(opts.out, surface, "layout.json"), "w") as handle:
        json.dump({"pane_chrome": rpc("debug.pane_chrome"), "windows": rpc("debug.windows")}, handle)


def paced_drag(x, y, to_x, to_y, seconds=0.45):
    """A drag at pointer pace: one `debug.mouse` move per display frame (a
    single `drag` call posts every event at once, so the release carries no
    real velocity), then the release where the pointer stopped moving."""
    frames = max(2, int(seconds * 60))
    rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "release": False})
    last = (x, y)
    for frame in range(1, frames + 1):
        t = frame / frames
        eased = 1 - (1 - t) ** 2  # the hand slows into the drop
        point = (x + (to_x - x) * eased, y + (to_y - y) * eased)
        rpc("debug.mouse", {"action": "drag", "x": last[0], "y": last[1], "to_x": point[0], "to_y": point[1],
                            "steps": 1, "press": False, "release": frame == frames})
        last = point
        time.sleep(1 / 60)  # test harness: pointer pace
    return {"frames": frames}


def first_pill():
    """The focused pane's first tab pill in window points (`debug.pane_chrome`)."""
    for window in (rpc("debug.pane_chrome") or {}).get("windows") or []:
        for pane in window.get("panes") or []:
            if pane.get("pill"):
                return pane["pill"]
    return None


def tabs():
    save_layout("tabs")
    for _ in range(3):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    record("tabs", "open", lambda: action("newSurface"))
    record("tabs", "close", lambda: action("tab.close"))
    # The last tab is selected after the close: move it left, then back.
    record("tabs", "move-left", lambda: action("moveSurfaceLeft"))
    record("tabs", "move-right", lambda: action("moveSurfaceRight"))
    pill = first_pill()
    if pill:
        # Pills sit side by side: drag the first one past the third's center.
        left, top, width, height = pill
        x, y = left + width / 2, top + height / 2
        to_x = x + width * 2.2
        record("tabs", "drag-reorder", lambda: paced_drag(x, y, to_x, y))
    else:
        print("tabs/drag-reorder: skipped, pane_chrome reports no tab pill", flush=True)


def panes():
    save_layout("panes")
    record("panes", "split-right", lambda: action("splitRight"))
    record("panes", "split-down", lambda: action("splitDown"))
    record("panes", "close", lambda: action("closePane"))
    record("panes", "equalize", lambda: action("equalizeSplits"))
    record("panes", "zoom", lambda: action("toggleSplitZoom"))
    record("panes", "unzoom", lambda: action("toggleSplitZoom"))


def focus():
    save_layout("focus")
    record("focus", "left", lambda: action("focusLeft"))
    record("focus", "right", lambda: action("focusRight"))


SURFACES = {"tabs": tabs, "panes": panes, "focus": focus}


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    os.makedirs(opts.out, exist_ok=True)
    action("workspace.selectFirst")
    time.sleep(1.0)  # test harness: the workspace settles
    for name in opts.surface or list(SURFACES):
        SURFACES[name]()
    print("\nRESULT PASS (recorded)")


main()
