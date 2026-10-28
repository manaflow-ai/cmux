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
  app-hidden       the app is hidden (Show/Hide All Windows) with the session
                   it has, no setup of its own; shown again after it
  covered-window   a second main window (action newWindow) the size of the
                   first, put exactly over it (debug.window_frame): macOS
                   still calls the first one visible (crbug.com/883031), so
                   only cmux's occlusion family stops its frames, terminals
                   and pages (p03-rendering-097). Fails when the covered
                   window's family was not occluded at the window's start
                   (`debug.windows` family_occluded). The cover stays open.
                   app-hidden and covered-window launch the app with the
                   feature windowOcclusionFamily on (a Labs local choice in
                   the tag's fresh state, BenchApp local_features) and the
                   user's draw of occluded windows
                   (CMUX_NEXT_BENCH_SHIPPING_DRAW=1; a Debug automation launch
                   draws them otherwise), for every scenario of the run.
  hidden-printing  runs last: --printing-terminals terminals (default 10),
                   each shown as it opens and sent PRINT_LOOP (a line every
                   50 ms) by its own tab target, then a new workspace hides
                   them (p03-rendering-088: a hidden surface's renderer wakes
                   nothing). Skipped unless that many distinct tabs took the
                   loop and their workspace no longer shows. Not idle, so
                   reported, never judged: compare its CPU and wakeups between
                   two builds. The loops never stop, hence last.
  tabs-10          runs alone (--fresh --scenarios tabs-10 --engine chromium|webkit): 10
                   static tab_pages `engine` pages over 3 workspaces (4, 3, 3; a new workspace is action
                   newTab), each opened with openBrowser.<engine> and selected, so the
                   last one is the only page shown; settled past browser.freezeHiddenTabs
                   (set to 30 s). The program target idle-wakeups and its stories
                   (scripts/perf-lab/stories.d/idle-tabs.json, idle-tabs-webkit.json).

CPU and wakeups come from proc_pid_rusage through scripts/perf-bench/procs.py,
as idle-budget.py reads them (user+system time; interrupt wakeups only, Chrome's
ProcessMetrics::GetIdleWakeupsPerSecond, base/process/process_metrics_apple.mm;
package-idle wakeups, a subset of them, are reported apart), sampled at the
start and end of each window, after the bench's last request before it and
before its first request after it, so the bench itself adds no wakeups to the
app. `usage()` is that read for the benches that import it here. Each scenario
also records:

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
measured; the visible phase fails when its window was not visible. app-hidden and covered-window
need main thread <= 0.5/s (--max-main-wakeups) and fail when it was not measured. The Chromium Host app's
browser process (cef-host, the Debug-only host prototype) is reported, not
judged: it does the app's in-process Chromium work, so the helper limit does
not fit it and it has no limit of its own yet.

tabs-10's process set adds every Chromium process of the app's process tree and the WebKit XPC processes macOS
counts the app responsible for (procs.Instance). It needs an empty session (--fresh): each newTab must add exactly
one workspace, and the session ends with 3. It reads the app only at the window's two ends: debug.hangs (the main
run loop's `main_wakes`, timed by its own replies), a quiet second, the counters; the counters, then debug.hangs
and debug.cef. The pages must be real pages of the engine: every page POSTed its load and its navigator.vendor to
the bench's page server (tab_pages.py `engine` pages), exactly the last one reports `visible`, and for Chromium
every vendor is Chromium's, debug.cef is ready with no fallback and a Chromium renderer runs; for WebKit every
vendor is WebKit's, debug.cef has default_engine webkit and Chromium not started, and no Chromium process runs.
Otherwise no result is written. Each measured metric is one cmux-perf-result/v1 file
(BenchApp.record, story idle-tabs or idle-tabs-webkit, engine chromium or webkit):
idle.tabs-10.app_daemon_wakeups_per_s and .main_wakes_per_s claim the targets.json row idle-wakeups.<engine>;
.app_wakeups_per_s and .daemon_wakeups_per_s name their idle-budget.json kind (/kinds/<kind>/wakeups_per_s);
.helper_wakeups_per_s (every Chromium and WebKit process) is reported, with no limit yet: when a helper came or
went in the window it is a note, not a missing result.

Usage:
  scripts/cmux-next/bench-idle.sh <tag> [--app PATH] [--measure 60]
      [--settle 20] [--scenarios terminals,chromium-static,chromium-hidden,minimized,mixed-hidden]
      [--url URL] [--out DIR] [--label NAME] [--no-fail] [--keep-running]
  scripts/cmux-next/bench-idle.sh <tag> --scenarios app-hidden,covered-window
  scripts/cmux-next/bench-idle.sh <tag> --scenarios hidden-printing [--printing-terminals 10]
  scripts/cmux-next/bench-idle.sh <tag> --fresh --scenarios tabs-10 --engine chromium|webkit

Writes artifacts/cmux-next-bench/<sha>-idle-<label>.json; exits 1 when a
criterion fails (unless --no-fail), and 2 when tabs-10 wrote no valid result
(INVALID lines: not built, the app gone, a socket or file error, not real engine pages, a judged metric not
measured). Quits the app it launched and ends its
daemon's terminals on exit (unless --keep-running).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import PERF_LAB, SHIPPING_DRAW_KEY, BenchApp, load_by_path, main_binary  # noqa: E402
from daemon_teardown import end_terminals  # noqa: E402
from tab_pages import TabPages, chromium_children, chromium_kind, process_table  # noqa: E402  (re-exported: other benches import them here)

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench"))
import procs  # noqa: E402  (the one rusage reader: interrupt wakeups, and the app's WebKit XPC processes)

# ---------------------------------------------------------------------------
# Process usage (procs.usage, proc_pid_rusage RUSAGE_INFO_V6)


def usage(pid: int):
    """(cpu_ns, interrupt wakeups, footprint_bytes) or None when the process is gone (procs.usage)."""
    got = procs.usage(pid)
    return None if got is None else (got.cpu_ns, got.interrupt_wakeups, got.footprint)


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
    start = {pid: procs.usage(pid) for pid in kinds}
    t0 = time.monotonic()
    time.sleep(seconds)  # test script: the measurement window itself
    wall = time.monotonic() - t0
    end = {pid: procs.usage(pid) for pid in kinds}
    wakes_end = main_wakes(control)
    kinds.update({pid: kind for pid, kind in classify(app_pid, bundle).items() if pid not in kinds})
    # Started or ended inside the window (a daemon restart shows here): a partial row.
    rows = window_rows(kinds, start, end, wall)
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


# ---------------------------------------------------------------------------
# tabs-10: the session of the idle-wakeups target


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
    and the WebKit arm's default engine is WebKit, so nothing starts Chromium (engine_problems refuses a WebKit
    run in which it did)."""
    browser = config.setdefault("browser", {})
    browser.setdefault("freezeHiddenTabs", TABS10_FREEZE_S)
    if engine == "webkit":
        browser.setdefault("defaultEngine", "webkit")
    return config


def error_code(response):
    error = response.get("error")
    return error.get("code") if isinstance(error, dict) else None


def run_script_action(control, name, action_args=None):
    """action.run as a script, the new item selected, sent once. A reply that misses the app's 2 s control deadline
    does not mean the action did not run (a cold CefInitialize, a busy main turn), so a retry could make a second
    tab or workspace: the page loads and the workspace count after the build are the proof."""
    params = {"action": name, "args": action_args or {}, "focus": True, "origin": "script"}
    return control.call("action.run", params, timeout=90)


def wait_loaded(pages, key, limit_s=PAGE_LOAD_S):
    """True once the local page `key` POSTed /loaded/<key> to the bench's own page server (no app read)."""
    deadline = time.monotonic() + limit_s
    while key not in pages.loaded:
        if time.monotonic() > deadline:
            return False
        time.sleep(0.2)  # test script: bounded wait on the bench's page server for the tab's load
    return True


def workspace_count(control):
    """The number of workspaces in the app's topology (snapshot.get), or None when it cannot be read."""
    topology = (reply_result(control.call("snapshot.get", timeout=30)) or {}).get("topology")
    workspaces = topology.get("workspaces") if isinstance(topology, dict) else None
    return len(workspaces) if isinstance(workspaces, list) else None


def build_tabs10(control, pages, engine, plan=None, loaded=wait_loaded):
    """Opens the plan's pages: a new workspace (action newTab) before each workspace after the launch one, then
    openBrowser.<engine> for each of its pages (tab_pages `engine` pages), then checks the session has exactly the
    plan's workspaces. Returns a skip reason or None."""
    plan = plan or tabs10_plan()
    current = 0
    for workspace, key in plan:
        if workspace != current:
            response = run_script_action(control, "newTab")
            if response.get("error") and error_code(response) != "timeout":
                return f"newTab refused: {str(response['error'])[:200]}"
            current = workspace
        response = run_script_action(control, f"openBrowser.{engine}", {"url": pages.url("engine", key)})
        if response.get("error") and error_code(response) != "timeout":
            return f"openBrowser.{engine} refused: {str(response['error'])[:200]}"
        if not loaded(pages, key):
            return f"{engine} page {key} did not load in {PAGE_LOAD_S} s"
    expected = plan[-1][0] + 1
    count = workspace_count(control)
    if count != expected:
        return f"{count} workspaces after the build, expected {expected} (a newTab that timed out, or a restored session: --fresh)"
    return None


def tab_kinds(app_pid, bundle):
    """classify's kinds plus the rest of the app's process set (procs.Instance: its whole process tree, processes
    run from its bundle, and the processes macOS counts it responsible for): every Chromium process, not only the
    app's direct children, and the WebKit XPC processes, which the ps parent walk misses."""
    kinds = classify(app_pid, bundle)
    for pid, cmd in procs.Instance(bundle, app_pid).pids().items():
        if pid in kinds:
            continue
        chromium = chromium_kind(cmd)
        if chromium is not None:
            kinds[pid] = chromium
        elif "com.apple.WebKit." in cmd:
            kinds[pid] = procs.kind_of(cmd)
    return kinds


def is_helper(kind):
    """A browser engine process: a Chromium helper or host (tab_pages.chromium_kind) or a WebKit XPC process."""
    return kind.startswith(("cef-", "webkit-"))


# navigator.vendor of each engine (tab_pages.py `engine` pages): Blink's NavigatorID::vendor
# (third_party/blink/renderer/core/frame/navigator_id.cc) and WebKit's NavigatorBase::vendor.
ENGINE_VENDORS = {"chromium": "Google Inc.", "webkit": "Apple Computer, Inc."}
# debug.cef states (CEFStartReport.state) in which Chromium is starting or running in the app.
CEF_STARTED = ("loading", "loaded", "ready")


def engine_problems(engine, cef, kinds, loaded, keys, vendors):
    """Why the pages may not be real `engine` pages: a page that never loaded, or that reported another engine's
    navigator.vendor (each page names the engine that drew it); a `debug.cef` that did not answer. For Chromium a
    debug.cef unavailable reason, WebKit fallback or state other than ready, or no Chromium renderer; for WebKit a
    default engine other than webkit, Chromium started, or any Chromium process."""
    problems = [f"page {key} never loaded" for key in keys if key not in loaded]
    wrong = [f"{key}={vendors.get(key)!r}" for key in keys if vendors.get(key) != ENGINE_VENDORS[engine]]
    if wrong:
        problems.append(f"pages not drawn by {engine} (navigator.vendor): {', '.join(wrong)[:200]}")
    if not isinstance(cef, dict) or cef.get("error"):
        return problems + [f"debug.cef answered {str(cef)[:80]}"]
    names = set(kinds.values())
    if engine == "chromium":
        if cef.get("unavailable"):
            problems.append(f"Chromium unavailable: {str(cef.get('unavailable'))[:160]}")
        if cef.get("fallback"):
            problems.append(f"WebKit fallbacks: {str(cef.get('fallback'))[:160]}")
        if cef.get("state") != "ready":
            problems.append(f"Chromium state {cef.get('state')}, not ready")
        if "cef-renderer" not in names:
            problems.append("no Chromium renderer process")
    else:
        if cef.get("default_engine") != "webkit":
            problems.append(f"default engine {cef.get('default_engine')}, not webkit")
        if cef.get("state") in CEF_STARTED:
            problems.append(f"Chromium state {cef.get('state')}: Chromium started in a WebKit run")
        chromium = sorted(name for name in names if name.startswith("cef-"))
        if chromium:
            problems.append(f"Chromium processes run in a WebKit run: {', '.join(chromium)}")
    return problems


def shown_problems(visibility, keys):
    """Exactly one page shown, the last one opened (each page POSTs every document.visibilityState change)."""
    shown = [key for key in keys if visibility.get(key) == "visible"]
    if shown != keys[-1:]:
        return [f"pages shown: {', '.join(shown) or 'none'}; expected only {keys[-1]}"]
    return []


def window_rows(kinds, start, end, wall):
    """Per-process rows of a window from two procs.usage reads per pid. wakeups_per_s counts interrupt wakeups
    (idle-budget.json's definition, Chrome's GetIdleWakeupsPerSecond); package-idle wakeups are apart. A process
    that came or went in the window is a partial row with no rates."""
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


def tabs10_metrics(rows, main_wakes, wakes_span):
    """{result-v1 metric: value or None}. A judged kind (app, daemon) with a partial row has no value, and no sum
    over it has. Helpers sum their complete rows (a helper that came or went is a note: helper_notes). Main wakes
    need debug.hangs `main_wakes` at both ends and are divided by `wakes_span`, the time between those two replies."""
    def kind_sum(match, complete_only=False):
        picked = [row for row in rows if match(row["kind"])]
        if complete_only:
            picked = [row for row in picked if not row.get("partial")]
        if not picked or any(row.get("partial") for row in picked):
            return None
        return round(sum(row["wakeups_per_s"] for row in picked), 3)

    app, daemon = kind_sum(lambda kind: kind == "app"), kind_sum(lambda kind: kind == "daemon")
    wakes = None
    if main_wakes is not None and wakes_span > 0:
        wakes = round((main_wakes[1] - main_wakes[0]) / wakes_span, 3)
    return {
        "idle.tabs-10.app_daemon_wakeups_per_s": None if app is None or daemon is None else round(app + daemon, 3),
        "idle.tabs-10.main_wakes_per_s": wakes,
        "idle.tabs-10.app_wakeups_per_s": app,
        "idle.tabs-10.daemon_wakeups_per_s": daemon,
        "idle.tabs-10.helper_wakeups_per_s": kind_sum(is_helper, complete_only=True),
    }


def helper_notes(rows):
    """One note per helper that came or went in the window: left out of helper_wakeups_per_s, not a failure."""
    return [f"{row['kind']} {row['pid']} {row['note']}: not in helper_wakeups_per_s"
            for row in rows if row.get("partial") and is_helper(row["kind"])]


def reply_result(reply):
    return reply.get("result") if isinstance(reply, dict) and "result" in reply else reply


def main_wakes_of(reply):
    """debug.hangs `main_wakes` (the main run loop's wakes from sleep), or None when the build has no counter."""
    result = reply_result(reply)
    value = result.get("main_wakes") if isinstance(result, dict) else None
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def measure_tabs10(app_pid, bundle, seconds, control, engine, pages, keys):
    """One window with no app read inside it: debug.hangs, a quiet gap, the counters; the counters, then
    debug.hangs, debug.cef and the engine and shown-page checks. Main wakes are timed by the debug.hangs replies,
    the process counters by their own reads."""
    wakes0 = main_wakes_of(control.call("debug.hangs", {"limit": 0}, timeout=30))
    hangs0 = time.monotonic()
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
    wakes_span = time.monotonic() - hangs0
    rows = window_rows(kinds, start, end, wall)
    main_wakes = None if wakes0 is None or wakes1 is None else (wakes0, wakes1)
    cef = reply_result(control.call("debug.cef", timeout=30))
    problems = (engine_problems(engine, cef, kinds, pages.loaded, keys, pages.vendors)
                + shown_problems(pages.visibility, keys))
    return {"wall_s": round(wall, 1), "main_wakes_span_s": round(wakes_span, 1), "engine": engine,
            "processes": rows, "metrics": tabs10_metrics(rows, main_wakes, wakes_span), "notes": helper_notes(rows),
            "engine_problems": problems, "visibility": {key: pages.visibility.get(key) for key in keys},
            "vendors": {key: pages.vendors.get(key) for key in keys}}


def record_tabs10(bench, engine, metrics, target_ref_type):
    """Writes each measured metric as one result-v1 file through BenchApp.record; returns (paths, failures).
    `target_ref_type` is perf_result.TargetRef (a path + key reference). A judged metric (one with a limit) that has
    no value or no written result is a failure; a reported one with no value is left out (the window's notes say
    why)."""
    paths, failures = [], []
    for metric, ref in TABS10_METRICS.items():
        value = metrics.get(metric)
        if value is None:
            if ref:
                failures.append(f"{TABS10}: {metric} not measured (no result written)")
            continue
        target_ref = None
        if ref and "target" in ref:
            target_ref = ref["target"].format(engine=engine)
        elif ref:
            target_ref = target_ref_type(path=ref["path"], key=ref["key"])
        try:
            paths.append(bench.record(TABS10_STORIES[engine], metric, "per_s", [value], "lower", engine, target_ref))
        except (OSError, RuntimeError, ValueError) as error:  # the ndjson write, bench_launch.RecordError, perf_result.ResultError
            failures.append(f"{TABS10}: {metric} result not written: {error}")
    return paths, failures


def judge_tabs10(result, bench, engine, target_ref_type):
    """Writes a measured window's results when its pages were real `engine` pages; returns why nothing (or not
    everything) was written: the engine problems, or a judged metric that had no value or no valid result."""
    if result["engine_problems"]:
        return result["engine_problems"] + [f"{TABS10}: not real {engine} pages, no result written"]
    result["results"], unwritten = record_tabs10(bench, engine, result["metrics"], target_ref_type)
    return unwritten


def run_tabs10(control, args, app_pid, bundle, pages, bench, target_ref_type):
    """Settles the built session, measures one window and writes its results. Returns (the scenario's report
    entry, invalid reasons): a socket error (the app gone or timed out), a reply that is not JSON or a file error
    is an invalid entry, never a traceback, so the report is still written and the exit is 2."""
    try:
        time.sleep(max(args.settle, TABS10_SETTLE_MIN_S))  # test script: past the hidden tabs' freeze
        keys = [key for _workspace, key in tabs10_plan()]
        result = measure_tabs10(app_pid, bundle, args.measure, control, args.engine, pages, keys)
        return result, judge_tabs10(result, bench, args.engine, target_ref_type)
    except (OSError, ValueError) as error:
        reason = f"measure failed: {error}"
        return {"skipped": reason}, [f"{TABS10}: {reason}, no result written"]


def exit_code(failures, invalid, no_fail):
    """2 when tabs-10 wrote no valid result (whatever --no-fail says), 1 when a criterion failed, else 0."""
    if invalid:
        return 2
    return 1 if failures and not no_fail else 0


def prepare(scenario, control, args, app_pid, bundle, pages=None):
    """Sets the scenario up; returns a skip reason or None."""
    if scenario == TABS10:
        return build_tabs10(control, pages, args.engine)
    refused = refused_reply

    def run_action(name, target=None, focus=None, **action_args):
        # A loaded machine can miss the app's 2 s control deadline; retry.
        params = action_request(name, action_args, target, focus)
        for _ in range(3):
            response = control.call("action.run", params, timeout=60)
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
    if scenario in APP_HIDDEN:
        return refused(show_all(control, hidden=True))
    if scenario == COVERED_WINDOW:
        return cover_window(control, run_action)
    if scenario == HIDDEN_PRINTING:
        return hide_printing_terminals(control, run_action, args.printing_terminals)
    return None


def action_request(name, action_args=None, target=None, focus=None):
    """action.run's params: `target` aims the action at one object (`tab:<id>`), `focus` True lets it change the
    view (a socket run without it may not select what it makes: ActionInvocation.allowsViewChange)."""
    params = {"action": name}
    if action_args:
        params["args"] = action_args
    if target:
        params["target"] = target
    if focus is not None:
        params["focus"] = focus
    return params


def topology_of(control):
    """snapshot.get's topology, or {} when it cannot be read."""
    topology = (read_result(control, "snapshot.get") or {}).get("topology")
    return topology if isinstance(topology, dict) else {}


def daemon_terminal_tabs(topology):
    """{tab id: workspace id} of the topology's terminal tabs that the daemon made (a `terminal` id: not the
    provisional tab of a create still in flight)."""
    tabs = {}
    for workspace in topology.get("workspaces") or []:
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("kind") == "terminal" and tab.get("id") and tab.get("terminal"):
                        tabs[tab["id"]] = workspace.get("id")
    return tabs


def shown_workspaces(topology):
    """The workspaces a window shows."""
    return {window.get("workspace") for window in topology.get("windows") or [] if window.get("workspace")}


def new_terminal_tab(control, known):
    """(tab id, workspace id) of a daemon terminal tab not in `known`, waited for up to PRINTING_TAB_WAIT_S, or
    None."""
    found = []

    def appeared():
        found[:] = [item for item in daemon_terminal_tabs(topology_of(control)).items() if item[0] not in known]
        return bool(found)
    return found[0] if wait_for(appeared, PRINTING_TAB_WAIT_S) else None


def hide_printing_terminals(control, run_action, count):
    """hidden-printing's setup: `count` new terminals, each shown as it opens (so it has a renderer) and sent
    PRINT_LOOP by its own `tab:<id>` target, then a new workspace shows and hides them. Returns a skip reason or
    None; the scenario is measured only when `count` distinct tabs took the loop and none of them shows."""
    known = set(daemon_terminal_tabs(topology_of(control)))
    printing = {}
    for index in range(count):
        reason = refused_reply(run_action("newSurface", focus=True))
        if reason:
            return f"printing terminal {index + 1}: newSurface: {reason}"
        made = new_terminal_tab(control, known)
        if made is None:
            return f"printing terminal {index + 1}: no new terminal tab in {PRINTING_TAB_WAIT_S} s"
        tab, workspace = made
        known.add(tab)
        reason = refused_reply(run_action("terminal.sendText", target=f"tab:{tab}", focus=False, text=PRINT_LOOP))
        if reason:
            return f"printing terminal {index + 1}: terminal.sendText: {reason}"
        printing[tab] = workspace
    reason = refused_reply(run_action("newTab", focus=True))
    if reason:
        return f"new workspace: {reason}"
    hosts = set(printing.values())
    if not wait_for(lambda: not hosts & shown_workspaces(topology_of(control)), PRINTING_TAB_WAIT_S):
        return f"the printing workspace still shows {PRINTING_TAB_WAIT_S} s after newTab"
    return None


def window_entries(control):
    """The app's windows as `debug.windows` lists them (id, visible, family_occluded, ...)."""
    return [w for w in (read_result(control, "debug.windows") or {}).get("windows") or [] if isinstance(w, dict)]


def feature_state(control, name):
    """`features.list`'s state of feature `name` ("on" or "off"), or None when the app does not list it."""
    listed = (read_result(control, "features.list") or {}).get("features") or []
    return next((f.get("state") for f in listed if isinstance(f, dict) and f.get("name") == name), None)


def same_frame(a, b):
    """Whether two [x, y, w, h] frames are the same within a point."""
    return (isinstance(a, list) and isinstance(b, list) and len(a) == len(b) == 4
            and all(abs(x - y) <= 1 for x, y in zip(a, b)))


def cover_window(control, run_action):
    """covered-window's setup: a new main window over the shown one, at its exact frame. Returns a skip reason or
    None; the covered window's id goes to COVERED for the measurement."""
    state = feature_state(control, OCCLUSION_FEATURE)
    if state != "on":
        return f"the feature {OCCLUSION_FEATURE} is {state or 'not listed'}"
    if main_window_shown(control) is not True:
        reason = refused_reply(run_action("showMainWindow"))
        if reason:
            return f"restore the window: {reason}"
        if not wait_for(lambda: main_window_shown(control) is True, 15):
            return "the main window is still minimized or hidden 15 s after showMainWindow"
    covered = next((w.get("id") for w in window_entries(control) if w.get("visible")), None)
    if not covered:
        return "no visible main window to cover (debug.windows)"
    # No frame given: debug.window_frame reports the window's frame and leaves it there.
    frame = (read_result(control, "debug.window_frame", {"window": covered}) or {}).get("frame")
    if not (isinstance(frame, list) and len(frame) == 4):
        return f"no frame for window {covered} (debug.window_frame)"
    before = {w.get("id") for w in window_entries(control)}

    def new_window():
        return next((w.get("id") for w in window_entries(control) if w.get("id") not in before and w.get("visible")), None)

    reason = refused_reply(run_action("newWindow"))
    if reason:
        return f"newWindow: {reason}"
    if not wait_for(lambda: new_window() is not None, 30):
        return "no new visible window 30 s after newWindow"
    moved = (read_result(control, "debug.window_frame", {"window": new_window(), "frame": frame}) or {}).get("frame")
    if not same_frame(moved, frame):
        return f"the cover window took {moved}, not the covered one's frame {frame} (debug.window_frame)"
    COVERED["window"] = covered
    return None


def covered_family_occluded(control):
    """Whether the covered window's occlusion family says occluded now (`debug.windows` family_occluded; None when
    the window or its family is not listed)."""
    entry = next((w for w in window_entries(control) if w.get("id") == COVERED.get("window")), None)
    return None if entry is None else entry.get("family_occluded")


def show_all(control, hidden):
    """Show/Hide All Windows from a script (idle-budget.py's hide_all): `hidden` hides the app, False shows it."""
    return control.call("action.run", {"action": "showHideAllWindows", "args": {"hidden": hidden}, "focus": False,
                                       "origin": "script"}, timeout=30)


# A scenario name that runs several, in order.
SCENARIO_GROUPS = {"mixed-hidden": ("mixed-hidden-visible", "mixed-hidden-app-hidden")}
MIXED_HIDDEN = ("mixed-hidden-visible", "mixed-hidden-app-hidden")
# The phases measured with the app hidden: Show/Hide All Windows hides it before and shows it again after.
APP_HIDDEN = ("mixed-hidden-app-hidden", "app-hidden")
COVERED_WINDOW = "covered-window"
HIDDEN_PRINTING = "hidden-printing"
# hidden-printing's command in each terminal: a line every 50 ms, as an agent's status output prints.
PRINT_LOOP = "while :; do date; sleep 0.05; done\r"
# Seconds hidden-printing waits for each new terminal tab, and for its workspace to hide.
PRINTING_TAB_WAIT_S = 15
# The scenarios of p03-rendering-097's occlusion family, judged on the main thread's wakes.
OCCLUSION_SCENARIOS = ("app-hidden", COVERED_WINDOW)
OCCLUSION_FEATURE = "windowOcclusionFamily"
# The window covered-window's setup covered (its `debug.windows` id).
COVERED = {}


def occlusion_launch(scenarios):
    """(env, local features) of a launch whose `scenarios` have an occlusion scenario: the user's draw of occluded
    windows, and the feature on as a Labs local choice (BenchApp local_features; an inherited CMUX_ENABLE_FEATURES
    never reaches the app, LaunchIdentity strips it). ({}, None) otherwise."""
    if not any(name in OCCLUSION_SCENARIOS for name in scenarios):
        return {}, None
    return {SHIPPING_DRAW_KEY: "1"}, {OCCLUSION_FEATURE: True}


def scenario_list(text):
    """The scenarios of `--scenarios`, groups expanded, each once, in the order given."""
    names = []
    for name in (part.strip() for part in text.split(",")):
        for item in SCENARIO_GROUPS.get(name, (name,)):
            if item and item not in names:
                names.append(item)
    return names


def scenario_order_error(scenarios):
    """Why `scenarios` can not run in this order, or None. Each scenario builds on the last one's tabs: tabs-10's
    10 pages are its whole session, and hidden-printing's loops never stop, so a scenario after it would be judged
    with that load still running."""
    if TABS10 in scenarios and scenarios != [TABS10]:
        return f"{TABS10} runs alone (--scenarios {TABS10})"
    if HIDDEN_PRINTING in scenarios and scenarios[-1] != HIDDEN_PRINTING:
        return f"{HIDDEN_PRINTING} runs last (its terminals keep printing)"
    return None


def refused_reply(response):
    """The error of a control reply, or None when it succeeded."""
    if response.get("ok") is False or "error" in response:
        return response.get("error") or "refused"
    return None


def criteria(scenario, result, args):
    """The --max-* limits of the legacy scenarios. tabs-10 is judged by its result-v1 references (targets.json,
    idle-budget.json) and judge_tabs10, not by these flags."""
    failures = []
    if scenario in (TABS10, HIDDEN_PRINTING) or "processes" not in result:
        return failures
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
    if scenario in OCCLUSION_SCENARIOS:
        main = result.get("main_wakeups_per_s")
        if main is None:
            failures.append(f"{scenario}: main thread wakeups not measured")
        elif main > args.max_main_wakeups:
            failures.append(f"{scenario}: main thread {main} wakeups/s > {args.max_main_wakeups}")
        if scenario == COVERED_WINDOW and result.get("covered_family_occluded") is not True:
            failures.append(f"{scenario}: the covered window's family was not occluded "
                            f"(family_occluded={result.get('covered_family_occluded')})")
    return failures


def print_result(scenario, result):
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
    for metric, value in result.get("metrics", {}).items():
        print(f"   {metric} = {value}")
    for note in result.get("notes", []):
        print(f"   note: {note}")


def run_scenarios(scenarios, app, control, args, app_pid, bundle, pages, bench, report):
    """Prepares, settles and measures each scenario into report["scenarios"]; returns (failures, invalid). invalid
    lists why tabs-10 wrote no result: the app gone before it, not built, or run_tabs10's reasons."""
    failures, invalid = [], []
    for scenario in scenarios:
        if app.poll() is not None:
            # Negative: killed by that signal (a crash, or someone else's cleanup).
            report["app_exit"] = app.returncode
            failures.append(f"{scenario}: the app exited ({app.returncode}) before this scenario")
            if TABS10 in scenarios:
                invalid.append(f"{TABS10}: the app exited ({app.returncode}), no result written")
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
            writer = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
            result, unwritten = run_tabs10(control, args, app_pid, bundle, pages, bench, writer.TargetRef)
            invalid += unwritten
            report["scenarios"][scenario] = result
            if "skipped" in result:
                print(f"== {scenario}: skipped ({result['skipped']})")
                continue
        else:
            time.sleep(args.settle)  # test script: let the scenario settle
            window_visible = main_window_shown(control) if scenario == "mixed-hidden-visible" else None
            occluded = covered_family_occluded(control) if scenario == COVERED_WINDOW else None
            result = measure(app_pid, bundle, args.measure, control)
            if scenario == "mixed-hidden-visible":
                result["window_visible"] = window_visible
            if scenario == COVERED_WINDOW:
                result["covered_family_occluded"] = occluded
            if scenario in APP_HIDDEN:
                result["shown_again"] = refused_reply(show_all(control, hidden=False)) is None
            report["scenarios"][scenario] = result
        failures += criteria(scenario, result, args)
        print_result(scenario, result)
    return failures, invalid


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
    parser.add_argument("--json", help="also write the report here (split-spring.sh --suite=bench-idle's report.json)")
    parser.add_argument("--max-cpu", type=float, default=0.5)
    parser.add_argument("--max-wakeups", type=float, default=5)
    parser.add_argument("--max-host-cpu", type=float, default=0.2)
    parser.add_argument("--max-host-wakeups", type=float, default=2)
    parser.add_argument("--max-helper-cpu", type=float, default=1.0)
    parser.add_argument("--max-mixed-wakeups", type=float, default=1.0,
                        help="mixed-hidden: app + daemon wakeups/s (default 1.0)")
    parser.add_argument("--max-main-wakeups", type=float, default=0.5,
                        help="mixed-hidden, app-hidden, covered-window: main run-loop wakes/s (default 0.5)")
    parser.add_argument("--hidden-tabs", type=int, default=10, help="mixed-hidden: Chromium tabs (default 10)")
    parser.add_argument("--hidden-terminals", type=int, default=5, help="mixed-hidden: terminals (default 5)")
    parser.add_argument("--printing-terminals", type=int, default=10,
                        help="hidden-printing: printing terminals (default 10)")
    parser.add_argument("--no-fail", action="store_true")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="an extra variable for the app (repeatable; for example a feature's DEV opt-in)")
    parser.add_argument("--setting", action="append", default=[], metavar="DOTTED.KEY=JSON",
                        help="a value written to the scratch cmux.json before launch (repeatable)")
    parser.add_argument("--fresh", action="store_true",
                        help="start from an empty daemon session for this tag (removes the tag's saved tabs)")
    args = parser.parse_args()
    scenarios = scenario_list(args.scenarios)
    order_error = scenario_order_error(scenarios)
    if order_error:
        parser.error(order_error)

    tag = args.tag
    bundle = args.app or os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app")
    # A Debug build's `cmux DEV`, else a bench build's own executable (an optimized build has only `cmux`).
    binary = main_binary(bundle) if os.path.isdir(os.path.join(bundle, "Contents/MacOS")) else ""
    if not os.path.exists(binary):
        raise SystemExit(f"bench-idle: no app at {bundle}")
    if args.fresh:
        # Saved tabs (a restored Chromium tab starts CEF) would change every scenario.
        shutil.rmtree(os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui"), ignore_errors=True)
    scratch = tempfile.mkdtemp(prefix=f"bench-idle-{tag}-")
    # The bench's own variables on top of bench_launch.py's defaults (--env adds or overrides them).
    env, local_features = occlusion_launch(scenarios)
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
    report_env = {"env": sorted(args.env), "settings": sorted(args.setting), "local_features": local_features}
    pages = None
    if not args.url or TABS10 in scenarios:
        pages = TabPages(default_kind="plain")
        args.url = args.url or pages.url()
    # mixed-hidden opens one page per tab (each its own URL), or --url in every tab.
    args.next_url = pages.url if pages else (lambda: args.url)
    args.mixed_ready = False
    args.has_layout_counters = False
    # One launch path for GUI benches (bench_launch.py): the console-session check, a refusal when this app already
    # runs, the tag's socket in the state folder, and the reason when the app does not come up.
    bench = BenchApp(bundle, out=args.out or scratch, config=config, window=None, screen="last", env=env,
                     log_name=f"app-{tag}-{args.label}.log", local_features=local_features)
    bench.launch(timeout=120, ready="system.ping")
    app = bench.process
    report = {"tag": tag, "sha": args.sha, "label": args.label, "app": bundle, "scenarios": {}, **report_env}
    failures = []
    invalid = []  # tabs-10 measurements that wrote no result (exit 2, whatever --no-fail says)
    try:
        control = wait_for_socket(bench.socket)
        try:
            identity = control.call("system.identify").get("result", {})
            report["has_debug_wakeups"] = "error" not in control.call("debug.wakeups", timeout=30)
            args.has_layout_counters = report["has_layout_counters"] = (
                read_result(control, "debug.layout_counters") is not None)
        except (OSError, ValueError) as error:
            control = None
            failures.append(f"the app's socket failed before the first scenario: {error}")
            if TABS10 in scenarios:
                invalid.append(f"{TABS10}: the app's socket failed ({error}), no result written")
        if control is not None:
            app_pid = identity.get("pid", app.pid)
            failures, invalid = run_scenarios(scenarios, app, control, args, app_pid, bundle, pages, bench, report)
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
    for path in [out] + ([args.json] if args.json else []):
        with open(path, "w") as handle:
            json.dump(report, handle, indent=2)
    print(f"bench-idle: wrote {out}")
    for failure in failures:
        print(f"FAIL {failure}")
    for reason in invalid:
        print(f"INVALID {reason}")
    code = exit_code(failures, invalid, args.no_fail)
    if code:
        sys.exit(code)


if __name__ == "__main__":
    main()
