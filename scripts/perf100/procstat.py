"""Per-process counters for perf100, with no root.

macOS (one call per process, no wakeup of the process read):
  proc_pid_rusage(RUSAGE_INFO_V6), u64 words:
    2, 3   ri_user_time, ri_system_time (mach ticks)       -> cpu_ns
    5      ri_interrupt_wkups                              -> wakeups (every wakeup of the process from
                                                              idle; ri_pkg_idle_wkups is a subset of it)
    4      ri_pkg_idle_wkups                               -> pkg_idle_wakeups (package-idle exits only;
                                                              always 0 on Apple silicon, measured
                                                              2026-10-21 on cmux-lawrence-2)
    8      ri_resident_size                                -> rss
    9      ri_phys_footprint                               -> footprint (Activity Monitor "Memory")
    18, 19 ri_diskio_bytesread / ri_diskio_byteswritten    -> disk_read_io, disk_write_io (I/O that
                                                              reached the storage layer)
    29     ri_logical_writes                               -> disk_write_logical (bytes the process
                                                              wrote to files, before the cache)
    30     ri_lifetime_max_phys_footprint                  -> max_footprint
    42     ri_energy_nj                                    -> energy_nj (CPU energy estimate)
  proc_pidinfo(PROC_PIDTASKINFO): pti_threadnum (threads), pti_syscalls_mach + pti_syscalls_unix
    (syscalls), pti_csw (context switches).
Linux:
  /proc/<pid>/stat utime+stime, /proc/<pid>/status Threads/VmRSS/VmHWM, voluntary context switches
  summed over /proc/<pid>/task/* (wakeups; threads that exit inside a window are not counted), /proc/<pid>/smaps_rollup Pss (footprint),
  /proc/<pid>/io write_bytes (disk_write_logical and disk_write_io: bytes this process caused to be
  sent to storage, counted when the page is dirtied; wchar is not used, it counts PTY, pipe and
  socket writes too), syscr+syscw (I/O syscalls only).

`SOURCES` names the source of every field for the run JSON. A process that exits between two
samples keeps its last sampled counters (at most one sample interval is lost).
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import threading
import time

IS_MAC = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")
MB = 1048576.0

FIELDS = ("cpu_ns", "wakeups", "pkg_idle_wakeups", "rss", "footprint", "max_footprint", "threads", "disk_write_logical",
          "disk_write_io", "disk_read_io", "syscalls", "csw", "energy_nj")
# Fields that only grow over a process's life: a window reports last - first.
CUMULATIVE = ("cpu_ns", "wakeups", "pkg_idle_wakeups", "disk_write_logical", "disk_write_io", "disk_read_io", "syscalls", "csw",
              "energy_nj")

if IS_MAC:
    SOURCES = {
        "cpu": "proc_pid_rusage(RUSAGE_INFO_V6) ri_user_time + ri_system_time",
        "wakeups": "proc_pid_rusage ri_interrupt_wkups (all wakeups from idle; includes ri_pkg_idle_wkups, "
                   "which is 0 on Apple silicon and reported apart as pkg_idle_wakeups)",
        "rss": "proc_pid_rusage ri_resident_size",
        "footprint": "proc_pid_rusage ri_phys_footprint (Activity Monitor Memory; footprint(1) total)",
        "threads": "proc_pidinfo(PROC_PIDTASKINFO) pti_threadnum",
        "disk_written": "proc_pid_rusage ri_logical_writes (bytes written to files by the process, before the "
                        "buffer cache; the most precise unprivileged per-process write counter on macOS)",
        "disk_io_written": "proc_pid_rusage ri_diskio_byteswritten (I/O the process issued to storage)",
        "syscalls": "proc_pidinfo(PROC_PIDTASKINFO) pti_syscalls_mach + pti_syscalls_unix",
        "socket_bytes": "bytes the harness's own clients receive (attach streams, acpmux send); macOS has no "
                        "unprivileged per-process Unix-socket byte counter",
    }
else:
    SOURCES = {
        "cpu": "/proc/<pid>/stat utime + stime",
        "wakeups": "voluntary_ctxt_switches summed over /proc/<pid>/task/*/status",
        "rss": "/proc/<pid>/status VmRSS",
        "footprint": "/proc/<pid>/smaps_rollup Pss (VmRSS when unreadable)",
        "threads": "/proc/<pid>/status Threads",
        "disk_written": "/proc/<pid>/io write_bytes (storage-layer bytes, counted when dirtied; exact, unprivileged "
                        "for own processes)",
        "disk_io_written": "/proc/<pid>/io write_bytes",
        "syscalls": "/proc/<pid>/io syscr + syscw (I/O syscalls only)",
        "socket_bytes": "not available per process without root on Linux; harness-owned connections only",
    }

if IS_MAC:
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

    class _TaskInfo(ctypes.Structure):
        _fields_ = [("virtual_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64),
                    ("total_user", ctypes.c_uint64), ("total_system", ctypes.c_uint64),
                    ("threads_user", ctypes.c_uint64), ("threads_system", ctypes.c_uint64),
                    ("policy", ctypes.c_int32), ("faults", ctypes.c_int32), ("pageins", ctypes.c_int32),
                    ("cow_faults", ctypes.c_int32), ("messages_sent", ctypes.c_int32),
                    ("messages_received", ctypes.c_int32), ("syscalls_mach", ctypes.c_int32),
                    ("syscalls_unix", ctypes.c_int32), ("csw", ctypes.c_int32), ("threadnum", ctypes.c_int32),
                    ("numrunning", ctypes.c_int32), ("priority", ctypes.c_int32)]

    _timebase = _Timebase()
    _libsystem.mach_timebase_info(ctypes.byref(_timebase))
    _PROC_PIDTASKINFO = 4
else:
    _responsible = None
    _CLK = os.sysconf("SC_CLK_TCK") if IS_LINUX else 100
    _PAGE = os.sysconf("SC_PAGE_SIZE") if IS_LINUX else 4096


def responsible_pid(pid: int) -> int | None:
    """macOS: the process macOS holds responsible for `pid` (WebKit XPC processes -> the app)."""
    if _responsible is None:
        return None
    got = _responsible(pid)
    return got if got > 0 else None


def read(pid: int) -> dict | None:
    """Every field of FIELDS for `pid` now, or None once it is gone or unreadable."""
    return _read_mac(pid) if IS_MAC else _read_linux(pid)


def _read_mac(pid: int) -> dict | None:
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    task = _TaskInfo()
    size = ctypes.sizeof(_TaskInfo)
    got_task = _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTASKINFO), ctypes.c_uint64(0),
                                     ctypes.byref(task), ctypes.c_int(size)) == size
    return {
        "cpu_ns": (buf[2] + buf[3]) * _timebase.numer // _timebase.denom,
        "wakeups": buf[5],
        "pkg_idle_wakeups": buf[4],
        "rss": buf[8],
        "footprint": buf[9],
        "max_footprint": buf[30],
        "threads": task.threadnum if got_task else None,
        "disk_write_logical": buf[29],
        "disk_write_io": buf[19],
        "disk_read_io": buf[18],
        "syscalls": (task.syscalls_mach + task.syscalls_unix) if got_task else None,
        "csw": task.csw if got_task else None,
        "energy_nj": buf[42],
    }


def _read_linux(pid: int) -> dict | None:
    base = f"/proc/{pid}"
    try:
        with open(f"{base}/stat") as handle:
            stat = handle.read()
        fields = stat[stat.rindex(")") + 2:].split()
        status = {}
        with open(f"{base}/status") as handle:
            for line in handle:
                key, _, value = line.partition(":")
                status[key] = value.strip()
    except (OSError, ValueError):
        return None
    io = {}
    try:
        with open(f"{base}/io") as handle:
            for line in handle:
                key, _, value = line.partition(":")
                io[key] = int(value)
    except (OSError, ValueError):
        pass
    pss = None
    try:
        with open(f"{base}/smaps_rollup") as handle:
            for line in handle:
                if line.startswith("Pss:"):
                    pss = int(line.split()[1]) * 1024
                    break
    except (OSError, ValueError):
        pass
    switches = 0
    try:
        for tid in os.listdir(f"{base}/task"):
            try:
                with open(f"{base}/task/{tid}/status") as handle:
                    for line in handle:
                        if line.startswith("voluntary_ctxt_switches:"):
                            switches += int(line.split()[1])
            except OSError:
                continue
    except OSError:
        pass

    def kb(name):
        value = status.get(name, "").split()
        return int(value[0]) * 1024 if value else None

    rss = kb("VmRSS")
    return {
        "cpu_ns": (int(fields[11]) + int(fields[12])) * 1_000_000_000 // _CLK,
        "wakeups": switches,
        "pkg_idle_wakeups": None,
        "rss": rss,
        "footprint": pss if pss is not None else rss,
        "max_footprint": kb("VmHWM"),
        "threads": int(status["Threads"]) if status.get("Threads", "").isdigit() else None,
        "disk_write_logical": io.get("write_bytes"),
        "disk_write_io": io.get("write_bytes"),
        "disk_read_io": io.get("read_bytes"),
        "syscalls": (io["syscr"] + io["syscw"]) if "syscr" in io and "syscw" in io else None,
        "csw": switches,
        "energy_nj": None,
    }


def process_table() -> list[tuple[int, int, str]]:
    """(pid, ppid, command) of every process."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def descendants(roots: set[int], table: list[tuple[int, int, str]]) -> set[int]:
    children: dict[int, list[int]] = {}
    for pid, ppid, _cmd in table:
        children.setdefault(ppid, []).append(pid)
    found: set[int] = set()
    stack = list(roots)
    while stack:
        pid = stack.pop()
        if pid in found:
            continue
        found.add(pid)
        stack.extend(children.get(pid, []))
    return found


def du(path: str) -> dict:
    """Allocated and apparent bytes and the file count under `path` (no symlinks followed)."""
    allocated = apparent = files = 0
    for root, dirs, names in os.walk(path, followlinks=False):
        for name in names + dirs:
            try:
                st = os.lstat(os.path.join(root, name))
            except OSError:
                continue
            allocated += getattr(st, "st_blocks", 0) * 512
            if name in names:
                apparent += st.st_size
                files += 1
    return {"allocated_mb": round(allocated / MB, 2), "apparent_mb": round(apparent / MB, 2), "files": files}


class Tracker:
    """Follows a process set through one measured window.

    `discover()` returns {pid: kind} for the processes that belong to the run now. A sampler
    thread re-discovers and reads every process each `interval` seconds, so processes that start
    inside the window count from their start (zero baseline) and processes that end inside it keep
    their last sample. Reading another process's counters does not wake it, so the sampler adds
    no wakeups or CPU to the measured processes (only to this harness)."""

    def __init__(self, discover, interval: float = 1.0):
        self.discover = discover
        self.interval = interval
        self.first: dict[int, dict] = {}
        self.last: dict[int, dict] = {}
        self.kind: dict[int, str] = {}
        self.born_inside: set[int] = set()
        self.samples: list[dict] = []
        self.alive: set[int] = set()
        self._stop = threading.Event()
        self._thread = None
        self._lock = threading.Lock()

    def _sample(self, initial: bool = False):
        found = self.discover()
        totals: dict[str, float] = {}
        alive: set[int] = set()
        now = time.monotonic()
        for pid, kind in found.items():
            got = read(pid)
            if got is None:
                continue
            alive.add(pid)
            with self._lock:
                if pid not in self.first:
                    if initial:
                        self.first[pid] = got
                    else:
                        # Started inside the window: its whole life is inside it.
                        self.first[pid] = {k: (0 if k in CUMULATIVE else v) for k, v in got.items()}
                        self.born_inside.add(pid)
                self.last[pid] = got
                self.kind[pid] = kind
            totals[kind] = totals.get(kind, 0.0) + (got["footprint"] or 0)
        self.samples.append({"t": now, "footprint_by_kind": totals})
        self.alive = alive

    def start(self):
        self.began = time.monotonic()
        self._sample(initial=True)
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def _loop(self):
        while not self._stop.wait(self.interval):
            self._sample()

    def stop(self) -> "Window":
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=30)
        self._sample()
        self.ended = time.monotonic()
        return Window(self)


class Window:
    """The result of one Tracker window: per process deltas and steady-state values."""

    def __init__(self, tracker: Tracker):
        self.seconds = tracker.ended - tracker.began
        self.rows = []
        for pid, last in tracker.last.items():
            first = tracker.first.get(pid, {})
            row = {"pid": pid, "kind": tracker.kind[pid], "born_inside": pid in tracker.born_inside,
                   "exited": pid not in tracker.alive}
            for field in FIELDS:
                if field in CUMULATIVE:
                    a, b = first.get(field), last.get(field)
                    # Linux sums context switches over live threads: an exited thread takes its
                    # count with it, so a delta can go below zero. Clamp (an undercount, noted).
                    row[field] = max(0, b - a) if (a is not None and b is not None) else None
                else:
                    row[field] = last.get(field)
            self.rows.append(row)
        self.samples = tracker.samples

    def peak(self, select) -> float:
        """The highest summed footprint (bytes) over the samples, of the kinds `select(kind)` keeps."""
        best = 0.0
        for sample in self.samples:
            best = max(best, sum(v for k, v in sample["footprint_by_kind"].items() if select(k)))
        return best

    def aggregate(self, key) -> dict[str, dict]:
        """Rows summed by `key(kind)`: CPU-seconds, CPU %, wakeups/s, disk (every process of the window,
        exited ones too) and memory, threads, process count (only those alive at the window's end)."""
        out: dict[str, dict] = {}
        steady = ("rss", "footprint", "threads")
        for row in self.rows:
            name = key(row["kind"])
            if name is None:
                continue
            e = out.setdefault(name, {"procs": 0, "exited": 0, "cpu_ns": 0, "wakeups": 0, "pkg_idle_wakeups": 0,
                                      "rss": 0, "footprint": 0, "threads": 0, "disk_write_logical": 0,
                                      "disk_write_io": 0, "syscalls": 0, "energy_nj": 0})
            if row["exited"]:
                e["exited"] += 1
            else:
                e["procs"] += 1
            for field in ("cpu_ns", "wakeups", "pkg_idle_wakeups", "rss", "footprint", "threads",
                          "disk_write_logical", "disk_write_io", "syscalls", "energy_nj"):
                if field in steady and row["exited"]:
                    continue
                if row.get(field) is not None:
                    e[field] += row[field]
        result = {}
        s = max(self.seconds, 1e-9)
        for name, e in out.items():
            peak = self.peak(lambda k, name=name: key(k) == name)
            result[name] = {
                "procs": e["procs"],
                "exited_procs": e["exited"],
                "cpu_s": round(e["cpu_ns"] / 1e9, 3),
                "cpu_pct": round(100 * e["cpu_ns"] / 1e9 / s, 3),
                "wakeups_per_s": round(e["wakeups"] / s, 2),
                "pkg_idle_wakeups_per_s": round(e["pkg_idle_wakeups"] / s, 2) if IS_MAC else None,
                "rss_mb": round(e["rss"] / MB, 1),
                "footprint_mb": round(e["footprint"] / MB, 1),
                "peak_footprint_mb": round(max(peak, e["footprint"]) / MB, 1),
                "threads": e["threads"],
                "disk_written_mb": round(e["disk_write_logical"] / MB, 3),
                "disk_io_written_mb": round(e["disk_write_io"] / MB, 3),
                "disk_written_mb_per_min": round(e["disk_write_logical"] / MB / s * 60, 3),
                "syscalls_per_s": round(e["syscalls"] / s, 1),
                "energy_mw": round(e["energy_nj"] / 1e6 / s, 2) if IS_MAC else None,
            }
        return result
