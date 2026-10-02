#!/usr/bin/env python3
"""Live check of cmux-next's default theme on a running tagged build.

The default is Ghostty's Apple System Colors (dark) / Apple System Colors
Light (light), following the appearance. The script switches only the
app's own appearance (debug.appearance, never the system setting) and
checks that Ghostty's applied config (the terminals) and the window chrome
follow, then restores the system appearance. Launch the tag with no Ghostty
theme of its own (CMUX_NEXT_GHOSTTY_CONFIG=<empty file>), or pass --expect
to check another theme's backgrounds.

Usage: default-theme-e2e.py --tag <tag> [--expect-dark #1E1E1E --expect-light #FEFFFF]
"""
import argparse, glob, json, os, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--expect-dark", default="#1E1E1E")
parser.add_argument("--expect-light", default="#FEFFFF")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/*.app/Contents/Resources/bin/cmux")))), None)
if not CLI:
    sys.exit(f"no tagged CLI for {opts.tag}")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}


def rpc(method, params=None):
    out = subprocess.run([CLI, "--socket", SOCKET, "rpc", method, json.dumps(params or {})],
                         capture_output=True, text=True, timeout=30, env=ENV).stdout
    return json.loads(out)


def state():
    themes = rpc("debug.themes")
    surfaces = [t["surface_scheme"] for t in themes["terminals"] if t.get("surface_theme") is None]
    return themes.get("ghostty_background"), [w["window_background"] for w in themes["windows"]], surfaces


def check(mode, expected, step=None):
    rpc("debug.appearance", {"mode": mode})
    if step:
        rpc("action.run", {"action": step})
    # The scheme change applies on the main thread; a reload answers through
    # Ghostty's CONFIG_CHANGE. Give the app a few turns (bounded).
    for _ in range(50):
        ghostty, windows, surfaces = state()
        if ghostty == expected and windows and all(w == expected for w in windows) and all(s == mode for s in surfaces):
            print(f"ok {mode}{' after ' + step if step else ''}: ghostty {ghostty}, windows {windows}, surfaces {surfaces}")
            return True
        time.sleep(0.1)
    print(f"FAIL {mode}{' after ' + step if step else ''}: ghostty {ghostty}, windows {windows}, surfaces {surfaces}, expected {expected}")
    return False


try:
    good = (check("dark", opts.expect_dark) & check("light", opts.expect_light) & check("dark", opts.expect_dark)
            # A config reload in dark mode keeps the dark variant.
            & check("dark", opts.expect_dark, step="reloadConfiguration"))
finally:
    rpc("debug.appearance", {"mode": "system"})
sys.exit(0 if good else 1)
