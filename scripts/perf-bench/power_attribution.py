"""Who spends a browser's idle power: owners of one measured window (p14-energy-096: cmux-chromium 122 mW in view
against Chrome's 51.2 mW, plans/cmux-next/chrome-parity/p14-energy.md 2.1).

Per process (procs.usage, proc_pid_rusage RUSAGE_INFO_V6, same user, no root):
  own       ri_energy_nj: the CPU energy macOS estimates for the process
  billed    ri_billed_energy: what other processes (WindowServer, the GPU process) spent for it under its voucher
  serviced  ri_serviced_energy: what it spent for others (inside `own`)
  mw = own + billed - serviced, procs.rates' energy_mw_billed: work moved to another process counts against the
  process it was done for, and a renderer's billed energy cancels its GPU process's serviced energy in a sum.

Per thread: the process's own energy split by each thread's CPU time in the window (PROC_PIDTHREADID64INFO), as
Chromium's resource attribution splits a process's measured CPU over the contexts it hosts
(components/performance_manager/resource_attribution/cpu_measurement_monitor.cc). Energy per CPU second differs
between P and E cores, so a thread's mW is an estimate; the process's is measured. Unnamed owners are one row
per kind, so energy spread over many threads is seen whole: `unnamed threads` (live threads with no pthread name,
until a stack sample names them), `exited threads` (CPU of threads that exited inside the window) and `process`
(energy with no thread split).

Total: the main process's resource coalition (procs.coalition_rates, what components/power_metrics/
resource_coalition_mac.mm reads), less the coalition's members outside the instance, plus the instance's
processes outside the coalition. The owners must sum to within TOLERANCE of it; the gap is energy of processes
that exited in the window or that the instance missed.

WindowServer: its own energy over the window, read as root (`sudo -n`; null without it). It is the whole
Mac's, so it compares two browsers measured the same way on one host, not one browser's share; what it did for
the instance is already each process's `billed`.

FrameClients: the wakeup ledger's `frame` entries (FrameScheduler records each client's frame under its owner)
that grew in the window, and each FrameScheduler's frames per second (debug.wakeups).

Every reader goes through `Reader`, so the pure parts and PowerWindow test anywhere.
`python3 -I power_attribution.py rusage PID` prints one process's procs.Usage as JSON (the root read).
"""
from __future__ import annotations

import ctypes
import dataclasses
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script's folder
import procs  # noqa: E402

FLOOR_MW = 2.0  # every owner at or above it must be named (the acceptance of p14-energy-096)
TOLERANCE = 0.10  # the owners sum to within 10% of the measured total

# ---------------------------------------------------------------------------------------------------------
# Readers (macOS)

_PROC_PIDLISTTHREADIDS = 28
_PROC_PIDTHREADID64INFO = 15


class _ThreadInfo(ctypes.Structure):
    _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


def thread_cpu(pid: int) -> dict[int, tuple[int, str]]:
    """{thread id: (CPU ns, pthread name)} of `pid` now; {} once it is gone."""
    libproc = procs._darwin().libproc
    ids = (ctypes.c_uint64 * 8192)()
    size = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDLISTTHREADIDS), ctypes.c_uint64(0),
                                ctypes.byref(ids), ctypes.c_int(ctypes.sizeof(ids)))
    out = {}
    for index in range(max(0, size) // 8):
        info = _ThreadInfo()
        got = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(_PROC_PIDTHREADID64INFO), ctypes.c_uint64(ids[index]),
                                   ctypes.byref(info), ctypes.c_int(ctypes.sizeof(info)))
        if got == ctypes.sizeof(info):
            out[int(ids[index])] = (info.user_time + info.system_time, info.name.decode(errors="replace"))
    return out


def root_usage(pid: int | None) -> procs.Usage | None:
    """procs.usage of another user's process (WindowServer) as root through `sudo -n`, or None without it."""
    if pid is None:
        return None
    try:
        out = subprocess.run(["sudo", "-n", sys.executable, "-I", os.path.abspath(__file__), "rusage", str(pid)],
                             capture_output=True, text=True, timeout=30)
        fields = json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else None
        return procs.Usage(**fields) if isinstance(fields, dict) else None
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return None


def sample_text(pid: int, seconds: float, path: str) -> str:
    """`/usr/bin/sample` of `pid` for `seconds` into `path` (after the window: it suspends the process); its text."""
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(max(1, int(seconds))), "-mayDie", "-file", path],
                       capture_output=True, timeout=seconds + 60)
        with open(path, errors="replace") as handle:
            return handle.read()
    except (OSError, subprocess.TimeoutExpired):
        return ""


@dataclasses.dataclass(frozen=True)
class Reader:
    """The counters PowerWindow reads (resolved at each call, so a test's patch of procs applies); tests pass fakes."""
    usage: object = lambda pid: procs.usage(pid)  # noqa: E731
    threads: object = lambda pid: thread_cpu(pid)  # noqa: E731
    coalition_id: object = lambda pid: procs.coalition_id(pid)  # noqa: E731
    coalition_usage: object = lambda cid: procs.coalition_usage(cid)  # noqa: E731
    process_table: object = lambda: procs.process_table()  # noqa: E731
    root_usage: object = lambda pid: root_usage(pid)  # noqa: E731
    clock: object = lambda: time.monotonic()  # noqa: E731


def window_server_pid(table) -> int | None:
    """WindowServer's pid from a process table of (pid, ppid, command)."""
    return next((pid for pid, _ppid, cmd in table if cmd.split(" -", 1)[0].endswith("/WindowServer")), None)


class PowerWindow:
    """The reads of one attributed window around the caller's idle sleep, in four steps so that a caller with its
    own counter bracket keeps both brackets clean:

      prepare()  the subprocesses (ps, `sudo -n` for WindowServer) and the coalition ids: before the caller's
                 first counter reads
      begin()    the counter burst (libproc and coalition reads, no subprocess): just before the sleep
      end()      the counter burst: just after it
      finish()   processes that started in the window and WindowServer's end read: after the caller's last
                 counter reads; returns the raw reads attribute() takes

    No subprocess runs between begin() and end(), so a bench in the instance's coalition adds no exited task to
    its total, and none runs inside the caller's bracket."""

    def __init__(self, main_pid: int, pids, classify, reader: Reader | None = None):
        self.main_pid, self.pids, self.classify = main_pid, pids, classify  # pids(): {pid: command} now; classify(cmd, pid): a kind
        self.reader = reader or Reader()

    def prepare(self):
        table = self.reader.process_table()
        self.ws_pid = window_server_pid(table)
        self.ws0 = (self.reader.clock(), self.reader.root_usage(self.ws_pid))
        self.commands = dict(self.pids())
        self.cid = self.reader.coalition_id(self.main_pid)
        self.foreign = {pid for pid in self.commands if self.cid is None or self.reader.coalition_id(pid) != self.cid}
        self.outside = [pid for pid, _ppid, _cmd in table
                        if self.cid is not None and pid not in self.commands and self.reader.coalition_id(pid) == self.cid]

    def begin(self):
        self.first = self._read()

    def end(self):
        self.last = self._read()

    def _read(self):
        """Counters of the instance, the coalition and its outside members, in one burst with no subprocess."""
        at = self.reader.clock()
        coalition = self.reader.coalition_usage(self.cid) if self.cid is not None else None
        usage = {pid: self.reader.usage(pid) for pid in list(self.commands) + self.outside}
        threads = {pid: self.reader.threads(pid) for pid in self.commands}
        return {"at": at, "coalition": coalition, "usage": usage, "threads": threads}

    def finish(self) -> dict:
        """The window's raw reads (attribute() turns them into owners)."""
        last = self.last
        # Processes that started inside the window count from zero (read after the burst: ps is a subprocess).
        for pid, cmd in self.pids().items():
            if pid not in self.commands:
                self.commands[pid] = cmd
                last["usage"][pid] = self.reader.usage(pid)
                last["threads"][pid] = self.reader.threads(pid)
                if self.cid is None or self.reader.coalition_id(pid) != self.cid:
                    self.foreign.add(pid)
        ws1 = (self.reader.clock(), self.reader.root_usage(self.ws_pid))
        return {"first": self.first, "last": last, "commands": self.commands, "foreign": self.foreign,
                "outside": self.outside, "ws": (self.ws0, ws1), "classify": self.classify}


# ---------------------------------------------------------------------------------------------------------
# Arithmetic (pure)

# Chromium process kinds of cmux (idle-budget's `kind`) to Chrome's (idle-budget's `chrome_kind`), so the same work
# compares: the app with its in-process CEF browser and the Chromium Host are Chrome's browser process; Chrome's
# utility processes are one kind.
COMPARE_ROLES = {"app": "browser", "cef-host": "browser", "cef-renderer": "renderer", "cef-extension": "extension",
                 "cef-gpu": "gpu", "cef-network": "utility", "cef-storage": "utility", "cef-audio": "utility",
                 "cef-utility": "utility", "cef-helper": "other"}


def compare_key(owner: str) -> str:
    """An owner's key against the other browser: `cef-renderer/main` -> `renderer/main`."""
    kind, _, rest = owner.partition("/")
    return f"{COMPARE_ROLES.get(kind, kind)}/{rest.split(' (', 1)[0]}"


def process_power(first: procs.Usage | None, last: procs.Usage, elapsed: float) -> dict:
    """mW of one process over the window; one that started inside it counts from zero."""
    first = first or procs.Usage()
    rate = lambda a, b: (a - b) / 1e6 / elapsed  # noqa: E731 - nJ over the window to mW
    own = rate(last.energy_nj, first.energy_nj)
    billed = rate(last.billed_energy_nj, first.billed_energy_nj)
    serviced = rate(last.serviced_energy_nj, first.serviced_energy_nj)
    return {"mw": round(own + billed - serviced, 3), "own_mw": round(own, 3), "billed_mw": round(billed, 3),
            "serviced_mw": round(serviced, 3), "cpu_ns": last.cpu_ns - first.cpu_ns,
            "wakeups_per_s": round((last.interrupt_wakeups - first.interrupt_wakeups) / elapsed, 3)}


def thread_split(own_mw: float, cpu_ns: int, before: dict, after: dict, elapsed: float) -> list[dict]:
    """The process's own mW per thread by CPU time in the window; `cpu_ns` is the process's (rusage) CPU in it.

    `before`/`after` are thread_cpu reads. The lowest thread id is the main thread (`main`, in every process,
    so CrBrowserMain, CrRendererMain and an AppKit main thread compare). CPU of threads that exited in the
    window (the process's less its live threads') is one unnamed `exited threads` row."""
    if not after or elapsed <= 0:
        return []
    main = min(after)
    rows, live_ns = [], 0
    for tid, (cpu, name) in after.items():
        ran = cpu - before.get(tid, (0, name))[0]
        if ran <= 0:
            continue
        live_ns += ran
        label = "main" if tid == main else name
        rows.append({"tid": tid, "name": label, "named": bool(label), "cpu_ns": ran})
    total_ns = max(cpu_ns, live_ns)
    if total_ns <= 0:
        return []
    if total_ns > live_ns:
        rows.append({"tid": None, "name": "exited threads", "named": False, "cpu_ns": total_ns - live_ns})
    for row in rows:
        row["mw"] = round(own_mw * row["cpu_ns"] / total_ns, 3)
        row["cpu_ms_per_s"] = round(row.pop("cpu_ns") / 1e6 / elapsed, 3)
    return sorted(rows, key=lambda row: -row["mw"])


def owners(processes: list[dict]) -> list[dict]:
    """The instance's owners, most mW first, summing to the processes' mW.

    `processes`: [{pid, kind, power (process_power), threads (thread_split)}]. An owner is `<kind>/<thread>`
    summed over the processes of one kind (a role's main threads are one owner), `<kind>/billed` (what other
    processes spent for it) and `<kind>/serviced` (negative: what it spent for others, inside its threads).
    Unnamed (`named` false) owners, each one row per kind so that energy spread thin is still seen whole:
    `<kind>/unnamed threads` (live threads with no pthread name, GCD and Swift concurrency workers; `threads`
    lists each one's pid, tid and mW, for name_threads), `<kind>/exited threads` and `<kind>/process` (energy
    with no thread read, or no CPU to split it by)."""
    merged: dict[str, dict] = {}

    def add(key: str, mw: float, pid: int, named: bool = True, thread: dict | None = None):
        entry = merged.setdefault(key, {"owner": key, "mw": 0.0, "named": named, "pids": []})
        entry["mw"] = round(entry["mw"] + mw, 3)
        entry["named"] = entry["named"] and named
        entry["pids"] = sorted(set(entry["pids"]) | {pid})
        if thread is not None:
            entry.setdefault("threads", []).append(thread)

    for process in processes:
        power, kind, pid = process["power"], process["kind"], process["pid"]
        threads = process.get("threads") or []
        for thread in threads:
            if thread["named"]:
                add(f"{kind}/{thread['name']}", thread["mw"], pid)
            elif thread["tid"] is None:
                add(f"{kind}/exited threads", thread["mw"], pid, named=False)
            else:
                add(f"{kind}/unnamed threads", thread["mw"], pid, named=False,
                    thread={"pid": pid, "tid": thread["tid"], "mw": thread["mw"]})
        unsplit = power["own_mw"] - sum(thread["mw"] for thread in threads)
        if abs(unsplit) >= 0.01:  # no thread read, or no CPU to split the energy by
            add(f"{kind}/process", unsplit, pid, named=False)
        if power["billed_mw"]:
            add(f"{kind}/billed", power["billed_mw"], pid)
        if power["serviced_mw"]:
            add(f"{kind}/serviced", -power["serviced_mw"], pid)
    return sorted(merged.values(), key=lambda entry: -entry["mw"])


def name_threads(entries: list[dict], pid: int, labels: dict[int, str]) -> list[dict]:
    """Moves each of `pid`'s unnamed threads that a stack sample labels ({tid: label}) out of its kind's
    `unnamed threads` owner into the named owner `<kind>/<label>` (threads with one label are one owner); an
    unnamed owner left with no thread goes. Returns the entries, most mW first."""
    by_owner = {entry["owner"]: entry for entry in entries}
    for entry in [e for e in entries if e.get("threads") and not e["named"]]:
        kind = entry["owner"].rsplit("/", 1)[0]
        keep = []
        for thread in entry["threads"]:
            label = labels.get(thread["tid"]) if thread["pid"] == pid else None
            if not label:
                keep.append(thread)
                continue
            key = f"{kind}/{label}"
            named = by_owner.get(key)
            if named is None:
                named = by_owner[key] = {"owner": key, "mw": 0.0, "named": True, "pids": [], "sampled": True}
                entries.append(named)
            named["mw"] = round(named["mw"] + thread["mw"], 3)
            named["pids"] = sorted(set(named["pids"]) | {pid})
            named.setdefault("tids", []).append(thread["tid"])
            entry["mw"] = round(entry["mw"] - thread["mw"], 3)
        entry["threads"] = keep
        entry["pids"] = sorted({thread["pid"] for thread in keep})
        if not keep:
            entries.remove(entry)
    entries.sort(key=lambda entry: -entry["mw"])
    return entries


def unnamed(entries: list[dict], floor: float = FLOOR_MW) -> list[dict]:
    """Owners at or above `floor` without a name (the acceptance: none)."""
    return [entry for entry in entries if entry["mw"] >= floor and not entry["named"]]


# Blocking calls: a sample under one is a thread asleep, not work.
_WAITS = ("mach_msg", "__psynch_cvwait", "__workq_kernreturn", "kevent", "__semwait", "__select", "__ulock_wait",
          "__CFRunLoopServiceMachPort")
# Thread entry and run-loop frames: on every stack of a thread, so never its label (the work under them counts).
_ENTRIES = ("start_wqthread", "thread_start", "_pthread_start", "_pthread_wqthread", "_dispatch_worker_thread",
            "_dispatch_workloop_worker_thread", "__CFRunLoopRun", "CFRunLoopRunSpecific")


def sample_labels(text: str) -> dict[int, str]:
    """{thread id: label} from `/usr/bin/sample` output (its Thread_<id> is the PROC_PIDLISTTHREADIDS id): the
    thread's dispatch queue or pthread name from its header, else `top <frame>`: the deepest frame that holds the
    most of the thread's work, its samples whose stack runs under no wait (_WAITS). A wait under the run-loop
    frame (RunLoop::Run > kevent64) adds nothing to the run loop's work, so the frame that does the work wins."""
    graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
    labels: dict[int, str] = {}
    current, roots, stack = None, [], []  # stack: the open frames [(indent, node)]

    def close():
        best = _busiest(roots)
        if current is not None and current not in labels and best:
            labels[current] = f"top {best}"

    for line in graph.splitlines():
        head = re.match(r"\s{4}\d+ Thread_(\d+)(.*)", line)
        if head:
            close()
            current, roots, stack = int(head.group(1)), [], []
            name = re.sub(r"\s+", " ", head.group(2).strip(" :")).replace(" (serial)", "").replace(" (concurrent)", "")
            name = re.sub(r"^DispatchQueue_\d+: ", "", name).strip()
            if name:
                labels[current] = name
            continue
        frame = re.match(r"([\s+!:|]*)(\d+) (.+?)(?:\s+\(in ([^)]+)\).*)?$", line)
        if current is None or not frame:
            continue
        indent, symbol = len(frame.group(1)), frame.group(3).strip()
        node = {"name": f"{symbol} ({frame.group(4)})" if frame.group(4) else symbol, "count": int(frame.group(2)),
                "wait": any(wait in symbol for wait in _WAITS), "entry": any(entry in symbol for entry in _ENTRIES),
                "children": []}
        while stack and stack[-1][0] >= indent:
            stack.pop()
        (stack[-1][1]["children"] if stack else roots).append(node)
        stack.append((indent, node))
    close()
    return labels


def _busiest(roots: list[dict]) -> str | None:
    """The deepest frame with the most work (samples under no wait) of one thread's call tree, entry frames
    excluded; None when the thread did no work."""
    def work(node: dict, waiting: bool) -> int:
        waiting = waiting or node["wait"]  # every sample under a wait is asleep
        inner = sum(work(child, waiting) for child in node["children"])
        own = max(0, node["count"] - sum(child["count"] for child in node["children"]))
        node["work"] = 0 if waiting else own + inner
        return node["work"]

    for root in roots:
        work(root, False)
    best = None  # (work, depth, name)
    pending = [(root, 0) for root in roots]
    while pending:
        node, depth = pending.pop()
        if node["work"] > 0 and not node["entry"] and (best is None or (node["work"], depth) > best[:2]):
            best = (node["work"], depth, node["name"])
        pending += [(child, depth + 1) for child in node["children"]]
    return best[2] if best else None


def breakdown(owned_mw: float, coalition: dict | None, outside_mw: float, foreign_mw: float) -> dict:
    """The owners' sum against the measured total: the coalition's billed mW (procs.coalition_rates) less its
    members outside the instance plus the instance's processes outside it."""
    result = {"sum_mw": round(owned_mw, 3), "total_mw": None, "ratio": None, "within": None}
    if coalition is None:
        result["note"] = "no coalition total"
        return result
    total = round(coalition["energy_mw_billed"] - outside_mw + foreign_mw, 3)
    result.update({"total_mw": total, "coalition_mw": coalition["energy_mw_billed"], "outside_mw": round(outside_mw, 3),
                   "foreign_mw": round(foreign_mw, 3)})
    if total <= 0:
        result["within"] = abs(owned_mw) <= 1e-3
        return result
    result["ratio"] = round(owned_mw / total, 3)
    result["within"] = abs(owned_mw - total) <= TOLERANCE * total
    return result


def window_server_power(ws) -> dict | None:
    """WindowServer's mW over its window from two (time, procs.Usage) reads, or None without the root reads."""
    (t0, first), (t1, last) = ws
    if first is None or last is None or t1 <= t0:
        return None
    got = process_power(first, last, t1 - t0)
    return {"own_mw": got["own_mw"], "serviced_mw": got["serviced_mw"], "mw": got["mw"],
            "cpu_pct": round(100 * got["cpu_ns"] / 1e9 / (t1 - t0), 3)}


def attribute(raw: dict, floor: float = FLOOR_MW) -> dict:
    """Owners, breakdown and WindowServer of one PowerWindow.end() read."""
    first, last = raw["first"], raw["last"]
    elapsed = last["at"] - first["at"]
    processes = []
    for pid, cmd in sorted(raw["commands"].items()):
        end = last["usage"].get(pid)
        if end is None or elapsed <= 0:
            continue  # gone before the end read: its energy is the breakdown's gap
        power = process_power(first["usage"].get(pid), end, elapsed)
        threads = thread_split(power["own_mw"], power["cpu_ns"], first["threads"].get(pid) or {},
                               last["threads"].get(pid) or {}, elapsed)
        processes.append({"pid": pid, "kind": raw["classify"](cmd, pid), "power": power, "threads": threads})
    outside = sum(process_power(first["usage"].get(pid), last["usage"][pid], elapsed)["mw"]
                  for pid in raw["outside"] if last["usage"].get(pid) is not None)
    foreign = sum(p["power"]["mw"] for p in processes if p["pid"] in raw["foreign"])
    coalition = procs.coalition_rates(first["coalition"], last["coalition"], elapsed) if elapsed > 0 else None
    entries = owners(processes)
    return {"seconds": round(elapsed, 1), "owners": entries,
            "breakdown": breakdown(sum(p["power"]["mw"] for p in processes), coalition, outside, foreign),
            "window_server": window_server_power(raw["ws"]),
            "processes": [{"pid": p["pid"], "kind": p["kind"], **{k: v for k, v in p["power"].items() if k != "cpu_ns"}}
                          for p in processes]}


def power_over(entries: list[dict], reference: list[dict] | None, floor: float = FLOOR_MW) -> list[dict]:
    """The owner groups (compare_key) at or above `floor` that spend more than the reference browser's same
    group, or that it does not have; most mW first. A group of one owner keeps that owner's own name (its sample
    label included). None reference: nothing to compare (no rows)."""
    if reference is None:
        return []
    ref: dict[str, float] = {}
    for entry in reference:
        ref[compare_key(entry["owner"])] = ref.get(compare_key(entry["owner"]), 0.0) + entry["mw"]
    groups: dict[str, dict] = {}
    for entry in entries:
        group = groups.setdefault(compare_key(entry["owner"]), {"mw": 0.0, "owners": []})
        group["mw"] = round(group["mw"] + entry["mw"], 3)
        group["owners"].append(entry["owner"])
    out = []
    for key, group in groups.items():
        other = ref.get(key)
        if group["mw"] >= floor and (other is None or group["mw"] > other):
            name = group["owners"][0] if len(group["owners"]) == 1 else key
            out.append({"owner": name, "mw": group["mw"], "reference_mw": None if other is None else round(other, 3),
                        "from": group["owners"]})
    return sorted(out, key=lambda row: -row["mw"])


def frame_clients(before: dict, after: dict, elapsed: float) -> dict:
    """What can tick in an idle window, from reads at its two ends.

    FrameScheduler clients (debug.wakeups `before`/`after`): every ledger owner with reason `frame` that grew,
    per second; each FrameScheduler that made frames, with its active clients; the clients active at the two
    ends. What was not read is named in `not_covered`."""
    counts = {e.get("owner"): e.get("count", 0) for e in (before.get("ledger") or []) if e.get("reason") == "frame"}
    ticked = []
    for entry in after.get("ledger") or []:
        if entry.get("reason") != "frame" or elapsed <= 0:
            continue
        delta = entry.get("count", 0) - counts.get(entry.get("owner"), 0)
        if delta > 0:
            ticked.append({"owner": entry.get("owner"), "per_s": round(delta / elapsed, 3)})
    frames0 = {s.get("name"): s.get("frames", 0) for s in before.get("frame_schedulers") or []}
    schedulers = []
    for scheduler in after.get("frame_schedulers") or []:
        delta = scheduler.get("frames", 0) - frames0.get(scheduler.get("name"), scheduler.get("frames", 0))
        if delta > 0 and elapsed > 0:
            schedulers.append({"name": scheduler.get("name"), "frames_per_s": round(delta / elapsed, 3),
                               "active_clients": scheduler.get("active_clients", [])})
    out = {"ticked": sorted(ticked, key=lambda e: -e["per_s"]), "schedulers": schedulers,
           "active_start": before.get("active_frame_clients", []), "active_end": after.get("active_frame_clients", [])}
    not_covered = []
    if not before.get("ledger") and not after.get("ledger"):
        not_covered.append("FrameScheduler clients: the build has no debug.wakeups ledger")
    out["not_covered"] = not_covered
    return out


def report_lines(session: str, power: dict, floor: float = FLOOR_MW) -> list[str]:
    """POWER-BREAKDOWN, POWER-OWNER (each owner at or above `floor`, and the rest summed), POWER-UNNAMED and
    POWER-WINDOWSERVER lines of one session."""
    lines = [f"POWER-BREAKDOWN {session} " + json.dumps(power["breakdown"])]
    big = [entry for entry in power["owners"] if abs(entry["mw"]) >= floor]
    for entry in big:
        lines.append(f"POWER-OWNER {session} {entry['owner']} {entry['mw']} mW" + ("" if entry["named"] else " unnamed"))
    rest = round(sum(entry["mw"] for entry in power["owners"]) - sum(entry["mw"] for entry in big), 3)
    lines.append(f"POWER-OWNER {session} (owners under {floor:g} mW) {rest} mW")
    lines += [f"POWER-UNNAMED {session} {entry['owner']} {entry['mw']} mW pids={entry['pids']}" for entry in unnamed(power["owners"], floor)]
    lines.append(f"POWER-WINDOWSERVER {session} " + json.dumps(power["window_server"]))
    return lines


def over_lines(rows: list[dict]) -> list[str]:
    """POWER-OVER <owner> <mW> lines (power_over's rows)."""
    return [f"POWER-OVER {row['owner']} {row['mw']} mW chrome={'none' if row['reference_mw'] is None else row['reference_mw']}"
            f" from={','.join(row['from'])}" for row in rows]


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "rusage":
    got = procs.usage(int(sys.argv[2]))
    print(json.dumps(None if got is None else dataclasses.asdict(got)))
