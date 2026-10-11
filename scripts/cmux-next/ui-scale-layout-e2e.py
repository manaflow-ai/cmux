#!/usr/bin/env python3
"""Live check that stepping the interface scale keeps the app running (cx-wcej) on a running tagged
cmux-next build.

The palette panel lays out at the new scale on every step, even while hidden. At some scales its
rows used to get fractional label frames that the window's layout engine rounded, and each
rounding asked the row for another layout pass. AppKit then threw "more Layout Window passes
than there are views in the window" and the app died. The script walks `appearance.uiScale`
down, across the whole range up, and back down, once holding each step for a second and once
without a pause, and checks after every step that the app still answers. The loop depended on
font metrics at each scale, so it did not trap on every walk; `--walks` repeats the walk. A
passing run is not proof that a build is free of it; a failing run is. Each step writes
`app.uiScale` to the build's settings file, so run it only against a disposable tagged build
whose settings file is its own (a capture slot's); it resets the scale when it exits.

It attaches to an app already running (a capture slot's `capture-host launch`, or a tagged
build) through its debug socket. It never launches or quits the app.

Usage: ui-scale-layout-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--walks 3] [--gap 1.0]
Exit status 0 when the app answered after every step.
"""
import argparse, json, re, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--walks", type=int, default=3)
parser.add_argument("--gap", type=float, default=1.0, help="seconds to hold each step on the slow pass")
opts = parser.parse_args()


def rpc(method, params=None, timeout=20):
    """One line-JSON request on the app's control socket; an error dict when it does not answer."""
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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error), "unreachable": True}


def alive():
    for _ in range(3):
        if (rpc("debug.windows", timeout=10) or {}).get("windows") is not None:
            return True
        time.sleep(2)  # test harness: a busy main thread may answer late
    return False


def main():
    if not re.search(r"/cmux-debug-[\w.-]+\.sock$", opts.socket):
        sys.exit("refusing: only a tagged debug socket (/tmp/cmux-debug-<tag>[-capslot<N>].sock)")
    if not alive():
        sys.exit("FAIL the app does not answer on the socket")
    try:
        walk_scales()
    finally:
        rpc("action.run", {"action": "appearance.uiScale.reset"})
    print("PASS", flush=True)


def walk_scales():
    steps = (("appearance.uiScale.decrease", 4), ("appearance.uiScale.increase", 14), ("appearance.uiScale.decrease", 14))
    for walk in range(1, opts.walks + 1):
        rpc("action.run", {"action": "appearance.uiScale.reset"})
        time.sleep(1)  # test harness: let the reset lay out before the walk
        for gap in (opts.gap, 0.0):
            for action, count in steps:
                for step in range(1, count + 1):
                    reply = rpc("action.run", {"action": action})
                    time.sleep(gap)  # test harness: hold each scale for the gap
                    if not alive():
                        print(f"FAIL walk {walk} gap={gap} {action} step {step}: the app stopped answering", flush=True)
                        sys.exit(1)
                    if isinstance(reply, dict) and reply.get("error") and not reply.get("unreachable"):
                        code = reply["error"].get("code") if isinstance(reply["error"], dict) else reply["error"]
                        print(f"note walk {walk} {action} step {step}: {code}", flush=True)
            print(f"ok walk {walk} gap={gap}", flush=True)


main()
