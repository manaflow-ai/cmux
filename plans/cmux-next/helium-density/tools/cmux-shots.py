#!/usr/bin/env python3
"""cmux's browser chrome at every density, light and dark, for the Helium comparison (a1169, 2026-11-13).

A workspace with the docked Chief (Home, its tools in the tab row) on the left and a terminal | browser split,
example.com in the browser, then per density and appearance a window snapshot (debug.window_snapshot, 2x).
Run on cmux-lawrence-2 against an app already running on SOCKET:

  cmux-shots.py --socket /tmp/....sock --cli PATH/TO/cmux --out DIR
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--cli", required=True)
parser.add_argument("--densities", default="compact,cozy,comfortable,spacious")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def windows():
    report = rpc("debug.focus") or {}
    return (report.get("windows") or []) if isinstance(report, dict) else []


def cli(*args):
    env = dict(os.environ, CMUX_SOCKET_PATH=opts.socket)
    for key in [k for k in env if k.startswith("CMUX_") and k != "CMUX_SOCKET_PATH"]:
        env.pop(key)
    run = subprocess.run([opts.cli, *args], capture_output=True, text=True, env=env, timeout=60)
    print("cli", args, run.returncode, run.stdout.strip()[:300], run.stderr.strip()[:300], flush=True)
    return run.stdout


if not wait(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 180):
    sys.exit("no app on the socket")
if not windows():
    rpc("action.run", {"action": "newWindow", "origin": "script"})
window = (wait(windows, 60) or [{}])[0].get("id")
print("window", window, flush=True)
WS = f"Density{os.getpid()}"
cli("workspace", "create", "--name", WS, "--focus")
time.sleep(2)
panes = json.loads(cli("--json", "pane", "list", "--workspace", f"name:{WS}") or "[]")
items = panes if isinstance(panes, list) else (panes.get("items") or panes.get("panes") or [])
pane = items[0].get("id") if items else None
cli("pane", pane, "split", "--right", "--focus")
time.sleep(2)
cli("tab", "create", "browser", "--url", "https://example.com", "--name", f"Ex{os.getpid()}")
time.sleep(5)
cli("tab", f"name:Ex{os.getpid()}", "focus")
print("dock", rpc("action.run", {"action": "home.openChiefDock", "origin": "script"}), flush=True)
time.sleep(4)
# The user's state (msg 31502): the dock's own tab bar shown, so its strip shares the row with Home's tools.
print("dock tab bar", rpc("action.run", {"action": "window.toggleDockTabBar", "origin": "script"}), flush=True)
time.sleep(2)

TOUCHED = ("appearance.theme", "appearance.density")
saved = {path: rpc("settings.get", {"path": path}) or {} for path in TOUCHED}
failures = 0
try:
    for density in opts.densities.split(","):
        print("density", density, rpc("settings.set", {"path": "appearance.density", "value": density}), flush=True)
        for mode in ("dark", "light"):
            looks = rpc("debug.appearance", {"mode": mode})
            background = (looks or {}).get("terminal_background") if isinstance(looks, dict) else None
            if mode == "light" and isinstance(background, str) and background.startswith("#"):
                r, g, b = (int(background[i:i + 2], 16) for i in (1, 3, 5))
                if r + g + b < 384:
                    rpc("settings.set", {"path": "appearance.theme", "value": "Catppuccin Latte"})
            if mode == "dark" and saved["appearance.theme"].get("exists"):
                rpc("settings.set", {"path": "appearance.theme", "value": saved["appearance.theme"].get("value")})
            elif mode == "dark":
                rpc("settings.unset", {"path": "appearance.theme"})
            time.sleep(1.5)  # proof capture only: the repaint lands before the capture
            name = f"{density}-{mode}"
            snap = rpc("debug.window_snapshot", {"window": window, "path": os.path.join(opts.out, f"{name}.png")})
            print("snapshot", name, snap, flush=True)
            bar = rpc("debug.omnibar", {"window": window})
            with open(os.path.join(opts.out, f"{name}.json"), "w") as f:
                json.dump({"density": density, "mode": mode, "omnibar": bar, "snapshot": snap}, f, indent=1, default=str)
            if isinstance(snap, dict) and snap.get("error"):
                failures += 1
finally:
    for path, before in saved.items():
        if before.get("exists"):
            rpc("settings.set", {"path": path, "value": before.get("value")})
        else:
            rpc("settings.unset", {"path": path})
print(f"{failures} failure(s)")
sys.exit(1 if failures else 0)
