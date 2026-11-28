#!/usr/bin/env python3
"""Live check: the browser toolbar shows only the essentials by default (cx-d0d.81).

  scripts/cmux-next/browser-toolbar-default-live.py --tag <tag> [--out DIR] [--app PATH] [--no-checks]

Launches the tagged app (no activation, automation socket, its own cmux.json), opens a WebKit tab
and reads `debug.extensions.toolbar`:

  1. the default toolbar shows Back, Forward, Reload, the address bar and More, and no other
     button (the media hub, zoom and Downloads have nothing to show on a fresh page, and no
     extension is pinned, so the Extensions button is hidden);
  2. `browser.toolbarButtons` naming every button (written to cmux.json) shows Favorites, design
     mode, the profile, the theme and DevTools in every toolbar;
  3. removing the key returns to the default.

Snapshots of each state in light and dark (`debug.window_snapshot`) go to --out. `--no-checks`
only takes the snapshots (a build from before the change). GUI host only. Exits 1 when a check
fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
parser.add_argument("--socket", help="attach to the app serving this automation socket instead of launching one")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-toolbar-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--no-checks", action="store_true", help="snapshots only")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
if not opts.socket and not opts.tag:
    parser.error("--tag or --socket is required")
SOCKET = opts.socket or f"/tmp/cmux-debug-{opts.tag}.sock"
URL = "https://example.com/"
failures = []


def check(ok, what):
    if opts.no_checks:
        print("note " + what, flush=True)
        return
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
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
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": {"code": "socket", "message": str(error)}}


def rpc(method, params=None):
    reply = call(method, params)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    if not value:
        check(False, f"timed out: {what}")
    return value


def windows():
    report = rpc("debug.focus") or {}
    return report.get("windows") or [] if isinstance(report, dict) else []


def toolbar():
    reply = rpc("debug.extensions.toolbar") or {}
    return reply if isinstance(reply, dict) else {}


def buttons():
    """The trailing buttons shown now, by raw value."""
    return sorted(key.split(":", 1)[1] for key in (toolbar().get("frames") or {}) if key.startswith("button:"))


def write_config(text):
    # Whole-file replace, so the config watcher never reads a half-written file.
    with open(CONFIG + ".tmp", "w") as f:
        f.write(text)
    os.replace(CONFIG + ".tmp", CONFIG)


def snapshot(name):
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        path = os.path.join(opts.out, f"{name}-{mode}.png")
        rpc("debug.window_snapshot", {"path": path})
        print(f"snapshot {path} {os.path.exists(path)}", flush=True)
    rpc("debug.appearance", {"mode": "system"})


app = teardown = None
CONFIG = None
if not opts.socket:
    APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
    if not APP:
        sys.exit(f"no tagged app for {opts.tag}")
    with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
        BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
    SCRATCH = tempfile.mkdtemp(prefix=f"browser-toolbar-{opts.tag}-")
    CONFIG = os.path.join(SCRATCH, "cmux.json")
    with open(CONFIG, "w") as f:
        f.write("{}\n")
    teardown = TagTeardown(APP)
    teardown.install()
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
        "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
        stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)

ALL = ["media", "zoom", "favorites", "downloads", "designMode", "profile", "theme", "devTools"]
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait_for(lambda: windows(), "a window", 60)
    print("open a WebKit tab", rpc("action.run", {"action": "openBrowser.webkit", "args": {"url": URL}, "focus": True}), flush=True)
    wait_for(lambda: "omnibar" in (toolbar().get("frames") or {}), "a browser toolbar", 90)
    report = toolbar()
    print("default toolbar", json.dumps(report.get("frames")), flush=True)
    check(buttons() == ["overflow"], f"default: only More after the address bar: {buttons()}")
    check(not report.get("shows_extensions_button"), "default: no Extensions button with no pinned extension")
    check(all(k in report.get("frames", {}) for k in ("back", "forward", "reload", "omnibar")), "default: Back, Forward, Reload and the address bar")
    snapshot("default")

    if CONFIG:
        write_config(json.dumps({"browser": {"toolbarButtons": ALL}}) + "\n")
        pinned = quiet_wait(lambda: "favorites" in buttons() and buttons(), 20) or buttons()
        check({"favorites", "designMode", "profile", "theme", "devTools", "overflow"} <= set(pinned),
              f"every button pinned shows (media, zoom and Downloads only with content): {pinned}")
        snapshot("all-pinned")
        write_config("{}\n")
        back = quiet_wait(lambda: buttons() == ["overflow"] and buttons(), 20) or buttons()
        check(back == ["overflow"], f"removing the key returns to the default: {back}")
finally:
    if app:
        rpc("debug.quit", {"fixture_quit": "end-sessions"})
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()  # the exact PID this script started
            app.wait()
        teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
