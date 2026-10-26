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
  tabs-10          runs alone (--scenarios tabs-10 --engine chromium|webkit): 10 static
                   tab_pages pages over 3 workspaces (4, 3, 3; a new workspace is action
                   newTab), each opened with openBrowser.<engine> and selected, so the
                   last one is the only page shown; settled past browser.freezeHiddenTabs
                   (set to 30 s). The program target idle-wakeups and its stories
                   (scripts/perf-lab/stories.d/idle-tabs.json, idle-tabs-webkit.json).

CPU and wakeups come from proc_pid_rusage (user+system time, package idle
exits plus interrupt wakeups), sampled at the start and end of each window,
so the bench itself adds no wakeups to the app. When the build has
`debug.wakeups`, the ledger owners, active frame clients and live display
links are recorded too. Pass criteria (defaults, per process; tune with
flags): no display link at idle; app and
daemon < 0.5% CPU and < 5 wakeups/s, each terminal host < 0.2% and < 2/s,
Chromium helpers < 1% on the static and hidden pages. The Chromium Host app's
browser process (cef-host, the Debug-only host prototype) is reported, not
judged: it does the app's in-process Chromium work, so the helper limit does
not fit it and it has no limit of its own yet.

tabs-10 reads wakeups as idle-budget.py does (scripts/perf-bench/procs.py): interrupt wakeups only, Chrome's
ProcessMetrics::GetIdleWakeupsPerSecond (base/process/process_metrics_apple.mm), with the app's WebKit XPC
processes in its set; the other scenarios keep their package-idle + interrupt sum. It reads the app only at the
window's two ends: debug.hangs (the main run loop's `main_wakes`), a quiet second, the counters; the counters, then
debug.hangs and debug.cef. The pages must be real pages of the engine: every page POSTed its load to the bench's
page server, exactly the last one reports `visible`, and for Chromium debug.cef is ready with no fallback and a
Chromium renderer runs; for WebKit (browser.defaultEngine webkit) a WebContent process runs and no Chromium
renderer does. Otherwise no result is written. Each measured metric is one cmux-perf-result/v1 file
(BenchApp.record, story idle-tabs or idle-tabs-webkit, engine chromium or webkit):
idle.tabs-10.app_daemon_wakeups_per_s and .main_wakes_per_s claim the targets.json row idle-wakeups.<engine>;
.app_wakeups_per_s and .daemon_wakeups_per_s name their idle-budget.json kind (/kinds/<kind>/wakeups_per_s);
.helper_wakeups_per_s (every Chromium and WebKit process) is reported, with no limit yet.

Usage:
  scripts/cmux-next/bench-idle.sh <tag> [--app PATH] [--measure 60]
      [--settle 20] [--scenarios terminals,chromium-static,chromium-hidden,minimized]
      [--url URL] [--out DIR] [--label NAME] [--no-fail] [--keep-running]
  scripts/cmux-next/bench-idle.sh <tag> --scenarios tabs-10 --engine chromium|webkit

Writes artifacts/cmux-next-bench/<sha>-idle-<label>.json; exits 1 when a
criterion fails (unless --no-fail), and 2 when tabs-10 wrote no valid result
(INVALID lines: not built, not real engine pages, a metric not measured). Quits the app it launched and ends its
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
from bench_launch import PERF_LAB, BenchApp, load_by_path  # noqa: E402
from daemon_teardown import end_terminals  # noqa: E402
from tab_pages import TabPages, chromium_children, process_table  # noqa: E402  (re-exported: other benches import them here)

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench"))
import procs  # noqa: E402  (interrupt wakeups and the app's WebKit XPC processes, as idle-budget.py reads them)

# ---------------------------------------------------------------------------
# Process usage (proc_pid_rusage, RUSAGE_INFO_V4)


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


@functools.cache
def _darwin():
    """libproc and the mach timebase, loaded on first use so the pure parts import on any OS (the Linux tests)."""
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    timebase = _Timebase()
    ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(timebase))
    return libproc, timebase.numer, timebase.denom


def usage(pid: int):
    """(cpu_ns, wakeups, footprint_bytes) or None when the process is gone."""
    libproc, numer, denom = _darwin()
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
    diag = {}
    try:
        report = control.call("debug.wakeups", timeout=30).get("result")
        if report:
            diag["ledger"] = [e for e in report.get("ledger", []) if e.get("per_second", 0) > 0][:12]
            diag["active_frame_clients"] = report.get("active_frame_clients", [])
            if "display_links" in report:
                diag["display_links"] = report["display_links"]
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


# ---------------------------------------------------------------------------
# tabs-10 (p12-perf-process-034): the session of the idle-wakeups target


TABS10 = "tabs-10"
ENGINES = ("chromium", "webkit")
# Static pages per workspace, in opening order. Each page opens selected, so the last page of the last
# workspace is the one page shown; the 9 others are hidden behind it or in a workspace that is not shown.
TABS10_LAYOUT = (4, 3, 3)
# Hidden Chromium tabs freeze this long after they hide (browser.freezeHiddenTabs, set so that the settle is known
# to outlast it, as idle-budget.py's tab sessions do); the settle lasts at least TABS10_SETTLE_MIN_S.
TABS10_FREEZE_S = 30
TABS10_SETTLE_MIN_S = TABS10_FREEZE_S + 15
# Seconds between the start's socket read (debug.hangs) and the first counter read: that read's own wake stays out.
QUIET_GAP_S = 1.0
PAGE_LOAD_S = 90
# One story file per engine arm (scripts/perf-lab/stories.d); the result-v1 story of each.
TABS10_STORIES = {"chromium": "idle-tabs", "webkit": "idle-tabs-webkit"}
IDLE_BUDGET = "scripts/cmux-next/idle-budget.json"
# result-v1 metric -> its limit: the engine's idle-wakeups target row, or an idle-budget.json kind (the number
# stays in the file that owns it). Helper wakeups have no budget row yet: reported, not judged.
TABS10_METRICS = {
    "idle.tabs-10.app_daemon_wakeups_per_s": {"target": "idle-wakeups.{engine}"},
    "idle.tabs-10.main_wakes_per_s": {"target": "idle-wakeups.{engine}"},
    "idle.tabs-10.app_wakeups_per_s": {"path": IDLE_BUDGET, "key": "/kinds/app/wakeups_per_s"},
    "idle.tabs-10.daemon_wakeups_per_s": {"path": IDLE_BUDGET, "key": "/kinds/daemon/wakeups_per_s"},
    "idle.tabs-10.helper_wakeups_per_s": None,
}


def tabs10_plan(layout=TABS10_LAYOUT):
    """[(workspace index, page key)] in opening order; the last entry is the page shown."""
    plan, n = [], 0
    for workspace, count in enumerate(layout):
        for _ in range(count):
            plan.append((workspace, f"t{n}"))
            n += 1
    return plan


def tabs10_config(engine, config):
    """The scratch cmux.json keys tabs-10 needs, under any --setting: hidden tabs freeze after TABS10_FREEZE_S,
    and the WebKit arm's default engine is WebKit, so nothing starts Chromium and a Chromium renderer in its
    process set means a page that is not WebKit."""
    browser = config.setdefault("browser", {})
    browser.setdefault("freezeHiddenTabs", TABS10_FREEZE_S)
    if engine == "webkit":
        browser.setdefault("defaultEngine", "webkit")
    return config


def error_code(response):
    error = response.get("error")
    return error.get("code") if isinstance(error, dict) else None


def run_script_action(control, name, action_args=None, attempts=3, backoff_s=5):
    """action.run as a script, the new item selected. A reply that misses the app's 2 s control deadline is
    retried, except for openBrowser: that tab may still open (a cold CefInitialize), and its page load is the proof."""
    params = {"action": name, "args": action_args or {}, "focus": True, "origin": "script"}
    response = {}
    for attempt in range(attempts):
        response = control.call("action.run", params, timeout=90)
        if error_code(response) != "timeout" or name.startswith("openBrowser."):
            return response
        if attempt + 1 < attempts:
            time.sleep(backoff_s)  # test script: back off before retrying the action
    return response


def wait_loaded(pages, key, limit_s=PAGE_LOAD_S):
    """True once the local page `key` POSTed /loaded/<key> to the bench's own page server (no app read)."""
    deadline = time.monotonic() + limit_s
    while key not in pages.loaded:
        if time.monotonic() > deadline:
            return False
        time.sleep(0.2)  # test script: bounded wait on the bench's page server for the tab's load
    return True


def build_tabs10(control, pages, engine, plan=None, loaded=wait_loaded):
    """Opens the plan's pages: a new workspace (action newTab) before each workspace after the launch one, then
    openBrowser.<engine> for each of its pages. Returns a skip reason or None."""
    current = 0
    for workspace, key in plan or tabs10_plan():
        if workspace != current:
            response = run_script_action(control, "newTab")
            if response.get("error"):
                return f"newTab refused: {str(response['error'])[:200]}"
            current = workspace
        response = run_script_action(control, f"openBrowser.{engine}", {"url": pages.url("static", key)})
        if response.get("error") and error_code(response) != "timeout":
            return f"openBrowser.{engine} refused: {str(response['error'])[:200]}"
        if not loaded(pages, key):
            return f"{engine} page {key} did not load in {PAGE_LOAD_S} s"
    return None


def tab_kinds(app_pid, bundle):
    """classify's kinds plus the WebKit XPC processes macOS counts the app responsible for (procs.Instance):
    they are not the app's children, so the ps parent walk misses them."""
    kinds = classify(app_pid, bundle)
    for pid, cmd in procs.Instance(bundle, app_pid).pids().items():
        if pid not in kinds and "com.apple.WebKit." in cmd:
            kinds[pid] = procs.kind_of(cmd)
    return kinds


def is_helper(kind):
    """A browser engine process: a Chromium helper or host (tab_pages.chromium_kind) or a WebKit XPC process."""
    return kind.startswith(("cef-", "webkit-"))


def engine_problems(engine, cef, kinds, loaded, keys):
    """Why the pages may not be real `engine` pages: a page that never loaded; for Chromium a `debug.cef` error,
    unavailable reason, WebKit fallback or state other than ready, or no Chromium renderer; for WebKit no
    WebContent process, or a Chromium renderer (the arm runs with browser.defaultEngine webkit)."""
    problems = [f"page {key} never loaded" for key in keys if key not in loaded]
    names = set(kinds.values())
    if engine == "chromium":
        if not isinstance(cef, dict):
            return problems + [f"debug.cef answered {str(cef)[:80]}"]
        if cef.get("error") or cef.get("unavailable"):
            problems.append(f"Chromium unavailable: {str(cef.get('error') or cef.get('unavailable'))[:160]}")
        if cef.get("fallback"):
            problems.append(f"WebKit fallbacks: {str(cef.get('fallback'))[:160]}")
        if cef.get("state") != "ready":
            problems.append(f"Chromium state {cef.get('state')}, not ready")
        if "cef-renderer" not in names:
            problems.append("no Chromium renderer process")
    else:
        if "webkit-webcontent" not in names:
            problems.append("no WebKit WebContent process")
        if "cef-renderer" in names:
            problems.append("a Chromium renderer runs: a page may not be WebKit")
    return problems


def shown_problems(visibility, keys):
    """Exactly one page shown, the last one opened (each page POSTs every document.visibilityState change)."""
    shown = [key for key in keys if visibility.get(key) == "visible"]
    if shown != keys[-1:]:
        return [f"pages shown: {', '.join(shown) or 'none'}; expected only {keys[-1]}"]
    return []


def tabs10_rows(kinds, start, end, wall):
    """Per-process rows of a window from two procs.usage reads per pid. wakeups_per_s counts interrupt wakeups
    (idle-budget.json's definition, Chrome's GetIdleWakeupsPerSecond); package-idle wakeups are apart."""
    rows = []
    for pid, kind in sorted(kinds.items(), key=lambda item: (item[1], item[0])):
        before, after = start.get(pid), end.get(pid)
        if before is None or after is None:
            rows.append({"pid": pid, "kind": kind, "partial": True,
                         "note": "appeared during the window" if before is None else "exited during the window"})
            continue
        rates = procs.rates(before, after, wall)
        rows.append({"pid": pid, "kind": kind, "cpu_percent": round(rates["cpu_pct"], 3),
                     "wakeups_per_s": round(rates["wakeups_per_s"], 3),
                     "pkg_idle_wakeups_per_s": round(rates["pkg_idle_wakeups_per_s"], 3),
                     "footprint_mb": round(after.footprint / 1048576, 1)})
    return rows


def tabs10_metrics(rows, main_wakes, wall):
    """{result-v1 metric: value or None}. A kind with a partial row (a process came or went) has no value, and
    no sum over it has; main wakes need debug.hangs `main_wakes` at both ends of the window."""
    def kind_sum(match):
        picked = [row for row in rows if match(row["kind"])]
        if not picked or any(row.get("partial") for row in picked):
            return None
        return round(sum(row["wakeups_per_s"] for row in picked), 3)

    app, daemon = kind_sum(lambda kind: kind == "app"), kind_sum(lambda kind: kind == "daemon")
    wakes = None
    if main_wakes is not None and wall > 0:
        wakes = round((main_wakes[1] - main_wakes[0]) / wall, 3)
    return {
        "idle.tabs-10.app_daemon_wakeups_per_s": None if app is None or daemon is None else round(app + daemon, 3),
        "idle.tabs-10.main_wakes_per_s": wakes,
        "idle.tabs-10.app_wakeups_per_s": app,
        "idle.tabs-10.daemon_wakeups_per_s": daemon,
        "idle.tabs-10.helper_wakeups_per_s": kind_sum(is_helper),
    }


def reply_result(reply):
    return reply.get("result") if isinstance(reply, dict) and "result" in reply else reply


def main_wakes_of(reply):
    """debug.hangs `main_wakes` (the main run loop's wakes from sleep), or None when the build has no counter."""
    result = reply_result(reply)
    value = result.get("main_wakes") if isinstance(result, dict) else None
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def measure_tabs10(app_pid, bundle, seconds, control, engine, pages, keys):
    """One window with no app read inside it: debug.hangs, a quiet gap, the counters; the counters, then
    debug.hangs, debug.cef and the engine and shown-page checks."""
    wakes0 = main_wakes_of(control.call("debug.hangs", {"limit": 0}, timeout=30))
    time.sleep(QUIET_GAP_S)  # test script: keeps the read's own wake out of the counters
    kinds = tab_kinds(app_pid, bundle)
    start = {pid: procs.usage(pid) for pid in kinds}
    t0 = time.monotonic()
    time.sleep(seconds)  # test script: the measurement window itself
    end = {pid: procs.usage(pid) for pid in kinds}
    wall = time.monotonic() - t0
    for pid, kind in tab_kinds(app_pid, bundle).items():
        kinds.setdefault(pid, kind)  # started inside the window: a partial row
    wakes1 = main_wakes_of(control.call("debug.hangs", {"limit": 0}, timeout=30))
    rows = tabs10_rows(kinds, start, end, wall)
    main_wakes = None if wakes0 is None or wakes1 is None else (wakes0, wakes1)
    cef = reply_result(control.call("debug.cef", timeout=30))
    problems = engine_problems(engine, cef, kinds, pages.loaded, keys) + shown_problems(pages.visibility, keys)
    return {"wall_s": round(wall, 1), "engine": engine, "processes": rows,
            "metrics": tabs10_metrics(rows, main_wakes, wall), "engine_problems": problems,
            "visibility": {key: pages.visibility.get(key) for key in keys}}


def record_tabs10(bench, engine, metrics, target_ref_type):
    """Writes each measured metric as one result-v1 file through BenchApp.record; returns (paths, failures).
    `target_ref_type` is perf_result.TargetRef (a path + key reference)."""
    paths, failures = [], []
    for metric, ref in TABS10_METRICS.items():
        value = metrics.get(metric)
        if value is None:
            failures.append(f"{TABS10}: {metric} not measured (no result written)")
            continue
        target_ref = None
        if ref and "target" in ref:
            target_ref = ref["target"].format(engine=engine)
        elif ref:
            target_ref = target_ref_type(path=ref["path"], key=ref["key"])
        try:
            paths.append(bench.record(TABS10_STORIES[engine], metric, "per_s", [value], "lower", engine, target_ref))
        except (RuntimeError, ValueError) as error:  # bench_launch.RecordError, perf_result.ResultError
            failures.append(f"{TABS10}: {metric} result not written: {error}")
    return paths, failures


def judge_tabs10(result, bench, engine, target_ref_type):
    """Writes a measured window's results when its pages were real `engine` pages; returns why nothing (or not
    everything) was written: the engine problems, or a metric that had no value or no valid result."""
    if result["engine_problems"]:
        return result["engine_problems"] + [f"{TABS10}: not real {engine} pages, no result written"]
    result["results"], unwritten = record_tabs10(bench, engine, result["metrics"], target_ref_type)
    return unwritten


def prepare(scenario, control, args, app_pid, bundle, pages=None):
    """Sets the scenario up; returns a skip reason or None."""
    if scenario == TABS10:
        return build_tabs10(control, pages, args.engine)

    def refused(response):
        if response.get("ok") is False or "error" in response:
            return response.get("error") or "refused"
        return None

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
    parser.add_argument("--engine", choices=ENGINES, default="chromium",
                        help="the engine of the tabs-10 pages (default chromium)")
    parser.add_argument("--out")
    parser.add_argument("--label", default="run")
    parser.add_argument("--max-cpu", type=float, default=0.5)
    parser.add_argument("--max-wakeups", type=float, default=5)
    parser.add_argument("--max-host-cpu", type=float, default=0.2)
    parser.add_argument("--max-host-wakeups", type=float, default=2)
    parser.add_argument("--max-helper-cpu", type=float, default=1.0)
    parser.add_argument("--no-fail", action="store_true")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="an extra variable for the app (repeatable; for example a feature's DEV opt-in)")
    parser.add_argument("--setting", action="append", default=[], metavar="DOTTED.KEY=JSON",
                        help="a value written to the scratch cmux.json before launch (repeatable)")
    parser.add_argument("--fresh", action="store_true",
                        help="start from an empty daemon session for this tag (removes the tag's saved tabs)")
    args = parser.parse_args()
    scenarios = args.scenarios.split(",")
    if TABS10 in scenarios and scenarios != [TABS10]:
        # Each scenario builds on the last one's tabs; tabs-10's 10 pages are its whole session.
        parser.error(f"{TABS10} runs alone (--scenarios {TABS10})")

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
    if TABS10 in scenarios:
        tabs10_config(args.engine, config)
    report_env = {"env": sorted(args.env), "settings": sorted(args.setting)}
    pages = None
    if not args.url or TABS10 in scenarios:
        pages = TabPages(default_kind="plain")
        args.url = args.url or pages.url()
    # One launch path for GUI benches (bench_launch.py): the console-session check, a refusal when this app already
    # runs, the tag's socket in the state folder, and the reason when the app does not come up.
    bench = BenchApp(bundle, out=args.out or scratch, config=config, window=None, screen="last", env=env,
                     log_name=f"app-{tag}-{args.label}.log")
    bench.launch(timeout=120, ready="system.ping")
    app = bench.process
    report = {"tag": tag, "sha": args.sha, "label": args.label, "app": bundle, "scenarios": {}, **report_env}
    failures = []
    invalid = []  # tabs-10 measurements that wrote no result (exit 2, whatever --no-fail says)
    try:
        control = wait_for_socket(bench.socket)
        identity = control.call("system.identify").get("result", {})
        app_pid = identity.get("pid", app.pid)
        report["has_debug_wakeups"] = "error" not in control.call("debug.wakeups", timeout=30)
        for scenario in scenarios:
            if app.poll() is not None:
                # Negative: killed by that signal (a crash, or someone else's cleanup).
                report["app_exit"] = app.returncode
                failures.append(f"{scenario}: the app exited ({app.returncode}) before this scenario")
                print(f"bench-idle: the app exited with {app.returncode}", file=sys.stderr)
                break
            try:
                skipped = prepare(scenario, control, args, app_pid, bundle, pages)
            except (OSError, ValueError) as error:
                skipped = f"setup failed: {error}"
            if skipped is not None:
                report["scenarios"][scenario] = {"skipped": skipped}
                print(f"== {scenario}: skipped ({skipped})")
                if scenario == TABS10:
                    invalid.append(f"{scenario}: not built ({skipped}), no result written")
                continue
            if scenario == TABS10:
                time.sleep(max(args.settle, TABS10_SETTLE_MIN_S))  # test script: past the hidden tabs' freeze
                keys = [key for _workspace, key in tabs10_plan()]
                result = measure_tabs10(app_pid, bundle, args.measure, control, args.engine, pages, keys)
                writer = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
                invalid += judge_tabs10(result, bench, args.engine, writer.TargetRef)
            else:
                time.sleep(args.settle)  # test script: let the scenario settle
                result = measure(app_pid, bundle, args.measure, control)
            report["scenarios"][scenario] = result
            failures += criteria(scenario, result, args)
            print(f"== {scenario}")
            for row in result["processes"]:
                if row.get("partial"):
                    print(f"   {row['kind']:<14} pid {row['pid']:<6} {row['note']}")
                else:
                    print(f"   {row['kind']:<14} pid {row['pid']:<6} {row['cpu_percent']:>7.3f}% CPU {row['wakeups_per_s']:>8.2f} wakeups/s")
            if result.get("ledger"):
                top = ", ".join(f"{e['owner']}:{e['reason']}={e['per_second']}/s" for e in result["ledger"][:6])
                print(f"   ledger: {top}")
            if result.get("active_frame_clients"):
                print(f"   active frame clients: {result['active_frame_clients']}")
            for metric, value in result.get("metrics", {}).items():
                print(f"   {metric} = {value}")
    finally:
        if not args.keep_running:
            # The app's quit, then TERM and KILL of its own PID, then the tag's daemons (tag_teardown.py).
            bench.stop()
            report["teardown"] = "bench_launch"
        if pages:
            pages.close()
    report["failures"] = failures
    if TABS10 in scenarios:
        report["invalid"] = invalid
    out_dir = args.out or os.path.join(args.repo_root, "artifacts/cmux-next-bench")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{args.sha}-idle-{args.label}.json")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=2)
    print(f"bench-idle: wrote {out}")
    for failure in failures:
        print(f"FAIL {failure}")
    for reason in invalid:
        print(f"INVALID {reason}")
    if invalid:
        sys.exit(2)
    if failures and not args.no_fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
