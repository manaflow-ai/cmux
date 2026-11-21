#!/usr/bin/env python3
"""Light and dark shots of every + button and its neighbours, at rest and hovered, at every density.

  scripts/cmux-next/plus-button-shots-live.py --app "$NX_APP" --tag "$NX_APP_TAG" [--out DIR]

GUI host only (cmux-lawrence-2, under nx-remote --needs gui --app-from-fleet); never on a laptop. Launches the
tagged app (no activation, automation socket, its own cmux.json), adds a second tab and a workspace group, then for
each density hovers, in turn, nothing (the window only), the tab bar's New Tab +, the sidebar's New Workspace + and
the group header (which reveals its +), and writes a crop of the sidebar's top and of the tab bar's trailing end,
light and dark, to --out. `debug.top_alignment` and `debug.pane_chrome` give the frames; each state's frames go to
frames.json. The user's 2026-11-15 ask ("make the new tab plus button the standard for all plus buttons") is the
Before/After this shows.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402
from safe_log import safe_print  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="plus-button-"))
parser.add_argument("--densities", default="ultraCompact,compact,cozy,comfortable")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"plus-button-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
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
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the live app's own state
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(0.25)
    return None


def write_config(density):
    with open(CONFIG + ".tmp", "w") as f:
        json.dump({"appearance": {"density": density}}, f)
    os.replace(CONFIG + ".tmp", CONFIG)


def chrome():
    report = rpc("debug.pane_chrome") or {}
    wins = report.get("windows") or [] if isinstance(report, dict) else []
    return wins[0] if wins else {}


def first_pane(report=None):
    found = sorted((report or chrome()).get("panes") or [], key=lambda p: p["strip"][0])
    return found[0] if found else {}


def top():
    report = rpc("debug.top_alignment")
    return report if isinstance(report, dict) else {}


def window_height():
    frame = rpc("debug.window_frame") or {}
    return (frame.get("frame") or [0, 0, 1200, 800])[3] if isinstance(frame, dict) else 800


def hover(point):
    """`point` is window top-left; the debug pointer takes window bottom-left."""
    if point is None:
        return rpc("debug.pointer_hover", {"point": None})
    return rpc("debug.pointer_hover", {"point": [point[0], window_height() - point[1]]})


def new_tab_point(pane, frames):
    """The tab bar's + center: the strip's own report when the build has it, else after the last tab."""
    if frames.get("new_tab"):
        x, y, w, h = frames["new_tab"]
        return [x + w / 2, y + h / 2]
    slots = pane.get("tab_slots") or []
    if not slots or not pane.get("strip"):
        return None
    sx, sy, sw, sh = pane["strip"]
    end = max(s[0] + s[1] for s in slots)
    side = (frames.get("plus") or [0, 0, 24, 24])[3]
    pill = pane.get("pill") or [sx, sy, 0, sh]
    return [sx + end + 4 + side / 2, pill[1] + pill[3] / 2]


def group_header_point(frames):
    """A point on the group header row: the first sidebar row above the topmost workspace row."""
    if frames.get("group_header"):
        x, y, w, h = frames["group_header"]
        return [x + w * 0.4, y + h / 2]
    row = frames.get("row")
    if not row:
        return None
    x, y, w, h = row
    return [x + w * 0.4, y - h / 2 - 2]


def crop(src, dst, rect, scale):
    x, y, w, h = rect
    subprocess.run(["sips", "-c", str(int(h * scale)), str(int(w * scale)), "--cropOffset", str(int(max(0, y) * scale)),
                    str(int(max(0, x) * scale)), src, "--out", dst],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def shoot(name, pane, frames, scale):
    sidebar = chrome().get("sidebar") or [0, 0, 240, 600]
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        time.sleep(0.8)  # capture harness: the theme repaints before the snapshot
        path = os.path.join(opts.out, f"{name}-{mode}.png")
        rpc("debug.window_snapshot", {"path": path})
        if os.path.exists(path):
            # The sidebar's top: its titlebar row (the +) and the first rows (the group header and its +).
            crop(path, os.path.join(opts.out, f"{name}-{mode}-sidebar.png"), [sidebar[0], 0, sidebar[2], 150], scale)
            if pane.get("strip"):
                sx, sy, sw, sh = pane["strip"]
                slots = pane.get("tab_slots") or [[0, 0]]
                end = sx + max(s[0] + s[1] for s in slots)
                left = max(sx, end - 160)
                crop(path, os.path.join(opts.out, f"{name}-{mode}-tabbar.png"), [left, sy - 4, 300, sh + 8], scale)
        safe_print("shot", path, os.path.exists(path), flush=True)
    rpc("debug.appearance", {"mode": "system"})


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
densities = [d for d in opts.densities.split(",") if d]
write_config(densities[0])
open(GHOSTTY, "w").write("")
teardown = TagTeardown(opts.app)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
    "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"),
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,640", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
safe_print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
report = {}
try:
    if not wait(lambda: os.path.exists(SOCKET) and first_pane(), 180):
        sys.exit("the tagged app did not come up")
    added = rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    safe_print("newTab", json.dumps(added)[:200], flush=True)
    wait(lambda: len((first_pane().get("tab_slots") or [])) >= 2, 15)
    group = rpc("action.run", {"action": "newWorkspaceGroup", "origin": "script"})
    safe_print("newWorkspaceGroup", json.dumps(group)[:200], flush=True)
    time.sleep(1.5)  # capture harness: the group's header row lands in the list
    for density in densities:
        write_config(density)
        time.sleep(1.5)  # capture harness: the config watcher applies the density
        win = chrome()
        scale = win.get("scale") or 2
        pane, frames = first_pane(win), top()
        sidebar = win.get("sidebar") or [0, 0, 240, 600]
        plus = frames.get("plus")
        states = {
            "rest": [sidebar[0] + sidebar[2] * 0.5, 300],  # inside the window, on the list: the hover reveals show
            "tab-plus": new_tab_point(pane, frames),
            "sidebar-plus": [plus[0] + plus[2] / 2, plus[1] + plus[3] / 2] if plus else None,
            "group-header": group_header_point(frames),
        }
        report[density] = {"frames": frames, "toolbar": pane.get("toolbar"), "pane": {k: pane.get(k) for k in ("strip", "pill", "tab_slots")},
                           "points": states}
        for state, point in states.items():
            if point is None:
                safe_print(density, state, "no point", flush=True)
                continue
            hover(point)
            time.sleep(0.7)  # capture harness: the hover fade ends
            shoot(f"{density}-{state}", pane, frames, scale)
        hover(None)
        safe_print(density, json.dumps(report[density], ensure_ascii=False)[:500], flush=True)
    with open(os.path.join(opts.out, "frames.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
finally:
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()
