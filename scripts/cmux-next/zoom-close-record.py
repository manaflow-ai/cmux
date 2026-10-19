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
       [--video --app-pid PID] (a display video through the capture daemon, with Chromium pages)
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
parser.add_argument("--video", action="store_true", help="also record the display through the capture daemon (--cua-socket)")
parser.add_argument("--cua-socket", default=os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock"))
parser.add_argument("--app-pid", type=int, default=0, help="the app's pid, to find its window in the display video")
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


def paint_terminal(pane, color):
    """`pane`'s terminal background becomes `color` (OSC 11), the screen cleared."""
    text = "printf '\\033]11;#%s\\007'; clear\r" % COLORS[color].lstrip("#")
    reply = action("terminal.sendText", target=f"pane:{pane}", args={"text": text})
    if isinstance(reply, dict) and reply.get("error"):
        # A pane that opened on a New Tab page: a terminal tab first.
        action("newSurface", target=f"pane:{pane}")
        settle(0.8)
        reply = action("terminal.sendText", target=f"pane:{pane}", args={"text": text})
    print("paint", color, json.dumps(reply)[:140], flush=True)


def new_pane(before, color):
    known = {p["pane"] for p in before}
    created = [p["pane"] for p in panes() if p["pane"] not in known]
    if not created:
        return None
    colors[created[0]], ids[color] = color, created[0]
    return created[0]


def fill(pane, color, engine=None):
    if engine:
        reply = rpc("action.run", {"action": f"openBrowser.{engine}", "target": f"pane:{pane}", "args": {"url": BASE + color}}, timeout=90)
        print("open", engine, color, json.dumps(reply)[:160], flush=True)
        settle(3.0 if engine == "chromium" else 1.5)
    else:
        paint_terminal(pane, color)
        settle(0.6)


def focus(color):
    reply = action("pane.focus", target=f"pane:{ids[color]}")
    settle(0.5)
    return reply


def split(of, direction, color, engine=None):
    focus(of)
    before = panes()
    action("splitRight" if direction == "right" else "splitDown")
    settle(1.0)
    pane = new_pane(before, color)
    if pane:
        fill(pane, color, engine)
    else:
        print("split: no new pane for", color, flush=True)
    return pane


def first_terminal(color):
    ids.clear()
    before = panes()
    action("workspace.newAtBottom")
    settle(1.2)
    pane = new_pane(before, color)
    if not pane:
        shown = panes()
        if len(shown) == 1:
            pane = shown[0]["pane"]
            colors[pane], ids[color] = color, pane
    if pane:
        fill(pane, color)


def window_on_screen():
    """The app's window in screen points (top-left origin) and the main display's size, from the capture daemon."""
    listed = cua("list_windows", {"pid": opts.app_pid, "on_screen_only": True}) if opts.app_pid else {}
    windows = (((listed.get("result") or {}).get("structuredContent") or {}).get("windows")) or []
    windows = [w for w in windows if (w.get("bounds") or {}).get("width", 0) > 400]
    size = cua("get_screen_size", {})
    return {"window": max(windows, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"]) if windows else None,
            "screen": (size.get("result") or {}).get("structuredContent")}


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
    video = None
    if opts.video:
        video = os.path.realpath(os.path.join(directory, "video"))
        os.makedirs(video, exist_ok=True)
        with open(os.path.join(directory, "screen.json"), "w") as handle:
            json.dump(window_on_screen(), handle)
        started_video = cua("start_recording", {"output_dir": video, "record_video": True})
        print(name, "video", json.dumps(started_video)[:160], flush=True)
        settle(0.4)
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
        settle(1.0)
        pane = new_pane(before, color)
        if pane:
            fill(pane, color)
    print("strip panes:", json.dumps(ids), flush=True)
    zoom_pair("strip", "blue")
    focus("blue")
    record("strip-close-blue", lambda: action("closePane"))
    # A docked column at the left edge, from a new terminal tab of the green column.
    focus("green")
    before = panes()
    action("newSurface", target=f"pane:{ids['green']}")
    settle(0.8)
    paint_terminal(ids["green"], "purple")
    settle(0.4)
    print("dock", json.dumps(rpc("action.run", {"action": "tab.moveToNewDockColumn", "args": {"edge": "left"}}))[:160], flush=True)
    settle(1.2)
    new_pane(before, "purple")
    print("strip+dock panes:", json.dumps(ids), flush=True)
    zoom_pair("dock", "yellow")


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
