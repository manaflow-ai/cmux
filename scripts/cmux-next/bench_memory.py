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

--navigate N (the navigate-N phase, p07-memory-101) follows: each local tab walks N same-site pages by itself
(/nav/N to /nav/0), so N pages wait behind Back in Chromium's back-forward cache; a terminal workspace is then
shown, so every tab is hidden, and the Chromium renderers' count and footprint are sampled hidden, after
--navigate-freeze-wait seconds (0: no freeze sample) and --navigate-window seconds after the debug pressure
override goes to warning (cleared at the end). --bfcache-flush on|off launches with feature
memoryBackForwardCacheFlush set that way (a Labs local choice); the report names the state features.list gives.
The deltas against the hidden sample, feature on against off, are what the flushes free. The flush needs a fork
with cmux_flush_back_forward_cache.

Two ways to run (macOS only, a fleet or capture mini, never a laptop):
  attach  --socket PATH --app-pid PID: an app someone else launched, for
          example by `capture-host launch` into a capture slot (capture
          leases end after 10 minutes, so churn there stays short).
  launch  no --socket: starts the tagged `cmux DEV <tag>.app` through
          bench_launch.BenchApp (the lab's bench env, a scratch config, an
          empty saved session for the tag) and ends it and every process of
          its tag at the end (BenchApp.stop, tag_teardown.py).

--out FILE is the full report (JSON). With --hidden-slope, --out DIR (a path
that does not end in .json) is the lab runner's results folder instead: the
cmux-perf-result/v1 files through BenchApp.record, and the report as
DIR/bench-memory.json.

Usage:
  bench_memory.py --app BUNDLE [--socket PATH --app-pid PID]
      [--workspaces 1,10,30] [--mix terminal+chat,terminal+browser,terminal]
      [--settle 30] [--measure 0] [--churn-minutes 0] [--sample-minutes 5]
      [--url URL] [--top 15] [--config JSON] [--fake-agent SCRIPT] [--out FILE.json]
  bench_memory.py --app BUNDLE --tabs 1,10,20 [--urls local|real|URL,URL,...] [--settle 30]
  bench_memory.py --app BUNDLE --tabs 20 --navigate 5 [--bfcache-flush on|off] [--navigate-freeze-wait 0]
      [--navigate-window 10]
  bench_memory.py --app BUNDLE --hidden-workspaces 100 [--grace 960] [--mix terminal] [--terminal-host-model hosts|holder]
      [--gpu-release off|on] [--thread-window 10]
  bench_memory.py --app BUNDLE --hidden-slope [--engine chromium|webkit] [--slope-counts 10,60] [--slope-samples 3]
      [--hibernate-after 1] [--tag TAG] [--session light] [--out DIR]
  bench_memory.py --app BUNDLE --pressure warning|critical [--pressure-window 10]
  bench_memory.py --app BUNDLE ... --kernel-pressure warn|critical [--kernel-pressure-window 5]
  bench_memory.py --app BUNDLE --cold-scrollback 100 [--cold-scrollback-mb 10] [--cold-idle 0,10,30]
      [--cold-codec-samples 5] [--cold-pressure 5] [--out FILE.json]

Phases (plans/cmux-next/chrome-parity/p07-memory.md, DC6 and DC10):
  --hidden-workspaces N [--grace S]
          opens N workspaces of --mix, shows the first workspace again so all
          N are hidden, and samples after --settle and again S seconds after
          they went hidden (960 is past the 15 min parked idle timeout). It
          prints, per process kind, the processes added and the footprint
          each hidden workspace adds at both points, and debug.memory's
          workspace states (mounted, parked, unmounted). DC6 runs with
          --terminal-host-model holder (launch only); the table names the
          model the launch gave the app, says when the daemon started
          terminal hosts all the same, and says unknown-attach for an attached app.
          It also gives the app threads per hidden terminal at both points
          and how many of the hidden terminals' renderer and IO threads
          (Ghostty names them) woke in --thread-window idle seconds after
          each: none, once their compression timers are armed (p07-memory-078).
          Run --gpu-release off, then on, for the numbers before and after the
          GPU release (debug.memory's budget says whether the release is live).
          The release is a debug tunable, so --gpu-release needs a bench build
          (reload.sh --config bench) of a .dev or .debug bundle.

Threads (p07-memory-078, DC8): every sample counts each process's threads
(proc_taskinfo), per kind and per owner of the share (THREAD_OWNERS), and each
--workspaces count gives the app threads per terminal it added.
  --pressure warning|critical [--pressure-window S]
          runs last. It sets the debug pressure override
          (debug.hibernation.pressure, DEBUG and bench-hook builds), follows
          the app's footprint for S seconds, and prints released_mb (app
          footprint before minus its lowest), release_s (time from sending
          the override to 90 % of that drop) and the footprint of the managed
          memory consumers before (stateful and supporting a limit, from
          debug.memory, summed over every consumer of a name; volatile bytes
          left out). It clears the override (`none`) at the end, also after
          a failed request.
  On a build without debug.memory both phases report process footprint only;
  a build without the override skips the pressure phase and says so; any
  other override failure is printed and recorded as the phase's error.

--hidden-slope (p12-perf-process-035, target "hidden-workspace memory slope
<= 0.5 MB per workspace"): opens terminal+<engine> workspaces (a terminal and
one page of --engine, each workspace its own local site, served here) until
the first --slope-counts count, shows the launch workspace again so all of
them are hidden, waits the hibernation grace, then sums phys_footprint (not
RSS) of the app, its daemons, terminal hosts and holders, its Chromium
helpers or its WebKit processes, --slope-samples times, --slope-interval
seconds apart; then the same at the second count. The slope is
(F_high - F_low) / (high - low) bytes per hidden workspace, one per sample
pair. result-v1: memory.hidden_slope (target row memory-slope.<engine>) and
memory.hidden_footprint.<count>, every sample stored. The grace is the page
hibernation timeout plus the planner's pace for that many pages at the
pressure debug.surfaces reports (HibernationPlanner.pace(at:)); after it the
bench reads debug.surfaces until every hidden page is hibernated or a kept
neighbor. A page that did not open, no engine process of the app for the
open pages, or pages that never hibernate is an error: nothing is recorded
and the run exits 1, as it does when a result cannot be written. A launch
shortens the timeout with the
documented setting `browser.hibernation` = --hibernate-after minutes
(BrowserHibernationSetting: a number is minutes) in its scratch config. An
attached app keeps its own setting: the bench reads it from debug.surfaces,
or takes --grace. Lab stories: scripts/perf-lab/stories.d/memory-hidden.json
(Chromium) and memory-hidden-webkit.json (WebKit).

--cold-scrollback N (p07-memory-112, the gate of tasks 040 and 041; cold_scrollback.py has the method):
N workspaces with one terminal each are opened (a control sample with empty scrollback), print
--cold-scrollback-mb MiB of log-like text (a full 10 MB scrollback each), go hidden, and are sampled with
`footprint -j` (dirty and compressed columns) and vm_stat at each --cold-idle minute and once more after
--cold-pressure (real memory pressure, memory_pressure -p); then the deflated size of --cold-codec-samples
terminals' scrollback. It prints, per terminal, the daemon's dirty and compressed growth, its scrollback share, the
kernel compressor's ratio, what the kernel keeps for that scrollback, deflate's bytes and the go/no-go (gain >= 2x),
or `not measured`, as COLD-SCROLLBACK lines and the cold-scrollback-DESIGN.md table. A launch runs the holder
terminal model (refuses --terminal-host-model hosts) and raises `terminal.scrollback.maxTotalMemoryBytes` to twice
N x 10 MB so the daemon's scrollback budget does not trim the terminals; an attached app keeps its own budget
(default 256 MiB), so the bench says it may trim, and an attached app on the hosts model decides `not measured`.

--kernel-pressure warn|critical then feeds real kernel pressure
(`/usr/bin/memory_pressure -S -l LEVEL`, root or passwordless sudo; without
either it says so and skips that step): kern.memorystatus_vm_pressure_level
changes and the app's kernel source reads it. Printed as PERF-KERNEL-PRESSURE:
when the kernel reached the level and the footprint before and after
--kernel-pressure-window seconds.

Prints a table per measurement (top processes by footprint, totals per
kind) and writes every sample to --out. It records no budgets and gates
nothing.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import PERF_LAB, BenchApp, RecordError, load_by_path, tag_of  # noqa: E402
from bench_pane_scale import thread_times  # noqa: E402
import cold_scrollback  # noqa: E402
from daemon_teardown import daemon_status, request as daemon_request  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

MB = 1048576.0


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase()
_responsible = None
# macOS only; elsewhere the module still loads, so --help works and main() refuses to run.
if sys.platform == "darwin":
    _libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    _libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    try:
        _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
        _responsible.restype = ctypes.c_int
        _responsible.argtypes = [ctypes.c_int]
    except AttributeError:  # an OS without the call: WebKit processes are not attributed
        _responsible = None
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


# PROC_PIDTASKINFO: struct proc_taskinfo (sys/proc_info.h), 6 u64 then 12 i32; pti_threadnum is the 10th i32.
PROC_PIDTASKINFO = 4
TASKINFO_SIZE = 96
TASKINFO_THREADNUM_OFFSET = 84


def thread_count(pid: int) -> int | None:
    """The process's thread count (proc_taskinfo.pti_threadnum), read from outside; None off macOS or once it is
    gone."""
    if sys.platform != "darwin":
        return None
    buf = ctypes.create_string_buffer(TASKINFO_SIZE)
    if _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTASKINFO), ctypes.c_uint64(0), buf,
                             ctypes.c_int(TASKINFO_SIZE)) != TASKINFO_SIZE:
        return None
    return int.from_bytes(buf.raw[TASKINFO_THREADNUM_OFFSET:TASKINFO_THREADNUM_OFFSET + 4], "little", signed=True)


# Who owns each process kind's thread share (p07-memory.md DC8, threads <= 300): the app's (Ghostty's two threads per
# surface included) is task 078's, the daemon's task 095's with PL-daemon.
THREAD_OWNERS = (("app", "PL-memory 078"), ("tui-daemon", "PL-daemon 095"), ("terminal-", "PL-daemon 095"),
                 ("cef-", "PL-cefhost"), ("acpmux-", "PL-acpmux"), ("webkit-", "PL-webui"))


def thread_owner(kind: str) -> str:
    """The owner of a process kind's threads (``THREAD_OWNERS``, the first prefix that matches); PL-memory for the
    other bundled helpers."""
    return next((owner for prefix, owner in THREAD_OWNERS if kind.startswith(prefix)), "PL-memory")


def threads_by_owner(kinds: dict) -> dict[str, int]:
    """{owner: threads} over a sample's kinds (``thread_owner``), most first."""
    owners: dict[str, int] = {}
    for kind, entry in kinds.items():
        owner = thread_owner(kind)
        owners[owner] = owners.get(owner, 0) + (entry.get("threads") or 0)
    return dict(sorted(owners.items(), key=lambda item: -item[1]))


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
    (/tmp/...), so both spellings count."""
    for root in (bundle, bundle.removeprefix("/private")):
        if cmd.startswith(root + "/"):
            return cmd[len(root):]
    return None


def kind_of(cmd: str, bundle: str) -> str:
    rel = in_bundle(cmd, bundle) or cmd
    if " Helper" in rel:
        for flag, name in (("--type=renderer", "cef-renderer"), ("--type=gpu-process", "cef-gpu"),
                           ("--type=utility", "cef-utility"), ("--type=plugin", "cef-plugin")):
            if flag in rel:
                return name
        return "cef-helper"
    # The Chromium Host is a second executable of the app (embed-cef.sh), not the app.
    if re.match(r"/Contents/MacOS/[^/]* Chromium Host( |$)", rel):
        return "cef-host"
    if rel.startswith("/Contents/MacOS/"):
        return "app"
    terminal = terminal_kind(rel)
    if terminal:
        return terminal
    if "/bin/cmux-tui" in rel or "/bin/cmux " in rel or rel.endswith("/bin/cmux"):
        if "--session cmux-chief" in rel:
            return "tui-daemon-chief"
        return "tui-daemon"
    if "/bin/acpmux" in rel:
        return "acpmux-" + (rel.split("/bin/acpmux", 1)[1].split() or ["agent"])[0]
    if "/bin/" in rel:
        return rel.split("/bin/", 1)[1].split()[0]
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    return os.path.basename(cmd.split()[0])


def terminal_kind(cmd: str) -> str | None:
    """`terminal-host` (`__terminal-host`) or `terminal-holder` (the standalone `cmux-holder`, or the host binary's
    built-in `__holder`; holder_runtime/service.rs launch), else None."""
    if "__terminal-host" in cmd:
        return "terminal-host"
    words = cmd.split()
    if words and (os.path.basename(words[0]) == "cmux-holder" or "__holder" in words[1:]):
        return "terminal-holder"
    return None


# A terminal host's or holder's `--owner <bundle>:<tag>@<daemon pid>` (host_session.rs host_owner_args): both run
# from a content-addressed copy outside the bundle (host_exe.rs), so only the daemon pid ties them to this app.
OWNER_ARG = re.compile(r"--owner \S+@(\d+)")

# WebKit processes that ran before this run launched the app as its child (a BenchApp launch: this bench's,
# bench_hibernation's and bench_renderer_sharing's, through ``note_child_launch``); None for an attached app, whose
# WebKit processes name the app as their responsible process, and for bench_power, which starts the app through
# ``launch``.
_foreign_webkit: set[int] | None = None


def webkit_pids() -> set[int]:
    return {pid for pid, _, cmd in process_table() if "com.apple.WebKit." in cmd}


def note_child_launch() -> None:
    """Call right before a bench launches the app as its own child (BenchApp.launch): the WebKit processes that run
    now are another app's, and those that start later and share the app's responsible process are its own
    (``webkit_is_apps``)."""
    global _foreign_webkit
    _foreign_webkit = webkit_pids()


def webkit_is_apps(pid: int, app_pid: int, app_responsible: int | None) -> bool:
    """WebKit's processes are launchd's children. macOS holds the app responsible for them (an attached app, or one
    `open` started), or, for an app this run started as its child (BenchApp, ``launch`` with `direct`), the process
    responsible for the app. Such a WebKit process counts only when ``_foreign_webkit`` is set and it did not run
    before the launch."""
    if _responsible is None:
        return False
    owner = _responsible(pid)
    if owner == app_pid:
        return True
    return (_foreign_webkit is not None and pid not in _foreign_webkit and app_responsible not in (None, app_pid)
            and owner == app_responsible)


def owned(app_pid: int, bundle: str):
    """{pid: (kind, command)} for every process from the bundle, the terminal hosts and holders its running daemons
    started, and the WebKit processes that are the app's (``webkit_is_apps``)."""
    table = process_table()
    found = {}
    for pid, _ppid, cmd in table:
        if in_bundle(cmd, bundle) is not None:
            _run_pids.add(pid)
            found[pid] = (kind_of(cmd, bundle), cmd)
    app_responsible = _responsible(app_pid) if _responsible is not None else None
    for pid, _ppid, cmd in table:
        if pid in found:
            continue
        owner = OWNER_ARG.search(cmd)
        if owner and int(owner.group(1)) in found and terminal_kind(cmd):
            found[pid] = (terminal_kind(cmd), cmd)
        elif "com.apple.WebKit." in cmd and webkit_is_apps(pid, app_pid, app_responsible):
            found[pid] = (kind_of(cmd, bundle), cmd)
    return found


def sample(app_pid: int, bundle: str, label: str, workspaces: int, measure: float = 0):
    """Memory per process now; with `measure` > 0 also CPU % and wakeups/s
    over that many idle seconds (proc_pid_rusage at both ends, so the bench
    adds no wakeups to the measured processes)."""
    start = {}
    if measure > 0:
        for pid in owned(app_pid, bundle):
            got = usage(pid)
            if got is not None:
                start[pid] = got
        time.sleep(measure)  # test script: the measured idle window
    rows = []
    for pid, (kind, cmd) in owned(app_pid, bundle).items():
        got = usage(pid)
        if got is None:
            continue
        row = {"pid": pid, "kind": kind, "rss_mb": round(got[0] / MB, 1),
               "footprint_mb": round(got[1] / MB, 1), "footprint_bytes": got[1],
               "max_footprint_mb": round(got[2] / MB, 1), "threads": thread_count(pid), "command": cmd[:160]}
        if pid in start:
            row["cpu_pct"] = round(100 * (got[3] - start[pid][3]) / 1e9 / measure, 3)
            row["wakeups_per_s"] = round((got[4] - start[pid][4]) / measure, 2)
        rows.append(row)
    rows.sort(key=lambda row: -row["footprint_mb"])
    kinds = {}
    for row in rows:
        entry = kinds.setdefault(row["kind"], {"count": 0, "rss_mb": 0.0, "footprint_mb": 0.0, "footprint_bytes": 0,
                                               "threads": 0})
        entry["count"] += 1
        entry["threads"] += row["threads"] or 0
        entry["footprint_bytes"] += row["footprint_bytes"]
        entry["rss_mb"] = round(entry["rss_mb"] + row["rss_mb"], 1)
        entry["footprint_mb"] = round(entry["footprint_mb"] + row["footprint_mb"], 1)
        if "cpu_pct" in row:
            entry["cpu_pct"] = round(entry.get("cpu_pct", 0.0) + row["cpu_pct"], 3)
            entry["wakeups_per_s"] = round(entry.get("wakeups_per_s", 0.0) + row["wakeups_per_s"], 2)
    return {"measure_s": measure, "label": label, "workspaces": workspaces, "time": round(time.time()),
            "total_rss_mb": round(sum(r["rss_mb"] for r in rows), 1),
            "total_footprint_mb": round(sum(r["footprint_mb"] for r in rows), 1),
            "total_footprint_bytes": sum(r["footprint_bytes"] for r in rows),
            "total_threads": sum(r["threads"] or 0 for r in rows),
            "threads_by_owner": threads_by_owner(kinds),
            "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["footprint_mb"])),
            "processes": rows}


def print_sample(result, top: int):
    print(f"== {result['label']}: {result['workspaces']} workspaces, {len(result['processes'])} processes, "
          f"footprint {result['total_footprint_mb']:.0f} MB, RSS {result['total_rss_mb']:.0f} MB, "
          f"{result.get('total_threads', 0)} threads")
    print(f"   {'kind':<22}{'n':>4}{'footprint MB':>14}{'RSS MB':>10}{'threads':>9}{'CPU %':>9}{'wakeups/s':>11}")
    for kind, entry in result["kinds"].items():
        print(f"   {kind:<22}{entry['count']:>4}{entry['footprint_mb']:>14.1f}{entry['rss_mb']:>10.1f}"
              f"{entry.get('threads', 0):>9}"
              f"{entry.get('cpu_pct', float('nan')):>9.3f}{entry.get('wakeups_per_s', float('nan')):>11.2f}")
    owners = result.get("threads_by_owner") or {}
    if any(owners.values()):
        print("   threads by owner (DC8): " + ", ".join(f"{owner} {count}" for owner, count in owners.items()))
    print(f"   top {top} processes by footprint:")
    for row in result["processes"][:top]:
        print(f"   {row['footprint_mb']:>8.1f} MB  RSS {row['rss_mb']:>7.1f}  max {row['max_footprint_mb']:>7.1f}  "
              f"{row['kind']:<20} pid {row['pid']}")
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

    def action(self, action: str, *, focus: bool = False, **args) -> dict:
        """`action.run` over the socket itself: the CLI reads `--session`
        as its own option, so an action argument of that name never reaches
        the app through it. `focus` moves the app's focus to what the action
        opens or selects, as the user's shortcut would; without it a new tab
        opens in the background and does not load until it is shown."""
        params = {"action": action, "args": args, "wait": True, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params, label=action)

    def call(self, method: str, params: dict | None = None, label: str | None = None, timeout: float = 120) -> dict:
        """One control-socket request; its result, or {"error": ...} (an unknown method, a refusal, a timeout)."""
        reply = b""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(timeout)
                stream.connect(self.socket)
                stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                while not reply.endswith(b"\n"):
                    chunk = stream.recv(1 << 20)
                    if not chunk:
                        break
                    reply += chunk
        except OSError as error:  # includes a timeout: this step is skipped, the run goes on
            return {"error": f"{label or method}: {error}"}
        try:
            answer = json.loads(reply or b"{}")
        except ValueError:
            return {"error": reply.decode(errors="replace")[:300]}
        if answer.get("error"):
            return {"error": json.dumps(answer["error"])[:300]}
        result = answer.get("result")
        return result if isinstance(result, dict) else {"value": result}

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


FAKE_AGENT_ID = "bench-memory-fake"


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
        added = app.run("agent.harness.add", id=FAKE_AGENT_ID, name="Memory bench", command=sys.executable,
                        args=os.path.abspath(script), protocol="acp", replace="true")
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

    def open(self, index: int) -> str | None:
        """A new workspace on a new answered chat; returns the workspace id."""
        made = subprocess.run([self.app.cli_path, "acp", "new", "--json", "-d", "-m", FAKE_AGENT_ID,
                               f"memory bench chat {index}"],
                              capture_output=True, text=True, timeout=120, env=self.env)
        try:
            session = json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            print(f"   acp new: {(made.stdout + made.stderr).strip()[:300]}", file=sys.stderr)
            return None
        response = self.app.action("agent.openSessionWorkspace", session=session)
        created = [item for item in response.get("created", []) if str(item).startswith("ws_")]
        if not created:
            print(f"   agent.openSessionWorkspace: {response.get('error') or response}", file=sys.stderr)
            return None
        return created[0]


def open_workspace(app: App, recipe: str, url: str, index: int, chats: FakeChats | None = None):
    """One workspace of `recipe` (kinds joined by +); returns its id or None. A kind that fails in it is printed and
    the workspace still counts (``open_workspace_parts`` tells)."""
    return open_workspace_parts(app, recipe, url, index, chats)[0]


def open_workspace_parts(app: App, recipe: str, url: str, index: int,
                         chats: FakeChats | None = None) -> tuple[str | None, list[str]]:
    """(the workspace id or None, the kinds of `recipe` that failed to open in it)."""
    kinds = recipe.split("+")
    if chats and "chat" in kinds:
        # The workspace opens on its chat (with a terminal first, as every such workspace).
        kinds.remove("chat")
        workspace = chats.open(index)
        if workspace is None:
            return None, []
        app.action("goToWorkspace", workspace=workspace)
    else:
        made = app.run("workspace.newAtBottom")
        created = [item for item in made.get("created", []) if str(item).startswith("ws_")]
        if not created:
            print(f"   workspace.newAtBottom: {made.get('error') or made.get('message') or made}", file=sys.stderr)
            return None, []
        workspace = created[0]
        # Browser and chat tabs open in the focused pane (they take a tab or pane
        # target, not a workspace), so show the new workspace first, as a user
        # who opened it would; that also loads its pages and renderers.
        app.run("workspace.selectLast")
    failed = []
    for kind in kinds:
        if kind == "none":
            # The workspace alone (its first page): `--mix none` churns workspaces only.
            continue
        if kind == "terminal":
            response = app.run("newSurface")
        elif kind in ("browser", "chromium"):
            response = app.run("openBrowser.chromium", url=url)
        elif kind == "webkit":
            response = app.run("openBrowser.webkit", url=url)
        elif kind == "chat":
            # A prompt opens an agent chat tab. It waits in the composer for a
            # Send (fleet minis carry no agent credentials either): --fake-agent
            # makes chats that answered.
            response = app.run("newTab.submit", text=f"memory bench chat {index}")
        else:
            raise SystemExit(f"bench-memory: unknown kind {kind!r} in --mix")
        if response.get("error") or response.get("code"):
            print(f"   {kind} in {workspace}: {response.get('message') or response.get('error')}", file=sys.stderr)
            failed.append(kind)
    return workspace, failed


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


def end_processes(pids: set[int]):
    """SIGTERM, then SIGKILL what is still there after a grace period."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        alive = set()
        for pid in pids:
            try:
                os.kill(pid, sig)
                alive.add(pid)
            except ProcessLookupError:
                pass
        pids = {pid for pid in alive if not wait_gone(pid, 10)}
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


def end_bundle(bundle: str):
    """Ends every process of the bundle, the app first: a live app (it can
    ignore SIGTERM) respawns daemons ended before it. No process of this
    bundle ran before the launch (`launch`), so every one is this run's."""
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    apps = {pid for pid, _, cmd in process_table() if cmd.startswith(binary_dir + "/")}
    bundle_pids(bundle)  # notes the daemons before they go, for their terminal hosts
    end_processes(apps)
    end_processes(bundle_pids(bundle))


def wait_gone(pid: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.5)  # test script: waiting for the app to quit
    return False


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


def launch(bundle: str, config: dict, extra_env: dict | None = None, direct: bool | None = None):
    """Starts the app with a scratch HOME, TMPDIR and config; returns (pid, socket, scratch). The launcher of
    bench_power; this bench, bench_hibernation and bench_renderer_sharing launch through BenchApp.

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
    running = bundle_pids(bundle)
    if running:
        raise SystemExit(f"bench-memory: processes from {bundle} are running ({sorted(running)}); end them first")
    scratch = tempfile.mkdtemp(prefix="bench-memory-")
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, "Library"), exist_ok=True)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.path.join(scratch, "tmp") + "/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json")}
    env.update(extra_env or {})
    os.makedirs(env["TMPDIR"], exist_ok=True)
    # Sparkle would otherwise download a newer nightly into the bundle under
    # test mid-run (and its installer counts as the bundle's process).
    with open(env["CMUX_NEXT_CONFIG_FILE"], "w") as handle:
        json.dump(merged({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, config), handle)
    log_path = os.path.join(scratch, "app.log")
    if direct:
        env.setdefault("CMUX_NEXT_TEST_WINDOW_FRAME", "40,40,1400,900")
        with open(log_path, "a") as log:
            subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    else:
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
        raise SystemExit(f"bench-memory: the launched app opened no socket within 90 s "
                         f"(app pid {pid or 'none: it did not start'}; {state}: {seen}; "
                         f"launch {'direct' if direct else 'open'})" + tail(log_path))
    except BaseException:
        end_bundle(bundle)
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


# A navigate-N page goes on to the next one this long after its load event: a navigation after the load adds a history
# entry (one before it replaces the current one), so the page it leaves can enter the back-forward cache.
NAVIGATE_STEP_DELAY_MS = 300
_NAVIGATE_SCRIPT = ("<script>addEventListener('load',()=>setTimeout(()=>{location.href='/nav/%(next)d'},"
                    f"{NAVIGATE_STEP_DELAY_MS}))</script>")
NAVIGATE_PATH = re.compile(r"^/nav/(\d+)$")


def local_sites(count: int, navigate: int = 0, visits: set | None = None) -> list[str]:
    """`count` distinct sites (siteN.localhost, its own renderer under site isolation) served here. With `navigate`
    N > 0 each URL is `/nav/N`, whose page goes on by itself to `/nav/N-1` and so on to `/nav/0`: N same-site
    navigations, and N pages behind Back. `visits` gets (site number, step) for each `/nav/` page served."""
    import http.server
    import threading

    cards = "".join(f"<div class=card><h3>Card {i}</h3><p>{'lorem ipsum dolor sit amet ' * 12}</p></div>" for i in range(40))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = (self.headers.get("Host") or "site0").split(".")[0]
            number = int(re.sub(r"\D", "", host) or 0)
            body = (_LOCAL_PAGE % {"n": number, "cards": cards}).encode()
            step = NAVIGATE_PATH.match(self.path)
            if step:
                left = int(step.group(1))
                if visits is not None:
                    visits.add((number, left))
                if left > 0:
                    body = body.replace(b"</body>", (_NAVIGATE_SCRIPT % {"next": left - 1}).encode() + b"</body>")
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
    path = f"nav/{navigate}" if navigate > 0 else ""
    return [f"http://site{i}.localhost:{port}/{path}" for i in range(count)]


def tab_urls(spec: str, count: int, navigate: int = 0, visits: set | None = None) -> list[str]:
    if spec == "local":
        return local_sites(count, navigate, visits)
    urls = REAL_SITES if spec == "real" else [u for u in spec.split(",") if u]
    return [urls[i % len(urls)] for i in range(count)]


def open_browser_tab(app: App, url: str) -> bool:
    response = app.run("openBrowser.chromium", url=url)
    if response.get("error") or response.get("code"):
        print(f"   browser tab {url}: {response.get('message') or response.get('error')}", file=sys.stderr)
        return False
    return True


def known_int(value) -> int | None:
    """A count or byte count of the debug.memory JSON: an integer, or None for null (unknown, never 0)."""
    return value if isinstance(value, int) and not isinstance(value, bool) else None


class MemoryReport:
    """The app's own memory accounting through `debug.memory`, read as MemoryDiagnosticsReport (p07-memory-010)
    writes it: snake_case keys, integer byte counts, null for unknown. `read` gives None on a build without it,
    and every phase then reports process footprint only."""

    def __init__(self, raw: dict):
        self.raw = raw

    @staticmethod
    def read(app: App) -> MemoryReport | None:
        answer = app.call("debug.memory", timeout=30)
        return None if "error" in answer or "consumers" not in answer else MemoryReport(answer)

    def consumers(self) -> list[dict]:
        return [consumer for consumer in self.raw.get("consumers") or [] if isinstance(consumer, dict)]

    def managed_consumers(self) -> list[dict]:
        """The consumers the report marks `managed`: Chrome's ShouldManageConsumer
        (memory_saver_memory_coordinator_policy.h), stateful and supporting a limit."""
        return [consumer for consumer in self.consumers() if consumer.get("managed") is True]

    def managed(self) -> dict[str, dict]:
        """{name: {"instances", "footprint_bytes", "unknown"}} over the managed consumers. A name is not unique
        (one `tab-hover-cards` per tab strip; every name that is not a plain token is `redacted`), so a row adds
        up every consumer of that name; `unknown` counts the ones with null bytes, which add nothing."""
        rows: dict[str, dict] = {}
        for consumer in self.managed_consumers():
            row = rows.setdefault(str(consumer.get("name")), {"instances": 0, "footprint_bytes": 0, "unknown": 0})
            row["instances"] += 1
            footprint = known_int(consumer.get("footprint_bytes"))
            if footprint is None:
                row["unknown"] += 1
            else:
                row["footprint_bytes"] += footprint
        return rows

    def managed_bytes(self) -> tuple[int, int]:
        """(known footprint bytes of every managed consumer, how many have unknown bytes). Volatile bytes are
        left out: the kernel takes them without the app (DC10)."""
        footprints = [known_int(consumer.get("footprint_bytes")) for consumer in self.managed_consumers()]
        return sum(b for b in footprints if b is not None), sum(1 for b in footprints if b is None)

    def level(self) -> str | None:
        pressure = self.raw.get("pressure")
        return pressure.get("level") if isinstance(pressure, dict) else None

    @staticmethod
    def workspace_state(row: dict) -> str:
        """parked (hidden, kept mounted until the parked idle timeout), mounted or unmounted, from the row's
        `parked` and `mounted` flags (memory-DESIGN.md section 7)."""
        if row.get("parked") is True:
            return "parked"
        return "mounted" if row.get("mounted") is True else "unmounted"

    def workspaces(self) -> dict:
        """{state: {"count", "attributed_mb", "terminal_surfaces", "gpu_resident_surfaces"}} over the workspace
        rows; attributed is the app bytes debug.memory gives each workspace."""
        states: dict = {}
        for row in self.raw.get("workspaces") or []:
            if not isinstance(row, dict):
                continue
            entry = states.setdefault(self.workspace_state(row), {"count": 0, "attributed_mb": 0.0,
                                                                  "terminal_surfaces": 0, "gpu_resident_surfaces": 0})
            entry["count"] += 1
            attributed = known_int(row.get("app_bytes"))
            if attributed is not None:
                entry["attributed_mb"] = round(entry["attributed_mb"] + attributed / MB, 2)
            for name in ("terminal_surfaces", "gpu_resident_surfaces"):
                value = known_int(row.get(name))
                if value is not None:
                    entry[name] += value
        return states

    def hidden_iosurface_mb(self) -> float | None:
        """terminal.hidden_nonvolatile_iosurface_bytes: what hidden terminals keep in GPU memory."""
        terminal = self.raw.get("terminal")
        value = known_int(terminal.get("hidden_nonvolatile_iosurface_bytes")) if isinstance(terminal, dict) else None
        return None if value is None else round(value / MB, 2)

    def terminal_surfaces(self) -> int | None:
        """terminal.surfaces: the live terminal surfaces, shown or not (each has its own Ghostty threads)."""
        terminal = self.raw.get("terminal")
        return known_int(terminal.get("surfaces")) if isinstance(terminal, dict) else None

    def gpu_release(self) -> bool | None:
        """budget.gpu_resident_available: hidden terminals let their GPU memory go (feature terminalGPURelease on a
        GhosttyNextKit pin with ghostty_surface_set_gpu_resident); None when the report does not say."""
        budget = self.raw.get("budget")
        value = budget.get("gpu_resident_available") if isinstance(budget, dict) else None
        return value if isinstance(value, bool) else None


# The threads Ghostty starts for each surface, by the name it gives them (ghostty-next src/renderer/Thread.zig and
# src/termio/Thread.zig, pthread_setname_np): what one terminal adds to the app besides shared threads.
SURFACE_THREADS = ("renderer", "io")


def same_thread(read: dict, handle: int, name: str) -> bool:
    """Whether `read` (a ``thread_times`` read) has the thread `handle` named `name`: the handle of a thread that
    exited can come back on a thread of another name."""
    return read.get(handle, (None,))[0] == name


def terminal_threads(base: dict, end: dict, terminals: int | None, start: dict | None = None,
                     window_s: float = 0) -> dict:
    """App threads per added terminal, and with an idle window (`start`, `window_s`) which of their threads woke.

    `base`, `start` and `end` are ``thread_times`` reads of the app: before the terminals opened, and at both ends of
    the window. A surface thread (``SURFACE_THREADS``) not in `base` is an added terminal's. One whose CPU time grew
    in the window woke: proc_threadinfo counts CPU time to the microsecond, and a wakeup of the renderer's event loop
    runs longer than that. `terminals` is how many terminal surfaces were added (debug.memory), else one per added
    renderer thread. A read's handle is the thread's pthread address, which a later thread can get once its thread
    exits, so a thread is the one in an earlier read only when the name there is the same (``same_thread``)."""
    added = {name: [handle for handle, (thread, _) in end.items()
                    if thread == name and not same_thread(base, handle, name)]
             for name in SURFACE_THREADS}
    if not terminals or terminals < 0:
        terminals = len(added["renderer"])
    out = {"app_threads_base": len(base), "app_threads": len(end), "terminals": terminals,
           "threads_per_terminal": round((len(end) - len(base)) / terminals, 2) if terminals else None}
    if start is not None:
        out["window_s"] = window_s
    for name, handles in added.items():
        row = {"threads": len(handles), "per_terminal": round(len(handles) / terminals, 2) if terminals else None}
        if start is not None:
            # A thread started inside the window counts from zero.
            grew = [end[handle][1] - (start[handle][1] if same_thread(start, handle, name) else 0)
                    for handle in handles]
            row["woke"] = sum(1 for delta in grew if delta > 0)
            row["cpu_us"] = round(sum(delta for delta in grew if delta > 0) / 1000, 1)
        out[name] = row
    return out


def print_terminal_threads(label: str, threads: dict, gpu_release: bool | None):
    """One line per `terminal_threads` result: threads per terminal and, with a window, the surface threads that
    woke (0 for hidden terminals once their compression timers are armed)."""
    gpu = {True: "on", False: "off", None: "unknown"}[gpu_release]
    per = threads["threads_per_terminal"]
    print(f"   app threads {label}: {threads['app_threads']} (base {threads['app_threads_base']}, "
          f"{'n/a' if per is None else f'{per:.2f}'} per terminal of {threads['terminals']}); GPU release {gpu}")
    for name in SURFACE_THREADS:
        row = threads[name]
        woke = f", woke in {threads['window_s']:.0f} s idle: {row['woke']} ({row['cpu_us']:.0f} us CPU)" \
            if "woke" in row else ""
        print(f"     {name} threads: {row['threads']}{woke}")


def kind_deltas(base: dict, after: dict, per: int) -> dict:
    """{kind: {"processes_added", "mb_each"}}: footprint from `base` to `after` divided by `per`, plus a
    "total" row."""
    out = {}
    for kind in set(base["kinds"]) | set(after["kinds"]):
        first, last = base["kinds"].get(kind, {}), after["kinds"].get(kind, {})
        out[kind] = {"processes_added": last.get("count", 0) - first.get("count", 0),
                     "mb_each": round((last.get("footprint_bytes", 0) - first.get("footprint_bytes", 0))
                                      / MB / max(per, 1), 3)}
    grown = (sum(entry.get("footprint_bytes", 0) for entry in after["kinds"].values())
             - sum(entry.get("footprint_bytes", 0) for entry in base["kinds"].values()))
    out["total"] = {"processes_added": len(after["processes"]) - len(base["processes"]),
                    "mb_each": round(grown / MB / max(per, 1), 3)}
    return dict(sorted(out.items(), key=lambda item: -item[1]["mb_each"]))


def hidden_workspaces_phase(app: App, count: int, grace: float, recipes: list[str], url: str, opened: list,
                            chats, settle_and_sample, host_model: str, read_threads=None,
                            thread_window: float = 0) -> dict:
    """DC6. Opens `count` workspaces of the mix, shows the first workspace again so all of them are hidden,
    samples after --settle and again `grace` seconds after they went hidden (past the parked idle timeout),
    and prints what one hidden workspace costs per process kind. `host_model` is the terminal host model the
    launch gave the app (`unknown-attach` for an app this run did not launch).

    With `read_threads` (the app's ``thread_times``) it also gives the app threads per hidden terminal at both
    points (``terminal_threads``) and, over `thread_window` idle seconds after each, how many of the hidden terminals'
    renderer and IO threads woke (p07-memory-078: none, GPU-released or not)."""
    app.run("workspace.selectFirst")
    base = settle_and_sample("hidden-base")
    base_threads = read_threads() if read_threads else None
    base_report = MemoryReport.read(app) if read_threads else None
    base_surfaces = base_report.terminal_surfaces() if base_report else None

    def hidden_threads(report: MemoryReport | None) -> dict:
        surfaces = report.terminal_surfaces() if report else None
        added = surfaces - base_surfaces if surfaces is not None and base_surfaces is not None else None
        start = read_threads() if thread_window > 0 else None
        if start is not None:
            time.sleep(thread_window)  # test script: the idle window the hidden terminals' threads must sleep through
        return terminal_threads(base_threads, read_threads(), added, start, thread_window)

    made = 0
    while made < count:
        workspace = open_workspace(app, recipes[made % len(recipes)], url, 2000 + made, chats)
        if workspace is None:
            break
        opened.append(workspace)
        made += 1
    app.run("workspace.selectFirst")
    hidden_at = time.monotonic()
    phase = {"requested": count, "hidden": made, "grace_s": grace, "mix": recipes,
             "terminal_host_model": host_model, "terminal_host_model_requested": host_model}
    settled = settle_and_sample(f"hidden-{made}-settled")
    phase["settled"] = kind_deltas(base, settled, made)
    if host_model == "holder" and phase["settled"].get("terminal-host", {}).get("processes_added", 0) > 0:
        # Holder terminals start no terminal host: this daemon did not get the model (an older build).
        phase["terminal_host_model"] = "hosts"
    report = MemoryReport.read(app)
    if report is not None:
        phase["debug_memory_settled"] = report.workspaces()
        phase["hidden_iosurface_mb_settled"] = report.hidden_iosurface_mb()
    if base_threads is not None:
        phase["gpu_release"] = report.gpu_release() if report else None
        phase["threads_settled"] = hidden_threads(report)
    after = settled
    if grace > 0:
        time.sleep(max(0.0, grace - (time.monotonic() - hidden_at)))  # test script: the hidden workspaces' grace
        after = settle_and_sample(f"hidden-{made}-grace")
        report = MemoryReport.read(app)
        if report is not None:
            phase["debug_memory_after_grace"] = report.workspaces()
            phase["hidden_iosurface_mb_after_grace"] = report.hidden_iosurface_mb()
        if base_threads is not None:
            phase["threads_after_grace"] = hidden_threads(report)
    phase["after_grace"] = kind_deltas(base, after, made)
    print(f"== hidden workspaces: {made} of {count} hidden (mix {','.join(recipes)}), grace {grace:.0f} s, "
          f"terminal host model {phase['terminal_host_model']}"
          + (f" (requested {host_model}; the daemon started terminal hosts)"
             if phase["terminal_host_model"] != host_model else ""))
    print(f"   {'kind':<22}{'added':>7}{'MB/ws settled':>15}{'MB/ws after grace':>19}")
    for kind, entry in phase["after_grace"].items():
        early = phase["settled"].get(kind, {"mb_each": 0.0})
        print(f"   {kind:<22}{entry['processes_added']:>+7}{early['mb_each']:>15.3f}{entry['mb_each']:>19.3f}")
    states = phase.get("debug_memory_after_grace", phase.get("debug_memory_settled"))
    if states is None:
        print("   debug.memory: not in this build; process footprint only")
    else:
        for state, entry in sorted(states.items()):
            print(f"   debug.memory workspaces {state:<10}{entry['count']:>5}  attributed {entry['attributed_mb']:.2f} MB  "
                  f"terminals {entry['terminal_surfaces']} (GPU-resident {entry['gpu_resident_surfaces']})")
        iosurface = phase.get("hidden_iosurface_mb_after_grace", phase.get("hidden_iosurface_mb_settled"))
        shown = "unknown" if iosurface is None else f"{iosurface:.2f} MB"
        print(f"   hidden terminal IOSurface (non-volatile): {shown}")
    for key, label in (("threads_settled", "settled"), ("threads_after_grace", "after grace")):
        if key in phase:
            print_terminal_threads(label, phase[key], phase["gpu_release"])
    sys.stdout.flush()
    return phase


# HibernationPlanner.pace(at:) (CmuxNextHibernation/HibernationPlanner.swift), per pressure level: (pages per pass,
# seconds between passes while more are due, seconds a page is hidden at least). Without pressure two pages every 5 s,
# so a burst of hidden pages never closes at once; under warning one page every 15 s.
HIBERNATION_PACES = {"normal": (2, 5, 0), "warning": (1, 15, 60), "critical": (3, 3, 10)}
# HibernationPlanner.plan: under pressure the timeout is 10 minutes at most.
HIBERNATION_PRESSURE_CAP_MINUTES = 10.0
# debug.surfaces reads after the grace, until the hidden pages are hibernated; the last read is this long after the
# planner's last pass should have run.
HIBERNATION_POLL_S = 5
HIBERNATION_POLL_SLACK_S = 30
# BrowserHibernationSetting.hiddenMinutes of each named `browser.hibernation` mode.
HIBERNATION_MODE_MINUTES = {"moderate": 30.0, "aggressive": 10.0}
SLOPE_METRIC = "memory.hidden_slope"
# The `browser.hibernation` minutes a --hidden-slope launch sets (the bench hook that shortens the grace from the
# default 30 minutes; BrowserHibernationSetting reads a number as minutes).
SLOPE_HIBERNATE_AFTER_MINUTES = 1.0
SLOPE_STORIES = {"chromium": "memory-hidden", "webkit": "memory-hidden-webkit"}
# The process kind (``kind_of``) an open page of each engine runs in: without one, the footprint leaves the engine out.
ENGINE_PAGE_KINDS = {"chromium": "cef-renderer", "webkit": "webkit-webcontent"}
# How long the open pages get to start their engine processes before the slope gives up.
ENGINE_WAIT_S = 30


def hibernation_minutes(mode) -> float | None:
    """Minutes hidden before a page hibernates, for debug.surfaces' `hibernation.mode` (the `browser.hibernation`
    value: a mode name or a number of minutes); None when off or unknown."""
    if isinstance(mode, bool):
        return None
    if isinstance(mode, (int, float)):
        return float(mode) if mode > 0 else None
    return HIBERNATION_MODE_MINUTES.get(mode)


def slope_hibernation_minutes(state: dict, configured: float | None) -> float | None:
    """The hibernation timeout the grace waits for: what the app reports (debug.surfaces, DEBUG and bench-hook
    builds), else what this run configured, else the app's default mode (BrowserHibernationSetting.fallback)."""
    if "mode" in state:
        return hibernation_minutes(state["mode"])
    return configured if configured is not None else HIBERNATION_MODE_MINUTES["moderate"]


def hibernation_grace(minutes: float | None, pages: int, pressure: str = "normal") -> float:
    """Seconds from the moment `pages` browser pages went hidden until the planner's pace at `pressure` has
    hibernated the last of them; 0 when hibernation is off. An unknown level takes the slowest pace (warning)."""
    if minutes is None:
        return 0.0
    per_pass, interval, minimum_hidden = HIBERNATION_PACES.get(pressure, HIBERNATION_PACES["warning"])
    if pressure != "normal":
        minutes = min(minutes, HIBERNATION_PRESSURE_CAP_MINUTES)
    return max(minutes * 60, minimum_hidden) + math.ceil(pages / per_pass) * interval


def hibernation_state(app: App) -> dict:
    """debug.surfaces' hibernation summary: the `mode`, the `pressure`, how many pages are hibernated and how many
    are kept awake as neighbors of the shown one; {} on a build without it."""
    reply = app.call("debug.surfaces", timeout=60)
    state = reply.get("hibernation") if isinstance(reply, dict) else None
    if not isinstance(state, dict):
        return {}
    hibernated, neighbors = state.get("hibernated"), state.get("awake_neighbors")
    return {"mode": state.get("mode"), "pressure": state.get("pressure"),
            "hibernated": len(hibernated) if isinstance(hibernated, list) else None,
            "awake_neighbors": len(neighbors) if isinstance(neighbors, list) else 0}


def wait_hibernated(app: App, pages: int, hidden_at: float, grace_s, settle: float) -> tuple[dict, str | None]:
    """Reads debug.surfaces until each of the `pages` hidden pages is hibernated or kept awake as a neighbor, at most
    until the grace at the pressure it reports (plus `settle` and a slack) has passed since `hidden_at`. Returns
    (the last hibernation state, None or why the hidden state was not reached)."""
    while True:
        state = hibernation_state(app)
        if state.get("hibernated") is None:
            return state, "debug.surfaces reports no hibernated pages (a build without it): the hidden state is unconfirmed"
        if state["hibernated"] + state["awake_neighbors"] >= pages:
            return state, None
        waited = grace_s(pages, state.get("pressure") or "normal") + settle + HIBERNATION_POLL_SLACK_S
        if time.monotonic() - hidden_at >= waited:
            return state, (f"{state['hibernated']} of {pages} hidden pages hibernated ({state['awake_neighbors']} "
                           f"awake neighbors) {waited:.0f} s after they went hidden, at pressure {state.get('pressure')}")
        time.sleep(HIBERNATION_POLL_S)  # test script: waiting for the planner's last pass


def wait_engine(engine_missing) -> str | None:
    """None once `engine_missing()` (None, or why the engine's processes are not among the app's) finds them, else
    its last reason after ENGINE_WAIT_S."""
    deadline = time.monotonic() + ENGINE_WAIT_S
    while True:
        missing = engine_missing()
        if missing is None or time.monotonic() >= deadline:
            return missing
        time.sleep(1)  # test script: the open pages start their engine processes


def slope_samples(low: list[int], high: list[int], low_count: int, high_count: int) -> list[float]:
    """Bytes each hidden workspace adds, one per sample pair: (F_high - F_low) / (high_count - low_count)."""
    return [(after - before) / (high_count - low_count) for before, after in zip(low, high)]


def slope_error(phase: dict, message: str) -> dict:
    phase["error"] = message
    print(f"bench-memory: --hidden-slope: {message}", file=sys.stderr, flush=True)
    return phase


def hidden_slope_phase(app: App, recipe: str, counts: list[int], samples: int, interval: float,
                       grace_s, settle: float, take_sample, urls: list[str], opened: list, engine_missing,
                       chats=None) -> dict:
    """Footprint at each of the two `counts` of hidden `recipe` workspaces after the hibernation grace, and the slope
    between them. `grace_s(pages, pressure)` is the grace for that many hidden pages; `take_sample(label, workspaces)`
    is one ``sample``; `engine_missing()` is None when the app's processes include its pages' engine, else why not.
    Every sample is kept: `counts[n]["footprint_bytes"]` holds `samples` totals. A workspace whose page did not open,
    no engine process, or pages that never hibernate set `error` and end the phase without a slope."""
    low, high = counts
    phase: dict = {"recipe": recipe, "counts": {}, "samples_per_count": samples, "interval_s": interval}
    for count in counts:
        while len(opened) < count:
            workspace, failed = open_workspace_parts(app, recipe, urls[len(opened) % len(urls)], 3000 + len(opened),
                                                     chats)
            if workspace is None:
                return slope_error(phase, f"opened {len(opened)} of {count} workspaces")
            opened.append(workspace)
            if failed:
                return slope_error(phase, f"workspace {len(opened)} ({workspace}): {', '.join(failed)} did not open")
        if count == low:
            missing = wait_engine(engine_missing)
            if missing is not None:
                return slope_error(phase, missing)
        app.run("workspace.selectFirst")
        hidden_at = time.monotonic()
        grace = grace_s(count, "normal")
        time.sleep(max(0.0, hidden_at + grace + settle - time.monotonic()))  # test script: the hibernation grace
        hibernation, unreached = wait_hibernated(app, count, hidden_at, grace_s, settle)
        if unreached is not None:
            return slope_error(phase, f"{count} hidden: {unreached}")
        taken = []
        for index in range(samples):
            if index:
                time.sleep(interval)  # test script: spacing between the samples of one count
            taken.append(take_sample(f"slope-{count}-{index + 1}", count + 1))
        phase["counts"][str(count)] = {
            "grace_s": grace, "hibernation": hibernation,
            "footprint_bytes": [result["total_footprint_bytes"] for result in taken],
            "kinds_mb": [{kind: entry["footprint_mb"] for kind, entry in result["kinds"].items()} for result in taken]}
    phase["slope_bytes"] = slope_samples(phase["counts"][str(low)]["footprint_bytes"],
                                         phase["counts"][str(high)]["footprint_bytes"], low, high)
    phase["slope_summary"] = perf_stats.summary(phase["slope_bytes"])
    slope_p50 = phase["slope_summary"]["p50"]
    footprints = {count: perf_stats.pct(phase["counts"][str(count)]["footprint_bytes"], 0.5) for count in counts}
    print(f"== hidden slope ({recipe}): footprint p50 {footprints[low] / MB:.1f} MB at {low} hidden, "
          f"{footprints[high] / MB:.1f} MB at {high} hidden; slope p50 {slope_p50 / MB:.3f} MB per hidden workspace "
          f"({samples} samples per count)")
    for count in counts:
        entry = phase["counts"][str(count)]
        hibernation = entry["hibernation"]
        print(f"   {count:>4} hidden: grace {entry['grace_s']:.0f} s, hibernation mode {hibernation.get('mode')}, "
              f"{hibernation['hibernated']} pages hibernated, {hibernation['awake_neighbors']} awake neighbors; "
              "footprint MB " + ", ".join(f"{value / MB:.1f}" for value in entry["footprint_bytes"]))
    print(f"PERF-HIDDEN-SLOPE recipe={recipe} slope_bytes_p50={slope_p50:.0f} "
          f"samples={','.join(f'{value:.0f}' for value in phase['slope_bytes'])}", flush=True)
    return phase


def record_slope(bench, story: str, engine: str, phase: dict, counts: list[int]) -> dict:
    """Writes the slope phase as result-v1 through `bench`.record (a BenchApp): memory.hidden_slope against target row
    memory-slope.<engine>, and memory.hidden_footprint.<count> for each of `counts`, every sample. A phase without a
    slope writes nothing, not even the footprint of a count it reached. Returns {metric: path or
    "not recorded: <reason>"}."""
    metrics = [SLOPE_METRIC] + [f"memory.hidden_footprint.{count}" for count in counts]
    if phase.get("error") or not phase.get("slope_bytes"):
        why = phase.get("error") or "no slope"
        return {metric: f"not recorded: {why}" for metric in metrics}
    series = [(SLOPE_METRIC, phase["slope_bytes"], f"memory-slope.{engine}")]
    series += [(metric, phase["counts"][str(count)]["footprint_bytes"], None)
               for metric, count in zip(metrics[1:], counts)]
    written = {}
    for metric, samples, target in series:
        try:
            written[metric] = str(bench.record(story, metric, "bytes", samples, better="lower", engine=engine,
                                               target_ref=target))
        except (RecordError, perf_result.ResultError) as error:
            written[metric] = f"not recorded: {error}"
    return written


def slope_failure(phase: dict | None) -> str | None:
    """Why a --hidden-slope run is not a result (the phase's error, or a metric it could not record), else None."""
    if not phase:
        return "the phase did not run"
    if phase.get("error"):
        return phase["error"]
    unrecorded = [f"{metric}: {outcome}" for metric, outcome in phase.get("results", {}).items()
                  if outcome.startswith("not recorded")]
    return "; ".join(unrecorded) or None


def set_pressure(app: App, level: str) -> tuple[str, str | None]:
    """The debug pressure override (DEBUG and bench-hook builds), which the memory coordinator and browser
    hibernation both take (p07-memory-004); `none` clears it and hands both the kernel's level again.
    ("set", None) when the reply's `override` is `level` (null for `none`); ("missing", error) when this build
    has no such method; ("failed", why) for anything else (a timeout, a refusal, another override)."""
    reply = app.call("debug.hibernation.pressure", {"level": level}, timeout=30)
    error = reply.get("error")
    if error is not None:
        # ControlRouter.methodNotFound: a release build without the debug method.
        return ("missing" if "method_not_found" in str(error) else "failed"), str(error)
    want = None if level == "none" else level
    if "override" not in reply or reply["override"] != want:
        return "failed", f"override {reply.get('override', 'absent')!r}, not {want!r}: {json.dumps(reply)[:200]}"
    return "set", None


def pressure_phase(app: App, app_pid: int, level: str, window: float, interval: float, settle_and_sample) -> dict:
    """DC10. Sets the pressure override to `level` and follows the app's footprint for `window` seconds
    through proc_pid_rusage (no request to the app while it releases). released_mb is the app footprint
    before minus the lowest in the window, release_s the time to 90 % of that drop, counted from the moment
    the override request is sent (the app releases in the request's own main-actor turn), and the managed
    consumers' footprint before is what the drop should reach 80 % of."""
    before = settle_and_sample(f"pressure-{level}-before")
    phase: dict = {"level": level, "window_s": window}
    report = MemoryReport.read(app)
    if report is not None:
        managed, unknown = report.managed_bytes()
        phase.update({"managed_before_mb": round(managed / MB, 1), "managed_unknown": unknown,
                      "managed_consumers_before": report.managed(), "level_before": report.level()})
    start = usage(app_pid)
    if start is None:
        raise SystemExit("bench-memory: the app exited before the pressure phase")
    began = time.monotonic()
    outcome, error = set_pressure(app, level)
    if outcome == "missing":
        print(f"== pressure {level}: skipped, this build has no debug.hibernation.pressure override "
              "(DEBUG and bench-hook builds have it)")
        phase["skipped"] = "no pressure override"
        return phase
    timeline = [(0.0, start[1])]
    try:
        if outcome == "failed":
            # The override may be set all the same (a reply that timed out); the finally clears it.
            print(f"== pressure {level}: the override request failed: {error}")
            phase["error"] = error
            return phase
        while True:
            got = usage(app_pid)
            if got is None:
                break
            timeline.append((round(time.monotonic() - began, 3), got[1]))
            if time.monotonic() - began >= window:
                break
            time.sleep(interval)  # test script: footprint samples while the app releases
        lowest = min(footprint for _, footprint in timeline)
        released = start[1] - lowest
        release_s = (next(t for t, footprint in timeline if start[1] - footprint >= 0.9 * released)
                     if released >= MB else None)
        phase.update({"app_before_mb": round(start[1] / MB, 1), "app_lowest_mb": round(lowest / MB, 1),
                      "released_mb": round(released / MB, 1), "release_s": release_s,
                      "timeline": [(t, round(footprint / MB, 1)) for t, footprint in timeline]})
        after = settle_and_sample(f"pressure-{level}-after")
        phase["kinds_delta_mb"] = {kind: entry["mb_each"] for kind, entry in kind_deltas(before, after, 1).items()}
        report = MemoryReport.read(app)
        if report is not None:
            managed, _ = report.managed_bytes()
            phase.update({"managed_after_mb": round(managed / MB, 1),
                          "managed_consumers_after": report.managed(), "level_after": report.level()})
    finally:
        cleared, why = set_pressure(app, "none")
        if cleared != "set":
            print(f"bench-memory: clearing the pressure override failed ({why}); the app may keep it",
                  file=sys.stderr)
            phase["clear_error"] = why
    if phase.get("managed_before_mb"):
        phase["released_pct_of_managed"] = round(100 * phase["released_mb"] / phase["managed_before_mb"], 1)
    release = f"{phase['release_s']:.2f}" if phase["release_s"] is not None else "n/a (under 1 MB)"
    print(f"== pressure {level} (override): released_mb {phase['released_mb']:.1f}, release_s {release}, "
          f"app {phase['app_before_mb']:.1f} -> lowest {phase['app_lowest_mb']:.1f} MB in {window:.0f} s")
    if "managed_before_mb" not in phase:
        print("   managed footprint before: unknown (no debug.memory in this build; process footprint only)")
    else:
        share = phase.get("released_pct_of_managed")
        print(f"   managed footprint before {phase['managed_before_mb']:.1f} MB "
              f"({phase['managed_unknown']} consumers unknown), after {phase.get('managed_after_mb', 'n/a')} MB, "
              f"released {f'{share:.0f} %' if share is not None else 'n/a'} of managed")
        before_rows, later = phase["managed_consumers_before"], phase.get("managed_consumers_after", {})
        empty = {"instances": 0, "footprint_bytes": 0, "unknown": 0}
        rows = sorted(((name, before_rows.get(name, empty), later.get(name, empty))
                       for name in set(before_rows) | set(later)),
                      key=lambda row: row[2]["footprint_bytes"] - row[1]["footprint_bytes"])
        for name, first, last in rows[:10]:
            unknown = first["unknown"] + last["unknown"]
            print(f"   {first['footprint_bytes'] / MB:>8.1f} -> {last['footprint_bytes'] / MB:>8.1f} MB  {name} "
                  f"(x{first['instances']} -> x{last['instances']}{f', {unknown} unknown' if unknown else ''})")
    print("   footprint change per kind (after - before):")
    for kind, delta in phase["kinds_delta_mb"].items():
        print(f"   {kind:<22}{delta:>+10.1f} MB")
    sys.stdout.flush()
    return phase


BFCACHE_FEATURE = "memoryBackForwardCacheFlush"
# How long the tabs get to walk their navigation chains before the phase measures what it has.
NAVIGATE_WAIT_S = 120
NAVIGATE_POLL_S = 1


def feature_state(app: App, name: str) -> str | None:
    """Feature `name`'s state as features.list reports it (`on`, `off`, ...), None on a build without it."""
    reply = app.call("features.list", timeout=30)
    rows = reply.get("features") if isinstance(reply, dict) else None
    row = next((f for f in rows or [] if isinstance(f, dict) and f.get("name") == name), None)
    return row.get("state") if row else None


def renderer_point(result: dict) -> dict:
    """The Chromium renderers of a sample: their count and footprint, and the footprint of every process."""
    kinds = result.get("kinds", {})
    renderers = kinds.get(ENGINE_PAGE_KINDS["chromium"], {})
    total = result.get("total_footprint_bytes")
    if total is None:
        total = sum(entry.get("footprint_bytes", 0) for entry in kinds.values())
    return {"renderers": renderers.get("count", 0), "renderer_mb": round(renderers.get("footprint_bytes", 0) / MB, 1),
            "total_mb": round(total / MB, 1)}


def navigate_phase(app: App, steps: int, tabs: int, visits: set, hide, settle_and_sample, freeze_wait: float,
                   window: float) -> dict:
    """navigate-N (p07-memory-101): `tabs` tabs walk their chains of `steps` same-site pages (``local_sites``, so
    each keeps `steps` pages behind Back), then `hide()` shows another workspace so every tab is hidden. It samples
    the Chromium renderers' count and footprint hidden, after `freeze_wait` seconds (0: no freeze sample; the
    freeze flush needs `browser.freezeSeconds` below it), and `window` seconds after the debug pressure override
    goes to warning (cleared at the end, also after a failure). Run it with feature memoryBackForwardCacheFlush on
    and off (--bfcache-flush): the deltas against the hidden sample are what the flushes free."""
    phase: dict = {"steps": steps, "tabs": tabs, "bfcache_flush": feature_state(app, BFCACHE_FEATURE)}
    deadline = time.monotonic() + NAVIGATE_WAIT_S
    while True:
        done = len({site for site, left in visits if left == 0})
        if done >= tabs or time.monotonic() >= deadline:
            break
        time.sleep(NAVIGATE_POLL_S)  # test script: the pages walk their chains by themselves
    phase["navigated"] = done
    if done < tabs:
        print(f"bench-memory: navigate-{steps}: {done} of {tabs} tabs reached the end of their chain in "
              f"{NAVIGATE_WAIT_S} s", file=sys.stderr, flush=True)
    if hide() is None:
        phase["error"] = "no workspace to show, so the tabs never went hidden"
        print(f"bench-memory: navigate-{steps}: {phase['error']}", file=sys.stderr, flush=True)
        return phase
    points = {"hidden": renderer_point(settle_and_sample(f"navigate-{steps}-hidden"))}
    if freeze_wait > 0:
        time.sleep(freeze_wait)  # test script: the hidden pages' freeze timer
        points["frozen"] = renderer_point(settle_and_sample(f"navigate-{steps}-frozen"))
    try:
        state, error = set_pressure(app, "warning")
        if state == "set":
            time.sleep(window)  # test script: the flush and the renderers' release
            points["warning"] = renderer_point(settle_and_sample(f"navigate-{steps}-warning"))
        elif state == "missing":
            phase["skipped"] = "no pressure override"
        else:
            phase["error"] = error
    finally:
        cleared, why = set_pressure(app, "none")
        if cleared == "failed":
            phase["clear_error"] = why
    phase["points"] = points
    base = points["hidden"]
    phase["deltas"] = {label: {key: round(point[key] - base[key], 1) for key in base}
                       for label, point in points.items() if label != "hidden"}
    print(f"== navigate-{steps}: {tabs} tabs, {done} walked their chain, {BFCACHE_FEATURE} {phase['bfcache_flush']}")
    for label, point in points.items():
        delta = phase["deltas"].get(label)
        change = (f" ({delta['renderers']:+.0f} renderers, {delta['renderer_mb']:+.1f} MB renderers, "
                  f"{delta['total_mb']:+.1f} MB total)") if delta else ""
        print(f"   {label:<8} renderers {point['renderers']:>3}  renderer footprint {point['renderer_mb']:>8.1f} MB  "
              f"total {point['total_mb']:>8.1f} MB{change}")
    if "error" in phase or "skipped" in phase:
        print(f"   warning sample: {phase.get('error') or phase.get('skipped')}")
    sys.stdout.flush()
    return phase


KERNEL_LEVELS = {"warn": 2, "critical": 4}
MEMORY_PRESSURE = "/usr/bin/memory_pressure"


def kernel_pressure_level() -> int | None:
    """kern.memorystatus_vm_pressure_level (1 normal, 2 warn, 4 critical): the
    level the app's KernelMemoryPressureSource reads on each event. None when
    sysctl fails."""
    value = ctypes.c_int32(0)
    size = ctypes.c_size_t(ctypes.sizeof(value))
    if _libsystem.sysctlbyname(b"kern.memorystatus_vm_pressure_level", ctypes.byref(value),
                               ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
        return None
    return value.value


def owned_footprint_mb(app_pid: int, bundle: str) -> float:
    total = 0
    for pid in owned(app_pid, bundle):
        got = usage(pid)
        if got is not None:
            total += got[1]
    return round(total / MB, 1)


def kernel_pressure(app_pid: int, bundle: str, level: str, window: float, workspaces: int, top: int) -> dict:
    """Real kernel pressure (`memory_pressure -S -l LEVEL`), not the app's
    debug override: the kernel's level changes, every process's dispatch
    source fires, and the app reads the new level. Samples the footprint of
    the app and its processes before, every 0.5 s for `window` seconds, and
    after. memory_pressure -S needs root: without it (and without passwordless
    sudo) this records why and the run goes on.

    memory_pressure holds the level for -s seconds, then resets it to normal;
    it has no signal handler, so a killed simulator never resets. The hold is
    the window, so it ends with the window; on an interrupt the run waits only
    for the rest of the hold, then terminates the simulator."""
    hold = max(1, math.ceil(window))
    result = {"level": level, "window_s": window}
    argv = [MEMORY_PRESSURE, "-S", "-l", level, "-s", str(hold)]
    if not os.access(MEMORY_PRESSURE, os.X_OK):
        result["skipped"] = f"{MEMORY_PRESSURE} not found"
    elif os.geteuid() != 0:
        if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
            result["skipped"] = "memory_pressure -S needs root: run as root or allow passwordless sudo"
        argv = ["sudo", "-n"] + argv
    if "skipped" in result:
        print(f"bench-memory: --kernel-pressure {level} skipped: {result['skipped']}", flush=True)
        return result
    want = KERNEL_LEVELS[level]
    before = sample(app_pid, bundle, f"kernel-pressure-{level}-before", workspaces)
    print_sample(before, top)
    result["kernel_level_before"] = kernel_pressure_level()
    simulator = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    started = time.monotonic()
    timeline = []
    try:
        while time.monotonic() - started < window:
            time.sleep(0.5)  # test script: the footprint timeline under pressure
            seen = kernel_pressure_level()
            timeline.append({"t_s": round(time.monotonic() - started, 2), "kernel_level": seen,
                             "total_footprint_mb": owned_footprint_mb(app_pid, bundle)})
            if seen == want and "kernel_level_reached_s" not in result:
                result["kernel_level_reached_s"] = timeline[-1]["t_s"]
            if simulator.poll() is not None and simulator.returncode != 0:
                break
        after = sample(app_pid, bundle, f"kernel-pressure-{level}-after", workspaces)
        print_sample(after, top)
    except BaseException:
        # Ctrl-C or SIGTERM: wait at most for the rest of the hold (its reset), then stop it.
        stop_simulator(simulator, max(0.0, hold - (time.monotonic() - started)) + 2)
        raise
    _, errors = stop_simulator(simulator, hold + 10)
    result["kernel_level_after"] = kernel_pressure_level()
    if simulator.returncode != 0:
        result["simulator_error"] = (errors or "").strip()[:300] or f"exit {simulator.returncode}"
    fall = before["total_footprint_mb"] - after["total_footprint_mb"]
    result.update({"timeline": timeline, "footprint_before_mb": before["total_footprint_mb"],
                   "footprint_after_mb": after["total_footprint_mb"], "fall_mb": round(fall, 1),
                   "fall_pct": round(100 * fall / before["total_footprint_mb"], 1) if before["total_footprint_mb"] else None,
                   "samples": [before, after]})
    print(f"PERF-KERNEL-PRESSURE level={level} kernel_level_reached_s={result.get('kernel_level_reached_s')} "
          f"footprint_before_mb={result['footprint_before_mb']} footprint_after_mb={result['footprint_after_mb']} "
          f"fall_mb={result['fall_mb']} fall_pct={result['fall_pct']} "
          f"simulator_error={result.get('simulator_error')}", flush=True)
    if "kernel_level_reached_s" not in result:
        print(f"bench-memory: kern.memorystatus_vm_pressure_level never reached {want} within {window} s", flush=True)
    return result


def stop_simulator(simulator: subprocess.Popen, timeout: float) -> tuple[str | None, str | None]:
    """Waits up to `timeout` s for memory_pressure to reset the level and
    exit; terminates it after that, saying the level may stay simulated."""
    try:
        return simulator.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        simulator.terminate()
        print("bench-memory: memory_pressure did not end with its hold and was terminated; the simulated "
              "level stays until the next memory_pressure -S run resets it", file=sys.stderr, flush=True)
        return simulator.communicate()


class ColdScrollbackEnv:
    """The effects cold_scrollback.cold_scrollback_phase needs, on a real app and its daemon."""

    python = sys.executable

    def __init__(self, app: App, app_pid: int, bundle: str, url: str, opened: list):
        self.app, self.app_pid, self.bundle, self.url, self.opened = app, app_pid, bundle, url, opened
        self.binary = os.path.join(bundle, "Contents/Resources/bin/cmux-tui")
        self.tag = tag_of(bundle)
        self.socket: str | None = None
        self.next_id = 0
        self.sleep, self.monotonic = time.sleep, time.monotonic

    def say(self, text: str):
        print(text, flush=True)

    def daemon(self, cmd: str, params: dict, timeout: float) -> dict:
        """One request to the app's daemon; {"ok": False, "error": ...} when it cannot be made."""
        try:
            if self.socket is None:
                status = daemon_status(self.binary, self.tag)
                if status is None:
                    return {"ok": False, "error": "the app's daemon is not running"}
                self.socket = status["socket"]
            self.next_id += 1
            return daemon_request(self.socket, dict(params, id=self.next_id, cmd=cmd), timeout)
        except (OSError, ValueError, ConnectionError, subprocess.TimeoutExpired) as error:
            return {"ok": False, "error": f"{cmd}: {error}"}

    def columns(self) -> tuple[dict[int, dict], dict[int, str]]:
        """`footprint -j` columns of the app and its daemon-side processes, and their kinds."""
        kinds = {pid: kind for pid, (kind, _) in owned(self.app_pid, self.bundle).items()
                 if kind == "app" or kind in cold_scrollback.DAEMON_KINDS}
        if not kinds:
            return {}, {}
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "footprint.json")
            try:
                ran = subprocess.run(["footprint", "-j", path, *map(str, sorted(kinds))], capture_output=True,
                                     text=True, timeout=300)
                why = (ran.stderr or ran.stdout).strip()[:300]
                with open(path) as handle:
                    columns = cold_scrollback.parse_footprint(json.load(handle))
            except subprocess.TimeoutExpired:
                why, columns = "timed out after 300 s", None
            except (OSError, ValueError) as error:
                why, columns = f"{error}", None
        if columns is None:
            # The sample is then invalid (no daemon category rows) and the decision says not measured.
            print(f"bench-memory: footprint -j failed: {why}", file=sys.stderr, flush=True)
            columns = {}
        return columns, kinds

    @staticmethod
    def press(free_pct: int, hold_s: float) -> dict:
        """Real memory pressure: `memory_pressure -p PCT -y S` allocates until PCT% of RAM is free, waits S
        seconds, then exits and frees its pages. Not -S, which only sets the level the dispatch sources read and
        makes the kernel compress nothing; not -l, which allocates and then waits forever."""
        if not os.access(MEMORY_PRESSURE, os.X_OK):
            return {"ok": False, "error": f"{MEMORY_PRESSURE} not found"}
        argv = [MEMORY_PRESSURE, "-Q", "-p", str(free_pct), "-y", str(max(1, math.ceil(hold_s)))]
        started = time.monotonic()
        try:
            ran = subprocess.run(argv, capture_output=True, text=True, timeout=hold_s + 900)
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": f"{' '.join(argv)} did not exit within {hold_s + 900:.0f} s"}
        except OSError as error:
            return {"ok": False, "error": f"{' '.join(argv)}: {error}"}
        result = {"ok": ran.returncode == 0, "argv": argv, "seconds": round(time.monotonic() - started, 1),
                  "kernel_level_after": kernel_pressure_level()}
        if ran.returncode != 0:
            result["error"] = (ran.stderr or ran.stdout).strip()[:300] or f"exit {ran.returncode}"
        return result

    @staticmethod
    def vm_stat() -> str:
        return subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=30).stdout

    def open_workspace(self) -> str | None:
        workspace, _ = open_workspace_parts(self.app, "none", self.url, 3000 + len(self.opened))
        if workspace:
            self.opened.append(workspace)
        return workspace

    def terminal_surface(self, workspace: str) -> int | None:
        """The daemon surface of the workspace's first terminal tab; adds one when the workspace has none."""
        for attempt in range(2):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                surface = workspace_terminal(self.app.call("snapshot.get").get("topology") or {}, workspace)
                if surface is not None:
                    return surface
                time.sleep(0.1)  # test script: polls the app's published snapshot for the new terminal
            if attempt == 0:
                self.app.run("newSurface")
        return None


def workspace_terminal(topology: dict, workspace: str) -> int | None:
    """The daemon surface id of `workspace`'s first terminal tab in a snapshot.get topology, or None."""
    for row in topology.get("workspaces") or []:
        if row.get("id") != workspace:
            continue
        for screen in row.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("kind") == "terminal" and str(tab.get("surface", "")).isdigit():
                        return int(tab["surface"])
    return None


def cold_scrollback_config(count: int) -> dict:
    """Launch settings: the daemon's scrollback budget holds every cold terminal's full scrollback twice over."""
    total = 2 * count * cold_scrollback.SCROLLBACK_LIMIT_BYTES
    return {"terminal": {"scrollback": {"maxTotalMemoryBytes": total}}}


def launch_env(cef_switches: str, host_model: str | None) -> dict:
    """The launch knobs of the app's environment. The app strips every inherited CMUX_* variable that is not
    CMUX_NEXT_* (LaunchIdentity.stripInheritedEnvironment), so the daemon's host model goes under its app name,
    which DaemonDiagnosticKnobs passes on to the daemon."""
    env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": cef_switches} if cef_switches else {}
    if host_model:
        env["CMUX_NEXT_TUI_TERMINAL_HOST_MODEL"] = host_model
    return env


# The debug tunable the terminalGPURelease feature replaces (MemorySettings.terminalGPURelease). Launch reads it only
# from the debug tunables file (DebugSettingsService.launchFile), never from cmux.json.
GPU_RELEASE_TUNABLE = "memory.discard.terminalGPURelease"


def gpu_release_env(gpu_release: str | None, folder: str) -> dict:
    """The launch env for --gpu-release: a debug tunables file in `folder` that sets ``GPU_RELEASE_TUNABLE``, named
    by CMUX_NEXT_DEBUG_TUNABLES_FILE as chromium-host-bench.py does. A bench build of a .dev or .debug bundle
    reads it; {} without --gpu-release."""
    if not gpu_release:
        return {}
    path = os.path.join(folder, "debug-tunables.json")
    with open(path, "w") as handle:
        json.dump({"version": 1, "values": {GPU_RELEASE_TUNABLE: gpu_release == "on"}}, handle)
    return {"CMUX_NEXT_DEBUG_TUNABLES_FILE": path}


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def check_args(parser: argparse.ArgumentParser, args) -> list[int]:
    """Refuses the option combinations a run cannot honor; returns the two --slope-counts, low first ([] without
    --hidden-slope)."""
    if args.grace and args.hidden_workspaces is None and not args.hidden_slope:
        parser.error("--grace needs --hidden-workspaces or --hidden-slope")
    if args.hidden_workspaces is not None and args.tabs:
        parser.error("--hidden-workspaces and --tabs are separate runs")
    if args.navigate is not None and (args.navigate < 1 or not args.tabs or args.urls != "local"):
        parser.error("--navigate N (N >= 1) walks the --tabs tabs through local pages (--urls local)")
    if args.bfcache_flush and (args.socket or args.navigate is None):
        parser.error(f"--bfcache-flush sets {BFCACHE_FEATURE} of an app this run launches, for --navigate")
    if args.navigate_freeze_wait < 0 or args.navigate_window < 0:
        parser.error("--navigate-freeze-wait and --navigate-window are seconds >= 0")
    if args.gpu_release and args.socket:
        parser.error(f"--gpu-release sets {GPU_RELEASE_TUNABLE} of an app this run launches, not of an attached one")
    if args.thread_window < 0:
        parser.error("--thread-window is a number of seconds >= 0")
    if args.terminal_host_model and args.socket:
        parser.error("--terminal-host-model sets the model of an app this run launches, not of an attached one")
    if args.hibernate_after is not None and (args.socket or args.hibernate_after <= 0):
        parser.error("--hibernate-after is a number of minutes > 0, for an app this run launches")
    if args.tag is not None and tag_of(f"cmux DEV {args.tag}.app") != tag_of(args.app):
        parser.error(f"--tag {args.tag!r} is not the tag of --app {args.app!r}")
    if args.cold_scrollback is not None:
        if (args.tabs or args.hidden_workspaces is not None or args.hidden_slope or args.workspaces
                or args.churn_minutes or args.pressure or args.kernel_pressure):
            parser.error("--cold-scrollback is a run of its own (no --tabs, --hidden-workspaces, --hidden-slope, "
                         "--workspaces, churn or pressure)")
        if args.cold_scrollback < 1 or args.cold_scrollback_mb <= 0 or args.cold_codec_samples < 1:
            parser.error("--cold-scrollback, --cold-scrollback-mb and --cold-codec-samples are > 0")
        if args.terminal_host_model == "hosts":
            parser.error("--cold-scrollback runs the holder model: a terminal host keeps a second VT copy of each "
                         "scrollback, so the daemon's bytes would be half of what a terminal keeps")
        if not 0 <= args.cold_pressure < 100:
            parser.error("--cold-pressure is a percent of free RAM, 1 to 99, or 0 for none")
        if not args.socket:
            args.terminal_host_model = "holder"
        try:
            args.cold_idle_minutes = sorted(float(n) for n in args.cold_idle.split(",") if n)
        except ValueError:
            parser.error(f"--cold-idle {args.cold_idle!r}: idle minutes, e.g. 0,10,30")
        if not args.cold_idle_minutes or args.cold_idle_minutes[0] < 0:
            parser.error(f"--cold-idle {args.cold_idle!r}: idle minutes >= 0, e.g. 0,10,30")
    if not args.hidden_slope:
        return []
    if args.tabs or args.hidden_workspaces is not None or args.workspaces or args.churn_minutes:
        parser.error("--hidden-slope is a run of its own (no --tabs, --hidden-workspaces, --workspaces or churn)")
    try:
        counts = sorted(int(n) for n in args.slope_counts.split(",") if n)
    except ValueError:
        parser.error(f"--slope-counts {args.slope_counts!r}: two workspace counts, e.g. 10,60")
    if len(counts) != 2 or counts[0] < 1 or counts[0] == counts[1]:
        parser.error(f"--slope-counts {args.slope_counts!r}: two different workspace counts >= 1, e.g. 10,60")
    if args.slope_samples < 1:
        parser.error("--slope-samples is at least 1")
    return counts


def out_paths(out: str | None, hidden_slope: bool) -> tuple[str | None, str | None]:
    """(report file, result-v1 folder) of --out. It is the report file, except that with --hidden-slope a path that
    does not end in .json is the lab runner's folder for the result-v1 files and bench-memory.json."""
    if not out:
        return None, None
    if out.endswith(".json") or not hidden_slope:
        return out, None
    os.makedirs(out, exist_ok=True)
    return os.path.join(out, "bench-memory.json"), out


def run_hidden_slope(app: App, args, counts: list[int], opened: list, chats, app_pid: int, bundle: str, report: dict,
                     bench, results_dir: str | None) -> dict:
    """The --hidden-slope run: its local sites, its grace (--grace, else the app's hibernation timeout plus the
    planner's pace), the phase, and its result-v1 files when there is a results folder."""
    state = hibernation_state(app)
    minutes = slope_hibernation_minutes(state, args.hibernate_after)
    if args.hibernate_after is not None and minutes != args.hibernate_after:
        print(f"bench-memory: the app reports hibernation mode {state.get('mode')!r}, not the "
              f"{args.hibernate_after:g} minutes its config sets; the grace follows the app", file=sys.stderr, flush=True)
    report["hibernation_mode"] = state.get("mode")
    report["hibernation_minutes"] = minutes

    def grace_s(pages: int, pressure: str) -> float:
        return args.grace if args.grace else hibernation_grace(minutes, pages, pressure)

    def engine_missing() -> str | None:
        kinds = sorted({kind for kind, _ in owned(app_pid, bundle).values()})
        want = ENGINE_PAGE_KINDS[args.engine]
        return None if want in kinds else f"no {want} process of the app for its open pages (kinds: {', '.join(kinds)})"

    def take_sample(label: str, workspaces: int) -> dict:
        result = sample(app_pid, bundle, label, workspaces, 0)
        report["samples"].append(result)
        print_sample(result, args.top)
        return result

    urls = tab_urls(args.urls, counts[1])
    phase = hidden_slope_phase(app, f"terminal+{args.engine}", counts, args.slope_samples, args.slope_interval,
                               grace_s, args.settle, take_sample, urls, opened, engine_missing, chats)
    if results_dir and bench is not None:
        story = args.story or SLOPE_STORIES[args.engine]
        phase["results"] = record_slope(bench, story, args.engine, phase, counts)
        for metric, outcome in phase["results"].items():
            print(f"bench-memory: {metric}: {outcome}")
    return phase


def parse_args(argv=None):
    """(args, the two --slope-counts low first or []) of a command line; exits 2 on an invalid one."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the .app bundle")
    parser.add_argument("--tag", help="the lab runner's tag of --app (checked against the bundle's name)")
    parser.add_argument("--session", choices=["light"], default="light",
                        help="result-v1 session; the bench launches with a fresh state (light)")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--workspaces", help="workspace counts to sample (default 1,10,30; 1 with --hidden-workspaces)")
    parser.add_argument("--mix", default="terminal+chat,terminal+browser,terminal")
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--measure", type=float, default=0,
                        help="seconds of idle CPU and wakeup measurement after each settle (0: memory only)")
    parser.add_argument("--churn-minutes", type=float, default=0)
    parser.add_argument("--sample-minutes", type=float, default=5)
    parser.add_argument("--url", default="https://example.com")
    parser.add_argument("--tabs", help="browser-tab counts to sample, e.g. 1,10,20 (instead of --workspaces)")
    parser.add_argument("--urls", default="local",
                        help="--tabs and --hidden-slope: local, real or a comma list of URLs")
    parser.add_argument("--navigate", type=int, metavar="N",
                        help="navigate-N phase after --tabs (--urls local): each tab walks N same-site pages, the tabs "
                             "go hidden, and the renderers' count and footprint are sampled hidden, after "
                             "--navigate-freeze-wait and at the warning pressure override (p07-memory-101)")
    parser.add_argument("--navigate-freeze-wait", type=float, default=0, metavar="S",
                        help="--navigate: seconds hidden before the freeze sample (0: none)")
    parser.add_argument("--navigate-window", type=float, default=10, metavar="S",
                        help="--navigate: seconds at the warning override before its sample")
    parser.add_argument("--bfcache-flush", choices=("on", "off"),
                        help=f"launch, --navigate: feature {BFCACHE_FEATURE} as a Labs local choice; run on, then off")
    parser.add_argument("--cef-switches", default="",
                        help="launch, DEBUG builds: extra Chromium switches, colon-separated (CMUX_NEXT_CEF_EXTRA_SWITCHES)")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--config", default="{}",
                        help='launch: cmux.json settings as JSON, e.g. \'{"browser": {"hibernation": 1}}\'')
    parser.add_argument("--fake-agent", metavar="SCRIPT",
                        help="an ACP agent script (cmux-tui/crates/acpmux/tests/fake_agent.py) the chats use: "
                             "its turns end, as a chat's do after its reply")
    parser.add_argument("--hidden-workspaces", type=int, metavar="N",
                        help="hidden-workspace phase: open N workspaces of --mix, show the first one again, and "
                             "print the footprint each hidden workspace adds per process kind, after --settle and "
                             "after --grace")
    parser.add_argument("--grace", type=float, default=0, metavar="S",
                        help="--hidden-workspaces: seconds after the workspaces went hidden for the second sample "
                             "(960 is past the 15 min parked idle timeout); --hidden-slope: the grace before each "
                             "count's samples instead of the hibernation timeout plus the planner's pace")
    parser.add_argument("--hidden-slope", action="store_true",
                        help="hidden-workspace memory slope: footprint at the two --slope-counts of hidden "
                             "terminal+<--engine> workspaces after the hibernation grace, and the bytes each adds")
    parser.add_argument("--engine", choices=sorted(SLOPE_STORIES), default="chromium",
                        help="--hidden-slope: the page engine of each workspace (and result-v1's engine)")
    parser.add_argument("--slope-counts", default="10,60", metavar="LOW,HIGH",
                        help="--hidden-slope: the two hidden workspace counts")
    parser.add_argument("--slope-samples", type=int, default=3, metavar="N",
                        help="--hidden-slope: footprint samples per count, all stored")
    parser.add_argument("--slope-interval", type=float, default=10, metavar="S",
                        help="--hidden-slope: seconds between the samples of one count")
    parser.add_argument("--hibernate-after", type=float, metavar="MINUTES",
                        help="launch: `browser.hibernation` minutes in the scratch config, the documented hook that "
                             "shortens the hibernation grace (default 1 with --hidden-slope)")
    parser.add_argument("--story", help="--hidden-slope: result-v1 story (default memory-hidden for chromium, "
                                        "memory-hidden-webkit for webkit)")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    parser.add_argument("--terminal-host-model", choices=("hosts", "holder"),
                        help="launch: the daemon's terminal host model (CMUX_NEXT_TUI_TERMINAL_HOST_MODEL on the app, "
                             "which its daemon launch passes on as CMUX_TUI_TERMINAL_HOST_MODEL); default hosts, the "
                             "daemon's default. --hidden-workspaces names it")
    parser.add_argument("--gpu-release", choices=("on", "off"),
                        help="launch: the debug tunable memory.discard.terminalGPURelease, in a tunables file named "
                             "by CMUX_NEXT_DEBUG_TUNABLES_FILE (hidden terminals let their GPU memory go). Needs a "
                             "bench build (reload.sh --config bench) of a .dev or .debug bundle and a GhosttyNextKit "
                             "pin with ghostty_surface_set_gpu_resident. Run off then on for the app threads per "
                             "hidden terminal before and after (p07-memory-078)")
    parser.add_argument("--thread-window", type=float, default=10, metavar="S",
                        help="--hidden-workspaces: idle seconds after each sample in which the hidden terminals' "
                             "renderer and IO threads must not wake; 0 counts threads only")
    parser.add_argument("--pressure", choices=("warning", "critical"),
                        help="pressure phase, last: set the debug pressure override (DEBUG and bench-hook builds) "
                             "and print released_mb, release_s and the managed consumers' footprint before")
    parser.add_argument("--pressure-window", type=float, default=10, metavar="S",
                        help="--pressure: seconds of footprint samples after the override")
    parser.add_argument("--kernel-pressure", choices=sorted(KERNEL_LEVELS),
                        help="after the counts, feed real kernel pressure (/usr/bin/memory_pressure -S, needs root "
                             "or passwordless sudo) and sample the footprint before, during and after")
    parser.add_argument("--kernel-pressure-window", type=float, default=5,
                        help="--kernel-pressure: seconds to sample under pressure")
    parser.add_argument("--cold-scrollback", type=int, metavar="N",
                        help="cold-scrollback run (p07-memory-112): N hidden terminals with a full scrollback each, "
                             "footprint -j dirty and compressed bytes at each --cold-idle minute, against deflate")
    parser.add_argument("--cold-scrollback-mb", type=float, default=10, metavar="MIB",
                        help="--cold-scrollback: MiB of text each terminal prints (10 fills the 10 MB scrollback-limit)")
    parser.add_argument("--cold-idle", default="0,10,30", metavar="MINUTES",
                        help="--cold-scrollback: minutes after the terminals went hidden to sample")
    parser.add_argument("--cold-codec-samples", type=int, default=5, metavar="N",
                        help="--cold-scrollback: terminals whose scrollback is read back and deflated, after the last "
                             "sample")
    parser.add_argument("--cold-pressure", type=int, default=5, metavar="PCT_FREE",
                        help="--cold-scrollback: after the idle samples, real memory pressure (memory_pressure -p, "
                             "allocating until this percent of RAM is free) until the compressor holds the cold "
                             "pages; 0 runs none and decides no-go")
    parser.add_argument("--cold-pressure-hold", type=float, default=30, metavar="S",
                        help="--cold-pressure: seconds memory_pressure holds before it exits and frees its pages")
    parser.add_argument("--out", help="the report file; with --hidden-slope a path not ending in .json is a folder for "
                                      "the result-v1 files and bench-memory.json")
    args = parser.parse_args(argv)
    return args, check_args(parser, args)


def main(argv=None):
    args, slope_counts = parse_args(argv)
    report_path, results_dir = out_paths(args.out, args.hidden_slope)
    # SIGTERM (a timeout, a scheduler) ends the run through its cleanup, as Ctrl-C does.
    signal.signal(signal.SIGTERM, interrupted)
    if sys.platform != "darwin":
        raise SystemExit("bench-memory: macOS only (run it on a fleet or capture mini)")

    bundle = os.path.realpath(args.app)
    bench = None
    if args.socket:
        if not args.app_pid:
            raise SystemExit("bench-memory: --socket needs --app-pid")
        socket_path, app_pid = args.socket, args.app_pid
        host_model = "unknown-attach"
        if args.hidden_slope and results_dir:
            # result-v1 for an attached app: its build, this host, and the features it answers now.
            bench = BenchApp(bundle, out=results_dir, teardown=False, build_config=args.build_config,
                             perf_session=args.session)
            bench.socket = socket_path
            bench.features = bench.read_features()
    else:
        host_model = args.terminal_host_model or "hosts"
        config = merged({"updates": {"checkAutomatically": False, "downloadAutomatically": False}},
                        json.loads(args.config))
        if args.hibernate_after is None and args.hidden_slope:
            args.hibernate_after = SLOPE_HIBERNATE_AFTER_MINUTES
        if args.hibernate_after is not None:
            config = merged(config, {"browser": {"hibernation": args.hibernate_after}})
        if args.cold_scrollback is not None:
            config = merged(config, cold_scrollback_config(args.cold_scrollback))
        env = launch_env(args.cef_switches, args.terminal_host_model)
        if args.gpu_release:
            env.update(gpu_release_env(args.gpu_release, results_dir or tempfile.mkdtemp(prefix="bench-memory-")))
        if args.fake_agent:
            # The fake agent is a real ACP process: the bench env's agent-pane mock and launch denial would stop it.
            env.update({"CMUX_NEXT_AGENT_PANE_MOCK": None, "ACPMUX_AGENT_LAUNCH": None})
        local_features = {BFCACHE_FEATURE: args.bfcache_flush == "on"} if args.bfcache_flush else None
        bench = BenchApp(bundle, out=results_dir, env=env, config=config, build_config=args.build_config,
                         perf_session=args.session, local_features=local_features)
        note_child_launch()
        try:
            bench.launch()
        except BaseException:
            bench.stop()
            raise
        socket_path, app_pid = bench.socket, bench.process.pid
    app = App(bundle, socket_path)
    chats = None
    recipes = args.mix.split(",")
    workspaces = args.workspaces or ("1" if args.hidden_workspaces is not None else "1,10,30")
    counts = [] if args.hidden_slope or args.cold_scrollback else sorted(int(n) for n in workspaces.split(",") if n)
    report = {"app": bundle, "mix": recipes, "settle_s": args.settle, "samples": [], "cef_switches": args.cef_switches,
              "webkit_attributed": _responsible is not None,
              "webkit_attribution": "app-responsible" if _foreign_webkit is None else "app-or-its-launcher"}
    opened = []

    def settle_and_sample(label):
        time.sleep(args.settle)  # test script: let the app and its helpers go idle
        result = sample(app_pid, bundle, label, len(opened) + 1, args.measure)
        report["samples"].append(result)
        print_sample(result, args.top)
        return result

    try:
        if args.fake_agent:
            chats = FakeChats(app, bundle, args.fake_agent)
        settle_and_sample("idle-launch")
        if args.tabs:
            tab_counts = sorted(int(n) for n in args.tabs.split(",") if n)
            visits: set = set()
            urls = tab_urls(args.urls, max(tab_counts), args.navigate or 0, visits)
            report["tabs"] = tab_counts
            report["urls"] = args.urls
            made = 0
            for count in tab_counts:
                while made < count and open_browser_tab(app, urls[made]):
                    made += 1
                result = settle_and_sample(f"tabs-{made}")
                result["tabs"] = made
            counts = []
            if args.navigate is not None:
                def hide():
                    workspace = open_workspace(app, "terminal", args.url, len(opened), chats)
                    if workspace is not None:
                        opened.append(workspace)
                    return workspace

                report["navigate"] = navigate_phase(app, args.navigate, made, visits, hide, settle_and_sample,
                                                    args.navigate_freeze_wait, args.navigate_window)
        launch_threads = thread_times(app_pid) if counts else None
        launch_memory = MemoryReport.read(app) if counts else None
        launch_surfaces = launch_memory.terminal_surfaces() if launch_memory else None
        for count in counts:
            # The launch workspace counts as the first one.
            while len(opened) + 1 < count:
                workspace = open_workspace(app, recipes[len(opened) % len(recipes)], args.url, len(opened), chats)
                if workspace is None:
                    break
                opened.append(workspace)
            result = settle_and_sample(f"idle-{count}")
            memory = MemoryReport.read(app)
            surfaces = memory.terminal_surfaces() if memory else None
            added = surfaces - launch_surfaces if surfaces is not None and launch_surfaces is not None else None
            result["terminal_threads"] = terminal_threads(launch_threads, thread_times(app_pid), added)
            print_terminal_threads(f"at {count} workspaces", result["terminal_threads"],
                                   memory.gpu_release() if memory else None)
        report["debug_memory"] = MemoryReport.read(app) is not None
        if not report["debug_memory"] and (args.hidden_workspaces is not None or args.pressure):
            print("bench-memory: this build has no debug.memory; the phases report process footprint only")
        if args.hidden_workspaces is not None:
            report["hidden_workspaces"] = hidden_workspaces_phase(app, args.hidden_workspaces, args.grace, recipes,
                                                                  args.url, opened, chats, settle_and_sample,
                                                                  host_model, lambda: thread_times(app_pid),
                                                                  args.thread_window)
        if args.cold_scrollback is not None:
            if args.socket and args.cold_scrollback * cold_scrollback.SCROLLBACK_LIMIT_BYTES > 256 * MB:
                print("bench-memory: an attached app keeps its own terminal.scrollback.maxTotalMemoryBytes "
                      "(default 256 MiB); past it the daemon trims the least recently active terminals", flush=True)
            env = ColdScrollbackEnv(app, app_pid, bundle, args.url, opened)
            report["cold_scrollback"] = cold_scrollback.cold_scrollback_phase(
                env, args.cold_scrollback, int(args.cold_scrollback_mb * MB), args.cold_idle_minutes,
                args.cold_codec_samples, pressure=args.cold_pressure, pressure_hold_s=args.cold_pressure_hold)
        if args.hidden_slope:
            report["hidden_slope"] = run_hidden_slope(app, args, slope_counts, opened, chats, app_pid, bundle,
                                                      report, bench, results_dir)
        if args.kernel_pressure:
            report["kernel_pressure"] = kernel_pressure(app_pid, bundle, args.kernel_pressure,
                                                        args.kernel_pressure_window, len(opened) + 1, args.top)
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
        if args.pressure:
            # Last: a lossy release (discarded pages, torn-down workspaces) changes what any later phase measures.
            report["pressure"] = pressure_phase(app, app_pid, args.pressure, args.pressure_window, 0.1,
                                                settle_and_sample)
    finally:
        if args.socket:
            # Someone else's app: leave it as it was. A launched app ends whole with its tag below.
            for workspace in opened:
                close_workspace(app, workspace)
        elif bench is not None:
            bench.stop()
        if report_path:
            with open(report_path, "w") as handle:
                json.dump(report, handle, indent=2)
            print(f"bench-memory: wrote {report_path}")
    failure = slope_failure(report.get("hidden_slope")) if args.hidden_slope else None
    if failure:
        raise SystemExit(f"bench-memory: --hidden-slope is not a result: {failure}")


if __name__ == "__main__":
    main()
