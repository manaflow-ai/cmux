#!/usr/bin/env python3
"""Live check that panes made by rapid splits and new browser splits stay (cmux#26695) on a running tagged cmux-next build.

User report (nightly): after making splits or new browsers, they disappear suddenly and the
workspace is left empty. The script presses Cmd-D (Split Right), Shift-Cmd-D (Split Down) and
Option-Cmd-D (Split Browser Right) as a person does (`debug.key`), several times faster than the
daemon answers, from a terminal and from a browser tab, then watches the window's strips
(`debug.tab_drag` `strips`) for several seconds. Every pane the presses made must stay: the pane
count never drops below the count the presses reached, and no strip goes empty.

The script attaches to an app already running (`nx-remote --app-from-fleet`, a capture slot or a
tagged build) through its debug socket. It never launches or quits the app.

Usage: rapid-split-keeps-panes-e2e.py --socket /tmp/cmux-debug-<tag>.sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--watch", type=float, default=8.0, help="seconds to watch the panes after the presses")
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


def action(name, args=None, focus=False):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": focus})


def key(name, *modifiers):
    return rpc("debug.key", {"key": name, "modifiers": list(modifiers)})


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
    """The first window's visible strips."""
    windows = (rpc("debug.windows") or {}).get("windows") or []
    first = windows[0].get("id") if windows else None
    return [s for s in (rpc("debug.tab_drag") or {}).get("strips") or [] if first is None or s.get("window") == first]


def labels(strip):
    return [t.get("label") for t in strip.get("tabs") or []]


def shape():
    return [labels(s) for s in strips()]


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def snapshot(name):
    path = os.path.join(opts.out, f"rapid-split-{name}.png")
    print("snapshot:", path, rpc("debug.window_snapshot", {"path": path}), flush=True)


def fresh_workspace():
    """A shown workspace with one pane holding one terminal."""
    print("newTab (workspace):", action("newTab", focus=True), flush=True)
    if not wait(lambda: len(strips()) == 1 and len(labels(strips()[0])) == 1, 15):
        sys.exit(f"no single-pane workspace: {json.dumps(strips())[:600]}")
    time.sleep(1)  # test harness: the strip settles


def burst(name, presses, gap):
    """Presses the keys `gap` seconds apart, then watches the strips for `opts.watch` seconds.
    Returns the timeline of (seconds, pane count, empty strips)."""
    start = time.time()
    timeline = []
    for index, (k, modifiers) in enumerate(presses):
        reply = key(k, *modifiers)
        if "error" in (reply or {}):
            print(f"press {index} {k}{modifiers}:", reply, flush=True)
        time.sleep(gap)  # key-repeat speed: the next press comes before the daemon answers this one
        s = strips()
        timeline.append((round(time.time() - start, 2), len(s), sum(1 for x in s if not labels(x))))
    snapshot(f"{name}-pressed")
    deadline = time.time() + opts.watch
    shots = 0
    while time.time() < deadline:
        s = strips()
        timeline.append((round(time.time() - start, 2), len(s), sum(1 for x in s if not labels(x))))
        if shots < 3 and time.time() - start > (shots + 1) * opts.watch / 3:
            snapshot(f"{name}-t{shots + 1}")
            shots += 1
        time.sleep(0.1)  # test harness sampling a live app
    snapshot(f"{name}-end")
    return timeline


def judge(name, timeline, expected_min):
    counts = [count for _, count, _ in timeline]
    peak = max(counts) if counts else 0
    final = counts[-1] if counts else 0
    # A drop after the peak is a pane that showed and left.
    drops = [(t, c) for (t, c, _) in timeline if c < peak and t >= next(t2 for t2, c2, _ in timeline if c2 == peak)]
    empties = [(t, e) for (t, _, e) in timeline if e]
    compact = []
    for t, c, e in timeline:
        if not compact or compact[-1][1:] != (c, e):
            compact.append((t, c, e))
    row(f"{name}: every pane the presses made stays",
        f"at least {expected_min} panes, never fewer than the peak, no empty strip",
        f"peak {peak}, final {final}, drops {drops[:5]}, empty {empties[:5]}, timeline {compact}, shape {shape()}",
        final >= expected_min and not drops and not empties and final == peak)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 90):
        sys.exit("the app does not answer on " + opts.socket)
    split_right, split_down, browser_right = ("d", ["command"]), ("d", ["command", "shift"]), ("d", ["command", "option"])

    # Terminal splits at key-repeat speed.
    fresh_workspace()
    judge("terminal splits", burst("terminal", [split_right, split_down, split_right, split_down], 0.05), 5)

    # Browser splits, then terminal splits from the new browser pane, interleaved.
    fresh_workspace()
    judge("browser splits", burst("browser", [browser_right, split_down, browser_right, split_right], 0.05), 5)

    # From a browser tab a person's split opens the New Tab page (cx-jfo7).
    fresh_workspace()
    print("openBrowser:", action("openBrowser", focus=True), flush=True)
    wait(lambda: len(labels(strips()[0])) == 2, 15)
    time.sleep(2)  # test harness: the browser tab loads
    judge("New Tab page splits", burst("newtab", [split_right, split_down, split_right], 0.05), 4)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
