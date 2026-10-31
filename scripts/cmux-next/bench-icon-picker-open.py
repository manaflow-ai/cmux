#!/usr/bin/env python3
"""Icon picker open bench (cx-ag5.9.2) against a running DEBUG cmux-next app.

Opens the icon picker with Set Workspace Icon (`workspace.setIcon`, no icon: the picker) `--opens`
times through the app's own CLI and control socket, each open replacing the last, then prints
each open's span from `debug.timings` (`icon_picker_opens`): catalog wait, panel and page made or
reused (`created_page`), present. With the launch warm-up the first open reuses the picker
like later ones (created_page false, no catalog wait).

  scripts/cmux-next/bench-icon-picker-open.py --cli "<app>/Contents/Resources/bin/cmux" \\
      --socket /tmp/cmux-debug-<tag>.sock [--opens 6] [--json out.json]
  scripts/cmux-next/bench-icon-picker-open.py --app "<...>/cmux DEV <tag>.app" [--cold-launches 3] [--json out.json]

Three arms of the open (`--arms`, default all; bench_arms.py), each reported with p50/p95/p99/max of the open's
`ms`:

  warm   the opens after the first, `--settle` (1.0 s) apart, after the launch warm-up made the picker
  quick  two quick opens (`--quick-runs`, default 4): Set Workspace Icon twice through the socket at once; the
         second open's span, with no wait for the picker to be made again
  cold   cold, no wait (`--cold-launches`, default 3, needs `--app`): the app launches (bench_launch.BenchApp) and
         the timed open is its first, as soon as the socket answers with a window, before the launch warm-up ends

The HEADLINE is the WORST arm (a missed run first, else the highest p95, then the highest max), printed as
`HEADLINE icon-picker open_ms = <arm> arm ...`; the warm arm alone never stands for the bench. An attached app
(`--socket`) cannot be launched cold: its cold arm is reported as not run.

With `--socket` it never launches, quits or activates an app; it only talks to the socket it is given. With `--app`
it launches the app with the bench env (no activation) and quits it and its tag's daemons at the end; with
`--app`, the warm and quick arms run in a last launch after `--warm-up-wait` (5 s).
"""
import argparse
import json
import os
import socket as socketlib
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # bench_arms, bench_launch, also under `python3 -I`
import bench_arms  # noqa: E402


def call(cli, socket, method, params):
    out = subprocess.run([cli, "--json", "--app-socket", socket, "app", "call", method, json.dumps(params)],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        sys.exit(f"{method} failed: {out.stderr.strip() or out.stdout.strip()}")
    return json.loads(out.stdout or "null")


def action(cli, socket, name):
    out = subprocess.run([cli, "--json", "--app-socket", socket, "action", "run", name],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        sys.exit(f"{name} failed: {out.stderr.strip() or out.stdout.strip()}")


def rpc(socket_path, method, params=None, timeout=30):
    """One request on the app's socket (the quick arm's opens: no CLI process between them)."""
    try:
        conn = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(socket_path)
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


def opens_since(cli, socket_path, before):
    """The icon picker opens recorded after the first `before`."""
    return ((call(cli, socket_path, "debug.timings", {}) or {}).get("icon_picker_opens") or [])[before:]


def recorded(cli, socket_path):
    return len((call(cli, socket_path, "debug.timings", {}) or {}).get("icon_picker_opens") or [])


def launched(app_path):
    """A BenchApp of `app_path`, launched (bench env, no activation); its socket answers with a window."""
    from bench_launch import BenchApp
    bench = BenchApp(app_path, config={})
    bench.launch(timeout=120)
    return bench


def cold_opens(opts):
    """The cold arm: per launch, the first open as soon as the socket answers; None for a launch whose open
    recorded nothing."""
    samples = []
    for index in range(opts.cold_launches):
        bench = launched(opts.app)
        try:
            rpc(bench.socket, "action.run", {"action": "workspace.setIcon"})
            got = None
            for _ in range(50):
                got = (rpc(bench.socket, "debug.timings", {}) or {}).get("icon_picker_opens") or []
                if got:
                    break
                time.sleep(0.1)  # test harness polling a live app
            first = got[0] if got else None
            print(f"cold launch {index + 1}: " + (f"{first['ms']} ms (created_page {first['created_page']}, "
                                                  f"catalog {first['catalog_ms']} ms)" if first else "no open recorded"),
                  flush=True)
            samples.append(first["ms"] if first else None)
        finally:
            bench.stop()
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cli", help="the app's bundled cmux CLI (default: the --app's)")
    parser.add_argument("--socket", help="the app's control socket (an app that runs already)")
    parser.add_argument("--app", help="launch this tagged DEV app instead (needed for the cold arm)")
    parser.add_argument("--opens", type=int, default=6)
    parser.add_argument("--settle", type=float, default=1.0, help="seconds between opens")
    parser.add_argument("--arms", default="warm,quick,cold", help="the arms to time (bench_arms.py)")
    parser.add_argument("--quick-runs", type=int, default=4, help="quick arm: pairs of opens at once")
    parser.add_argument("--cold-launches", type=int, default=3, help="cold arm (--app): launches, each timing its first open")
    parser.add_argument("--warm-up-wait", type=float, default=5.0, help="--app: seconds after the last launch before the warm arm")
    parser.add_argument("--json")
    opts = parser.parse_args()
    if bool(opts.socket) == bool(opts.app):
        parser.error("pass --socket (with --cli), or --app")
    arms = [a for a in opts.arms.split(",") if a]
    if set(arms) - set(bench_arms.ARMS):
        parser.error(f"--arms: one of {', '.join(bench_arms.ARMS)}")
    if opts.app:
        opts.app = os.path.abspath(opts.app.rstrip("/"))
        opts.cli = opts.cli or os.path.join(opts.app, "Contents/Resources/bin/cmux")
    elif not opts.cli:
        parser.error("--socket needs --cli")
    samples = {}
    if "cold" in arms:
        if opts.app:
            samples["cold"] = cold_opens(opts)
        else:
            print("cold arm: not run (an attached --socket app cannot be launched cold; pass --app)", flush=True)
            samples["cold"] = []
    bench = None
    if opts.app:
        bench = launched(opts.app)
        opts.socket = bench.socket
        time.sleep(opts.warm_up_wait)  # test harness: the launch warm-up makes the picker (the warm arm's premise)
    try:
        summary = measure(opts, arms, samples)
    finally:
        if bench:
            bench.stop()
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(summary, out, indent=2)


def measure(opts, arms, samples):
    call(opts.cli, opts.socket, "debug.timings", {"clear": True})
    for _ in range(opts.opens):
        action(opts.cli, opts.socket, "workspace.setIcon")
        time.sleep(opts.settle)  # bench pacing, not app code
    opens = (call(opts.cli, opts.socket, "debug.timings", {}) or {}).get("icon_picker_opens") or []
    if not opens:
        sys.exit("no icon_picker_opens: is this a build with the open timings, and did Set Icon open the picker?")

    print("open  total_ms  catalog_ms  page_ms  present_ms  created_page")
    for index, open_ in enumerate(opens, 1):
        print(f"{index:>4}  {open_['ms']:>8}  {open_['catalog_ms']:>10}  {open_['page_ms']:>7}  {open_['present_ms']:>10}  {open_['created_page']}")
    later = [open_["ms"] for open_ in opens[1:]]
    summary = {"first_ms": opens[0]["ms"], "first_created_page": opens[0]["created_page"],
               "later_median_ms": statistics.median(later) if later else None, "opens": opens}
    print(f"first {summary['first_ms']} ms (created_page {summary['first_created_page']}), "
          f"later median {summary['later_median_ms']} ms over {len(later)}")
    if "warm" in arms:
        samples["warm"] = later
    if "quick" in arms:
        samples["quick"] = []
        for index in range(opts.quick_runs):
            time.sleep(opts.settle)  # bench pacing: the FIRST open of the pair finds the picker made
            before = recorded(opts.cli, opts.socket)
            rpc(opts.socket, "action.run", {"action": "workspace.setIcon"})
            rpc(opts.socket, "action.run", {"action": "workspace.setIcon"})  # at once: the timed open
            pair = []
            for _ in range(50):
                pair = opens_since(opts.cli, opts.socket, before)
                if len(pair) >= 2:
                    break
                time.sleep(0.1)  # test harness polling a live app
            second = pair[1] if len(pair) >= 2 else None
            print(f"quick {index + 1}: " + (f"{second['ms']} ms (created_page {second['created_page']})" if second
                                            else f"{len(pair)} of 2 opens recorded"), flush=True)
            samples["quick"].append(second["ms"] if second else None)
    summary["arms"] = bench_arms.report("icon-picker", "open_ms", "ms", samples, out=lambda line: print(line, flush=True))
    return summary


if __name__ == "__main__":
    main()
