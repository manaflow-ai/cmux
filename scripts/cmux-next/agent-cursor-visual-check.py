#!/usr/bin/env python3
"""Visual check of the agent cursor in a tagged DEBUG build (fleet GUI Mac
only, never a person's laptop). Drives debug.agent_cursor.demo step by step
against a real browser tab and prints each reply; the checker watches the
window (or records it) for: arrow shape and rotation along the glide, click
ripple, outline while paused, indicator at the tab chip when the tab is in
the background, removal on end, and the cursor below an NSAlert sheet.

  agent-cursor-visual-check.py --tag TAG --target TAB_ID [--pace 1.5] [--cli PATH]
"""
import argparse, glob, json, os, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--target", required=True, help="a browser tab id in the shown workspace")
parser.add_argument("--pace", type=float, default=1.5, help="seconds between steps (the checker's pace)")
parser.add_argument("--cli")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = opts.cli or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app/Contents/Resources/bin/cmux")))), None)
if not CLI:
    sys.exit(f"no tagged CLI for {opts.tag}; pass --cli")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET}

STEPS = [
    ("move", 80, 80, "cursor appears at the page's top-left area, arrow tip up-left"),
    ("click", 420, 260, "glides along a straight line, tip pointing along travel, ripple at the end"),
    ("click", 120, 480, "glides down-left, rotation follows the path, settles with a small spring"),
    ("pause", None, None, "arrow becomes an outline, stays still"),
    ("click", 600, 120, "no movement while paused"),
    ("resume", None, None, "arrow filled again"),
    ("click", 600, 120, "glides up-right"),
    ("end", None, None, "cursor removed"),
]

def rpc(params):
    r = subprocess.run([CLI, "--socket", SOCKET, "rpc", "debug.agent_cursor.demo", json.dumps(params)],
                       capture_output=True, text=True, timeout=30, env=ENV)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"error": (r.stdout + r.stderr).strip()}

for index, (action, x, y, expect) in enumerate(STEPS):
    params = {"action": action, "target": opts.target, "session": "visual-check"}
    if x is not None:
        params.update(x=x, y=y)
    reply = rpc(params)
    print(f"[{index}] {action} -> expect: {expect}")
    print("     " + json.dumps(reply.get("windows", reply))[:400])
    time.sleep(opts.pace)
print("Also check by hand: switch the tab to the background (indicator at its chip) and open an NSAlert sheet (cursor below it).")
