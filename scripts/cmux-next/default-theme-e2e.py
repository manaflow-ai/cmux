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
    return themes.get("ghostty_background"), [w["window_background"] for w in themes["windows"]]


def check(mode, expected):
    rpc("debug.appearance", {"mode": mode})
    # Ghostty applies the color scheme on its next config change; give the
    # main thread a few turns (bounded).
    for _ in range(50):
        ghostty, windows = state()
        if ghostty == expected and windows and all(w == expected for w in windows):
            print(f"ok {mode}: ghostty {ghostty}, windows {windows}")
            return True
        time.sleep(0.1)
    print(f"FAIL {mode}: ghostty {ghostty}, windows {windows}, expected {expected}")
    return False


try:
    good = check("dark", opts.expect_dark) & check("light", opts.expect_light) & check("dark", opts.expect_dark)
finally:
    rpc("debug.appearance", {"mode": "system"})
sys.exit(0 if good else 1)
