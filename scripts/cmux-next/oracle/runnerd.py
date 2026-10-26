#!/usr/bin/env python3
"""runnerd: the Linux VM's one queue for oracle builds and suite runs (p15-oracle-007).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3G and task 007. Stdlib only, Linux only
(pidfd), Python 3.9+, safe under `python3 -I`.

    runnerd.py submit --sha SHA --suite S [--arm A] [--profile P] [--target-cache]
                      [--key-path PATH]... [--extra K=V]... [--timeout SEC] -- COMMAND...
    runnerd.py status [--json]
    runnerd.py gc [--budget-gb N]

`submit` behaves like running COMMAND (same stdout, same exit code), but:
- One key per request: (sha, suite, arm, profile) plus the content hash of every --key-path and the
  --extra strings (what else changes the result: the build recipe, the corpus, the run arguments).
- A request whose key is queued or running joins that job; a request whose key already finished with
  exit 0 reuses its receipt and runs nothing. A failed job is not reused: the next submit reruns it.
- Jobs run FIFO, at most --slots at once (default 2: the two arms of one diff), in a dispatcher that
  lives in one `systemd-run --scope -p CPUQuota=24000% -p MemoryMax=600G` under `nice -n 10`, so all
  queued work together stays inside one quota and agent shells keep 120 cores and the rest of memory.
- A job writes its results to RUNNERD_OUT (ROOT/jobs/<digest>/out). --target-cache also gives it
  RUNNERD_TARGET_DIR=ROOT/targets/<sha>-<profile>, a per-SHA cargo target dir that is only a cache.
  Target dirs and job dirs share one 150 GB budget, evicted least recently used first; --hold PATH
  keeps another job's output (a built binary) while this job waits or runs.

Chrome reference (chromium/src):
- net/http/http_cache.cc, http_cache_transaction.cc: concurrent requests for one cache key share one
  ActiveEntry; the first transaction is the writer and later ones are added to the entry and get the
  writer's response instead of starting their own network request (request joining). A stored
  response is served without the network (receipt reuse).
- net/disk_cache/simple/simple_index.cc: eviction starts above high_watermark_ = max_size_ -
  max_size_ / kEvictionMarginDivisor (20) and removes entries by last-used time until the index is
  under low_watermark_ = max_size_ - 2 * (max_size_ / kEvictionMarginDivisor).
- build/toolchain/concurrent_links.gni: a fixed pool bounds the jobs that need most of the machine,
  rather than letting every request start one.

Files under ROOT (default /tmp/oracle-runnerd, or ORACLE_RUNNERD_ROOT):
    lock                 flock of every queue change (short sections, never held while a job runs)
    dispatcher.lock      flock held by the live dispatcher for its whole life
    dispatcher.json      {"pid", "scope", "started"} of the live dispatcher
    wake                 FIFO: a submit writes one byte so the dispatcher looks at the spool
    spool/<seq>-<digest> one empty file per queued job; the lowest seq runs next
    jobs/<digest>/       receipt.json (the job's state and, when done, its receipt), stdout, log,
                         out/ (RUNNERD_OUT), waiters/<fifo> (one per waiting submit)
    targets/<sha>-<profile>/  cargo target dirs (RUNNERD_TARGET_DIR)
    index.json           {"seq", "entries": {"targets/<name>" | "jobs/<digest>": {"bytes", "used"}}}
    trash/               evicted dirs, deleted outside the lock
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = Path("/tmp/oracle-runnerd")
JOB_SCHEMA = "cmux-oracle-runnerd-job-v1"
INDEX_SCHEMA = "cmux-oracle-runnerd-index-v1"
CPU_QUOTA = "24000%"
MEMORY_MAX = "600G"
NICE = 10
DEFAULT_SLOTS = 2
DEFAULT_BUDGET = 150 * 10**9
EVICTION_MARGIN_DIVISOR = 20
DEFAULT_TIMEOUT = 4 * 3600
# A waiter starts a new dispatcher when the one it waits on dies; past this it stops and reports.
MAX_DISPATCHER_STARTS = 5
LOG_TAIL_LINES = 40
SCOPES = ("systemd", "none")
# Jobs get this environment and nothing else from the submit that created them. CMUX_GHOSTTY_SRC is
# left out on purpose: each SHA builds the ghostty-next of its own worktree (p15-oracle-024), and so is
# RUSTUP_TOOLCHAIN: each SHA builds with the toolchain its rust-toolchain.toml pins.
ENV_PASS = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TERM", "TMPDIR",
            "RUSTUP_HOME", "CARGO_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy")
ENV_PASS_PREFIXES = ("ORACLE_", "CMUX_ORACLE_")
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
NAME_RE = re.compile(r"^[A-Za-z0-9._,=+:-]{1,200}$")


class RunnerError(Exception):
    """A bad request or a queue that cannot make progress: exit 2."""


# ---------------------------------------------------------------------------------------
# Layout, lock and small file helpers


@dataclass(frozen=True)
class Layout:
    root: Path

    @property
    def lock(self) -> Path:
        return self.root / "lock"

    @property
    def dispatcher_lock(self) -> Path:
        return self.root / "dispatcher.lock"

    @property
    def dispatcher_info(self) -> Path:
        return self.root / "dispatcher.json"

    @property
    def dispatcher_log(self) -> Path:
        return self.root / "dispatcher.log"

    @property
    def wake(self) -> Path:
        return self.root / "wake"

    @property
    def spool(self) -> Path:
        return self.root / "spool"

    @property
    def jobs(self) -> Path:
        return self.root / "jobs"

    @property
    def targets(self) -> Path:
        return self.root / "targets"

    @property
    def index(self) -> Path:
        return self.root / "index.json"

    @property
    def trash(self) -> Path:
        return self.root / "trash"

    def job(self, digest: str) -> Path:
        return self.jobs / digest

    def ensure(self) -> None:
        for directory in (self.root, self.spool, self.jobs, self.targets, self.trash):
            directory.mkdir(parents=True, exist_ok=True)
        try:
            os.mkfifo(self.wake, 0o600)
        except FileExistsError:
            pass


@contextmanager
def queue_lock(layout: Layout) -> Iterator[None]:
    fd = os.open(layout.lock, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None


def write_json(path: Path, value: Mapping[str, Any]) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def tree_bytes(path: Path) -> int:
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_blocks * 512
            except FileNotFoundError:
                continue
    return total


def move_to_trash(layout: Layout, path: Path) -> None:
    """Called under the lock: a rename is instant; empty_trash deletes outside the lock."""
    try:
        os.rename(path, layout.trash / f"{path.name}.{uuid.uuid4().hex[:12]}")
    except FileNotFoundError:
        pass


def empty_trash(layout: Layout) -> None:
    for entry in layout.trash.iterdir():
        shutil.rmtree(entry, ignore_errors=True)


def process_start_time(pid: int) -> Optional[str]:
    """Field 22 of /proc/PID/stat: tells a live job from a reused pid."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except (FileNotFoundError, ProcessLookupError):
        return None
    return stat[stat.rindex(")") + 2:].split()[19]


def exit_status(returncode: int) -> int:
    return 128 - returncode if returncode < 0 else returncode


# ---------------------------------------------------------------------------------------
# Requests and keys


@dataclass(frozen=True)
class Key:
    sha: str
    suite: str
    arm: str
    profile: str
    extra: Tuple[str, ...] = ()

    def validate(self) -> None:
        if not SHA_RE.match(self.sha):
            raise RunnerError(f"--sha {self.sha!r}: a full commit sha (resolve refs with git rev-parse first)")
        for name, value in (("suite", self.suite), ("arm", self.arm), ("profile", self.profile)):
            if not NAME_RE.match(value):
                raise RunnerError(f"--{name} {value!r}: letters, digits and . _ , = + : - only")

    @property
    def digest(self) -> str:
        blob = json.dumps({"sha": self.sha, "suite": self.suite, "arm": self.arm, "profile": self.profile,
                           "extra": list(self.extra)}, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(blob.encode()).hexdigest()[:24]

    def as_json(self) -> Dict[str, Any]:
        return {"sha": self.sha, "suite": self.suite, "arm": self.arm, "profile": self.profile,
                "extra": list(self.extra)}

    def label(self) -> str:
        return f"{self.sha[:12]} {self.suite} {self.arm} {self.profile}"


def path_digest(path: Path) -> str:
    """Content hash of a file, or of every tracked and untracked (not ignored) file under a dir."""
    path = path.resolve()
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if not path.is_dir():
        raise RunnerError(f"--key-path {path}: no such file or directory")
    proc = subprocess.run(["git", "-C", str(path), "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                           "--", "."], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise RunnerError(f"--key-path {path}: not in a git checkout ({proc.stderr.decode(errors='replace').strip()})")
    digest = hashlib.sha256()
    for name in sorted(set(proc.stdout.split(b"\0")) - {b""}):
        member = path / os.fsdecode(name)
        digest.update(name + b"\0")
        try:
            digest.update(hashlib.sha256(member.read_bytes()).digest())
        except FileNotFoundError:
            digest.update(b"deleted")
    return digest.hexdigest()


def job_environment(source: Mapping[str, str]) -> Dict[str, str]:
    return {name: value for name, value in source.items()
            if name in ENV_PASS or name.startswith(ENV_PASS_PREFIXES)}


@dataclass(frozen=True)
class Request:
    key: Key
    argv: Tuple[str, ...]
    cwd: str
    env: Dict[str, str]
    target_cache: bool
    timeout: float
    holds: Tuple[Path, ...] = ()

    def as_json(self, layout: Layout) -> Dict[str, Any]:
        return {"argv": list(self.argv), "cwd": self.cwd, "env": self.env, "targetCache": self.target_cache,
                "timeout": self.timeout, "holds": sorted({hold_entry(layout, path) for path in self.holds})}


# ---------------------------------------------------------------------------------------
# Dispatcher launch (the quota)


@dataclass(frozen=True)
class Settings:
    layout: Layout
    scope: str
    slots: int
    budget: int

    def dispatcher_command(self, unit: str, lock_fd: int) -> List[str]:
        inner = ["nice", "-n", str(NICE), sys.executable, "-I", str(Path(__file__).resolve()),
                 "--root", str(self.layout.root), "_dispatch", "--slots", str(self.slots), "--budget", str(self.budget),
                 "--scope", self.scope, "--lock-fd", str(lock_fd)]
        if self.scope == "none":
            return inner
        user = [] if os.geteuid() == 0 else ["--user"]
        return ["systemd-run", *user, "--scope", "--quiet", "--collect", f"--unit={unit}",
                "-p", f"CPUQuota={CPU_QUOTA}", "-p", f"MemoryMax={MEMORY_MAX}", "--", *inner]


def settings_from_env(root: Path, env: Mapping[str, str]) -> Settings:
    scope = env.get("ORACLE_RUNNERD_SCOPE", "systemd")
    if scope not in SCOPES:
        raise RunnerError(f"ORACLE_RUNNERD_SCOPE={scope!r}: one of {', '.join(SCOPES)}")
    try:
        slots = int(env.get("ORACLE_RUNNERD_SLOTS", DEFAULT_SLOTS))
        budget = int(float(env.get("ORACLE_RUNNERD_BUDGET_GB", DEFAULT_BUDGET / 10**9)) * 10**9)
    except ValueError as error:
        raise RunnerError(f"ORACLE_RUNNERD_SLOTS / ORACLE_RUNNERD_BUDGET_GB: {error}") from None
    if slots < 1 or budget < 1:
        raise RunnerError("ORACLE_RUNNERD_SLOTS and ORACLE_RUNNERD_BUDGET_GB must be positive")
    return Settings(Layout(root), scope, slots, budget)


@dataclass
class DispatcherHandle:
    pid: int
    child: Optional[subprocess.Popen] = None


def ensure_dispatcher(settings: Settings) -> DispatcherHandle:
    """Called under the queue lock. The new dispatcher inherits the held dispatcher.lock, so there is
    never a moment where a second submit could start another one."""
    layout = settings.layout
    fd = os.open(layout.dispatcher_lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            info = read_json(layout.dispatcher_info) or {}
            return DispatcherHandle(int(info.get("pid", 0)))
        unit = f"cmux-oracle-runnerd-{int(time.time())}-{uuid.uuid4().hex[:6]}"
        with open(layout.dispatcher_log, "ab") as log:
            # `systemd-run --scope` execs the command in its own pid, so the held lock and the pid both
            # carry over to the dispatcher.
            child = subprocess.Popen(settings.dispatcher_command(unit, fd), stdin=subprocess.DEVNULL, stdout=log,
                                     stderr=log, pass_fds=(fd,), start_new_session=True)
        write_json(layout.dispatcher_info, {"pid": child.pid, "scope": settings.scope, "unit": unit,
                                            "started": time.time(), "slots": settings.slots,
                                            "budget": settings.budget})
        return DispatcherHandle(child.pid, child)
    finally:
        os.close(fd)


def wake_dispatcher(layout: Layout) -> None:
    try:
        fd = os.open(layout.wake, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        if error.errno == errno.ENXIO:  # no dispatcher has the FIFO open; a new one reads the spool first
            return
        raise
    try:
        os.write(fd, b"\n")
    except BlockingIOError:
        pass  # the FIFO is full of unread wakes already
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------------------
# Index and eviction


def load_index(layout: Layout) -> Dict[str, Any]:
    return read_json(layout.index) or {"schema": INDEX_SCHEMA, "seq": 0, "entries": {}}


def plan_eviction(entries: Mapping[str, Mapping[str, Any]], budget: int, in_use: Sequence[str]) -> List[str]:
    """simple_index.cc: above the high watermark, oldest first down to the low watermark."""
    margin = budget // EVICTION_MARGIN_DIVISOR
    high, low = budget - margin, budget - 2 * margin
    total = sum(int(entry["bytes"]) for entry in entries.values())
    if total <= high:
        return []
    victims = []
    busy = set(in_use)
    for name, entry in sorted(entries.items(), key=lambda item: (item[1]["used"], item[0])):
        if total <= low:
            break
        if name in busy:
            continue
        victims.append(name)
        total -= int(entry["bytes"])
    return victims


def evict(layout: Layout, index: Dict[str, Any], budget: int, in_use: Sequence[str]) -> List[str]:
    """Under the lock: removes the victims from the index and moves their dirs to the trash. A target
    dir is only a cache: a job's results live in its own RUNNERD_OUT, so they outlive it."""
    victims = plan_eviction(index["entries"], budget, in_use)
    for name in victims:
        index["entries"].pop(name, None)
        move_to_trash(layout, layout.root / name)
    return victims


def busy_entries(layout: Layout) -> List[str]:
    """Index names that a queued or running job holds: its own, its target dir and its --hold paths."""
    names = []
    for receipt_path in layout.jobs.glob("*/receipt.json"):
        receipt = read_json(receipt_path)
        if receipt and receipt["state"] in ("queued", "running"):
            names.append(f"jobs/{receipt['digest']}")
            names.extend(receipt["request"].get("holds", []))
            if receipt.get("targetDir"):
                names.append(f"targets/{Path(receipt['targetDir']).name}")
    return names


def hold_entry(layout: Layout, path: Path) -> str:
    """The index name (jobs/<digest> or targets/<name>) that holds PATH, an output of another job."""
    try:
        parts = path.resolve().relative_to(layout.root.resolve()).parts
    except ValueError:
        raise RunnerError(f"--hold {path}: not under {layout.root}") from None
    if len(parts) < 2 or parts[0] not in ("jobs", "targets"):
        raise RunnerError(f"--hold {path}: not inside a job or target dir of {layout.root}")
    return f"{parts[0]}/{parts[1]}"


# ---------------------------------------------------------------------------------------
# submit


@dataclass
class Waiter:
    fifo: Path
    fd: int

    @classmethod
    def register(cls, job_dir: Path) -> "Waiter":
        waiters = job_dir / "waiters"
        waiters.mkdir(exist_ok=True)
        fifo = waiters / f"{os.getpid()}-{uuid.uuid4().hex[:8]}"
        os.mkfifo(fifo, 0o600)
        # Read-write: the dispatcher's non-blocking open always finds a reader, and no EOF arrives early.
        return cls(fifo, os.open(fifo, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC))

    def wait(self, dispatcher: DispatcherHandle) -> bool:
        """True when the job finished; False when the dispatcher died first."""
        try:
            pidfd = os.pidfd_open(dispatcher.pid) if dispatcher.pid > 0 else -1
        except ProcessLookupError:
            pidfd = -1
        if pidfd < 0:
            return self._ready()
        with selectors.DefaultSelector() as selector:
            selector.register(self.fd, selectors.EVENT_READ, "job")
            selector.register(pidfd, selectors.EVENT_READ, "dispatcher")
            try:
                events = selector.select()
            finally:
                os.close(pidfd)
        return any(key.data == "job" for key, _ in events) or self._ready()

    def _ready(self) -> bool:
        try:
            return bool(os.read(self.fd, 64))
        except BlockingIOError:
            return False

    def close(self) -> None:
        os.close(self.fd)
        try:
            self.fifo.unlink()
        except FileNotFoundError:
            pass


def new_receipt(layout: Layout, request: Request, seq: int) -> Dict[str, Any]:
    return {
        "schema": JOB_SCHEMA,
        "digest": request.key.digest,
        "key": request.key.as_json(),
        "state": "queued",
        "seq": seq,
        "request": request.as_json(layout),
        "submitted": time.time(),
        "submits": 1,
        "joins": 0,
        "reuses": 0,
        "host": socket.gethostname(),
    }


@dataclass(frozen=True)
class Result:
    receipt: Dict[str, Any]
    stdout: bytes
    log_tail: List[str]


def read_result(layout: Layout, digest: str) -> Result:
    """Under the lock, so a resubmit of a failed key cannot replace the job dir while it is read."""
    job_dir = layout.job(digest)
    receipt = read_json(job_dir / "receipt.json")
    if receipt is None or receipt["state"] not in ("done", "failed"):
        raise RunnerError(f"job {digest}: no finished receipt in {job_dir}")
    tail: List[str] = []
    if receipt["exit"] != 0 or receipt.get("timedOut"):
        log = (job_dir / "log").read_text(encoding="utf-8", errors="replace").splitlines()
        tail = log[-LOG_TAIL_LINES:]
    return Result(receipt, (job_dir / "stdout").read_bytes(), tail)


def submit(settings: Settings, request: Request, stdout=None, stderr=None) -> int:
    """Joins the queued or running job of the key, reuses its finished receipt, or queues it; then
    replays the job's stdout and returns its exit code."""
    stdout = stdout or sys.stdout.buffer
    stderr = stderr or sys.stderr
    layout = settings.layout
    request.key.validate()
    if "RUNNERD_JOB" in os.environ:
        raise RunnerError("submit from inside a runnerd job would wait on its own queue; run the command directly")
    layout.ensure()
    digest = request.key.digest
    job_dir = layout.job(digest)
    first = True
    deaths = 0
    while True:
        waiter: Optional[Waiter] = None
        with queue_lock(layout):
            receipt = read_json(job_dir / "receipt.json")
            state = receipt["state"] if receipt else None
            # A failed job is reused only by the submits that waited on it; a new submit reruns it.
            if state == "done" or (state == "failed" and not first):
                if first:
                    receipt["reuses"] += 1
                    receipt["submits"] += 1
                    write_json(job_dir / "receipt.json", receipt)
                    touch_entries(layout, receipt)
                result = read_result(layout, digest)
            else:
                if state in (None, "failed"):
                    mode = "queued"
                    create_job(layout, request)
                else:
                    mode = "joined"
                    if first:
                        receipt["joins"] += 1
                        receipt["submits"] += 1
                        write_json(job_dir / "receipt.json", receipt)
                waiter = Waiter.register(job_dir)
                dispatcher = ensure_dispatcher(settings)
                if mode == "queued":
                    wake_dispatcher(layout)
        if waiter is None:
            empty_trash(layout)
            return emit(result, "reused" if first else "finished", job_dir, stdout, stderr)
        if first:
            print(f"runnerd: {mode} job {digest} ({request.key.label()}); log {job_dir / 'log'}", file=stderr)
        first = False
        try:
            finished = waiter.wait(dispatcher)
        finally:
            waiter.close()
            if dispatcher.child is not None:
                dispatcher.child.poll()
        if finished:
            continue  # the top of the loop reads the result (or joins a rerun another submit queued)
        deaths += 1
        if deaths >= MAX_DISPATCHER_STARTS:
            raise RunnerError(f"the dispatcher exited {deaths} times before job {digest} finished; "
                              f"see {layout.dispatcher_log}")
        print(f"runnerd: dispatcher {dispatcher.pid} exited before job {digest} finished; starting another",
              file=stderr)


def create_job(layout: Layout, request: Request) -> None:
    """Under the lock: a fresh job dir (a failed one goes to the trash) and its spool entry."""
    for path in request.holds:
        hold_entry(layout, path)
        if not path.exists():
            raise RunnerError(f"--hold {path}: evicted since its job finished; submit that job again")
    job_dir = layout.job(request.key.digest)
    index = load_index(layout)
    if job_dir.exists():
        index["entries"].pop(f"jobs/{request.key.digest}", None)
        move_to_trash(layout, job_dir)
    index["seq"] += 1
    seq = index["seq"]
    write_json(layout.index, index)
    job_dir.mkdir()
    write_json(job_dir / "receipt.json", new_receipt(layout, request, seq))
    spool_entry(layout, seq, request.key.digest).touch()


def spool_entry(layout: Layout, seq: int, digest: str) -> Path:
    return layout.spool / f"{seq:012d}-{digest}"


def touch_entries(layout: Layout, receipt: Mapping[str, Any]) -> None:
    index = load_index(layout)
    now = time.time()
    names = [f"jobs/{receipt['digest']}"]
    if receipt.get("targetDir"):
        names.append(f"targets/{Path(receipt['targetDir']).name}")
    for name in names:
        if name in index["entries"]:
            index["entries"][name]["used"] = now
    write_json(layout.index, index)


def emit(result: Result, mode: str, job_dir: Path, stdout, stderr) -> int:
    stdout.write(result.stdout)
    stdout.flush()
    receipt = result.receipt
    code = exit_status(receipt["exit"])
    note = " (timed out)" if receipt.get("timedOut") else ""
    print(f"runnerd: {mode} job {receipt['digest']}: exit {code}{note} after {receipt['wallSeconds']:.1f} s; "
          f"receipt {job_dir / 'receipt.json'}", file=stderr)
    for line in result.log_tail:
        print(f"  | {line}", file=stderr)
    return 1 if receipt.get("timedOut") and code == 0 else code


# ---------------------------------------------------------------------------------------
# The dispatcher


@dataclass
class Running:
    digest: str
    proc: subprocess.Popen
    pidfd: int
    deadline: float
    started: float
    target: Optional[Path]
    timed_out: bool = False


@dataclass
class Dispatcher:
    settings: Settings
    lock_fd: int
    running: Dict[str, Running] = field(default_factory=dict)

    @property
    def layout(self) -> Layout:
        return self.settings.layout

    def run(self) -> int:
        layout = self.layout
        os.set_inheritable(self.lock_fd, False)
        wake_fd = os.open(layout.wake, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
        selector = selectors.DefaultSelector()
        selector.register(wake_fd, selectors.EVENT_READ, None)
        with queue_lock(layout):
            self.recover()
        while True:
            with queue_lock(layout):
                for running in self.start_jobs():
                    selector.register(running.pidfd, selectors.EVENT_READ, running.digest)
                if not self.running:
                    layout.dispatcher_info.unlink(missing_ok=True)
                    os.close(self.lock_fd)
                    return 0
            deadlines = [r.deadline for r in self.running.values() if not r.timed_out]
            timeout = max(0.0, min(deadlines) - time.time()) if deadlines else None
            for key, _ in selector.select(timeout):
                if key.data is None:
                    drain(wake_fd)
            now = time.time()
            for running in list(self.running.values()):
                if running.proc.poll() is not None:
                    selector.unregister(running.pidfd)
                    os.close(running.pidfd)
                    del self.running[running.digest]
                    self.finish(running)
                elif now >= running.deadline and not running.timed_out:
                    running.timed_out = True
                    kill_group(running.proc.pid)

    def recover(self) -> None:
        """Under the lock, before the first job: a dead dispatcher's running jobs run again."""
        queued = {p.name.split("-", 1)[1] for p in self.layout.spool.iterdir()}
        for receipt_path in self.layout.jobs.glob("*/receipt.json"):
            receipt = read_json(receipt_path)
            if not receipt or receipt["state"] not in ("queued", "running"):
                continue
            if receipt["state"] == "running":
                pid = receipt.get("pid")
                if pid and process_start_time(pid) == receipt.get("pidStart"):
                    kill_group(pid)
                receipt["state"] = "queued"
                receipt["recovered"] = receipt.get("recovered", 0) + 1
                write_json(receipt_path, receipt)
            if receipt["digest"] not in queued:
                spool_entry(self.layout, receipt["seq"], receipt["digest"]).touch()

    def start_jobs(self) -> List[Running]:
        started = []
        entries = sorted(self.layout.spool.iterdir())
        while entries and len(self.running) < self.settings.slots:
            entry = entries.pop(0)
            digest = entry.name.split("-", 1)[1]
            entry.unlink()
            running = self.start(digest)
            if running is not None:
                self.running[digest] = running
                started.append(running)
        return started

    def start(self, digest: str) -> Optional[Running]:
        layout = self.layout
        job_dir = layout.job(digest)
        receipt = read_json(job_dir / "receipt.json")
        if receipt is None or receipt["state"] != "queued":
            return None
        request = receipt["request"]
        key = receipt["key"]
        out = job_dir / "out"
        if out.exists():
            move_to_trash(layout, out)
        out.mkdir()
        env = dict(request["env"])
        env.update({"RUNNERD_JOB": digest, "RUNNERD_OUT": str(out), "RUNNERD_ROOT": str(layout.root)})
        target = None
        if request["targetCache"]:
            target = layout.targets / f"{key['sha']}-{key['profile']}"
            target.mkdir(exist_ok=True)
            env["RUNNERD_TARGET_DIR"] = str(target)
            receipt["targetDir"] = str(target)
        now = time.time()
        with open(job_dir / "stdout", "wb") as out_file, open(job_dir / "log", "wb") as log_file:
            try:
                proc = subprocess.Popen(request["argv"], cwd=request["cwd"], env=env, stdin=subprocess.DEVNULL,
                                        stdout=out_file, stderr=log_file, start_new_session=True)
            except OSError as error:
                log_file.write(f"runnerd: cannot start {request['argv'][0]}: {error}\n".encode())
                receipt.update({"state": "failed", "exit": 127, "started": now, "finished": now,
                                "wallSeconds": 0.0, "timedOut": False})
                write_json(job_dir / "receipt.json", receipt)
                notify_waiters(job_dir)
                return None
        receipt.update({"state": "running", "started": now, "pid": proc.pid,
                        "pidStart": process_start_time(proc.pid), "dispatcher": os.getpid(),
                        "quota": self.quota()})
        write_json(job_dir / "receipt.json", receipt)
        return Running(digest, proc, os.pidfd_open(proc.pid), now + float(request["timeout"]), now, target)

    def quota(self) -> Dict[str, Any]:
        if self.settings.scope == "none":
            return {"scope": "none", "nice": NICE}
        return {"scope": "systemd", "cpuQuota": CPU_QUOTA, "memoryMax": MEMORY_MAX, "nice": NICE}

    def finish(self, running: Running) -> None:
        layout = self.layout
        job_dir = layout.job(running.digest)
        sizes = {f"jobs/{running.digest}": tree_bytes(job_dir)}
        if running.target is not None:
            sizes[f"targets/{running.target.name}"] = tree_bytes(running.target)
        with queue_lock(layout):
            receipt = read_json(job_dir / "receipt.json") or {}
            code = running.proc.returncode
            now = time.time()
            receipt.update({"state": "done" if code == 0 and not running.timed_out else "failed", "exit": code,
                            "finished": now, "wallSeconds": now - running.started, "timedOut": running.timed_out})
            write_json(job_dir / "receipt.json", receipt)
            index = load_index(layout)
            for name, size in sizes.items():
                index["entries"][name] = {"bytes": size, "used": now}
            evict(layout, index, self.settings.budget, busy_entries(layout) + list(sizes))
            write_json(layout.index, index)
            notify_waiters(job_dir)
        empty_trash(layout)


def notify_waiters(job_dir: Path) -> None:
    waiters = job_dir / "waiters"
    if not waiters.is_dir():
        return
    for fifo in waiters.iterdir():
        try:
            fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            fifo.unlink(missing_ok=True)  # ENXIO: that submit is gone
            continue
        try:
            os.write(fd, b"done\n")
        finally:
            os.close(fd)
        fifo.unlink(missing_ok=True)


def drain(fd: int) -> None:
    try:
        while os.read(fd, 4096):
            pass
    except BlockingIOError:
        pass


def kill_group(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


# ---------------------------------------------------------------------------------------
# status and gc


def status(layout: Layout) -> Dict[str, Any]:
    layout.ensure()
    with queue_lock(layout):
        index = load_index(layout)
        info = read_json(layout.dispatcher_info)
        jobs = [r for r in (read_json(p) for p in layout.jobs.glob("*/receipt.json")) if r]
    alive = bool(info) and process_start_time(int(info["pid"])) is not None
    now = time.time()
    running = [{"digest": r["digest"], "key": r["key"], "pid": r.get("pid"), "seconds": now - r["started"],
                "joins": r["joins"]} for r in jobs if r["state"] == "running"]
    queued = [{"digest": r["digest"], "key": r["key"], "seq": r["seq"], "joins": r["joins"]}
              for r in sorted(jobs, key=lambda r: r["seq"]) if r["state"] == "queued"]
    return {
        "root": str(layout.root),
        "dispatcher": info if alive else None,
        "running": running,
        "queued": queued,
        "done": sum(1 for r in jobs if r["state"] == "done"),
        "failed": sum(1 for r in jobs if r["state"] == "failed"),
        "cacheBytes": sum(int(e["bytes"]) for e in index["entries"].values()),
        "cacheEntries": len(index["entries"]),
    }


def print_status(report: Mapping[str, Any]) -> None:
    dispatcher = report["dispatcher"]
    print(f"runnerd {report['root']}: dispatcher "
          + (f"{dispatcher['pid']} ({dispatcher['scope']}, {dispatcher['slots']} slots)" if dispatcher else "none"))
    for job in report["running"]:
        key = job["key"]
        print(f"  running {job['digest']} {key['sha'][:12]} {key['suite']} {key['arm']} {key['profile']} "
              f"pid {job['pid']} {job['seconds']:.0f} s, {job['joins']} joined")
    for job in report["queued"]:
        key = job["key"]
        print(f"  queued  {job['digest']} {key['sha'][:12]} {key['suite']} {key['arm']} {key['profile']} "
              f"seq {job['seq']}, {job['joins']} joined")
    print(f"  receipts: {report['done']} done, {report['failed']} failed; cache "
          f"{report['cacheBytes'] / 10**9:.1f} GB in {report['cacheEntries']} entries")


def gc(layout: Layout, budget: int) -> List[str]:
    layout.ensure()
    with queue_lock(layout):
        index = load_index(layout)
        victims = evict(layout, index, budget, busy_entries(layout))
        write_json(layout.index, index)
    empty_trash(layout)
    return victims


# ---------------------------------------------------------------------------------------
# CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="runnerd.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(os.environ.get("ORACLE_RUNNERD_ROOT", DEFAULT_ROOT)))
    sub = parser.add_subparsers(dest="command", required=True)

    submit_p = sub.add_parser("submit", help="queue COMMAND, join an identical job or reuse its receipt")
    submit_p.add_argument("--sha", required=True)
    submit_p.add_argument("--suite", required=True, help="suite list, or `build` for a build job")
    submit_p.add_argument("--arm", default="-", help="switch arm (NAME=ARM) or - (default)")
    submit_p.add_argument("--profile", default="oracle")
    submit_p.add_argument("--target-cache", action="store_true", help="give the job a per-SHA cargo target dir")
    submit_p.add_argument("--key-path", type=Path, action="append", default=[],
                          help="file or checkout dir whose content is part of the key (repeat)")
    submit_p.add_argument("--extra", action="append", default=[], help="K=V string that is part of the key (repeat)")
    submit_p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="seconds before the job is killed")
    submit_p.add_argument("--hold", type=Path, action="append", default=[],
                          help="output of another job this job reads; not evicted while this job waits or runs")
    submit_p.add_argument("argv", nargs=argparse.REMAINDER, help="-- COMMAND ARGS")

    status_p = sub.add_parser("status", help="dispatcher, running and queued jobs, cache size")
    status_p.add_argument("--json", action="store_true")

    gc_p = sub.add_parser("gc", help="evict least recently used entries above the budget now")
    gc_p.add_argument("--budget-gb", type=float)

    dispatch_p = sub.add_parser("_dispatch", help=argparse.SUPPRESS)
    dispatch_p.add_argument("--slots", type=int, required=True)
    dispatch_p.add_argument("--budget", type=int, required=True)
    dispatch_p.add_argument("--scope", choices=SCOPES, required=True)
    dispatch_p.add_argument("--lock-fd", type=int, required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == "_dispatch":
            settings = Settings(Layout(root), args.scope, args.slots, args.budget)
            return Dispatcher(settings, args.lock_fd).run()
        settings = settings_from_env(root, os.environ)
        if args.command == "submit":
            command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            if not command:
                raise RunnerError("submit needs -- COMMAND")
            extra = tuple(args.extra) + tuple(f"path:{path_digest(p)}" for p in args.key_path)
            request = Request(Key(args.sha, args.suite, args.arm, args.profile, extra), tuple(command),
                              os.getcwd(), job_environment(os.environ), args.target_cache, args.timeout,
                              tuple(args.hold))
            return submit(settings, request)
        if args.command == "status":
            report = status(settings.layout)
            if args.json:
                print(json.dumps(report, indent=1, sort_keys=True))
            else:
                print_status(report)
            return 0
        budget = int(args.budget_gb * 10**9) if args.budget_gb else settings.budget
        victims = gc(settings.layout, budget)
        print(f"runnerd: evicted {len(victims)} entries" + "".join(f"\n  {name}" for name in victims))
        return 0
    except RunnerError as error:
        print(f"runnerd: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
