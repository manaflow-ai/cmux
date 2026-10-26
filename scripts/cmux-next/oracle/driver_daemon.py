#!/usr/bin/env python3
"""The oracle's daemon driver: one isolated cmux-tui per case, driven only through the Python SDK.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D and 3G and task 023. Stdlib plus the
cmux Python SDK of this checkout (cmux-tui/bindings/python), Python 3.9+, safe under `python3 -I`.
It implements the driver protocol of oracle.py (`open_session`, `session.run_case`, `session.close`).

Each case gets:
- its own state root `/tmp/o/<run6>/<case6>` (oracle.py gives it out), holding the daemon's socket
  (`s.sock`, so every socket path stays <= 100 bytes, under Linux's 108-byte sun_path), state, HOME,
  XDG dirs, TMPDIR, config and log.
- its own session name (`oracle-<token of the root>`). The daemon names its install by the session, and
  a debug-assertion build (`--profile oracle`, a debug build) with `CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT=1`
  binds its terminal hosts' sockets in that install's directory, `/tmp/cmux-th-<uid>/<token>/`
  (terminal_host_runtime/sys/unix.rs), so no two cases share it. A build without debug assertions binds
  them flat in `/tmp/cmux-th-<uid>/`, one file per terminal id. The facet shows the fixture's name,
  `oracle`, as paths show $ROOT.
- one `cmux-tui --headless` child started in its own session, awaited on its readiness pipe
  (`--owner-ready-fd`, the daemon's own startup protocol), never by probing the socket.
- the environment of `case_environment` only (an `env -i` base). Task p15-oracle-200 moves that function
  into hermetic_env.py and adds `unshare -rn`, the repository fixture and the daemon's CMUX_TUI_OFFLINE
  early return (the variable is set here already). Terminals use the default per-terminal
  `cmux-tui __terminal-host` model (CMUX_TUI_TERMINAL_HOST_MODEL is unset).
- every request through the SDK: resource operations on `cmux._protocol.ProtocolConnection` (the SDK's
  wire layer; the oracle compares wire replies, so it does not decode them into dataclasses), and the
  daemon-control commands (`identify`, `shutdown-daemon`, `oracle-state`, `oracle-advance-clock`) on
  `cmux.raw.CmuxClient`.

Steps: resource.call, snapshot, settle (one ping round trip: the daemon acknowledges a mutation after
it committed it, so the next read on the connection sees it), kill and restart of the daemon process,
advance_clock (`oracle-advance-clock {ms}` of task p15-oracle-185), and waitFor on session.events (each
event re-reads the facet; no sleeps). cli, mcp, action.run, key and tui.key belong to the other drivers.

Invariant I6 (no orphan processes or sockets). Each case runs in its own worker process (`case-worker`),
which on Linux is a child subreaper (prctl PR_SET_CHILD_SUBREAPER): a process the case starts stays in
the worker's process tree until it exits, whatever its environment, session or parent did, so the
worker finds all of them by walking /proc/<pid>/task/*/children from itself, never by a scan of the
host's process table. macOS has no subreaper; there the worker also reads the case's marker
(`CMUX_ORACLE_CASE=<state root>`) from `ps`, which finds a child that kept its environment. Teardown
asks the daemon to stop and end its terminals (`shutdown-daemon end_terminals`; a daemon a step killed
or that died is started again first, so it adopts its terminals and rebinds its endpoints, then ends
them), waits for those exits on pidfds (kqueue on macOS), and then any process left in the tree fails
the case and is killed. A process is known by pid and start time, so a reused pid is never mistaken
for it. The session in oracle.py's process then checks the sockets: a socket file someone still listens
on fails the case; one with no listener (connect is refused) is a file the daemon did not remove, which
the result reports as daemon debt. When a worker did not finish (it hung or crashed), the session ends
its tree by SIGTERM and falls back to one marker scan of the process table for that case.

Chrome reference (chromium/src):
- base/test/launcher/test_launcher.cc: each test child runs in its own process group and the launcher
  kills what remains of that group when the test ends (KillSpawnedTestProcesses), so a leaked process
  never outlives its test. cmux-tui's terminal hosts call setsid(), so the worker's subreaper tree
  stands in for the group here.
- chrome/test/base/in_process_browser_test.cc: a fresh temporary user data dir per test
  (temp_user_data_dir_), the per-case state root's model.

Usage:
  driver_daemon.py run-case --binary CMUX_TUI CASE.json [--state-base DIR] [--snapshot-schema S]
                                                     one case, its result JSON
  driver_daemon.py smoke --binary CMUX_TUI [--cases 300] [--jobs 300] [--case CASE.json]
                                                     parallel cases (no-op by default), then nothing left
"""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import hashlib
import json
import os
import platform as platform_mod
import re
import select
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from functools import lru_cache, partial
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SDK = REPO / "cmux-tui" / "bindings" / "python"
OPERATIONS_SPEC = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"

for _path in (str(HERE), str(SDK)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import check_snapshot_schema  # noqa: E402 - sibling of this file (capture rules of the daemon facet)
import normalize  # noqa: E402 - sibling of this file (p15-oracle-013)
from cmux._protocol import ProtocolConnection  # noqa: E402
from cmux.errors import (  # noqa: E402
    CmuxConnectionError,
    CmuxError,
    ResourceError,
    StreamError,
)
from cmux.errors import TimeoutError as SdkTimeout  # noqa: E402
from cmux.raw import CmuxClient  # noqa: E402

MARKER_ENV = "CMUX_ORACLE_CASE"
# The fixture's session name, as the facet shows it; each case runs as `oracle-<token>` (CasePaths.session).
SESSION_NAME = "oracle"
# prctl(2) option: orphaned descendants are re-parented to the caller, not to init.
PR_SET_CHILD_SUBREAPER = 36
# sun_path is 108 bytes on Linux and 104 on macOS; the spec keeps every path at 100 or less.
SOCKET_LIMIT = 100
DEFAULT_STATE_BASE = Path("/tmp/o")
SELECTORS = {"machine": "current", "session": "current"}
FACETS = (
    "topology", "daemon", "focus", "layout", "sidebar", "tabs", "overlays", "settings", "intents", "windows",
    "history", "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects",
    "invariants", "switches",
)
DEFAULT_FACETS = ("daemon",)
# The daemon product's only facet; the rest come from the app (driver_app.py) or later daemon tasks.
FACET_TASKS = {"crashes": "p15-oracle-188", "liveObjects": "p15-oracle-188", "switches": "p15-oracle-049"}
ORACLE_STATE_KEYS = ("switches", "terminalAttach", "liveObjects", "panicLog")
OTHER_DRIVERS = {
    "cli": "driver_cli.py (p15-oracle-048)",
    "mcp": "driver_mcp.py (p15-oracle-209)",
    "tui.key": "driver_tui.py (p15-oracle-234)",
    "action.run": "driver_app.py (p15-oracle-047)",
    "key": "driver_app.py (p15-oracle-047)",
}
SIGNALS = {"KILL": signal.SIGKILL, "TERM": signal.SIGTERM, "ABRT": signal.SIGABRT, "SEGV": signal.SIGSEGV}
STEP_REF = re.compile(r"^\$step:([a-z0-9][a-z0-9-]{0,63})#((?:/(?:[^~/]|~[01])*)*)$")
TYPED_ID = re.compile(r"^[a-z][a-z_]*_[0-9a-f]{32}$")
ENV_WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
UNKNOWN_COMMAND = "unknown variant `{}`"
# Seconds; a case's Slow expectation multiplies them (case_ctx timeout_multiplier).
REQUEST_S = 10.0
READY_S = 60.0
STOP_S = 60.0
SHUTDOWN_S = 120.0
EXIT_S = 10.0
LOG_TAIL_BYTES = 2048
MISSING = object()


class CaseError(Exception):
    """Ends the case with `status` (Failure, Crash or Timeout) at `step`."""

    def __init__(self, status: str, message: str, step: Optional[str] = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.step = step


# ---------------------------------------------------------------------------------------------------------
# Paths and environment


@dataclass(frozen=True)
class CasePaths:
    root: Path

    @property
    def socket(self) -> Path:
        return self.root / "s.sock"

    @property
    def state(self) -> Path:
        return self.root / "state"

    @property
    def home(self) -> Path:
        return self.root / "home"

    @property
    def run(self) -> Path:
        return self.root / "run"

    @property
    def tmp(self) -> Path:
        return self.root / "tmp"

    @property
    def log(self) -> Path:
        return self.root / "daemon.log"

    @property
    def session(self) -> str:
        """The case's own session name: the daemon names its install, so its host socket directory, by it."""
        return f"{SESSION_NAME}-{short_token(str(self.root))}"

    @property
    def install_dir(self) -> Path:
        """Where the case's terminal hosts bind on a debug-assertion build: `/tmp/cmux-th-<uid>/<token>`,
        the token being cmux-tui's stable_token (FNV-1a 64) of the session (sys/unix.rs install_endpoint_dir)."""
        return Path("/tmp") / f"cmux-th-{os.geteuid()}" / stable_token(self.session)

    @classmethod
    def for_case(cls, state_root: Optional[str], run_id: str, key: str) -> "CasePaths":
        """oracle.py's state root, or `/tmp/o/<run6>/<case6>` from the run id and case key."""
        if state_root:
            return cls(Path(state_root))
        return cls(DEFAULT_STATE_BASE / short_token(run_id) / short_token(key))

    def check(self) -> None:
        if not self.root.is_absolute():
            raise CaseError("Crash", f"state root {self.root} is not absolute")
        length = len(os.fsencode(str(self.socket)))
        if length > SOCKET_LIMIT:
            raise CaseError("Crash", f"socket path {self.socket} is {length} bytes, over {SOCKET_LIMIT}: use a "
                                     f"state base like /tmp/o (spec rule 12)")

    def create(self) -> None:
        """A fresh, empty root: a leftover from another run would be shared state."""
        if self.root.exists() and any(self.root.iterdir()):
            raise CaseError("Crash", f"state root {self.root} is not empty; it belongs to another case")
        for path in (self.root, self.state, self.home, self.tmp):
            path.mkdir(parents=True, exist_ok=True)
        self.run.mkdir(mode=0o700, exist_ok=True)


def short_token(text: str) -> str:
    """Six base-36 characters derived from `text`."""
    value = int.from_bytes(hashlib.sha256(text.encode("utf-8")).digest()[:5], "big")
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    for _ in range(6):
        value, rest = divmod(value, 36)
        out = digits[rest] + out
    return out


def stable_token(text: str) -> str:
    """cmux-tui's terminal_host_runtime codec::stable_token: FNV-1a 64 of the UTF-8 bytes, 16 hex digits."""
    value = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def case_environment(paths: CasePaths, seed: str) -> Dict[str, str]:
    """The case daemon's whole environment (an `env -i` base: nothing is inherited).

    p15-oracle-200 moves this into hermetic_env.py, the one place both drivers build env.
    """
    home = paths.home
    return {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_RUNTIME_DIR": str(paths.run),
        "TMPDIR": str(paths.tmp),
        "CMUX_TUI_CONFIG": str(paths.root / "config.json"),
        "CMUX_NEXT_CONFIG_FILE": str(paths.root / "cmux-next.json"),
        "CMUX_TUI_STATE_DIR": str(paths.state),
        "CMUX_TUI_SOCKET": str(paths.socket),
        "CMUX_TUI_LOG_FILE": str(paths.root / "client.log"),
        "CMUX_TUI_NO_LOGIN_SHELL": "1",
        "CMUX_TUI_OFFLINE": "1",
        "CMUX_TUI_ORACLE_SEED": seed,
        "CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT": "1",
        "TZ": "UTC",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "SHELL": "/bin/sh",
        "PS1": "$ ",
        "TERM": "xterm-256color",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        MARKER_ENV: str(paths.root),
    }


# ---------------------------------------------------------------------------------------------------------
# Processes: the case's process tree, its sockets, exit waits


@dataclass(frozen=True)
class CaseProcess:
    pid: int
    ppid: int
    # /proc/<pid>/stat field 22 (clock ticks after boot), or ps lstart: a reused pid has another.
    start: str
    argv: Tuple[str, ...]

    def describe(self) -> str:
        return f"{self.pid} {' '.join(self.argv)[:120]}"


def _linux_process(pid: int, needle: Optional[bytes] = None) -> Optional[CaseProcess]:
    """The live process `pid` (not a zombie); with `needle`, only if its environment carries it."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            # Fields after the command name: state (3), ppid (4), ... starttime (22).
            fields = handle.read().rsplit(b")", 1)[-1].split()
        if fields[0] == b"Z":
            return None  # it exited; its parent has not reaped it yet
        if needle is not None:
            with open(f"/proc/{pid}/environ", "rb") as handle:
                if needle not in handle.read().split(b"\0"):
                    return None
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            argv = tuple(part.decode("utf-8", "replace") for part in handle.read().split(b"\0") if part)
    except (OSError, IndexError):
        return None  # exited while we looked, or not ours
    return CaseProcess(pid, int(fields[1]), fields[19].decode(), argv)


def _linux_children(pid: int) -> List[int]:
    kids: List[int] = []
    for path in glob.glob(f"/proc/{pid}/task/*/children"):
        try:
            with open(path, "rb") as handle:
                kids.extend(int(value) for value in handle.read().split())
        except OSError:
            continue
    return kids


def _ps_table() -> List[Tuple[int, int, bytes, str, Tuple[str, ...]]]:
    """(pid, ppid, state, start, words) of every process, the words being argv and then the environment of
    this user's own processes (BSD ps `e` appends it): the macOS source of the functions below."""
    ps = subprocess.Popen(["ps", "-axeww", "-o", "pid=,ppid=,stat=,lstart=,command="], stdout=subprocess.PIPE)
    out, _ = ps.communicate()
    rows = []
    for line in out.splitlines():
        # lstart is five words: "Mon Oct 26 05:41:00 2026".
        parts = line.split(None, 8)
        # ps lists itself, a child of the caller: never a case process.
        if len(parts) == 9 and int(parts[0]) != ps.pid:
            rows.append((int(parts[0]), int(parts[1]), parts[2], b" ".join(parts[3:8]).decode(),
                         tuple(word for word in parts[8].decode("utf-8", "replace").split(" ") if word)))
    return rows


def _ps_process(row: Tuple[int, int, bytes, str, Tuple[str, ...]]) -> Optional[CaseProcess]:
    pid, ppid, state, start, words = row
    if state.startswith(b"Z"):
        return None
    # The environment follows the command: its first NAME=value word ends argv.
    end = next((i for i, word in enumerate(words) if ENV_WORD.match(word)), len(words))
    return CaseProcess(pid, ppid, start, words[:end])


def descendants(root: int, marker: str) -> List[CaseProcess]:
    """Every live descendant of `root`, whatever its environment. On macOS also every process that carries
    the case's marker: with no subreaper there, an orphan leaves the tree for launchd.

    Linux walks /proc/<pid>/task/*/children down from `root`, so a case reads its own few processes, never
    the host's whole process table (tens of thousands on the shared VM).
    """
    if not sys.platform.startswith("linux"):
        needle = f"{MARKER_ENV}={marker}"
        rows = _ps_table()
        children: Dict[int, List[int]] = {}
        for row in rows:
            children.setdefault(row[1], []).append(row[0])
        procs = {row[0]: _ps_process(row) for row in rows}
        wanted = {row[0] for row in rows if needle in row[4] and row[0] != root}
        stack = list(children.get(root, ()))
        while stack:
            pid = stack.pop()
            wanted.add(pid)
            stack.extend(children.get(pid, ()))
        return [procs[pid] for pid in sorted(wanted) if procs.get(pid) is not None]
    found, stack, seen = [], _linux_children(root), {root}
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        proc = _linux_process(pid)
        if proc is not None:
            found.append(proc)
        stack.extend(_linux_children(pid))
    return found


def still_running(known: Iterable[CaseProcess]) -> List[CaseProcess]:
    """The processes of `known` that still run: same pid and same start time."""
    if not sys.platform.startswith("linux"):
        rows = {row[0]: _ps_process(row) for row in _ps_table()}
        procs = (rows.get(p.pid) for p in known)
    else:
        procs = (_linux_process(p.pid) for p in known)
    starts = {p.pid: p.start for p in known}
    return [proc for proc in procs if proc is not None and proc.start == starts[proc.pid]]


def become_subreaper() -> bool:
    """Makes this process the reaper of its orphaned descendants (Linux 3.4+); False elsewhere."""
    if not sys.platform.startswith("linux"):
        return False
    import ctypes  # noqa: PLC0415 - Linux only

    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER)")
    return True


def reap_orphans(keep: Optional[int]) -> None:
    """Reaps the exited orphans a subreaper adopted (every exited child but `keep`, which subprocess owns)."""
    if not sys.platform.startswith("linux"):
        return
    for pid in _linux_children(os.getpid()):
        if pid == keep:
            continue
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            continue


def scan_markers() -> Dict[str, List[CaseProcess]]:
    """Every live process that carries a case marker, by marker: one pass over the whole process table.
    Only for a case whose worker did not finish, and for the smoke run's final check."""
    found: Dict[str, List[CaseProcess]] = {}
    prefix = f"{MARKER_ENV}="
    if not sys.platform.startswith("linux"):
        for row in _ps_table():
            marks = [word for word in row[4] if word.startswith(prefix)]
            proc = _ps_process(row) if marks else None
            if proc is not None:
                found.setdefault(marks[0][len(prefix):], []).append(proc)
        return found
    head = prefix.encode()
    for path in glob.glob("/proc/[0-9]*"):
        try:
            with open(f"{path}/environ", "rb") as handle:
                marks = [entry for entry in handle.read().split(b"\0") if entry.startswith(head)]
        except OSError:
            continue  # not this user's, or gone
        if marks:
            proc = _linux_process(int(path[6:]), marks[0])
            if proc is not None:
                found.setdefault(marks[0][len(head):].decode("utf-8", "replace"), []).append(proc)
    return found


def socket_paths(processes: Sequence[CaseProcess]) -> Set[str]:
    """Unix socket paths the processes name (`--socket PATH`) or listen on (Linux /proc/net/unix)."""
    paths: Set[str] = set()
    for proc in processes:
        for flag, value in zip(proc.argv, proc.argv[1:]):
            if flag == "--socket":
                paths.add(value)
    if not sys.platform.startswith("linux"):
        return paths
    inodes: Set[str] = set()
    for proc in processes:
        for fd in glob.glob(f"/proc/{proc.pid}/fd/*"):
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
    if not inodes:
        return paths
    try:
        with open("/proc/net/unix", "r", encoding="utf-8", errors="replace") as handle:
            rows = handle.read().splitlines()[1:]
    except OSError:
        return paths
    for row in rows:
        # Num RefCount Protocol Flags Type St Inode [Path]; an abstract name starts with '@'.
        columns = row.split(None, 7)
        if len(columns) == 8 and columns[6] in inodes and columns[7].startswith("/"):
            paths.add(columns[7])
    return paths


def socket_files(root: Path) -> Set[str]:
    found = set()
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                if os.lstat(path).st_mode & 0o170000 == 0o140000:
                    found.add(path)
            except OSError:
                continue
    return found


def has_listener(path: str) -> bool:
    """Whether a process accepts on the Unix socket file `path`. Only a refused connect (no listener, or
    no file) says no; any other answer counts as a listener, so a doubt fails the case."""
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(1.0)
        probe.connect(path)
    except (ConnectionRefusedError, FileNotFoundError):
        return False
    except OSError:
        return True
    finally:
        probe.close()
    return True


def wait_for_exits(pids: Iterable[int], timeout: float) -> Set[int]:
    """Waits until every pid exited or `timeout` passed; returns the pids still alive.

    Exit events, not polling: a pidfd per process on Linux (readable once it exits), kqueue NOTE_EXIT
    elsewhere. A pid that is already gone counts as exited.
    """
    pending = set(pids)
    if not pending:
        return set()
    deadline = time.monotonic() + timeout
    if hasattr(os, "pidfd_open"):
        fds: Dict[int, int] = {}
        for pid in pending:
            try:
                fds[os.pidfd_open(pid)] = pid
            except ProcessLookupError:
                continue
        poller = select.poll()
        for fd in fds:
            poller.register(fd, select.POLLIN)
        try:
            while fds:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                for fd, _event in poller.poll(remaining * 1000):
                    poller.unregister(fd)
                    os.close(fd)
                    fds.pop(fd)
            return set(fds.values())
        finally:
            for fd in fds:
                os.close(fd)
    queue = select.kqueue()
    try:
        alive = set()
        for pid in pending:
            event = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)
            try:
                queue.control([event], 0, 0)
                alive.add(pid)
            except ProcessLookupError:
                continue
        while alive:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            for event in queue.control(None, len(alive), remaining):
                alive.discard(event.ident)
        return alive
    finally:
        queue.close()


def log_tail(path: Path) -> str:
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - LOG_TAIL_BYTES))
            return handle.read().decode("utf-8", "replace").strip()
    except OSError:
        return ""


# ---------------------------------------------------------------------------------------------------------
# The case daemon


@dataclass
class DaemonExit:
    step: str
    kind: str
    reason: str
    exit_code: Optional[int]


class Daemon:
    """One cmux-tui child on one state root, with its SDK clients."""

    def __init__(self, binary: str, paths: CasePaths, env: Dict[str, str], scale: float):
        self.binary = binary
        self.paths = paths
        self.env = env
        self.scale = scale
        self.proc: Optional[subprocess.Popen] = None
        self.conn: Optional[ProtocolConnection] = None
        self.raw: Optional[CmuxClient] = None
        self.identity: Dict[str, Any] = {}
        self.starts = 0
        self.oracle_state_supported: Optional[bool] = None
        self.virtual_clock = False

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, step: str) -> None:
        read_fd, write_fd = os.pipe()
        argv = [self.binary, "--headless", "--session", self.paths.session, "--socket", str(self.paths.socket),
                "--state", str(self.paths.state), "--owner-ready-fd", str(write_fd)]
        try:
            with open(self.paths.log, "ab") as log:
                self.proc = subprocess.Popen(
                    argv, env=self.env, cwd=str(self.paths.root), pass_fds=(write_fd,), stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=log, start_new_session=True,
                )
        except OSError as error:
            os.close(read_fd)
            raise CaseError("Crash", f"cannot start {self.binary}: {error}", step) from None
        finally:
            os.close(write_fd)
        self.starts += 1
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(read_fd, selectors.EVENT_READ)
                byte = os.read(read_fd, 1) if selector.select(READY_S * self.scale) else None
        finally:
            os.close(read_fd)
        if byte is None:
            raise CaseError("Timeout", f"the daemon did not report ready in {READY_S * self.scale:.0f} s", step)
        if not byte:
            self.proc.wait()
            raise CaseError("Crash", f"the daemon exited before it was ready ({self.exit_text()}): "
                                     f"{log_tail(self.paths.log)}", step)
        try:
            self.conn = ProtocolConnection(str(self.paths.socket), REQUEST_S * self.scale)
            self.raw = CmuxClient(str(self.paths.socket), timeout=REQUEST_S * self.scale)
            self.identity = self.command("identify", step)
        except CmuxError as error:
            raise CaseError("Crash", f"cannot connect to the daemon: {error}", step) from None
        self.oracle_state_supported = None
        self.virtual_clock = self.probe_clock(step)

    def exit_text(self) -> str:
        code = self.proc.returncode if self.proc is not None else None
        if code is None:
            return "running"
        if code < 0:
            return f"signal {signal.Signals(-code).name}"
        return f"exit {code}"

    def exit_code(self) -> Optional[int]:
        code = self.proc.returncode if self.proc is not None else None
        return code if code is not None and code >= 0 else None

    def request(self, method: str, params: Mapping[str, Any], key: Optional[str], timeout: float) -> Any:
        if self.conn is None:
            raise CmuxConnectionError("the daemon is not running")
        return self.conn.request(method, params, idempotency_key=key, timeout=timeout)

    def command(self, cmd: str, step: str, **params: Any) -> Dict[str, Any]:
        """A daemon-control command; an unknown command raises KeyError, a refusal CaseError."""
        if self.raw is None:
            raise CmuxConnectionError("the daemon is not running")
        return self.reply(self.raw.request(cmd, **params), cmd, step)

    @staticmethod
    def reply(response: Dict[str, Any], cmd: str, step: str) -> Dict[str, Any]:
        if response.get("ok") is True:
            data = response.get("data")
            return data if isinstance(data, dict) else {}
        error = str(response.get("error", "unknown error"))
        if UNKNOWN_COMMAND.format(cmd) in error:
            raise KeyError(cmd)
        raise CaseError("Failure", f"{cmd} refused: {error[:300]}", step)

    def probe_clock(self, step: str) -> bool:
        """A daemon with the oracle virtual clock (p15-oracle-185) accepts an advance of 0 ms."""
        try:
            self.command("oracle-advance-clock", step, ms=0)
        except (KeyError, CaseError):
            return False
        return True

    def oracle_state(self, step: str) -> Optional[Dict[str, Any]]:
        """`oracle-state` (p15-oracle-021, oracle feature or debug builds), or None on a daemon without it."""
        if self.oracle_state_supported is False:
            return None
        try:
            data = self.command("oracle-state", step)
        except KeyError:
            self.oracle_state_supported = False
            return None
        self.oracle_state_supported = True
        return data

    def close_clients(self) -> None:
        for client in (self.conn, self.raw):
            if client is not None:
                try:
                    client.close()
                except CmuxError:
                    pass
        self.conn = None
        self.raw = None

    def reap(self, timeout: float) -> bool:
        """Waits for the child's exit event, then reaps it; False if it is still running."""
        if self.proc is None or self.proc.poll() is not None:
            return True
        if wait_for_exits([self.proc.pid], timeout):
            return False
        self.proc.wait()
        return True

    def kill(self, sig: int) -> None:
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            os.kill(self.proc.pid, sig)
        except ProcessLookupError:
            pass
        self.close_clients()
        if not self.reap(EXIT_S * self.scale) and sig != signal.SIGKILL:
            os.kill(self.proc.pid, signal.SIGKILL)
            self.reap(EXIT_S * self.scale)

    def stop(self, step: str, end_terminals: bool) -> None:
        """`shutdown-daemon` for this generation, then the child's exit. Ending the terminals waits for their
        hosts (up to 60 s, then 5 s after SIGKILL: mux/terminal_reap.rs), so the request gets the CLI's 120 s."""
        try:
            with CmuxClient(str(self.paths.socket), timeout=SHUTDOWN_S * self.scale) as client:
                self.reply(client.request("shutdown-daemon", pid=int(self.identity["pid"]),
                                          generation=str(self.identity["generation"]), force=True,
                                          end_terminals=end_terminals), "shutdown-daemon", step)
        except (CmuxError, KeyError) as error:
            raise CaseError("Crash", f"shutdown-daemon failed: {error!r}: {log_tail(self.paths.log)}", step) from None
        self.close_clients()
        if not self.reap(STOP_S * self.scale):
            raise CaseError("Timeout", f"the daemon did not exit {STOP_S * self.scale:.0f} s after shutdown-daemon",
                            step)


# ---------------------------------------------------------------------------------------------------------
# Pure helpers: pointers, predicates, selectors


def decode_pointer(pointer: str) -> List[str]:
    if pointer == "":
        return []
    if not pointer.startswith("/"):
        raise ValueError(f"JSON pointer {pointer!r} does not start with /")
    return [part.replace("~1", "/").replace("~0", "~") for part in pointer[1:].split("/")]


def resolve_pointer(value: Any, pointer: str) -> Any:
    """The value at `pointer` (RFC 6901), or MISSING."""
    for part in decode_pointer(pointer):
        if isinstance(value, dict) and part in value:
            value = value[part]
        elif isinstance(value, list) and part.isdigit() and (part == "0" or not part.startswith("0")) \
                and int(part) < len(value):
            value = value[int(part)]
        else:
            return MISSING
    return value


def predicate_holds(wait: Mapping[str, Any], value: Any, baseline: Any) -> bool:
    """The waitFor condition of case-v1 (`equals` or `predicate`) on the value at its pointer."""
    if "equals" in wait:
        return value is not MISSING and value == wait["equals"]
    predicate = wait["predicate"]
    if isinstance(predicate, str):
        sized = isinstance(value, (list, dict, str))
        return {
            "exists": value is not MISSING,
            "absent": value is MISSING,
            "empty": sized and len(value) == 0,
            "nonEmpty": sized and len(value) > 0,
            "changed": value != baseline,
        }[predicate]
    op, target = predicate["op"], predicate["value"]
    if value is MISSING:
        return False
    if op == "lengthEquals":
        return isinstance(value, (list, dict, str)) and len(value) == target
    if op == "contains":
        if isinstance(value, str) and isinstance(target, str):
            return target in value
        if isinstance(value, dict) and isinstance(target, str):
            return target in value
        return isinstance(value, list) and target in value
    numbers = (int, float)
    if not (isinstance(value, numbers) and isinstance(target, numbers)) or isinstance(value, bool):
        return False
    return {"gt": value > target, "gte": value >= target, "lt": value < target, "lte": value <= target}[op]


def encode_selector(kind: str, value: Any) -> str:
    """A case handle as a resource selector: the fixture's machine and session are `current`, a typed id
    (or a value an earlier step returned) is sent as is, any other handle is a name selector."""
    if not isinstance(value, str):
        raise CaseError("Crash", f"target.{kind} is {value!r}, not a string")
    if (kind, value) in (("machine", "local"), ("session", "fixture")) or value == "current":
        return "current"
    if TYPED_ID.match(value) or value.startswith("name:"):
        return value
    return f"name:{value}"


def selector_params(spec: Mapping[str, Any], target: Mapping[str, Any], method: str) -> Dict[str, str]:
    accepted = (spec.get("params") or {}).get("selectors") or {}
    out = {}
    for kind, value in target.items():
        if kind == "process":
            continue
        if kind not in accepted:
            raise CaseError("Crash", f"{method} takes no {kind} selector (cmux-tui/spec/resource-operations-v2.json)")
        out[kind] = encode_selector(kind, value)
    for kind in ("machine", "session"):
        if accepted.get(kind) == "required" and kind not in out:
            out[kind] = "current"
    return out


def resolve_refs(value: Any, replies: Mapping[str, Any]) -> Any:
    """Substitutes `$step:<id>#<pointer>` strings with the value from that earlier step's reply."""
    if isinstance(value, str):
        match = STEP_REF.match(value)
        if not match:
            return value
        step, pointer = match.groups()
        if step not in replies:
            raise CaseError("Crash", f"{value}: step {step} has no reply")
        found = resolve_pointer(replies[step], pointer)
        if found is MISSING:
            raise CaseError("Failure", f"{value}: the reply of {step} has nothing at {pointer}")
        return found
    if isinstance(value, list):
        return [resolve_refs(item, replies) for item in value]
    if isinstance(value, dict):
        return {key: resolve_refs(item, replies) for key, item in value.items()}
    return value


def not_comparable(reason: str, task: Optional[str] = None) -> Dict[str, str]:
    out = {"status": "not-comparable", "reason": reason}
    if task:
        out["task"] = task
    return out


def crash_allowed(entries: Sequence[Mapping[str, Any]], exits: Sequence[DaemonExit]) -> Optional[str]:
    """None when allow_crashes covers every exit, else why not (invariant I17's rule for the daemon kind)."""
    by_kind: Dict[str, List[DaemonExit]] = {}
    for item in exits:
        by_kind.setdefault(item.kind, []).append(item)
    for kind, items in sorted(by_kind.items()):
        mine = [e for e in entries if e.get("kind") == kind]
        for item in items:
            if not any("steps" not in e or item.step in e["steps"] for e in mine):
                return f"a {kind} exit at step {item.step} ({item.reason}) is not in allow_crashes"
        allowed = sum(int(e.get("max", 1)) for e in mine)
        if len(items) > allowed:
            return f"{len(items)} {kind} exits, allow_crashes allows {allowed}"
    return None


@lru_cache(maxsize=1)
def operations_spec() -> Dict[str, Any]:
    with open(OPERATIONS_SPEC, encoding="utf-8") as handle:
        return json.load(handle)["operations"]


@lru_cache(maxsize=4)
def load_snapshot_schema(path: str) -> Tuple[Optional[normalize.Schema], str]:
    """The snapshot schema as normalize.py loads it, or None and why it refused it (cached either way)."""
    try:
        return normalize.Schema.load(Path(path)), ""
    except normalize.OracleError as error:
        return None, str(error)


def host_meta() -> Dict[str, str]:
    model = "unknown"
    for path in ("/sys/devices/virtual/dmi/id/product_name", "/sys/firmware/devicetree/base/model"):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                model = handle.read().strip("\0\n ") or model
            break
        except OSError:
            continue
    return {"os": f"{platform_mod.system()} {platform_mod.release()}", "arch": platform_mod.machine(),
            "model": model}


# ---------------------------------------------------------------------------------------------------------
# One case


@dataclass
class Capture:
    step: str
    checkpoint: str
    snapshot: Dict[str, Any]


@dataclass
class CaseState:
    replies: Dict[str, Any] = field(default_factory=dict)
    captures: List[Capture] = field(default_factory=list)
    exits: List[DaemonExit] = field(default_factory=list)
    killed_by: Optional[str] = None


class CaseRun:
    """One case in a worker process: the steps, then an orderly shutdown of everything it started."""

    def __init__(self, binary: str, sha: str, schema: normalize.Schema, case: Mapping[str, Any],
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any]):
        self.case = case
        self.schema = schema
        self.known: Dict[int, CaseProcess] = {}
        self.sockets: Set[str] = set()
        self.case_id = ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        self.scale = float(ctx.get("timeout_multiplier") or 1)
        self.paths = CasePaths.for_case(ctx.get("state_root"), str(session_ctx.get("run_id") or "run"),
                                        str(ctx.get("key") or self.case_id))
        fixture = case.get("fixture") or {}
        self.env = case_environment(self.paths, str(fixture.get("seed") or case.get("id") or "oracle"))
        self.daemon = Daemon(binary, self.paths, self.env, self.scale)
        self.sha = sha
        self.state = CaseState()
        self.host = host_meta()
        self.dirty = False
        self.ops: Dict[str, Callable[[int, Mapping[str, Any]], Any]] = {
            "resource.call": self.op_resource_call,
            "snapshot": self.op_snapshot,
            "settle": self.op_settle,
            "kill": self.op_kill,
            "restart": self.op_restart,
            "advance_clock": self.op_advance_clock,
        }

    # -- the run

    def run(self) -> Dict[str, Any]:
        status, message, at = "Pass", "", None
        problems: List[str] = []
        try:
            try:
                self.daemon.start("setup")
                for index, step in enumerate(self.case.get("steps") or ()):
                    self.run_step(index, step)
            except CaseError as error:
                status, message, at = error.status, error.message, error.step
            except CmuxError as error:
                status, message = "Crash", f"SDK error: {error!r}"
        finally:
            # Also when a driver bug raises: the worker reports it after the shutdown.
            problems = self.shutdown()
        if problems:
            message = "; ".join(filter(None, [message, *problems]))
            if status == "Pass":
                status = "Failure"
        result: Dict[str, Any] = {"status": status, "message": message, "checkpoints": [],
                                  "sockets": sorted(self.sockets)}
        if at:
            result["step"] = at
        if self.dirty:
            result["session_dirty"] = True
        try:
            result["checkpoints"] = self.canonical_checkpoints()
        except normalize.OracleError as error:
            result.update(status="Crash", message="; ".join(filter(None, [message, f"snapshot refused: {error}"])))
        return result

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        step_id = step["id"]
        op = step["op"]
        handler = self.ops.get(op)
        if handler is None:
            owner = OTHER_DRIVERS.get(op, "no driver")
            raise CaseError("Crash", f"op {op} is not a daemon-driver step; it runs in {owner}", step_id)
        self.check_alive(step_id)
        checkpoints = step.get("checkpoint") or ["settled"]
        facets = tuple((step.get("args") or {}).get("facets") or FACETS) if op == "snapshot" else DEFAULT_FACETS
        if "before" in checkpoints:
            self.capture(index, step_id, "before", facets)
        waiter = Waiter(self, step) if step.get("waitFor") else None
        try:
            outcome = handler(index, step)
            self.check_expect(step, outcome)
            if waiter is not None:
                waiter.finish()
        finally:
            if waiter is not None:
                waiter.close()
        if "settled" in checkpoints:
            self.capture(index, step_id, "settled", facets)

    def check_alive(self, step: str) -> None:
        """A daemon that exited while nobody killed it is a Crash at the step that finds it."""
        if self.state.killed_by is None and self.daemon.proc is not None and not self.daemon.running:
            self.daemon.close_clients()
            self.state.exits.append(DaemonExit(step, "daemon", f"exited on its own ({self.daemon.exit_text()})",
                                               self.daemon.exit_code()))
            refusal = crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
            if refusal:
                raise CaseError("Crash", f"I17: {refusal}: {log_tail(self.paths.log)}", step)
            self.state.killed_by = step

    def sdk_failure(self, error: CmuxError, step: str, what: str) -> CaseError:
        if isinstance(error, SdkTimeout):
            return CaseError("Timeout", f"{what}: {error}", step)
        if isinstance(error, CmuxConnectionError):
            self.check_alive(step)
        return CaseError("Crash", f"{what}: {error!r}", step)

    # -- steps

    def op_resource_call(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        args = resolve_refs(step["args"], self.state.replies)
        target = resolve_refs(step.get("target") or {}, self.state.replies)
        method = args["method"]
        spec = operations_spec().get(method)
        if spec is None:
            raise CaseError("Crash", f"{method} is not in cmux-tui/spec/resource-operations-v2.json", step_id)
        if spec["class"] not in ("read", "mutation", "connection_control"):
            raise CaseError("Crash", f"{method} is a {spec['class']} operation; resource.call sends reads and "
                                     f"mutations (streams are p15-oracle-204)", step_id)
        params = dict(args.get("params") or {})
        selectors = selector_params(spec, target, method)
        clash = sorted(set(params) & set(selectors))
        if clash:
            raise CaseError("Crash", f"{', '.join(clash)} is both a param and a target selector", step_id)
        params.update(selectors)
        if not self.daemon.running:
            raise CaseError("Failure", f"{method}: the daemon is not running (killed at {self.state.killed_by})",
                            step_id)
        before = self.daemon_facet(step_id) if step.get("readOnly") else None
        timeout = REQUEST_S * self.scale
        try:
            reply = self.daemon.request(method, params, args.get("idempotencyKey"), timeout)
            outcome: Tuple[str, Any] = ("ok", reply)
        except ResourceError as error:
            reply = {"error": {"code": error.code, "message": error.message, "retryable": error.retryable}}
            outcome = ("error", error.code)
        except CmuxError as error:
            raise self.sdk_failure(error, step_id, method) from None
        self.state.replies[step_id] = reply
        if before is not None:
            self.check_read_only(index, step_id, before)
        return outcome

    def check_read_only(self, index: int, step_id: str, before: Any) -> None:
        after = self.daemon_facet(step_id)
        pair = [self.snapshot(index, "before", {"daemon": before}), self.snapshot(index, "settled", {"daemon": after})]
        first, second = normalize.canonicalize_case(pair, self.schema, self.normalize_context())
        if first.value["facets"] != second.value["facets"]:
            raise CaseError("Failure", "readOnly step changed the daemon facet", step_id)

    def op_snapshot(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        return ("ok", {})

    def op_settle(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        if not self.daemon.running:
            return ("ok", {})
        bound = int(step.get("settleMaxMs") or REQUEST_S * 1000) / 1000 * self.scale
        try:
            reply = self.daemon.request("session.ping", SELECTORS, None, bound)
        except CmuxError as error:
            raise self.sdk_failure(error, step["id"], "settle") from None
        self.state.replies[step["id"]] = reply
        return ("ok", reply)

    def op_kill(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        process = step["target"]["process"]
        if process != "daemon":
            raise CaseError("Crash", f"the daemon driver kills only the daemon, not a {process} process "
                                     f"(holder kills are p15-oracle-224)", step_id)
        if not self.daemon.running:
            raise CaseError("Failure", "kill: the daemon is not running", step_id)
        name = (step.get("args") or {}).get("signal", "KILL")
        self.remember()
        self.daemon.kill(SIGNALS[name])
        self.state.exits.append(DaemonExit(step_id, "daemon", f"SIG{name} by step {step_id}", self.daemon.exit_code()))
        refusal = crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
        if refusal:
            raise CaseError("Crash", f"I17: {refusal}", step_id)
        self.state.killed_by = step_id
        reply = {"signal": name}
        self.state.replies[step_id] = reply
        return ("ok", reply)

    def op_restart(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        process = step["target"]["process"]
        if process != "daemon":
            raise CaseError("Crash", f"the daemon driver restarts only the daemon, not a {process} process", step_id)
        if self.daemon.running:
            self.remember()
            self.daemon.stop(step_id, end_terminals=False)
        self.daemon.start(step_id)
        self.state.killed_by = None
        self.state.replies[step_id] = dict(self.daemon.identity)
        return ("ok", self.daemon.identity)

    def op_advance_clock(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        ms = int(step["args"]["ms"])
        if not self.daemon.running:
            raise CaseError("Failure", "advance_clock: the daemon is not running", step_id)
        try:
            reply = self.daemon.command("oracle-advance-clock", step_id, ms=ms)
        except KeyError:
            raise CaseError("Crash", "advance_clock: this cmux-tui has no oracle-advance-clock (the oracle "
                                     "virtual clock is p15-oracle-185)", step_id) from None
        except CmuxError as error:
            raise self.sdk_failure(error, step_id, "advance_clock") from None
        self.state.replies[step_id] = reply
        return ("ok", reply)

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        expect = step.get("expect")
        if not expect:
            return
        step_id = step["id"]
        kind, detail = outcome
        if expect["outcome"] != kind:
            got = f"error {detail}" if kind == "error" else "ok"
            raise CaseError("Failure", f"expected {expect['outcome']}"
                                       f"{' ' + expect['error'] if 'error' in expect else ''}, got {got}", step_id)
        if kind == "error":
            if detail != expect["error"]:
                raise CaseError("Failure", f"expected error {expect['error']}, got {detail}", step_id)
            return
        receipt = expect.get("receipt")
        if receipt == "mutation_result":
            if not (isinstance(detail, dict) and {"value", "generation", "revision", "replayed"} <= set(detail)):
                raise CaseError("Failure", f"expected a mutation_result receipt, got {json.dumps(detail)[:200]}",
                                step_id)
        elif receipt == "identify":
            if not (isinstance(detail, dict) and "pid" in detail and "generation" in detail):
                raise CaseError("Failure", "expected an identify receipt", step_id)
        elif receipt is not None:
            raise CaseError("Crash", f"receipt kind {receipt} has no daemon reply", step_id)
        if "result" in expect and detail != expect["result"]:
            raise CaseError("Failure", f"result differs: {json.dumps(detail, sort_keys=True)[:300]}", step_id)

    # -- snapshots

    def daemon_facet(self, step: str) -> Any:
        """session.snapshot + settings.snapshot (+ oracle-state extras) with the schema's capture rules."""
        if not self.daemon.running:
            return not_comparable(f"the daemon is not running (killed at step {self.state.killed_by})")
        timeout = REQUEST_S * self.scale
        try:
            session = self.daemon.request("session.snapshot", SELECTORS, None, timeout)
            settings = self.daemon.request("settings.snapshot", SELECTORS, None, timeout)
            extras = self.daemon.oracle_state(step)
        except CmuxError as error:
            raise self.sdk_failure(error, step, "daemon facet") from None
        info = session.get("session") if isinstance(session, dict) else None
        if isinstance(info, dict) and info.get("name") == self.paths.session:
            # The case's own name only isolates its install directory; the fixture's session is `oracle`.
            info["name"] = SESSION_NAME
        doc = self.schema.doc
        node = doc["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]
        facet: Dict[str, Any] = {
            "session": check_snapshot_schema.capture(doc, node["session"], session),
            "settings": check_snapshot_schema.capture(doc, node["settings"], settings),
        }
        if extras is not None:
            if "journal_head" in extras:
                facet["journalHead"] = extras["journal_head"]
            oracle = {key: extras[key] for key in ORACLE_STATE_KEYS if key in extras}
            if oracle:
                facet["oracle"] = oracle
        return facet

    def facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        out = {}
        for name in names:
            if name == "daemon":
                out[name] = self.daemon_facet(step)
            else:
                out[name] = not_comparable(f"the daemon product has no {name} facet", FACET_TASKS.get(name))
        return out

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "schema": "cmux.oracle.snapshot/v1",
            "meta": {
                "case": self.case_id,
                "step": index,
                "checkpoint": checkpoint,
                "product": "daemon",
                "sha": self.sha,
                "host": self.host,
                "clock": "virtual" if self.daemon.virtual_clock else "wall",
                "capturedAtMs": int(time.time() * 1000),
                "facets": list(facets),
            },
            "facets": facets,
        }

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        self.check_alive(step)
        self.state.captures.append(Capture(step, checkpoint, self.snapshot(index, checkpoint, self.facets(names, step))))

    def normalize_context(self) -> normalize.Context:
        roots = tuple(dict.fromkeys([str(self.paths.root), os.path.realpath(self.paths.root)]))
        return normalize.Context(root=roots, home=(str(self.paths.home),))

    def canonical_checkpoints(self) -> List[Dict[str, Any]]:
        captures = self.state.captures
        if not captures:
            return []
        results = normalize.canonicalize_case([c.snapshot for c in captures], self.schema,
                                              self.normalize_context(), [f"{c.step}/{c.checkpoint}" for c in captures])
        return [{"step": c.step, "checkpoint": c.checkpoint, "snapshot": r.value} for c, r in zip(captures, results)]

    # -- teardown and I6

    def remember(self) -> None:
        """Records the case's processes and the sockets they use, before a stop or a kill ends them."""
        tree = descendants(os.getpid(), str(self.paths.root))
        self.known.update((proc.pid, proc) for proc in tree)
        self.sockets |= socket_paths(tree)

    def case_processes(self) -> List[CaseProcess]:
        """The case's live processes: the worker's tree, and the recorded ones still running (on macOS an
        orphan leaves the tree)."""
        live = {proc.pid: proc for proc in descendants(os.getpid(), str(self.paths.root))}
        for proc in still_running(self.known.values()):
            live.setdefault(proc.pid, proc)
        return sorted(live.values(), key=lambda proc: proc.pid)

    def shutdown(self) -> List[str]:
        """Ends what the case started, in order, and proves its process tree empty; returns the problems.
        The session checks the sockets afterwards."""
        problems: List[str] = []
        self.remember()
        not_restarted = ""
        if self.daemon.identity and not self.daemon.running:
            # A daemon a step killed, or that died, left its terminal hosts and its endpoint files: a new one
            # adopts the hosts, rebinds the endpoints, and then ends and removes both.
            try:
                self.daemon.start("teardown")
            except CaseError as error:
                not_restarted = f" (the daemon did not start again to end them: {error.message})"
                self.daemon.kill(signal.SIGKILL)
            self.remember()
        if self.daemon.running:
            try:
                self.daemon.stop("teardown", end_terminals=True)
            except CaseError as error:
                problems.append(f"I6: {error.message}")
                self.daemon.kill(signal.SIGKILL)
        self.daemon.close_clients()
        # The hosts and shells the daemon ended exit on their own time.
        wait_for_exits([proc.pid for proc in self.case_processes()], EXIT_S * self.scale)
        left = self.case_processes()
        if left:
            problems.append(f"I6: processes left after teardown{not_restarted}: "
                            + "; ".join(proc.describe() for proc in left))
            self.sockets |= socket_paths(left)
            if end_processes(left, EXIT_S * self.scale):
                problems.append("I6: processes still alive after SIGKILL")
                self.dirty = True
        reap_orphans(self.daemon.proc.pid if self.daemon.proc is not None else None)
        return problems


def end_processes(procs: Sequence[CaseProcess], timeout: float) -> Set[int]:
    """SIGKILL, then the exit events; returns the pids still alive."""
    for proc in procs:
        try:
            os.kill(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return wait_for_exits([p.pid for p in procs], timeout)


@dataclass
class Proof:
    problems: List[str] = field(default_factory=list)
    # Files the daemon should have removed: no process listens on them, so they are not I6 leaks.
    debt: List[str] = field(default_factory=list)
    # A process survived SIGKILL.
    dirty: bool = False


def prove_clean(paths: CasePaths, sockets: Iterable[str], worker_finished: bool,
                scan: Callable[[], Dict[str, List[CaseProcess]]], timeout: float) -> Proof:
    """Invariant I6 for one case, after its worker. A worker that finished proved its own process tree
    empty; for one that did not, one marker scan of the process table stands in. Then the sockets the case
    used, its root's and its install directory's: one that still listens fails the case, a file with no
    listener is daemon debt. Everything left is killed and removed, so the next case shares nothing."""
    proof = Proof()
    found = set(sockets)
    if not worker_finished:
        left = scan().get(str(paths.root), [])
        if left:
            proof.problems.append("I6: processes left by a worker that did not finish: "
                                  + "; ".join(p.describe() for p in left))
            found |= socket_paths(left)
            if end_processes(left, timeout):
                proof.problems.append("I6: processes still alive after SIGKILL")
                proof.dirty = True
    found |= socket_files(paths.root) | socket_files(paths.install_dir)
    stale = sorted(path for path in found if os.path.lexists(path))
    live = [path for path in stale if has_listener(path)]
    if live:
        proof.problems.append("I6: sockets still listening after teardown: " + ", ".join(live))
    dead = [path for path in stale if path not in live]
    if dead:
        proof.debt.append("socket files with no listener after teardown (the daemon did not remove them): "
                          + ", ".join(dead))
    long = sorted(path for path in found if len(os.fsencode(path)) > SOCKET_LIMIT)
    if long:
        proof.problems.append(f"socket paths over {SOCKET_LIMIT} bytes: " + ", ".join(long))
    for path in stale:
        try:
            os.unlink(path)
        except OSError:
            pass
    shutil.rmtree(paths.root, ignore_errors=True)
    # The case's own install directory (CasePaths.session); the shared /tmp/cmux-th-<uid> stays.
    shutil.rmtree(paths.install_dir, ignore_errors=True)
    return proof


class Waiter:
    """waitFor on a daemon facet pointer, woken by session.events (Kombucha WaitForState)."""

    def __init__(self, run: CaseRun, step: Mapping[str, Any]):
        self.run = run
        self.step_id = step["id"]
        self.spec = step["waitFor"]
        self.pointer = self.spec["pointer"]
        self.facet = decode_pointer(self.pointer)[0]
        self.stream = None
        self.stream_start = -1
        self.baseline = self.value()
        self.open()

    def value(self) -> Any:
        facets = self.run.facets([self.facet], self.step_id)
        if facets[self.facet].get("status") == "not-comparable":
            return MISSING
        return resolve_pointer(facets, self.pointer)

    def open(self) -> None:
        """Subscribes before the step acts and again after a restart, so no change is missed."""
        self.close()
        daemon = self.run.daemon
        if self.facet != "daemon" or not daemon.running or daemon.conn is None:
            return
        try:
            self.stream = daemon.conn.open_stream("session.events", SELECTORS, lambda item: item,
                                                  timeout=REQUEST_S * self.run.scale)
        except CmuxError as error:
            raise self.run.sdk_failure(error, self.step_id, "session.events") from None
        self.stream_start = daemon.starts

    def close(self) -> None:
        if self.stream is not None:
            try:
                self.stream.close()
            except CmuxError:
                pass
            self.stream = None

    def finish(self) -> None:
        bound = self.spec["maxMs"] / 1000 * self.run.scale
        deadline = time.monotonic() + bound
        while True:
            if self.run.daemon.starts != self.stream_start:
                self.open()
            if predicate_holds(self.spec, self.value(), self.baseline):
                return
            remaining = deadline - time.monotonic()
            if self.stream is None or remaining <= 0:
                raise CaseError("Timeout", f"waitFor {self.pointer} did not hold within {bound * 1000:.0f} ms",
                                self.step_id)
            try:
                self.stream.next(timeout=remaining)
            except SdkTimeout:
                continue
            except (StreamError, StopIteration):
                self.stream_start = -1  # a gap or an end: subscribe again, then re-read
            except CmuxError as error:
                raise self.run.sdk_failure(error, self.step_id, "session.events") from None


# ---------------------------------------------------------------------------------------------------------
# Driver protocol (oracle.py)


class DaemonSession:
    """The daemon product's session. Each case runs in its own worker process (`case-worker`), as
    Chrome's test launcher runs each test in a child: hundreds of cases run in parallel without one
    interpreter lock or one descriptor table, and a hung or crashed worker fails only its case. The
    session itself gives out the state roots and checks each case's sockets after its worker; `scan` (the
    whole-table marker scan) runs only for a worker that did not finish."""

    def __init__(self, session_ctx: Mapping[str, Any],
                 scan: Callable[[], Dict[str, List[CaseProcess]]] = scan_markers):
        binary = session_ctx.get("binary")
        if not binary:
            raise ValueError("the daemon driver needs --binary (the cmux-tui that linux_run.sh build prints)")
        if not os.access(str(binary), os.X_OK):
            raise ValueError(f"--binary {binary} is not an executable")
        if session_ctx.get("switches"):
            raise ValueError("switch arms reach the daemon in p15-oracle-049; this driver runs the default arms")
        self.schema_path = str(session_ctx.get("snapshot_schema") or normalize.DEFAULT_SCHEMA)
        schema, refusal = load_snapshot_schema(self.schema_path)
        if schema is None:
            raise ValueError(f"normalize.py refuses the snapshot schema, so no snapshot can be canonical: {refusal}")
        self.scan = scan
        self.binary = os.path.realpath(str(binary))
        self.session_ctx = dict(session_ctx)
        self.sha = resolve_sha(session_ctx.get("ref"), self.binary)

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        case_id = case_ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        paths = CasePaths.for_case(case_ctx.get("state_root"), str(self.session_ctx.get("run_id") or "run"),
                                   str(case_ctx.get("key") or case_id))
        try:
            paths.check()
            paths.create()
        except CaseError as error:
            return {"status": error.status, "message": error.message, "checkpoints": []}
        scale = float(case_ctx.get("timeout_multiplier") or 1)
        result, finished = self.run_worker(case, {**case_ctx, "state_root": str(paths.root)}, scale)
        proof = prove_clean(paths, result.pop("sockets", ()), finished, self.scan, EXIT_S * scale)
        if proof.problems:
            result["message"] = "; ".join(filter(None, [result.get("message"), *proof.problems]))
            if result["status"] == "Pass":
                result["status"] = "Failure"
        if proof.debt:
            result["daemon_debt"] = proof.debt
            result["message"] = "; ".join(filter(None, [result.get("message"),
                                                        *(f"daemon debt (not I6): {d}" for d in proof.debt)]))
        if proof.dirty:
            result["session_dirty"] = True
        return result

    def run_worker(self, case: Dict[str, Any], case_ctx: Dict[str, Any],
                   scale: float) -> Tuple[Dict[str, Any], bool]:
        """The worker's result, and whether it finished (then it proved its own process tree empty)."""
        payload = {"binary": self.binary, "sha": self.sha, "schema": self.schema_path, "case": case,
                   "ctx": case_ctx, "session": self.session_ctx}
        bound = worker_bound(case, scale)
        worker = subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()), "case-worker"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = worker.communicate(json.dumps(payload).encode(), timeout=bound)
        except subprocess.TimeoutExpired:
            # SIGTERM first: the worker ends its process tree (end_tree_on_term), then the session kills it.
            worker.terminate()
            try:
                out, err = worker.communicate(timeout=EXIT_S * scale)
            except subprocess.TimeoutExpired:
                worker.kill()
                out, err = worker.communicate()
            return {"status": "Timeout", "checkpoints": [], "session_dirty": True,
                    "message": f"the case worker ran over its bound of {bound:.0f} s: {tail(err)}"}, False
        try:
            result = json.loads(out) if worker.returncode == 0 else None
        except ValueError:
            result = None
        if not isinstance(result, dict):
            return {"status": "Crash", "checkpoints": [], "session_dirty": True,
                    "message": f"the case worker failed (exit {worker.returncode}): {tail(err)}"}, False
        return result, True

    def close(self) -> None:
        """Nothing outlives a case: each run_case ends its worker and proves I6."""


def worker_bound(case: Mapping[str, Any], scale: float) -> float:
    """Seconds a case worker may take: every bound the case can wait on, so only a hang reaches it."""
    steps = case.get("steps") or ()
    waits = sum(((s.get("waitFor") or {}).get("maxMs", 0) + s.get("settleMaxMs", 0)) / 1000 for s in steps)
    stop = SHUTDOWN_S + STOP_S
    restarts = sum(1 for s in steps if s.get("op") == "restart") * (READY_S + stop)
    return scale * (2 * READY_S + 2 * stop + 6 * EXIT_S + len(steps) * 4 * REQUEST_S + waits + restarts)


def tail(data: bytes) -> str:
    return data[-LOG_TAIL_BYTES:].decode("utf-8", "replace").strip()


def case_worker() -> int:
    """`case-worker`: one case from the JSON payload on stdin; the result JSON on stdout."""
    payload = json.load(sys.stdin)
    schema, refusal = load_snapshot_schema(payload["schema"])
    if schema is None:
        raise SystemExit(f"driver_daemon.py case-worker: {refusal}")
    run = CaseRun(payload["binary"], payload["sha"], schema, payload["case"], payload["ctx"], payload["session"])
    # Every process the case starts stays in this worker's tree, whatever it does (I6).
    become_subreaper()
    signal.signal(signal.SIGTERM, partial(end_tree_on_term, str(run.paths.root)))
    json.dump(run.run(), sys.stdout)
    return 0


def end_tree_on_term(marker: str, signum: int, _frame: Any) -> None:
    """The session's SIGTERM to a worker over its bound: ends the case's processes, then the worker."""
    end_processes(descendants(os.getpid(), marker), EXIT_S)
    os._exit(128 + signum)


def open_session(session_ctx: Dict[str, Any]) -> DaemonSession:
    return DaemonSession(session_ctx)


def resolve_sha(ref: Any, binary: str) -> str:
    """The SHA under test: a full-SHA ref, else the build receipt beside the binary (linux_run.sh)."""
    if isinstance(ref, str) and re.fullmatch(r"[0-9a-f]{40}", ref):
        return ref
    receipt = Path(binary).parent / "oracle-build-receipt.json"
    try:
        sha = json.loads(receipt.read_text(encoding="utf-8")).get("sha")
    except (OSError, ValueError):
        sha = None
    if isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha):
        return sha
    # meta.sha is volatile (diff.py prints it); an unknown build says so with zeros.
    return "0" * 40


# ---------------------------------------------------------------------------------------------------------
# CLI


def noop_case(index: int) -> Dict[str, Any]:
    return {
        "corpusVersion": 1, "id": f"noop-{index}", "suite": "smoke",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"}, "environment": {},
        "fixture": {"seed": f"noop-{index}", "network": "offline", "clock": "fixed"},
        "preconditions": [], "requires": ["resource_api"], "platforms": ["linux", "mac"],
        "steps": [{"id": "noop", "op": "snapshot", "args": {"facets": ["daemon"]}}],
        "invariants": [], "teardown": ["stop the case daemon"],
    }


def remove_empty_dir(path: Path) -> None:
    """A run's state base, once its cases removed their roots (a root left behind keeps it)."""
    try:
        path.rmdir()
    except OSError:
        pass


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    run_id = args.run_id or f"rc-{os.getpid()}-{time.time_ns()}"
    session = open_session({"binary": args.binary, "run_id": run_id, "ref": args.ref,
                            **getattr(args, "session_extra", {})})
    base = args.state_base / short_token(run_id)
    ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": "0", "state_root": str(base / short_token(case["id"]))}
    result = session.run_case(case, ctx)
    remove_empty_dir(base)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if result["status"] == "Pass" else 1


def cmd_smoke(args: argparse.Namespace) -> int:
    """N cases at once (no-op cases, or N copies of --case), then nothing of theirs may be left: the test
    of task 023. Checks the marker of every case root, `pgrep -f` of the run's state base, and the cases'
    roots and install directories. Daemon debt is reported; it does not fail the run."""
    run_id = args.run_id or f"smoke-{os.getpid()}-{time.time_ns()}"
    base = args.state_base / short_token(run_id)
    template = json.loads(Path(args.case).read_text(encoding="utf-8")) if args.case else None
    session = open_session({"binary": args.binary, "run_id": run_id, **getattr(args, "session_extra", {})})
    started = time.monotonic()

    roots = [base / f"{index:06d}"[-6:] for index in range(args.cases)]

    def one(index: int) -> Dict[str, Any]:
        case = noop_case(index) if template is None else {**template, "id": f"{template['id']}-{index}"}
        ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": str(index), "state_root": str(roots[index])}
        return session.run_case(case, ctx)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(one, range(args.cases)))
    counts: Dict[str, int] = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    marked = sorted(f"{p.pid} {marker}" for marker, procs in scan_markers().items()
                    if marker.startswith(f"{base}/") for p in procs)
    pgrep = subprocess.run(["pgrep", "-f", str(base)], check=False, stdout=subprocess.PIPE, text=True).stdout.split()
    leftover_roots = glob.glob(str(base / "*"))
    leftover_installs = [str(CasePaths(root).install_dir) for root in roots if CasePaths(root).install_dir.exists()]
    debt = [r for r in results if r.get("daemon_debt")]
    report = {
        "binary": session.binary, "sha": session.sha,
        "cases": args.cases, "jobs": args.jobs, "seconds": round(time.monotonic() - started, 1), "counts": counts,
        "marked_processes_left": marked, "pgrep_left": pgrep, "state_roots_left": leftover_roots,
        "install_dirs_left": leftover_installs,
        "failures": [r["message"][:300] for r in results if r["status"] != "Pass"][:5],
        "daemon_debt_cases": len(debt), "daemon_debt": [r["daemon_debt"][0][:300] for r in debt][:3],
    }
    print(json.dumps(report, indent=1, sort_keys=True))
    shutil.rmtree(base, ignore_errors=True)
    ok = (counts.get("Pass", 0) == args.cases and not marked and not pgrep and not leftover_roots
          and not leftover_installs)
    return 0 if ok else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("case-worker", help="internal: one case from a JSON payload on stdin (DaemonSession)")
    for name in ("run-case", "smoke"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--binary", required=True, help="the cmux-tui to run")
        cmd.add_argument("--snapshot-schema", help="the snapshot schema (default: normalize.py's)")
        cmd.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
        cmd.add_argument("--run-id")
        if name == "run-case":
            cmd.add_argument("case", help="a case-v1 JSON file")
            cmd.add_argument("--ref", help="the SHA under test (meta.sha)")
        else:
            cmd.add_argument("--cases", type=int, default=300)
            cmd.add_argument("--jobs", type=int, default=300)
            cmd.add_argument("--case", help="run N copies of this case-v1 file instead of no-op cases")
    args = parser.parse_args(argv)
    if args.command == "case-worker":
        return case_worker()
    if args.snapshot_schema:
        args.session_extra = {"snapshot_schema": args.snapshot_schema}
    try:
        return cmd_run_case(args) if args.command == "run-case" else cmd_smoke(args)
    except ValueError as error:
        print(f"driver_daemon.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
