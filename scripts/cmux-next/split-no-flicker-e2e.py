#!/usr/bin/env python3
"""Live check that a split never flickers (cx-ry0y) on a running tagged cmux-next DEBUG build.

Cmd-D shows the new pane at once as a provisional pane (plans/cmux-next/remote-state-ownership.md
S3), which the daemon's pane replaces. The provisional pane must stay until then: a split that is
undone one turn before the daemon pane lands shows 1 -> 2 -> 1 -> 2 panes, a one-frame flash of
the unsplit pane.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. Each run opens a workspace (`action.run`), resets
`debug.layout_counters`, presses Cmd-D (or Cmd-Shift-D on a split pane) through `debug.key`, and
reads the pane counts the workspace view showed (`pane_count_changes`): they may only grow. It
never launches or quits the app.

Usage: split-no-flicker-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--runs N]
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--runs", type=int, default=6)
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
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
        return {"error": str(error)}


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def strips():
    windows = (rpc("debug.windows") or {}).get("windows") or []
    first = windows[0].get("id") if windows else None
    return [s for s in (rpc("debug.tab_drag") or {}).get("strips") or [] if first is None or s.get("window") == first]


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def split(modifiers, panes):
    """Resets the counters, presses d with `modifiers` and returns the pane counts shown."""
    rpc("debug.layout_counters", {"reset": True})
    print("split:", rpc("debug.key", {"key": "d", "modifiers": modifiers}), flush=True)
    wait(lambda: len(strips()) == panes, 10)
    time.sleep(1.5)  # test harness: the daemon pane has replaced the provisional one
    return (rpc("debug.layout_counters") or {}).get("pane_count_changes")


def grows(counts):
    return bool(counts) and all(b > a for a, b in zip(counts, counts[1:]))


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    if "error" in (rpc("debug.layout_counters") or {"error": True}):
        sys.exit("debug.layout_counters is missing: a DEBUG build is needed")
    right, down = [], []
    for _ in range(opts.runs):
        print("newTab (workspace):", rpc("action.run", {"action": "newTab", "args": {}, "focus": True}), flush=True)
        if not wait(lambda: len(strips()) == 1, 15):
            sys.exit(f"no single-pane workspace: {json.dumps(strips())[:600]}")
        time.sleep(1)  # test harness: the workspace settles
        right.append(split(["command"], 2))
        down.append(split(["command", "shift"], 3))
    row("Cmd-D never shows the unsplit pane again", f"pane counts only grow, in {opts.runs} runs",
        f"pane counts {right}", all(grows(c) and c[-1] == 2 for c in right))
    row("Cmd-Shift-D on a split pane never shows the pane unsplit again", f"pane counts only grow, in {opts.runs} runs",
        f"pane counts {down}", all(grows(c) and c[-1] == 3 for c in down))
    rpc("debug.window_snapshot", {"path": f"{opts.out}/split-no-flicker.png"})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
