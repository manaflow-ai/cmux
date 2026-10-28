#!/usr/bin/env python3
"""runnerd: the Linux VM's one queue for oracle builds and suite runs (p15-oracle-007).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3G and task 007. Stdlib only, Linux only
(pidfd), Python 3.9+, safe under `python3 -I`.

    runnerd.py submit --sha SHA --suite S [--arm A] [--profile P] [--target-cache [--target-tag T]]
                      [--key-path PATH]... [--extra K=V]... [--hold PATH]... [--timeout SEC] [--fresh]
                      -- COMMAND...
    runnerd.py status [--json]
    runnerd.py gc [--budget-gb N]

`submit` behaves like running COMMAND (same stdout, same exit code), but:
- One key per request: (sha, suite, arm, profile) plus the content hash of every --key-path and the
  --extra strings (what else changes the result: the build recipe, the corpus, the run arguments).
- A request whose key is queued or running joins that job; a request whose key already finished with
  exit 0 reuses its receipt and runs nothing. A failed job is not reused: the next submit reruns it.
  --fresh reruns a finished key too (a confirm or flake rerun of a nondeterministic suite run).
- Jobs run FIFO, at most --slots at once (default 2: the two arms of one diff), in a dispatcher that
  lives in one `systemd-run --scope -p CPUQuota=24000% -p MemoryMax=600G` under `nice -n 10`, so all
  queued work together stays inside one quota and agent shells keep 120 cores and the rest of memory.
- A job writes its results to RUNNERD_OUT (ROOT/jobs/<digest>/out/<seq>, one dir per attempt; a
  rerun keeps the previous attempt's, which its waiters may still be reading) and its scratch files
  (a worktree) to RUNNERD_SCRATCH, which the dispatcher removes when the job ends however it ends.
  --target-cache also gives it RUNNERD_TARGET_DIR=ROOT/targets/<sha>-<profile>[-<tag>], a per-SHA
  cargo target dir that is only a cache; --target-tag names what else selects the artifact (cargo
  features). Two jobs never use one target dir at once. Target dirs and job dirs share one 150 GB
  budget, evicted least recently used first; --hold PATH keeps another job's output (a built
  binary) while this job waits or runs.
- Under the systemd scope (Delegate=yes) each job runs in its own child cgroup, so a timeout, a
  recovery or the end of the job kills every process it started, setsid ones too (cgroup.kill).
  Sizing the cache and deleting evicted dirs happen on an upkeep thread, never on the dispatcher's
  loop or in a submit.

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
                         out/<seq>/ (RUNNERD_OUT), scratch/ (RUNNERD_SCRATCH while the job runs),
                         waiters/<fifo> (one per waiting submit)
    targets/<sha>-<profile>[-<tag>]/  cargo target dirs (RUNNERD_TARGET_DIR)
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
import queue
import re
import select
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple

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
# After cgroup.kill, how long the upkeep thread waits for the job cgroup to empty before leaving it.
CGROUP_DRAIN_SECONDS = 10.0
CGROUP_FS = Path("/sys/fs/cgroup")
SCOPES = ("systemd", "none")
# Jobs get this environment and nothing else from the submit that created them. CMUX_GHOSTTY_SRC is
# left out on purpose: each SHA builds the ghostty-next of its own worktree, and so is
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
    target_tag: str = ""
    fresh: bool = False

    def validate(self) -> None:
        self.key.validate()
        if self.target_tag and not (self.target_cache and NAME_RE.match(self.target_tag)):
            raise RunnerError(f"--target-tag {self.target_tag!r}: needs --target-cache; letters, digits and "
                              ". _ , = + : - only")

    @property
    def target(self) -> Optional[str]:
        """Name of the cargo target dir under ROOT/targets, or None without --target-cache."""
        if not self.target_cache:
            return None
        name = f"{self.key.sha}-{self.key.profile}"
        return f"{name}-{self.target_tag}" if self.target_tag else name

    def as_json(self, layout: Layout) -> Dict[str, Any]:
        return {"argv": list(self.argv), "cwd": self.cwd, "env": self.env, "target": self.target,
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
        # Delegate=yes lets the dispatcher give each job its own child cgroup (cgroup.kill on a timeout).
        return ["systemd-run", *user, "--scope", "--quiet", "--collect", f"--unit={unit}",
                "-p", f"CPUQuota={CPU_QUOTA}", "-p", f"MemoryMax={MEMORY_MAX}", "-p", "Delegate=yes",
                "--", *inner]


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
            if receipt["request"].get("target"):
                names.append(f"targets/{receipt['request']['target']}")
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
    request.validate()
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
            finished = state in ("done", "failed")
            # A failed job is reused only by the submits that waited on it; a new submit reruns it, and
            # so does a --fresh one of a done job.
            if finished and not (first and (state == "failed" or request.fresh)):
                if first:
                    receipt["reuses"] += 1
                    receipt["submits"] += 1
                    write_json(job_dir / "receipt.json", receipt)
                    touch_entries(layout, receipt)
                result = read_result(layout, digest)
            else:
                if state is None or finished:
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
    """Under the lock: the job's receipt for a new attempt and its spool entry."""
    for path in request.holds:
        hold_entry(layout, path)
        if not path.exists():
            raise RunnerError(f"--hold {path}: evicted since its job finished; submit that job again")
    job_dir = layout.job(request.key.digest)
    if job_dir.exists():
        retire_attempts(layout, job_dir)
    index = load_index(layout)
    index["seq"] += 1
    seq = index["seq"]
    write_json(layout.index, index)
    job_dir.mkdir(exist_ok=True)
    write_json(job_dir / "receipt.json", new_receipt(layout, request, seq))
    spool_entry(layout, seq, request.key.digest).touch()


def attempt_dirs(job_dir: Path) -> List[Path]:
    return sorted((p for p in (job_dir / "out").glob("*") if p.name.isdigit()), key=lambda p: int(p.name))


def retire_attempts(layout: Layout, job_dir: Path) -> None:
    """Under the lock, before a rerun: the last attempt's output stays, because the submits that just got
    it may still be reading it (a run dir) and a queued job may hold it (a binary); older ones go."""
    move_to_trash(layout, job_dir / "scratch")
    if f"jobs/{job_dir.name}" in busy_entries(layout):
        return
    for old in attempt_dirs(job_dir)[:-1]:
        move_to_trash(layout, old)


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
    seq: int
    proc: subprocess.Popen
    pidfd: int
    deadline: float
    started: float
    target: Optional[str]
    cgroup: Optional[Path]
    timed_out: bool = False


@dataclass(frozen=True)
class Chore:
    """Slow file work for the upkeep thread: empty and remove a job cgroup, size index entries (names
    under ROOT) and mark them used, evict above the budget, delete the trash."""
    sizes: Tuple[str, ...] = ()
    cgroup: Optional[Path] = None


class Upkeep:
    """One thread does every chore in order, so the dispatcher's loop never walks a target dir or
    deletes one: it keeps starting, reaping and timing out jobs meanwhile. Each chore ends with one byte
    on `done_fd`; only the loop's thread reads it and counts `pending`, so no state is shared."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.chores: "queue.Queue[Chore]" = queue.Queue()
        self.done_fd, self._done_write = os.pipe()
        os.set_blocking(self.done_fd, False)
        self.pending = 0
        threading.Thread(target=self._work, name="runnerd-upkeep", daemon=True).start()

    def add(self, chore: Chore) -> None:
        self.pending += 1
        self.chores.put(chore)

    def collect(self) -> None:
        try:
            while True:
                done = os.read(self.done_fd, 4096)
                if not done:
                    return
                self.pending -= len(done)
        except BlockingIOError:
            return

    def _work(self) -> None:
        while True:
            chore = self.chores.get()
            try:
                self._do(chore)
            except OSError as error:  # a chore that fails leaves its sizes stale; the queue goes on
                print(f"runnerd: upkeep {chore}: {error}", file=sys.stderr, flush=True)
            finally:
                os.write(self._done_write, b".")

    def _do(self, chore: Chore) -> None:
        layout = self.settings.layout
        if chore.cgroup is not None:
            remove_cgroup(chore.cgroup)
        sizes = {name: tree_bytes(layout.root / name) for name in chore.sizes if (layout.root / name).exists()}
        if sizes:
            with queue_lock(layout):
                index = load_index(layout)
                now = time.time()
                for name, size in sizes.items():
                    index["entries"][name] = {"bytes": size, "used": now}
                evict(layout, index, self.settings.budget, busy_entries(layout) + list(sizes))
                write_json(layout.index, index)
        empty_trash(layout)


@dataclass
class Dispatcher:
    settings: Settings
    lock_fd: int
    running: Dict[str, Running] = field(default_factory=dict)
    cgroup_base: Optional[Path] = None
    upkeep: Optional[Upkeep] = None

    @property
    def layout(self) -> Layout:
        return self.settings.layout

    def run(self) -> int:
        layout = self.layout
        os.set_inheritable(self.lock_fd, False)
        if self.settings.scope == "systemd":
            self.cgroup_base = own_cgroup()
        upkeep = self.upkeep = Upkeep(self.settings)
        wake_fd = os.open(layout.wake, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
        selector = selectors.DefaultSelector()
        selector.register(wake_fd, selectors.EVENT_READ, "wake")
        selector.register(upkeep.done_fd, selectors.EVENT_READ, "upkeep")
        with queue_lock(layout):
            self.recover()
        upkeep.add(Chore())  # the trash an earlier dispatcher left
        while True:
            with queue_lock(layout):
                for running in self.start_jobs():
                    selector.register(running.pidfd, selectors.EVENT_READ, running.digest)
                if not self.running and not upkeep.pending:
                    layout.dispatcher_info.unlink(missing_ok=True)
                    os.close(self.lock_fd)
                    return 0
            deadlines = [r.deadline for r in self.running.values() if not r.timed_out]
            timeout = max(0.0, min(deadlines) - time.time()) if deadlines else None
            for key, _ in selector.select(timeout):
                if key.data == "wake":
                    drain(wake_fd)
                elif key.data == "upkeep":
                    upkeep.collect()
            now = time.time()
            for running in list(self.running.values()):
                if running.proc.poll() is not None:
                    selector.unregister(running.pidfd)
                    os.close(running.pidfd)
                    del self.running[running.digest]
                    self.finish(running)
                elif now >= running.deadline and not running.timed_out:
                    running.timed_out = True
                    kill_job(running.proc.pid, running.cgroup)

    def recover(self) -> None:
        """Under the lock, before the first job: a dead dispatcher's running jobs run again, after
        everything they started is killed."""
        queued = {p.name.split("-", 1)[1] for p in self.layout.spool.iterdir()}
        for receipt_path in self.layout.jobs.glob("*/receipt.json"):
            receipt = read_json(receipt_path)
            if not receipt or receipt["state"] not in ("queued", "running"):
                continue
            if receipt["state"] == "running":
                pid = receipt.get("pid")
                alive = bool(pid) and process_start_time(pid) == receipt.get("pidStart")
                cgroup = Path(receipt["cgroup"]) if receipt.get("cgroup") else None
                kill_job(pid if alive else None, cgroup)
                if cgroup is not None:
                    self.upkeep.add(Chore(cgroup=cgroup))
                receipt["state"] = "queued"
                receipt["recovered"] = receipt.get("recovered", 0) + 1
                write_json(receipt_path, receipt)
            if receipt["digest"] not in queued:
                spool_entry(self.layout, receipt["seq"], receipt["digest"]).touch()

    def start_jobs(self) -> List[Running]:
        """FIFO, except that a job whose target dir another running job builds in waits for it: two cargo
        builds in one dir serialize on its lock, so the second's times would be the first's, and the
        uplifted binary would be whichever finished last."""
        started = []
        busy_targets = {r.target for r in self.running.values() if r.target is not None}
        for entry in sorted(self.layout.spool.iterdir()):
            if len(self.running) >= self.settings.slots:
                break
            digest = entry.name.split("-", 1)[1]
            receipt = read_json(self.layout.job(digest) / "receipt.json")
            if receipt is None or receipt["state"] != "queued":
                entry.unlink()
                continue
            target = receipt["request"].get("target")
            if target is not None and target in busy_targets:
                continue
            entry.unlink()
            running = self.start(digest, receipt)
            if running is not None:
                self.running[digest] = running
                started.append(running)
                if running.target is not None:
                    busy_targets.add(running.target)
        return started

    def start(self, digest: str, receipt: Dict[str, Any]) -> Optional[Running]:
        layout = self.layout
        job_dir = layout.job(digest)
        request = receipt["request"]
        seq = int(receipt["seq"])
        out = job_dir / "out" / str(seq)
        scratch = job_dir / "scratch"
        for directory in (out, scratch):
            if directory.exists():
                move_to_trash(layout, directory)
            directory.mkdir(parents=True)
        env = dict(request["env"])
        env.update({"RUNNERD_JOB": digest, "RUNNERD_OUT": str(out), "RUNNERD_SCRATCH": str(scratch),
                    "RUNNERD_ROOT": str(layout.root)})
        target = request.get("target")
        if target is not None:
            (layout.targets / target).mkdir(exist_ok=True)
            env["RUNNERD_TARGET_DIR"] = str(layout.targets / target)
            receipt["targetDir"] = str(layout.targets / target)
        argv = list(request["argv"])
        cgroup = None
        if self.cgroup_base is not None:
            cgroup = self.cgroup_base / f"job-{digest}-{seq}"
            cgroup.mkdir(exist_ok=True)
            # The job moves itself into its cgroup before it execs the command, so nothing it starts
            # is ever outside it.
            argv = ["sh", "-c", 'echo $$ > "$0/cgroup.procs" && exec "$@"', str(cgroup), *argv]
        now = time.time()
        with open(job_dir / "stdout", "wb") as out_file, open(job_dir / "log", "wb") as log_file:
            try:
                proc = subprocess.Popen(argv, cwd=request["cwd"], env=env, stdin=subprocess.DEVNULL,
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
                        "cgroup": str(cgroup) if cgroup else None, "quota": self.quota()})
        write_json(job_dir / "receipt.json", receipt)
        return Running(digest, seq, proc, os.pidfd_open(proc.pid), now + float(request["timeout"]), now, target,
                       cgroup)

    def quota(self) -> Dict[str, Any]:
        if self.settings.scope == "none":
            return {"scope": "none", "nice": NICE}
        return {"scope": "systemd", "cpuQuota": CPU_QUOTA, "memoryMax": MEMORY_MAX, "nice": NICE}

    def finish(self, running: Running) -> None:
        """Short: the receipt, the waiters and the scratch dir. Killing what the job left behind,
        sizing and eviction are the upkeep thread's."""
        layout = self.layout
        job_dir = layout.job(running.digest)
        if running.cgroup is not None:
            kill_job(None, running.cgroup)
        with queue_lock(layout):
            receipt = read_json(job_dir / "receipt.json") or {}
            code = running.proc.returncode
            now = time.time()
            receipt.update({"state": "done" if code == 0 and not running.timed_out else "failed", "exit": code,
                            "finished": now, "wallSeconds": now - running.started, "timedOut": running.timed_out})
            write_json(job_dir / "receipt.json", receipt)
            move_to_trash(layout, job_dir / "scratch")
            notify_waiters(job_dir)
        sizes = (f"jobs/{running.digest}",) + ((f"targets/{running.target}",) if running.target else ())
        self.upkeep.add(Chore(sizes=sizes, cgroup=running.cgroup))


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


def own_cgroup() -> Path:
    """The dispatcher's cgroup v2 dir: its systemd scope, delegated to it (Delegate=yes)."""
    for line in Path("/proc/self/cgroup").read_text(encoding="ascii").splitlines():
        if line.startswith("0::"):
            path = CGROUP_FS / line[3:].lstrip("/")
            if os.access(path, os.W_OK):
                return path
            raise RunnerError(f"{path}: not writable; the scope needs Delegate=yes")
    raise RunnerError("no cgroup v2 hierarchy in /proc/self/cgroup")


def kill_job(pid: Optional[int], cgroup: Optional[Path]) -> None:
    """SIGKILL to the job's process group (pid must be its live leader) and, under the systemd scope,
    to every process in its cgroup, setsid ones too."""
    if pid:
        kill_group(pid)
    if cgroup is not None:
        try:
            (cgroup / "cgroup.kill").write_text("1", encoding="ascii")
        except FileNotFoundError:
            pass


def remove_cgroup(cgroup: Path) -> None:
    """Upkeep: waits on cgroup.events (a POLLPRI notification, not a timer loop) until the killed job
    cgroup is empty, then removes it; one still busy after CGROUP_DRAIN_SECONDS goes with its scope."""
    kill_job(None, cgroup)
    deadline = time.monotonic() + CGROUP_DRAIN_SECONDS
    try:
        events = os.open(cgroup / "cgroup.events", os.O_RDONLY | os.O_CLOEXEC)
    except FileNotFoundError:
        return
    try:
        poller = select.poll()
        poller.register(events, select.POLLPRI | select.POLLERR)
        while b"populated 0" not in os.pread(events, 4096, 0):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            poller.poll(remaining * 1000)
    finally:
        os.close(events)
    try:
        cgroup.rmdir()
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.EBUSY):
            raise


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
    submit_p.add_argument("--target-tag", default="",
                          help="what else selects the cargo artifact (features): part of the target dir name")
    submit_p.add_argument("--fresh", action="store_true", help="rerun the key even when a finished receipt exists")
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
    if not sys.platform.startswith("linux") or not hasattr(os, "pidfd_open"):
        print("runnerd: the oracle queue runs on the Linux VM only (it needs pidfd_open, Linux 5.3+ and "
              "Python 3.9+); nothing was queued", file=sys.stderr)
        return 2
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
                              tuple(args.hold), args.target_tag, args.fresh)
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
