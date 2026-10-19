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

Scenarios (OUT/<scenario>/): frame-NNNNN.jpg, frames.json, trace.json,
timing.json, before.json and after.json (`debug.pane_chrome`), colors.json
(pane id -> color name).

Usage: zoom-close-record.py --socket SOCK --out DIR [--only NAME ...] [--seconds 1.2]
       [--speed normal] [--reduce-motion]
"""
import argparse, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--only", action="append", default=[])
parser.add_argument("--seconds", type=float, default=1.2)
parser.add_argument("--speed", default="normal", help="debug.motion speed for the run (fast, normal)")
parser.add_argument("--reduce-motion", action="store_true")
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
    return rpc("action.run", {"action": name, **params})


def settle(seconds):
    time.sleep(seconds)  # test harness: the layout and the pages settle


def panes():
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    return windows[0].get("panes") or [] if windows else []


colors = {}


def paint_terminal(color):
    """The focused terminal's background becomes `color` (OSC 11), the screen cleared."""
    hex_ = COLORS[color].lstrip("#")
    text = "printf '\\033]11;#%s\\007'; clear\r" % hex_
    print("paint", color, json.dumps(action("terminal.sendText", args={"text": text}))[:120], flush=True)


def new_pane_ids(before):
    known = {p["pane"] for p in before}
    return [p["pane"] for p in panes() if p["pane"] not in known]


def note(color, before):
    created = new_pane_ids(before)
    if created:
        colors[created[0]] = color
    return created


def open_page(engine, color):
    reply = rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": BASE + color}, "focus": True}, timeout=90)
    print("open", engine, color, json.dumps(reply)[:160], flush=True)


def split(direction, color, engine=None):
    before = panes()
    action("splitRight" if direction == "right" else "splitDown")
    settle(1.0)
    created = note(color, before)
    if engine:
        open_page(engine, color)
        settle(3.0 if engine == "chromium" else 1.5)
    else:
        paint_terminal(color)
        settle(0.6)
    return created[0] if created else None


def first_terminal(color):
    before = panes()
    action("workspace.newAtBottom")
    settle(1.2)
    created = note(color, before)
    if not created:
        # The new workspace's pane replaces the old screen: the one pane shown is it.
        shown = panes()
        if len(shown) == 1:
            colors[shown[0]["pane"]] = color
    paint_terminal(color)
    settle(0.6)


def record(name, trigger, seconds=None):
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, name)
    os.makedirs(directory, exist_ok=True)
    seconds = seconds or opts.seconds
    with open(os.path.join(directory, "before.json"), "w") as handle:
        json.dump({"pane_chrome": rpc("debug.pane_chrome")}, handle)
    with open(os.path.join(directory, "colors.json"), "w") as handle:
        json.dump(colors, handle)
    rpc("debug.motion", {"action": "trace_start", "targets": ["panes", "dividers", "zoom"]})
    t0 = time.monotonic()
    started = rpc("debug.window_record", {"dir": directory, "seconds": seconds})
    t_started = time.monotonic() - t0
    time.sleep(0.15)  # test harness: still frames before the change
    t_sent = time.monotonic() - t0
    reply = trigger()
    t_replied = time.monotonic() - t0
    time.sleep(seconds + 0.5)  # test harness: the recording stops by itself
    trace = rpc("debug.motion", {"action": "trace_stop"}) or {}
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


def focus_by(*moves):
    for move in moves:
        action(move)
        settle(0.35)


def twice(name):
    def run():
        first = action(name)
        time.sleep(0.12)  # test harness: the second key 120 ms after the first
        return [first, action(name)]
    return run


def then_close():
    first = action("toggleSplitZoom")
    time.sleep(0.15)  # test harness: the close lands mid-zoom
    return [first, action("closePane")]


def row():
    first_terminal("orange")
    split("right", "magenta", "webkit")
    split("right", "cyan", "chromium")
    print("row panes:", json.dumps(colors), flush=True)
    # Focus is on the Chromium pane (right).
    for target, moves in (("cyan", ()), ("magenta", ("focusLeft",)), ("orange", ("focusLeft",))):
        focus_by(*moves)
        record(f"row-zoom-{target}", lambda: action("toggleSplitZoom"))
        record(f"row-unzoom-{target}", lambda: action("toggleSplitZoom"))
    focus_by("focusRight")  # the WebKit pane
    record("row-zoom-twice-magenta", twice("toggleSplitZoom"), seconds=1.6)
    record("row-close-middle", lambda: action("closePane"))


def grid():
    first_terminal("orange")
    split("right", "magenta", "webkit")
    focus_by("focusLeft")
    split("down", "yellow")
    focus_by("focusRight")
    split("down", "cyan", "chromium")
    print("grid panes:", json.dumps(colors), flush=True)
    # Focus: Chromium (bottom right). Zoom it, then the terminal diagonal to it.
    record("grid-zoom-cyan", lambda: action("toggleSplitZoom"))
    record("grid-unzoom-cyan", lambda: action("toggleSplitZoom"))
    focus_by("focusUp", "focusLeft")
    record("grid-zoom-orange", lambda: action("toggleSplitZoom"))
    record("grid-unzoom-orange", lambda: action("toggleSplitZoom"))
    focus_by("focusDown")
    record("grid-zoom-yellow", lambda: action("toggleSplitZoom"))
    record("grid-unzoom-yellow", lambda: action("toggleSplitZoom"))
    focus_by("focusUp", "focusRight")
    record("grid-zoom-magenta", lambda: action("toggleSplitZoom"))
    record("grid-unzoom-magenta", lambda: action("toggleSplitZoom"))
    record("grid-zoom-then-close-magenta", then_close, seconds=1.6)


def strip():
    first_terminal("red")
    for color in ("green", "blue", "yellow"):
        before = panes()
        action("newColumn")
        settle(1.0)
        note(color, before)
        paint_terminal(color)
        settle(0.5)
    print("strip panes:", json.dumps(colors), flush=True)
    focus_by("focusLeft")  # the blue column, mid-strip
    record("strip-zoom-blue", lambda: action("toggleSplitZoom"))
    record("strip-unzoom-blue", lambda: action("toggleSplitZoom"))
    record("strip-close-blue", lambda: action("closePane"))
    # A docked column at the left edge, from a new tab of the focused column.
    before = panes()
    action("newSurface")
    settle(0.6)
    paint_terminal("purple")
    settle(0.4)
    print("dock", json.dumps(rpc("action.run", {"action": "tab.moveToNewDockColumn", "args": {"edge": "left"}}))[:160], flush=True)
    settle(1.2)
    note("purple", before)
    print("strip+dock panes:", json.dumps(colors), flush=True)
    # The focus moves to a strip column (right of the dock).
    focus_by("focusRight")
    record("dock-zoom", lambda: action("toggleSplitZoom"))
    record("dock-unzoom", lambda: action("toggleSplitZoom"))


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
        for layout in (row, grid, strip):
            layout()
    finally:
        if opts.reduce_motion:
            rpc("debug.motion", {"action": "reduce", "value": None})
        with open(os.path.join(opts.out, "colors.json"), "w") as handle:
            json.dump(colors, handle)
    print("\nRESULT PASS (recorded)")


main()
