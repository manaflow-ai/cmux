#!/usr/bin/env python3
"""Window snapshots of the sidebar spaces strip (cx-5k3r) on a no-activate tagged build.

For 1, 3 and 8 spaces (mixed names, colors, a symbol and an emoji icon) it
launches the tagged app once per look (dark or light theme, narrow or wide
sidebar, a background painting) and snapshots the window at rest and with
the pointer over the sidebar, then crops the sidebar's bottom strip. Prints
the strip's slot frames from `debug.sidebar_rows` when the app reports
them. Run on cmux-lawrence-2, never the laptop.

Usage: spaces-strip-shots.py --tag <tag> --label before|after [--out DIR]
"""
import argparse, glob, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--app", help="the tagged app (default: the tag's DerivedData build)")
parser.add_argument("--counts", default="1,3,8")
parser.add_argument("--looks", default="", help="comma-separated look names (default: all)")
parser.add_argument("--window-record", action="store_true",
                    help="only record hover reveal and space switches with debug.window_record (every display frame)")
parser.add_argument("--record", action="store_true", help="only record space switches (30 fps main display) and split frames")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/*.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix=f"spaces-{opts.tag}-")
# An isolated HOME: the run's spaces and daemon state never touch the tag's
# real state (a dogfood build of the same tag keeps its own).
HOME = os.path.join(SCRATCH, "home")
os.makedirs(HOME, exist_ok=True)
OUT = os.path.join(opts.out, opts.label)
os.makedirs(OUT, exist_ok=True)
THEMES = {
    "dark": "background = #1d1f21\nforeground = #c5c8c6\n",
    "light": "background = #fafafa\nforeground = #383a42\n",
}
LOOKS = [
    ("dark-wide", "dark", 300, None),
    ("dark-narrow", "dark", 180, None),
    ("light-wide", "light", 300, None),
    ("light-narrow", "light", 180, None),
    ("dark-painting", "dark", 240, "met-sunflowers-436524"),
    ("light-painting", "light", 240, "wheat-field-with-cypresses"),
]
SPACES = [("Work", "blue", None), ("Play", "green", "gamecontroller"), ("Ops", "red", None),
          ("Music", "purple", "🎵"), ("Reading", "orange", None), ("Admin", "cyan", None),
          ("Zeta", "yellow", None)]


CUA_SOCKET = os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock")


def cua(name, args):
    """One call to the shared agent capture helper (Screen Recording granted)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
        conn.connect(CUA_SOCKET)
        conn.sendall((json.dumps({"method": "call", "name": name, "args": args}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 16)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": str(error)}


def window_id(pid):
    reply = cua("list_windows", {"pid": pid})
    windows = ((reply.get("result") or {}).get("structuredContent") or {}).get("windows") or []
    windows = [w for w in windows if w.get("is_on_screen") and w.get("title")]
    return max(windows, key=lambda w: (w.get("bounds") or {}).get("width", 0)).get("window_id") if windows else None


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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


SESSION = []


def find_session():
    roots = glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-tui-*")) + glob.glob("/tmp/cmux-tui-*")
    tagged = [p for root in roots for p in glob.glob(os.path.join(root, "*.sock")) if opts.tag in os.path.basename(p)]
    if tagged:
        SESSION[:] = ["--socket", tagged[0]]


def cli(*args):
    env = {"HOME": HOME, "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    out = subprocess.run([CLI, *SESSION, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=env)
    return (out.stdout + out.stderr).strip()


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    sys.exit(f"FAIL {label}")


def launch(theme, width, painting, screen="last", always=True):
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    config, ghostty = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
    open(ghostty, "w").write(THEMES[theme])
    appearance = {"metrics": {"sidebarWidth": width}}
    if painting:
        appearance.update({"background": painting, "backgroundOpacity": 0.55})
    root = {"appearance": appearance}
    if always:
        # Shows the strip at rest so a window capture sees it (synthetic
        # pointer moves do not drive the sidebar's hover tracking area).
        root["sidebar"] = {"spacesVisibility": "always"}
    open(config, "w").write(json.dumps(root))
    env = {"HOME": HOME, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": screen, "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1000,640"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    try:
        # The first window may be the Home page (not listed as a surface window).
        wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and "windows" in (rpc("debug.surfaces") or {})
             and window_id(app.pid), 240)
    except SystemExit:
        stop(app)
        raise
    time.sleep(2)  # test harness: let the window settle
    find_session()
    return app


def stop(app):
    if app.poll() is None:
        app.terminate()
        try:
            app.wait(timeout=15)
        except subprocess.TimeoutExpired:
            app.kill()


def rooms():
    raw = cli("--json", "room", "list")
    try:
        value = json.loads(raw.splitlines()[-1]) if raw else []
    except ValueError:
        print("room list:", raw[:400], flush=True)
        return []
    if isinstance(value, dict):
        value = value.get("value") or value.get("rooms") or []
    return value if isinstance(value, list) else []


def set_space_count(count):
    """Keeps the first room (the default) and makes count - 1 more."""
    listed = rooms()
    for room in listed[1:]:
        cli("room", str(room.get("id") or room.get("name")), "delete")
    for name, color, icon in SPACES[:count - 1]:
        args = ["room", "create", "--name", name, "--color", color]
        if icon:
            args += ["--icon", icon]
        print("create:", cli(*args)[:200], flush=True)
    time.sleep(1)  # test harness: let the rooms reach the sidebar
    names = [r.get("name") for r in rooms()]
    print(f"rooms ({count}):", names, flush=True)
    if count >= 3:
        # Select the second space so the current one is not the leading dot.
        print("switch:", cli("action", "run", "space.switch", "--", "--room", names[1])[:200] if len(names) > 1 else "", flush=True)
        print("next:", cli("action", "run", "space.next")[:200], flush=True)


def sidebar_rect():
    report = rpc("debug.sidebar_rows") or {}
    for window in report.get("windows", []) if isinstance(report, dict) else []:
        if window.get("spaces"):
            print("spaces:", json.dumps(window["spaces"])[:600], flush=True)
        return window.get("sidebar_frame")
    return None


def shot(name, app):
    """A real pixel capture of the main window through the shared capture
    helper, plus the in-process snapshot (`-snap.png`) as a fallback."""
    path = os.path.join(OUT, name + ".png")
    snap = rpc("debug.window_snapshot", {"path": path.replace(".png", "-snap.png")}) or {}
    wid = (snap.get("window_number") if isinstance(snap, dict) else None) or window_id(app.pid)
    reply = cua("get_window_state", {"pid": app.pid, "window_id": wid, "max_elements": 1, "screenshot_out_file": path}) if wid else {}
    print(name, "window", wid, "helper:", "ok" if os.path.exists(path) else str(reply)[:300], flush=True)


def record():
    """Records three dot switches and two keyboard switches with 3 spaces."""
    app = launch("dark", 240, None)
    try:
        set_space_count(3)
    finally:
        stop(app)
    app = launch("dark", 240, None, screen="0")
    try:
        rec = os.path.join(OUT, "rec")
        os.makedirs(rec, exist_ok=True)
        print("start:", str(cua("start_recording", {"output_dir": rec, "record_video": True}))[:300], flush=True)
        time.sleep(1.0)  # test harness: lead-in frames
        rpc("debug.mouse", {"x": 60, "y": 300, "action": "move"})
        time.sleep(0.8)  # test harness: hover reveal settles
        for action in ("space.next", "space.next", "space.previous", "space.previous", "space.next"):
            print(action, cli("action", "run", action)[:120], flush=True)
            time.sleep(1.2)  # test harness: let the switch animation finish on video
        print("stop:", str(cua("stop_recording", {}))[:400], flush=True)
        video = os.path.join(rec, "recording.mp4")
        frames = os.path.join(rec, "frames")
        os.makedirs(frames, exist_ok=True)
        subprocess.run(["/opt/homebrew/bin/ffmpeg", "-loglevel", "error", "-i", video, os.path.join(frames, "%04d.png")], check=False)
        print("frames:", len(os.listdir(frames)), flush=True)
    finally:
        stop(app)


def window_record():
    """The hover reveal and two switches (default hover-only strip), every
    display frame of the window, from the app itself (debug.window_record)."""
    app = launch("dark", 240, None)
    try:
        set_space_count(3)
    finally:
        stop(app)
    app = launch("dark", 240, None, always=False)
    try:
        frames = os.path.join(OUT, "window-record")
        print("record:", rpc("debug.window_record", {"dir": frames, "seconds": 8}), flush=True)
        time.sleep(0.8)  # test harness: frames before the hover
        print("hover in:", rpc("debug.mouse", {"x": 100, "y": 300, "action": "hover"}), flush=True)
        time.sleep(1.2)  # test harness: the reveal fade finishes on the recording
        for action in ("space.next", "space.previous"):
            print(action, cli("action", "run", action)[:80], flush=True)
            time.sleep(1.6)  # test harness: the slide settles on the recording
        print("hover out:", rpc("debug.mouse", {"x": 700, "y": 300, "action": "hover"}), flush=True)
        time.sleep(2.0)  # test harness: the fade out, then the recording ends by itself
        print("frames:", len([f for f in os.listdir(frames) if f.endswith(".jpg")]) if os.path.isdir(frames) else 0, flush=True)
    finally:
        stop(app)


if opts.window_record:
    window_record()
    sys.exit(0)

if opts.record:
    record()
    sys.exit(0)


app = launch("dark", 240, None)
try:
    print("room help:", cli("room", "--help")[:300], flush=True)
finally:
    stop(app)

for count in [int(c) for c in opts.counts.split(",")]:
    app = launch("dark", 240, None)
    try:
        set_space_count(count)
    finally:
        stop(app)
    if not opts.looks or "default" in opts.looks.split(","):
        app = launch("dark", 240, None, always=False)
        try:
            shot(f"{count}-default-hover-only-rest", app)
        finally:
            stop(app)
    for look, theme, width, painting in LOOKS:
        if opts.looks and look not in opts.looks.split(","):
            continue
        app = launch(theme, width, painting)
        try:
            sidebar_rect()
            shot(f"{count}-{look}-rest", app)
            # Pointer over the sidebar (the hover reveal), then over the strip.
            rpc("debug.mouse", {"x": 60, "y": 300, "action": "move"})
            time.sleep(0.6)  # test harness: let the hover fade finish
            shot(f"{count}-{look}-hover", app)
        finally:
            stop(app)
print("shots in", OUT, flush=True)
