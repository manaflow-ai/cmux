#!/usr/bin/env python3
"""Light and dark shots of a pane's tab bar trailing end at every density, over a terminal and chat pair.

  scripts/cmux-next/tab-bar-trailing-shots-live.py --app "$NX_APP" --tag "$NX_APP_TAG" [--out DIR]

GUI host only (cmux-lawrence-2, under nx-remote --needs gui --app-from-fleet); never on a laptop. Launches the
tagged app (no activation, automation socket, its own cmux.json), makes the first terminal report a Claude Code
session (`cmux agent hook emit`, as the agent's SessionStart hook does), so the terminal is half of a terminal and
chat pair (the case that drew the Toggle Terminal and Chat control), hovers the tab bar (which revealed the pane's
"…"), and for each density writes window snapshots and a crop of the tab bar, light and dark, to --out. It also
writes the pane toolbar's `debug.pane_chrome` report per density (its frame, buttons, and on builds that have it the
tab bar's right-click rows). The user's 2026-11-13 ask, "get rid of these buttons", is the Before/After this shows.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402
from safe_log import safe_print  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="tab-bar-trailing-"))
parser.add_argument("--densities", default="compact,cozy,comfortable,ultraCompact")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
SCRATCH = tempfile.mkdtemp(prefix=f"tab-bar-trailing-{opts.tag}-")
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


def write_config(density):
    with open(CONFIG + ".tmp", "w") as f:
        json.dump({"appearance": {"density": density}}, f)
    os.replace(CONFIG + ".tmp", CONFIG)


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


def shoot(name, pane):
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        time.sleep(0.8)  # capture harness: the theme repaints before the snapshot
        path = os.path.join(opts.out, f"{name}-{mode}.png")
        rpc("debug.window_snapshot", {"path": path})
        if os.path.exists(path) and pane:
            scale = chrome().get("scale") or 2
            sx, sy, sw, sh = pane["strip"]
            tool = (pane.get("toolbar") or {}).get("frame") or [sx + sw, sy, 0, sh]
            right = max(sx + sw, tool[0] + tool[2])
            left = sx  # the whole bar: its tabs, the + and whatever sits after them
            crop = os.path.join(opts.out, f"{name}-{mode}-tabbar.png")
            subprocess.run(["sips", "-c", str(int((max(sh, tool[3]) + 8) * scale)), str(int((right - left + 8) * scale)),
                            "--cropOffset", str(int(sy * scale)), str(int(left * scale)), path, "--out", crop],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
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
    terminal = wait(focused_terminal, 30)
    safe_print("terminal", terminal, flush=True)
    # A second tab, so the bar reads as a bar of tabs; the terminal stays the pair's half.
    pane_ids = ids("pane_")
    with open(os.path.join(opts.out, "snapshot.json"), "w") as f:
        json.dump({"snapshot": rpc("snapshot.get"), "surfaces": rpc("debug.surfaces")}, f, indent=1)
    added = rpc("action.run", {"action": "newTab", "origin": "script", "focus": True,
                               **({"target": f"pane:{pane_ids[0]}"} if pane_ids else {})})
    safe_print("panes", pane_ids, "newTab", json.dumps(added)[:200], flush=True)
    wait(lambda: len((first_pane().get("tab_slots") or [])) >= 2, 15)
    payload = json.dumps({"session_id": "5a7e5a7e-0000-4000-8000-0000000000aa", "prompt": "shot"})
    exe = os.environ.get("NX_APP_CLI") or "cmux"
    line = f"\"$(command -v cmux || echo '{exe}')\" agent hook emit --source claude --event SessionStart --payload-json '{payload}'"
    cli("terminal", terminal or "", "write", "--text", line + "\n")
    cli("agent", "hook", "emit", "--source", "claude", "--event", "SessionStart", "--terminal", terminal or "", "--payload-json", payload)
    time.sleep(3)  # capture harness: the hook's report reaches the tab and its toolbar
    for density in densities:
        write_config(density)
        time.sleep(1.5)  # capture harness: the config watcher applies the density
        pane = first_pane()
        hover_strip(pane)
        time.sleep(0.6)  # capture harness: the hover reveal's fade ends
        pane = first_pane()
        report[density] = pane.get("toolbar")
        safe_print(density, json.dumps(pane.get("toolbar"), ensure_ascii=False)[:600], flush=True)
        shoot(f"tabbar-{density}", pane)
        rpc("debug.pointer_hover", {"point": None})
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
