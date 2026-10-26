#!/usr/bin/env python3
"""The oracle's daemon driver: one isolated cmux-tui per case, driven only through the Python SDK.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D and 3G and task 023. Stdlib plus the
cmux Python SDK of this checkout (cmux-tui/bindings/python), Python 3.9+, safe under `python3 -I`.
It implements the driver protocol of oracle.py (`open_session`, `session.run_case`, `session.close`).

Each case gets:
- its own state root `/tmp/o/<run6>/<case6>` (oracle.py gives it out), holding the daemon's socket
  (`s.sock`, so every socket path stays <= 100 bytes, under Linux's 108-byte sun_path), state, HOME,
  XDG dirs, TMPDIR, config and log. Nothing is shared with another case: the terminal hosts bind in a
  per-install directory (`CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT=1`, honored by debug-assertion builds such
  as `--profile oracle`) and the holder's socket is keyed by the case's host root.
- one `cmux-tui --headless` child started in its own session, awaited on its readiness pipe
  (`--owner-ready-fd`, the daemon's own startup protocol), never by probing the socket.
- the environment of hermetic_env.daemon_case only (an `env -i` base, CMUX_TUI_OFFLINE=1, version
  control without the person's config), and on Linux its own user and network namespace (`unshare -rn`,
  loopback only). The session picks the isolation once (`isolation` in the session context or
  `--isolation`: netns by default, which refuses a host without unprivileged user namespaces; auto;
  none); each case result carries the environment it ran with (`environment`), and
  `<out_dir>/environment.json` lists it for the run.
- every request through the SDK: resource operations on `cmux._protocol.ProtocolConnection` (the SDK's
  wire layer; the oracle compares wire replies, so it does not decode them into dataclasses), and the
  daemon-control commands (`identify`, `shutdown-daemon`, `oracle-state`, `oracle-advance-clock`) on
  `cmux.raw.CmuxClient`.

Steps: resource.call, snapshot, settle (one ping round trip: the daemon acknowledges a mutation after
it committed it, so the next read on the connection sees it), kill and restart of the daemon process,
advance_clock (`oracle-advance-clock {ms}` of task p15-oracle-185), and waitFor on session.events (each
event re-reads the facet; no sleeps). cli, mcp, action.run, key and tui.key belong to the other drivers.

Each case runs in its own worker process (`case-worker`); the session in oracle.py's process gives out
the state roots and proves invariant I6 (no orphan processes or sockets) after each worker, whether it
passed, crashed or hung. Every process of a case carries its marker (`CMUX_ORACLE_CASE=<state root>`).
Before the daemon stops or is killed, the worker records its process tree (/proc/<pid>/task/*/children)
and the sockets those processes use; at the end it asks the daemon to stop and end its terminals
(`shutdown-daemon end_terminals`; a daemon the case killed is started again first, since only a daemon
ends its holder's terminals), waits for those exits on pidfds (kqueue on macOS), and ends a holder left
with no terminal (idle by design; it would exit after its idle exit). The proof is then one pass over the
whole process table for the marker (joined across the cases that end together) and a check of every
recorded socket: anything left fails the case, and is killed, so the next case shares nothing.

Chrome reference (chromium/src):
- base/test/launcher/test_launcher.cc: each test child runs in its own process group and the launcher
  kills what remains of that group when the test ends (KillSpawnedTestProcesses), so a leaked process
  never outlives its test. A holder calls setsid(), so the marker env stands in for the group here.
- chrome/test/base/in_process_browser_test.cc: a fresh temporary user data dir per test
  (temp_user_data_dir_), the per-case state root's model.

Usage:
  driver_daemon.py run-case --binary CMUX_TUI CASE.json [--state-base DIR] [--snapshot-schema S]
                            [--isolation netns|auto|none]
                                                     one case, its result JSON
  driver_daemon.py smoke --binary CMUX_TUI [--cases 300] [--jobs 300] [--case CASE.json] [--isolation ...]
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
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from functools import lru_cache
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
import hermetic_env  # noqa: E402 - sibling of this file (p15-oracle-200), the only place env is built
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
SESSION_NAME = "oracle"
SOCKET_LIMIT = hermetic_env.MAX_SOCKET_PATH_BYTES
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
        return self.root / hermetic_env.SOCKET_NAME

    @property
    def state(self) -> Path:
        return self.root / hermetic_env.STATE_DIR

    @property
    def home(self) -> Path:
        return self.root / hermetic_env.HOME_DIR

    @property
    def run(self) -> Path:
        return self.root / hermetic_env.RUN_DIR

    @property
    def tmp(self) -> Path:
        return self.root / hermetic_env.TMP_DIR

    @property
    def log(self) -> Path:
        return self.root / "daemon.log"

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


def host_platform() -> str:
    return "linux" if sys.platform.startswith("linux") else "mac"


def case_environment(paths: CasePaths, seed: str, isolation: hermetic_env.Isolation) -> hermetic_env.CaseEnv:
    """The case daemon's whole environment, from hermetic_env.py, with this driver's process marker."""
    return hermetic_env.daemon_case(paths.root, isolation, platform=host_platform(), seed=seed,
                                    extra={MARKER_ENV: str(paths.root)})


# ---------------------------------------------------------------------------------------------------------
# Processes: marked processes, their sockets, exit waits


@dataclass(frozen=True)
class CaseProcess:
    pid: int
    ppid: int
    argv: Tuple[str, ...]

    def describe(self) -> str:
        return f"{self.pid} {' '.join(self.argv)[:120]}"

    @property
    def is_holder(self) -> bool:
        return bool(self.argv) and os.path.basename(self.argv[0]).startswith("cmux-holder")


def _stat_fields(pid: int) -> Optional[List[bytes]]:
    """Fields of /proc/<pid>/stat after the command name ("S ppid ..."), or None once it is gone."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            return handle.read().rsplit(b")", 1)[-1].split()
    except OSError:
        return None


def _linux_process(pid: int, needle: bytes) -> Optional[CaseProcess]:
    """The live process `pid` if its environment carries `needle` (a reused pid does not)."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as handle:
            if needle not in handle.read().split(b"\0"):
                return None
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            argv = tuple(part.decode("utf-8", "replace") for part in handle.read().split(b"\0") if part)
    except OSError:
        return None  # exited while we looked, or not ours
    fields = _stat_fields(pid)
    # A zombie (Z) has exited; its parent has not reaped it yet.
    if not fields or fields[0] == b"Z":
        return None
    return CaseProcess(pid, int(fields[1]), argv)


def _ps_table() -> List[Tuple[int, int, bytes, Tuple[str, ...]]]:
    """(pid, ppid, state, argv) of every process, with the environment words of this user's own processes
    (BSD ps `e` appends them to the command): the macOS source of the functions below."""
    out = subprocess.run(["ps", "-axeww", "-o", "pid=,ppid=,stat=,command="], check=False,
                         stdout=subprocess.PIPE).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            rows.append((int(parts[0]), int(parts[1]), parts[2],
                         tuple(word for word in parts[3].decode("utf-8", "replace").split(" ") if word)))
    return rows


def _ps_process(row: Tuple[int, int, bytes, Tuple[str, ...]], needle: str) -> Optional[CaseProcess]:
    pid, ppid, state, words = row
    if state.startswith(b"Z") or needle not in words:
        return None
    # The environment follows the command: its first NAME=value word ends argv.
    end = next((i for i, word in enumerate(words) if ENV_WORD.match(word)), len(words))
    return CaseProcess(pid, ppid, words[:end])


def process_tree(root: int, marker: str) -> List[CaseProcess]:
    """`root` and its live descendants that carry the case's marker.

    Walks /proc/<pid>/task/*/children down from the case daemon, so a case reads its own few processes,
    never the host's whole process table (tens of thousands on the shared VM).
    """
    needle = f"{MARKER_ENV}={marker}"
    if not sys.platform.startswith("linux"):
        rows = _ps_table()
        children: Dict[int, List[int]] = {}
        for pid, ppid, _state, _words in rows:
            children.setdefault(ppid, []).append(pid)
        by_pid = {row[0]: row for row in rows}
        found, stack = [], [root]
        while stack:
            pid = stack.pop()
            proc = _ps_process(by_pid[pid], needle) if pid in by_pid else None
            if proc is not None:
                found.append(proc)
            stack.extend(children.get(pid, ()))
        return found
    found, stack, seen = [], [root], {root}
    while stack:
        pid = stack.pop()
        proc = _linux_process(pid, needle.encode())
        if proc is None:
            continue
        found.append(proc)
        for path in glob.glob(f"/proc/{pid}/task/*/children"):
            try:
                with open(path, "rb") as handle:
                    kids = [int(value) for value in handle.read().split()]
            except OSError:
                continue
            for kid in kids:
                if kid not in seen:
                    seen.add(kid)
                    stack.append(kid)
    return found


def still_running(known: Iterable[CaseProcess], marker: str) -> List[CaseProcess]:
    """The processes of `known` that still run, with their current parent (a holder is re-parented when
    its daemon exits)."""
    needle = f"{MARKER_ENV}={marker}"
    if not sys.platform.startswith("linux"):
        rows = {row[0]: row for row in _ps_table()}
        procs = (_ps_process(rows[p.pid], needle) if p.pid in rows else None for p in known)
    else:
        procs = (_linux_process(p.pid, needle.encode()) for p in known)
    return [proc for proc in procs if proc is not None]


def scan_markers() -> Dict[str, List[CaseProcess]]:
    """Every live process that carries a case marker, by marker: one pass over the whole process table."""
    found: Dict[str, List[CaseProcess]] = {}
    prefix = f"{MARKER_ENV}="
    if not sys.platform.startswith("linux"):
        for row in _ps_table():
            marks = [word for word in row[3] if word.startswith(prefix)]
            proc = _ps_process(row, marks[0]) if marks else None
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


class MarkerScan:
    """The I6 proof's whole-table scan, joined: a case that asks waits for the next scan that starts after
    it asked, and every case waiting then shares that one pass (request joining). 300 cases ending at once
    cost a few scans of the host's process table, not 300."""

    def __init__(self, scan: Callable[[], Dict[str, List[CaseProcess]]] = scan_markers):
        self._scan = scan
        self._changed = threading.Condition()
        self._started = 0
        self._done = 0
        self._running = False
        self._result: Dict[str, List[CaseProcess]] = {}

    def find(self, marker: str) -> List[CaseProcess]:
        with self._changed:
            wanted = self._started + 1
            while self._done < wanted:
                if self._running:
                    self._changed.wait()
                    continue
                self._running = True
                self._started += 1
                generation = self._started
                result: Optional[Dict[str, List[CaseProcess]]] = None
                self._changed.release()
                try:
                    result = self._scan()
                finally:
                    self._changed.acquire()
                    self._running = False
                    if result is not None:
                        self._result, self._done = result, generation
                    self._changed.notify_all()
            return list(self._result.get(marker, ()))


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

    def __init__(self, binary: str, paths: CasePaths, case_env: hermetic_env.CaseEnv, scale: float):
        self.binary = binary
        self.paths = paths
        self.case_env = case_env
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
        argv = [self.binary, "--headless", "--session", SESSION_NAME, "--socket", str(self.paths.socket),
                "--state", str(self.paths.state), "--owner-ready-fd", str(write_fd)]
        try:
            with open(self.paths.log, "ab") as log:
                self.proc = subprocess.Popen(
                    self.case_env.command(argv), env=dict(self.case_env.env), cwd=str(self.case_env.cwd),
                    pass_fds=(write_fd,), stdin=subprocess.DEVNULL,
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
        response = self.raw.request(cmd, **params)
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
        """`shutdown-daemon` for this generation, then the child's exit."""
        try:
            self.command("shutdown-daemon", step, pid=int(self.identity["pid"]),
                         generation=str(self.identity["generation"]), force=True, end_terminals=end_terminals)
        except (CmuxError, KeyError) as error:
            raise CaseError("Crash", f"shutdown-daemon failed: {error!r}", step) from None
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
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any], isolation: hermetic_env.Isolation):
        self.case = case
        self.schema = schema
        self.known: Dict[int, CaseProcess] = {}
        self.sockets: Set[str] = set()
        self.case_id = ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        self.scale = float(ctx.get("timeout_multiplier") or 1)
        self.paths = CasePaths.for_case(ctx.get("state_root"), str(session_ctx.get("run_id") or "run"),
                                        str(ctx.get("key") or self.case_id))
        fixture = case.get("fixture") or {}
        seed = str(fixture.get("seed") or case.get("id") or "oracle")
        self.case_env = case_environment(self.paths, seed, isolation)
        self.daemon = Daemon(binary, self.paths, self.case_env, self.scale)
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
                self.case_env.prepare()
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
                                  "sockets": sorted(self.sockets), "environment": self.case_env.receipt()}
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
        """Records the daemon's process tree and the sockets it uses before anything can orphan them: a
        holder is re-parented when its daemon exits, so after that only this record finds it cheaply."""
        if self.daemon.running:
            tree = process_tree(self.daemon.proc.pid, str(self.paths.root))
            self.known.update((proc.pid, proc) for proc in tree)
            self.sockets |= socket_paths(tree)

    def shutdown(self) -> List[str]:
        """Ends what the case started, in order; returns its problems. The parent proves I6 afterwards."""
        problems: List[str] = []
        marker = str(self.paths.root)
        self.remember()
        if not self.daemon.running and self.daemon.starts:
            # A daemon that a step killed or that died left its holders running, by design: only a daemon
            # ends their terminals, so a new one adopts them. The scan also finds what it orphaned.
            self.known.update((proc.pid, proc) for proc in scan_markers().get(marker, ()))
            if still_running(self.known.values(), marker):
                try:
                    self.daemon.start("teardown")
                except CaseError as error:
                    problems.append(f"I6: the daemon did not restart to end its terminals: {error.message}")
                    self.daemon.kill(signal.SIGKILL)
                self.remember()
        if self.daemon.running:
            try:
                self.daemon.stop("teardown", end_terminals=True)
            except CaseError as error:
                problems.append(f"I6: {error.message}")
                self.daemon.kill(signal.SIGKILL)
        self.daemon.close_clients()
        # The shells the daemon ended exit on their own time; then a holder with no terminal is idle.
        left = still_running(self.known.values(), marker)
        wait_for_exits([p.pid for p in left if not p.is_holder], EXIT_S * self.scale)
        left = still_running(self.known.values(), marker)
        # A holder with no terminal left is idle by design: it exits after its idle exit (30 s) and takes a
        # SIGTERM only from launchd or init. It holds nothing, so the case ends it and removes its socket.
        idle = [p for p in left if p.is_holder and not any(q.ppid == p.pid for q in left)]
        if end_processes(idle, EXIT_S * self.scale):
            self.dirty = True
        for path in socket_paths(idle):
            try:
                os.unlink(path)
            except OSError:
                pass
        return problems


def end_processes(procs: Sequence[CaseProcess], timeout: float) -> Set[int]:
    """SIGKILL, then the exit events; returns the pids still alive."""
    for proc in procs:
        try:
            os.kill(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return wait_for_exits([p.pid for p in procs], timeout)


def prove_clean(paths: CasePaths, sockets: Iterable[str], scan: "MarkerScan", timeout: float) -> Tuple[List[str], bool]:
    """Invariant I6 for one case, whatever its worker did: no process carries the case's marker and no
    socket it used is left. What is left is reported, killed and removed, so the next case shares nothing.
    Returns the problems and whether a process survived SIGKILL."""
    problems: List[str] = []
    dirty = False
    found = set(sockets)
    left = scan.find(str(paths.root))
    if left:
        problems.append("I6: processes left after teardown: " + "; ".join(p.describe() for p in left))
        found |= socket_paths(left)
        if end_processes(left, timeout):
            problems.append("I6: processes still alive after SIGKILL")
            dirty = True
    found |= socket_files(paths.root)
    stale = sorted(path for path in found if os.path.lexists(path))
    if stale:
        problems.append("I6: sockets left after teardown: " + ", ".join(stale))
    long = sorted(path for path in found if len(os.fsencode(path)) > SOCKET_LIMIT)
    if long:
        problems.append(f"socket paths over {SOCKET_LIMIT} bytes: " + ", ".join(long))
    for path in stale:
        try:
            os.unlink(path)
        except OSError:
            pass
    remove_case_dirs(paths.root, found)
    return problems, dirty


def remove_case_dirs(root: Path, sockets: Iterable[str]) -> None:
    """Removes the state root and the empty per-install socket directories outside it."""
    shutil.rmtree(root, ignore_errors=True)
    for path in sockets:
        parent = os.path.dirname(path)
        # /tmp/cmux-th-<uid>/<install>/: the shared /tmp/cmux-*-<uid> directory itself stays.
        if os.path.dirname(os.path.dirname(parent)) == "/tmp" and not parent.startswith(str(root)):
            try:
                os.rmdir(parent)
            except OSError:
                pass


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
    session itself gives out the state roots and proves I6 after each worker, with one joined scan."""

    def __init__(self, session_ctx: Mapping[str, Any]):
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
        try:
            self.isolation = hermetic_env.isolation_for(str(session_ctx.get("isolation") or "netns"), host_platform())
        except hermetic_env.HermeticError as error:
            raise ValueError(f"no hermetic case environment on this host: {error}") from None
        self.scan = MarkerScan()
        self.binary = os.path.realpath(str(binary))
        self.session_ctx = dict(session_ctx)
        self.sha = resolve_sha(session_ctx.get("ref"), self.binary)
        if session_ctx.get("out_dir"):
            write_environment(Path(str(session_ctx["out_dir"])), self.isolation)

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
        result = self.run_worker(case, {**case_ctx, "state_root": str(paths.root)}, scale)
        problems, dirty = prove_clean(paths, result.pop("sockets", ()), self.scan, EXIT_S * scale)
        if problems:
            result["message"] = "; ".join(filter(None, [result.get("message"), *problems]))
            if result["status"] == "Pass":
                result["status"] = "Failure"
        if dirty:
            result["session_dirty"] = True
        return result

    def run_worker(self, case: Dict[str, Any], case_ctx: Dict[str, Any], scale: float) -> Dict[str, Any]:
        payload = {"binary": self.binary, "sha": self.sha, "schema": self.schema_path, "case": case,
                   "ctx": case_ctx, "session": self.session_ctx, "isolation": self.isolation.describe()}
        bound = worker_bound(case, scale)
        worker = subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()), "case-worker"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = worker.communicate(json.dumps(payload).encode(), timeout=bound)
        except subprocess.TimeoutExpired:
            worker.kill()
            out, err = worker.communicate()
            return {"status": "Timeout", "checkpoints": [], "session_dirty": True,
                    "message": f"the case worker ran over its bound of {bound:.0f} s: {tail(err)}"}
        try:
            result = json.loads(out) if worker.returncode == 0 else None
        except ValueError:
            result = None
        if not isinstance(result, dict):
            return {"status": "Crash", "checkpoints": [], "session_dirty": True,
                    "message": f"the case worker failed (exit {worker.returncode}): {tail(err)}"}
        return result

    def close(self) -> None:
        """Nothing outlives a case: each run_case ends its worker and proves I6."""


def worker_bound(case: Mapping[str, Any], scale: float) -> float:
    """Seconds a case worker may take: every bound the case can wait on, so only a hang reaches it."""
    steps = case.get("steps") or ()
    waits = sum(((s.get("waitFor") or {}).get("maxMs", 0) + s.get("settleMaxMs", 0)) / 1000 for s in steps)
    return scale * (2 * READY_S + 2 * STOP_S + 6 * EXIT_S + len(steps) * 4 * REQUEST_S + waits)


def tail(data: bytes) -> str:
    return data[-LOG_TAIL_BYTES:].decode("utf-8", "replace").strip()


def case_worker() -> int:
    """`case-worker`: one case from the JSON payload on stdin; the result JSON on stdout."""
    payload = json.load(sys.stdin)
    schema, refusal = load_snapshot_schema(payload["schema"])
    if schema is None:
        raise SystemExit(f"driver_daemon.py case-worker: {refusal}")
    run = CaseRun(payload["binary"], payload["sha"], schema, payload["case"], payload["ctx"], payload["session"],
                  hermetic_env.Isolation.from_description(payload["isolation"]))
    json.dump(run.run(), sys.stdout)
    return 0


def write_environment(out_dir: Path, isolation: hermetic_env.Isolation) -> None:
    """`<out_dir>/environment.json`: the environment every case of the run gets, the case root and the
    per-case values as tokens (each case result has its own under `environment`)."""
    template = hermetic_env.daemon_case(DEFAULT_STATE_BASE / "run000" / "case00", isolation,
                                        platform=host_platform(), seed="$SEED",
                                        extra={MARKER_ENV: hermetic_env.ROOT_TOKEN})
    out_dir.mkdir(parents=True, exist_ok=True)
    staged = out_dir / f".environment.json.{os.getpid()}.{threading.get_ident()}"
    staged.write_text(json.dumps(template.receipt(), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(staged, out_dir / "environment.json")


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


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    run_id = args.run_id or f"rc-{os.getpid()}-{time.time_ns()}"
    session = open_session({"binary": args.binary, "run_id": run_id, "ref": args.ref,
                            **getattr(args, "session_extra", {})})
    ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": "0",
           "state_root": str(args.state_base / short_token(run_id) / short_token(case["id"]))}
    result = session.run_case(case, ctx)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if result["status"] == "Pass" else 1


def cmd_smoke(args: argparse.Namespace) -> int:
    """N cases at once (no-op cases, or N copies of --case), then nothing of theirs may be left: the test
    of task 023. Checks the marker of every case root and `pgrep -f` of the run's state base."""
    run_id = args.run_id or f"smoke-{os.getpid()}-{time.time_ns()}"
    base = args.state_base / short_token(run_id)
    template = json.loads(Path(args.case).read_text(encoding="utf-8")) if args.case else None
    session = open_session({"binary": args.binary, "run_id": run_id, **getattr(args, "session_extra", {})})
    started = time.monotonic()

    def one(index: int) -> Dict[str, Any]:
        case = noop_case(index) if template is None else {**template, "id": f"{template['id']}-{index}"}
        ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": str(index),
               "state_root": str(base / f"{index:06d}"[-6:])}
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
    report = {
        "cases": args.cases, "jobs": args.jobs, "seconds": round(time.monotonic() - started, 1), "counts": counts,
        "marked_processes_left": marked, "pgrep_left": pgrep, "state_roots_left": leftover_roots,
        "failures": [r["message"][:300] for r in results if r["status"] != "Pass"][:5],
    }
    print(json.dumps(report, indent=1, sort_keys=True))
    shutil.rmtree(base, ignore_errors=True)
    ok = counts.get("Pass", 0) == args.cases and not marked and not pgrep and not leftover_roots
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
        cmd.add_argument("--isolation", choices=hermetic_env.ISOLATION_MODES, default="netns",
                         help="netns: unshare -rn, refuse a host without it (default); auto: netns when the host "
                              "allows it; none: no namespace (each result's environment says so)")
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
    args.session_extra = {"isolation": args.isolation}
    if args.snapshot_schema:
        args.session_extra["snapshot_schema"] = args.snapshot_schema
    try:
        return cmd_run_case(args) if args.command == "run-case" else cmd_smoke(args)
    except ValueError as error:
        print(f"driver_daemon.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
