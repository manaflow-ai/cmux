#!/usr/bin/env python3
"""Record pane close and pane zoom motion on a running tagged cmux-next build.

Every pane shows one solid color so a frame says which pane each pixel
belongs to: a terminal's background is set with OSC 11, a WebKit or a
Chromium tab shows a page of one color (served by this script on
127.0.0.1). Each scenario records the composited window (`debug.window_record`,
child windows included: Chromium pages) and, on the same display frames, the
layout's pane and divider geometry (`debug.motion` `trace_*`, the screen
sampler: the presented rect, alpha and subview order of every pane host).
`zoom-close-check.py` reads the result.

Layouts:
  row   terminal | WebKit | Chromium, side by side
  grid  terminal, WebKit / terminal, Chromium (2 x 2; the Chromium pane is
        diagonal to the first terminal)
  strip four terminal columns in a scrolling strip, plus a docked column
  splits a split right and a split down of one terminal
  perf  four panes (three terminals, one WebKit page), one terminal printing `yes` the whole
        time: zoom, unzoom, zoom the busy one, close and split, for the frame times

Scenarios (OUT/<scenario>/): frame-NNNNN.jpg, frames.json, trace.json,
timing.json, before.json and after.json (`debug.pane_chrome`), colors.json
(pane id -> color name), work.json (`debug.motion` stop: the main-thread time of each frame,
`work.layout` the layout's step and `work.clock` the whole display-link tick, in ms).

Usage: zoom-close-record.py --socket SOCK --out DIR [--only NAME ...] [--seconds 1.2]
       [--video --app-name 'cmux DEV TAG'] (a display video through the capture daemon, with Chromium pages)
       [--speed normal] [--reduce-motion]
"""
import argparse, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--only", action="append", default=[])
parser.add_argument("--seconds", type=float, default=1.2)
parser.add_argument("--speed", default="fast", help="debug.motion speed for the run (fast is the default setting)")
parser.add_argument("--layout", action="append", default=[], help="close, row, grid, strip, springs, splits, perf (default: all)")
parser.add_argument("--reduce-motion", action="store_true")
parser.add_argument("--no-pixels", action="store_true",
                    help="no window record in any scenario: the trace runs at the display's rate (the record's per-frame JPEG loads the main thread)")
parser.add_argument("--video", action="store_true", help="also record the display through the capture daemon (--cua-socket)")
parser.add_argument("--cua-socket", default=os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock"))
parser.add_argument("--app-name", default="", help="the app's name (cmux DEV <tag>), to find its window in the display video")
opts = parser.parse_args()

COLORS = {
    "orange": "#ff8c00", "magenta": "#ff00ff", "cyan": "#00ffff", "yellow": "#ffff00",
    "red": "#ff2020", "green": "#00c000", "blue": "#2040ff", "purple": "#8000ff",
}


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0]
        color = COLORS.get(name, "#808080")
        body = f"<!doctype html><title>{name}</title><body style='margin:0;background:{color};height:100vh'></body>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}/"


def rpc(method, params=None, timeout=60):
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
    started = time.monotonic()
    reply = rpc("action.run", {"action": name, **params})
    took = time.monotonic() - started
    if took > 0.5:
        print(f"slow reply: {name} {took:.2f} s {json.dumps(reply)[:400]}", flush=True)
    return reply


def settle(seconds):
    time.sleep(seconds)  # test harness: the layout and the pages settle


def panes():
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    return windows[0].get("panes") or [] if windows else []


colors = {}   # pane id -> color name
ids = {}      # color name -> pane id (of the layout being built)


def cua(name, args, timeout=60):
    """A call to the host's capture daemon (the agent-capture helper's cmux Computer Use, which holds
    the Screen Recording grant: its display video includes Chromium pages, which the app's own
    composited snapshot cannot read without the grant)."""
    if not opts.cua_socket:
        return {"error": "no capture socket"}
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.cua_socket)
        conn.sendall((json.dumps({"method": "call", "name": name, "args": args}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def focus_pane(pane):
    reply = action("pane.focus", target=f"pane:{pane}")
    settle(0.4)
    return reply


def paint_terminal(pane, color):
    """`pane`'s terminal background becomes `color` (OSC 11), the screen cleared and the cursor
    hidden (a blinking cursor would change pixels in a pane that must stay static). The actions
    take a tab target, so the pane is focused and its focused tab gets the text."""
    text = "printf '\\033]11;#%s\\007'; clear; printf '\\033[?25l'\r" % COLORS[color].lstrip("#")
    focus_pane(pane)
    reply = action("terminal.sendText", args={"text": text})
    if isinstance(reply, dict) and reply.get("error"):
        # A pane that opened on a New Tab page: a terminal tab first.
        action("newSurface")
        settle(0.8)
        reply = action("terminal.sendText", args={"text": text})
    print("paint", color, json.dumps(reply)[:140], flush=True)


def new_pane(before, color):
    known = {p["pane"] for p in before}
    created = [p["pane"] for p in panes() if p["pane"] not in known]
    if not created:
        return None
    colors[created[0]], ids[color] = color, created[0]
    return created[0]


def await_pane(before, color):
    """The pane a split, a new column or a new workspace made, once `debug.pane_chrome` lists it."""
    for _ in range(20):
        settle(0.4)
        pane = new_pane(before, color)
        if pane:
            return pane
    return None


def fill(pane, color, engine=None):
    if engine:
        focus_pane(pane)
        reply = rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": BASE + color}}, timeout=90)
        print("open", engine, color, json.dumps(reply)[:160], flush=True)
        settle(3.0 if engine == "chromium" else 1.5)
    else:
        paint_terminal(pane, color)
        settle(0.6)


def focus(color):
    if color not in ids:
        print("focus: no pane for", color, json.dumps(ids), flush=True)
        return None
    return focus_pane(ids[color])


def split(of, direction, color, engine=None):
    focus(of)
    before = panes()
    action("splitRight" if direction == "right" else "splitDown")
    pane = await_pane(before, color)
    if pane:
        fill(pane, color, engine)
    else:
        print("split: no new pane for", color, flush=True)
    return pane


def first_terminal(color):
    """A new workspace with one terminal pane painted `color`. A new workspace opens on a New Tab
    page, not a terminal: a split adds a terminal pane, then the page's pane closes."""
    ids.clear()
    old = {p["pane"] for p in panes()}
    reply = action("workspace.newAtBottom")
    # Through the socket the new workspace is made but not shown: show it (it is the last).
    action("workspace.selectLast")
    shown = []
    for _ in range(25):
        settle(0.4)
        shown = [p["pane"] for p in panes()]
        if shown and not (set(shown) & old):
            break
    print("new workspace", color, len(shown), "panes, shared with the last:", len(set(shown) & old), json.dumps(reply)[:100], flush=True)
    origin = shown[0] if len(shown) == 1 and shown[0] not in old else None
    known = {p["pane"] for p in panes()}
    action("splitRight")
    pane = None
    for _ in range(20):
        settle(0.4)
        created = [p["pane"] for p in panes() if p["pane"] not in known]
        if created:
            pane = created[0]
            break
    if pane and origin:
        focus_pane(origin)
        action("closePane")
        settle(0.8)
    if not pane:
        print("first_terminal: no terminal pane for", color, flush=True)
        return
    colors[pane], ids[color] = color, pane
    fill(pane, color)
    print("first terminal", color, pane, "alone:", len(panes()) == 1, flush=True)


def window_on_screen():
    """The app's window in screen points (top-left origin) and the main display's size, from the capture daemon."""
    listed = cua("list_windows", {"on_screen_only": True})
    windows = (((listed.get("result") or {}).get("structuredContent") or {}).get("windows")) or []
    windows = [w for w in windows if (w.get("bounds") or {}).get("width", 0) > 400
               and (not opts.app_name or w.get("app_name") == opts.app_name)]
    size = cua("get_screen_size", {})
    return {"window": max(windows, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"]) if windows else None,
            "screen": (size.get("result") or {}).get("structuredContent")}


def record(name, trigger, seconds=None, pixels=True):
    """`pixels` False (perf): no window record, whose per-frame snapshot and JPEG encode would load
    the main thread being measured; the trace and the frame times only."""
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, name)
    os.makedirs(directory, exist_ok=True)
    seconds = seconds or opts.seconds
    with open(os.path.join(directory, "before.json"), "w") as handle:
        json.dump({"pane_chrome": rpc("debug.pane_chrome")}, handle)
    with open(os.path.join(directory, "colors.json"), "w") as handle:
        json.dump(colors, handle)
    video = None
    if opts.video:
        video = os.path.realpath(os.path.join(directory, "video"))
        os.makedirs(video, exist_ok=True)
        with open(os.path.join(directory, "screen.json"), "w") as handle:
            json.dump(window_on_screen(), handle)
        started_video = cua("start_recording", {"output_dir": video, "record_video": True})
        print(name, "video", json.dumps(started_video)[:160], flush=True)
        settle(0.4)
    rpc("debug.motion", {"action": "trace_start", "targets": ["panes", "dividers", "zoom", "strip_edges"]})
    rpc("debug.motion", {"action": "start"})
    t0 = time.monotonic()
    pixels = pixels and not opts.no_pixels
    started = rpc("debug.window_record", {"dir": directory, "seconds": seconds}) if pixels else {"pixels": False}
    t_started = time.monotonic() - t0
    time.sleep(0.15)  # test harness: still frames before the change
    t_sent = time.monotonic() - t0
    reply = trigger()
    t_replied = time.monotonic() - t0
    time.sleep(seconds + 0.5)  # test harness: the recording stops by itself
    trace = rpc("debug.motion", {"action": "trace_stop"}) or {}
    work = rpc("debug.motion", {"action": "stop"}) or {}
    with open(os.path.join(directory, "work.json"), "w") as handle:
        json.dump(work, handle)
    if video:
        print(name, "video stop", json.dumps(cua("stop_recording", {}))[:200], flush=True)
    with open(os.path.join(directory, "trace.json"), "w") as handle:
        json.dump(trace, handle)
    with open(os.path.join(directory, "timing.json"), "w") as handle:
        json.dump({"record_reply": t_started, "trigger_sent": t_sent, "trigger_reply": t_replied}, handle)
    with open(os.path.join(directory, "after.json"), "w") as handle:
        json.dump({"pane_chrome": rpc("debug.pane_chrome")}, handle)
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    samples = len(trace.get("samples") or [])
    print(f"{name}: {frames} frames, {samples} trace samples; record={json.dumps(started)[:80]} reply={json.dumps(reply)[:140]}", flush=True)
    settle(0.5)


def toggle():
    return action("toggleSplitZoom")


def twice():
    first = toggle()
    time.sleep(0.12)  # test harness: the second key 120 ms after the first
    return [first, toggle()]


def then_close():
    first = toggle()
    time.sleep(0.15)  # test harness: the close lands mid-zoom
    return [first, action("closePane")]


def zoom_pair(prefix, color):
    focus(color)
    record(f"{prefix}-zoom-{color}", toggle)
    record(f"{prefix}-unzoom-{color}", toggle)


def row():
    first_terminal("orange")
    split("orange", "right", "magenta", "webkit")
    split("magenta", "right", "cyan", "chromium")
    print("row panes:", json.dumps(ids), flush=True)
    for color in ("orange", "magenta", "cyan"):
        zoom_pair("row", color)
    focus("magenta")
    record("row-zoom-twice-magenta", twice, seconds=1.6)
    focus("magenta")
    record("row-close-middle", lambda: action("closePane"))


def grid():
    # orange (terminal) | magenta (WebKit)
    # yellow (terminal) | cyan (Chromium, diagonal to orange)
    first_terminal("orange")
    split("orange", "right", "magenta", "webkit")
    split("orange", "down", "yellow")
    split("magenta", "down", "cyan", "chromium")
    print("grid panes:", json.dumps(ids), flush=True)
    for color in ("cyan", "orange", "yellow", "magenta"):
        zoom_pair("grid", color)
    focus("magenta")
    record("grid-zoom-then-close-magenta", then_close, seconds=1.6)


def strip():
    first_terminal("red")
    for color in ("green", "blue", "yellow"):
        before = panes()
        action("newColumn")
        pane = await_pane(before, color)
        if pane:
            fill(pane, color)
    print("strip panes:", json.dumps(ids), flush=True)
    zoom_pair("strip", "blue")
    focus("blue")
    record("strip-close-blue", lambda: action("closePane"))


def close_layouts():
    """The close, first: a split of two, the middle of three side by side and stacked, a nested
    split, and a strip column; each in its own workspace of terminals, one color per pane."""
    first_terminal("red")
    split("red", "right", "green")
    record("close-two", lambda: action("closePane"))
    first_terminal("red")
    split("red", "right", "green")
    split("green", "right", "blue")
    focus("green")
    record("close-mid-h", lambda: action("closePane"))
    first_terminal("red")
    split("red", "down", "green")
    split("green", "down", "blue")
    focus("green")
    record("close-mid-v", lambda: action("closePane"))
    # red | (green / blue): close green; blue grows up, red does not move.
    first_terminal("red")
    split("red", "right", "green")
    split("green", "down", "blue")
    focus("green")
    record("close-nested", lambda: action("closePane"))
    # (red / yellow) | green | blue: close red; yellow grows up, the right column does not move.
    first_terminal("red")
    split("red", "right", "green")
    split("green", "right", "blue")
    split("red", "down", "yellow")
    focus("red")
    record("close-nested-left", lambda: action("closePane"))
    first_terminal("red")
    for color in ("green", "blue", "yellow"):
        before = panes()
        action("newColumn")
        pane = await_pane(before, color)
        if pane:
            fill(pane, color)
    focus("green")
    record("close-strip", lambda: action("closePane"))


# Spring candidates (DESIGN.md "Spring"): set live through Debug Settings tunables, speed fast.
CANDIDATES = {
    "zoom": [("r28", 0.28, 1.0), ("r32", 0.32, 1.0), ("r38", 0.38, 1.0), ("r32b08", 0.32, 0.92)],
    "exit": [("r20", 0.20, 1.0), ("r24", 0.24, 1.0), ("r28", 0.28, 1.0), ("r24b08", 0.24, 0.92)],
}


def tune(token, response, damping):
    key = f"motion.spring.{token}"
    value = None if response is None else {"response": response, "dampingFraction": damping}
    reply = rpc("debug.tunables", {"action": "set", "key": key, "value": value})
    rpc("debug.motion", {"action": "speed", "value": opts.speed})  # a tunable write reloads settings
    return reply


def springs():
    first_terminal("red")
    split("red", "right", "green")
    split("green", "right", "blue")
    for label, response, damping in CANDIDATES["zoom"]:
        print("tune zoom", label, json.dumps(tune("zoom", response, damping))[:120], flush=True)
        focus("green")
        record(f"spring-zoom-{label}", toggle)
        record(f"spring-unzoom-{label}", toggle)
    tune("zoom", None, None)
    for label, response, damping in CANDIDATES["exit"]:
        print("tune exit", label, json.dumps(tune("exit", response, damping))[:120], flush=True)
        first_terminal("red")
        split("red", "right", "green")
        split("green", "right", "blue")
        focus("green")
        record(f"spring-close-{label}", lambda: action("closePane"))
    tune("exit", None, None)


def splits():
    first_terminal("red")
    focus("red")
    record("split-right", lambda: action("splitRight"))
    first_terminal("red")
    focus("red")
    record("split-down", lambda: action("splitDown"))
    # red | green | blue, split green right: with even split sizing the whole chain evens out.
    first_terminal("red")
    split("red", "right", "green")
    split("green", "right", "blue")
    focus("green")
    record("split-chain-right", lambda: action("splitRight"))


def type_into(color, text):
    focus(color)
    print("type", color, json.dumps(action("terminal.sendText", args={"text": text}))[:120], flush=True)


def perf():
    # red | green | blue (WebKit) / yellow under red, printing `yes` through every scenario.
    first_terminal("red")
    split("red", "right", "green")
    split("green", "right", "blue", "webkit")
    split("red", "down", "yellow")
    for color in ("red", "green"):
        type_into(color, "seq 1 400 | paste -sd ' ' -\r")
    type_into("yellow", "yes\r")
    settle(0.5)
    focus("green")
    record("perf-zoom-green", toggle, pixels=False)
    record("perf-unzoom-green", toggle, pixels=False)
    focus("yellow")
    record("perf-zoom-busy", toggle, pixels=False)
    record("perf-unzoom-busy", toggle, pixels=False)
    focus("blue")
    record("perf-zoom-webkit", toggle, pixels=False)
    record("perf-unzoom-webkit", toggle, pixels=False)
    focus("red")
    record("perf-split-red", lambda: action("splitRight"), pixels=False)
    focus("green")
    record("perf-close-green", lambda: action("closePane"), pixels=False)
    type_into("yellow", "\x03")


def perf_busy_first():
    """perf with the busy terminal's zoom first: is a live resize of a terminal under heavy output
    what slows the daemon (every later reply slow), or another pane's zoom next to it."""
    first_terminal("red")
    split("red", "right", "green")
    split("green", "right", "blue", "webkit")
    split("red", "down", "yellow")
    for color in ("red", "green"):
        type_into(color, "seq 1 400 | paste -sd ' ' -\r")
    type_into("yellow", "yes\r")
    settle(0.5)
    focus("yellow")
    record("perf-zoom-busy", toggle, pixels=False)
    record("perf-unzoom-busy", toggle, pixels=False)
    focus("green")
    record("perf-zoom-green", toggle, pixels=False)
    record("perf-unzoom-green", toggle, pixels=False)
    focus("blue")
    record("perf-zoom-webkit", toggle, pixels=False)
    record("perf-unzoom-webkit", toggle, pixels=False)
    focus("red")
    record("perf-split-red", lambda: action("splitRight"), pixels=False)
    focus("green")
    record("perf-close-green", lambda: action("closePane"), pixels=False)
    type_into("yellow", "\x03")
    settle(2)
    focus("red")
    print("after ctrl-c, a focus took", json.dumps(action("pane.focus", target=f"pane:{ids.get('red')}"))[:120], flush=True)


LAYOUTS = {"perf-busy-first": perf_busy_first, "close": close_layouts, "row": row, "grid": grid, "strip": strip, "springs": springs, "splits": splits, "perf": perf}


def main():
    if not (rpc("debug.windows") or {}).get("windows"):
        for _ in range(120):
            settle(0.5)
            if (rpc("debug.windows") or {}).get("windows"):
                break
        else:
            sys.exit("the app does not answer on " + opts.socket)
    os.makedirs(opts.out, exist_ok=True)
    print("speed", json.dumps(rpc("debug.motion", {"action": "speed", "value": opts.speed}))[:200], flush=True)
    print("pane animations", json.dumps(rpc("debug.motion", {"action": "kind", "name": "paneAnimations", "value": True}))[:120], flush=True)
    if opts.reduce_motion:
        print("reduce motion:", json.dumps(rpc("debug.motion", {"action": "reduce", "value": True}))[:120], flush=True)
    try:
        for layout in [LAYOUTS[name] for name in (opts.layout or list(LAYOUTS))]:
            layout()
    finally:
        if opts.reduce_motion:
            rpc("debug.motion", {"action": "reduce", "value": None})
        with open(os.path.join(opts.out, "colors.json"), "w") as handle:
            json.dump(colors, handle)
    print("\nRESULT PASS (recorded)")


main()
