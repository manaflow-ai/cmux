#!/usr/bin/env python3
"""Idle benchmark for a tagged cmux-next build (plans/cmux-next/idle-wakeups.md).

Launches the tagged app itself (clean environment, no activation, test
window on the last screen, scratch config), then measures, per scenario,
the CPU share and wakeups per second of the app, the cmux-tui daemon, its
terminal hosts, and each Chromium helper over --measure seconds after
--settle seconds of quiet:

  terminals        the launch window with its terminal
  chromium-static  plus one Chromium tab on a static page (selected)
  chromium-hidden  that Chromium tab's workspace is not shown (a new
                   workspace is selected)
  minimized        the window is minimized (action minimizeWindow)

CPU and wakeups come from proc_pid_rusage (user+system time, package idle
exits plus interrupt wakeups), sampled at the start and end of each window,
so the bench itself adds no wakeups to the app. When the build has
`debug.wakeups`, the ledger owners and active frame clients are recorded
too. Pass criteria (defaults, per process; tune with flags): app and
daemon < 0.5% CPU and < 5 wakeups/s, each terminal host < 0.2% and < 2/s,
Chromium helpers < 1% on the static and hidden pages.

Usage:
  scripts/cmux-next/bench-idle.sh <tag> [--app PATH] [--measure 60]
      [--settle 20] [--scenarios terminals,chromium-static,chromium-hidden,minimized]
      [--url URL] [--out DIR] [--label NAME] [--no-fail] [--keep-running]

Writes artifacts/cmux-next-bench/<sha>-idle-<label>.json; exits 1 when a
criterion fails (unless --no-fail). Quits the app it launched and ends its
daemon's terminals on exit (unless --keep-running).
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from daemon_teardown import end_terminals  # noqa: E402

STATIC_PAGE_HTML = "<!doctype html><title>idle</title><h1>static page</h1><p>no script, no animation</p>"

# ---------------------------------------------------------------------------
# Process usage (proc_pid_rusage, RUSAGE_INFO_V4)

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = _Timebase()
_libc.mach_timebase_info(ctypes.byref(_tb))


def usage(pid: int):
    """(cpu_ns, wakeups, footprint_bytes) or None when the process is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    # uuid (2 x u64), user, system, pkg_idle_wkups, interrupt_wkups, pageins,
    # wired, resident, phys_footprint
    ticks = buf[2] + buf[3]
    return ticks * _tb.numer // _tb.denom, buf[4] + buf[5], buf[9]


def run(argv, env=None):
    return subprocess.run(argv, capture_output=True, text=True, env=env).stdout


def children(pid: int):
    return [int(p) for p in run(["pgrep", "-P", str(pid)]).split()]


def command(pid: int) -> str:
    return run(["ps", "-o", "command=", "-p", str(pid)]).strip()


def classify(app_pid: int, bundle: str):
    """{pid: kind} for the app, its Chromium helpers, the daemon and hosts."""
    kinds = {app_pid: "app"}
    for child in children(app_pid):
        cmd = command(child)
        if " Helper" in cmd:
            kind = "cef-helper"
            for name in ("Renderer", "GPU", "Plugin", "Alerts"):
                if f"({name})" in cmd:
                    kind = f"cef-{name.lower()}"
            kinds[child] = kind
    tui = os.path.join(bundle, "Contents/Resources/bin/cmux-tui")
    for pid in [int(p) for p in run(["pgrep", "-f", tui]).split()]:
        kinds[pid] = "terminal-host" if "__terminal-host" in command(pid) else "daemon"
    return kinds


# ---------------------------------------------------------------------------
# Control socket


class Client:
    def __init__(self, path, timeout=10.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.timeout = timeout
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1

    def call(self, method, params=None, timeout=None):
        request_id = self.next_id
        self.next_id += 1
        self.sock.settimeout(timeout or self.timeout)
        self.sock.sendall((json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n").encode())
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("socket closed")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            message = json.loads(line)
            # A late answer to an earlier request that timed out: skip it.
            if message.get("id") == request_id:
                return message

    def action(self, name, timeout=None, **args):
        params = {"action": name}
        if args:
            params["args"] = args
        return self.call("action.run", params, timeout=timeout)


def wait_for_socket(path, limit_s=60):
    deadline = time.monotonic() + limit_s
    while time.monotonic() < deadline:
        try:
            client = Client(path, timeout=5)
            if client.call("system.ping").get("ok", True):
                return client
        except OSError:
            pass
        time.sleep(0.5)  # test script: waiting for the app's socket to appear
    raise SystemExit(f"bench-idle: no control socket at {path} after {limit_s} s")


# ---------------------------------------------------------------------------


def measure(app_pid, bundle, seconds, control):
    kinds = classify(app_pid, bundle)
    start = {pid: usage(pid) for pid in kinds}
    t0 = time.monotonic()
    time.sleep(seconds)  # test script: the measurement window itself
    wall = time.monotonic() - t0
    kinds.update({pid: kind for pid, kind in classify(app_pid, bundle).items() if pid not in kinds})
    rows = []
    for pid, kind in sorted(kinds.items(), key=lambda item: item[1]):
        before, after = start.get(pid), usage(pid)
        if before is None or after is None:
            continue
        rows.append({
            "pid": pid, "kind": kind,
            "cpu_percent": round(100.0 * (after[0] - before[0]) / (wall * 1e9), 3),
            "wakeups_per_s": round((after[1] - before[1]) / wall, 2),
            "footprint_mb": round(after[2] / 1048576, 1),
        })
    diag = {}
    try:
        report = control.call("debug.wakeups", timeout=30).get("result")
        if report:
            diag["ledger"] = [e for e in report.get("ledger", []) if e.get("per_second", 0) > 0][:12]
            diag["active_frame_clients"] = report.get("active_frame_clients", [])
    except (OSError, ValueError):
        pass
    try:
        hangs = control.call("debug.hangs", {"limit": 5}).get("result") or {}
        diag["busy_count"] = hangs.get("busy_count")
        diag["stall_count"] = hangs.get("count")
    except (OSError, ValueError):
        pass
    return {"wall_s": round(wall, 1), "processes": rows, **diag}


def wait_for(condition, limit_s):
    deadline = time.monotonic() + limit_s
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.5)  # test script: waiting for Chromium helpers to appear
    return False


def prepare(scenario, control, args, app_pid, bundle):
    """Sets the scenario up; returns a skip reason or None."""
    def refused(response):
        if response.get("ok") is False or "error" in response:
            return response.get("error") or "refused"
        return None

    if scenario == "chromium-static":
        # The first Chromium tab starts CEF (slow on a loaded machine).
        reason = refused(control.action("openBrowser.chromium", timeout=90, url=args.url))
        if reason is None and not wait_for(lambda: "cef-renderer" in classify(app_pid, bundle).values(), 90):
            reason = "no Chromium renderer appeared within 90 s"
        return reason
    if scenario == "chromium-hidden":
        return refused(control.action("workspace new"))
    if scenario == "minimized":
        return refused(control.action("minimizeWindow"))
    return None


def criteria(scenario, result, args):
    failures = []
    for row in result["processes"]:
        kind, cpu, wake = row["kind"], row["cpu_percent"], row["wakeups_per_s"]
        if kind in ("app", "daemon"):
            limit_cpu, limit_wake = args.max_cpu, args.max_wakeups
        elif kind == "terminal-host":
            limit_cpu, limit_wake = args.max_host_cpu, args.max_host_wakeups
        elif scenario != "terminals":
            limit_cpu, limit_wake = args.max_helper_cpu, None
        else:
            continue
        if cpu > limit_cpu:
            failures.append(f"{scenario}: {kind} {row['pid']} {cpu}% CPU > {limit_cpu}%")
        if limit_wake is not None and wake > limit_wake:
            failures.append(f"{scenario}: {kind} {row['pid']} {wake} wakeups/s > {limit_wake}")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app")
    parser.add_argument("--repo-root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
    parser.add_argument("--sha", default="unknown")
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--scenarios", default="terminals,chromium-static,chromium-hidden,minimized")
    parser.add_argument("--url", help="page for the Chromium scenarios (default: a static local file)")
    parser.add_argument("--out")
    parser.add_argument("--label", default="run")
    parser.add_argument("--max-cpu", type=float, default=0.5)
    parser.add_argument("--max-wakeups", type=float, default=5)
    parser.add_argument("--max-host-cpu", type=float, default=0.2)
    parser.add_argument("--max-host-wakeups", type=float, default=2)
    parser.add_argument("--max-helper-cpu", type=float, default=1.0)
    parser.add_argument("--no-fail", action="store_true")
    parser.add_argument("--keep-running", action="store_true")
    args = parser.parse_args()

    tag = args.tag
    bundle = args.app or os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app")
    binary = os.path.join(bundle, "Contents/MacOS/cmux DEV")
    if not os.path.exists(binary):
        raise SystemExit(f"bench-idle: no app at {bundle}")
    if run(["pgrep", "-f", f"{bundle}/Contents/MacOS/cmux DEV"]).strip():
        raise SystemExit(f"bench-idle: {bundle} is already running; quit it first")
    scratch = tempfile.mkdtemp(prefix=f"bench-idle-{tag}-")
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
    }
    if not args.url:
        page = os.path.join(scratch, "static.html")
        with open(page, "w") as handle:
            handle.write(STATIC_PAGE_HTML)
        args.url = "file://" + page
    app = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    socket_path = f"/tmp/cmux-debug-{tag}.sock"
    report = {"tag": tag, "sha": args.sha, "label": args.label, "app": bundle, "scenarios": {}}
    failures = []
    try:
        control = wait_for_socket(socket_path)
        identity = control.call("system.identify").get("result", {})
        app_pid = identity.get("pid", app.pid)
        report["has_debug_wakeups"] = "error" not in control.call("debug.wakeups", timeout=30)
        for scenario in args.scenarios.split(","):
            try:
                skipped = prepare(scenario, control, args, app_pid, bundle)
            except (OSError, ValueError) as error:
                skipped = f"setup failed: {error}"
            if skipped is not None:
                report["scenarios"][scenario] = {"skipped": skipped}
                print(f"== {scenario}: skipped ({skipped})")
                continue
            time.sleep(args.settle)  # test script: let the scenario settle
            result = measure(app_pid, bundle, args.measure, control)
            report["scenarios"][scenario] = result
            failures += criteria(scenario, result, args)
            print(f"== {scenario}")
            for row in result["processes"]:
                print(f"   {row['kind']:<14} pid {row['pid']:<6} {row['cpu_percent']:>7.3f}% CPU {row['wakeups_per_s']:>8.2f} wakeups/s")
            if result.get("ledger"):
                top = ", ".join(f"{e['owner']}:{e['reason']}={e['per_second']}/s" for e in result["ledger"][:6])
                print(f"   ledger: {top}")
            if result.get("active_frame_clients"):
                print(f"   active frame clients: {result['active_frame_clients']}")
    finally:
        if not args.keep_running:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=15)
            except subprocess.TimeoutExpired:
                app.kill()
            try:
                teardown = end_terminals(os.path.join(bundle, "Contents/Resources/bin/cmux-tui"), tag)
                report["teardown"] = teardown
            except Exception as error:  # noqa: BLE001 - teardown is best effort; report it
                print(f"bench-idle: daemon teardown: {error}", file=sys.stderr)
    report["failures"] = failures
    out_dir = args.out or os.path.join(args.repo_root, "artifacts/cmux-next-bench")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{args.sha}-idle-{args.label}.json")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=2)
    print(f"bench-idle: wrote {out}")
    for failure in failures:
        print(f"FAIL {failure}")
    if failures and not args.no_fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
