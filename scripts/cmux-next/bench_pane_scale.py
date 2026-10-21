#!/usr/bin/env python3
"""Pane-scale stress benchmark for a tagged cmux-next build.

Builds a layout of N panes through the app's control socket (`action.run`,
the same path as menus and shortcuts), and at each checkpoint N in --counts
measures, for the app, its cmux-tui daemon, the terminal hosts and the
Chromium helpers:

  memory   phys_footprint per process (app, daemon, sum of hosts, helpers)
  idle     CPU % and wakeups/s over --idle seconds after --settle seconds of
           quiet; the debug.wakeups ledger owners that woke and the active
           frame clients (the budget is 0 % and 0 wakeups: no polling)
  churn    per phase (focus moves, pane resizes, window resizes, split/close,
           tab switches): op latency p50/p99/max, app and daemon CPU %,
           main-thread hang time (debug.hangs), frame intervals
           (debug.frames), and layout passes per op when the build has
           debug.layout_counters

Shapes (--shape):
  grid     columns of rows: --rows rows per column, then a new column
           (columns past the window width scroll offscreen)
  nested   per column a split tree of depth --depth: splitRight and
           splitDown alternate on the newest pane, then a new column
  mixed    grid, with every --browser-every-th new pane a browser split
           (at most --max-browsers)
--tabs T adds T-1 extra tabs to every pane at each checkpoint (new tabs open
the new-tab page, so they are hidden tabs that hold no PTY).

macOS gives every terminal one PTY: kern.tty.ptmx_max (default 511, hard cap
999) is shared by the whole host. The bench stops before a checkpoint whose
terminals would leave fewer than --pty-margin free PTYs and records it as
skipped with the numbers.

Run it on the GUI host (cmux-lawrence-2 through `nx-remote --needs gui`),
never on a laptop. The tagged app must not be running; the bench launches it
in a clean environment without activation (bench_idle.py), quits it, and
ends its daemon's terminals at the end.

Usage:
  scripts/cmux-next/bench_pane_scale.py --tag TAG [--app PATH]
      [--counts 16,64,256,1024] [--shape grid|nested|mixed] [--rows 4]
      [--depth 4] [--tabs 1] [--browser-every 8] [--max-browsers 4]
      [--settle 10] [--idle 20] [--ops 40] [--phases focus,resize,window,churn,tabs,status]
      [--pty-margin 64] [--label NAME] [--out DIR] [--keep-running]

Writes <out>/<sha>-pane-scale-<label>.json (default
artifacts/cmux-next-bench); scripts/cmux-next/pane_scale_report.py turns one
or more of those into an HTML table.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_idle import Client, classify, process_table, usage, wait_for_socket  # noqa: E402
from daemon_teardown import end_terminals  # noqa: E402


class _ThreadInfo(ctypes.Structure):
    """struct proc_threadinfo (sys/proc_info.h)."""
    _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


def thread_times(pid):
    """{thread handle: (name, cpu_ns)} for every thread of `pid`, read from
    outside (proc_pidinfo PROC_PIDLISTTHREADS / PROC_PIDTHREADINFO), so the
    probe adds no wakeup to the app."""
    handles = (ctypes.c_uint64 * 4096)()
    size = _libproc.proc_pidinfo(pid, 6, ctypes.c_uint64(0), handles, ctypes.sizeof(handles))
    out = {}
    for handle in handles[:max(0, size) // 8]:
        info = _ThreadInfo()
        if _libproc.proc_pidinfo(pid, 5, ctypes.c_uint64(handle), ctypes.byref(info), ctypes.sizeof(info)) <= 0:
            continue
        out[handle] = (info.name.decode(errors="replace") or "(unnamed)", info.user_time + info.system_time)
    return out


def thread_activity(before, after, wall):
    """Threads that ran during the window, grouped by name: how many threads
    of that name exist, how many ran, and their CPU (us/s)."""
    groups = {}
    for handle, (name, cpu) in after.items():
        entry = groups.setdefault(name, {"name": name, "threads": 0, "ran": 0, "cpu_us_per_s": 0.0})
        entry["threads"] += 1
        # A thread started inside the window counts from zero.
        delta = cpu - before[handle][1] if handle in before else cpu
        if delta > 0:
            entry["ran"] += 1
            entry["cpu_us_per_s"] += delta / 1000 / wall
    rows = [g for g in groups.values() if g["ran"]]
    for g in rows:
        g["cpu_us_per_s"] = round(g["cpu_us_per_s"], 1)
    return sorted(rows, key=lambda g: -g["cpu_us_per_s"])


def sysctl_int(name):
    try:
        return int(subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip())
    except ValueError:
        return None


def ptys_in_use():
    return len([n for n in os.listdir("/dev") if n.startswith("ttys") and n[4:].isdigit()])


def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))], 2)


class Bench:
    def __init__(self, args, control, app_pid, bundle):
        self.args = args
        self.control = control
        self.app_pid = app_pid
        self.bundle = bundle
        self.has = {}
        methods = control.call("system.identify").get("result", {}).get("methods", [])
        for name in ("debug.hangs", "debug.frames", "debug.wakeups", "debug.layout_counters", "debug.layers"):
            self.has[name] = name in methods
        self.terminals_created = 0
        self.browsers_created = 0
        self.refusals = []

    # -- topology -----------------------------------------------------------

    def topology(self):
        return self.control.call("snapshot.get", timeout=60).get("result", {})

    def counts(self):
        """(panes, tabs, terminal tabs) in the focused workspace's screens."""
        snap = self.topology()
        topo = snap.get("topology", {})
        focus = (topo.get("focus") or {}).get("workspace")
        panes = tabs = terminals = 0
        for workspace in topo.get("workspaces", []):
            if focus and workspace.get("id") != focus:
                continue
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    panes += 1
                    for tab in pane.get("tabs", []):
                        tabs += 1
                        if tab.get("kind") == "terminal":
                            terminals += 1
        return panes, tabs, terminals

    def focused_pane(self):
        topo = self.topology().get("topology", {})
        return (topo.get("focus") or {}).get("pane")

    # -- actions ------------------------------------------------------------

    def action(self, name, **args):
        start = time.monotonic()
        response = self.control.action(name, timeout=120, **args)
        elapsed = (time.monotonic() - start) * 1000
        error = response.get("error")
        if error:
            self.refusals.append({"action": name, "error": error})
        return elapsed, error

    def wait_panes(self, expected, limit_s=60):
        """Wait until the focused workspace shows `expected` panes; returns ms or None."""
        start = time.monotonic()
        while time.monotonic() - start < limit_s:
            if self.counts()[0] >= expected:
                return (time.monotonic() - start) * 1000
            time.sleep(0.02)  # test script: polls the app's published snapshot
        return None

    def create_pane(self, index):
        """Adds one pane by the shape's recipe; returns (action, rtt_ms, visible_ms, error)."""
        a = self.args
        if a.shape == "nested":
            per_column = 2 ** a.depth
            slot = index % per_column
            if slot == 0:
                name = "newColumn"
            else:
                name = "splitRight" if slot % 2 else "splitDown"
        else:
            slot = index % a.rows
            name = "newColumn" if slot == 0 else "newRow"
            if a.shape == "mixed" and index % a.browser_every == a.browser_every - 1 \
                    and self.browsers_created < a.max_browsers:
                name = "splitBrowserRight"
        before = self.counts()[0]
        rtt, error = self.action(name)
        if error:
            return name, rtt, None, error
        visible = self.wait_panes(before + 1)
        if name == "splitBrowserRight":
            self.browsers_created += 1
        else:
            self.terminals_created += 1
        return name, rtt, visible, None

    # -- measurement --------------------------------------------------------

    def processes(self):
        kinds = classify(self.app_pid, self.bundle)
        return kinds, {pid: usage(pid) for pid in kinds}

    @staticmethod
    def group(kinds, samples):
        out = {}
        for pid, kind in kinds.items():
            sample = samples.get(pid)
            if sample is None:
                continue
            entry = out.setdefault(kind, {"count": 0, "cpu_ns": 0, "wakeups": 0, "footprint_mb": 0.0})
            entry["count"] += 1
            entry["cpu_ns"] += sample[0]
            entry["wakeups"] += sample[1]
            entry["footprint_mb"] += sample[2] / 1048576
        return out

    def window(self, seconds=None, body=None):
        """CPU and wakeups per process kind over `seconds` of sleep or over `body()`."""
        kinds, before = self.processes()
        start = time.monotonic()
        result = None
        if body is None:
            time.sleep(seconds)  # test script: the idle measurement window itself
        else:
            result = body()
        wall = time.monotonic() - start
        # Hosts and helpers started inside the window count from zero.
        for pid, kind in classify(self.app_pid, self.bundle).items():
            if pid not in kinds:
                kinds[pid] = kind
                before[pid] = (0, 0, 0)
        after = {pid: usage(pid) for pid in kinds}
        # A process that exited inside the window has no end sample: count it
        # from neither side (closePane ends hosts during churn).
        for pid in [pid for pid, sample in after.items() if sample is None]:
            before.pop(pid, None)
            after.pop(pid, None)
        g0, g1 = self.group(kinds, before), self.group(kinds, after)
        rows = {}
        for kind, end in g1.items():
            begin = g0.get(kind)
            if not begin:
                continue
            rows[kind] = {
                "count": end["count"],
                "cpu_percent": round(100.0 * (end["cpu_ns"] - begin["cpu_ns"]) / (wall * 1e9), 3),
                "wakeups_per_s": round((end["wakeups"] - begin["wakeups"]) / wall, 2),
                "footprint_mb": round(end["footprint_mb"], 1),
            }
        return {"wall_s": round(wall, 2), "processes": rows}, result

    def start_tickers(self):
        """Starts the status tickers (background workspaces through the tagged CLI); False when it cannot."""
        cli = self.args.status_cli or os.environ.get("NX_APP_CLI")
        if self.args.status_tickers <= 0:
            return False
        if not cli:
            self.refusals.append({"action": "status", "error": "no CLI for tickers (--status-cli or NX_APP_CLI)"})
            return False
        if getattr(self, "tickers_started", False):
            return True
        loop = ("while :; do for p in 5 15 25 35 45 55 65 75 85 95; do "
                "printf '\\033]7501;state=working:progress=%d\\033\\\\' $p; sleep 0.25; done; done")
        env = dict(os.environ, CMUX_TAG=self.args.tag)
        for i in range(self.args.status_tickers):
            done = subprocess.run([cli, "workspace", "create", "--name", f"bench tick {i}", "--shell", loop],
                                  env=env, capture_output=True, text=True, timeout=120)
            if done.returncode != 0:
                self.refusals.append({"action": "status", "error": (done.stdout + done.stderr).strip()[-300:]})
                return False
        self.tickers_started = True
        time.sleep(2.0)  # test script: let the tickers start printing before the measured window
        return True

    def debug(self, method, params=None):
        if not self.has.get(method):
            return None
        try:
            return self.control.call(method, params or {}, timeout=60).get("result")
        except (OSError, ValueError):
            return None

    def idle(self):
        time.sleep(self.args.settle)  # test script: let the layout settle
        self.debug("debug.wakeups", {"reset": True})
        threads_before = thread_times(self.app_pid)
        measured, _ = self.window(self.args.idle)
        threads_after = thread_times(self.app_pid)
        # Which app threads woke while idle (wakeups are per process only;
        # a thread that ran has CPU time), grouped by thread name.
        measured["app_threads"] = thread_activity(threads_before, threads_after, measured["wall_s"])[:20]
        report = self.debug("debug.wakeups") or {}
        measured["ledger"] = [e for e in report.get("ledger", []) if e.get("per_second", 0) > 0][:12]
        measured["active_frame_clients"] = report.get("active_frame_clients", [])
        return measured

    def phase(self, name, ops):
        """Runs `ops` [(action, args)] and returns latency, CPU, hangs, frames, layout passes."""
        self.debug("debug.hangs", {"clear": True})
        self.debug("debug.frames", {"action": "start"})
        layout_before = self.debug("debug.layout_counters")
        # LayoutPassGuard (P0 layout-loop lane): view layout passes by class.
        self.debug("debug.layers", {"reset_layout_passes": True})

        def body():
            latencies = []
            for action, args in ops:
                if action == "wait":
                    time.sleep(args["seconds"])  # test script: the measured window while the tickers print
                    latencies.append(0.0)
                    continue
                if action == "window_frame":
                    start = time.monotonic()
                    self.control.call("debug.window_frame", args, timeout=60)
                    latencies.append((time.monotonic() - start) * 1000)
                    continue
                rtt, _ = self.action(action, **args)
                latencies.append(rtt)
            return latencies

        busy = {"s": None}
        busy_start = time.monotonic()

        def settled_body():
            latencies = body()
            busy["s"] = time.monotonic() - busy_start
            # Observation work for the last ops runs after their replies.
            self.topology()
            time.sleep(1.0)  # test script: let trailing async apply work finish inside the window
            return latencies

        measured, latencies = self.window(body=settled_body)
        frames = self.debug("debug.frames", {"action": "stop"})
        hangs = self.debug("debug.hangs", {"limit": 3})
        layout_after = self.debug("debug.layout_counters")
        passes = (self.debug("debug.layers") or {}).get("layout_passes")
        measured.update({
            "ops": len(ops),
            # wall_s includes a 1 s settle after the last op; busy_s ends at the last op.
            "busy_s": round(busy["s"], 2) if busy["s"] is not None else None,
            "latency_ms": {"p50": pct(latencies, 0.5), "p99": pct(latencies, 0.99),
                           "max": round(max(latencies), 2) if latencies else None,
                           "mean": round(statistics.fmean(latencies), 2) if latencies else None},
        })
        if hangs is not None:
            measured["hangs"] = {k: hangs.get(k) for k in ("count", "total_ms", "max_ms", "long_frames",
                                                          "long_frame_max_ms", "frames_over_8_3ms", "max_gap_ms")}
            # The main-thread stack of each hang (the watchdog's sample), to name its cause.
            measured["hangs"]["records"] = [{k: r.get(k) for k in ("kind", "duration_ms", "cpu_ms", "frames")}
                                            for r in hangs.get("records") or []]
        if frames is not None:
            measured["frames"] = {k: frames.get(k) for k in ("frames", "p50_ms", "p99_ms", "max_ms", "missed")}
        if layout_before is not None and layout_after is not None:
            measured["layout"] = diff_counters(layout_before, layout_after, len(ops))
            # Which call sites made the counted calls (debug.layout_counters `sources`).
            sb, sa = layout_before.get("sources") or {}, layout_after.get("sources") or {}
            measured["layout_sources"] = dict(sorted(((k, v - sb.get(k, 0)) for k, v in sa.items() if v - sb.get(k, 0) > 0),
                                                     key=lambda kv: -kv[1]))
        if isinstance(passes, dict):
            # debug.layers layout_passes (LayoutPassGuard): top_classes are the
            # busiest view classes since the reset at the phase start (top 20),
            # max_in_one_turn the most layout calls of one view in one window
            # layout, with its view class, window class and that window's limit.
            by_class = passes.get("top_classes") or []
            total = sum(p.get("passes", 0) for p in by_class)
            measured["layout_passes"] = {"top20_total": total, "top20_per_op": round(total / len(ops), 2) if ops else None,
                                         "max_in_one_window_layout": passes.get("max_in_one_turn"),
                                         "max_view_class": passes.get("max_view_class"),
                                         "max_window_class": passes.get("max_window_class"),
                                         "max_window_limit": passes.get("max_window_limit"),
                                         "loops": passes.get("loops") or [],
                                         "top": by_class[:5]}
        return measured

    def phases(self, panes):
        n = self.args.ops
        plan = {
            "focus": [("focusNextPane", {})] * n,
            "resize": [("resizePaneRight" if i % 2 == 0 else "resizePaneLeft", {}) for i in range(n)],
            "window": [("window_frame", {"frame": [80, 80, 1500 if i % 2 == 0 else 1200, 950 if i % 2 == 0 else 800]})
                       for i in range(n)],
            "churn": [op for _ in range(max(1, n // 2)) for op in (("splitRight", {}), ("closePane", {}))],
            # nextSurface: Next Tab (Ctrl-Tab) in the focused pane.
            "tabs": [("nextSurface", {})] * n,
            # Status ticks: --status-tickers background workspaces print an OSC 7501
            # progress every 250 ms for --status-seconds; a tick should re-map no strip
            # of the shown panes (layout counters per tick stay near 0).
            "status": [("wait", {"seconds": self.args.status_seconds})],
        }
        out = {}
        # status runs last: its tickers keep printing after it (later phases would measure them).
        names = self.args.phases.split(",")
        names = [n for n in names if n != "status"] + (["status"] if "status" in names else [])
        for name in names:
            if name == "tabs" and self.args.tabs <= 1:
                continue
            if name not in plan:
                continue
            if name == "status" and not self.start_tickers():
                continue
            out[name] = self.phase(name, plan[name])
            if name == "status":
                # The window is one op; per tick = window totals / expected ticks (4/s per ticker).
                ticks = int(self.args.status_seconds * 4 * self.args.status_tickers)
                out[name]["ticks"] = ticks
                layout = out[name].get("layout") or {}
                out[name]["layout_per_tick"] = {k: round(v / ticks, 3) for k, v in layout.items()
                                                if not k.endswith("_per_op") and ticks}
        return out

    def add_tabs(self):
        """Gives every pane --tabs tabs (new-tab page tabs, hidden)."""
        if self.args.tabs <= 1:
            return None
        start = time.monotonic()
        panes, tabs, _ = self.counts()
        want = panes * self.args.tabs
        added = 0
        for _ in range(panes):
            for _ in range(self.args.tabs - 1):
                if tabs + added >= want:
                    break
                _, error = self.action("newTab.page")  # "newTab" is New Workspace
                if error:
                    break
                added += 1
            self.action("focusNextPane")
        return {"added": added, "seconds": round(time.monotonic() - start, 1)}


def diff_counters(before, after, ops):
    out = {}
    for key, value in after.items():
        if isinstance(value, (int, float)) and isinstance(before.get(key), (int, float)):
            delta = value - before[key]
            out[key] = delta
            out[key + "_per_op"] = round(delta / ops, 2) if ops else None
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app")
    parser.add_argument("--repo-root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
    parser.add_argument("--counts", default="16,64,256,1024")
    parser.add_argument("--shape", default="grid", choices=["grid", "nested", "mixed"])
    parser.add_argument("--rows", type=int, default=4)
    parser.add_argument("--depth", type=int, default=4)
    parser.add_argument("--tabs", type=int, default=1)
    parser.add_argument("--browser-every", type=int, default=8)
    parser.add_argument("--max-browsers", type=int, default=4)
    parser.add_argument("--settle", type=float, default=10)
    parser.add_argument("--idle", type=float, default=20)
    parser.add_argument("--ops", type=int, default=40)
    parser.add_argument("--phases", default="focus,resize,window,churn,tabs")
    parser.add_argument("--pty-margin", type=int, default=64)
    parser.add_argument("--label", default="run")
    parser.add_argument("--status-tickers", type=int, default=4)
    parser.add_argument("--status-seconds", type=float, default=5)
    parser.add_argument("--status-cli")
    parser.add_argument("--out")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--sample-seconds", type=int, default=0,
                        help="after each idle window, /usr/bin/sample the app for N seconds into the out dir")
    args = parser.parse_args()

    sha = subprocess.run(["git", "-C", args.repo_root, "rev-parse", "--short=12", "HEAD"],
                         capture_output=True, text=True).stdout.strip() or "unknown"
    tag = args.tag
    bundle = args.app or os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app")
    binary = os.path.join(bundle, "Contents/MacOS/cmux DEV")
    if not os.path.exists(binary):
        raise SystemExit(f"pane-scale: no app at {bundle}")
    if any(cmd.startswith(binary) for _, _, cmd in process_table()):
        raise SystemExit(f"pane-scale: {bundle} is already running; quit it first")
    # Start from an empty session: restored tabs would change every checkpoint.
    shutil.rmtree(os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui"), ignore_errors=True)
    scratch = tempfile.mkdtemp(prefix=f"pane-scale-{tag}-")
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
    }
    app = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"pane-scale: launched pid {app.pid}", flush=True)
    report = {
        "tag": tag, "sha": sha, "label": args.label, "app": bundle, "shape": args.shape, "rows": args.rows,
        "depth": args.depth, "tabs": args.tabs, "host": os.uname().nodename,
        "ptmx_max": sysctl_int("kern.tty.ptmx_max"), "checkpoints": [],
    }
    try:
        control = wait_for_socket(f"/tmp/cmux-debug-{tag}.sock", limit_s=120)
        identity = control.call("system.identify").get("result", {})
        app_pid = identity.get("pid", app.pid)
        bench = Bench(args, control, app_pid, bundle)
        report["debug_methods"] = bench.has
        # Wait for the launch terminal.
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and bench.counts()[0] < 1:
            time.sleep(0.25)  # test script: waiting for the first pane
        create_log = []
        for target in [int(c) for c in args.counts.split(",")]:
            if app.poll() is not None:
                report["app_exit"] = app.returncode
                print(f"pane-scale: the app exited ({app.returncode})", file=sys.stderr)
                break
            panes = bench.counts()[0]
            new = max(0, target - panes)
            new_terminals = new if args.shape != "mixed" else new - min(new // args.browser_every, args.max_browsers)
            limit = report["ptmx_max"]
            used = ptys_in_use()
            if limit and used + new_terminals + args.pty_margin > limit:
                skip = (f"PTY guard: {used} PTYs in use on the host + {new_terminals} new terminals "
                        f"+ {args.pty_margin} margin > kern.tty.ptmx_max {limit}")
                report["checkpoints"].append({"target": target, "skipped": skip})
                print(f"== N={target}: skipped ({skip})", flush=True)
                break
            build_start = time.monotonic()
            created = []

            def build():
                for i in range(panes, target):
                    name, rtt, visible, error = bench.create_pane(i)
                    created.append({"i": i, "action": name, "rtt_ms": round(rtt, 1),
                                    "visible_ms": round(visible, 1) if visible is not None else None, "error": error})
                    if error:
                        print(f"   create {i}: {name} refused: {error}", flush=True)
                        break

            build_window, _ = bench.window(body=build)
            create_log += created
            tabs_info = bench.add_tabs()
            panes, tabs, terminals = bench.counts()
            rtts = [c["rtt_ms"] for c in created]
            visibles = [c["visible_ms"] for c in created if c["visible_ms"] is not None]
            checkpoint = {
                "target": target, "panes": panes, "tabs": tabs, "terminals": terminals,
                "browsers": bench.browsers_created, "ptys_in_use": ptys_in_use(),
                "build": {"seconds": round(time.monotonic() - build_start, 1), "created": len(created),
                          "rtt_ms": {"p50": pct(rtts, 0.5), "p99": pct(rtts, 0.99), "max": max(rtts) if rtts else None},
                          "visible_ms": {"p50": pct(visibles, 0.5), "p99": pct(visibles, 0.99)},
                          "window": build_window, "refused": [c for c in created if c["error"]]},
                "tabs_added": tabs_info,
            }
            print(f"== N={target}: panes {panes} tabs {tabs} terminals {terminals} "
                  f"build {checkpoint['build']['seconds']} s, create rtt p50 {checkpoint['build']['rtt_ms']['p50']} ms",
                  flush=True)
            checkpoint["idle"] = bench.idle()
            for row in checkpoint["idle"].get("app_threads", [])[:8]:
                print(f"   idle thread {row['name'][:40]:<40} {row['ran']}/{row['threads']} ran, {row['cpu_us_per_s']} us/s", flush=True)
            if args.sample_seconds:
                # After the idle window (sample suspends threads): stacks of what woke.
                path = os.path.join(args.out or os.path.join(args.repo_root, "artifacts/cmux-next-bench"),
                                    f"sample-{args.label}-{panes}.txt")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                subprocess.run(["/usr/bin/sample", str(app.pid), str(args.sample_seconds), "-mayDie", "-file", path],
                               capture_output=True, timeout=args.sample_seconds + 120)
                checkpoint["sample"] = path
            for kind, row in sorted(checkpoint["idle"]["processes"].items()):
                print(f"   idle {kind:<14} x{row['count']:<5} {row['cpu_percent']:>7.3f}% CPU "
                      f"{row['wakeups_per_s']:>8.2f} wk/s {row['footprint_mb']:>9.1f} MB", flush=True)
            checkpoint["phases"] = bench.phases(panes)
            for name, ph in checkpoint["phases"].items():
                app_row = ph["processes"].get("app", {})
                print(f"   {name:<7} p50 {ph['latency_ms']['p50']} p99 {ph['latency_ms']['p99']} ms, "
                      f"app {app_row.get('cpu_percent')}% CPU, hangs {ph.get('hangs', {}).get('total_ms')} ms, "
                      f"frames p99 {ph.get('frames', {}).get('p99_ms')} ms, layout {ph.get('layout')}", flush=True)
            report["checkpoints"].append(checkpoint)
            if created and created[-1]["error"]:
                break
        report["create_log"] = create_log
        report["refusals"] = bench.refusals[:50]
    finally:
        if not args.keep_running:
            try:
                Client(f"/tmp/cmux-debug-{tag}.sock", timeout=10).call("debug.quit", {"fixture_quit": "end-sessions"})
            except (OSError, ValueError):
                pass
            try:
                app.wait(timeout=30)
            except subprocess.TimeoutExpired:
                app.send_signal(signal.SIGTERM)
                try:
                    app.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    app.kill()
            try:
                report["teardown"] = end_terminals(os.path.join(bundle, "Contents/Resources/bin/cmux-tui"), tag)
            except Exception as error:  # noqa: BLE001 - teardown is best effort; report it
                print(f"pane-scale: daemon teardown: {error}", file=sys.stderr)
    out_dir = args.out or os.path.join(args.repo_root, "artifacts/cmux-next-bench")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{sha}-pane-scale-{args.label}.json")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=2)
    print(f"pane-scale: wrote {out}")


if __name__ == "__main__":
    main()
