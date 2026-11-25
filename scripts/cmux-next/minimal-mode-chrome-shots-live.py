#!/usr/bin/env python3
"""Light and dark shots of the window chrome at rest and on hover, by default and in Minimal Mode.

  scripts/cmux-next/minimal-mode-chrome-shots-live.py --app "$NX_APP" --tag "$NX_APP_TAG" [--out DIR]

GUI host only (cmux-lawrence-2, under nx-remote --needs gui --app-from-fleet); never on a laptop. Launches the
tagged app (no activation, automation socket, its own cmux.json with one pinned tab bar button, Split Right), adds a
second tab, and for each mode (`default`: no `sidebar.minimal`; `minimal`: `sidebar.minimal` true) writes window
snapshots, light and dark, with the pointer away (`rest`), over the sidebar (`hover-sidebar`) and over the tab bar
(`hover-tabbar`), plus a crop of the window's top rows. It writes the pane toolbar's `debug.pane_chrome` report per
state. `--cards` stages an update first, so the Restart to Update card shows (it must hide with the pointer away in
Minimal Mode, user 2026-11-17). The user's 2026-11-15 ask ("by default, all buttons should be visible, not fade into view on hover ... only
when minimal mode is enabled, we should hide the buttons ...") is the Before/After this shows.
"""
import argparse, hashlib, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402
from safe_log import safe_print  # noqa: E402
from state_wait import wait_stable  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="minimal-chrome-"))
parser.add_argument("--modes", default="default,minimal")
# Comma-separated `sidebar.density` values (Lawrence 2026-11-15: "minimal mode should not change density at all"):
# with it, each density is shot with Minimal Mode off and on, at rest, and the rows must match.
parser.add_argument("--densities", default="")
# Records the window (debug.window_record, a JPEG per display frame) in Minimal Mode while the pointer enters the
# sidebar and leaves it (Lawrence 2026-11-15, msg 34327: the footer's height goes to the list at rest, animated).
parser.add_argument("--record", action="store_true")
# Stages an update (the Restart to Update card) and fills the list before the shots (user 2026-11-17, msg 38388:
# "minimal mode should hide everything in sidebar including cards like update, iff user is not hovered in sidebar").
parser.add_argument("--cards", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
SCRATCH = tempfile.mkdtemp(prefix=f"minimal-chrome-{opts.tag}-")
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


def cli(*args):
    env = dict(os.environ, CMUX_TAG=opts.tag)
    done = subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=60)
    safe_print("cli", " ".join(args)[:120], "->", done.returncode, (done.stdout + done.stderr).strip()[-160:], flush=True)
    return done


def write_config(minimal, density=None):
    config = {"tabs": {"toolbarButtons": ["splitRight"]}}
    sidebar = {}
    if minimal:
        sidebar["minimal"] = True
    if density:
        sidebar["density"] = density
    if sidebar:
        config["sidebar"] = sidebar
    with open(CONFIG + ".tmp", "w") as f:
        json.dump(config, f)
    os.replace(CONFIG + ".tmp", CONFIG)


def settled(what, reads=4, interval=0.2, timeout=15):
    """The main window's snapshot is the same image `reads` times in a row: what changed came in and stopped moving.
    Best effort: a window still moving at the deadline is shot anyway."""
    probe = os.path.join(SCRATCH, "settle.png")

    def image():
        reply = rpc("debug.window_snapshot", {"path": probe})
        if (reply or {}).get("error") or not os.path.exists(probe):
            raise RuntimeError(f"no snapshot: {reply}")
        with open(probe, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        os.remove(probe)
        return digest

    if wait_stable(image, what, timeout=timeout, interval=interval, reads=reads, raise_on_timeout=False) is None:
        safe_print(f"note: no settled snapshot of {what} in {timeout} s", flush=True)


def config_applied(minimal, density=None):
    """The config watcher applied write_config's file (settings.get reads the app's values), then the window
    repainted and holds still."""
    def setting(path):
        return (rpc("settings.get", {"path": path}) or {}).get("value")
    applied = wait(lambda: (setting("sidebar.minimal") is True) == bool(minimal)
                   and (density is None or setting("sidebar.density") == density), 10)
    if not applied:
        safe_print(f"note: settings.get never showed sidebar.minimal={bool(minimal)} density={density} in 10 s", flush=True)
    settled(f"the window with minimal={bool(minimal)} density={density}")


def chrome():
    report = rpc("debug.pane_chrome") or {}
    wins = report.get("windows") or [] if isinstance(report, dict) else []
    return wins[0] if wins else {}


def first_pane():
    found = sorted(chrome().get("panes") or [], key=lambda p: p["strip"][0])
    return found[0] if found else {}


def ids(prefix):
    """Every `prefix…` id in the app's snapshot and surfaces reports, first seen first."""
    found = []

    def walk(value):
        if isinstance(value, dict):
            for v in value.values():
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)
        elif isinstance(value, str) and value.startswith(prefix) and value not in found:
            found.append(value)
    walk(rpc("snapshot.get"))
    walk(rpc("debug.surfaces"))
    return found


def focused_terminal():
    found = ids("term_")
    return found[0] if found else None


def window_height():
    frame = rpc("debug.window_frame") or {}
    return (frame.get("frame") or [0, 0, 1200, 800])[3] if isinstance(frame, dict) else 800


def hover_strip(pane):
    if not pane.get("strip"):
        return None
    x, y, w, h = pane["strip"]
    return rpc("debug.pointer_hover", {"point": [x + w * 0.45, window_height() - (y + h / 2)]})


def hover_sidebar():
    return rpc("debug.pointer_hover", {"point": [120, window_height() / 2]})


def shoot(name):
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        time.sleep(0.8)  # capture harness: the theme repaints before the snapshot
        path = os.path.join(opts.out, f"{name}-{mode}.png")
        rpc("debug.window_snapshot", {"path": path})
        if os.path.exists(path):
            scale = chrome().get("scale") or 2
            crop = os.path.join(opts.out, f"{name}-{mode}-top.png")
            subprocess.run(["sips", "-c", str(int(90 * scale)), str(int(1100 * scale)), "--cropOffset", "0", "0", path, "--out", crop],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        safe_print("shot", path, os.path.exists(path), flush=True)
    rpc("debug.appearance", {"mode": "system"})


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
modes = [m for m in opts.modes.split(",") if m]
densities = [d for d in opts.densities.split(",") if d]
write_config(modes[0] == "minimal", densities[0] if densities else None)
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
    terminal = wait(focused_terminal, 30)
    safe_print("terminal", terminal, flush=True)
    # A second tab, so the bar reads as a bar of tabs.
    pane_ids = ids("pane_")
    with open(os.path.join(opts.out, "snapshot.json"), "w") as f:
        json.dump({"snapshot": rpc("snapshot.get"), "surfaces": rpc("debug.surfaces")}, f, indent=1)
    added = rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    safe_print("panes", pane_ids, "newTab", json.dumps(added)[:200], flush=True)
    wait(lambda: len((first_pane().get("tab_slots") or [])) >= 2, 15)
    if opts.record:
        # Enough workspaces to fill the list to the footer, so the room the footer gives shows as more rows.
        for _ in range(20):
            rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"})
            time.sleep(0.3)  # capture harness: the new row settles
    if opts.cards:
        for _ in range(8):
            rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"})
            time.sleep(0.3)  # capture harness: the new row settles
        safe_print("stage", json.dumps(rpc("debug.updater", {"action": "stage", "version": "1.99.0"}))[:200], flush=True)
        settled("the update card's entrance")
    if densities:
        # A few workspaces and a group, so the list's row heights read in the shots.
        for name in ("workspace.newAtBottom", "workspace.newAtBottom", "workspace.newInNewGroup", "workspace.newBelow"):
            reply = rpc("action.run", {"action": name, "args": {}, "focus": False, "origin": "script"})
            safe_print(name, json.dumps(reply)[:160], flush=True)
            time.sleep(1.0)  # capture harness: the new row settles
        for density in densities:
            for mode in modes:
                write_config(mode == "minimal", density)
                config_applied(mode == "minimal", density)
                rpc("debug.pointer_hover", {"point": None})
                time.sleep(0.6)  # capture harness: the hover chrome's fade ends
                report[f"{density}-{mode}"] = first_pane().get("toolbar")
                shoot(f"{density}-{mode}-rest")
        modes = []
    for mode in modes:
        write_config(mode == "minimal")
        config_applied(mode == "minimal")
        for state in ("rest", "hover-sidebar", "hover-tabbar"):
            rpc("debug.pointer_hover", {"point": None})
            if state == "hover-sidebar":
                hover_sidebar()
            elif state == "hover-tabbar":
                hover_strip(first_pane())
            time.sleep(0.6)  # capture harness: the hover reveal's fade ends
            pane = first_pane()
            report[f"{mode}-{state}"] = pane.get("toolbar")
            safe_print(mode, state, json.dumps(pane.get("toolbar"), ensure_ascii=False)[:400], flush=True)
            shoot(f"{mode}-{state}")
        rpc("debug.pointer_hover", {"point": None})
    if opts.record:
        write_config(True)
        config_applied(True)
        for appearance in ("light", "dark"):
            rpc("debug.appearance", {"mode": appearance})
            rpc("debug.pointer_hover", {"point": None})
            time.sleep(0.8)  # capture harness: the theme repaints and the chrome settles at rest
            frames = os.path.join(opts.out, f"record-minimal-{appearance}")
            os.makedirs(frames, exist_ok=True)
            started = rpc("debug.window_record", {"dir": frames, "seconds": 3.2})
            time.sleep(0.5)  # capture harness: still frames at rest first
            hover_sidebar()
            time.sleep(1.2)  # capture harness: the reveal plays, then holds
            rpc("debug.pointer_hover", {"point": None})
            time.sleep(1.5 + 0.6)  # capture harness: the hide plays; the recording stops by itself
            count = len([f for f in os.listdir(frames) if f.endswith(".jpg")])
            safe_print("record", appearance, count, "frames", json.dumps(started)[:120], flush=True)
        rpc("debug.appearance", {"mode": "system"})
    with open(os.path.join(opts.out, "toolbar.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
finally:
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()
