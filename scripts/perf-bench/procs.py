"""Per-process counters for xbench.py: energy, CPU, wakeups and memory with no root.

`proc_pid_rusage(RUSAGE_INFO_V6)` gives, per process:
  ri_energy_nj       macOS's CPU energy estimate (word 42): the mW rows
  ri_user/system     CPU time in mach ticks (words 2, 3): CPU %
  pkg idle + interrupt wakeups (words 4, 5): wakeups/s (what Activity Monitor shows)
  ri_phys_footprint  (word 9): what Activity Monitor calls Memory
  ri_diskio_byteswritten (word 19): bytes the process wrote to disk (the disk-write rows)

`proc_pidinfo(PROC_PIDTASKINFO)` adds the overhead counters of speed-of-sound-DESIGN.md:
threads, Mach messages sent + received (IPC), Unix + Mach syscalls and context switches.

An instance is every process of one browser run: the main pid's descendants,
every process whose executable lies inside the bundle (helpers, crashpad,
cmux daemons and terminal hosts, which outlive their parents), and every
process macOS counts the main pid responsible for (Safari's and cmux's
WebKit XPC processes).
"""
from __future__ import annotations

import ctypes
import os
import re
import subprocess
import time

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
try:
    _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
    _responsible.restype = ctypes.c_int
    _responsible.argtypes = [ctypes.c_int]
except AttributeError:
    _responsible = None


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase()
_libsystem.mach_timebase_info(ctypes.byref(_timebase))
MB = 1048576.0


def counters(pid: int):
    """(energy nJ, cpu ns, wakeups, footprint bytes), or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    cpu_ns = (buf[2] + buf[3]) * _timebase.numer // _timebase.denom
    return buf[42], cpu_ns, buf[4] + buf[5], buf[9]


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
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    info = _TaskInfo()
    size = ctypes.sizeof(info)
    if _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTASKINFO), ctypes.c_uint64(0),
                             ctypes.byref(info), ctypes.c_int(size)) != size:
        return buf[19], 0, 0, 0, 0
    return (buf[19], info.threadnum, (info.messages_sent + info.messages_received) & 0xFFFFFFFF,
            (info.syscalls_mach + info.syscalls_unix) & 0xFFFFFFFF, info.csw & 0xFFFFFFFF)


def _delta32(last: int, first: int) -> int:
    return (last - first) & 0xFFFFFFFF


def process_table():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


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


def kind_of(cmd: str) -> str:
    """A short process kind for the per-kind breakdown."""
    if "--type=renderer" in cmd:
        return "renderer"
    if "--type=gpu-process" in cmd:
        return "gpu"
    if "--type=utility" in cmd:
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
    exe = cmd.split(" --", 1)[0].split(" -")[0]
    if " Helper" in exe:
        return "helper"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "main"
    return os.path.basename(exe)[:40]


class Instance:
    """The process set of one browser run, re-read on every sample."""

    def __init__(self, bundle: str, pid: int):
        self.bundle = bundle
        self.pid = pid
        self.roots = _roots(bundle)
        self.seen: set[int] = set()

    def pids(self) -> dict[int, str]:
        table = process_table()
        children: dict[int, list[int]] = {}
        commands = {}
        for pid, ppid, cmd in table:
            children.setdefault(ppid, []).append(pid)
            commands[pid] = cmd
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
            elif _responsible is not None and pid != self.pid and _responsible(pid) == self.pid:
                found.add(pid)
        # Terminal hosts name their daemon (`--owner ...@<pid>`) and run from outside the bundle.
        for pid, cmd in commands.items():
            owner = re.search(r"--owner \S+@(\d+)", cmd) if "__terminal-host" in cmd else None
            if owner and int(owner.group(1)) in found:
                found.add(pid)
        self.seen |= found
        return {pid: commands[pid] for pid in found}

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
            kinds[kind_of(cmd)] = kinds.get(kind_of(cmd), 0.0) + mb
            if per_pid:
                rows.append({"pid": pid, "kind": kind_of(cmd), "command": cmd[:160], "footprint_mb": round(mb, 1),
                             "rss_mb": rss.get(pid)})
        result = {"mb": round(total, 1), "processes": count,
                  "kinds": {k: round(v, 1) for k, v in sorted(kinds.items(), key=lambda kv: -kv[1])}}
        if per_pid:
            result["pids"] = sorted(rows, key=lambda row: -row["footprint_mb"])
        return result

    def window(self, seconds: float, during=None, per_pid: bool = False) -> dict:
        """Energy (mW), CPU % (of one core) and wakeups/s over `seconds`, summed over the instance
        (and per process with `per_pid`).

        A process that starts inside the window counts from its start; one that
        ends inside it is lost (its last counters cannot be read)."""
        start = {pid: (counters(pid), cmd) for pid, cmd in self.pids().items()}
        start_overhead = {pid: overhead(pid) for pid in start}
        began = time.monotonic()
        if during:
            during(seconds)
        else:
            time.sleep(seconds)  # bench: the measured window
        elapsed = time.monotonic() - began
        kinds: dict[str, dict] = {}
        totals = {"mw": 0.0, "cpu_pct": 0.0, "wakeups_per_s": 0.0, "disk_kb_per_s": 0.0,
                  "mach_msgs_per_s": 0.0, "syscalls_per_s": 0.0, "csw_per_s": 0.0}
        threads = 0
        processes = 0
        rows = []
        for pid, cmd in self.pids().items():
            last = counters(pid)
            last_overhead = overhead(pid)
            if last is None or last_overhead is None:
                continue
            first = start.get(pid, (None, cmd))[0] or (0, 0, 0, 0)
            first_overhead = start_overhead.get(pid) or (0, 0, 0, 0, 0)
            values = {"mw": (last[0] - first[0]) / 1e6 / elapsed,
                      "cpu_pct": 100 * (last[1] - first[1]) / 1e9 / elapsed,
                      "wakeups_per_s": (last[2] - first[2]) / elapsed,
                      "disk_kb_per_s": (last_overhead[0] - first_overhead[0]) / 1024 / elapsed,
                      "mach_msgs_per_s": _delta32(last_overhead[2], first_overhead[2]) / elapsed,
                      "syscalls_per_s": _delta32(last_overhead[3], first_overhead[3]) / elapsed,
                      "csw_per_s": _delta32(last_overhead[4], first_overhead[4]) / elapsed}
            threads += last_overhead[1]
            processes += 1
            entry = kinds.setdefault(kind_of(cmd), {"n": 0, "threads": 0, **{k: 0.0 for k in totals}})
            entry["n"] += 1
            entry["threads"] += last_overhead[1]
            for key, value in values.items():
                entry[key] += value
                totals[key] += value
            if per_pid:
                rows.append({"pid": pid, "kind": kind_of(cmd), "threads": last_overhead[1],
                             **{k: round(v, 3) for k, v in values.items()}})
        rounded = {k: round(v, 3) for k, v in totals.items()}
        rounded["threads"] = threads
        rounded["processes"] = processes
        rounded["seconds"] = round(elapsed, 1)
        rounded["kinds"] = {k: {kk: round(vv, 3) for kk, vv in e.items()}
                            for k, e in sorted(kinds.items(), key=lambda kv: -kv[1]["mw"])}
        if per_pid:
            rounded["pids"] = sorted(rows, key=lambda row: -row["cpu_pct"])
        return rounded

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
