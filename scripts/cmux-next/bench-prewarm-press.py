#!/usr/bin/env python3
"""The cost of intent prewarm on a press's own turn (reward-hacking audit 2 item 3c), on a running tagged build.

A press on a sidebar row runs the prewarm service on the press's turn (`intentPrewarmPress`: the row's page lookup,
the FIFO admit, the hover dwell's cancel) before the press's own work. The app times that work and the press
deadline's run after it (IntentPrewarmService, `debug.input` section `prewarm`: `press_turn_ns`, `press_start_ns`).
This bench presses sidebar workspace rows through `debug.mouse` (the real event path: sendEvent, hit test, the
list's mouseDown) and reads the press turns, by arm (bench_arms.py), with p50/p95/p99/max in microseconds:

  warm   a press every `--settle` (0.5 s), alternating between two rows
  quick  two quick presses (`--quick-runs`, default 12): a press on one row, then at once a press on the other; the
         second press's turn
  cold   cold, no wait (`--cold-launches`, default 3, needs `--app`): the app launches (bench_launch.BenchApp) and the
         timed press is its first, as soon as the sidebar lists two workspace rows

The HEADLINE is the WORST arm (a missed run first, else the highest p95, then the highest max), printed as
`HEADLINE prewarm-press press_turn_us = <arm> arm ...`. A press with no service (neither intentPrewarmHover nor
intentPrewarmPress on) records nothing: every run is then missed, and the bench says so. The press deadline's runs
are printed apart (`press_start_us`, every arm together): they run after the press's turn, on a background-class
deadline.

  scripts/cmux-next/bench-prewarm-press.py --socket /tmp/cmux-debug-<tag>.sock [--presses 24] [--json out.json]
  scripts/cmux-next/bench-prewarm-press.py --app "<...>/cmux DEV <tag>.app" [--cold-launches 3] [--json out.json]

With `--socket` it never launches, quits or activates an app; it makes workspaces (a script's newTab) when the
sidebar lists fewer than two. With `--app` it launches the app with the bench env (no activation) and quits it and
its tag's daemons at the end. Run it on a fleet or capture mini, never on a laptop in use.
"""
import argparse
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # bench_arms, bench_launch, also under `python3 -I`
import bench_arms  # noqa: E402


class App:
    def __init__(self, path):
        self.path = path

    def rpc(self, method, params=None, timeout=30):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.path)
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

    def rows(self):
        """The first window's workspace rows: (key, centre x, centre y) in window points from the top left."""
        windows = (self.rpc("debug.sidebar_rows") or {}).get("windows") or [{}]
        out = []
        for row in windows[0].get("rows") or []:
            frame = row.get("window_frame") or {}
            if str(row.get("key", "")).startswith("workspace(") and row.get("in_list") and frame.get("height"):
                out.append((row["key"], frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2))
        return out

    def press_turns(self):
        """(press_turn_ns, press_start_ns) since the last reset; None when the build has no prewarm section."""
        reply = self.rpc("debug.input", {"action": "read", "sections": ["prewarm"]}) or {}
        prewarm = reply.get("prewarm") if isinstance(reply, dict) else None
        if not isinstance(prewarm, dict) or "press_turn_ns" not in prewarm:
            return None
        return prewarm.get("press_turn_ns") or [], prewarm.get("press_start_ns") or []

    def press(self, x, y):
        return self.rpc("debug.mouse", {"x": x, "y": y, "action": "click"})


def wait(check, seconds, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def two_rows(app, make=True):
    rows = app.rows()
    for index in range(max(0, 2 - len(rows)) if make else 0):
        app.rpc("action.run", {"action": "newTab", "args": {"name": f"prewarm-press-{index}"}, "wait": True})
    return wait(lambda: (lambda r: r if len(r) >= 2 else None)(app.rows()), 20)


def timed_press(app, point, before):
    """Presses `point`; the press's turn in µs (None when no turn was recorded), and the count after it."""
    app.press(*point)
    got = wait(lambda: (lambda t: t if t and len(t[0]) > before else None)(app.press_turns()), 2, step=0.01)
    if not got:
        return None, before
    turns = got[0]
    return round(turns[before] / 1000, 2), len(turns)


def measure(app, opts, arms, samples, starts):
    rows = two_rows(app)
    if not rows:
        sys.exit("fewer than two sidebar workspace rows")
    points = [(x, y) for _, x, y in rows[:2]]
    if app.press_turns() is None:
        sys.exit("debug.input has no prewarm.press_turn_ns: a build without the press timing")
    if "warm" in arms:
        app.rpc("debug.input", {"action": "reset"})
        count, samples["warm"] = 0, []
        for index in range(opts.presses):
            time.sleep(opts.settle)  # bench pacing: the press after the last one settled
            value, count = timed_press(app, points[index % 2], count)
            samples["warm"].append(value)
        starts.extend((app.press_turns() or ([], []))[1])
    if "quick" in arms:
        app.rpc("debug.input", {"action": "reset"})
        count, samples["quick"] = 0, []
        for index in range(opts.quick_runs):
            time.sleep(opts.settle)  # bench pacing: the FIRST press of the pair after a settle
            app.press(*points[0])
            value, _ = timed_press(app, points[1], count + 1)  # at once: the timed second press
            count = len((app.press_turns() or ([], []))[0])
            samples["quick"].append(value)
        starts.extend((app.press_turns() or ([], []))[1])


def cold(opts):
    """Per launch, the first press as soon as the sidebar lists two workspace rows."""
    from bench_launch import BenchApp
    out, starts = [], []
    for index in range(opts.cold_launches):
        bench = BenchApp(opts.app, config={})
        bench.launch(timeout=120)
        try:
            app = App(bench.socket)
            rows = two_rows(app)
            value = None
            if rows:
                app.rpc("debug.input", {"action": "reset"})
                value, _ = timed_press(app, (rows[0][1], rows[0][2]), 0)
                starts.extend((app.press_turns() or ([], []))[1])
            print(f"cold launch {index + 1}: press turn {value} us", flush=True)
            out.append(value)
        finally:
            bench.stop()
    return out, starts


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", help="the app's control socket (an app that runs already)")
    parser.add_argument("--app", help="launch this tagged DEV app instead (needed for the cold arm)")
    parser.add_argument("--presses", type=int, default=24, help="warm arm: presses")
    parser.add_argument("--settle", type=float, default=0.5, help="seconds before each warm press and each quick pair")
    parser.add_argument("--quick-runs", type=int, default=12, help="quick arm: pairs of presses")
    parser.add_argument("--cold-launches", type=int, default=3, help="cold arm (--app): launches, each timing its first press")
    parser.add_argument("--arms", default="warm,quick,cold", help="the arms to time (bench_arms.py)")
    parser.add_argument("--json")
    opts = parser.parse_args()
    if bool(opts.socket) == bool(opts.app):
        parser.error("pass --socket, or --app")
    arms = [a for a in opts.arms.split(",") if a]
    if set(arms) - set(bench_arms.ARMS):
        parser.error(f"--arms: one of {', '.join(bench_arms.ARMS)}")
    samples, starts = {}, []
    if "cold" in arms:
        if opts.app:
            opts.app = os.path.abspath(opts.app.rstrip("/"))
            samples["cold"], cold_starts = cold(opts)
            starts.extend(cold_starts)
        else:
            print("cold arm: not run (an attached --socket app cannot be launched cold; pass --app)", flush=True)
            samples["cold"] = []
    bench = None
    if opts.app:
        from bench_launch import BenchApp
        bench = BenchApp(opts.app, config={})
        bench.launch(timeout=120)
        opts.socket = bench.socket
    try:
        measure(App(opts.socket), opts, arms, samples, starts)
    finally:
        if bench:
            bench.stop()
    if all(v is None for values in samples.values() for v in values):
        print("no press turn recorded: is intentPrewarmHover or intentPrewarmPress on in this build?", flush=True)
    result = {"arms": bench_arms.report("prewarm-press", "press_turn_us", "us", samples, out=lambda line: print(line, flush=True))}
    start = bench_arms.stats([round(n / 1000, 2) for n in starts])
    print(f"press_start_us (the press deadline's runs, every arm): n={start['n']} p50={start['p50']} p95={start['p95']} "
          f"p99={start['p99']} max={start['max']} us", flush=True)
    result["press_start_us"] = start
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(result, out, indent=2)


if __name__ == "__main__":
    main()
