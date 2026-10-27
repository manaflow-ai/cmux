"""Per-thread wakeups of a process, by thread name (p06-scheduler-228, queue QD of p06-scheduler.md).

The kernel keeps interrupt wakeups per process only (proc_pid_rusage), so a thread's wakeups come from sampling:
every `interval` the sampler reads each thread's CPU time with proc_pidinfo (PROC_PIDLISTTHREADS, then
PROC_PIDTHREADINFO: `pth_user_time + pth_system_time`, and `pth_name`), and a thread whose CPU time moved between
two samples ran at least once in between. At idle a thread wakes far less often than the 20 ms default interval, so
each run is one wakeup; above about 25/s the count saturates at the sample rate and is a floor. A thread that
starts inside the window counts its start as one run. proc_pidinfo is a kernel read: the sampled process does
not wake for it. On Linux the same counts come from /proc/<pid>/task/<tid>/schedstat (run time in ns) and comm,
so the sampler runs anywhere the tests do.

Threads with one name pattern (digit runs read as `*`: `mux-deadline-3` and `mux-deadline-7` are
`mux-deadline-*`) are one row. Each row over QUEUE_THRESHOLD wakeups/s is one entry of the queue: one thread
whose idle wakeups a task removes (a blocking wait with an explicit wake, or a dirty-triggered deadline).
"""
from __future__ import annotations

import ctypes
import os
import re
import struct
import sys
import time

# A thread waking more often than this at idle is one queue entry (p06-scheduler.md, queue QD).
QUEUE_THRESHOLD = 0.05
DEFAULT_INTERVAL_S = 0.02


class DarwinThreads:
    """{thread handle: (name, cpu_ns)} of a process through libproc."""

    PROC_PIDTHREADINFO, PROC_PIDLISTTHREADS, PROC_PIDTASKINFO = 5, 6, 4
    THREADINFO_SIZE, TASKINFO_SIZE = 112, 96

    def __init__(self):
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        self.lib = lib
        self.info = ctypes.create_string_buffer(self.THREADINFO_SIZE)

    def _pidinfo(self, pid, flavor, arg, size):
        buf = self.info if size == self.THREADINFO_SIZE else ctypes.create_string_buffer(size)
        n = self.lib.proc_pidinfo(pid, flavor, arg, buf, size)
        return buf.raw[:n] if n > 0 else None

    def threads(self, pid):
        task = self._pidinfo(pid, self.PROC_PIDTASKINFO, 0, self.TASKINFO_SIZE)
        if not task or len(task) < self.TASKINFO_SIZE:
            return None  # the process is gone
        count = struct.unpack_from("<i", task, 84)[0]  # pti_threadnum
        raw = self._pidinfo(pid, self.PROC_PIDLISTTHREADS, 0, 8 * (count + 64)) or b""
        result = {}
        for (handle,) in struct.iter_unpack("<Q", raw[:len(raw) - len(raw) % 8]):
            info = self._pidinfo(pid, self.PROC_PIDTHREADINFO, handle, self.THREADINFO_SIZE)
            if not info or len(info) < self.THREADINFO_SIZE:
                continue  # the thread ended between the list and the read
            user_ns, system_ns = struct.unpack_from("<QQ", info, 0)
            name = info[48:112].split(b"\0", 1)[0].decode("utf-8", "replace")
            result[handle] = (name, user_ns + system_ns)
        return result


class LinuxThreads:
    """{tid: (name, run_ns)} of a process from procfs."""

    def threads(self, pid):
        base = f"/proc/{pid}/task"
        try:
            tids = os.listdir(base)
        except OSError:
            return None
        result = {}
        for tid in tids:
            try:
                with open(f"{base}/{tid}/comm") as handle:
                    name = handle.read().strip()
                with open(f"{base}/{tid}/schedstat") as handle:
                    run_ns = int(handle.read().split()[0])
            except (OSError, ValueError, IndexError):
                continue  # the thread ended
            result[int(tid)] = (name, run_ns)
        return result


def reader():
    """This system's thread reader, or None where there is none."""
    if sys.platform == "darwin":
        return DarwinThreads()
    if sys.platform.startswith("linux"):
        return LinuxThreads()
    return None


def sample(source, pids, seconds, interval_s=DEFAULT_INTERVAL_S, clock=time.monotonic, sleep=time.sleep):
    """Samples `pids` every `interval_s` for `seconds`; returns ({(pid, thread): {name, runs, cpu_ns}}, samples).
    Takes the place of the measurement window's sleep, so it returns at the window's end."""
    deadline = clock() + seconds
    last = {}
    threads = {}
    samples = 0
    while True:
        now = clock()
        for pid in pids:
            snapshot = source.threads(pid)
            if snapshot is None:
                continue
            for handle, (name, cpu_ns) in snapshot.items():
                key = (pid, handle)
                row = threads.get(key)
                if row is None:
                    # Present at the first sample: the baseline. Started later: its start was a run.
                    threads[key] = row = {"name": name, "runs": 1 if samples and cpu_ns > 0 else 0, "cpu_ns": 0}
                elif cpu_ns > last[key]:
                    row["runs"] += 1
                    row["cpu_ns"] += cpu_ns - last[key]
                row["name"] = name or row["name"]
                last[key] = cpu_ns
        samples += 1
        if now >= deadline:
            return threads, samples
        sleep(max(0.0, min(interval_s, deadline - clock())))  # test script: the sampling interval


def name_pattern(name):
    """A thread name with its digit runs as `*` (per-surface and per-worker threads share a row)."""
    return re.sub(r"\d+", "*", name) if name else "(unnamed)"


def summarize(threads, wall, interval_s=DEFAULT_INTERVAL_S, threshold=QUEUE_THRESHOLD):
    """The `daemon_threads` JSON: one row per name pattern, most wakeups first, their sum, and the queue (rows
    over `threshold` wakeups/s)."""
    rows = {}
    for row in threads.values():
        pattern = name_pattern(row["name"])
        entry = rows.setdefault(pattern, {"name": pattern, "threads": 0, "wakeups": 0, "cpu_ms": 0.0})
        entry["threads"] += 1
        entry["wakeups"] += row["runs"]
        entry["cpu_ms"] += row["cpu_ns"] / 1e6
    ordered = sorted(rows.values(), key=lambda entry: (-entry["wakeups"], entry["name"]))
    for entry in ordered:
        entry["per_second"] = round(entry["wakeups"] / wall, 3) if wall > 0 else None
        entry["cpu_ms"] = round(entry["cpu_ms"], 3)
    total = sum(entry["wakeups"] for entry in ordered)
    return {
        "method": "proc_pidinfo thread CPU-time deltas" if sys.platform == "darwin" else "procfs schedstat deltas",
        "sample_ms": round(interval_s * 1000, 1),
        "wall_s": round(wall, 1),
        "sum_per_s": round(total / wall, 3) if wall > 0 else None,
        "threads": ordered,
        "queue": [entry["name"] for entry in ordered
                  if entry["per_second"] is not None and entry["per_second"] > threshold],
    }
