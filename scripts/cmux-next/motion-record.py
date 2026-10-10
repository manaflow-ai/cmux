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
  toasts a toast appears (pin a tab), a second stacks under it (close a tab),
         and the newest ends (undo) while the other slides back down

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


def record(surface, name, trigger, seconds=None):
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, surface, name)
    os.makedirs(directory, exist_ok=True)
    seconds = seconds or opts.seconds
    started = rpc("debug.window_record", {"dir": directory, "seconds": seconds})
    time.sleep(0.15)  # test harness: a few still frames before the change
    reply = trigger()
    time.sleep(seconds + 0.6)  # test harness: the recording stops by itself
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


def key(name, *modifiers):
    """A key press through the window's key path, as a person types it."""
    return rpc("debug.key", {"key": name, "modifiers": list(modifiers)})


def shown_toasts():
    print("toasts shown:", json.dumps((rpc("debug.filepages") or {}).get("toasts")), flush=True)


def toasts():
    # Toasts answer a person's gesture (automation runs show none), so each
    # step is a key press. Cmd-W on a terminal tab shows the close undo
    # toast, recorded until it ends by itself; a second close while one is
    # up replaces it; Cmd-Z undoes that close and its toast leaves. (A stack
    # needs a second kind of user toast: the palette's Pin Tab traps on
    # open, cx-bpcj, and a capture slot's window never becomes key, which
    # the zoom readout needs.)
    for _ in range(4):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    save_layout("toasts")
    record("toasts", "appear", lambda: key("w", "cmd"), seconds=7.5)
    shown_toasts()
    key("w", "cmd")
    time.sleep(1.0)  # test harness: the close toast is up
    record("toasts", "replace", lambda: key("w", "cmd"))
    record("toasts", "undo", lambda: key("z", "cmd"))
    shown_toasts()


def hold(x, y, seconds=0.6):
    """A press held in place (the chip's press-and-hold opens its editor)."""
    rpc("debug.mouse", {"action": "down", "x": x, "y": y})
    time.sleep(seconds)  # test harness: the hold
    return rpc("debug.mouse", {"action": "up", "x": x, "y": y})


def snapshot(name):
    path = os.path.join(opts.out, "popups", name + ".png")
    print(name, json.dumps(rpc("debug.window_snapshot", {"path": path}))[:200], flush=True)


def popups():
    # The tab group editor opens from a press-and-hold on its chip and
    # closes when its group is ungrouped; the sidebar group editor
    # opens from a click on its header and closes on a second click there.
    for _ in range(2):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    rpc("action.run", {"action": "selectSurfaceByNumber", "args": {"index": 1}})
    print("group:", json.dumps(rpc("action.run", {"action": "tabGroup.create", "args": {"name": "Motion"}}))[:200], flush=True)
    time.sleep(0.8)  # test harness: the chip settles
    save_layout("popups")
    chrome = (rpc("debug.pane_chrome") or {}).get("windows") or []
    pane = (chrome[0].get("panes") or [{}])[0] if chrome else {}
    strip, pill = pane.get("strip"), pane.get("pill")
    print("strip", strip, "pill", pill, flush=True)
    snapshot("chip")
    if strip and pill:
        x, y = (strip[0] + pill[0]) / 2, pill[1] + pill[3] / 2
        record("popups", "tab-open", lambda: hold(x, y))
        snapshot("tab-opened")
        # A click elsewhere closes it for a person by making the window key,
        # which a capture slot's window never becomes; Ungroup (its own row's
        # command) closes it as the group goes.
        record("popups", "tab-close", lambda: action("tabGroup.ungroup"))
        snapshot("tab-closed")
    print("ws group:", json.dumps(rpc("action.run", {"action": "workspace.moveToNewGroup", "args": {"name": "Motion"}}))[:200], flush=True)
    time.sleep(1.0)  # test harness: the group row settles
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    header = next((r for r in rows if str(r.get("key", "")).startswith("group")), None)
    print("header", json.dumps(header)[:300], flush=True)
    if header:
        f = header["window_frame"]
        hx, hy = f["x"] + 40, f["y"] + f["height"] / 2
        record("popups", "sidebar-open", lambda: rpc("debug.mouse", {"action": "click", "x": hx, "y": hy}))
        snapshot("sidebar-opened")
        record("popups", "sidebar-close", lambda: rpc("debug.mouse", {"action": "click", "x": hx, "y": hy}))
        snapshot("sidebar-closed")


SURFACES = {"tabs": tabs, "panes": panes, "focus": focus, "toasts": toasts, "popups": popups}


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
