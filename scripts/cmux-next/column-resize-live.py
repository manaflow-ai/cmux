#!/usr/bin/env python3
"""cx-ww20 live proof on the GUI host: column-edge drag, strip scroll under a
still pointer, divider hover, recorded frame by frame.

  column-resize-live.py --tag <tag> --out DIR

Launches the tagged app (no activation, automation socket, own config),
makes three columns (terminal, terminal + New Tab page tab, New Tab page) so
the strip overflows, then while `debug.window_record` records every display
frame: drags the first column edge right in paced steps (samples the edge
after each step), puts the synthesized pointer on a divider, scrolls the
strip with a trackpad gesture under it, holds still, and leaves. Writes
frames, samples.json and app.log to DIR. Kills only the app it started.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def layers():
    result = rpc("debug.layers")
    return ((result or {}).get("windows") or [{}])[0] if isinstance(result, dict) else {}


def window_height(layer):
    frame = layer.get("frame") or [0, 0, 0, 720]
    return frame[3]


def areas(layer):
    """Vertical divider areas (column edges and splits) as (x_mid, y_mid_top, rect), left to right."""
    height = window_height(layer)
    result = []
    for x, y, w, h in layer.get("divider_areas_in_window") or []:
        if h > w:
            result.append((x + w / 2, height - (y + h / 2), [x, y, w, h]))
    return sorted(result)


def mouse(**params):
    return rpc("debug.mouse", params)


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,760"}
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"pid": app.pid, "steps": [], "notes": []}
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("app did not come up")
    time.sleep(2)
    report["focus_before"] = rpc("debug.focus")
    report["new_workspace"] = rpc("action.run", {"action": "newTab", "focus": True})
    time.sleep(3)
    report["focus_workspace"] = rpc("debug.focus")
    def focused_pane():
        windows = (rpc("debug.focus") or {}).get("windows") or [{}]
        return windows[0].get("layout_focused_pane")

    def run(action):
        pane = focused_pane()
        reply = rpc("action.run", {"action": action, "focus": True, "target": f"pane:{pane}" if pane else None})
        time.sleep(1.5)
        return {"pane": pane, "reply": reply}

    def run_on(action, pane):
        reply = rpc("action.run", {"action": action, "focus": False, "target": f"pane:{pane}"})
        time.sleep(1.0)
        return reply

    first = focused_pane()
    report["new_column_1"] = run("newColumn")
    second = focused_pane()
    report["new_tab_page_1"] = run("newTab.page")
    report["new_column_2"] = run("newColumn")
    third = focused_pane()
    report["new_tab_page_2"] = run("newTab.page")
    report["panes"] = [first, second, third]
    report["widths"] = [run_on("column.widthOneThird", first), run_on("column.widthHalf", second),
                        run_on("column.widthHalf", third)]
    # Focus the middle column (right of the edge that is dragged), as in Lawrence's recording.
    report["focus_middle"] = rpc("action.run", {"action": "column.focusLeft", "focus": True, "target": f"pane:{third}"})
    time.sleep(1.0)
    report["focused_before_drag"] = focused_pane()
    time.sleep(4)
    layer = layers()
    report["layers_before"] = {k: layer.get(k) for k in ("frame", "divider_areas_in_window", "placement", "browsers")}
    edges = areas(layer)
    if not edges:
        with open(os.path.join(opts.out, "samples.json"), "w") as f:
            json.dump(report, f, indent=1)
        sys.exit(f"no divider areas: {json.dumps({k: report.get(k) for k in ('focus_before', 'new_workspace', 'focus_workspace', 'new_column_1', 'new_tab_page_1')})[:2500]}")
    frames_dir = os.path.join(opts.out, "frames")
    report["record"] = rpc("debug.window_record", {"dir": frames_dir, "seconds": 8})
    time.sleep(0.3)

    # 1. Drag the first edge right, 30 paced steps of 6 pt.
    x0, y0, _ = edges[0]
    report["drag_down"] = mouse(action="down", x=x0, y=y0)
    for step in range(1, 31):
        x = x0 + step * 6
        mouse(action="drag", x=x - 6, y=y0, to_x=x, to_y=y0, steps=1, press=False, release=False)
        time.sleep(1 / 60)
        sample = areas(layers())
        report["steps"].append({"pointer_x": x, "edges_x": [round(e[0], 1) for e in sample]})
    mouse(action="up", x=x0 + 180, y=y0)
    time.sleep(0.6)

    # 2. Pointer still on a divider; the strip then scrolls under it (a focus
    #    change reveals the last column: the real scroll path, no mouse event).
    edges = areas(layers())
    hover_x, hover_y, _ = edges[-1]
    report["hover_point"] = [hover_x, hover_y]
    report["hover"] = mouse(action="hover", x=hover_x, y=hover_y)
    time.sleep(0.6)
    report["snap_hovered"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "hovered.png")})
    report["reveal"] = rpc("action.run", {"action": "column.focusRight", "focus": True, "target": f"pane:{focused_pane()}"})
    time.sleep(1.5)
    report["after_scroll_edges_x"] = [round(e[0], 1) for e in areas(layers())]
    report["snap_after_scroll"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "after-scroll.png")})
    time.sleep(0.5)
    report["after_settle_edges_x"] = [round(e[0], 1) for e in areas(layers())]
    mouse(action="leave")
    time.sleep(3)
    report["layers_after"] = {k: layer.get(k) for k in ("divider_areas_in_window", "browsers")}
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
with open(os.path.join(opts.out, "samples.json"), "w") as f:
    json.dump(report, f, indent=1)
print(json.dumps({k: report.get(k) for k in ("record", "hover_point", "after_scroll_edges_x", "after_settle_edges_x")})[:1500])
print("steps:", json.dumps(report["steps"][:3]), "...", json.dumps(report["steps"][-2:]))
