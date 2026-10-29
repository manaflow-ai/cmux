"""Per-process counters for xbench.py and idle-budget.py: energy, CPU, wakeups, GPU and memory with no root.

`proc_pid_rusage(RUSAGE_INFO_V6)` gives, per process (`Usage`; word index in `rusage_info_v6`):
  ri_energy_nj           (42) the process's own CPU energy: energy_mw_cpu (the `mw` rows)
  ri_billed_energy       (33) energy other processes spent on this one's behalf (vouchers: WindowServer,
                              the render server), nJ
  ri_serviced_energy     (34) energy this process spent on behalf of others, nJ.
                              energy_mw_billed = cpu + billed - serviced: work moved to another process
                              still counts against the process it was done for
  ri_user/system         (2, 3) CPU time in mach ticks: CPU %
  ri_interrupt_wkups     (5) interrupt wakeups: `wakeups_per_s`, the judged number (Chrome's
                              ProcessMetrics::GetIdleWakeupsPerSecond, Activity Monitor's Idle Wake Ups)
  ri_pkg_idle_wkups      (4) package-idle wakeups, a subset of the interrupt wakeups:
                              `pkg_idle_wakeups_per_s` (ProcessMetrics::GetPackageIdleWakeupsPerSecond).
                              Chrome reports the two apart (base/process/process_metrics_apple.mm); their
                              sum counted every package-idle wakeup twice.
  ri_phys_footprint      (9) what Activity Monitor calls Memory
  ri_diskio_byteswritten (19) bytes the process wrote to disk (the disk-write rows)

`power_assertions` reads `pmset -g assertions` for a pid set and `thermal_state` the Mac's thermal state
(idle-budget.py records both per window).

Readers that run outside the measured processes (no wakeup of theirs): nettop (bytes and connections per
process: `nettop_command`, `parse_nettop`), `log show` (unified-log lines per process: `read_log`, `parse_log`)
and top's IDLEW of another user's process (`top_idlew`: WindowServer without root).

`proc_pidinfo(PROC_PIDTASKINFO)` adds the overhead counters of speed-of-sound-DESIGN.md:
threads, Mach messages sent + received (IPC), Unix + Mach syscalls and context switches.

`priorities()` reads each process's scheduling role for idle-budget.py's role audit (p14-energy-106): the task's
base priority (`proc_pidinfo(PROC_PIDTASKINFO)` pti_priority) and the kernel's darwinbg bit and nice
(`proc_pidinfo(PROC_PIDTBSDINFO)` pbi_flags, the bit `taskinfo` prints, and pbi_nice). Neither read wakes the
process. `ps -o pri` is not used: it prints the highest priority of the process's threads (adv_cmds ps, ki->curpri),
which follows thread QoS and boosts, not the task's role.

GPU time per process is the IORegistry's `accumulatedGPUTime` of each GPU user client (what Activity
Monitor's GPU Time column reads): `gpu_ms_per_s`, None when the registry cannot be read.

The app's resource coalition (`coalition_info_resource_usage`, read as
components/power_metrics/resource_coalition_mac.mm reads it) gives energy, energy_billed_to_me,
energy_billed_to_others, gpu_time and both wakeup counts of everything the app started, gone processes
included. A coalition that cannot be read is None, never zeros.

An instance is every process of one browser run: the main pid's descendants,
every process whose executable lies inside the bundle (helpers, crashpad,
cmux daemons and terminal hosts, which outlive their parents), every
process macOS counts the main pid responsible for (Safari's and cmux's
WebKit XPC processes), the Computer Use helper started with `--owner-pid <main pid>`,
and every descendant of one of its acpmux agent hosts
(`__agent-host`, pooled ones included: the harness and its tools run from
outside the bundle, under a host that detached from its daemon). Those
descendants are kind `agent-harness` (`agent_harness_pids`).

The libraries load on first use, so the pure parts (`usage_from_words`, `rates`, `gpu_ns_from_registry`,
`coalition_from_words`, `coalition_rates`, `window_totals`, `priorities` with its reads passed) import and test on any OS.
"""
from __future__ import annotations

import csv
import ctypes
import datetime
import json
import math
import os
import plistlib
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from functools import cache

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-next"))
from tab_pages import process_table, process_type_kind  # noqa: E402,F401  (the one `ps` reader and --type classifier)


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


@dataclass(frozen=True)
class _Darwin:
    libproc: ctypes.CDLL
    responsible: object  # responsibility_get_pid_responsible_for_pid, or None
    coalition_usage: object  # coalition_info_resource_usage, or None
    numer: int
    denom: int


@cache
def _darwin() -> _Darwin:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    responsible = getattr(libsystem, "responsibility_get_pid_responsible_for_pid", None)
    if responsible is not None:
        responsible.restype = ctypes.c_int
        responsible.argtypes = [ctypes.c_int]
    coalition_usage = getattr(libsystem, "coalition_info_resource_usage", None)
    if coalition_usage is not None:
        coalition_usage.restype = ctypes.c_int
        coalition_usage.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
    timebase = _Timebase()
    libsystem.mach_timebase_info(ctypes.byref(timebase))
    return _Darwin(libproc, responsible, coalition_usage, timebase.numer, timebase.denom)


MB = 1048576.0

# rusage_info_v6 word indexes (sys/resource.h; words 0-1 are ri_uuid).
_RI_USER, _RI_SYSTEM, _RI_PKG_IDLE, _RI_INTERRUPT, _RI_FOOTPRINT, _RI_DISK_WRITTEN = 2, 3, 4, 5, 9, 19
_RI_BILLED_ENERGY, _RI_SERVICED_ENERGY, _RI_ENERGY_NJ = 33, 34, 42


@dataclass(frozen=True)
class Usage:
    """One `proc_pid_rusage(RUSAGE_INFO_V6)` read; every field is cumulative except `footprint`."""
    energy_nj: int = 0
    cpu_ns: int = 0
    interrupt_wakeups: int = 0
    pkg_idle_wakeups: int = 0
    footprint: int = 0
    billed_energy_nj: int = 0
    serviced_energy_nj: int = 0


def usage_from_words(words, numer: int, denom: int) -> Usage:
    """A `Usage` from the words of an `rusage_info_v6` and the mach timebase."""
    return Usage(energy_nj=words[_RI_ENERGY_NJ],
                 cpu_ns=(words[_RI_USER] + words[_RI_SYSTEM]) * numer // denom,
                 interrupt_wakeups=words[_RI_INTERRUPT],
                 pkg_idle_wakeups=words[_RI_PKG_IDLE],
                 footprint=words[_RI_FOOTPRINT],
                 billed_energy_nj=words[_RI_BILLED_ENERGY],
                 serviced_energy_nj=words[_RI_SERVICED_ENERGY])


def _rusage_words(pid: int):
    buf = (ctypes.c_uint64 * 64)()
    if _darwin().libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    return buf


def usage(pid: int) -> Usage | None:
    """The process's rusage counters, or None once the pid is gone."""
    words = _rusage_words(pid)
    if words is None:
        return None
    darwin = _darwin()
    return usage_from_words(words, darwin.numer, darwin.denom)


def counters(pid: int):
    """(energy nJ, cpu ns, interrupt wakeups, footprint bytes), or None once the pid is gone."""
    got = usage(pid)
    return None if got is None else (got.energy_nj, got.cpu_ns, got.interrupt_wakeups, got.footprint)


def rates(first: Usage | None, last: Usage, elapsed: float) -> dict:
    """Per-second rates of one process between two reads (one that started inside the window counts from
    zero): wakeups_per_s (interrupt wakeups, the judged number), pkg_idle_wakeups_per_s, energy_mw_cpu,
    energy_mw_billed and cpu_pct."""
    first = first or Usage()
    cpu = last.energy_nj - first.energy_nj
    billed = cpu + (last.billed_energy_nj - first.billed_energy_nj) - (last.serviced_energy_nj - first.serviced_energy_nj)
    return {"wakeups_per_s": (last.interrupt_wakeups - first.interrupt_wakeups) / elapsed,
            "pkg_idle_wakeups_per_s": (last.pkg_idle_wakeups - first.pkg_idle_wakeups) / elapsed,
            "energy_mw_cpu": cpu / 1e6 / elapsed,
            "energy_mw_billed": billed / 1e6 / elapsed,
            "cpu_pct": 100 * (last.cpu_ns - first.cpu_ns) / 1e9 / elapsed}


# ---------------------------------------------------------------- GPU time per process (IORegistry)


def gpu_ns_from_registry(entries) -> dict[int, int]:
    """{pid: accumulated GPU ns} from `ioreg -a -l -r -c IOAccelerator` (a plist list of registry entries
    with their children): each GPU user client names its creator (`IOUserClientCreator` = "pid N, name")
    and its `AppUsage` entries carry `accumulatedGPUTime` in ns."""
    found: dict[int, int] = {}
    stack = list(entries) if isinstance(entries, list) else [entries]
    while stack:
        entry = stack.pop()
        if not isinstance(entry, dict):
            continue
        stack.extend(entry.get("IORegistryEntryChildren") or [])
        creator = re.match(r"pid (\d+)", str(entry.get("IOUserClientCreator") or ""))
        app_usage = entry.get("AppUsage")
        if creator and isinstance(app_usage, list):
            gpu = sum(item.get("accumulatedGPUTime", 0) for item in app_usage if isinstance(item, dict))
            pid = int(creator.group(1))
            found[pid] = found.get(pid, 0) + gpu
    return found


def gpu_ns_by_pid() -> dict[int, int] | None:
    """{pid: accumulated GPU ns} of every process with a GPU client now, or None when the IORegistry
    cannot be read. A process with no GPU client has used no GPU (absent: 0)."""
    try:
        out = subprocess.run(["ioreg", "-a", "-l", "-r", "-c", "IOAccelerator"], capture_output=True,
                             timeout=30).stdout
        return gpu_ns_from_registry(plistlib.loads(out)) if out else None
    except (OSError, subprocess.TimeoutExpired, plistlib.InvalidFileException, ValueError):
        return None


def gpu_ms_per_s(first: dict[int, int] | None, last: dict[int, int] | None, pid: int, elapsed: float) -> float | None:
    """The process's GPU ms per second between two `gpu_ns_by_pid` reads; None when either read failed."""
    if first is None or last is None:
        return None
    return max(0, last.get(pid, 0) - first.get(pid, 0)) / 1e6 / elapsed


# ---------------------------------------------------------------- resource coalitions

_PROC_PIDCOALITIONINFO = 20
_COALITION_TYPE_RESOURCE = 0
# struct coalition_resource_usage (mach/coalition.h) word indexes.
_CRU_CPU_TIME, _CRU_INTERRUPT, _CRU_PLATFORM_IDLE, _CRU_GPU_TIME, _CRU_ENERGY = 3, 4, 5, 8, 11
_CRU_BILLED_TO_ME, _CRU_BILLED_TO_OTHERS = 20, 21
# The struct through cpu_time_eqos[7] (macOS 11+); the kernel copies at most the size it is given.
_CRU_WORDS = 31


@dataclass(frozen=True)
class CoalitionUsage:
    """One `coalition_info_resource_usage` read; every field is cumulative."""
    energy_nj: int
    energy_billed_to_me_nj: int
    energy_billed_to_others_nj: int
    gpu_ns: int
    cpu_ns: int
    interrupt_wakeups: int
    platform_idle_wakeups: int


def coalition_from_words(words, numer: int, denom: int) -> CoalitionUsage:
    """A `CoalitionUsage` from the words of a `coalition_resource_usage`. cpu_time is mach time (converted
    with the timebase, as resource_coalition_mac.mm does); gpu_time is ns (XNU sums task_gpu_ns); the
    energies are nJ."""
    return CoalitionUsage(energy_nj=words[_CRU_ENERGY],
                          energy_billed_to_me_nj=words[_CRU_BILLED_TO_ME],
                          energy_billed_to_others_nj=words[_CRU_BILLED_TO_OTHERS],
                          gpu_ns=words[_CRU_GPU_TIME],
                          cpu_ns=words[_CRU_CPU_TIME] * numer // denom,
                          interrupt_wakeups=words[_CRU_INTERRUPT],
                          platform_idle_wakeups=words[_CRU_PLATFORM_IDLE])


class _CoalitionInfo(ctypes.Structure):
    _fields_ = [("coalition_id", ctypes.c_uint64 * 2), ("reserved", ctypes.c_uint64 * 3)]


def coalition_id(pid: int) -> int | None:
    """The process's resource coalition id, or None when it cannot be read."""
    info = _CoalitionInfo()
    size = ctypes.sizeof(info)
    if _darwin().libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDCOALITIONINFO), ctypes.c_uint64(0),
                                      ctypes.byref(info), ctypes.c_int(size)) != size:
        return None
    return info.coalition_id[_COALITION_TYPE_RESOURCE] or None


def coalition_usage(cid: int) -> CoalitionUsage | None:
    """The resource coalition's counters, or None when the read fails (never zeros)."""
    darwin = _darwin()
    if darwin.coalition_usage is None:
        return None
    words = (ctypes.c_uint64 * _CRU_WORDS)()
    if darwin.coalition_usage(ctypes.c_uint64(cid), ctypes.byref(words), ctypes.c_size_t(ctypes.sizeof(words))) != 0:
        return None
    return coalition_from_words(words, darwin.numer, darwin.denom)


def coalition_of(pid: int) -> CoalitionUsage | None:
    """The counters of the resource coalition `pid` belongs to (an app launched by LaunchServices leads its
    own: its helpers, XPC services and daemons are in it), or None when either read fails."""
    cid = coalition_id(pid)
    return None if cid is None else coalition_usage(cid)


def coalition_rates(first: CoalitionUsage | None, last: CoalitionUsage | None, elapsed: float) -> dict | None:
    """Per-second rates of one coalition between two reads, None when either read failed. energy_mw_billed
    is energy + billed to me - billed to others."""
    if first is None or last is None:
        return None
    energy = last.energy_nj - first.energy_nj
    billed = (energy + (last.energy_billed_to_me_nj - first.energy_billed_to_me_nj)
              - (last.energy_billed_to_others_nj - first.energy_billed_to_others_nj))
    return {"energy_mw_cpu": round(energy / 1e6 / elapsed, 3),
            "energy_mw_billed": round(billed / 1e6 / elapsed, 3),
            "gpu_ms_per_s": round((last.gpu_ns - first.gpu_ns) / 1e6 / elapsed, 3),
            "cpu_pct": round(100 * (last.cpu_ns - first.cpu_ns) / 1e9 / elapsed, 3),
            "wakeups_per_s": round((last.interrupt_wakeups - first.interrupt_wakeups) / elapsed, 3),
            "pkg_idle_wakeups_per_s": round((last.platform_idle_wakeups - first.platform_idle_wakeups) / elapsed, 3)}


class _TaskInfo(ctypes.Structure):
    _fields_ = [("virtual_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64),
                ("total_user", ctypes.c_uint64), ("total_system", ctypes.c_uint64),
                ("threads_user", ctypes.c_uint64), ("threads_system", ctypes.c_uint64),
                ("policy", ctypes.c_int32), ("faults", ctypes.c_int32), ("pageins", ctypes.c_int32),
                ("cow_faults", ctypes.c_int32), ("messages_sent", ctypes.c_int32),
                ("messages_received", ctypes.c_int32), ("syscalls_mach", ctypes.c_int32),
                ("syscalls_unix", ctypes.c_int32), ("csw", ctypes.c_int32), ("threadnum", ctypes.c_int32),
                ("numrunning", ctypes.c_int32), ("priority", ctypes.c_int32)]


_PROC_PIDTASKINFO = 4


def overhead(pid: int):
    """(disk bytes written, threads, Mach messages, syscalls, context switches), or None once gone.

    The message, syscall and switch counters are cumulative 32-bit counts: diff two reads."""
    words = _rusage_words(pid)
    if words is None:
        return None
    written = words[_RI_DISK_WRITTEN]
    info = _TaskInfo()
    size = ctypes.sizeof(info)
    if _darwin().libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTASKINFO), ctypes.c_uint64(0),
                                      ctypes.byref(info), ctypes.c_int(size)) != size:
        return written, 0, 0, 0, 0
    return (written, info.threadnum, (info.messages_sent + info.messages_received) & 0xFFFFFFFF,
            (info.syscalls_mach + info.syscalls_unix) & 0xFFFFFFFF, info.csw & 0xFFFFFFFF)


class _BSDInfo(ctypes.Structure):
    """`struct proc_bsdinfo` (sys/proc_info.h), read with PROC_PIDTBSDINFO: same user, no root."""
    _fields_ = [("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32), ("pbi_xstatus", ctypes.c_uint32),
                ("pbi_pid", ctypes.c_uint32), ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
                ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32), ("pbi_rgid", ctypes.c_uint32),
                ("pbi_svuid", ctypes.c_uint32), ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
                ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32), ("pbi_nfiles", ctypes.c_uint32),
                ("pbi_pgid", ctypes.c_uint32), ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
                ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32), ("pbi_start_tvsec", ctypes.c_uint64),
                ("pbi_start_tvusec", ctypes.c_uint64)]


_PROC_PIDTBSDINFO = 3
# sys/proc_info.h: the task runs darwin background now (PRIO_DARWIN_BG, a darwinbg role or a background QoS
# ceiling: what `taskinfo` prints as darwinbg), and the part another process set on it.
PROC_FLAG_DARWINBG = 0x8000
PROC_FLAG_EXT_DARWINBG = 0x10000


def bsd_state(pid: int):
    """(darwinbg, nice) of `pid` now: whether the kernel runs it darwin background (pbi_flags) and its nice value
    (pbi_nice); None when it cannot be read (gone, not macOS)."""
    try:
        libproc = _darwin().libproc
    except OSError:
        return None
    info = _BSDInfo()
    size = ctypes.sizeof(info)
    if libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTBSDINFO), ctypes.c_uint64(0),
                            ctypes.byref(info), ctypes.c_int(size)) != size:
        return None
    return bool(info.pbi_flags & (PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG)), info.pbi_nice


def task_priority(pid: int) -> int | None:
    """The task's base priority (proc_pidinfo PROC_PIDTASKINFO pti_priority, bsd/kern/proc_info.c fill_taskprocinfo:
    task->priority), the priority task_policy gives the task as a whole, not its busiest thread's; None when it
    cannot be read."""
    try:
        libproc = _darwin().libproc
    except OSError:
        return None
    info = _TaskInfo()
    size = ctypes.sizeof(info)
    if libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTASKINFO), ctypes.c_uint64(0),
                            ctypes.byref(info), ctypes.c_int(size)) != size:
        return None
    return info.priority


def priorities(pids, task_priority_of=task_priority, bsd_state_of=bsd_state) -> dict[int, dict]:
    """{pid: {base, nice, darwinbg}} of `pids` now: the task's base priority (task_priority) and its darwinbg bit
    and nice (bsd_state). A pid with neither read (gone) is left out; one unread value is None. Tests pass the
    reads."""
    found = {}
    for pid in pids:
        base = task_priority_of(pid)
        bsd = bsd_state_of(pid)
        if base is None and bsd is None:
            continue
        found[pid] = {"base": base, "darwinbg": bsd[0] if bsd else None, "nice": bsd[1] if bsd else None}
    return found


# rusage_info_v6 words 20-26 (sys/resource.h, since v3): CPU time per effective QoS class, in mach ticks.
QOS_CLASSES = ("default", "maintenance", "background", "utility", "legacy", "user_initiated", "user_interactive")


def qos_cpu_ns(pid: int) -> dict[str, int] | None:
    """CPU ns `pid` ran at each QoS class since it started, or None once it is gone (or off macOS).

    Diff two reads for a window: the split says which QoS the process really ran at."""
    try:
        darwin = _darwin()
    except OSError:
        return None
    words = _rusage_words(pid)
    if words is None:
        return None
    return {name: words[20 + index] * darwin.numer // darwin.denom for index, name in enumerate(QOS_CLASSES)}


class _ThreadInfo(ctypes.Structure):
    """`struct proc_threadinfo` (sys/proc_info.h), read with PROC_PIDTHREADINFO: same user, no root."""
    _fields_ = [("pth_user_time", ctypes.c_uint64), ("pth_system_time", ctypes.c_uint64),
                ("pth_cpu_usage", ctypes.c_int32), ("pth_policy", ctypes.c_int32), ("pth_run_state", ctypes.c_int32),
                ("pth_flags", ctypes.c_int32), ("pth_sleep_time", ctypes.c_int32), ("pth_curpri", ctypes.c_int32),
                ("pth_priority", ctypes.c_int32), ("pth_maxpriority", ctypes.c_int32), ("pth_name", ctypes.c_char * 64)]


_PROC_PIDTHREADINFO = 5
_PROC_PIDLISTTHREADS = 6
_MAX_THREADS = 2048
# osfmk/kern/sched.h. task_policy_update_internal_locked caps every thread of a task with low-priority CPU or
# darwin background at MAXPRI_THROTTLE and a suppressed one at MAXPRI_SUPPRESSED; the task role sets the base
# priority (TASK_FOREGROUND_APPLICATION 47, TASK_BACKGROUND_APPLICATION 46).
MAXPRI_THROTTLE = 4
MAXPRI_SUPPRESSED = 28
BASEPRI_BACKGROUND = 46
BASEPRI_FOREGROUND = 47


def thread_priorities(pid: int) -> list[tuple[int, int]] | None:
    """(base priority, priority ceiling) of each thread of `pid`, main thread first; None when unreadable.

    proc_pidinfo only: it needs no task port and does not wake the process."""
    try:
        libproc = _darwin().libproc
    except OSError:
        return None
    handles = (ctypes.c_uint64 * _MAX_THREADS)()
    got = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDLISTTHREADS), ctypes.c_uint64(0),
                               ctypes.byref(handles), ctypes.c_int(ctypes.sizeof(handles)))
    if got <= 0:
        return None
    info = _ThreadInfo()
    size = ctypes.sizeof(info)
    found = []
    for handle in handles[:got // 8]:
        if libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTHREADINFO), ctypes.c_uint64(handle),
                                ctypes.byref(info), ctypes.c_int(size)) == size:
            found.append((info.pth_priority, info.pth_maxpriority))
    return found or None


BACKGROUNDED_ROLES = frozenset({"throttled", "suppressed"})


def role_of(threads: list[tuple[int, int]] | None) -> str:
    """The scheduling role a `thread_priorities` list shows.

    `throttled`: every thread capped at MAXPRI_THROTTLE (low-priority CPU or darwin background; Chrome's kBestEffort,
    base/process/process_mac.cc SetTaskSuppressionPolicy with lowpri_cpu). `suppressed`: capped at MAXPRI_SUPPRESSED
    (App Nap). Otherwise the main thread's base priority: `foreground` (47 and up: TASK_FOREGROUND_APPLICATION,
    Chrome's kUserBlocking, or a user-interactive main thread), `background-role` (46: TASK_BACKGROUND_APPLICATION
    without suppression, Chrome's kUserVisible) or `default`. `unknown` when unreadable. Only the first two are
    backgrounded (BACKGROUNDED_ROLES)."""
    if not threads:
        return "unknown"
    ceiling = max(cap for _base, cap in threads)
    if ceiling <= MAXPRI_THROTTLE:
        return "throttled"
    if ceiling <= MAXPRI_SUPPRESSED:
        return "suppressed"
    main = threads[0][0]
    if main >= BASEPRI_FOREGROUND:
        return "foreground"
    if main == BASEPRI_BACKGROUND:
        return "background-role"
    return "default"


def _delta32(last: int, first: int) -> int:
    return (last - first) & 0xFFFFFFFF


def resident_mb() -> dict[int, float]:
    """RSS in MB per pid, from one `ps` call (phys_footprint is the budgeted number; RSS is context)."""
    out = subprocess.run(["ps", "-axo", "pid=,rss="], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            found[int(parts[0])] = round(int(parts[1]) / 1024, 1)
    return found


def _roots(bundle: str) -> tuple[str, ...]:
    real = os.path.realpath(bundle)
    return tuple({real + "/", real.removeprefix("/private") + "/", bundle.rstrip("/") + "/"})


def main_pid(bundle: str) -> int | None:
    """The app process of `bundle` (its Contents/MacOS binary), or None."""
    macos = tuple(root + "Contents/MacOS/" for root in _roots(bundle))
    pids = [pid for pid, _ppid, cmd in process_table() if cmd.startswith(macos)]
    return min(pids) if pids else None


# The Computer Use helper app (CuaHelperIdentity.appName), in a cmux bundle's Contents/Library or on its own.
CUA_HELPER_APP = "/cmux Computer Use.app/Contents/MacOS/"
# The crash watcher (CrashWatcher.swift): `zsh -f -c <script> cmux-crash-watcher <pid> <sample file> <seconds>`.
CRASH_WATCHER = re.compile(r"^/bin/zsh -f -c .* cmux-crash-watcher \d+ ", re.S)
# The standalone terminal holder's argv[0] (cmux-tui-platform host_exe.rs HOLDER_NAME); the built-in one runs as
# `<host executable> __holder`.
HOLDER_NAME = "cmux-holder"


def is_holder(cmd: str) -> bool:
    """Whether `cmd` is a terminal holder: the built-in (`__holder`) or the standalone `cmux-holder`."""
    return "__holder" in cmd or os.path.basename(cmd.split(" --", 1)[0].strip()) == HOLDER_NAME


class ProcessTree:
    """The parents and commands of one `ps` table ([(pid, ppid, command)], process_table): what a process's
    ancestry tells that its command line cannot (a terminal's job, an agent's harness)."""

    def __init__(self, table):
        self.parent = {pid: ppid for pid, ppid, _cmd in table}
        self.command = {pid: cmd for pid, _ppid, cmd in table}

    def ancestors(self, pid: int) -> list[tuple[int, str]]:
        """[(pid, command)] of `pid`'s parents, nearest first, up to launchd; a parent not in the table ends it."""
        out, seen = [], {pid}
        parent = self.parent.get(pid)
        while parent and parent not in seen and parent in self.command:
            out.append((parent, self.command[parent]))
            seen.add(parent)
            parent = self.parent.get(parent)
        return out


# The word acpmux starts an agent host with (cmux-tui/crates/acpmux/src/agent_host/mod.rs HOST_ARG): one host per
# agent session and per pooled entry (`hosts/pool/`), the harness its child.
AGENT_HOST_ARG = "__agent-host"
AGENT_HARNESS = "agent-harness"


def is_agent_host(cmd: str) -> bool:
    """Whether `cmd` is an acpmux agent host (`acpmux __agent-host`, or `cmux acp __agent-host` in the multicall
    binary)."""
    return AGENT_HOST_ARG in cmd.split()


def agent_harness_pids(table) -> dict[int, int]:
    """{pid: host pid} of every descendant of an agent host in `table` ([(pid, ppid, command)], process_table): the
    harness and whatever it runs, under its nearest host. A host is never a harness."""
    children: dict[int, list[int]] = {}
    hosts = []
    for pid, ppid, cmd in table:
        children.setdefault(ppid, []).append(pid)
        if is_agent_host(cmd):
            hosts.append(pid)
    host_set = set(hosts)
    found: dict[int, int] = {}
    for host in hosts:
        stack = list(children.get(host, []))
        while stack:
            pid = stack.pop()
            if pid in host_set or pid in found:
                continue  # a host under a host is its own; a racy table's cycle ends here
            found[pid] = host
            stack.extend(children.get(pid, []))
    return found


def kind_of(cmd: str) -> str:
    """A short process kind for the per-kind breakdown (xbench's names for the tab_pages.process_type_kind kinds)."""
    chromium = process_type_kind(cmd)
    if chromium in ("cef-renderer", "cef-extension"):
        return "renderer"
    if chromium == "cef-gpu":
        return "gpu"
    if chromium == "cef-utility":
        match = re.search(r"--utility-sub-type=(\S+)", cmd)
        return "utility:" + (match.group(1).rsplit(".", 1)[-1] if match else "?")
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    if "__terminal-host" in cmd:
        return "terminal-host"
    if "/bin/cmux-tui" in cmd:
        return "cmux-tui"
    if "/bin/acpmux" in cmd:
        return "acpmux"
    if CUA_HELPER_APP in cmd.split(" --", 1)[0]:
        return "cua-helper"
    if CRASH_WATCHER.search(cmd):
        return "crash-watcher"
    exe = cmd.split(" --", 1)[0].split(" -")[0]
    if " Helper" in exe:
        return "helper"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "main"
    return os.path.basename(exe)[:40]


WINDOW_RATES = ("mw", "energy_mw_cpu", "energy_mw_billed", "gpu_ms_per_s", "cpu_pct", "wakeups_per_s",
                "pkg_idle_wakeups_per_s", "disk_kb_per_s", "mach_msgs_per_s", "syscalls_per_s", "csw_per_s")


def _add(total, value):
    return None if total is None or value is None else total + value


def window_totals(rows: list[dict]) -> dict:
    """The instance's sums and per-kind sums (`n`, `threads` and every `WINDOW_RATES` key) of per-process
    window rows. A rate one process could not report (GPU time with no IORegistry read) makes its kind's and
    the instance's sum None: an unknown is never a 0."""
    totals: dict = {key: 0.0 for key in WINDOW_RATES}
    kinds: dict[str, dict] = {}
    threads = 0
    for row in rows:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, **{key: 0.0 for key in WINDOW_RATES}})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        threads += row["threads"]
        for key in WINDOW_RATES:
            entry[key] = _add(entry[key], row.get(key))
            totals[key] = _add(totals[key], row.get(key))
    rounded = {key: None if value is None else round(value, 3) for key, value in totals.items()}
    rounded["threads"] = threads
    rounded["processes"] = len(rows)
    rounded["kinds"] = {name: {key: round(value, 3) if isinstance(value, float) else value for key, value in entry.items()}
                        for name, entry in sorted(kinds.items(), key=lambda kv: -kv[1]["mw"])}
    return rounded


class Instance:
    """The process set of one browser run, re-read on every sample."""

    def __init__(self, bundle: str, pid: int):
        self.bundle = bundle
        self.pid = pid
        self.roots = _roots(bundle)
        self.seen: set[int] = set()
        self.harness: dict[int, int] = {}  # the last pids() read's agent harness processes: {pid: host pid}

    def pids(self, table: list[tuple[int, int, str]] | None = None) -> dict[int, str]:
        """{pid: command} of the instance in `table` (process_table rows; read now when None)."""
        table = process_table() if table is None else table
        children: dict[int, list[int]] = {}
        commands = {}
        for pid, ppid, cmd in table:
            children.setdefault(ppid, []).append(pid)
            commands[pid] = cmd
        responsible = _darwin().responsible
        found = set()
        stack = [self.pid]
        while stack:  # descendants of the app
            pid = stack.pop()
            if pid in commands and pid not in found:
                found.add(pid)
                stack.extend(children.get(pid, []))
        for pid, cmd in commands.items():
            if cmd.startswith(self.roots):
                found.add(pid)
            elif responsible is not None and pid != self.pid and responsible(pid) == self.pid:
                found.add(pid)
        # Terminal hosts and holders name their daemon (`--owner ...@<pid>`) and run from outside the bundle; the
        # Computer Use helper names the app (`--owner-pid <pid>`), disclaims its responsibility and may run from
        # another cmux.
        for pid, cmd in commands.items():
            owner = re.search(r"--owner \S+@(\d+)", cmd) if "__terminal-host" in cmd or is_holder(cmd) else None
            if owner and int(owner.group(1)) in found:
                found.add(pid)
            if CUA_HELPER_APP in cmd and re.search(rf"--owner-pid {self.pid}(\s|$)", cmd):
                found.add(pid)
        # Agent harnesses run from outside the bundle, under a host that is the instance's.
        self.harness = {pid: host for pid, host in agent_harness_pids(table).items() if host in found}
        found |= set(self.harness)
        self.seen |= found
        return {pid: commands[pid] for pid in found}

    def kind(self, pid: int, cmd: str) -> str:
        """`kind_of`, with the last pids() read's agent harness processes as `agent-harness`."""
        return AGENT_HARNESS if pid in self.harness else kind_of(cmd)

    def memory(self, per_pid: bool = False) -> dict:
        """Physical footprint now: total MB, process count and MB per kind (and per process with
        `per_pid`: pid, kind, command, footprint MB, RSS MB)."""
        kinds: dict[str, float] = {}
        total = 0.0
        count = 0
        rows = []
        rss = resident_mb() if per_pid else {}
        for pid, cmd in self.pids().items():
            got = counters(pid)
            if got is None:
                continue
            mb = got[3] / MB
            total += mb
            count += 1
            name = self.kind(pid, cmd)
            kinds[name] = kinds.get(name, 0.0) + mb
            if per_pid:
                rows.append({"pid": pid, "kind": name, "command": cmd[:160], "footprint_mb": round(mb, 1),
                             "rss_mb": rss.get(pid)})
        result = {"mb": round(total, 1), "processes": count,
                  "kinds": {k: round(v, 1) for k, v in sorted(kinds.items(), key=lambda kv: -kv[1])}}
        if per_pid:
            result["pids"] = sorted(rows, key=lambda row: -row["footprint_mb"])
        return result

    def window(self, seconds: float, during=None, per_pid: bool = False) -> dict:
        """Energy (CPU and billed mW), GPU ms/s, CPU % (of one core), interrupt and package-idle wakeups/s
        and the overhead rates over `seconds`, summed over the instance and per kind (and per process with
        `per_pid`), plus the app's resource coalition (`coalition`, None when unreadable). `mw` is
        `energy_mw_cpu` (the rows measured before billed energy existed).

        A process that starts inside the window counts from its start; one that
        ends inside it is lost (its last counters cannot be read)."""
        start = {pid: (usage(pid), overhead(pid), cmd) for pid, cmd in self.pids().items()}
        gpu_first = gpu_ns_by_pid()
        coalition_first = coalition_of(self.pid)
        began = time.monotonic()
        if during:
            during(seconds)
        else:
            time.sleep(seconds)  # bench: the measured window
        elapsed = time.monotonic() - began
        coalition_last = coalition_of(self.pid)
        gpu_last = gpu_ns_by_pid()
        rows = []
        for pid, cmd in self.pids().items():
            last = usage(pid)
            last_overhead = overhead(pid)
            if last is None or last_overhead is None:
                continue
            first, first_overhead, _ = start.get(pid, (None, None, cmd))
            first_overhead = first_overhead or (0, 0, 0, 0, 0)
            values = rates(first, last, elapsed)
            values.update({"mw": values["energy_mw_cpu"],
                           "gpu_ms_per_s": gpu_ms_per_s(gpu_first, gpu_last, pid, elapsed),
                           "disk_kb_per_s": (last_overhead[0] - first_overhead[0]) / 1024 / elapsed,
                           "mach_msgs_per_s": _delta32(last_overhead[2], first_overhead[2]) / elapsed,
                           "syscalls_per_s": _delta32(last_overhead[3], first_overhead[3]) / elapsed,
                           "csw_per_s": _delta32(last_overhead[4], first_overhead[4]) / elapsed})
            rows.append({"pid": pid, "kind": self.kind(pid, cmd), "threads": last_overhead[1], **values})
        result = window_totals(rows)
        result["seconds"] = round(elapsed, 1)
        result["coalition"] = coalition_rates(coalition_first, coalition_last, elapsed)
        if per_pid:
            result["pids"] = sorted(({k: round(v, 3) if isinstance(v, float) else v for k, v in row.items()}
                                     for row in rows), key=lambda row: -row["cpu_pct"])
        return result

    def end(self, grace: float = 10):
        """SIGTERM the app, then SIGKILL anything of the instance still alive."""
        import signal
        pids = set(self.pids()) | {self.pid}
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and _alive(self.pid):
            time.sleep(0.2)  # bench: waiting for a clean quit
        pids |= set(self.pids())
        for pid in pids:
            if _alive(pid) and pid != os.getpid():
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def load_average() -> float:
    return os.getloadavg()[0]


# `pmset -g assertions`, "Listed by owning process": one header line per assertion, then indented detail lines
# (`Created for PID: N.` when a daemon such as powerd or runningboardd holds it on a process's behalf).
# A header is `pid N(process): [assertion ID] age type named: "name"`; the age (HH:MM:SS held so far) changes
# between reads, the ID does not.
_ASSERTION_RE = re.compile(r"^\s*pid (\d+)\((.*?)\): \[(0x[0-9a-fA-F]+)\] (\S+) (\S+)(?: named: \"(.*)\")?")
_CREATED_FOR_RE = re.compile(r"Created for PID: (\d+)")


def power_assertions(pids, text: str | None = None) -> list[dict]:
    """The power assertions held by or created for a pid of `pids`: [{pid, process, id, type, name, age, line}].

    `id` is the assertion's ID (`0x...`, the same at every read while it is held) and `age` how long it has been
    held at this read. `text` is `pmset -g assertions` output (read now when None). An assertion created for one
    of the pids by another process counts for that pid."""
    if text is None:
        text = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True).stdout
    wanted = set(pids)
    found, current = [], None
    for line in text.splitlines():
        header = _ASSERTION_RE.match(line)
        if header:
            pid, process, assertion_id, age, kind, name = header.groups()
            current = {"pid": int(pid), "process": process, "id": assertion_id.lower(), "type": kind,
                       "name": name or "", "age": age, "line": line.strip()[:240]}
            found.append(current)
            continue
        if current is not None and line[:1] in ("\t", " ") and line.strip():
            created = _CREATED_FOR_RE.search(line)
            if created:
                current["created_for"] = int(created.group(1))
        else:
            current = None
    return [a for a in found if a["pid"] in wanted or a.get("created_for") in wanted]


THERMAL_STATES = ("nominal", "fair", "serious", "critical")  # NSProcessInfoThermalState 0...3


def thermal_state() -> str | None:
    """The Mac's `ProcessInfo.processInfo.thermalState` now (system-wide, the value the app reads), or None."""
    try:
        objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
        ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    except OSError:
        return None
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    send_object = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
    send_integer = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
    info = send_object(objc.objc_getClass(b"NSProcessInfo"), objc.sel_registerName(b"processInfo"))
    if not info:
        return None
    state = send_integer(info, objc.sel_registerName(b"thermalState"))
    return THERMAL_STATES[state] if 0 <= state < len(THERMAL_STATES) else None


# ---------------------------------------------------------------------------------------------------------
# Network, unified log and top's IDLEW (D15 of plans/cmux-next/chrome-parity/p14-energy.md). Each reader asks
# the kernel or logd, never the measured processes, so a reading wakes none of them. Each has a pure parser
# that scripts/cmux-next/tests/test_idle_budget.py covers with fixtures on any host.

NETTOP = "/usr/bin/nettop"
LOG = "/usr/bin/log"
TOP = "/usr/bin/top"


def nettop_command(seconds: float) -> list[str]:
    """nettop for a window of `seconds`: CSV (-L) of one sample a second (-s 1), byte deltas (-d), raw numbers
    (-x), no name lookups (-n). Sample 0 has the totals so far and is not counted; samples 1..N are the window.
    No -P: each process row is followed by its flows, so one run gives the bytes and the connections."""
    return [NETTOP, "-x", "-n", "-d", "-L", str(max(1, math.ceil(seconds)) + 1), "-s", "1"]


_FLOW = re.compile(r"((?:tcp|udp|quic)\d?) (.+)<->(.+)")
_PROCESS = re.compile(r"(.+)\.(\d+)")


def _nettop_samples(text: str) -> list[list[dict]]:
    """nettop's CSV as samples (each starts at a `time,...` header) of rows {column: value, "name": ...}."""
    samples: list[list[dict]] = []
    header: list[str] | None = None
    for line in csv.reader(text.splitlines()):
        if not line:
            continue
        if line[0] == "time":
            header = line
            samples.append([])
            continue
        if header is None or len(line) < 2:
            continue
        row = {column: line[index] for index, column in enumerate(header) if column and index < len(line)}
        row["name"] = line[1]
        samples[-1].append(row)
    return samples


def _bytes(row: dict) -> int:
    values = (row.get(column, "").strip() for column in ("bytes_in", "bytes_out"))
    return sum(int(value) for value in values if value.isdigit())


# A window sample may land up to this long before the window's end (nettop's 1 s interval and its jitter).
NETTOP_SLACK_S = 1.5


def _nettop_stamp(sample: list[dict], near: float) -> float | None:
    """The epoch of a sample's `time` column (local HH:MM:SS.ffffff, no date): the day nearest to `near`."""
    if not sample:
        return None
    try:
        clock = datetime.datetime.strptime(sample[0].get("time", ""), "%H:%M:%S.%f").time()
    except ValueError:
        return None
    day = datetime.datetime.fromtimestamp(near).date()
    stamps = [datetime.datetime.combine(day + datetime.timedelta(days=shift), clock).timestamp() for shift in (-1, 0, 1)]
    return min(stamps, key=lambda stamp: abs(stamp - near))


def _window_samples(samples: list[list[dict]], start: float | None, end: float | None) -> list[list[dict]] | None:
    """The delta samples that count: without a window samples 1..N; with one, those stamped inside start..end, and
    None unless they cover it (a sample at or before `start` precedes them, the last lands within NETTOP_SLACK_S of
    `end`). Sample 0 holds the totals so far and never counts."""
    samples = [sample for sample in samples if sample]
    if len(samples) < 2:
        return None
    if start is None or end is None:
        return samples[1:]
    stamps = [_nettop_stamp(sample, start) for sample in samples]
    if any(stamp is None for stamp in stamps):
        return None
    inside = [index for index in range(1, len(samples)) if start <= stamps[index] <= end]
    if not inside or stamps[inside[0] - 1] > start or stamps[inside[-1]] < end - NETTOP_SLACK_S:
        return None
    return [samples[index] for index in inside]


def _host(end: str) -> str:
    """The host of a nettop -n end: `17.253.4.125:443` and IPv6 `fe80::1%en0.443` (port after a dot)."""
    if end.count(":") == 1:
        return end.rsplit(":", 1)[0]
    head, _, port = end.rpartition(".")
    return head if head and port.isdigit() and ":" in head else end


def remote_matches(allowed: str, end: str) -> bool:
    """Whether a remote end (`tcp4 17.253.4.125:443`, parse_nettop's) is `allowed`: the same `proto host:port`,
    `host:port` or `host`, compared whole (never a substring: 1.1.1.1 is not 11.1.1.1)."""
    address = end.split(" ", 1)[-1]
    return allowed in (end, address, _host(address))


def parse_nettop(text: str, start: float | None = None, end: float | None = None) -> dict[int, dict] | None:
    """{pid: {bytes, loopback_bytes, connections, remotes, remote_bytes}} from `nettop_command` output, or None when
    the output does not measure the window (fewer than two samples, or with start..end (epoch seconds) samples that
    do not cover it): not measured is never 0 bytes.

    Only the samples stamped inside start..end count (`_window_samples`), so reads made around the window are not
    counted. bytes: in + out of the process rows; loopback_bytes: the part of its lo0 flows; connections: flows of
    the last counted sample with a remote end that are not listening; remote_bytes: {remote end: bytes} of the flows
    that moved bytes; remotes: those ends, then the ends only open at the end (the owner of an over)."""
    samples = _window_samples(_nettop_samples(text), start, end)
    if samples is None:
        return None
    out: dict[int, dict] = {}
    opened: dict[int, list[str]] = {}
    for index, sample in enumerate(samples):
        last = index == len(samples) - 1
        got = None
        for row in sample:
            flow = _FLOW.fullmatch(row["name"])
            if flow is None:
                process = _PROCESS.fullmatch(row["name"])
                pid = None if process is None else int(process.group(2))
                got = None if pid is None else out.setdefault(
                    pid, {"bytes": 0, "loopback_bytes": 0, "connections": 0, "remotes": [], "remote_bytes": {}})
                if got is not None:
                    got["bytes"] += _bytes(row)
                continue
            if got is None:
                continue
            moved = _bytes(row)
            if row.get("interface") == "lo0":
                got["loopback_bytes"] += moved
            remote = flow.group(3).strip()
            end_name = f"{flow.group(1)} {remote}"
            if moved:
                got["remote_bytes"][end_name] = got["remote_bytes"].get(end_name, 0) + moved
            if last and row.get("state") != "Listen" and not remote.startswith("*"):
                got["connections"] += 1
                opened.setdefault(pid, []).append(end_name)
    for pid, got in out.items():
        got["remotes"] = list(dict.fromkeys([*got["remote_bytes"], *opened.get(pid, [])]))
    return out


def _log_time(epoch: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def log_command(pids, start: float, end: float) -> list[str]:
    """`log show` of every line (info and debug too) the pids wrote around start..end (epoch seconds), one JSON
    object a line. The query is whole seconds; parse_log keeps only the lines inside start..end."""
    predicate = " OR ".join(f"processID == {pid}" for pid in sorted(pids)) or "processID == -1"
    return [LOG, "show", "--style", "ndjson", "--info", "--debug", "--start", _log_time(math.floor(start)),
            "--end", _log_time(math.ceil(end)), "--predicate", predicate]


def _event_epoch(stamp) -> float | None:
    try:
        return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except (TypeError, ValueError):
        return None


def parse_log(text: str, pids=None, start: float | None = None, end: float | None = None) -> dict[int, dict]:
    """{pid: {lines, owners: {"subsystem:category": lines}}} from `log show --style ndjson`, counting only events
    of `pids` stamped inside start..end (a line that is not an event is skipped). An event with no subsystem is
    owned by its sender image."""
    out: dict[int, dict] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        pid = event.get("processID")
        if not isinstance(pid, int) or (pids is not None and pid not in pids):
            continue
        if start is not None or end is not None:
            at = _event_epoch(event.get("timestamp"))
            if at is None or (start is not None and at < start) or (end is not None and at > end):
                continue
        owner = f"{event.get('subsystem') or '-'}:{event.get('category') or '-'}"
        if owner == "-:-":
            owner = os.path.basename(event.get("senderImagePath") or "") or "-"
        got = out.setdefault(pid, {"lines": 0, "owners": {}})
        got["lines"] += 1
        got["owners"][owner] = got["owners"].get(owner, 0) + 1
    return out


def read_log(pids, start: float, end: float) -> dict[int, dict] | None:
    """parse_log of `log show` for the pids over start..end, or None when the log cannot be read."""
    try:
        done = subprocess.run(log_command(pids, start, end), capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    return parse_log(done.stdout, set(pids), start, end)


def parse_top_idlew(text: str, pid: int) -> int | None:
    """The cumulative IDLEW (package idle wakeups) of `pid` in `top -l 1 -pid PID -stats pid,idlew` output;
    top marks a value that changed with a trailing + or -."""
    found = None
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == str(pid):
            value = parts[1].rstrip("+-")
            if value.isdigit():
                found = int(value)
    return found


def top_idlew(pid: int) -> int | None:
    """The cumulative IDLEW of `pid` from `top`, for another user's process when proc_pid_rusage cannot read it
    (WindowServer without root): package idle wakeups only, so a rate compares it with a top reading, never with an
    rusage one."""
    try:
        text = subprocess.run([TOP, "-l", "1", "-pid", str(pid), "-stats", "pid,idlew"], capture_output=True,
                              text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_top_idlew(text, pid)
