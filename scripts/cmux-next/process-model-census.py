#!/usr/bin/env python3
"""Process census of a tagged cmux-next app (p01-process task 004, plans/cmux-next/chrome-parity/p01-process.md).

Finds the tagged app and every process of its process model, by executable path and owner, never by name:

  app              the app's own process (`<bundle>/Contents/MacOS/<exe>`)
  daemon           `<bundle>/Contents/Resources/bin/cmux-tui` or `bin/cmux` (cmux-tui is a symlink to cmux, and
                   proc_pidpath reads the resolved file) running the owner's argv (`--headless --session
                   cmux-app[-<tag>]`, local_owner.rs spawn_detached_owner, or `server run`): not a host or holder,
                   not the Chief daemon (`--session cmux-chief`), not a CLI call or `link serve`
  holder           `cmux-holder` (a host-exe copy) or the built-in `__holder`, owned by this tag
  terminal_host    `__terminal-host`, owned by this tag (`--owner <bundle>:<tag>@<daemon pid>`) or under its daemon
  chromium_host    `<bundle>/Contents/MacOS/<product> Chromium Host`
  chromium_helper  `<bundle>/Contents/Frameworks/<product> Helper*.app/...` (CEF helpers of the app or the host)
  other            any other process under a cmux process that runs from the bundle (acpmux, cmux-cua, ...)
  children         processes under a cmux process from outside the bundle (shells, agents): reported, never
                   part of cmux's totals

Hosts and the holder are not children of the app (they leave the daemon's session and outlive restarts), so
they are matched by the owner argument the daemon gives them (terminal_host_runtime/unix/host_session.rs,
`host_owner_args`): `:<tag>@` for a tagged build, else `@<daemon pid>`. The bundle matches in both spellings
(`/tmp/...` and `/private/tmp/...`): the app runs from the real path, its daemons keep the one they were given.

Per role: processes, threads, a thread-name histogram (digits folded to `<n>`, so `surface-12-reader` and
`surface-13-reader` are one name), thread QoS, RSS, phys_footprint (Chrome's private footprint on macOS,
services/resource_coordinator/public/cpp/memory_instrumentation/os_metrics_mac.cc) and unique memory: each
process's private resident pages plus each shared anonymous VM object (terminal rings, shared memory) once
across all roles, keyed by its VM object id, as Chrome's memory-infra counts a shared memory segment once
(base/memory/shared_memory_tracker.cc). File-backed shared pages (code, the dyld cache) are the system's and
not counted. Memory is known only when every counted process was read: a missing footprint or region walk
(`--no-regions`, a walk that failed) makes the sums null, never a partial number; `memory` in the report says
which pids lack what. `per_hidden_terminal_mb` is the growth of all roles' unique memory over a baseline census
of the same build, per added hidden terminal (`--baseline`, or for `--session heavy` a census taken before the
session is built). With no baseline it is null; `terminal_roles_unique_mb` is then only the holder's, VT
workers' and terminal hosts' memory, not a per-terminal figure.

Thread QoS on macOS comes from proc_pidinfo(PROC_PIDTHREADINFO): the thread's base priority, which each QoS
class sets (osfmk/kern/thread_policy.c, thread_qos_policy_params: user-interactive 46-47, user-initiated 37,
default 31, utility 20, background 4); a relative priority below the class base reads as the class below
it. Linux has no QoS (`-`).

Usage:
  process-model-census.py --tag T [--json] [--out F]          census of the running tagged app
  process-model-census.py --app "cmux DEV T.app" --session heavy   launch it, build the heavy session
                                                              (150 workspaces, 172 terminals), census it
  process-model-census.py --tag T --session light             build the light session first
  process-model-census.py --tag T --threads [--by-name]       thread names per role (or over all roles)
  process-model-census.py --tag T --sample-ms 50 --during agent-burst      peaks during 200 CLI calls
  process-model-census.py --tag T --sample-ms 50 --during daemon-restart   peaks while the daemon restarts
  process-model-census.py --tag T --check-thread-doc [plans/cmux-next/threading-model.md]
  process-model-census.py --pid P                             any process and its descendants (role app)
  process-model-census.py --from DIR                          a canned or dumped census (--dump DIR writes one)

A census directory (`--from`, `--dump`): ps.txt (`ps -axww -o pid=,ppid=,rss=,args=`), exe.txt
(`pid<TAB>executable path`, what proc_pidpath or /proc/<pid>/exe read; it classifies before argv), threads.txt
(`pid<TAB>qos<TAB>name`), memory.txt (`pid<TAB>footprint_kb<TAB>private_kb<TAB>obj:kb,obj:kb` for shared
anonymous objects; private_kb `-` when the region walk did not run), samples.txt
(`tick<TAB>pid<TAB>ppid<TAB>threads<TAB>args`), session.json ({bundle, tag, app_pid, terminals,
hidden_terminals, regions, build}). Only ps.txt is required.

`--check-thread-doc` lists each observed cmux thread name that the doc does not list, in its "Registered threads
and queues" section or in the first cell of its owner table (`| Thread / queue | ... | QoS | ...`, where the
Rust daemon's threads are), with the guardrails.py `thread-doc` rule's matching (`<x>` in a label is a
wildcard; a `-fanout` after a label and a `+` extends it), and each name whose QoS differs from the doc's: the QoS
written after a section label (`label` (user-initiated)), or the row's QoS cell when it names one class
(`not set` names none). Every named
thread of the Rust processes is cmux's; in the app and the Chromium Host only names that start with `cmux` or
`com.cmux` are (the rest are AppKit's and Chromium's). Exit 1 when any is found.

Exit status: 0, 1 when `--check-thread-doc` finds an unlisted name or a QoS mismatch, 2 when the census cannot
run (no app, a session that did not build, a socket that does not answer).

Runs on the fleet (`cmux-ci run`), never in CI. Stdlib only; macOS through libproc (ctypes), Linux through /proc.
"""
from __future__ import annotations

import argparse
import collections
import ctypes
import importlib.util
import json
import os
import platform
import re
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
THREAD_DOC = os.path.join(ROOT, "plans/cmux-next/threading-model.md")
THREAD_DOC_SECTION = "## Registered threads and queues"
THREAD_DOC_TABLE = "thread / queue"  # the owner table's first header cell
ROLES = ("app", "daemon", "holder", "terminal_host", "chromium_host", "chromium_helper", "other")
CMUX_ROLES = ROLES  # what totals count; `children` (shells, agents) never
TERMINAL_ROLES = ("holder", "terminal_host")
RUST_ROLES = ("daemon", "holder", "terminal_host")
HOST_ARG, HOLDER_ARG, OWNER_FLAG = "__terminal-host", "__holder", "--owner"
TERMINAL_ARGS = {HOST_ARG, HOLDER_ARG}
CHIEF_SESSION = "cmux-chief"
# macOS links /tmp, /var and /etc into /private; proc_pidpath returns the /private spelling.
PRIVATE_ROOTS = ("/tmp/", "/var/", "/etc/")
QOS_NAMES = ("user-interactive", "user-initiated", "default", "utility", "background")
BURST_CALLS, BURST_PARALLEL = 200, 50
MB = 1024.0


class CensusError(RuntimeError):
    """The census cannot run: no such app, a socket that does not answer, a platform it cannot read."""


class Proc:
    """One process: the ps row, then what a collector or a census directory adds."""

    def __init__(self, pid, ppid, rss_kb, args, exe=None):
        self.pid, self.ppid, self.rss_kb, self.args, self.exe = pid, ppid, rss_kb, args, exe
        self.threads = None        # [(name, qos)] or None when not read
        self.thread_count = None   # from the task info when the names were not read
        self.footprint_kb = None
        self.private_kb = None
        self.shared = {}           # shared anonymous VM object id -> resident KiB

    @property
    def command(self):
        """The executable path when known, else the command line (argv[0] is the path for cmux's processes)."""
        return self.exe or self.args

    def nthreads(self):
        if self.threads is not None:
            return len(self.threads)
        return self.thread_count


# ------------------------------------------------------------------ census directories (the fixture format)

def parse_ps(text):
    procs = []
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        procs.append(Proc(int(parts[0]), int(parts[1]), int(parts[2]), parts[3] if len(parts) > 3 else ""))
    return procs


def read_dir(path):
    """(procs, session, samples) from a census directory."""
    def text(name):
        full = os.path.join(path, name)
        if not os.path.exists(full):
            return None
        with open(full, encoding="utf-8") as handle:
            return handle.read()

    ps = text("ps.txt")
    if ps is None:
        raise CensusError(f"{path} has no ps.txt")
    procs = parse_ps(ps)
    by_pid = {p.pid: p for p in procs}
    exes = {}
    for line in (text("exe.txt") or "").splitlines():
        pid, _, exe = line.partition("\t")
        if pid.strip().isdigit() and exe:
            exes[int(pid)] = exe
    for p in procs:
        p.exe = exes.get(p.pid)
    threads = text("threads.txt")
    if threads is not None:
        for p in procs:
            p.threads = []
        for line in threads.splitlines():
            parts = line.split("\t", 2)
            if len(parts) < 2 or not parts[0].strip().isdigit():
                continue
            proc = by_pid.get(int(parts[0]))
            if proc is not None:
                proc.threads.append((parts[2] if len(parts) > 2 else "", parts[1] or "-"))
    memory = text("memory.txt")
    for line in (memory or "").splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or not parts[0].strip().isdigit():
            continue
        proc = by_pid.get(int(parts[0]))
        if proc is None:
            continue
        proc.footprint_kb = int(parts[1])
        proc.private_kb = None if parts[2].strip() == "-" else int(parts[2])
        for item in (parts[3] if len(parts) > 3 else "").split(","):
            if ":" in item:
                obj, kb = item.rsplit(":", 1)
                proc.shared[obj.strip()] = int(kb)
    session = json.loads(text("session.json") or "{}")
    samples = collections.OrderedDict()
    for line in (text("samples.txt") or "").splitlines():
        parts = line.split("\t", 4)
        if len(parts) < 4 or not parts[0].strip().isdigit():
            continue
        tick = int(parts[0])
        proc = Proc(int(parts[1]), int(parts[2]), 0, parts[4] if len(parts) > 4 else "", exes.get(int(parts[1])))
        proc.thread_count = int(parts[3])
        samples.setdefault(tick, []).append(proc)
    return procs, session, list(samples.values())


def write_dir(path, procs, session, samples):
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "ps.txt"), "w", encoding="utf-8") as handle:
        for p in procs:
            handle.write(f"{p.pid} {p.ppid} {p.rss_kb or 0} {p.args}\n")
    exes = {p.pid: p.exe for table in [procs] + list(samples or []) for p in table if p.exe}
    with open(os.path.join(path, "exe.txt"), "w", encoding="utf-8") as handle:
        for pid, exe in sorted(exes.items()):
            handle.write(f"{pid}\t{exe}\n")
    with open(os.path.join(path, "threads.txt"), "w", encoding="utf-8") as handle:
        for p in procs:
            for name, qos in p.threads or []:
                handle.write(f"{p.pid}\t{qos}\t{name}\n")
    with open(os.path.join(path, "memory.txt"), "w", encoding="utf-8") as handle:
        for p in procs:
            if p.footprint_kb is not None:
                shared = ",".join(f"{obj}:{kb}" for obj, kb in sorted(p.shared.items()))
                private = "-" if p.private_kb is None else p.private_kb
                handle.write(f"{p.pid}\t{p.footprint_kb}\t{private}\t{shared}\n")
    if samples:
        with open(os.path.join(path, "samples.txt"), "w", encoding="utf-8") as handle:
            for tick, table in enumerate(samples):
                for p in table:
                    handle.write(f"{tick}\t{p.pid}\t{p.ppid}\t{p.thread_count or 0}\t{p.args}\n")
    with open(os.path.join(path, "session.json"), "w", encoding="utf-8") as handle:
        json.dump(session, handle, indent=1)


# ------------------------------------------------------------------ live collectors

def qos_of_priority(priority):
    """The QoS class whose base priority the thread runs at (thread_policy.c qos_pri)."""
    if priority >= 46:
        return "user-interactive"
    if priority >= 37:
        return "user-initiated"
    if priority >= 31:
        return "default"
    if priority >= 20:
        return "utility"
    return "background"


class Darwin:
    """libproc through ctypes: the process table, thread names and base priorities, task memory, regions."""

    PROC_ALL_PIDS = 1
    PROC_PIDTBSDINFO, PROC_PIDTASKINFO, PROC_PIDTHREADINFO, PROC_PIDLISTTHREADS = 3, 4, 5, 6
    PROC_PIDREGIONPATHINFO = 8
    BSDINFO_SIZE, TASKINFO_SIZE, THREADINFO_SIZE = 136, 96, 112
    REGIONPATHINFO_SIZE = 1272          # proc_regioninfo (96) + vnode_info_path (152 + MAXPATHLEN)
    REGION_PATH_OFFSET = 96 + 152
    SHARED_MODES = (4, 5, 7)            # SM_SHARED, SM_TRUESHARED, SM_SHARED_ALIASED
    CTL_KERN, KERN_ARGMAX, KERN_PROCARGS2 = 1, 8, 49

    def __init__(self):
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        lib.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.proc_listallpids.restype = ctypes.c_int
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        lib.proc_pidpath.restype = ctypes.c_int
        lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        lib.proc_pid_rusage.restype = ctypes.c_int
        lib.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                               ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        lib.sysctl.restype = ctypes.c_int
        self.lib = lib
        self.page_kb = os.sysconf("SC_PAGE_SIZE") // 1024
        self.uid = os.getuid()
        self.cache = {}  # (pid, start) -> (exe, args): a pid the table saw keeps its command line
        self.argmax = self._argmax()

    def _pidinfo(self, pid, flavor, arg, size):
        buf = ctypes.create_string_buffer(size)
        n = self.lib.proc_pidinfo(pid, flavor, arg, buf, size)
        return buf.raw[:n] if n > 0 else None

    def _argmax(self):
        mib = (ctypes.c_int * 2)(self.CTL_KERN, self.KERN_ARGMAX)
        value = ctypes.c_int(0)
        size = ctypes.c_size_t(ctypes.sizeof(value))
        if self.lib.sysctl(mib, 2, ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
            return 1 << 20
        return value.value

    def _args(self, pid):
        mib = (ctypes.c_int * 3)(self.CTL_KERN, self.KERN_PROCARGS2, pid)
        buf = ctypes.create_string_buffer(self.argmax)
        size = ctypes.c_size_t(self.argmax)
        if self.lib.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0 or size.value < 4:
            return ""
        raw = buf.raw[:size.value]
        argc = struct.unpack_from("<i", raw, 0)[0]
        rest = raw[4:]
        end = rest.find(b"\0")
        rest = rest[end:].lstrip(b"\0") if end >= 0 else b""  # past the exec path and its padding
        argv = rest.split(b"\0")[:argc]
        return " ".join(a.decode("utf-8", "replace") for a in argv)

    def _path(self, pid):
        buf = ctypes.create_string_buffer(4096)
        n = self.lib.proc_pidpath(pid, buf, 4096)
        return buf.raw[:n].decode("utf-8", "replace") if n > 0 else None

    def table(self):
        """This user's processes: pid, ppid, executable path and command line (rss is read by `fill`)."""
        count = self.lib.proc_listallpids(None, 0)
        if count <= 0:
            raise CensusError("proc_listallpids failed")
        pids = (ctypes.c_int * (count + 256))()
        count = self.lib.proc_listallpids(pids, ctypes.sizeof(pids))
        procs, seen = [], set()
        for pid in pids[:max(count, 0)]:
            if pid <= 0:
                continue
            info = self._pidinfo(pid, self.PROC_PIDTBSDINFO, 0, self.BSDINFO_SIZE)
            if not info or len(info) < self.BSDINFO_SIZE:
                continue
            ppid, uid = struct.unpack_from("<II", info, 16)
            if uid != self.uid:
                continue
            key = (pid,) + struct.unpack_from("<QQ", info, 120)
            seen.add(key)
            if key not in self.cache:
                self.cache[key] = (self._path(pid), self._args(pid))
            exe, args = self.cache[key]
            procs.append(Proc(pid, ppid, None, args or exe or "", exe))
        for key in [k for k in self.cache if k not in seen]:
            del self.cache[key]
        return procs

    def thread_count(self, proc):
        info = self._pidinfo(proc.pid, self.PROC_PIDTASKINFO, 0, self.TASKINFO_SIZE)
        if not info or len(info) < self.TASKINFO_SIZE:
            return None
        proc.rss_kb = struct.unpack_from("<Q", info, 8)[0] // 1024
        return struct.unpack_from("<i", info, 84)[0]

    def fill(self, proc, regions=True):
        proc.thread_count = self.thread_count(proc)
        if proc.thread_count is None:
            return
        size = 8 * (proc.thread_count + 64)
        raw = self._pidinfo(proc.pid, self.PROC_PIDLISTTHREADS, 0, size) or b""
        proc.threads = []
        for (handle,) in struct.iter_unpack("<Q", raw[:len(raw) - len(raw) % 8]):
            info = self._pidinfo(proc.pid, self.PROC_PIDTHREADINFO, handle, self.THREADINFO_SIZE)
            if not info or len(info) < self.THREADINFO_SIZE:
                continue  # the thread ended
            priority = struct.unpack_from("<i", info, 40)[0]
            name = info[48:112].split(b"\0", 1)[0].decode("utf-8", "replace")
            proc.threads.append((name, qos_of_priority(priority)))
        usage = ctypes.create_string_buffer(512)
        if self.lib.proc_pid_rusage(proc.pid, 0, usage) == 0:  # RUSAGE_INFO_V0
            proc.footprint_kb = struct.unpack_from("<Q", usage.raw, 72)[0] // 1024
        if regions:
            self._regions(proc)

    def _regions(self, proc):
        """Private resident pages, and each shared anonymous VM object's resident pages by object id."""
        address, private, shared = 0, 0, {}
        buf = ctypes.create_string_buffer(self.REGIONPATHINFO_SIZE)
        while True:
            n = self.lib.proc_pidinfo(proc.pid, self.PROC_PIDREGIONPATHINFO, address, buf, self.REGIONPATHINFO_SIZE)
            if n <= 0:
                break  # past the last region (or the task ended)
            if n != self.REGIONPATHINFO_SIZE:
                raise CensusError(f"proc_regionwithpathinfo is {n} bytes here, the census reads "
                                  f"{self.REGIONPATHINFO_SIZE}")
            fields = struct.unpack_from("<4IQ14I2Q", buf.raw, 0)
            pages_resident, share_mode, private_resident, obj_id = fields[8], fields[14], fields[15], fields[17]
            region_address, region_size = fields[19], fields[20]
            private += private_resident
            if share_mode in self.SHARED_MODES and buf.raw[self.REGION_PATH_OFFSET] == 0:
                key = f"{obj_id:x}"
                shared[key] = max(shared.get(key, 0), pages_resident * self.page_kb)
            if region_size == 0:
                break
            address = region_address + region_size
        proc.private_kb = private * self.page_kb
        proc.shared = shared


class Linux:
    """/proc: the process table, thread names (no QoS on Linux), RSS and anonymous memory."""

    def __init__(self):
        self.page_kb = os.sysconf("SC_PAGE_SIZE") // 1024
        self.uid = os.getuid()
        self.cache = {}  # (pid, start time) -> (exe, args), as Darwin keeps them

    @staticmethod
    def _read(path, mode="r"):
        try:
            with open(path, mode) as handle:
                return handle.read()
        except OSError:
            return None

    def table(self):
        procs, seen = [], set()
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            pid = int(entry)
            try:
                if os.stat(f"/proc/{pid}").st_uid != self.uid:
                    continue
            except OSError:
                continue
            stat = self._read(f"/proc/{pid}/stat")
            if not stat or ")" not in stat:
                continue
            fields = stat.rsplit(")", 1)[1].split()
            ppid, key = int(fields[1]), (pid, fields[19])
            seen.add(key)
            if key not in self.cache:
                cmdline = (self._read(f"/proc/{pid}/cmdline", "rb") or b"").rstrip(b"\0").replace(b"\0", b" ")
                try:
                    exe = os.readlink(f"/proc/{pid}/exe")
                except OSError:
                    exe = None
                self.cache[key] = (exe, cmdline.decode("utf-8", "replace") or exe or "")
            exe, args = self.cache[key]
            procs.append(Proc(pid, ppid, None, args, exe))
        for key in [k for k in self.cache if k not in seen]:
            del self.cache[key]
        return procs

    def thread_count(self, proc):
        statm = self._read(f"/proc/{proc.pid}/statm")
        if statm:
            proc.rss_kb = int(statm.split()[1]) * self.page_kb
        try:
            return len(os.listdir(f"/proc/{proc.pid}/task"))
        except OSError:
            return None

    def fill(self, proc, regions=True):
        proc.thread_count = self.thread_count(proc)
        if proc.thread_count is None:
            return
        proc.threads = []
        for tid in sorted(os.listdir(f"/proc/{proc.pid}/task")) if os.path.isdir(f"/proc/{proc.pid}/task") else []:
            name = self._read(f"/proc/{proc.pid}/task/{tid}/comm")
            if name is not None:
                proc.threads.append((name.rstrip("\n"), "-"))
        status = self._read(f"/proc/{proc.pid}/status") or ""
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        kb = lambda key: int(fields.get(key, "0 kB").split()[0])  # noqa: E731 - one status field in KiB
        proc.footprint_kb = kb("RssAnon") + kb("VmSwap")
        if not regions:
            return
        rollup = self._read(f"/proc/{proc.pid}/smaps_rollup")
        if rollup is None:
            return  # not readable: the region state stays unknown, as a failed walk on macOS
        private = 0
        for line in rollup.splitlines():
            if line.startswith(("Private_Clean:", "Private_Dirty:")):
                private += int(line.split()[1])
        proc.private_kb = private


def collector():
    system = platform.system()
    if system == "Darwin":
        return Darwin()
    if system == "Linux":
        return Linux()
    raise CensusError(f"no process collector for {system}")


# ------------------------------------------------------------------ roles

class Target:
    """What the census looks for: the app's bundle path, its tag, its pid (any may be unknown)."""

    def __init__(self, bundle=None, tag=None, app_pid=None):
        self.bundle = bundle.rstrip("/") if bundle else None
        self.tag, self.app_pid = tag, app_pid

    @staticmethod
    def from_exe(exe, pid=None):
        """The target an app executable path names: `<bundle>.app/Contents/MacOS/<exe>`, tag from `cmux DEV <tag>.app`."""
        if not exe or ".app/Contents/MacOS/" not in exe:
            return Target(app_pid=pid)
        bundle = exe[:exe.index(".app/Contents/MacOS/") + len(".app")]
        name = os.path.basename(bundle)[:-len(".app")]
        tag = name[len("cmux DEV "):] if name.startswith("cmux DEV ") else None
        return Target(bundle, tag or None, pid)

    def owner_tag(self):
        """The tag as the daemon writes it in `--owner` (host_session.rs owner_part)."""
        if not self.tag:
            return None
        return "".join(c if c.isalnum() and c.isascii() or c in "._-" else "_" for c in self.tag[:96])

    def app_session(self):
        """The app daemon's session for the tag (DaemonLauncher.sessionName), or None for an untagged build."""
        if not self.tag:
            return None
        allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        cleaned = "".join(c if c in allowed else "-" for c in self.tag).strip("-.")
        return f"cmux-app-{cleaned}" if cleaned else None

    def roots(self):
        """The bundle path in each spelling a process may run it from: as given, and with or without the
        `/private` prefix macOS resolves /tmp, /var and /etc to."""
        if not self.bundle:
            return []
        roots = [self.bundle]
        if self.bundle.startswith("/private/") and self.bundle[len("/private"):].startswith(PRIVATE_ROOTS):
            roots.append(self.bundle[len("/private"):])
        elif self.bundle.startswith(PRIVATE_ROOTS):
            roots.append("/private" + self.bundle)
        return roots

    def in_bundle(self, path):
        return bool(path) and any(path.startswith(root + "/") for root in self.roots())


def owner_of(args):
    return flag_value(args.split(), OWNER_FLAG)


def flag_value(tokens, flag):
    for index, token in enumerate(tokens):
        if token == flag and index + 1 < len(tokens):
            return tokens[index + 1]
        if token.startswith(flag + "="):
            return token[len(flag) + 1:]
    return None


def runs(command, name):
    """`command` runs the executable `name` (its path ends in it), before any argument."""
    return re.search(r"(^|/)" + re.escape(name) + r"(\s|$)", command) is not None


def is_daemon_argv(tokens, target):
    """The app daemon's argv: the owner `cmux-tui --headless --session S ...` (local_owner.rs
    spawn_detached_owner) or `server run`, in the app's session; not a host, holder or VT worker, not the Chief
    daemon, not a CLI call (`cmux --app-socket ...`) or the cloud link (`link serve`)."""
    if TERMINAL_ARGS & set(tokens):
        return False
    owner = "--headless" in tokens or any(a == "server" and b == "run" for a, b in zip(tokens, tokens[1:]))
    if not owner:
        return False
    session = flag_value(tokens, "--session")
    if session is None:
        return True
    if session == CHIEF_SESSION or session.startswith(CHIEF_SESSION + "-"):
        return False
    expected = target.app_session()
    return expected is None or session == expected


def classify(procs, target):
    """{pid: role} for every process of the target's model; `children` for the user's processes under it.
    Also returns the target with its app pid filled in."""
    by_pid = {p.pid: p for p in procs}
    bundle = target.bundle
    roles = {}
    app_pid = target.app_pid
    if bundle:
        root = "(?:" + "|".join(re.escape(r) for r in target.roots()) + ")"
        main = re.compile(root + r"/Contents/MacOS/(?![^/]* Chromium Host(\s|$))[^/]+")
        host = re.compile(root + r"/Contents/MacOS/[^/]* Chromium Host(\s|$)")
        helper = re.compile(root + r"/Contents/Frameworks/[^/]* Helper[^/]*\.app/Contents/MacOS/")
        # bin/cmux-tui is a symlink to bin/cmux: proc_pidpath reads `cmux`, argv[0] keeps `cmux-tui`.
        daemon = re.compile(root + r"/Contents/Resources/bin/cmux(-tui)?(\s|$)")
        for p in procs:
            command = p.command
            if host.match(command):
                roles[p.pid] = "chromium_host"
            elif helper.match(command):
                roles[p.pid] = "chromium_helper"
            elif (daemon.match(command) or daemon.match(p.args)) and is_daemon_argv(p.args.split(), target):
                roles[p.pid] = "daemon"
            elif app_pid is None and main.match(command):
                app_pid = p.pid
    if app_pid is not None and app_pid in by_pid:
        roles[app_pid] = "app"
    daemons = {pid for pid, role in roles.items() if role == "daemon"}
    owner_tag = target.owner_tag()

    def owned(p):
        owner = owner_of(p.args)
        if not owner:
            return False
        if owner_tag is not None and ":" in owner and owner.split(":", 1)[1].rsplit("@", 1)[0] == owner_tag:
            return True
        return any(owner.endswith(f"@{pid}") for pid in daemons)

    for p in procs:
        if p.pid in roles:
            continue
        tokens = set(p.args.split())
        command = p.command
        if HOST_ARG in tokens:
            role = "terminal_host"
        elif HOLDER_ARG in tokens or runs(command, "cmux-holder"):
            role = "holder"
        else:
            continue
        if owned(p) or under(p, by_pid, {pid for pid, r in roles.items() if r in ("daemon", "holder", "app")}):
            roles[p.pid] = role
    # A host the holder started, with no owner argument of its own.
    for p in procs:
        if p.pid not in roles and HOST_ARG in p.args.split():
            if under(p, by_pid, {pid for pid, r in roles.items() if r in ("daemon", "holder")}):
                roles[p.pid] = "terminal_host"
    cmux = set(roles)
    for p in procs:
        if p.pid in roles:
            continue
        if under(p, by_pid, cmux):
            roles[p.pid] = "other" if target.in_bundle(p.command) else "children"
    return roles, Target(bundle, target.tag, app_pid)


def under(proc, by_pid, ancestors):
    """`proc` descends from a pid in `ancestors` (its ppid chain, bounded against a cycle in stale data)."""
    seen = 0
    pid = proc.ppid
    while pid and pid in by_pid and seen < 64:
        if pid in ancestors:
            return True
        pid = by_pid[pid].ppid
        seen += 1
    return pid in ancestors


def foreign_hosts(procs, roles):
    """Hosts and holders the census did not count (another tag's or an older build's)."""
    count = 0
    for p in procs:
        if p.pid not in roles and (TERMINAL_ARGS & set(p.args.split()) or runs(p.command, "cmux-holder")):
            count += 1
    return count


# ------------------------------------------------------------------ the census

def fold(name):
    """A thread name with its numbers folded: `surface-12-reader` -> `surface-<n>-reader`."""
    if not name:
        return "<unnamed>"
    return re.sub(r"\d+", "<n>", name)


def mb(kb):
    return round(kb / MB, 1) if kb is not None else None


def peaks_of(samples, target):
    """{role: (peak threads, peak processes)} over sampled process tables."""
    peaks = {}
    for table in samples:
        roles, _ = classify(table, target)
        threads, processes = collections.Counter(), collections.Counter()
        for p in table:
            role = roles.get(p.pid)
            if role in CMUX_ROLES:
                threads[role] += p.thread_count or 0
                processes[role] += 1
        for role in CMUX_ROLES:
            old = peaks.get(role, (0, 0))
            peaks[role] = (max(old[0], threads[role]), max(old[1], processes[role]))
    return peaks


def unique_kb(members):
    """Private resident KiB of `members` plus each shared anonymous object once, or None when the region walk of
    any member did not run (a partial sum would read as a measurement)."""
    if any(p.private_kb is None for p in members):
        return None
    shared = {}
    for p in members:
        for obj, kb in p.shared.items():
            shared[obj] = max(shared.get(obj, 0), kb)
    return sum(p.private_kb for p in members) + sum(shared.values())


def footprint_kb(members):
    if any(p.footprint_kb is None for p in members):
        return None
    return sum(p.footprint_kb for p in members)


def census(procs, target, session=None, samples=None, baseline=None, sampling=None):
    session = session or {}
    roles, target = classify(procs, target)
    peaks = peaks_of(samples or [], target)
    by_name = collections.OrderedDict()
    report_roles = {}
    for role in CMUX_ROLES + ("children",):
        members = [p for p in procs if roles.get(p.pid) == role]
        names = collections.Counter()
        qos = collections.Counter()
        for p in members:
            for name, level in p.threads or []:
                names[fold(name)] += 1
                qos[level] += 1
                if role != "children":
                    entry = by_name.setdefault(fold(name), {"count": 0, "roles": collections.Counter(),
                                                             "qos": collections.Counter()})
                    entry["count"] += 1
                    entry["roles"][role] += 1
                    entry["qos"][level] += 1
        threads = sum(p.nthreads() or 0 for p in members)
        unique = unique_kb(members)
        private = None if unique is None else sum(p.private_kb for p in members)
        peak_threads, peak_processes = peaks.get(role, (0, 0))
        report_roles[role] = {
            "processes": len(members),
            "threads": threads,
            "peak_threads": max(threads, peak_threads),
            "peak_processes": max(len(members), peak_processes),
            "rss_mb": mb(sum(p.rss_kb or 0 for p in members)),
            "footprint_mb": mb(footprint_kb(members)),
            "private_mb": mb(private),
            "shared_mb": mb(None if unique is None else unique - private),
            "unique_mb": mb(unique),
            "threads_by_qos": dict(sorted(qos.items())),
            "threads_by_name": dict(names.most_common()),
            "pids": sorted(p.pid for p in members),
        }
    children = report_roles.pop("children")
    cmux = [p for p in procs if roles.get(p.pid) in CMUX_ROLES]
    total_unique = unique_kb(cmux)
    terminal_unique = unique_kb([p for p in cmux if roles[p.pid] in TERMINAL_ROLES])
    hidden = session.get("hidden_terminals")
    per_hidden, basis = None, "no baseline census: pass --baseline (--session heavy takes one before it builds)"
    if baseline:
        base_hidden = (baseline.get("session") or {}).get("hidden_terminals")
        base_unique = (baseline.get("totals") or {}).get("unique_mb")
        if total_unique is None or base_unique is None:
            basis = "unknown: the memory of this census or of its baseline was not read in full"
        elif hidden is None or base_hidden is None:
            basis = "unknown: the hidden terminal count of this census or of its baseline is not known"
        elif hidden <= base_hidden:
            basis = f"unknown: {hidden} hidden terminals, not more than the baseline's {base_hidden}"
        else:
            per_hidden = round((total_unique / MB - base_unique) / (hidden - base_hidden), 2)
            basis = f"all roles, growth over the baseline ({base_hidden} hidden terminals)"
    footprint_missing = sorted(p.pid for p in cmux if p.footprint_kb is None)
    regions_missing = sorted(p.pid for p in cmux if p.private_kb is None)
    per_object = collections.Counter()
    for p in cmux:
        if roles[p.pid] in RUST_ROLES:
            for name, _ in p.threads or []:
                if "<n>" in fold(name):
                    per_object[fold(name)] += 1
    threads_by_name = {name: {"count": e["count"], "roles": dict(e["roles"]), "qos": dict(e["qos"])}
                       for name, e in sorted(by_name.items(), key=lambda item: (-item[1]["count"], item[0]))}
    return {
        "census": 1,
        "host": session.get("host") or platform.node(),
        "os": session.get("os") or f"{platform.system()} {platform.release()}",
        "bundle": target.bundle, "tag": target.tag, "app_pid": target.app_pid,
        "session": {k: session.get(k) for k in ("shape", "terminals", "hidden_terminals", "workspaces", "build")
                    if k in session},
        "roles": report_roles,
        "children": {"processes": children["processes"], "threads": children["threads"], "rss_mb": children["rss_mb"]},
        "threads_by_name": threads_by_name,
        "per_object_threads": dict(per_object.most_common()),
        "per_hidden_terminal_mb": per_hidden,
        "per_hidden_terminal_basis": basis,
        "terminal_roles_unique_mb": mb(terminal_unique),
        "memory": {"regions": session.get("regions"), "footprint_missing_pids": footprint_missing[:32],
                   "regions_missing_pids": regions_missing[:32]},
        "totals": {
            "processes": len(cmux),
            "threads": sum(r["threads"] for r in report_roles.values()),
            "cmux_threads_excluding_helpers": sum(r["threads"] for k, r in report_roles.items() if k != "chromium_helper"),
            "rss_mb": mb(sum(p.rss_kb or 0 for p in cmux)),
            "footprint_mb": mb(footprint_kb(cmux)),
            "unique_mb": mb(total_unique),
            "shared_objects": len({obj for p in cmux for obj in p.shared}),
        },
        "foreign_hosts": foreign_hosts(procs, roles),
        "sampling": sampling,
    }


# ------------------------------------------------------------------ the thread doc

def label_pattern(token):
    """The label as guardrails.py `doc_labels` matches it (`<x>` is a wildcard), or None for a placeholder alone."""
    if len(re.sub(r"<[^>]*>", "", token).strip(" .-_")) < 3:
        return None
    return re.compile("^" + ".+".join(re.escape(part) for part in re.split(r"<[^>]*>", token)) + "$")


def table_qos(cell):
    """The QoS class an owner-table QoS cell names, when it names exactly one (`user-interactive (system)`);
    None for `not set`, several classes or another word."""
    text = re.sub(r"\([^)]*\)", "", cell).strip()
    return text if text in QOS_NAMES else None


def table_labels(text):
    """[(pattern, qos or None)] for the backticked labels in the first cell of each owner-table row (the table
    whose header starts `| Thread / queue |`), with the row's QoS. A label that starts with `-` or `.` after
    another and a `+` extends it (`mux-session-journal-writer` (+ `-fanout`)); after a `/` it replaces the last
    part (`acpmux-socket-read` / `-write` is `acpmux-socket-write`)."""
    labels = []
    qos_column = None
    for line in text.splitlines():
        if not line.lstrip().startswith("|"):
            qos_column = None
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells and cells[0].lower() == THREAD_DOC_TABLE:
            lowered = [cell.lower() for cell in cells]
            qos_column = lowered.index("qos") if "qos" in lowered else -1
            continue
        if qos_column is None or set(line.strip()) <= set("|-: "):
            continue
        qos = table_qos(cells[qos_column]) if 0 <= qos_column < len(cells) else None
        previous, after = None, 0
        for match in re.finditer(r"`([^`\n]+)`", cells[0]):
            token, joint = match.group(1), cells[0][after:match.start()].strip(" (")
            after = match.end()
            if previous and token[0] in "-." and joint == "+":
                token = previous + token
            elif previous and token[0] in "-." and joint == "/":
                token = previous.rsplit(token[0], 1)[0] + token
            else:
                previous = token
            pattern = label_pattern(token)
            if pattern is not None:
                labels.append((pattern, qos))
    return labels


def doc_labels(text):
    """[(pattern, qos or None)] for the labels the thread doc lists: its "Registered threads and queues" section
    (the app's Swift labels), each with the QoS written right after it in parentheses, and its owner table (the
    Rust processes' threads too), each with its row's QoS."""
    labels = []
    start = text.find(THREAD_DOC_SECTION)
    if start >= 0:
        end = text.find("\n## ", start + len(THREAD_DOC_SECTION))
        section = text[start:end if end >= 0 else len(text)]
        for match in re.finditer(r"`([^`\n]+)`(\s*\(([a-z-]+))?", section):
            pattern = label_pattern(match.group(1))
            if pattern is not None:
                labels.append((pattern, match.group(3) if match.group(3) in QOS_NAMES else None))
    table = table_labels(text)
    if start < 0 and not table:
        raise CensusError(f"the thread doc has no \"{THREAD_DOC_SECTION[3:]}\" section and no owner table")
    return labels + table


def check_thread_doc(procs, roles, text):
    """{unlisted: [{name, roles, count}], qos_mismatch: [{name, doc, observed}], judged: N}."""
    labels = doc_labels(text)
    observed = {}
    for p in procs:
        role = roles.get(p.pid)
        if role not in CMUX_ROLES or role == "chromium_helper":
            continue
        for name, qos in p.threads or []:
            if not name or (role not in RUST_ROLES and not re.match(r"(?i)(com\.)?cmux", name)):
                continue
            entry = observed.setdefault(name, {"roles": collections.Counter(), "qos": collections.Counter()})
            entry["roles"][role] += 1
            entry["qos"][qos] += 1
    unlisted, mismatch = collections.OrderedDict(), []
    for name in sorted(observed):
        entry = observed[name]
        # Linux keeps 15 bytes of a thread name: a 15-byte name matches a label it starts.
        found = [qos for pattern, qos in labels if pattern.match(name)
                 or (len(name.encode()) == 15 and pattern.pattern.startswith("^" + re.escape(name)))]
        if not found:
            key = fold(name)
            item = unlisted.setdefault(key, {"name": key, "roles": collections.Counter(), "count": 0})
            item["roles"].update(entry["roles"])
            item["count"] += sum(entry["roles"].values())
            continue
        doc_qos = next((qos for qos in found if qos), None)
        if doc_qos and set(entry["qos"]) - {doc_qos, "-"}:
            mismatch.append({"name": name, "doc": doc_qos, "observed": dict(entry["qos"])})
    return {"judged": len(observed),
            "unlisted": [{"name": i["name"], "roles": dict(i["roles"]), "count": i["count"]} for i in unlisted.values()],
            "qos_mismatch": mismatch}


# ------------------------------------------------------------------ live runs: sessions, sampling, actions

def load_stress():
    path = os.path.join(HERE, "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_teardown():
    sys.path.insert(0, HERE)
    import daemon_teardown  # noqa: E402 - the sibling script, found through HERE
    return daemon_teardown


def candidates(procs, target):
    roles, target = classify(procs, target)
    return [p for p in procs if p.pid in roles], roles, target


def live_snapshot(source, target, regions=True):
    """(processes, target, regions state). A process that ended while it was read leaves the census; a region walk
    that fails stops the walk for the rest (the layout it reads is wrong for this OS), and the state says so."""
    procs = source.table()
    members, roles, target = candidates(procs, target)
    state = "read" if regions else "skipped (--no-regions)"
    alive = []
    for p in members:
        try:
            source.fill(p, regions=regions and roles[p.pid] != "children")
        except CensusError as error:
            print(f"census: memory of pid {p.pid}: {error}", file=sys.stderr)
            state = f"failed at pid {p.pid}: {error}"
            regions = False
        except OSError:
            continue  # the process ended while it was read
        if p.thread_count is not None:
            alive.append(p)
    return alive, target, state


def sample(source, target, interval_ms, action, tail_s=1.0):
    """Process tables every `interval_ms` while `action()` runs on a worker thread, and `tail_s` after it
    returns. Returns (tables, report)."""
    done = threading.Event()
    result = {}

    def run():
        try:
            result["action"] = action()
        except Exception as error:  # noqa: BLE001 - the action's failure is reported with the samples
            result["action"] = {"error": f"{type(error).__name__}: {error}"}
        finally:
            done.set()

    tables = []
    worker = threading.Thread(target=run, name="census-action", daemon=True)
    start = time.monotonic()
    worker.start()
    ended = None
    while True:
        tick = time.monotonic()
        members, _, target_now = candidates(source.table(), target)
        for p in members:
            p.thread_count = source.thread_count(p)
        tables.append(members)
        if done.is_set():
            ended = ended or time.monotonic()
            if time.monotonic() - ended >= tail_s:
                break
        remaining = interval_ms / 1000.0 - (time.monotonic() - tick)
        if remaining > 0:
            time.sleep(remaining)  # test script: the sample interval
    elapsed = time.monotonic() - start
    return tables, {"interval_ms": interval_ms, "samples": len(tables), "duration_s": round(elapsed, 2),
                    "mean_interval_ms": round(1000 * elapsed / max(len(tables), 1), 1), "action": result.get("action")}


def agent_burst(bundle, socket_path, calls=BURST_CALLS, parallel=BURST_PARALLEL):
    """`calls` CLI calls an agent makes (`cmux --app-socket S --json workspace list`), `parallel` at once."""
    cli = os.path.join(bundle, "Contents/Resources/bin/cmux")
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    failures = collections.Counter()
    lock = threading.Lock()
    queue = list(range(calls))

    def worker():
        while True:
            with lock:
                if not queue:
                    return
                queue.pop()
            try:
                code = subprocess.run([cli, "--app-socket", socket_path, "--json", "workspace", "list"], env=env,
                                      capture_output=True, timeout=60, stdin=subprocess.DEVNULL).returncode
            except subprocess.TimeoutExpired:
                code = "timeout"
            if code != 0:
                with lock:
                    failures[str(code)] += 1

    workers = [threading.Thread(target=worker, name=f"census-burst-{i}", daemon=True) for i in range(parallel)]
    start = time.monotonic()
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    return {"calls": calls, "parallel": parallel, "seconds": round(time.monotonic() - start, 2), "failures": dict(failures)}


def daemon_restart(bundle, tag, timeout_s=60.0):
    """Stops the tag's daemon without ending its terminals (`shutdown-daemon`); the app starts the next one and
    it adopts the terminals. Returns when another daemon answers."""
    teardown = load_teardown()
    binary = os.path.join(bundle, "Contents/Resources/bin/cmux-tui")
    status = teardown.daemon_status(binary, tag)
    if status is None:
        raise CensusError(f"tag {tag} has no running daemon")
    identity = teardown.request(status["socket"], {"id": 1, "cmd": "identify"}, 10).get("data", {})
    old = int(identity["pid"])
    reply = teardown.request(status["socket"], {"id": 2, "cmd": "shutdown-daemon", "pid": old,
                                                "generation": identity["generation"], "end_terminals": False}, 90)
    if not reply.get("ok"):
        raise CensusError(f"shutdown-daemon failed: {reply.get('error')}")
    start = time.monotonic()
    while time.monotonic() - start < timeout_s:
        try:
            status = teardown.daemon_status(binary, tag)
            pid = teardown.request(status["socket"], {"id": 3, "cmd": "identify"}, 5).get("data", {}).get("pid") \
                if status else None
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
            pid = None  # between daemons
        if pid not in (None, old):
            return {"old_pid": old, "new_pid": pid, "seconds": round(time.monotonic() - start, 2)}
        time.sleep(0.1)  # test script: poll the daemon's status until the next one answers
    return {"old_pid": old, "new_pid": None, "error": f"no new daemon in {timeout_s:.0f} s"}


def session_counts(socket_path):
    """{terminals, hidden_terminals} of the app's session (snapshot.get, with debug.screens for each window's shown
    screen; an app without debug.screens leaves a workspace of several screens unknown)."""
    stress = load_stress()
    rpc = stress.socket_rpc(socket_path)
    reply = rpc("snapshot.get", timeout=30)
    if not isinstance(reply, dict) or reply.get("error"):
        raise CensusError(f"snapshot.get on {socket_path}: {reply}")
    screens = rpc("debug.screens", timeout=30)
    screens = screens if isinstance(screens, dict) and not screens.get("error") else None
    return stress.terminal_counts(reply.get("topology") or {}, screens)


def build_session(shape, socket_path):
    stress = load_stress()
    builder = stress.Stress(stress.socket_rpc(socket_path))
    try:
        if shape == "heavy":
            return builder.build_heavy()
        workspace, panes = builder.build_light()
        return {"workspace": workspace, "panes": panes}
    except RuntimeError as error:  # StressShapeError, or a tab that did not appear (add_tab)
        raise CensusError(f"the {shape} session did not build: {error}") from error
    finally:
        builder.close()


def pre_session_census(source, target, session, socket_path, regions):
    """The census of the app before the heavy session is built: the baseline its growth per hidden terminal is
    taken over (the same build, the same roles)."""
    before = dict(session)
    before.update(session_counts(socket_path))
    procs, target, before["regions"] = live_snapshot(source, target, regions=regions)
    return census(procs, target, before)


# ------------------------------------------------------------------ output

def text_report(report, threads=False, by_name=False):
    lines = [f"process census: {report.get('bundle') or 'pid'} (app pid {report.get('app_pid')}) on {report['host']}, "
             f"{report['os']}"]
    lines.append(f"{'role':<16}{'procs':>6}{'threads':>9}{'peak':>7}{'rss MB':>10}{'footprint MB':>14}{'unique MB':>11}")
    for role, r in report["roles"].items():
        lines.append(f"{role:<16}{r['processes']:>6}{r['threads']:>9}{r['peak_threads']:>7}{r['rss_mb'] or 0:>10}"
                     f"{r['footprint_mb'] if r['footprint_mb'] is not None else '-':>14}"
                     f"{r['unique_mb'] if r['unique_mb'] is not None else '-':>11}")
    totals = report["totals"]
    lines.append(f"cmux: {totals['processes']} processes, {totals['threads']} threads "
                 f"({totals['cmux_threads_excluding_helpers']} excluding Chromium helpers), unique {totals['unique_mb']} MB; "
                 f"children {report['children']['processes']} processes")
    session = report.get("session") or {}
    if session.get("terminals") is not None:
        lines.append(f"terminals {session.get('terminals')}, hidden {session.get('hidden_terminals')}; "
                     f"per hidden terminal {report['per_hidden_terminal_mb']} MB ({report['per_hidden_terminal_basis']}); "
                     f"terminal roles {report['terminal_roles_unique_mb']} MB")
    memory = report.get("memory") or {}
    if memory.get("regions_missing_pids") or memory.get("footprint_missing_pids"):
        lines.append(f"memory not read in full (regions: {memory.get('regions')}): no region walk for pids "
                     f"{memory.get('regions_missing_pids')}, no footprint for {memory.get('footprint_missing_pids')}")
    if report["per_object_threads"]:
        lines.append("per-object threads: " + ", ".join(f"{n} x{c}" for n, c in report["per_object_threads"].items()))
    if report.get("foreign_hosts"):
        lines.append(f"not counted: {report['foreign_hosts']} hosts, holders or VT workers of another owner")
    if threads and by_name:
        lines.append(f"{'threads':>8}  {'name':<48} roles / qos")
        for name, e in report["threads_by_name"].items():
            roles = ",".join(f"{k}:{v}" for k, v in e["roles"].items())
            qos = ",".join(f"{k}:{v}" for k, v in e["qos"].items())
            lines.append(f"{e['count']:>8}  {name:<48} {roles} / {qos}")
    elif threads:
        for role, r in report["roles"].items():
            if r["threads_by_name"]:
                lines.append(f"{role}: " + ", ".join(f"{n} x{c}" for n, c in r["threads_by_name"].items()))
    doc = report.get("thread_doc")
    if doc:
        lines.append(f"thread doc: {doc['judged']} names judged, {len(doc['unlisted'])} unlisted, "
                     f"{len(doc['qos_mismatch'])} QoS mismatches")
        for item in doc["unlisted"]:
            lines.append(f"  unlisted {item['name']} x{item['count']} ({', '.join(item['roles'])})")
        for item in doc["qos_mismatch"]:
            lines.append(f"  qos {item['name']}: doc {item['doc']}, observed {item['observed']}")
    return "\n".join(lines)


def find_app(procs, tag):
    suffix = f"/cmux DEV {tag}.app/Contents/MacOS/cmux DEV"
    for p in procs:
        if p.exe and p.exe.endswith(suffix):
            return Target.from_exe(p.exe, p.pid)
        if not p.exe and (p.args.endswith(suffix) or suffix + " " in p.args):
            return Target.from_exe(p.args[:p.args.index(suffix) + len(suffix)], p.pid)
    raise CensusError(f"no running app for tag {tag}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a Debug `cmux DEV <tag>.app` to launch (not running), left running with --keep")
    where.add_argument("--tag", help="a running tagged app")
    where.add_argument("--pid", type=int, help="any process: the app role, with its descendants")
    where.add_argument("--from", dest="source", metavar="DIR", help="a census directory (canned or --dump)")
    parser.add_argument("--socket", help="the app's debug socket (default /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--session", choices=("light", "heavy"), help="build this session in the app first")
    parser.add_argument("--settle", type=float, default=5.0, help="seconds after building the session (default 5)")
    parser.add_argument("--json", action="store_true", help="print the census as JSON")
    parser.add_argument("--out", help="write the census JSON here")
    parser.add_argument("--dump", metavar="DIR", help="write the census directory (re-read with --from)")
    parser.add_argument("--threads", action="store_true", help="print thread names per role")
    parser.add_argument("--by-name", action="store_true", help="with --threads: one table over all roles by name")
    parser.add_argument("--sample-ms", type=int, help="sample process tables every N ms for peaks (--during)")
    parser.add_argument("--during", choices=("agent-burst", "daemon-restart"), help="the action the samples cover")
    parser.add_argument("--burst", type=int, default=BURST_CALLS, help="agent-burst CLI calls (default 200)")
    parser.add_argument("--burst-parallel", type=int, default=BURST_PARALLEL, help="agent-burst calls at once (default 50)")
    parser.add_argument("--hidden-terminals", type=int, help="the hidden terminal count, when the census cannot read it")
    parser.add_argument("--baseline", help="an earlier census JSON of the same build: per hidden terminal over all roles")
    parser.add_argument("--no-regions", action="store_true", help="skip the region walk (no private or shared memory)")
    parser.add_argument("--check-thread-doc", nargs="?", const=THREAD_DOC, metavar="DOC",
                        help="check observed thread names and QoS against the doc (default threading-model.md)")
    parser.add_argument("--keep", action="store_true", help="with --app: leave the launched app running")
    opts = parser.parse_args(argv)
    if opts.during and not opts.sample_ms:
        opts.sample_ms = 50
    if opts.source and (opts.session or opts.during):
        parser.error("--session and --during need a live app, not --from")
    if opts.during == "agent-burst" and not (opts.app or opts.tag):
        parser.error("--during agent-burst needs --app or --tag")
    app = None
    baseline, baseline_source = None, "a census before the session was built"
    try:
        samples, sampling = [], None
        if opts.source:
            procs, session, samples = read_dir(opts.source)
            target = Target(session.get("bundle"), session.get("tag"), session.get("app_pid"))
        else:
            source = collector()
            session = {"host": platform.node(), "os": f"{platform.system()} {platform.release()}"}
            if opts.app:
                stress = load_stress()
                out = os.environ.get("NX_ARTIFACTS") or os.path.join("/tmp", "cmux-census")
                os.makedirs(out, exist_ok=True)
                app = stress.load_activation_app()(os.path.abspath(opts.app), out, 50)
                app.launch()
                # The real path: proc_pidpath names every process by it (/private/tmp, symlinks resolved).
                target = Target(os.path.realpath(opts.app), app.tag, app.process.pid)
                socket_path = opts.socket or app.socket
            elif opts.tag:
                target = find_app(source.table(), opts.tag)
                socket_path = opts.socket or f"/tmp/cmux-debug-{opts.tag}.sock"
            else:
                exe = next((p.exe for p in source.table() if p.pid == opts.pid), None)
                target = Target.from_exe(exe, opts.pid)
                target.app_pid = opts.pid
                socket_path = opts.socket or (f"/tmp/cmux-debug-{target.tag}.sock" if target.tag else None)
            if opts.session:
                if not socket_path:
                    raise CensusError("--session needs the app's debug socket (--socket)")
                if opts.session == "heavy" and not opts.baseline:
                    if opts.app:
                        time.sleep(opts.settle)  # test script: the launched app settles before the baseline
                    baseline = pre_session_census(source, target, session, socket_path, not opts.no_regions)
                session["build"] = build_session(opts.session, socket_path)
                session["shape"] = opts.session
                time.sleep(opts.settle)  # test script: the session settles before it is counted
            if socket_path and os.path.exists(socket_path):
                session.update(session_counts(socket_path))
            if opts.during:
                if not target.bundle:
                    raise CensusError("--during needs a tagged app bundle")
                action = (lambda: agent_burst(target.bundle, socket_path, opts.burst, opts.burst_parallel)) \
                    if opts.during == "agent-burst" else (lambda: daemon_restart(target.bundle, target.tag))
                samples, sampling = sample(source, target, opts.sample_ms, action)
                sampling["during"] = opts.during
            procs, target, session["regions"] = live_snapshot(source, target, regions=not opts.no_regions)
            session.update({"bundle": target.bundle, "tag": target.tag, "app_pid": target.app_pid})
        if opts.hidden_terminals is not None:
            session["hidden_terminals"] = opts.hidden_terminals
        if opts.baseline:
            with open(opts.baseline, encoding="utf-8") as handle:
                baseline = json.load(handle)
            baseline_source = opts.baseline
        report = census(procs, target, session, samples, baseline, sampling)
        if baseline:
            report["baseline"] = {"source": baseline_source,
                                  "hidden_terminals": (baseline.get("session") or {}).get("hidden_terminals"),
                                  "unique_mb": (baseline.get("totals") or {}).get("unique_mb")}
        failed = False
        if opts.check_thread_doc:
            with open(opts.check_thread_doc, encoding="utf-8") as handle:
                roles, _ = classify(procs, target)
                report["thread_doc"] = check_thread_doc(procs, roles, handle.read())
            failed = bool(report["thread_doc"]["unlisted"] or report["thread_doc"]["qos_mismatch"])
        if opts.dump:
            write_dir(opts.dump, procs, session, samples)
        if opts.out:
            with open(opts.out, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=1)
        print(json.dumps(report, indent=1) if opts.json else text_report(report, opts.threads, opts.by_name))
        return 1 if failed else 0
    except (CensusError, OSError, ValueError) as error:
        print(f"process-model-census: {error}", file=sys.stderr)
        return 2
    finally:
        if app and not opts.keep:
            app.stop()


if __name__ == "__main__":
    sys.exit(main())
