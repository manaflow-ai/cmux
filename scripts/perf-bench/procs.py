"""Per-process counters for xbench.py: energy, CPU, wakeups and memory with no root.

`proc_pid_rusage(RUSAGE_INFO_V6)` gives, per process:
  ri_energy_nj       macOS's CPU energy estimate (word 42): the mW rows
  ri_user/system     CPU time in mach ticks (words 2, 3): CPU %
  pkg idle + interrupt wakeups (words 4, 5): wakeups/s (what Activity Monitor shows)
  ri_phys_footprint  (word 9): what Activity Monitor calls Memory
  ri_diskio_byteswritten (word 19): bytes the process wrote to disk (the disk-write rows)

Readers that run outside the measured processes (no wakeup of theirs): nettop (bytes and connections per
process), `log show` (unified-log lines per process) and WindowServer's wakeups (another user's process).

`proc_pidinfo(PROC_PIDTASKINFO)` adds the overhead counters of speed-of-sound-DESIGN.md:
threads, Mach messages sent + received (IPC), Unix + Mach syscalls and context switches.

An instance is every process of one browser run: the main pid's descendants,
every process whose executable lies inside the bundle (helpers, crashpad,
cmux daemons and terminal hosts, which outlive their parents), and every
process macOS counts the main pid responsible for (Safari's and cmux's
WebKit XPC processes).
"""
from __future__ import annotations

import csv
import ctypes
import datetime
import json
import math
import os
import re
import subprocess
import time


class _MacOnly:
    """Stands in for a macOS library on another OS, so the parsers below import and test anywhere; a counter
    call raises OSError."""

    def __init__(self, path: str):
        self.path = path

    def __getattr__(self, name: str):
        raise OSError(f"{self.path} exists only on macOS ({name})")


def dylib(path: str):
    """ctypes.CDLL(path), or a _MacOnly stand-in when the library does not exist."""
    try:
        return ctypes.CDLL(path)
    except OSError:
        return _MacOnly(path)


_libproc = dylib("/usr/lib/libproc.dylib")
_libsystem = dylib("/usr/lib/libSystem.B.dylib")
try:
    _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
    _responsible.restype = ctypes.c_int
    _responsible.argtypes = [ctypes.c_int]
except (AttributeError, OSError):
    _responsible = None


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase(1, 1)
if isinstance(_libsystem, ctypes.CDLL):
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


# ---------------------------------------------------------------------------------------------------------
# Network, unified log and WindowServer (D15 of plans/cmux-next/chrome-parity/p14-energy.md). Each reader asks
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


def parse_nettop(text: str) -> dict[int, dict]:
    """{pid: {bytes, loopback_bytes, connections, remotes}} from `nettop_command` output.

    bytes: in + out of the process rows of samples 1..N; loopback_bytes: the part of its lo0 flows; connections:
    flows of the last sample with a remote end that are not listening; remotes: the remote ends of every flow
    that moved bytes or stayed open (the owner of an over)."""
    out: dict[int, dict] = {}
    samples = _nettop_samples(text)
    for index, sample in enumerate(samples[1:], start=1):
        last = index == len(samples) - 1
        got = None
        for row in sample:
            flow = _FLOW.fullmatch(row["name"])
            if flow is None:
                process = _PROCESS.fullmatch(row["name"])
                got = None if process is None else out.setdefault(
                    int(process.group(2)), {"bytes": 0, "loopback_bytes": 0, "connections": 0, "remotes": []})
                if got is not None:
                    got["bytes"] += _bytes(row)
                continue
            if got is None:
                continue
            moved = _bytes(row)
            if row.get("interface") == "lo0":
                got["loopback_bytes"] += moved
            remote = flow.group(3).strip()
            is_open = last and row.get("state") != "Listen" and not remote.startswith("*")
            got["connections"] += 1 if is_open else 0
            end = f"{flow.group(1)} {remote}"
            if (moved or is_open) and end not in got["remotes"]:
                got["remotes"].append(end)
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


def windowserver_pid() -> int | None:
    for pid, _ppid, cmd in process_table():
        if os.path.basename(cmd.split(" -", 1)[0].strip()) == "WindowServer":
            return pid
    return None


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


def windowserver_wakeups(pid: int) -> tuple[int | None, str]:
    """(cumulative WindowServer wakeups, source). proc_pid_rusage reads another user's process only as root;
    otherwise top's IDLEW is the reading (package idle wakeups only, so compare a source with itself)."""
    try:
        got = counters(pid)
    except OSError:
        got = None
    if got is not None:
        return got[2], "rusage"
    try:
        text = subprocess.run([TOP, "-l", "1", "-pid", str(pid), "-stats", "pid,idlew"], capture_output=True,
                              text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, "unreadable"
    value = parse_top_idlew(text, pid)
    return value, ("top-idlew" if value is not None else "unreadable")
