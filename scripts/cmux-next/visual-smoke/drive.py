#!/usr/bin/env python3
"""Drive a running signed cmux NEXT app into the nightly visual smoke's scenes and
capture its window in each (smoke-signed-app-cli.sh --visual OUT runs it).

Release control socket only (no debug.* method), like the canary checks:

  home        `home.show`: the sidebar and the Home composer.
  composer    `palette.newAgentChat`: a new agent chat's composer.
  transcript  a test-agent session with one answered turn (the canary's
              agent_turn, in the app's own acpmux), opened with
              `agent.openSessionWorkspace`: the chat's transcript.

Each capture is the app's largest on-screen window alone (`screencapture -l`,
its CGWindowID from the window list), so the menu bar, the Dock and a system
dialog over the window never reach the judge (visual_check.py).

  drive.py --socket S --pid PID --acpmux-home H --harness ID --cwd DIR --out DIR

Writes OUT/<scene>.png and OUT/drive.json. Exits 1 when a scene could not be
reached; the scenes it did reach are still captured for the artifact.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("canary_checks", os.path.join(HERE, "..", "signed-app-canary-checks.py"))
canary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canary)
Client = canary.Client
Failed = canary.Failed

# The app's largest normal-layer window that is on screen, by owner pid. Bounds and ids need
# no Screen Recording grant (only window titles do).
WINDOW_JXA = r'''
ObjC.import("CoreGraphics");
function run(argv) {
  var pid = parseInt(argv[0], 10);
  var info = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))) || [];
  var best = null;
  info.forEach(function (w) {
    if (w.kCGWindowOwnerPID !== pid || w.kCGWindowLayer !== 0) return;
    var b = w.kCGWindowBounds, area = b.Width * b.Height;
    if (!best || area > best.area) best = {id: w.kCGWindowNumber, area: area, bounds: b};
  });
  return JSON.stringify(best);
}
'''


def app_window(pid):
    run = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOW_JXA, str(pid)],
                         capture_output=True, text=True, timeout=30)
    if run.returncode != 0:
        raise Failed(f"window list: osascript exited {run.returncode}: {run.stderr.strip()[-300:]}")
    return json.loads(run.stdout.strip() or "null")


def capture(pid, path):
    """The app's window alone as a PNG at path; the window's bounds."""
    window = app_window(pid)
    if not window:
        raise Failed(f"pid {pid} has no on-screen window to capture")
    run = subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-t", "png", "-l", str(window["id"]), path],
                         capture_output=True, text=True, timeout=60)
    if run.returncode != 0 or not os.path.exists(path) or os.path.getsize(path) == 0:
        raise Failed(f"screencapture -l {window['id']} exited {run.returncode}: {run.stderr.strip()[-300:]}")
    return window["bounds"]


def act(socket_path, action, **args):
    params = {"action": action, "focus": True}
    if args:
        params["args"] = args
    reply = Client(socket_path, timeout=60).call("action.run", params)
    if reply.get("ok") is False or "error" in reply:
        raise Failed(f"action.run {action}: {json.dumps(reply.get('error'))[:400]}")
    return reply.get("result") or {}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--acpmux-home", required=True)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--settle", type=float, default=4, help="seconds a scene gets to paint before its capture")
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    log = {"scenes": {}}

    def scene(name, reach):
        """Reach the scene, let it paint, capture it; record the outcome."""
        entry = log["scenes"][name] = {}
        try:
            entry["reached"] = reach()
            time.sleep(args.settle)  # a fixed paint allowance, not a poll
            entry["bounds"] = capture(args.pid, os.path.join(args.out, f"{name}.png"))
            entry["ok"] = True
            print(f"ok: {name} captured {entry['bounds']}")
        except (Failed, OSError, ValueError, subprocess.TimeoutExpired) as error:
            entry.update(ok=False, error=str(error))
            print(f"FAIL: {name}: {error}", file=sys.stderr)

    try:
        window = canary.wait(lambda: canary.visible_window(args.socket), args.timeout)
    except (Failed, OSError, ValueError) as error:
        print(f"FAIL: snapshot.get: {error}", file=sys.stderr)
        window = None
    log["window"] = window
    if not window:
        print(f"FAIL: no visible window within {args.timeout:.0f}s", file=sys.stderr)
    else:
        scene("home", lambda: act(args.socket, "home.show"))

        def new_chat():
            before = canary.tabs(canary.snapshot(args.socket))
            run = act(args.socket, "palette.newAgentChat")
            if not canary.wait(lambda: set(canary.tabs(canary.snapshot(args.socket))) - set(before), 20):
                raise Failed("palette.newAgentChat ran but no new tab is in snapshot.get")
            return run
        scene("composer", new_chat)

        def transcript():
            session = canary.agent_turn(args.acpmux_home, args.harness, args.cwd, args.timeout)
            run = act(args.socket, "agent.openSessionWorkspace", session=session)
            shown = canary.wait(lambda: next((t for t in canary.tabs(canary.snapshot(args.socket)).values()
                                              if t.get("agent_session") == session), None), 30)
            if not shown:
                raise Failed(f"agent.openSessionWorkspace ran but no tab shows session {session}")
            return {"session": session, "run": run, "tab": shown.get("id")}
        scene("transcript", transcript)

    ok = bool(window) and all(s.get("ok") for s in log["scenes"].values())
    if not ok:
        # The whole display, for what stood in the way (no window, a dialog, a crash).
        subprocess.run(["/usr/sbin/screencapture", "-x", "-t", "png", os.path.join(args.out, "screen.png")],
                       capture_output=True, timeout=60)
    with open(os.path.join(args.out, "drive.json"), "w") as f:
        json.dump(log, f, indent=1, default=str)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
