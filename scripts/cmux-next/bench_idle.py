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
  mixed-hidden     10 Chromium tabs and 5 terminals in a workspace that is
                   not shown (--hidden-tabs, --hidden-terminals), measured
                   twice: with the window visible (mixed-hidden-visible)
                   and with the app hidden (mixed-hidden-app-hidden, Show/
                   Hide All Windows; shown again after it). Each phase is
                   also a scenario of its own; the setup runs once, for the
                   first phase that runs, and both phases first restore a
                   window an earlier `minimized` left in the Dock.

CPU and wakeups come from proc_pid_rusage (user+system time, package idle
exits plus interrupt wakeups), sampled at the start and end of each window,
after the bench's last request before it and before its first request after
it, so the bench itself adds no wakeups to the app. Each scenario also records:

  main_wakeups_per_s  the app's main run loop wakes from sleep per second
                      (`debug.hangs` `main_wakes`, read last before and
                      first after the window, so the bench's own requests
                      add none in between)
  owners              per-owner wakeups over the window, from the
                      `debug.wakeups` ledger counts (owner, wakeups,
                      per_second, reasons), most first
  hidden_workspace_layouts, hidden_workspace_applies
                      layout passes of workspaces that are off screen, and
                      the tree changes that reached them (model only, kept
                      for their show), over the window
                      (`debug.layout_counters`, Debug builds; null without it)
  window_visible      mixed-hidden-visible: the main window was shown and not
                      minimized when the window began (`debug.window_list`)

When the build has `debug.wakeups`, the ledger's current rates, active
frame clients and live display links are recorded too. Pass criteria
(defaults, per process; tune with flags): no display link at idle; app and
daemon < 0.5% CPU and < 5 wakeups/s, each terminal host < 0.2% and < 2/s,
Chromium helpers < 1% on the static and hidden pages; no hidden workspace
layout. The mixed-hidden phases (p06-scheduler.md done check 6) also need
app + daemon <= 1.0 wakeups/s and main thread <= 0.5/s, and fail when either
number, or the hidden layouts of a build with `debug.layout_counters`, was not
measured; the visible phase fails when its window was not visible. The Chromium Host app's
browser process (cef-host, the Debug-only host prototype) is reported, not
judged: it does the app's in-process Chromium work, so the helper limit does
not fit it and it has no limit of its own yet.

Usage:
  scripts/cmux-next/bench-idle.sh <tag> [--app PATH] [--measure 60]
      [--settle 20] [--scenarios terminals,chromium-static,chromium-hidden,minimized,mixed-hidden]
      [--url URL] [--out DIR] [--label NAME] [--no-fail] [--keep-running]

Writes artifacts/cmux-next-bench/<sha>-idle-<label>.json; exits 1 when a
criterion fails (unless --no-fail). Quits the app it launched and ends its
daemon's terminals on exit (unless --keep-running).
"""
from __future__ import annotations

import argparse
import ctypes
import functools
import json
import os
import shutil
import signal
import socket
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402
from daemon_teardown import end_terminals  # noqa: E402
from tab_pages import TabPages, chromium_children, process_table  # noqa: E402  (re-exported: other benches import them here)

# ---------------------------------------------------------------------------
# Process usage (proc_pid_rusage, RUSAGE_INFO_V4)

class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


@functools.lru_cache(maxsize=1)
def _libproc():
    """libproc and the mach timebase, loaded at the first sample: the module's pure parts import on Linux too."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    timebase = _Timebase()
    libc.mach_timebase_info(ctypes.byref(timebase))
    return ctypes.CDLL("/usr/lib/libproc.dylib"), timebase.numer, timebase.denom


def usage(pid: int):
    """(cpu_ns, wakeups, footprint_bytes) or None when the process is gone."""
    libproc, numer, denom = _libproc()
    buf = (ctypes.c_uint64 * 64)()
    if libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    # uuid (2 x u64), user, system, pkg_idle_wkups, interrupt_wkups, pageins,
    # wired, resident, phys_footprint
    ticks = buf[2] + buf[3]
    return ticks * numer // denom, buf[4] + buf[5], buf[9]


def classify(app_pid: int, bundle: str):
    """{pid: kind} for the app, its Chromium helpers (tab_pages.chromium_kind), the daemon and hosts."""
    table = process_table()
    kinds = {app_pid: "app", **chromium_children(app_pid, table)}
    tui = os.path.join(bundle, "Contents/Resources/bin/cmux-tui")
    for pid, _ppid, cmd in table:
        if cmd.startswith(tui):
            kinds[pid] = "terminal-host" if "__terminal-host" in cmd else "daemon"
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


def main_wakes(control):
    """The app's cumulative main run-loop wakes (`debug.hangs` `main_wakes`), or None without it. The method answers
    from the last published snapshot and reads the watchdog's counter live, so it does not wake the main thread."""
    try:
        value = (control.call("debug.hangs", {"limit": 0}).get("result") or {}).get("main_wakes")
    except (OSError, ValueError):
        return None
    return value if isinstance(value, int) else None


def read_result(control, method, params=None):
    """`method`'s result, or None when the build lacks it or the socket fails."""
    try:
        reply = control.call(method, params or {}, timeout=30)
    except (OSError, ValueError):
        return None
    return None if "error" in reply else reply.get("result")


def rate(start, end, wall):
    """Per second between two cumulative reads; None when either is missing or the counter went back."""
    if start is None or end is None or end < start or wall <= 0:
        return None
    return round((end - start) / wall, 3)


def owner_wakeups(start_ledger, end_ledger, wall):
    """Per-owner wakeups over the window from two `debug.wakeups` ledgers (each entry: owner, reason, cumulative
    count): [{owner, wakeups, per_second, reasons: {reason: wakeups}}], most first, owners that did not wake left
    out. An entry new in the second read counts from 0; a counter that went back (a ledger reset) counts its end."""
    before = {(e.get("owner"), e.get("reason")): e.get("count", 0) for e in start_ledger or []}
    owners = {}
    for entry in end_ledger or []:
        key = (entry.get("owner"), entry.get("reason"))
        count = entry.get("count", 0)
        delta = count - before.get(key, 0)
        if delta < 0:
            delta = count
        if delta <= 0:
            continue
        row = owners.setdefault(key[0], {"owner": key[0], "wakeups": 0, "reasons": {}})
        row["wakeups"] += delta
        row["reasons"][key[1]] = row["reasons"].get(key[1], 0) + delta
    rows = sorted(owners.values(), key=lambda row: (-row["wakeups"], str(row["owner"])))
    for row in rows:
        row["per_second"] = round(row["wakeups"] / wall, 3) if wall > 0 else None
    return rows


HIDDEN_COUNTERS = ("hidden_workspace_layouts", "hidden_workspace_applies")


def hidden_counters(start, end):
    """The window's hidden-workspace layout passes and applies from two `debug.layout_counters` reads (app-wide
    monotonic counters): each a delta, None when a read is missing (a Release build has no such method) or the
    counter went back (a `reset` inside the window)."""
    def delta(name):
        if not (isinstance(start, dict) and isinstance(end, dict)):
            return None
        before, after = start.get(name), end.get(name)
        if not (isinstance(before, int) and isinstance(after, int)) or after < before:
            return None
        return after - before
    return {name: delta(name) for name in HIDDEN_COUNTERS}


def measure(app_pid, bundle, seconds, control):
    kinds = classify(app_pid, bundle)
    # The app's own counters first and its main wakes last: the requests that wake its main thread
    # (debug.wakeups, debug.layout_counters) land before the window, the main_wakes read itself wakes none.
    # The usage samples bracket the window with no request inside: the start ones after every request before it,
    # the end ones before every request after it (main_wakes reads a counter, so it can come after them).
    ledger_start = read_result(control, "debug.wakeups") or {}
    layout_start = read_result(control, "debug.layout_counters")
    wakes_start = main_wakes(control)
    start = {pid: usage(pid) for pid in kinds}
    t0 = time.monotonic()
    time.sleep(seconds)  # test script: the measurement window itself
    wall = time.monotonic() - t0
    end = {pid: usage(pid) for pid in kinds}
    wakes_end = main_wakes(control)
    kinds.update({pid: kind for pid, kind in classify(app_pid, bundle).items() if pid not in kinds})
    rows = []
    for pid, kind in sorted(kinds.items(), key=lambda item: item[1]):
        before, after = start.get(pid), end.get(pid)
        if before is None or after is None:
            # Started or ended inside the window (a daemon restart shows here).
            rows.append({"pid": pid, "kind": kind, "partial": True,
                         "note": "appeared during the window" if before is None else "exited during the window"})
            continue
        rows.append({
            "pid": pid, "kind": kind,
            "cpu_percent": round(100.0 * (after[0] - before[0]) / (wall * 1e9), 3),
            "wakeups_per_s": round((after[1] - before[1]) / wall, 2),
            "footprint_mb": round(after[2] / 1048576, 1),
        })
    diag = {"main_wakeups_per_s": rate(wakes_start, wakes_end, wall), "owners": []}
    report = read_result(control, "debug.wakeups")
    if report:
        diag["owners"] = owner_wakeups(ledger_start.get("ledger"), report.get("ledger"), wall)
        diag["ledger"] = [e for e in report.get("ledger", []) if e.get("per_second", 0) > 0][:12]
        diag["active_frame_clients"] = report.get("active_frame_clients", [])
        if "display_links" in report:
            diag["display_links"] = report["display_links"]
    diag.update(hidden_counters(layout_start, read_result(control, "debug.layout_counters")))
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


def main_window_shown(control):
    """True when every main window is visible and none is minimized (`debug.window_list`), False when one is not,
    None when the build has no such method or lists no main window."""
    windows = (read_result(control, "debug.window_list") or {}).get("windows")
    mains = [w for w in windows or [] if isinstance(w, dict) and w.get("kind") == "main"]
    if not mains:
        return None
    return all(w.get("visible") is True and w.get("miniaturized") is False for w in mains)


def prepare(scenario, control, args, app_pid, bundle):
    """Sets the scenario up; returns a skip reason or None."""
    refused = refused_reply

    def run_action(name, **action_args):
        # A loaded machine can miss the app's 2 s control deadline; retry.
        for _ in range(3):
            response = control.action(name, timeout=60, **action_args)
            if (response.get("error") or {}).get("code") != "timeout":
                return response
            time.sleep(5)  # test script: back off before retrying the action
        return response

    if scenario == "chromium-static":
        # The first Chromium tab starts CEF (slow on a loaded machine).
        response = control.action("openBrowser.chromium", timeout=90, url=args.url)
        # A cold CefInitialize on a loaded machine can outlast the 2 s
        # control deadline while the tab still opens: wait for its renderer.
        timed_out = (response.get("error") or {}).get("code") == "timeout"
        reason = None if timed_out else refused(response)
        if reason is None and not wait_for(lambda: "cef-renderer" in classify(app_pid, bundle).values(), 90):
            reason = "no Chromium renderer appeared within 90 s"
        return reason
    if scenario == "chromium-hidden":
        return refused(run_action("newTab"))
    if scenario == "minimized":
        return refused(run_action("minimizeWindow"))
    if scenario in MIXED_HIDDEN and main_window_shown(control) is not True:
        # An earlier `minimized` left the window in the Dock: Show Main Window restores it (minimizeWindow's handler).
        reason = refused(run_action("showMainWindow"))
        if reason:
            return f"restore the window: {reason}"
        if not wait_for(lambda: main_window_shown(control) is not False, 15):
            return "the main window is still minimized or hidden 15 s after showMainWindow"
    if scenario in MIXED_HIDDEN and not args.mixed_ready:
        # One workspace with the Chromium tabs and the terminals, then a new workspace shows: all of them are hidden.
        # Once for both phases, whichever runs first.
        for index in range(args.hidden_tabs):
            response = control.action("openBrowser.chromium", timeout=90, url=args.next_url())
            if (response.get("error") or {}).get("code") != "timeout" and refused(response):
                return f"Chromium tab {index + 1}: {refused(response)}"
        if args.hidden_tabs and not wait_for(lambda: "cef-renderer" in classify(app_pid, bundle).values(), 90):
            return "no Chromium renderer appeared within 90 s"
        for index in range(args.hidden_terminals):
            reason = refused(run_action("newSurface"))
            if reason:
                return f"terminal {index + 1}: {reason}"
        reason = refused(run_action("newTab"))
        if reason:
            return f"new workspace: {reason}"
        args.mixed_ready = True
    if scenario == "mixed-hidden-app-hidden":
        return refused(show_all(control, hidden=True))
    return None


def show_all(control, hidden):
    """Show/Hide All Windows from a script (idle-budget.py's hide_all): `hidden` hides the app, False shows it."""
    return control.call("action.run", {"action": "showHideAllWindows", "args": {"hidden": hidden}, "focus": False,
                                       "origin": "script"}, timeout=30)


# A scenario name that runs several, in order.
SCENARIO_GROUPS = {"mixed-hidden": ("mixed-hidden-visible", "mixed-hidden-app-hidden")}
MIXED_HIDDEN = ("mixed-hidden-visible", "mixed-hidden-app-hidden")


def scenario_list(text):
    """The scenarios of `--scenarios`, groups expanded, each once, in the order given."""
    names = []
    for name in (part.strip() for part in text.split(",")):
        for item in SCENARIO_GROUPS.get(name, (name,)):
            if item and item not in names:
                names.append(item)
    return names


def refused_reply(response):
    """The error of a control reply, or None when it succeeded."""
    if response.get("ok") is False or "error" in response:
        return response.get("error") or "refused"
    return None


def criteria(scenario, result, args):
    failures = []
    for row in result["processes"]:
        if row.get("partial"):
            if row["kind"] in ("app", "daemon"):
                failures.append(f"{scenario}: {row['kind']} {row['pid']} {row['note']}")
            continue
        kind, cpu, wake = row["kind"], row["cpu_percent"], row["wakeups_per_s"]
        if kind in ("app", "daemon"):
            limit_cpu, limit_wake = args.max_cpu, args.max_wakeups
        elif kind == "terminal-host":
            limit_cpu, limit_wake = args.max_host_cpu, args.max_host_wakeups
        elif kind == "cef-host":
            continue  # reported, not judged (module docstring)
        elif scenario != "terminals":
            limit_cpu, limit_wake = args.max_helper_cpu, None
        else:
            continue
        if cpu > limit_cpu:
            failures.append(f"{scenario}: {kind} {row['pid']} {cpu}% CPU > {limit_cpu}%")
        if limit_wake is not None and wake > limit_wake:
            failures.append(f"{scenario}: {kind} {row['pid']} {wake} wakeups/s > {limit_wake}")
    # An idle app holds no display link (DisplayClock drops a display's link with its last subscriber).
    if result.get("display_links", 0) > 0:
        failures.append(f"{scenario}: {result['display_links']} display links at idle > 0")
    # A hidden workspace's changes update the model only: no layout pass (p06-scheduler.md done check 4).
    if (result.get("hidden_workspace_layouts") or 0) > 0:
        failures.append(f"{scenario}: {result['hidden_workspace_layouts']} hidden workspace layouts > 0")
    if scenario in MIXED_HIDDEN:
        # These phases exist to judge these numbers (done check 6): one not measured fails, never passes.
        total = sum(row["wakeups_per_s"] for row in result["processes"]
                    if not row.get("partial") and row["kind"] in ("app", "daemon"))
        if total > args.max_mixed_wakeups:
            failures.append(f"{scenario}: app + daemon {round(total, 2)} wakeups/s > {args.max_mixed_wakeups}")
        main = result.get("main_wakeups_per_s")
        if main is None:
            failures.append(f"{scenario}: main thread wakeups not measured")
        elif main > args.max_main_wakeups:
            failures.append(f"{scenario}: main thread {main} wakeups/s > {args.max_main_wakeups}")
        if args.has_layout_counters and result.get("hidden_workspace_layouts") is None:
            failures.append(f"{scenario}: hidden workspace layouts not measured")
        if scenario == "mixed-hidden-visible" and result.get("window_visible") is not True:
            failures.append(f"{scenario}: the window was not visible (window_visible={result.get('window_visible')})")
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
    parser.add_argument("--url", help="page for the Chromium scenarios (default: tab_pages.py's plain page on a local server)")
    parser.add_argument("--out")
    parser.add_argument("--label", default="run")
    parser.add_argument("--max-cpu", type=float, default=0.5)
    parser.add_argument("--max-wakeups", type=float, default=5)
    parser.add_argument("--max-host-cpu", type=float, default=0.2)
    parser.add_argument("--max-host-wakeups", type=float, default=2)
    parser.add_argument("--max-helper-cpu", type=float, default=1.0)
    parser.add_argument("--max-mixed-wakeups", type=float, default=1.0,
                        help="mixed-hidden: app + daemon wakeups/s (default 1.0)")
    parser.add_argument("--max-main-wakeups", type=float, default=0.5,
                        help="mixed-hidden: main run-loop wakes/s (default 0.5)")
    parser.add_argument("--hidden-tabs", type=int, default=10, help="mixed-hidden: Chromium tabs (default 10)")
    parser.add_argument("--hidden-terminals", type=int, default=5, help="mixed-hidden: terminals (default 5)")
    parser.add_argument("--no-fail", action="store_true")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="an extra variable for the app (repeatable; for example a feature's DEV opt-in)")
    parser.add_argument("--setting", action="append", default=[], metavar="DOTTED.KEY=JSON",
                        help="a value written to the scratch cmux.json before launch (repeatable)")
    parser.add_argument("--fresh", action="store_true",
                        help="start from an empty daemon session for this tag (removes the tag's saved tabs)")
    args = parser.parse_args()

    tag = args.tag
    bundle = args.app or os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app")
    binary = os.path.join(bundle, "Contents/MacOS/cmux DEV")
    if not os.path.exists(binary):
        raise SystemExit(f"bench-idle: no app at {bundle}")
    if args.fresh:
        # Saved tabs (a restored Chromium tab starts CEF) would change every scenario.
        shutil.rmtree(os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui"), ignore_errors=True)
    scratch = tempfile.mkdtemp(prefix=f"bench-idle-{tag}-")
    # The bench's own variables on top of bench_launch.py's defaults (--env adds or overrides them).
    env = {}
    for item in args.env:
        name, _, value = item.partition("=")
        env[name] = value
    # --setting values go into the scratch cmux.json the launch writes.
    config: dict = {}
    for item in args.setting:
        key, _, raw = item.partition("=")
        node = config
        parts = key.split(".")
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = json.loads(raw)
    report_env = {"env": sorted(args.env), "settings": sorted(args.setting)}
    pages = None
    if not args.url:
        pages = TabPages(default_kind="plain")
        args.url = pages.url()
    # mixed-hidden opens one page per tab (each its own URL), or --url in every tab.
    args.next_url = pages.url if pages else (lambda: args.url)
    args.mixed_ready = False
    args.has_layout_counters = False
    # One launch path for GUI benches (bench_launch.py): the console-session check, a refusal when this app already
    # runs, the tag's socket in the state folder, and the reason when the app does not come up.
    bench = BenchApp(bundle, out=args.out or scratch, config=config, window=None, screen="last", env=env,
                     log_name=f"app-{tag}-{args.label}.log")
    bench.launch(timeout=120, ready="system.ping")
    app = bench.process
    report = {"tag": tag, "sha": args.sha, "label": args.label, "app": bundle, "scenarios": {}, **report_env}
    failures = []
    try:
        control = wait_for_socket(bench.socket)
        identity = control.call("system.identify").get("result", {})
        app_pid = identity.get("pid", app.pid)
        report["has_debug_wakeups"] = "error" not in control.call("debug.wakeups", timeout=30)
        args.has_layout_counters = report["has_layout_counters"] = read_result(control, "debug.layout_counters") is not None
        for scenario in scenario_list(args.scenarios):
            if app.poll() is not None:
                # Negative: killed by that signal (a crash, or someone else's cleanup).
                report["app_exit"] = app.returncode
                failures.append(f"{scenario}: the app exited ({app.returncode}) before this scenario")
                print(f"bench-idle: the app exited with {app.returncode}", file=sys.stderr)
                break
            try:
                skipped = prepare(scenario, control, args, app_pid, bundle)
            except (OSError, ValueError) as error:
                skipped = f"setup failed: {error}"
            if skipped is not None:
                report["scenarios"][scenario] = {"skipped": skipped}
                print(f"== {scenario}: skipped ({skipped})")
                continue
            time.sleep(args.settle)  # test script: let the scenario settle
            window_visible = main_window_shown(control) if scenario == "mixed-hidden-visible" else None
            result = measure(app_pid, bundle, args.measure, control)
            if scenario == "mixed-hidden-visible":
                result["window_visible"] = window_visible
            if scenario == "mixed-hidden-app-hidden":
                result["shown_again"] = refused_reply(show_all(control, hidden=False)) is None
            report["scenarios"][scenario] = result
            failures += criteria(scenario, result, args)
            print(f"== {scenario}")
            for row in result["processes"]:
                if row.get("partial"):
                    print(f"   {row['kind']:<14} pid {row['pid']:<6} {row['note']}")
                else:
                    print(f"   {row['kind']:<14} pid {row['pid']:<6} {row['cpu_percent']:>7.3f}% CPU {row['wakeups_per_s']:>8.2f} wakeups/s")
            if result.get("main_wakeups_per_s") is not None:
                print(f"   main thread {result['main_wakeups_per_s']} wakeups/s")
            if result.get("owners"):
                top = ", ".join(f"{e['owner']}={e['per_second']}/s" for e in result["owners"][:6])
                print(f"   owners: {top}")
            if result.get("hidden_workspace_layouts") is not None:
                print(f"   hidden workspaces: {result['hidden_workspace_layouts']} layouts, "
                      f"{result['hidden_workspace_applies']} applies")
            if result.get("active_frame_clients"):
                print(f"   active frame clients: {result['active_frame_clients']}")
    finally:
        if not args.keep_running:
            # The app's quit, then TERM and KILL of its own PID, then the tag's daemons (tag_teardown.py).
            bench.stop()
            report["teardown"] = "bench_launch"
        if pages:
            pages.close()
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
