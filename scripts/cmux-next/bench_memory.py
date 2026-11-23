#!/usr/bin/env python3
"""Resident memory of a cmux-next app and every process it owns.

Measures resident size (RSS) and physical footprint (what Activity Monitor
calls Memory) per process: the app, its Chromium helpers, the WebKit
processes it is responsible for (agent chats and pages), the cmux-tui
daemons and terminal hosts, acpmux, and the other bundled helpers. It
builds workspaces over the app socket (each takes the next entry of
--mix, for example terminal+chat, terminal+browser, terminal), measures at
each count in --workspaces after --settle seconds, then optionally churns:
for --churn-minutes it opens a workspace of the mix and closes it again,
and every --sample-minutes it lets the app settle at the same workspace
count and samples again. Growth across those samples at an unchanged
workspace count is a leak.

--tabs 1,10,20 measures browser tabs instead (the Ardia/Helium/Dia comparison):
N Chromium tabs in the launch workspace's focused pane, one URL each from --urls
(`local`: N distinct sites `siteN.localhost` served by this script, the same
page each, so a run is deterministic; `real`: 20 well-known public sites; or a
comma list). Each count is sampled after --settle seconds.

--axis page-hidden|page-visible (perf-10x-idle.sh axes=) opens Chromium pages that ask for every animation
frame, each on its own site (a renderer each), hidden (a workspace each, the launch workspace shown) or visible
(a pane each). Each sample then has `page_frames` (the frames per second the pages got, by visibility: a hidden
page should get none) and each renderer its base priority (`priority`; per kind `priorities`: Chromium's own
process priority lowers a renderer whose pages are all hidden). page-hidden ends with `show_latency`: a few
hidden pages shown again one at a time, from the request to their first frame.

--purge-hidden also measures, after each count's sample, what Chromium's own
memory purge gives back with nothing reloaded: every hidden cmux page's renderer
gets a critical memory-pressure notice (DevTools Memory.simulatePressureNotification
through `debug.cef_page_devtools`, a bench or DEV build), then the app settles and
is sampled again as `purged-N` (one count per run, so `idle-N` is an unpurged app). The page keeps its DOM, scroll and state, as the
"a page never reloads unless the person asks" design (#25791) requires.

--release-hidden-chats MINUTES measures lossless discard of hidden agent chats (Leo, 2026-11-07:
"if it really isn't being used after a while, can't things be more aggressive?"): the app runs with
the app runs with discard off until the count's `idle-N` sample, then the bench sets
`agents.hiddenChats.discardAfterMinutes` MINUTES and `agents.hiddenChats.discard` on through the
app's `settings.set` (its own settings writer; the reply's values are kept in the sample), so the
baseline holds no released chat. It waits for the hidden chats to be
released, samples `released-N` with the live Chromium page count, then shows the --restore-chats oldest
workspaces' chat tabs one at a time and times each chat back on screen with the app's own chat-open trace
(`debug.chat_open_trace`: first content, first kept image, longest empty run). The trace binds only to
a chat that loads again; a chat whose page stayed live shows at once and is counted as `live`, not
timed. One count per run, like --purge-hidden.

--diff-tab small|large gives the count's idle window a visible diff tab (diff_tab_cells.py): a
repository of that size with uncommitted changes, its diff tab opened and shown in the focused pane
before the settle. The page asks the app for the repository's fingerprint on a timer while it is
visible, each 4 s with the focus and each 30 s without it, so the window is --measure seconds when
the page says that it has the focus and --diff-unfocused-measure seconds when it does not.
--diff-scroll sends the page wheel events for the whole window. --child-time adds `child_cpu_pct`
to each process and kind: the CPU time of the children that ended in the window (the daemon's git
runs), which no live process's own time has. It is the whole CPU of each such child, also its part
from before the window. The run first proves the read with a child of its own (`child_time_check`
in the report); when that fails, no `child_cpu_pct` is written. One count per run, like --purge-hidden.

Two ways to run (macOS only, a fleet or capture mini, never a laptop):
  attach  --socket PATH --app-pid PID: an app someone else launched, for
          example by `capture-host launch` into a capture slot (capture
          leases end after 10 minutes, so churn there stays short).
  launch  no --socket: starts the bundle's app with a scratch HOME,
          TMPDIR and config, and quits it at the end.
          --relaunch-restored [cold|warm]: a returning user's launch. The first
          launch opens and shows one terminal workspace and quits (the session
          saves); the measured launch is the relaunch into the same scratch,
          checked to show a terminal workspace and not Home (an empty launch lands
          on Home, FirstWorkspace.swift). cold ends what outlived the quit
          first. `relaunch` in the report. --env NAME=VALUE sets the app's env.

Usage:
  bench_memory.py --app BUNDLE [--socket PATH --app-pid PID]
      [--workspaces 1,10,30] [--mix terminal+chat,terminal+browser,terminal]
      [--settle 30] [--measure 0] [--churn-minutes 0] [--sample-minutes 5]
      [--url URL] [--top 15] [--config JSON] [--fake-agent SCRIPT] [--purge-hidden]
      [--release-hidden-chats MINUTES [--restore-chats 10]] [--out FILE.json]
      [--diff-tab small|large [--diff-scroll] [--diff-unfocused-measure 300]] [--child-time]
  bench_memory.py --app BUNDLE --tabs 1,10,20 [--urls local|real|URL,URL,...] [--settle 30]

Prints a table per measurement (top processes by footprint, totals per
kind) and writes every sample to --out.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

try:
    import chat_renderer_crash  # noqa: E402  (CMUX_BENCH_CHAT_RENDERER_CRASH: the chat renderer crash test)
except ModuleNotFoundError:
    # perf-idle-ab.sh copies this file alone and the frame-pacing job's sparse checkout omits the helper:
    # without it the crash test is off, and asking for it is an error.
    if os.environ.get("CMUX_BENCH_CHAT_RENDERER_CRASH") == "1":
        raise

    class chat_renderer_crash:  # noqa: N801
        @staticmethod
        def enabled() -> bool:
            return False



def _thread_wakes():
    """thread_wakes.py beside this file (thread names and --attribute-trace), or None: a sparse checkout
    that copies only this script (cmux-next-frame-pacing.yml) still runs everything but those."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import thread_wakes
    except ImportError:
        return None
    return thread_wakes

def _diff_tab_cells():
    """diff_tab_cells.py beside this file (--diff-tab, --child-time); a run that names neither needs none."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import diff_tab_cells
    return diff_tab_cells


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
try:
    _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
    _responsible.restype = ctypes.c_int
    _responsible.argtypes = [ctypes.c_int]
except AttributeError:  # an OS without the call: WebKit processes are not attributed
    _responsible = None

MB = 1048576.0


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase()
_libsystem.mach_timebase_info(ctypes.byref(_timebase))


def usage(pid: int):
    """(resident, footprint, lifetime max footprint, cpu ns, wakeups), or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    # RUSAGE_INFO_V4 in u64 words: uuid (2), user, system (mach ticks), pkg
    # idle wakeups, interrupt wakeups, pageins, wired (7), resident (8),
    # phys_footprint (9), ... ri_lifetime_max_phys_footprint (30).
    cpu_ns = (buf[2] + buf[3]) * _timebase.numer // _timebase.denom
    return buf[8], buf[9], buf[30], cpu_ns, buf[4] + buf[5]


class _TaskInfo(ctypes.Structure):
    # struct proc_taskinfo (sys/proc_info.h, PROC_PIDTASKINFO).
    _fields_ = [("virtual_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64), ("total_user", ctypes.c_uint64),
                ("total_system", ctypes.c_uint64), ("threads_user", ctypes.c_uint64), ("threads_system", ctypes.c_uint64),
                ("policy", ctypes.c_int32), ("faults", ctypes.c_int32), ("pageins", ctypes.c_int32),
                ("cow_faults", ctypes.c_int32), ("messages_sent", ctypes.c_int32), ("messages_received", ctypes.c_int32),
                ("syscalls_mach", ctypes.c_int32), ("syscalls_unix", ctypes.c_int32), ("csw", ctypes.c_int32),
                ("threadnum", ctypes.c_int32), ("numrunning", ctypes.c_int32), ("priority", ctypes.c_int32)]


def task_priority(pid: int) -> int | None:
    """The process's base scheduling priority (`pti_priority`), or None once it is gone. It tells the CPU band
    Chromium's own process priority put a renderer in (`base::Process::SetPriority`, process_mac.cc: a task
    role and the App Nap suppression policy): about 47 for a foreground renderer, lower for a renderer Chromium
    backgrounded, 4 for the darwin background band (PRIO_DARWIN_BG), which ARCHITECTURE 6.4 rules out for work
    that must answer."""
    info = _TaskInfo()
    if _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(4), ctypes.c_uint64(0), ctypes.byref(info),
                             ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    return info.priority


def disk_io(pid: int):
    """(bytes read, bytes written, logical bytes written) over the process's life, or None once the pid is
    gone. RUSAGE_INFO_V4 words 18 and 19 (ri_diskio_bytesread, ri_diskio_byteswritten: what reached the
    storage device, page-ins and write-backs included) and 29 (ri_logical_writes: bytes the process wrote,
    before the cache folds them)."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    return buf[18], buf[19], buf[29]


def gpu_stats() -> dict:
    """The GPU's own counters now (`ioreg -r -c IOAccelerator`, PerformanceStatistics of the first
    accelerator that has them): device, renderer and tiler utilization % and the memory it holds. macOS
    gives no per-process GPU time and no frame count here; the GPU process's CPU is in its kind's row."""
    try:
        out = subprocess.run(["ioreg", "-r", "-c", "IOAccelerator", "-d", "1", "-a"], capture_output=True,
                             timeout=10).stdout
        entries = plistlib.loads(out) if out else []
    except (subprocess.TimeoutExpired, OSError, ValueError, plistlib.InvalidFileException):
        return {}
    for entry in entries if isinstance(entries, list) else [entries]:
        stats = entry.get("PerformanceStatistics") if isinstance(entry, dict) else None
        if isinstance(stats, dict):
            return {key: value for key, value in stats.items() if isinstance(value, (int, float))}
    return {}


def gpu_summary(samples: list[dict]) -> dict:
    """The mean of each GpuSampler key over a window's gpu_stats() samples (memory in MB)."""
    if not samples:
        return {"error": "ioreg gave no IOAccelerator PerformanceStatistics"}
    out: dict = {"samples": len(samples)}
    for key in GpuSampler.KEYS:
        values = [s[key] for s in samples if key in s]
        if not values:
            continue
        name = key.lower().replace(" %", "_pct").replace(" ", "_")
        mean = sum(values) / len(values)
        if key.endswith("memory"):
            out[name + "_mb"] = round(mean / MB, 1)
        else:
            out[name] = round(mean, 2)
    return out


class GpuSampler:
    """Samples gpu_stats() every `interval` seconds from a thread of this script (an ioreg child, nothing
    the measured app runs) and averages each counter over the window."""

    KEYS = ("Device Utilization %", "Renderer Utilization %", "Tiler Utilization %",
            "In use system memory", "Alloc system memory")

    def __init__(self, interval: float = 5.0):
        import threading
        self.interval, self.samples = interval, []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stop_event.is_set():
            got = gpu_stats()
            if got:
                self.samples.append(got)
            self.stop_event.wait(self.interval)

    def start(self):
        self.thread.start()

    def finish(self) -> dict:
        self.stop_event.set()
        self.thread.join(15)
        return gpu_summary(self.samples)


def process_table():
    rows = []
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def in_bundle(cmd: str, bundle: str) -> str | None:
    """`cmd` relative to the bundle, or None. The app runs from the real
    path (/private/tmp/...) while its daemons keep the path it handed them
    (/tmp/...), so every spelling counts, whichever one the caller passed."""
    for root in bundle_roots(bundle):
        if cmd.startswith(root + "/"):
            return cmd[len(root):]
    return None


def bundle_roots(bundle: str) -> tuple[str, ...]:
    """Every spelling of `bundle` a process command line can carry: as given, its realpath, and
    each without /private (xbench --app /tmp/X.app ran from /private/tmp/X.app and end_bundle
    missed it)."""
    given = bundle.rstrip("/")
    real = os.path.realpath(given)
    return tuple(dict.fromkeys((given, real, given.removeprefix("/private"), real.removeprefix("/private"))))


def is_app_process(cmd: str, bundle: str) -> bool:
    """Whether `cmd` is the bundle's own app (its Contents/MacOS binary), not its clone cleanup helper."""
    rel = in_bundle(cmd, bundle)
    return rel is not None and rel.startswith("/Contents/MacOS/") and not is_clone_cleanup(cmd)


def kind_of(cmd: str, bundle: str) -> str:
    rel = in_bundle(cmd, bundle) or cmd
    if " Helper" in rel:
        for flag, name in (("--type=renderer", "cef-renderer"), ("--type=gpu-process", "cef-gpu"),
                           ("--type=utility", "cef-utility"), ("--type=plugin", "cef-plugin")):
            if flag in rel:
                return name
        return "cef-helper"
    if rel.startswith("/Contents/MacOS/"):
        return "app"
    if "/bin/cmux-holder" in rel:
        return "holder"
    if "/bin/cmux-tui" in rel or "/bin/cmux " in rel or rel.endswith("/bin/cmux"):
        return tui_kind(rel)
    if "/bin/acpmux" in rel:
        return "acpmux-" + (rel.split("/bin/acpmux", 1)[1].split() or ["agent"])[0]
    if "/bin/" in rel:
        return rel.split("/bin/", 1)[1].split()[0]
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    return os.path.basename(cmd.split()[0])


def tui_kind(rel: str) -> str:
    """The kind of a cmux-tui (or cmux) process, by its first argument. The daemon starts with a flag
    (`--headless ...`) or as `<scope> start`. Every other bundle process of the binary runs one hidden
    subcommand (`__terminal-host`, `__holder`, `__provider-authority`, ...) and gets a kind of its own,
    so the daemon's row is the daemon alone (it was 4 processes summed into one 86 MB `tui-daemon`)."""
    tail = rel.split("/bin/", 1)[1].split()[1:] if "/bin/" in rel else rel.split()[1:]
    first = tail[0] if tail else ""
    if first == "__terminal-host":
        return "terminal-host"
    if first == "__holder":
        return "holder"
    if first.startswith("__"):
        return "tui-" + first.lstrip("_")
    if first and not first.startswith("-") and (tail[1:2] != ["start"]):
        return "cmux-" + first
    if "--session cmux-chief" in rel:
        return "tui-daemon-chief"
    return "tui-daemon"


# The processes the daemon starts with a bare argv[0] (host_exe.rs `arg0("cmux-tui")`, the holder's
# `cmux-holder`): their command line has no bundle path, so they are found by their executable or by
# the daemon that owns them.
BARE_NAMES = ("cmux-tui", "cmux-tui-host", "cmux-holder", "cmux")
OWNER = re.compile(r"--owner \S*@(\d+)")


def exe_path(pid: int) -> str | None:
    """The process's executable (proc_pidpath), whatever its argv[0] says."""
    buf = ctypes.create_string_buffer(4096)
    try:
        size = _libproc.proc_pidpath(ctypes.c_int(pid), buf, ctypes.c_uint32(4096))
    except (AttributeError, TypeError, ctypes.ArgumentError):
        return None
    if not isinstance(size, int) or size <= 0:
        return None
    return buf.value.decode("utf-8", "replace")


def bundle_processes(table, bundle: str, exe_of=exe_path) -> dict[int, tuple[str, str]]:
    """{pid: (kind, command)} for every process of the bundle in `table` ((pid, ppid, command) rows):
    a command that starts with the bundle path; else an executable inside the bundle (a bare argv[0]),
    named by that path; else a bare-named cmux-tui or holder process whose `--owner ...@<pid>` or
    parent is one of these (repeated, so a host of the holder counts too)."""
    found: dict[int, tuple[str, str]] = {}
    bare = []
    for pid, ppid, cmd in table:
        if in_bundle(cmd, bundle) is not None:
            found[pid] = (kind_of(cmd, bundle), cmd)
            continue
        name = os.path.basename(cmd.split(None, 1)[0]) if cmd.strip() else ""
        if name not in BARE_NAMES:
            continue
        exe = exe_of(pid)
        if exe and in_bundle(exe, bundle) is not None:
            named = exe + (" " + cmd.split(None, 1)[1] if len(cmd.split(None, 1)) > 1 else "")
            found[pid] = (kind_of(named, bundle), named)
        else:
            bare.append((pid, ppid, cmd, name))
    grew = True
    while grew:
        grew = False
        for pid, ppid, cmd, name in bare:
            if pid in found:
                continue
            owner = OWNER.search(cmd)
            if ppid in found or (owner and int(owner.group(1)) in found):
                found[pid] = (kind_of("/bin/" + cmd, bundle), cmd)
                grew = True
    return found


def owned(app_pid: int, bundle: str):
    """{pid: (kind, command)} for every process of the bundle (bundle_processes), plus the WebKit
    processes the app is responsible for."""
    table = process_table()
    found = bundle_processes(table, bundle)
    _run_pids.update(found)
    if _responsible is not None:
        for pid, _ppid, cmd in table:
            if pid not in found and "com.apple.WebKit." in cmd and webkit_owned(pid, app_pid):
                found[pid] = (kind_of(cmd, bundle), cmd)
    return found


# A direct launch (CMUX_BENCH_LAUNCH=direct) makes the app a child of this script, so macOS holds the
# script's own responsible process responsible for the app and for its WebKit processes too. Those
# then count as the app's when they did not run before the launch (`launch` records the ones that did).
_direct_launch = False
_webkit_before: set[int] = set()


def webkit_owned(pid: int, app_pid: int) -> bool:
    owner = _responsible(pid)
    if owner == app_pid:
        return True
    return _direct_launch and pid not in _webkit_before and owner == _responsible(app_pid)


def sample(app_pid: int, bundle: str, label: str, workspaces: int, measure: float = 0, child_ns=None):
    """Memory per process now; with `measure` > 0 also CPU % and wakeups/s
    over that many idle seconds (proc_pid_rusage at both ends, so the bench
    adds no wakeups to the measured processes). `child_ns` (pid -> ns, --child-time)
    adds `child_cpu_pct`: the CPU of the process's children that ended in the window."""
    start = {}
    child_start = {}
    io_start = {}
    gpu = None
    if measure > 0:
        for pid in owned(app_pid, bundle):
            got = usage(pid)
            if got is not None:
                start[pid] = got
                io_start[pid] = disk_io(pid)
                if child_ns is not None:
                    child_start[pid] = child_ns(pid)
        if SAMPLE_GPU:
            gpu = GpuSampler(GPU_INTERVAL_S)
            gpu.start()
        time.sleep(measure)  # test script: the measured idle window
    rows = []
    for pid, (kind, cmd) in owned(app_pid, bundle).items():
        got = usage(pid)
        if got is None:
            continue
        row = {"pid": pid, "kind": kind, "rss_mb": round(got[0] / MB, 1),
               "footprint_mb": round(got[1] / MB, 1), "max_footprint_mb": round(got[2] / MB, 1),
               "command": (in_bundle(cmd, bundle) or cmd)[:200]}
        if pid in start:
            row["cpu_pct"] = round(100 * (got[3] - start[pid][3]) / 1e9 / measure, 3)
            row["wakeups_per_s"] = round((got[4] - start[pid][4]) / measure, 2)
            child_end = child_ns(pid) if child_ns is not None else None
            if child_end is not None and child_start.get(pid) is not None:
                row["child_cpu_pct"] = round(100 * (child_end - child_start[pid]) / 1e9 / measure, 3)
            io_end = disk_io(pid)
            if io_end is not None and io_start.get(pid) is not None:
                # MB per hour of the window: a process that writes 1 MB a minute reads 60.
                per_hour = 3600 / measure / MB
                row["disk_read_mb_per_h"] = round((io_end[0] - io_start[pid][0]) * per_hour, 2)
                row["disk_write_mb_per_h"] = round((io_end[1] - io_start[pid][1]) * per_hour, 2)
                row["logical_write_mb_per_h"] = round((io_end[2] - io_start[pid][2]) * per_hour, 2)
        if kind == "cef-renderer":
            row["priority"] = task_priority(pid)
        rows.append(row)
    rows.sort(key=lambda row: -row["footprint_mb"])
    kinds = {}
    for row in rows:
        entry = kinds.setdefault(row["kind"], {"count": 0, "rss_mb": 0.0, "footprint_mb": 0.0})
        entry["count"] += 1
        entry["rss_mb"] = round(entry["rss_mb"] + row["rss_mb"], 1)
        entry["footprint_mb"] = round(entry["footprint_mb"] + row["footprint_mb"], 1)
        if "cpu_pct" in row:
            entry["cpu_pct"] = round(entry.get("cpu_pct", 0.0) + row["cpu_pct"], 3)
            entry["wakeups_per_s"] = round(entry.get("wakeups_per_s", 0.0) + row["wakeups_per_s"], 2)
        if "child_cpu_pct" in row:
            entry["child_cpu_pct"] = round(entry.get("child_cpu_pct", 0.0) + row["child_cpu_pct"], 3)
        for key in IO_KEYS:
            if key in row:
                entry[key] = round(entry.get(key, 0.0) + row[key], 2)
        if row.get("priority") is not None:
            # Renderers per base priority, with their CPU: which band the hidden pages' renderers run in.
            band = entry.setdefault("priorities", {}).setdefault(str(row["priority"]), {"n": 0, "cpu_pct": 0.0})
            band["n"] += 1
            band["cpu_pct"] = round(band["cpu_pct"] + row.get("cpu_pct", 0.0), 3)
    result = {"measure_s": measure, "label": label, "workspaces": workspaces, "time": round(time.time()),
              "total_rss_mb": round(sum(r["rss_mb"] for r in rows), 1),
              "total_footprint_mb": round(sum(r["footprint_mb"] for r in rows), 1),
              "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["footprint_mb"])),
              "processes": rows}
    if gpu is not None:
        result["gpu"] = gpu.finish()
    return result


IO_KEYS = ("disk_read_mb_per_h", "disk_write_mb_per_h", "logical_write_mb_per_h")
# --gpu: each measured window also samples the GPU's own counters (GpuSampler).
SAMPLE_GPU = False
# ioreg's Device Utilization % is a whole number; sampled each second, a 30 s window's mean steps by 1/30 %, fine
# enough to judge goal idle-gpu-disk's 0.5 % (a 5 s interval stepped by 1/6 %).
GPU_INTERVAL_S = 1.0


class _ThreadInfo(ctypes.Structure):
    # struct proc_threadinfo (sys/proc_info.h); times in nanoseconds.
    _fields_ = [("user_ns", ctypes.c_uint64), ("system_ns", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


def thread_times(pid: int) -> dict:
    """{thread id: (name, cpu ns)} for one process (PROC_PIDLISTTHREADIDS, PROC_PIDTHREADID64INFO)."""
    ids = (ctypes.c_uint64 * 4096)()
    size = _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(28), ctypes.c_uint64(0), ids, ctypes.sizeof(ids))
    out = {}
    for tid in ids[:max(0, size) // 8]:
        info = _ThreadInfo()
        if _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(15), ctypes.c_uint64(tid), ctypes.byref(info),
                                 ctypes.sizeof(info)) == ctypes.sizeof(info):
            out[tid] = (info.name.decode(errors="replace") or "?", info.user_ns + info.system_ns)
    return out


def thread_deltas(before: dict, after: dict, seconds: float, top: int = 12) -> list:
    """The threads that ran in the window, busiest first: name and CPU ms per second."""
    rows = []
    for tid, (name, cpu) in after.items():
        spent = cpu - before.get(tid, (name, 0))[1]
        if spent > 0:
            rows.append({"thread": tid, "name": name, "cpu_ms_per_s": round(spent / 1e6 / seconds, 3),
                         "new": tid not in before})
    rows.sort(key=lambda row: -row["cpu_ms_per_s"])
    return rows[:top]


def stack_sample(pid: int, seconds: int = 3) -> dict:
    """`sample PID` for a few seconds, after the measured window (it wakes the target): each thread's
    header line and the top-of-stack frames, the frames that ran rather than waited."""
    path = tempfile.mktemp(prefix=f"bench-sample-{pid}-", suffix=".txt")
    try:
        subprocess.run(["sample", str(pid), str(seconds), "1", "-mayDie", "-file", path],
                       capture_output=True, text=True, timeout=seconds + 60)
        text = open(path, errors="replace").read()
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)[:200]}
    finally:
        if os.path.exists(path):
            os.remove(path)
    threads = [line.strip() for line in text.splitlines() if re.match(r"^\s{4}\d+ Thread_\d+", line)]
    wakes_lib = _thread_wakes()
    by_tid = wakes_lib.sample_threads(text) if wakes_lib else {}
    top, in_top = [], False
    for line in text.splitlines():
        if line.startswith("Sort by top of stack"):
            in_top = True
            continue
        if in_top:
            if not line.strip() or line.startswith("Binary Images"):
                if top:
                    break
                continue
            top.append(line.strip())
    return {"threads": threads[:60], "top_of_stack": top[:40], "by_tid": by_tid}


class Attribution:
    """--attribute: who wakes the app and the GPU process in a measured window. Around the window:
    each thread's CPU time (app and Chromium GPU), the app's wakeup ledger (`debug.wakeups`,
    reset at the start; its main run loop's timers at the end) and live pages (`debug.cef_pages`);
    after it, a short stack `sample` of both."""

    def __init__(self, app: "App", app_pid: int, bundle: str, kinds: tuple = ("app", "cef-gpu"), trace_s: int = 0):
        self.app, self.app_pid, self.bundle, self.kinds = app, app_pid, bundle, kinds
        self.trace_s = trace_s
        self.before: dict = {}
        self.started = 0.0

    def pids(self) -> dict:
        return {pid: kind for pid, (kind, _cmd) in owned(self.app_pid, self.bundle).items() if kind in self.kinds}

    def start(self):
        self.app.call("debug.wakeups", {"reset": True}, timeout=30)
        self.before = {pid: thread_times(pid) for pid in self.pids()}
        self.started = time.monotonic()

    def finish(self) -> dict:
        seconds = max(time.monotonic() - self.started, 1e-3)
        pids = self.pids()
        threads = {f"{kind}:{pid}": thread_deltas(self.before.get(pid, {}), thread_times(pid), seconds)
                   for pid, kind in pids.items()}
        wakeups = self.app.call("debug.wakeups", {"run_loop": True}, timeout=30) or {}
        ledger = sorted(wakeups.get("ledger") or [], key=lambda e: -(e.get("count") or 0))
        run_loop = wakeups.get("main_run_loop") or ""
        timers = [line.strip() for line in run_loop.splitlines() if "CFRunLoopTimer" in line]
        pages = (self.app.call("debug.cef_pages", timeout=30) or {}).get("pages") or []
        stacks = {f"{kind}:{pid}": stack_sample(pid) for pid, kind in pids.items()}
        thread_wakes = _thread_wakes()
        # Each thread named: its pthread name, else its sample header or first frames (by thread id).
        for key, rows in threads.items():
            sampled = stacks.get(key, {}).get("by_tid") or {}
            for row in rows:
                row["label"] = thread_wakes.label(row["name"], sampled.get(row["thread"])) if thread_wakes else row["name"]
        # --attribute-trace: per-thread wakeups from a System Trace after the window (so it is not in
        # the rusage window), each thread named the same way.
        wakes = {}
        for pid, kind in (pids.items() if self.trace_s > 0 else ()):
            key = f"{kind}:{pid}"
            if thread_wakes is None:
                wakes[key] = {"error": "no thread_wakes.py beside bench_memory.py"}
                continue
            got = thread_wakes.record(pid, self.trace_s)
            sampled = stacks.get(key, {}).get("by_tid") or {}
            if got.get("error"):
                wakes[key] = {"error": got["error"]}
                continue
            wakes[key] = thread_wakes.summarize(got, sampled)
        for stack in stacks.values():
            stack.pop("by_tid", None)
        return {"thread_wakes": wakes, "window_s": round(seconds, 1), "threads": threads,
                "ledger": [{k: e.get(k) for k in ("owner", "reason", "count")} for e in ledger[:25]],
                "frame_clients": wakeups.get("active_frame_clients"),
                "frame_schedulers": [s for s in wakeups.get("frame_schedulers") or [] if s.get("running") or s.get("has_link")],
                "run_loop_timers": timers[:40],
                "pages": [{k: p.get(k) for k in ("browser", "origin", "path", "hidden")} for p in pages],
                "stacks": stacks}


def print_attribution(label: str, found: dict):
    window = found["window_s"]
    print(f"PERF-ATTR {label} window_s={window}")
    for key, rows in found["threads"].items():
        for row in rows:
            print(f"PERF-ATTR {label} thread {key} tid={row['thread']} name={row.get('label', row['name'])!r} "
                  f"cpu_ms_per_s={row['cpu_ms_per_s']}"
                  f"{' new' if row['new'] else ''}")
    for key, got in (found.get("thread_wakes") or {}).items():
        if got.get("error"):
            print(f"PERF-ATTR {label} wakes {key} error={got['error']!r}")
            continue
        print(f"PERF-ATTR {label} wakes {key} window_s={got['seconds']} total_wakes_per_s={got['total_wakes_per_s']}")
        for row in got["threads"][:25]:
            print(f"PERF-ATTR {label} wakes {key} tid={row['thread']} name={row['label']!r} "
                  f"wakes_per_s={row['wakes_per_s']} runs_per_s={row['runs_per_s']} cpu_ms_per_s={row['cpu_ms_per_s']}"
                  f" frames={' > '.join(row['frames'])!r}")
    for entry in found["ledger"]:
        print(f"PERF-ATTR {label} ledger owner={entry['owner']} reason={entry['reason']!r} "
              f"per_s={round((entry['count'] or 0) / window, 2)}")
    print(f"PERF-ATTR {label} frame_clients={json.dumps(found['frame_clients'])} "
          f"schedulers={json.dumps(found['frame_schedulers'])}")
    for timer in found["run_loop_timers"]:
        print(f"PERF-ATTR {label} timer {timer[:400]}")
    hidden = sum(1 for p in found["pages"] if p.get("hidden"))
    print(f"PERF-ATTR {label} pages n={len(found['pages'])} hidden={hidden} "
          f"shown={json.dumps([(p.get('origin'), p.get('path')) for p in found['pages'] if not p.get('hidden')])}")
    for key, stack in found["stacks"].items():
        for line in stack.get("top_of_stack", [])[:25]:
            print(f"PERF-ATTR {label} top {key} {line}")
        for line in stack.get("threads", [])[:40]:
            print(f"PERF-ATTR {label} sthread {key} {line}")
        if stack.get("error"):
            print(f"PERF-ATTR {label} sample {key} error={stack['error']}")
    sys.stdout.flush()


# --vmmap-kinds tui-daemon,app: after each sample, `vmmap --summary` of every process of those kinds, as VMMAP
# lines: where a process's footprint is (MALLOC zones, a framework's __DATA, stacks...). vmmap suspends the process
# while it reads it, so it runs after the sample's window and only when asked.
def print_vmmap(result, kinds_arg: str | None) -> None:
    kinds = {k for k in (kinds_arg or "").split(",") if k}
    if not kinds or not shutil.which("vmmap"):
        return
    for row in result["processes"]:
        if row["kind"] not in kinds:
            continue
        got = subprocess.run(["vmmap", "--summary", str(row["pid"])], capture_output=True, text=True, timeout=120)
        lines = got.stdout.splitlines()
        keep = [ln for ln in lines if ln.startswith(("Physical footprint", "ReadOnly portion", "Writable regions"))]
        start = next((i for i, ln in enumerate(lines) if ln.startswith("REGION TYPE")), None)
        if start is not None:
            keep += [ln for ln in lines[start:] if ln.strip() and not ln.startswith("=")][:60]
        for ln in keep:
            print(f"VMMAP {result['label']} {row['kind']} pid {row['pid']} | {ln.rstrip()}")
    sys.stdout.flush()


def print_sample(result, top: int):
    print(f"== {result['label']}: {result['workspaces']} workspaces, {len(result['processes'])} processes, "
          f"footprint {result['total_footprint_mb']:.0f} MB, RSS {result['total_rss_mb']:.0f} MB")
    print(f"   {'kind':<22}{'n':>4}{'footprint MB':>14}{'RSS MB':>10}{'CPU %':>9}{'wakeups/s':>11}"
          f"{'disk W MB/h':>13}{'disk R MB/h':>13}")
    for kind, entry in result["kinds"].items():
        print(f"   {kind:<22}{entry['count']:>4}{entry['footprint_mb']:>14.1f}{entry['rss_mb']:>10.1f}"
              f"{entry.get('cpu_pct', float('nan')):>9.3f}{entry.get('wakeups_per_s', float('nan')):>11.2f}"
              f"{entry.get('disk_write_mb_per_h', float('nan')):>13.2f}{entry.get('disk_read_mb_per_h', float('nan')):>13.2f}")
    if result.get("gpu"):
        print(f"   GPU (whole Mac, ioreg): {json.dumps(result['gpu'])}")
    for kind, entry in result["kinds"].items():
        if "child_cpu_pct" in entry:
            print(f"   children of {kind:<22}{entry['child_cpu_pct']:>9.3f} CPU % (ended in the window)")
    print(f"   top {top} processes by footprint:")
    for row in result["processes"][:top]:
        print(f"   {row['footprint_mb']:>8.1f} MB  RSS {row['rss_mb']:>7.1f}  max {row['max_footprint_mb']:>7.1f}  "
              f"{row['kind']:<20} pid {row['pid']}  {row.get('command', '')}")
    sys.stdout.flush()


class App:
    """The app's control socket, through the app's own bundled CLI."""

    def __init__(self, bundle: str, socket_path: str):
        self.cli_path = os.path.join(bundle, "Contents/Resources/bin/cmux")
        self.socket = socket_path

    def run(self, action: str, target: str | None = None, **args):
        argv = [self.cli_path, "--app-socket", self.socket, "--json", "action", "run", action]
        if target:
            argv += ["--target", target]
        for name, value in args.items():
            argv += [f"--{name}", str(value)]
        out = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            # A refused action exits non-zero with its reason on stderr.
            return {"error": (out.stderr or out.stdout).strip()[:300] or f"exit {out.returncode}"}
        try:
            return json.loads(out.stdout or "{}")
        except ValueError:
            return {"error": (out.stdout + out.stderr).strip()[:300]}

    def action(self, action: str, *, focus: bool = False, wait: bool = True, **args) -> dict:
        """`action.run` over the socket itself: the CLI reads `--session`
        as its own option, so an action argument of that name never reaches
        the app through it. `focus` moves the app's focus to what the action
        opens or selects, as the user's shortcut would; without it a new tab
        opens in the background and does not load until it is shown. `wait`
        False answers once the handler ran, before the work it started ends."""
        params = {"action": action, "args": args, "wait": wait, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params, label=action)

    def call(self, method: str, params: dict | None = None, timeout: float = 120, label: str | None = None) -> dict:
        """One control socket method: its result, or {"error": ...}."""
        action = label or method
        reply = b""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(timeout)
                stream.connect(self.socket)
                stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                while not reply.endswith(b"\n"):
                    chunk = stream.recv(65536)
                    if not chunk:
                        break
                    reply += chunk
        except OSError as error:  # includes a timeout: this workspace is skipped, the run goes on
            return {"error": f"{action}: {error}"}
        try:
            answer = json.loads(reply or b"{}")
        except ValueError:
            return {"error": reply.decode(errors="replace")[:300]}
        return {"error": json.dumps(answer["error"])[:300]} if answer.get("error") else answer.get("result") or {}

    def identify(self) -> dict:
        try:
            out = subprocess.run([self.cli_path, "--app-socket", self.socket, "--json", "app", "identify"],
                                 capture_output=True, text=True, timeout=10)
            return json.loads(out.stdout or "{}")
        except (subprocess.TimeoutExpired, ValueError):
            return {}

    def ping(self) -> bool:
        out = subprocess.run([self.cli_path, "--app-socket", self.socket, "app", "ping"],
                             capture_output=True, text=True, timeout=30)
        return out.returncode == 0


def workspace_ids(app: App) -> set[str]:
    """The ids of the app's workspaces (`snapshot.get`)."""
    found: set[str] = set()

    def walk(node):
        if isinstance(node, dict):
            value = node.get("id")
            if isinstance(value, str) and value.startswith("ws_"):
                found.add(value)
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)
    walk(app.call("snapshot.get", timeout=30))
    return found


# --axis: one kind of item, all hidden (each in a workspace of its own, the launch workspace shown) or all
# visible (each in a pane of the launch workspace).
AXES = ("chat-hidden", "chat-visible", "terminal-hidden", "terminal-visible", "page-hidden", "page-visible")
# --axis page-*: the pages' frame reports (PageFrames), made at the launch.
PAGES: "PageFrames | None" = None


def add_axis_item(app: App, chats: "FakeChats | None", axis: str, index: int, opened: list) -> bool:
    """Adds item `index` (0-based) of `axis`; True when the app made it.

    Hidden: a workspace of its own (an answered chat, or a terminal), as open_workspace does; the caller
    shows the launch workspace again afterwards. Visible: the first item in the launch workspace's pane,
    each later one in a new pane of it (`newPaneAutoLayout`, which a script's run opens on a terminal; a
    chat then opens over it with `agent.openSessionTab`, so each visible chat's pane also holds one hidden
    terminal)."""
    if axis == "chat-hidden":
        workspace = chats.open(index)
        if workspace is not None:
            # Shown once, so its page loads, as open_workspace does; hidden again by the next item.
            app.action("goToWorkspace", workspace=workspace, focus=True)
    elif axis == "terminal-hidden":
        workspace = open_workspace(app, "terminal", "", index)
    elif axis == "page-hidden":
        # Shown once (open_workspace selects it), so the page loads and draws; hidden again by the next item.
        workspace = open_workspace(app, "browser", PAGES.url(index), index)
    else:
        workspace = None
        if index > 0:
            split = app.action("newPaneAutoLayout", focus=True)
            if split.get("error") or split.get("code"):
                print(f"   newPaneAutoLayout {index}: {split.get('message') or split.get('error')}", file=sys.stderr)
                return False
            if axis == "terminal-visible":
                return True
        if axis == "terminal-visible":
            made = app.run("newSurface")
        elif axis == "page-visible":
            made = app.run("openBrowser.chromium", url=PAGES.url(index))
            PAGES.note_open(index, made)
        else:
            session = chats.new_session(index)
            if session is None:
                return False
            made = app.action("agent.openSessionTab", session=session, focus=True)
        if made.get("error") or made.get("code"):
            print(f"   {axis} {index}: {made.get('message') or made.get('error')}", file=sys.stderr)
            PANE_FAILURES.append(f"{axis} {index}: {made.get('message') or made.get('error')}"[:200])
            return False
        return True
    if workspace is None:
        return False
    opened.append(workspace)
    return True


def run_axis(app: App, chats, axis: str, counts: list[int], launch_workspaces: list[str], opened: list,
             settle_and_sample, settled_wait: float) -> dict:
    """Samples `axis` at each item count (`items-N`), and with `settled_wait` again after that much more
    idle time (`settled-N`: the hidden chats' pages frozen and released). Returns {count: items made}."""
    made, made_at = 0, {}
    for count in counts:
        while made < count:
            if not add_axis_item(app, chats, axis, made, opened):
                break
            made += 1
        if axis.endswith("-hidden") and launch_workspaces:
            # Every item hidden: the launch workspace shown again, as a person who went back to it.
            app.action("goToWorkspace", workspace=launch_workspaces[0], focus=True)
        made_at[count] = made
        settle_and_sample(f"items-{count}")["items"] = made
        if settled_wait > 0:
            time.sleep(settled_wait)  # test script: past the hidden pages' freeze (30 s) and release (60 s) timers
            settle_and_sample(f"settled-{count}")["items"] = made
        if made < count:
            print(f"== {axis}: the app made {made} of {count} items; later counts stop here", flush=True)
            break
    return made_at


FAKE_AGENT_ID = "bench-memory-fake"
# The first prompt of each --fake-agent chat (--chat-prompt); the fake agent echoes it back, so a
# long one gives the chat a long history to hold.
CHAT_PROMPT = ""


class FakeChats:
    """Chats on an ACP test agent whose turns end (--fake-agent).

    A prompt sent through the app's CLI waits in a new chat's composer for a
    Send, so such a chat never gets a session. Each chat here is instead an
    acpmux session made on the app's own acpmux, with its first turn already
    answered, opened as a workspace (`agent.openSessionWorkspace`): an idle
    chat, as one is after its reply. Its sessions stay in that acpmux's
    store (the app's tag under ~/.acpmux)."""

    def __init__(self, app: App, bundle: str, script: str):
        self.app = app
        # The app splits `args` into words like a shell: a fleet step's checkout is under
        # "/Library/Application Support/...", so the path is quoted or the agent never starts.
        for attempt in range(5):
            added = app.run("agent.harness.add", id=FAKE_AGENT_ID, name="Memory bench", command=sys.executable,
                            args=shlex.quote(os.path.abspath(script)), protocol="acp", replace="true")
            # The action answers "timeout" after 2 s while its work goes on (the harness is still added),
            # most often just after launch: wait, then try again (it replaces the same id).
            if "timeout" not in str(added.get("code") or added.get("error") or ""):
                break
            time.sleep(5)  # test script: the app is still starting; try again (5 tries)
        else:
            added = {}  # five timeouts: the work went on in the app; a missing harness fails `acp new` below
        if added.get("error") or added.get("code"):
            raise SystemExit(f"bench-memory: agent.harness.add: {added.get('message') or added.get('error')}")
        self.env = dict(os.environ, ACPMUX_SOCKET=self.acpmux_socket(bundle))

    @staticmethod
    def acpmux_socket(bundle: str) -> str:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            for pid, _, cmd in process_table():
                if in_bundle(cmd, bundle) is not None and "/bin/acpmux daemon run" in cmd:
                    listed = subprocess.run(["lsof", "-a", "-p", str(pid), "-U", "-Fn"],
                                            capture_output=True, text=True, timeout=30).stdout
                    # `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<hash>.sock` when that path is too long.
                    paths = [line[1:] for line in listed.splitlines()
                             if line.startswith("n/") and line.endswith(".sock") and "acpmux" in line]
                    if paths:
                        return paths[0]
            time.sleep(1)  # test script: waiting for the app's acpmux to listen
        raise SystemExit("bench-memory: the app's acpmux opened no socket within 90 s")

    def workspace_ids(self) -> set[str]:
        return workspace_ids(self.app)

    def new_session(self, index: int) -> str | None:
        """A new acpmux session on the fake agent, its first turn answered; returns its id."""
        made = subprocess.run([self.app.cli_path, "acp", "new", "--json", "-d", "-m", FAKE_AGENT_ID,
                               f"memory bench chat {index}" + (f"\n\n{CHAT_PROMPT}" if CHAT_PROMPT else "")],
                              capture_output=True, text=True, timeout=120, env=self.env)
        try:
            return json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            print(f"   acp new: {(made.stdout + made.stderr).strip()[:300]}", file=sys.stderr)
            return None

    def open(self, index: int) -> str | None:
        """A new workspace on a new answered chat; returns the workspace id."""
        session = self.new_session(index)
        if session is None:
            return None
        before = self.workspace_ids()
        response = self.app.action("agent.openSessionWorkspace", session=session)
        created = [item for item in response.get("created", []) if str(item).startswith("ws_")]
        if not created and "in_progress" in json.dumps(response):
            # The action answers "timeout" at its deadline while the open goes on (its state
            # "in_progress"): the workspace it makes is the one that was not there before.
            deadline = time.monotonic() + 60
            while not created and time.monotonic() < deadline:
                time.sleep(1)  # test script: waiting for the open that went on to make its workspace
                created = sorted(self.workspace_ids() - before)
        if not created:
            print(f"   agent.openSessionWorkspace: {response.get('error') or response}", file=sys.stderr)
            return None
        remember_chat_tab(created[0], response)
        if chat_renderer_crash.enabled():
            # A pinned chat keeps its hidden page (HiddenChatPages), so the crash test finds every chat live.
            tab = CHAT_TABS.get(created[0]) or chat_tab_of(self.app, created[0])
            pinned = self.app.run("palette.toggleTabPin", target=tab) if tab else {"error": "no chat tab"}
            if pinned.get("error"):
                print(f"   pin {created[0]}: {pinned['error']}", file=sys.stderr)
        return created[0]


def purge_hidden_pages(app: App) -> dict:
    """A critical memory-pressure notice to the renderer of every hidden cmux page, nothing reloaded.

    Chromium's own response to pressure: V8 collects and shrinks its heap, Blink drops its caches
    (decoded images, fonts, resources), Skia its GPU and raster caches. The notice goes to the
    page's renderer process, so a frozen page's renderer takes it too."""
    pages = (app.call("debug.cef_pages", timeout=30) or {}).get("pages")
    if not isinstance(pages, list):
        return {"error": "no debug.cef_pages (a bench or DEV build has it)"}
    hidden = [p for p in pages if p.get("hidden") and str(p.get("origin", "")).startswith("cmux-page://")]
    params = {"method": "Memory.simulatePressureNotification", "params": {"level": "critical"}}

    def notify(page):
        reply = app.call("debug.cef_page_devtools", dict(params, browser=page["browser"]), timeout=40)
        return reply.get("error")

    with ThreadPoolExecutor(max_workers=8) as pool:
        errors = [error for error in pool.map(notify, hidden) if error]
    return {"pages": len(pages), "hidden": len(hidden), "notified": len(hidden) - len(errors),
            "errors": errors[:5]}


# Each workspace's chat tab (from the `created` ids of the action that made it): a workspace shows the
# tab it showed last, which the terminal+chat mix leaves on its terminal, so a restore shows the chat itself.
CHAT_TABS: dict[str, str] = {}


def remember_chat_tab(workspace: str, response: dict):
    tab = next((str(item) for item in response.get("created", []) if str(item).startswith("tab_")), None)
    if tab:
        CHAT_TABS[workspace] = tab


def chat_tab_of(app: App, workspace: str) -> str | None:
    """`workspace`'s agent chat tab (kind `conversation`) from `snapshot.get`, or None.

    `agent.openSessionWorkspace` answers with the workspace id only, so a --fake-agent chat has no
    recorded tab; the restore then pressed `prevSurface`, which leaves a workspace that already shows its
    chat for its terminal, and the trace bound to a chat that went off screen (first_content_ms null)."""
    snap = app.call("snapshot.get", timeout=30) or {}
    if isinstance(snap, dict) and isinstance(snap.get("result"), dict):
        snap = snap["result"]
    topology = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
    for ws in topology.get("workspaces", []) or []:
        if ws.get("id") != workspace:
            continue
        for screen in ws.get("screens", []) or []:
            for pane in screen.get("panes", []) or []:
                for tab in pane.get("tabs", []) or []:
                    ident = str(tab.get("id") or "")
                    if tab.get("kind") == "conversation" and ident and not ident.startswith("pending_"):
                        return ident
    return None


def cef_page_count(app: App) -> int | None:
    """Live Chromium pages of cmux's own (`cmux-page://`), from `debug.cef_pages`."""
    pages = (app.call("debug.cef_pages", timeout=30) or {}).get("pages")
    if not isinstance(pages, list):
        return None
    return sum(1 for p in pages if str(p.get("origin", "")).startswith("cmux-page://"))


def heap_summary(pages: list, replies: dict) -> dict:
    """--js-heap (pure): the V8 heap of the renderers that host cmux's pages, from each page's
    `Runtime.getHeapUsage` reply. `replies` maps a page's browser id to its parsed reply.

    The reply is the page's renderer's whole isolate, not the page's own share: cmux pages share a
    renderer per site (CEFSwitches `cmux-process-per-site-schemes`), so every page of one renderer
    answers the same numbers. Summing pages counted that isolate once per page (a fleet Mac run at
    10 chats read 2,562 MB of "heap" from a 632 MB renderer). The totals count each renderer once (by
    its `renderer_clients`); a page with none is its own. `by_path` counts pages only.
    A page whose read failed is counted under `errors`, never as 0 MB."""
    rows, errors = [], []
    for page in pages:
        if not isinstance(page, dict) or not str(page.get("origin", "")).startswith("cmux-page://"):
            continue
        reply = replies.get(page.get("browser")) or {}
        used, total = reply.get("usedSize"), reply.get("totalSize")
        if not isinstance(used, (int, float)) or not isinstance(total, (int, float)):
            errors.append(str(reply.get("error") or "no heap in the reply")[:120])
            continue
        clients = sorted(int(c) for c in (page.get("renderer_clients") or []) if isinstance(c, (int, float)))
        rows.append({"browser": page.get("browser"), "path": str(page.get("path") or "/"), "hidden": bool(page.get("hidden")),
                     "renderer": clients[0] if clients else None,
                     "used_mb": round(used / MB, 1), "total_mb": round(total / MB, 1)})
    renderers: dict = {}
    for row in rows:
        key = ("renderer", row["renderer"]) if row["renderer"] is not None else ("page", row["browser"])
        entry = renderers.setdefault(key, {"renderer": row["renderer"], "pages": 0, "hidden_pages": 0,
                                           "used_mb": 0.0, "total_mb": 0.0})
        entry["pages"] += 1
        entry["hidden_pages"] += int(row["hidden"])
        # One isolate: its pages read it at slightly different moments; the largest read stands.
        entry["used_mb"] = max(entry["used_mb"], row["used_mb"])
        entry["total_mb"] = max(entry["total_mb"], row["total_mb"])
    by_path: dict = {}
    for row in rows:
        entry = by_path.setdefault(row["path"], {"pages": 0, "hidden_pages": 0})
        entry["pages"] += 1
        entry["hidden_pages"] += int(row["hidden"])
    isolates = sorted(renderers.values(), key=lambda r: -r["total_mb"])
    return {"pages": len(rows), "hidden_pages": sum(int(r["hidden"]) for r in rows), "renderers": len(isolates),
            "used_mb": round(sum(r["used_mb"] for r in isolates), 1),
            "total_mb": round(sum(r["total_mb"] for r in isolates), 1),
            "by_renderer": isolates[:12],
            "by_path": dict(sorted(by_path.items(), key=lambda item: -item[1]["pages"])),
            "per_page": sorted(rows, key=lambda r: -r["total_mb"])[:40], "errors": errors[:5], "error_count": len(errors)}


def js_heaps(app: App) -> dict:
    """--js-heap: every cmux page's V8 heap (DevTools `Runtime.getHeapUsage`, which needs no domain enabled
    and runs no script), read after the sample's window so the read is not in it. A bench or DEV build has
    `debug.cef_pages`; an app without it gives {"error": ...}."""
    pages = (app.call("debug.cef_pages", timeout=30) or {}).get("pages")
    if not isinstance(pages, list):
        return {"error": "no debug.cef_pages (a bench or DEV build has it)"}

    def read(page):
        reply = app.call("debug.cef_page_devtools", {"browser": page["browser"], "method": "Runtime.getHeapUsage",
                                                     "params": {}}, timeout=20)
        if reply.get("error") or not isinstance(reply.get("result"), str):
            return page["browser"], {"error": str(reply.get("error") or "no reply")}
        try:
            return page["browser"], json.loads(reply["result"])
        except ValueError as error:
            return page["browser"], {"error": str(error)}

    own = [p for p in pages if isinstance(p, dict) and "browser" in p and str(p.get("origin", "")).startswith("cmux-page://")]
    with ThreadPoolExecutor(max_workers=8) as pool:
        replies = dict(pool.map(read, own))
    return heap_summary(own, replies)


def percentile(values: list[float], share: float) -> float | None:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))] if ordered else None


def restore_chats(app: App, workspaces: list[str], count: int) -> dict:
    """Shows each of `workspaces[:count]` (oldest first: the least recently seen, released first) and
    times its chat back on screen with the app's chat-open trace."""
    opens = []
    for workspace in workspaces[:count]:
        tab = CHAT_TABS.get(workspace)
        # The snapshot's id of the chat tab (it names tabs otherwise than an action's `created`).
        snapshot_tab = None if tab else chat_tab_of(app, workspace)
        armed = app.call("debug.chat_open_trace", {"action": "arm"}, timeout=30)
        if not isinstance(armed, dict) or armed.get("error"):
            opens.append({"workspace": workspace, "error": f"arm: {armed}"})
            continue
        shown = app.action("goToWorkspace", focus=True, workspace=workspace)
        if not shown.get("error"):
            # No recorded id: the chat is the tab before the terminal the mix added last. The trace
            # binds only when a chat loads, so a wrong guess reads as `live`, never as a restore time.
            if tab:
                shown = app.run("tab.focus", target=tab)
            elif snapshot_tab:
                shown = app.call("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": snapshot_tab},
                                                "focus": True}, timeout=30) or {}
            else:
                shown = app.action("prevSurface")
        trace = app.call("debug.chat_open_trace", {"action": "wait", "timeout_ms": 15000, "settle_ms": 300}, timeout=40) or {}
        frames = trace.get("frames") or []
        opens.append({
            "workspace": workspace, "tab": tab or (snapshot_tab and f"snapshot:{snapshot_tab}") or "prevSurface",
            "error": shown.get("error") or trace.get("error"),
            "timed_out": trace.get("timed_out"),
            "first_content_ms": trace.get("first_content_ms"),
            "first_image_ms": next((ms for ms, surface in frames if surface == "image"), None),
            "longest_empty_ms": trace.get("longest_empty_ms"),
            # Why a restore read no first content (the trace never bound, the page never reported its paint, a
            # picture stood in until the wait ended): the marks that ran, the surface changes and the trace's note.
            "engine": trace.get("engine"),
            "marks_ms": {k: v for k, v in (trace.get("marks_ms") or {}).items() if v is not None},
            "frames": frames[:12],
            "note": trace.get("note"),
        })
    content = [o["first_content_ms"] for o in opens if isinstance(o.get("first_content_ms"), (int, float))]
    empty = [o["longest_empty_ms"] for o in opens if isinstance(o.get("longest_empty_ms"), (int, float))]
    errors = sum(1 for o in opens if o.get("error"))
    live = sum(1 for o in opens if not o.get("error") and o.get("timed_out") and o.get("first_content_ms") is None)
    return {"opens": opens, "n": len(content), "errors": errors, "live": live,
            "first_content_p50_ms": percentile(content, 0.5), "first_content_p95_ms": percentile(content, 0.95),
            "longest_empty_p50_ms": percentile(empty, 0.5), "longest_empty_p95_ms": percentile(empty, 0.95),
            "with_image": sum(1 for o in opens if o.get("first_image_ms") is not None)}


# The panes a workspace's recipe asked for that the app refused (the report's `pane_failures`).
PANE_FAILURES: list[str] = []


def open_workspace(app: App, recipe: str, url: str, index: int, chats: FakeChats | None = None):
    """One workspace of `recipe` (kinds joined by +); returns its id or None."""
    kinds = recipe.split("+")
    if chats and "chat" in kinds:
        # The workspace opens on its chat (with a terminal first, as every such workspace).
        kinds.remove("chat")
        workspace = chats.open(index)
        if workspace is None:
            return None
        app.action("goToWorkspace", workspace=workspace)
    else:
        made = app.run("workspace.newAtBottom")
        created = [item for item in made.get("created", []) if str(item).startswith("ws_")]
        if not created:
            print(f"   workspace.newAtBottom: {made.get('error') or made.get('message') or made}", file=sys.stderr)
            return None
        workspace = created[0]
        # Browser and chat tabs open in the focused pane (they take a tab or pane
        # target, not a workspace), so show the new workspace first, as a user
        # who opened it would; that also loads its pages and renderers.
        app.run("workspace.selectLast")
    for kind in kinds:
        if kind == "none":
            # The workspace alone (its first page): `--mix none` churns workspaces only.
            continue
        if kind == "terminal":
            response = app.run("newSurface")
        elif kind == "browser":
            response = app.run("openBrowser.chromium", url=url)
            if PAGES:
                PAGES.note_open(index, response)
        elif kind == "chat":
            # A prompt opens an agent chat tab. It waits in the composer for a
            # Send (fleet minis carry no agent credentials either): --fake-agent
            # makes chats that answered.
            response = app.run("newTab.submit", text=f"memory bench chat {index}")
            remember_chat_tab(workspace, response)
        else:
            raise SystemExit(f"bench-memory: unknown kind {kind!r} in --mix")
        if response.get("error") or response.get("code"):
            print(f"   {kind} in {workspace}: {response.get('message') or response.get('error')}", file=sys.stderr)
            PANE_FAILURES.append(f"{kind} in {workspace}: {response.get('message') or response.get('error')}"[:200])
    return workspace


def close_workspace(app: App, workspace: str):
    response = app.run("closeWorkspace", target=workspace)
    if response.get("error") or response.get("code"):
        response = app.run("closeWorkspace", target=workspace, confirm="true")
    return response


# Every process of the bundle this run saw: the terminal hosts its daemons
# start run outside the bundle and name their daemon (`--owner ...@<pid>`).
_run_pids: set[int] = set()


def bundle_pids(bundle: str) -> set[int]:
    """The bundle's processes, with the terminal hosts this run's daemons started."""
    table = process_table()
    pids = {pid for pid, _, cmd in table if in_bundle(cmd, bundle) is not None}
    _run_pids.update(pids)
    hosts = set()
    for pid, _, cmd in table:
        owner = re.search(r"--owner \S+@(\d+)", cmd) if "__terminal-host" in cmd else None
        if owner and int(owner.group(1)) in _run_pids:
            hosts.add(pid)
    return pids | hosts


def is_binary(cmd: str, binary: str) -> bool:
    return cmd == binary or cmd.startswith(binary + " ")


def end_processes(pids: set[int], grace: float = 10.0, kill_grace: float = 5.0):
    """SIGTERM every pid, then SIGKILL what is still there once `grace` s have passed for the whole set (one
    deadline, not one per pid), waiting at most `kill_grace` s more. A child of this script that exited is
    reaped (`gone`), so an unreaped zombie never holds the teardown."""
    for sig, seconds in ((signal.SIGTERM, grace), (signal.SIGKILL, kill_grace)):
        sent = set()
        for pid in pids:
            try:
                os.kill(pid, sig)
                sent.add(pid)
            except ProcessLookupError:
                pass
        pids = still_running(sent, seconds)
        if not pids:
            return


def control_socket(bundle: str, pid: int, dirs: list[str]) -> str | None:
    """The control socket whose app answers `identify` with `pid`: another
    cmux on this Mac may bind one meanwhile. (lsof shows the app's bind
    path, not the name it is reached by.)"""
    for directory in dirs:
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            path = os.path.join(directory, name)
            if name.startswith("cmux") and name.endswith(".sock") and App(bundle, path).identify().get("pid") == pid:
                return path
    return None


# Chromium's code-sign clone cleanup helper. CEF clones the app at each launch to
# $TMPDIR/../X/<bundle id>.code_sign_clone/ (about 1 GB); after the app quits, this
# helper (`<app>/Contents/MacOS/<exe> --type=code-sign-clone-cleanup`) removes the
# clone about 1 s later. Ended with the app, it leaves the clone until reboot: 29 GB
# on cmux18 (2026-11-02). A teardown lets it finish, up to CLONE_CLEANUP_WAIT_S.
CLONE_CLEANUP = "--type=code-sign-clone-cleanup"
CLONE_CLEANUP_WAIT_S = 15


def is_clone_cleanup(cmd: str) -> bool:
    return CLONE_CLEANUP in cmd


def end_bundle(bundle: str):
    """Ends every process of the bundle, the app first: a live app (it can
    ignore SIGTERM) respawns daemons ended before it. No process of this
    bundle ran before the launch (`launch`), so every one is this run's.
    Chromium's clone cleanup helper is ended last, and only when it is still
    there after CLONE_CLEANUP_WAIT_S."""
    apps = {pid for pid, _, cmd in process_table() if is_app_process(cmd, bundle)}
    bundle_pids(bundle)  # notes the daemons before they go, for their terminal hosts
    end_processes(apps)
    cleanups = {pid for pid, _, cmd in process_table() if in_bundle(cmd, bundle) is not None and is_clone_cleanup(cmd)}
    end_processes(bundle_pids(bundle) - cleanups)
    deadline = time.monotonic() + CLONE_CLEANUP_WAIT_S
    end_processes(still_running(cleanups, max(0.0, deadline - time.monotonic())))


def gone(pid: int) -> bool:
    """Whether `pid` has exited. A child of this script is reaped (waitpid): kill(pid, 0) succeeds on an
    unreaped zombie, which would read as alive until a timeout. Any other pid is probed with kill(pid, 0)."""
    try:
        reaped, _status = os.waitpid(pid, os.WNOHANG)
        return reaped == pid
    except ChildProcessError:
        pass  # not this script's child
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def still_running(pids: set[int], seconds: float) -> set[int]:
    """The pids not gone within `seconds`, one deadline for all; each is checked at least once."""
    deadline = time.monotonic() + seconds
    while True:
        pids = {pid for pid in pids if not gone(pid)}
        if not pids or time.monotonic() >= deadline:
            return pids
        time.sleep(0.05)  # test script: waiting for processes to exit


def wait_gone(pid: int, seconds: float) -> bool:
    """True once `pid` is gone; it is checked at least once, also with no time left."""
    return not still_running({pid}, seconds)


def merged(base: dict, extra: dict) -> dict:
    out = dict(base)
    for key, value in extra.items():
        out[key] = merged(out[key], value) if isinstance(value, dict) and isinstance(out.get(key), dict) else value
    return out


def tail(path: str, lines: int = 20) -> str:
    """The last `lines` of the app's own output, for a launch that failed (empty when none)."""
    try:
        with open(path, errors="replace") as handle:
            text = handle.read().splitlines()[-lines:]
    except OSError:
        return ""
    return ("\napp output:\n" + "\n".join(text)) if text else ""


def exception_records(bundle: str, since: float) -> str:
    """The app's own record of the exception it died on (AppRunMarker's `run.exception`), written
    since `since`. The app reads the account's real home (`homeDirectoryForCurrentUser`), not the
    scratch HOME, so it is under ~/Library/Application Support/cmux-next/<bundle id>/."""
    import pwd
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
            bundle_id = plistlib.load(handle).get("CFBundleIdentifier", "")
    except OSError:
        return ""
    real_home = pwd.getpwuid(os.getuid()).pw_dir
    path = os.path.join(real_home, "Library", "Application Support", "cmux-next", bundle_id, "run.exception")
    if not bundle_id or not os.path.exists(path) or os.path.getmtime(path) < since:
        return ""
    with open(path, errors="replace") as handle:
        return f"\n--- {path}\n{handle.read()[:4000]}"


def _tag_slug(raw: str) -> str | None:
    """BuildIdentity.tagSlug: lowercase, runs outside [a-z0-9] become one `-`, no edge `-`."""
    slug = ""
    for ch in raw.lower():
        if "a" <= ch <= "z" or "0" <= ch <= "9":
            slug += ch
        elif not slug.endswith("-"):
            slug += "-"
    return slug.strip("-") or None


def _path_component(raw: str) -> str | None:
    """BuildIdentity.component: ASCII letters, digits, `.` and `_` kept, other runs one `-`."""
    out = ""
    for ch in raw:
        if ch.isascii() and (ch.isalnum() or ch in "._"):
            out += ch
        elif not out.endswith("-"):
            out += "-"
    return out.strip("-.") or None


def _fnv1a32(data: bytes) -> str:
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return f"{value:08x}"


def saved_state_dir(bundle: str) -> str | None:
    """The cmux-tui daemon state folder of a DEV (`com.cmuxterm.app.debug[.<tag>]`) bundle, which holds
    its saved workspaces: `<Application Support>/cmux-next/tags/<tag>/tui` for a kept tag, else
    `.../builds/<key>/tui` (BuildIdentity.daemonStateDirectory, BuildIdentity+AppNames.swift). It is
    under the account's real home, which the app reads (`homeDirectoryForCurrentUser`), not the scratch
    HOME. None for any other bundle (release, NIGHTLY, RC, staging): their state is a person's."""
    import pwd
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
    except OSError:
        return None
    bundle_id = (info.get("CFBundleIdentifier") or "").strip()
    dev = "com.cmuxterm.app.debug"
    if bundle_id != dev and not bundle_id.startswith(dev + "."):
        return None
    shipped = _tag_slug((info.get("LSEnvironment") or {}).get("CMUX_TAG") or "")
    if shipped is None:
        name = os.path.basename(os.path.normpath(bundle)).removesuffix(".app")
        shipped = _tag_slug(name[len("cmux DEV "):]) if name.startswith("cmux DEV ") else None
    suffix = bundle_id[len(dev) + 1:] if bundle_id != dev else None
    suffix_tag = _tag_slug(suffix) if suffix else None
    owned = {"nightly", "rc", "staging", "cmux-next"}
    kept = None
    if suffix is None:
        kept = shipped if shipped and shipped not in owned else None
    elif (not shipped or shipped == suffix_tag) and suffix_tag and suffix_tag not in owned and \
            all(seg and re.fullmatch(r"[a-z0-9]+", seg) for seg in suffix.split(".")):
        kept = suffix_tag
    support = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library", "Application Support", "cmux-next")
    if kept:
        return os.path.join(support, "tags", kept, "tui")
    component = _path_component(bundle_id)
    key = component if component == bundle_id else f"{component or 'unbundled'}--{_fnv1a32(bundle_id.encode())}"
    if shipped and shipped != suffix_tag:
        key += "--" + shipped
    return os.path.join(support, "builds", key, "tui")


def clear_saved_state(bundle: str):
    """A fresh launch starts from no saved workspaces. The daemon state of a DEV bundle outlives the
    scratch (saved_state_dir), so without this every launch of one bundle id on a host restores the
    workspaces earlier runs left: perf-idle-ab's relaunch rounds restored one more terminal workspace
    each round (terminal hosts 3, 5, 7, 9, 11 after the quit, in both arms), and an "empty" launch is
    only empty on a host's first run. Called only with none of the bundle's processes running
    (launch). CMUX_BENCH_KEEP_STATE=1 keeps it (a bench of a restored session)."""
    path = saved_state_dir(bundle)
    if not path or os.environ.get("CMUX_BENCH_KEEP_STATE") == "1" or not os.path.isdir(path):
        return
    entries = len(os.listdir(path))
    shutil.rmtree(path, ignore_errors=True)
    print(f"   bench-memory: cleared the bundle's saved daemon state {path} ({entries} entries) for a fresh launch",
          file=sys.stderr, flush=True)


def downloads_dir(scratch: str) -> str:
    """The folder `launch` gives the app for its downloads (CMUX_NEXT_DOWNLOADS_DIR), in its scratch."""
    return os.path.join(scratch, "downloads")


def launch(bundle: str, config: dict, extra_env: dict | None = None, direct: bool | None = None,
           scratch: str | None = None):
    """Starts the app with a scratch HOME, TMPDIR and config; returns (pid, socket, scratch).

    `scratch` relaunches into an earlier launch's scratch (its HOME and state), as a relaunch after
    an update does (bench_relaunch_reconnect.py): that launch's daemons may still run then.

    Through LaunchServices (`open`), as a user's launch: the app is then the
    responsible process of its WebKit processes. A child of this script
    would leave them attributed to the shell that ran it.

    `direct` (default: CMUX_BENCH_LAUNCH=direct) runs the app binary as a child instead, as
    palette-open-stages.py does: a fleet step has no LaunchServices session (`open` starts
    nothing on the minis, and the AWS workers refuse it), so a measure script must launch so."""
    if direct is None:
        direct = os.environ.get("CMUX_BENCH_LAUNCH") == "direct"
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    # The bundle's own executable (Info.plist): a DEV build also ships `__preview.dylib` there,
    # which sorts first, so the first file is not the app.
    with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
        binary = os.path.join(binary_dir, plistlib.load(handle)["CFBundleExecutable"])
    # Every process from this bundle at the end is this run's (cleanup ends
    # them all), so none may exist before: an earlier app's detached daemons
    # and terminal hosts would otherwise be ended too.
    relaunch = scratch is not None
    running = bundle_pids(bundle)
    if running and not relaunch:
        raise SystemExit(f"bench-memory: processes from {bundle} are running ({sorted(running)}); end them first")
    if not relaunch:
        clear_saved_state(bundle)
    scratch = scratch or tempfile.mkdtemp(prefix="bench-memory-")
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, "Library"), exist_ok=True)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.path.join(scratch, "tmp") + "/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
           # Downloads go to the scratch, never the account's real ~/Downloads (the app ignores HOME there, and
           # macOS asks for Downloads access in a prompt that covers a fleet Mac's screen). Debug and bench
           # builds only; a Release app ignores it (DownloadsFolder.swift).
           "CMUX_NEXT_DOWNLOADS_DIR": downloads_dir(scratch)}
    env.update(extra_env or {})
    # A None in `extra_env` drops that default (CMUX_NEXT_NO_ACTIVATE for a bench that needs the keyboard).
    env = {name: value for name, value in env.items() if value is not None}
    os.makedirs(env["TMPDIR"], exist_ok=True)
    os.makedirs(env["CMUX_NEXT_DOWNLOADS_DIR"], exist_ok=True)
    # Sparkle would otherwise download a newer nightly into the bundle under
    # test mid-run (and its installer counts as the bundle's process).
    with open(env["CMUX_NEXT_CONFIG_FILE"], "w") as handle:
        json.dump(merged({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, config), handle)
    log_path = os.path.join(scratch, "app.log")
    launched_at = time.time()
    if direct:
        global _direct_launch
        _direct_launch = True
        _webkit_before.update(p for p, _, cmd in process_table() if "com.apple.WebKit." in cmd)
        env.setdefault("CMUX_NEXT_TEST_WINDOW_FRAME", "40,40,1400,900")
        with open(log_path, "a") as log:
            child = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    else:
        child = None
        argv = ["open", "-n", "-g"] + [arg for name, value in env.items() for arg in ("--env", f"{name}={value}")]
        subprocess.run(argv + ["-a", bundle], check=True, timeout=60)
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            pid = next((p for p, _, cmd in process_table() if is_binary(cmd, binary)), None)
            # Only a socket the launched app itself holds: another cmux on
            # this Mac may bind one meanwhile.
            # A DEV build binds its socket in <HOME>/.local/state/cmux (build_names.py), linked from /tmp
            # only when that path fits; look in all three.
            path = control_socket(bundle, pid, [os.path.join(home, ".local", "state", "cmux"), "/tmp", env["TMPDIR"]]) if pid else None
            if path:
                return pid, path, scratch
            time.sleep(1)  # test script: waiting for the launched app's socket
        state = os.path.join(home, ".local", "state", "cmux")
        seen = sorted(os.listdir(state)) if os.path.isdir(state) else []
        # A direct child that ended says how (its exit status, or the signal that ended it).
        ended = ""
        if child is not None and child.poll() is not None:
            code = child.returncode
            ended = f"; the app process {child.pid} ended with {'signal ' + str(-code) if code < 0 else 'exit status ' + str(code)}"
        elif child is not None:
            ended = f"; the app process {child.pid} still runs, as {next((cmd for p, _, cmd in process_table() if p == child.pid), '?')[:200]!r}"
        raise SystemExit(f"bench-memory: the launched app opened no socket within 90 s "
                         f"(app pid {pid or 'none: it did not start'}{ended}; {state}: {seen}; "
                         f"launch {'direct' if direct else 'open'})" + tail(log_path) + exception_records(bundle, launched_at))
    except BaseException:
        end_bundle(bundle)
        if not relaunch:
            shutil.rmtree(scratch, ignore_errors=True)
        raise


REAL_SITES = [
    "https://en.wikipedia.org/wiki/Main_Page", "https://github.com/explore", "https://news.ycombinator.com",
    "https://www.apple.com", "https://developer.mozilla.org/en-US/", "https://www.reddit.com",
    "https://www.nytimes.com", "https://www.bbc.com/news", "https://stackoverflow.com/questions",
    "https://www.youtube.com", "https://www.amazon.com", "https://docs.python.org/3/",
    "https://www.figma.com", "https://www.notion.so", "https://vercel.com", "https://www.cloudflare.com",
    "https://www.theverge.com", "https://arxiv.org", "https://www.espn.com", "https://www.imdb.com",
]

_LOCAL_PAGE = """<!doctype html><html><head><meta charset=utf-8><title>bench %(n)d</title>
<style>body{font:15px -apple-system,sans-serif;max-width:760px;margin:40px auto;line-height:1.5}
.card{border:1px solid #ccc;border-radius:8px;padding:12px;margin:12px 0}</style></head><body>
<h1>Memory bench site %(n)d</h1>%(cards)s
<script>document.querySelectorAll('.card').forEach((c,i)=>c.dataset.i=i)</script></body></html>"""


def local_sites(count: int) -> list[str]:
    """`count` distinct sites (siteN.localhost, its own renderer under site isolation) served here."""
    import http.server
    import threading

    cards = "".join(f"<div class=card><h3>Card {i}</h3><p>{'lorem ipsum dolor sit amet ' * 12}</p></div>" for i in range(40))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = (self.headers.get("Host") or "site0").split(".")[0]
            number = int(re.sub(r"\D", "", host) or 0)
            body = (_LOCAL_PAGE % {"n": number, "cards": cards}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    return [f"http://site{i}.localhost:{port}/" for i in range(count)]


_FRAMES_PAGE = """<!doctype html><html><head><meta charset=utf-8><title>frames %(n)d</title>
<style>body{font:15px -apple-system,sans-serif;max-width:760px;margin:40px auto}</style></head><body>
<h1>Frames bench page %(n)d</h1><p id=c>0</p>
<script>
// Asks for every frame (a page that animates): rAF runs only on a begin-frame, so its count is the frames
// Chromium gave the page. A hidden page should get none (ARCHITECTURE 5.5: "Hidden tabs get no begin-frames").
let raf = 0, shownAt = 0, firstFrame = 0;
const c = document.getElementById('c');
function beat() {
  fetch('/beat?n=%(n)d&raf=' + raf + '&vis=' + document.visibilityState + '&shown=' + shownAt + '&frame=' + firstFrame +
        '&t=' + Date.now(), {cache: 'no-store', keepalive: true}).catch(() => {});
}
(function loop() {
  raf++;
  if (raf %% 16 === 0) c.textContent = raf;
  if (shownAt && !firstFrame) { firstFrame = Date.now(); beat(); }
  requestAnimationFrame(loop);
})();
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') { shownAt = Date.now(); firstFrame = 0; }
  beat();
});
setInterval(beat, 1000);
</script></body></html>"""


class PageFrames:
    """--axis page-*: Chromium pages (siteN.localhost, a renderer each under site isolation) that ask for every
    animation frame and report their rAF count to this script once a second. The count over a measured window is
    the frames each page got: the begin-frame rate of a visible producer, and of a hidden one (0 is the goal).
    A frozen page sends nothing; it got no frames either. Also times a hidden page's show: from the request to
    its first frame after it turned visible (`show_latency`)."""

    def __init__(self):
        import http.server
        import threading
        from urllib.parse import parse_qs, urlparse

        self.beats: dict[int, dict] = {}
        self.loads: dict[str, int] = {}
        self.opens: list = []
        self.lock = threading.Lock()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                url = urlparse(self.path)
                if url.path == "/beat":
                    q = {k: v[0] for k, v in parse_qs(url.query).items()}
                    try:
                        n = int(q.get("n", "-1"))
                        beat = {"raf": int(q.get("raf", 0)), "vis": q.get("vis", ""), "shown": int(q.get("shown", 0)),
                                "frame": int(q.get("frame", 0)), "t": int(q.get("t", 0)), "at": time.time()}
                    except ValueError:
                        beat = None
                    if beat is not None:
                        with owner.lock:
                            owner.beats[n] = beat
                    body = b""
                    self.send_response(204)
                else:
                    host = (self.headers.get("Host") or "site0").split(".")[0]
                    with owner.lock:
                        owner.loads[host] = owner.loads.get(host, 0) + 1
                    body = (_FRAMES_PAGE % {"n": int(re.sub(r"\D", "", host) or 0)}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def url(self, index: int) -> str:
        return f"http://site{index}.localhost:{self.port}/"

    def note_open(self, index: int, reply: dict) -> None:
        """The app's reply to a page open (the first few, for the report's `page_debug`)."""
        if len(self.opens) < 3:
            self.opens.append({"index": index, "reply": json.dumps(reply)[:400]})

    def debug(self) -> dict:
        with self.lock:
            return {"port": self.port, "loads": dict(self.loads), "beating": sorted(self.beats), "opens": self.opens}

    def snapshot(self) -> dict[int, dict]:
        with self.lock:
            return {n: dict(b) for n, b in self.beats.items()}

    @staticmethod
    def window(before: dict, after: dict, seconds: float) -> dict:
        """Frames per second of each page over the window, summed by its visibility at the window's end."""
        out: dict[str, dict] = {}
        for n, end in after.items():
            start = before.get(n)
            if start is None or seconds <= 0:
                continue
            fps = round((end["raf"] - start["raf"]) / seconds, 2)
            entry = out.setdefault(end["vis"] or "?", {"pages": 0, "frames_per_s": 0.0, "max_page_frames_per_s": 0.0,
                                                       "reporting": 0})
            entry["pages"] += 1
            entry["frames_per_s"] = round(entry["frames_per_s"] + fps, 2)
            entry["max_page_frames_per_s"] = max(entry["max_page_frames_per_s"], fps)
            entry["reporting"] += 1 if end["at"] > start["at"] else 0
        return out

    def time_show(self, app: "App", index: int, workspace: str, back_to: str, deadline_s: float = 10) -> dict:
        """Shows `workspace` (page `index`, hidden now) and waits for its first frame after it turned visible;
        then shows `back_to` again. Times are ms from the request (wall clocks of one Mac)."""
        asked = time.time()
        app.action("goToWorkspace", workspace=workspace, focus=True)
        got = None
        end = time.monotonic() + deadline_s
        while time.monotonic() < end:
            beat = self.snapshot().get(index)
            if beat and beat["shown"] >= asked * 1000 - 5 and beat["frame"]:
                got = beat
                break
            time.sleep(0.02)  # test script: the page's beat arrives on its own
        app.action("goToWorkspace", workspace=back_to, focus=True)
        if got is None:
            return {"page": index, "first_frame_ms": None, "timeout_s": deadline_s}
        return {"page": index, "visible_ms": round(got["shown"] - asked * 1000, 1),
                "first_frame_ms": round(got["frame"] - asked * 1000, 1)}


def tab_urls(spec: str, count: int) -> list[str]:
    if spec == "local":
        return local_sites(count)
    urls = REAL_SITES if spec == "real" else [u for u in spec.split(",") if u]
    return [urls[i % len(urls)] for i in range(count)]


def open_browser_tab(app: App, url: str) -> bool:
    response = app.run("openBrowser.chromium", url=url)
    if response.get("error") or response.get("code"):
        print(f"   browser tab {url}: {response.get('message') or response.get('error')}", file=sys.stderr)
        return False
    return True


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


APP_VM_TOOLS = (
    # (tool, its arguments, lines kept): the app process's own memory by region, by footprint category, and by malloc
    # zone and class. The goal's app process (~250 MB idle) had never been broken down (ram-baseline, CMUX-571).
    ("vmmap", ["--summary"], 400),
    ("footprint", [], 400),
    ("heap", ["--sortBySize"], 160),
)
# Kept in the report but not printed as APP-VM lines (thousands of lines): `footprint -v` lists every region with its
# tag, so the App-Specific Tag 14 (Chromium PartitionAlloc's VM tag 253) regions can be counted and sized one by one.
APP_VM_QUIET_TOOLS = (
    ("footprint -v", "footprint", ["-v"], 20000),
)


def app_vm_stacks(pid: int, pattern: str, limit: int = 40) -> dict:
    """--app-vm-stacks: the address and size of each live block of a class `heap` names (`heap -addresses PATTERN`), and
    for up to `limit` of them, largest first, the stack that allocated it (`malloc_history`; the app runs with
    MallocStackLogging=lite for this). Says which code keeps the copies a class count shows (CMUX-571: 36 copies of the
    palette's item list in the idle app)."""
    try:
        # heap matches the whole type name; a step argument carries no regex characters, so a substring is wrapped here.
        proc = subprocess.run(["heap", str(pid), "-addresses", f".*{pattern}.*"], capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"error": str(e)[:300]}
    blocks = []
    for line in proc.stdout.splitlines():
        m = re.match(r"\s*(0x[0-9a-f]+): .*?\((\d+) bytes\)", line)
        if m:
            blocks.append((int(m.group(2)), m.group(1), line.strip()[:200]))
    blocks.sort(reverse=True)
    out = {"rc": proc.returncode, "blocks": [b[2] for b in blocks], "stderr": proc.stderr[-400:], "head": proc.stdout.splitlines()[:120],
           "stacks": {}}
    for size, address, _ in blocks[:limit]:
        try:
            hist = subprocess.run(["malloc_history", str(pid), address], capture_output=True, text=True, timeout=120)
            out["stacks"][f"{address} {size}"] = hist.stdout.splitlines()[-80:] + hist.stderr.splitlines()[-5:]
        except (OSError, subprocess.TimeoutExpired) as e:
            out["stacks"][f"{address} {size}"] = [str(e)[:200]]
    return out


def app_vm(pid: int, verbose: bool = False) -> dict:
    """--app-vm: the app process's `vmmap --summary`, `footprint` and `heap --sortBySize` (each output's first lines;
    heap lists its zones, then the largest classes). A tool that fails keeps its error, so the report says why.
    verbose (--app-vm-verbose) adds APP_VM_QUIET_TOOLS, stored but not printed."""
    out = {}
    for tool, extra, keep in APP_VM_TOOLS:
        if not shutil.which(tool):
            out[tool] = {"error": "not installed"}
            continue
        try:
            proc = subprocess.run([tool, *extra, str(pid)], capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired) as e:
            out[tool] = {"error": str(e)[:300]}
            continue
        lines = proc.stdout.splitlines()
        out[tool] = {"rc": proc.returncode, "lines": lines[:keep], "total_lines": len(lines),
                     "stderr": proc.stderr[-600:]}
    if verbose:
        for key, tool, extra, keep in APP_VM_QUIET_TOOLS:
            try:
                proc = subprocess.run([tool, *extra, str(pid)], capture_output=True, text=True, timeout=300)
            except (OSError, subprocess.TimeoutExpired) as e:
                out[key] = {"error": str(e)[:300], "quiet": True}
                continue
            lines = proc.stdout.splitlines()
            out[key] = {"rc": proc.returncode, "lines": lines[:keep], "total_lines": len(lines),
                        "stderr": proc.stderr[-600:], "quiet": True}
    return out


def soak_vm(result: dict, label: str) -> dict:
    """--soak-vm: app_vm() of the app process and of the largest Chromium renderer of this sample, printed as SOAK-VM
    lines (`SOAK-VM <label> <app|cef-renderer> pid P <tool>| line`), so two samples diff region by region."""
    pick = {}
    for row in result["processes"]:  # largest footprint first
        if row["kind"] in ("app", "cef-renderer") and row["kind"] not in pick:
            pick[row["kind"]] = row["pid"]
    out = {}
    for kind, pid in pick.items():
        vm = app_vm(pid)
        out[kind] = {"pid": pid, **vm}
        for tool, entry in vm.items():
            for line in entry.get("lines") or [f"error: {entry.get('error')}"]:
                print(f"SOAK-VM {label} {kind} pid {pid} {tool}| {line}", flush=True)
    return out


def soak_growth(first: dict, last: dict) -> dict:
    """Footprint MB gained by each process kind and in total between two samples (largest growth first)."""
    growth = {"total": round(last["total_footprint_mb"] - first["total_footprint_mb"], 1)}
    for kind in set(first["kinds"]) | set(last["kinds"]):
        growth[kind] = round(last["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                             - first["kinds"].get(kind, {}).get("footprint_mb", 0.0), 1)
    return dict(sorted(growth.items(), key=lambda item: -item[1]))


def print_app_vm(label: str, vm: dict) -> None:
    for tool, entry in ((t, e) for t, e in vm.items() if t not in ("pages", "stacks")):
        if entry.get("quiet"):
            print(f"APP-VM {label} {tool} rc={entry.get('rc')} lines={entry.get('total_lines')} (in the report only)", flush=True)
            continue
        if "error" in entry:
            print(f"APP-VM {label} {tool} error: {entry['error']}", flush=True)
            continue
        print(f"APP-VM {label} {tool} rc={entry.get('rc')} lines={entry.get('total_lines')}", flush=True)
        for line in entry.get("lines") or []:
            print(f"APP-VM {label} {tool}| {line}", flush=True)
        if entry.get("stderr") and entry.get("rc"):
            print(f"APP-VM {label} {tool} stderr: {entry['stderr']}", flush=True)


def shown_workspace(app: App) -> dict:
    """What the app's first window shows: its workspace id, whether that is Home (`debug.home`'s workspace,
    or a workspace of kind `home`), and the kinds of its tabs (`snapshot.get` topology)."""
    topology = (app.call("snapshot.get", timeout=30) or {}).get("topology") or {}
    home = ((app.call("debug.home", timeout=30) or {}).get("home_workspace") or {}).get("workspace")
    shown = [w.get("workspace") for w in topology.get("windows") or [] if isinstance(w, dict) and w.get("workspace")]
    workspace = next((ws for ws in topology.get("workspaces") or [] if isinstance(ws, dict) and shown
                      and ws.get("id") == shown[0]), {})
    tabs = [tab.get("kind") for screen in workspace.get("screens") or [] for pane in screen.get("panes") or []
            for tab in pane.get("tabs") or []]
    return {"shown": shown[0] if shown else None, "windows": len(topology.get("windows") or []), "home": home,
            "kind": workspace.get("kind"), "tabs": tabs,
            "is_home": bool(shown) and (shown[0] == home or workspace.get("kind") == "home")}


def wait_terminal_shown(app: App, workspace: str | None, seconds: float) -> dict:
    """Waits until the first window shows a terminal workspace that is not Home (`workspace` when given);
    returns the last `shown_workspace`, with `ok`."""
    deadline = time.monotonic() + seconds
    while True:
        got = shown_workspace(app)
        got["ok"] = (got["shown"] is not None and not got["is_home"] and "terminal" in got["tabs"]
                     and (workspace is None or got["shown"] == workspace))
        if got["ok"] or time.monotonic() >= deadline:
            return got
        time.sleep(1)  # test script: waiting for the restore to place the workspace in the window


def relaunch_restored(bundle: str, config: dict, extra: dict, socket_path: str, scratch: str,
                      mode: str) -> tuple[int, str, dict]:
    """--relaunch-restored: a returning user's launch, which shows the user's own last workspace, not Home.

    In the first launch, one terminal workspace opened and shown (`goToWorkspace`); the app quit as a
    person's Cmd-Q does (`quitKeepSessions`, which saves the session; SIGTERM after 20 s, as
    bench_relaunch_reconnect.py); then relaunched into the same scratch. `cold` (default) also ends every
    process of the bundle that outlived the quit (its daemons), as a login after a restart: no process of
    the first launch, which showed Home, is measured in the relaunch. `warm` leaves them running.
    Refuses (SystemExit) a relaunch whose window shows Home or no terminal workspace (a restore may give
    the workspace a new id, so any terminal workspace counts; `same_workspace` says whether it kept its id)."""
    app = App(bundle, socket_path)
    info: dict = {"mode": mode, "first_launch": shown_workspace(app)}
    workspace = open_workspace(app, "terminal", "", 0)
    if workspace is None:
        raise SystemExit(f"bench-memory --relaunch-restored: no terminal workspace opened ({PANE_FAILURES[-1:]})")
    app.action("goToWorkspace", workspace=workspace, focus=True)
    before = wait_terminal_shown(app, workspace, 30)
    info["before_quit"] = before
    print(f"== relaunch: shown before the quit {json.dumps(before)}", flush=True)
    if not before["ok"]:
        raise SystemExit(f"bench-memory --relaunch-restored: the opened terminal workspace {workspace} is not shown "
                         f"before the quit: {json.dumps(before)}")
    apps = {p for p, _, cmd in process_table() if is_app_process(cmd, bundle)}
    quit_reply = app.action("quitKeepSessions", wait=False)
    left = still_running(apps, 20)
    info["quit"] = {"reply": quit_reply, "sigterm": sorted(left)}
    if left:
        print(f"   relaunch: the app was still up 20 s after quitKeepSessions; SIGTERM {sorted(left)}", file=sys.stderr)
        end_processes(left)
    # By executable path too (bundle_processes): the holder and the daemon's children start with a bare
    # argv[0], so a command-line match (bundle_pids) misses them, and the relaunch would reattach to them.
    table = process_table()
    first = bundle_processes(table, bundle)
    first_cmd = {pid: cmd for pid, _, cmd in table if pid in first}
    survivors = sorted(kind for kind, _ in first.values())
    info["after_quit"] = survivors
    print(f"== relaunch: after the quit (mode {mode}): {survivors}", flush=True)
    if mode == "cold":
        # Taken before end_bundle: once the daemon is gone the holder (a copy outside the bundle, found only
        # through its parent or owner) is launchd's child and bundle_processes no longer sees it.
        end_bundle(bundle)
        # Only a pid whose command line is unchanged: one that exited during end_bundle may be another process now.
        now_cmd = {pid: cmd for pid, _, cmd in process_table()}
        end_processes({pid for pid in first if now_cmd.get(pid) == first_cmd[pid]})
        left = still_running(set(first), 0) | set(bundle_processes(process_table(), bundle))
        if left:
            raise SystemExit(f"bench-memory --relaunch-restored cold: processes of the first launch are still up "
                             f"after the cleanup: {sorted(left)}")
    pid, socket_path, _ = launch(bundle, config, extra, scratch=scratch)
    after = wait_terminal_shown(App(bundle, socket_path), None, 60)
    after["same_workspace"] = after["shown"] == workspace
    info["restored"] = after
    print(f"== relaunch: shown after the relaunch {json.dumps(after)}", flush=True)
    if not after["ok"]:
        end_bundle(bundle)
        raise SystemExit(f"bench-memory --relaunch-restored: the relaunch does not show a terminal workspace "
                         f"(opened {workspace}): {json.dumps(after)}")
    return pid, socket_path, info


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the .app bundle")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--workspaces", default="1,10,30")
    parser.add_argument("--mix", default="terminal+chat,terminal+browser,terminal")
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--measure", type=float, default=0,
                        help="seconds of idle CPU and wakeup measurement after each settle (0: memory only)")
    parser.add_argument("--churn-minutes", type=float, default=0)
    parser.add_argument("--sample-minutes", type=float, default=5)
    parser.add_argument("--url", default="https://example.com")
    parser.add_argument("--tabs", help="browser-tab counts to sample, e.g. 1,10,20 (instead of --workspaces)")
    parser.add_argument("--urls", default="local", help="--tabs: local, real or a comma list of URLs")
    parser.add_argument("--cef-switches", default="",
                        help="launch, DEBUG builds: extra Chromium switches, colon-separated (CMUX_NEXT_CEF_EXTRA_SWITCHES)")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--vmmap-kinds", help="after each sample, vmmap --summary of every process of these kinds "
                        "(comma list, e.g. tui-daemon,app), as VMMAP lines")
    parser.add_argument("--config", default="{}",
                        help='launch: cmux.json settings as JSON, e.g. \'{"browser": {"hibernation": 1}}\'')
    parser.add_argument("--fake-agent", metavar="SCRIPT",
                        help="an ACP agent script (cmux-tui/crates/acpmux/tests/fake_agent.py) the chats use: "
                             "its turns end, as a chat's do after its reply")
    parser.add_argument("--purge-hidden", action="store_true",
                        help="after each count, purge hidden pages' renderers (no reload) and sample again")
    parser.add_argument("--release-hidden-chats", type=float, default=0, metavar="MINUTES",
                        help="run with agents.hiddenChats.discard after MINUTES; sample released chats and time their restore")
    parser.add_argument("--restore-chats", type=int, default=10,
                        help="--release-hidden-chats: how many released chats to show again and time")
    parser.add_argument("--chat-prompt", default="",
                        help="--fake-agent: text added to each chat's first prompt (echoed back: a chat with history)")
    parser.add_argument("--attribute", action="store_true",
                        help="with --measure: name what wakes the app and the GPU process in each window "
                             "(thread CPU, debug.wakeups ledger and run loop timers, live pages, a stack sample); "
                             "PERF-ATTR lines")
    parser.add_argument("--attribute-kinds", default="app,cef-gpu",
                        help="--attribute: the process kinds whose threads and stacks it reads (PERF-IDLE kind names)")
    parser.add_argument("--attribute-trace", type=int, default=0, metavar="SECONDS",
                        help="--attribute: also record SECONDS of System Trace per attributed process after each "
                             "window, and print each thread's wakeups per second with its name (thread_wakes.py)")
    parser.add_argument("--diff-tab", choices=("small", "large"),
                        help="with --measure: a visible diff tab on a repository of this size in the count's "
                             "idle window (diff_tab_cells.py); one --workspaces count")
    parser.add_argument("--diff-scroll", action="store_true",
                        help="--diff-tab: wheel events on the diff page for the whole window")
    parser.add_argument("--diff-unfocused-measure", type=float, default=300, metavar="SECONDS",
                        help="--diff-tab: the window when the diff page does not say that it has the focus "
                             "(its timer is then 30 s, not 4 s)")
    parser.add_argument("--child-time", action="store_true",
                        help="with --measure: child_cpu_pct, the whole CPU of each process's children that ended "
                             "in the window (the daemon's git runs); none when the run's own check of the read fails")
    parser.add_argument("--js-heap", action="store_true",
                        help="after each sample: every cmux page's V8 heap (Runtime.getHeapUsage), summed by page path "
                             "(`js_heap` in the sample; a bench or DEV build)")
    parser.add_argument("--app-vm", action="store_true",
                        help="after the idle-launch sample: the app process's vmmap --summary, footprint and "
                             "heap --sortBySize (`app_vm` in the sample, APP-VM lines)")
    parser.add_argument("--idle-minutes", type=float, default=0,
                        help="after the counts: leave the app alone this many minutes (a soak, no churn), sampling every "
                             "--sample-minutes as `soak-<minutes>m`; with --soak-vm each of those samples (and idle-launch) "
                             "also stores vmmap --summary, footprint and heap of the app and of the largest Chromium renderer")
    parser.add_argument("--soak-vm", action="store_true",
                        help="with --idle-minutes: the app's and the largest cef-renderer's vmmap/footprint/heap at idle-launch "
                             "and at every soak sample (SOAK-VM lines, `soak_vm` in the sample), to diff what grows")
    parser.add_argument("--app-vm-verbose", action="store_true",
                        help="with --app-vm: also `footprint -v` (every region with its tag), kept in the report, not printed")
    parser.add_argument("--app-vm-stacks", metavar="PATTERN",
                        help="with --app-vm: launch with MallocStackLogging=lite and print each live block of the classes "
                             "`heap -addresses PATTERN` names with the stack that allocated it (a diagnostic run: the "
                             "logging itself costs memory, so its footprint is not a measurement)")
    parser.add_argument("--axis", choices=AXES,
                        help="instead of --workspaces: --items counts of one kind of item, visible or hidden "
                             "(chat-hidden needs --fake-agent; see run_axis)")
    parser.add_argument("--items", default="1,10,100", help="--axis: item counts to sample (0 is idle-launch)")
    parser.add_argument("--settled-wait", type=float, default=0, metavar="SECONDS",
                        help="--axis: after each count's sample, wait this long more (past the hidden pages' freeze "
                             "and release timers, 30 s and 60 s) and sample again as settled-N")
    parser.add_argument("--show-pages", type=int, default=5,
                        help="--axis page-hidden: after the last sample, show this many hidden pages one at a time and "
                             "time each to its first frame (show_latency)")
    parser.add_argument("--gpu", action="store_true",
                        help="each measured window also samples the GPU's counters (ioreg IOAccelerator)")
    parser.add_argument("--relaunch-restored", nargs="?", const="cold", choices=("cold", "warm"),
                        help="launch: open and show one terminal workspace, quit (the session saves), relaunch into "
                             "the same scratch and check that the window shows a terminal workspace, not Home, then "
                             "sample: a returning user's launch (relaunch_restored). cold (default) ends the "
                             "processes that outlived the quit first; warm leaves them")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="launch: an environment variable for the app (repeatable), e.g. CMUX_NEXT_CHIEF_START=visible")
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.relaunch_restored and args.socket:
        parser.error("--relaunch-restored needs an app that this run launches (no --socket)")
    if any("=" not in pair or not pair.split("=", 1)[0] for pair in args.env):
        parser.error("--env takes NAME=VALUE")
    global SAMPLE_GPU
    SAMPLE_GPU = args.gpu
    if args.axis and args.axis.startswith("chat-") and not args.fake_agent:
        parser.error("--axis chat-* needs --fake-agent (chats whose first turn is answered)")
    global CHAT_PROMPT
    CHAT_PROMPT = args.chat_prompt
    if (args.purge_hidden or args.release_hidden_chats > 0) and len([n for n in args.workspaces.split(",") if n]) > 1:
        # A later count's idle sample would follow the earlier purge, not an unpurged app. Checked
        # before the launch, so a refused run leaves no app behind.
        parser.error("--purge-hidden and --release-hidden-chats take one --workspaces count; run each count on its own")
    if args.diff_tab and (len([n for n in args.workspaces.split(",") if n]) > 1 or args.tabs or args.measure <= 0):
        parser.error("--diff-tab takes one --workspaces count, --measure seconds and no --tabs")
    if args.diff_scroll and not args.diff_tab:
        parser.error("--diff-scroll needs --diff-tab")
    if args.diff_tab and args.socket:
        # An attached app would keep the tab open on a repository that this run removes.
        parser.error("--diff-tab needs an app that this run launches (no --socket)")
    # SIGTERM (a timeout, a scheduler) ends the run through its cleanup, as Ctrl-C does.
    signal.signal(signal.SIGTERM, interrupted)
    if sys.platform != "darwin":
        raise SystemExit("bench-memory: macOS only (run it on a fleet or capture mini)")

    bundle = os.path.realpath(args.app)
    # Before the launch: this part needs no app, and an error here leaves none behind.
    cells = _diff_tab_cells() if args.diff_tab or args.child_time else None
    child_ns = child_check = None
    if args.child_time:
        # Proven on this Mac first, with a child of this script. A read that does not agree gives no
        # child_cpu_pct: the report says so, and a number that is not proven is not written.
        child_check = cells.child_time_check()
        print(f"== child time check: {json.dumps(child_check)}", flush=True)
        child_ns = cells.read_child_ns if child_check.get("ok") else None
    gpu_no_app = None
    if SAMPLE_GPU and args.measure > 0 and not args.socket:
        # The Mac's GPU with no app of this run open, over one window as long as the measured ones: ioreg's counters
        # are whole-Mac, so the app's own share is a window's reading minus this one (memory-agents-cron.py).
        sampler = GpuSampler(GPU_INTERVAL_S)
        sampler.start()
        time.sleep(args.measure)  # test script: the no-app GPU window, before the launch
        gpu_no_app = sampler.finish()
        print(f"== GPU with no app (whole Mac, ioreg, {args.measure:g} s): {json.dumps(gpu_no_app)}", flush=True)
    launched = scratch = None
    if args.socket:
        if not args.app_pid:
            raise SystemExit("bench-memory: --socket needs --app-pid")
        socket_path, app_pid = args.socket, args.app_pid
    else:
        extra = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": args.cef_switches} if args.cef_switches else {}
        if args.app_vm_stacks:
            extra["MallocStackLogging"] = "lite"  # --app-vm-stacks: malloc_history needs the allocation stacks
        config = json.loads(args.config)
        if chat_renderer_crash.enabled():
            config = merged(config, chat_renderer_crash.CONFIG)
        extra.update(pair.split("=", 1) for pair in args.env)
        launched, socket_path, scratch = launch(bundle, config, extra)
        if args.relaunch_restored:
            try:
                launched, socket_path, relaunch = relaunch_restored(bundle, config, extra, socket_path, scratch,
                                                                    args.relaunch_restored)
            except BaseException:
                end_bundle(bundle)
                shutil.rmtree(scratch, ignore_errors=True)
                raise
        app_pid = launched
    app = App(bundle, socket_path)
    chats = None
    recipes = args.mix.split(",")
    counts = sorted(int(n) for n in args.workspaces.split(",") if n)
    report = {"app": bundle, "mix": recipes, "settle_s": args.settle, "samples": [], "cef_switches": args.cef_switches,
              "webkit_attributed": _responsible is not None}
    opened = []
    diff_scratch = None
    if child_check is not None:
        report["child_time_check"] = child_check
    if args.env:
        report["env"] = args.env
    if args.relaunch_restored:
        report["relaunch"] = relaunch
    if gpu_no_app is not None:
        report["gpu_no_app"] = gpu_no_app

    def settle_and_sample(label, diff_tab=None):
        time.sleep(args.settle)  # test script: let the app and its helpers go idle
        measure, scroller = args.measure, None
        if diff_tab is not None:
            # What the page says now decides the window: its timer is 4 s with the focus and 30 s without it.
            facts = cells.require_visible(cells.page_facts(app))
            measure = cells.window_seconds(facts.get("focus"), args.measure, args.diff_unfocused_measure)
            diff_tab.update(page=facts, reads_expected=cells.reads_expected(facts.get("focus"), facts.get("hidden"), measure))
            print(f"== diff tab before the window: {json.dumps(diff_tab)[:1500]}", flush=True)
            if args.diff_scroll:
                scroller = cells.Scroller(app, facts)
                scroller.start()
        kinds = tuple(kind for kind in args.attribute_kinds.split(",") if kind)
        attribution = Attribution(app, app_pid, bundle, kinds, args.attribute_trace) if args.attribute and args.measure > 0 else None
        if attribution:
            attribution.start()
        if PAGES:
            report["page_debug"] = PAGES.debug()
        frames_before = PAGES.snapshot() if PAGES else None
        try:
            result = sample(app_pid, bundle, label, len(opened) + 1, measure, child_ns)
            if frames_before is not None:
                result["page_frames"] = PageFrames.window(frames_before, PAGES.snapshot(), measure)
                print(f"   page frames: {json.dumps(result['page_frames'])}", flush=True)
        finally:
            if scroller:
                diff_tab["scroll"] = scroller.stop()
        if diff_tab is not None:
            # After the window, so the read costs it nothing: the page is still the visible one.
            diff_tab["page_after"] = cells.page_facts(app)
            result["diff_tab"] = diff_tab
            print(f"== diff tab after the window: {json.dumps({k: diff_tab[k] for k in ('scroll', 'page_after') if k in diff_tab})[:1500]}", flush=True)
        if attribution:
            result["attribution"] = attribution.finish()
            print_attribution(label, result["attribution"])
        if args.js_heap:
            result["js_heap"] = js_heaps(app)
            heap = result["js_heap"]
            print(f"   JS heap: {heap.get('pages', 0)} cmux pages ({heap.get('hidden_pages', 0)} hidden) in "
                  f"{heap.get('renderers', 0)} renderers, used {heap.get('used_mb', 0)} MB, total {heap.get('total_mb', 0)} MB "
                  f"{json.dumps(heap.get('by_renderer') or heap.get('error'))[:600]}", flush=True)
        if args.app_vm and label == "idle-launch":
            result["app_vm"] = app_vm(app_pid, verbose=args.app_vm_verbose)
            if args.app_vm_stacks:
                stacks = app_vm_stacks(app_pid, args.app_vm_stacks)
                result["app_vm"]["stacks"] = stacks
                print(f"APP-VM {label} stacks rc={stacks.get('rc')} blocks={len(stacks.get('blocks') or [])} "
                      f"error={stacks.get('error')} stderr={stacks.get('stderr')!r}", flush=True)
                for line in stacks.get("head") or []:
                    print(f"APP-VM {label} stacks-head| {line}", flush=True)
                for line in stacks.get("blocks") or []:
                    print(f"APP-VM {label} block| {line}", flush=True)
                for key, frames in (stacks.get("stacks") or {}).items():
                    for frame in frames:
                        print(f"APP-VM {label} stack {key}| {frame}", flush=True)
            try:  # which pages are live at idle (their engines own the WebContent and renderer processes)
                result["app_vm"]["pages"] = (app.call("debug.page", {"action": "list"}, timeout=30) or {}).get("pages")
            except Exception as e:  # noqa: BLE001 - a build without the debug op still gets its vmmap
                result["app_vm"]["pages"] = {"error": str(e)[:300]}
            print(f"APP-VM {label} pages: {json.dumps(result['app_vm']['pages'])[:3000]}", flush=True)
            print_app_vm(label, result["app_vm"])
        if args.soak_vm and args.idle_minutes > 0:
            result["soak_vm"] = soak_vm(result, label)
        result["pane_failures"] = len(PANE_FAILURES)
        report["samples"].append(result)
        report["pane_failures"] = PANE_FAILURES[:20]
        print_sample(result, args.top)
        print_vmmap(result, args.vmmap_kinds)
        return result

    global PAGES
    if args.axis and args.axis.startswith("page-"):
        PAGES = PageFrames()
    try:
        if args.fake_agent:
            chats = FakeChats(app, bundle, args.fake_agent)
        launch_workspaces = sorted(workspace_ids(app)) if args.axis else []
        settle_and_sample("idle-launch")["items"] = 0
        if args.axis:
            report["axis"] = args.axis
            report["axis_made"] = run_axis(app, chats, args.axis, sorted(int(n) for n in args.items.split(",") if n),
                                           launch_workspaces, opened, settle_and_sample, args.settled_wait)
            if PAGES:
                try:  # which pages the app holds, for a run whose pages never report
                    pages = (app.call("debug.page", {"action": "list"}, timeout=30) or {}).get("pages")
                except Exception as e:  # noqa: BLE001 - a build without the debug op
                    pages = {"error": str(e)[:300]}
                report["page_debug"] = {**PAGES.debug(), "app_pages": json.dumps(pages)[:1200]}
            if args.axis == "page-hidden" and launch_workspaces:
                # What the hidden tier costs on the way back: a hidden (by now frozen) page shown again, timed to
                # its first frame. A few pages, each hidden again after its show.
                report["show_latency"] = [PAGES.time_show(app, index, workspace, launch_workspaces[0])
                                          for index, workspace in enumerate(opened[:args.show_pages])]
                print(f"== show latency: {json.dumps(report['show_latency'])}", flush=True)
            counts = []
        if args.tabs:
            tab_counts = sorted(int(n) for n in args.tabs.split(",") if n)
            urls = tab_urls(args.urls, max(tab_counts))
            report["tabs"] = tab_counts
            report["urls"] = args.urls
            made = 0
            for count in tab_counts:
                while made < count and open_browser_tab(app, urls[made]):
                    made += 1
                result = settle_and_sample(f"tabs-{made}")
                result["tabs"] = made
            counts = []
        for count in counts:
            # The launch workspace counts as the first one.
            while len(opened) + 1 < count:
                workspace = open_workspace(app, recipes[len(opened) % len(recipes)], args.url, len(opened), chats)
                if workspace is None:
                    break
                opened.append(workspace)
            diff_tab = None
            if args.diff_tab:
                # In the launch's scratch; an attached app has none, so in a folder of its own. Both are removed at the end.
                diff_scratch = scratch or tempfile.mkdtemp(prefix="bench-memory-diff-")
                repository = os.path.join(os.path.realpath(diff_scratch), "diff-tab-repository")
                diff_tab = {"repository": cells.make_repository(repository, args.diff_tab)}
                diff_tab["open"] = cells.open_tab(app, repository)
            result = settle_and_sample(f"idle-{count}", diff_tab)
            if chat_renderer_crash.enabled() and chats:
                result["chat_renderers"] = chat_renderer_crash.renderers(app)
                print(f"CHAT-RENDERERS phase=open agents={count} {json.dumps(result['chat_renderers'])}", flush=True)
            if args.purge_hidden:
                purge = purge_hidden_pages(app)
                print(f"== purge at {count}: {json.dumps(purge)}", flush=True)
                settle_and_sample(f"purged-{count}")["purge"] = purge
            if args.release_hidden_chats > 0:
                before = cef_page_count(app)
                applied = {}
                for key, value in (("agents.hiddenChats.discardAfterMinutes", args.release_hidden_chats),
                                   ("agents.hiddenChats.discard", True)):
                    reply = app.call("settings.set", {"path": key, "value": value}, timeout=30) or {}
                    applied[key] = reply.get("value") if not reply.get("error") else f"error: {reply.get('error')}"
                print(f"== discard settings: {json.dumps(applied)}", flush=True)
                # test script: the hidden chats come due after the setting's minutes (plus the planner's slack)
                time.sleep(args.release_hidden_chats * 60 + 30)
                result = settle_and_sample(f"released-{count}")
                result["cef_pages"] = {"before": before, "after": cef_page_count(app)}
                result["discard_settings"] = applied
                print(f"== released at {count}: cmux pages {json.dumps(result['cef_pages'])}", flush=True)
                report["restore"] = restore_chats(app, opened, args.restore_chats)
                print(f"== restore: {json.dumps({k: v for k, v in report['restore'].items() if k != 'opens'})}", flush=True)
        if chat_renderer_crash.enabled() and chats:
            report["chat_renderer_crash"] = chat_renderer_crash.crash(app)
        if args.idle_minutes > 0:
            started = time.monotonic()
            end = started + args.idle_minutes * 60
            step = max(args.sample_minutes, 1.0) * 60
            n = 1
            while time.monotonic() < end - 1:
                time.sleep(max(0.0, min(started + n * step, end) - time.monotonic()))
                settle_and_sample(f"soak-{round((time.monotonic() - started) / 60)}m")
                n += 1
            soak = [s for s in report["samples"] if s["label"].startswith("soak-")]
            if soak:
                first = next(s for s in report["samples"] if s["label"] == "idle-launch")
                report["soak_growth_mb"] = soak_growth(first, soak[-1])
                print(f"== soak: {soak[-1]['label']} against idle-launch, footprint growth by kind and total:")
                for kind, delta in report["soak_growth_mb"].items():
                    print(f"   {kind:<22}{delta:>+10.1f} MB")
        if args.churn_minutes > 0:
            end = time.monotonic() + args.churn_minutes * 60
            next_sample = time.monotonic() + args.sample_minutes * 60
            cycles = 0
            while time.monotonic() < end:
                workspace = open_workspace(app, recipes[cycles % len(recipes)], args.url, 1000 + cycles, chats)
                time.sleep(2)  # test script: let the new tabs load before closing them
                if workspace:
                    close_workspace(app, workspace)
                cycles += 1
                if time.monotonic() >= next_sample:
                    settle_and_sample(f"churn-{cycles}")
                    next_sample = time.monotonic() + args.sample_minutes * 60
            report["churn_cycles"] = cycles
            churn = [s for s in report["samples"] if s["label"].startswith("churn-")]
            base = report["samples"][-len(churn) - 1] if churn else None
            if base and churn:
                growth = {}
                for kind in set(base["kinds"]) | set(churn[-1]["kinds"]):
                    first = base["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                    last = churn[-1]["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                    growth[kind] = round(last - first, 1)
                report["churn_growth_mb"] = dict(sorted(growth.items(), key=lambda item: -item[1]))
                print(f"== churn: {cycles} open/close cycles; footprint growth at {base['workspaces']} workspaces:")
                for kind, delta in report["churn_growth_mb"].items():
                    print(f"   {kind:<22}{delta:>+10.1f} MB")
    finally:
        for workspace in opened:
            close_workspace(app, workspace)
        if launched is not None:
            app.run("quit")
            # A quit the app holds (a confirmation) and SIGTERM can both leave
            # it running, and a live app respawns its daemons: end it first.
            wait_gone(launched, 20)
            end_bundle(bundle)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=2)
            print(f"bench-memory: wrote {args.out}")
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        if diff_scratch and diff_scratch != scratch:
            shutil.rmtree(diff_scratch, ignore_errors=True)
    crash = report.get("chat_renderer_crash")
    if crash is not None and not crash.get("pass"):
        sys.exit(2 if crash.get("setup_failed") else 1)


if __name__ == "__main__":
    main()
