#!/usr/bin/env python3
"""The perf lab's build ledger: one record per (sha, config), ok or failed.

Chrome's perf waterfall measures only what a builder produced (docs/speed/perf_waterfall.md: a
tester takes the newest built commit), and Pinpoint's build quest (catapult
`dashboard/dashboard/pinpoint/models/quest/find_isolate.py`) reuses the isolate it already has for
a (change, target) instead of building it again. This ledger is that rule for cmux bench builds:

- `has_build(sha, config)`: an ok record with a 64-hex artifact digest exists, so a lab host can
  download the app by that digest.
- `should_build(sha, config)`: no record at all. A failed build is recorded once and never retried;
  a bisect skips that commit (p12-perf-process.md 3.6).
- Only a failure the commit causes is recorded (`build_outcome`): xcodebuild's BUILD FAILED with a
  compiler or linker error at a source, a reload.sh with no such --config arm, or a bench app whose
  Swift defines are not the config's. A full disk, the network, signing, a signal or an interrupted
  build records nothing, so the next attempt builds again.
- A failed record is final. A later ok build of an ok key replaces it: the builder rebuilds a commit
  whose zip it evicted, the zip is not byte-reproducible, and the newest digest is the one whose
  artifact still exists. `forget --reason` is the operator's undo of a record written by mistake; it
  keeps what it dropped in forgotten.jsonl.

Configs are only `bench` and `bench-checks` (task 147): a Debug result is never a bench point.
`scripts/measure/perf-lab-build.sh` keeps a ledger in the builder's cache next to the zips (named
by digest); that one is the builder's cache only. labd keeps the lab's ledger, built from every
builder's step receipts with the same `record()`, and the build queue (task 234) asks that one, so a
commit that failed on one builder is not handed to another.

    python3 -I scripts/perf-lab/builds.py status --ledger DIR --sha SHA --config bench
    python3 -I scripts/perf-lab/builds.py record --ledger DIR --sha SHA --config bench --status ok \\
        --digest HEX --seconds 812 --app "cmux DEV perf-lab.app" [--define CMUX_BENCH_HOOKS] [--job ID]
    python3 -I scripts/perf-lab/builds.py receipt --ledger DIR --sha SHA --config bench [--cached]
    python3 -I scripts/perf-lab/builds.py forget --ledger DIR --sha SHA --config bench --reason TEXT
    python3 -I scripts/perf-lab/builds.py digest FILE
    python3 -I scripts/perf-lab/builds.py supports --reload scripts/reload.sh --config bench-checks
    python3 -I scripts/perf-lab/builds.py outcome --config bench --rc 65 --log reload.log [--log build.log]
    python3 -I scripts/perf-lab/builds.py run-locked [--grace SECONDS] LOCKFILE -- CMD ARGS...  # 75 when busy

Stdlib only; runs under `python3 -I` on a builder.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "cmux-perf-lab-build/v1"
CONFIGS = ("bench", "bench-checks")
STATUSES = ("ok", "failed")
SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
DEFINE = re.compile(r"^[A-Z][A-Z0-9_]*$")
# reload.sh prints the Swift defines of a bench build on this line (reload.sh, `BENCH_HOOKS`), into its own
# log ($RELOAD_LOG, the file of its `==> log: PATH` line), since the commit that added its `bench)` arm.
BENCH_CONFIGURATION_LINE = re.compile(r"^==> bench configuration:.*$", re.M)
BENCH_HOOKS = "CMUX_BENCH_HOOKS"
BLOCKING_CHECKS = "CMUX_BLOCKING_CHECKS"
# reload.sh exits 65 for BUILD INTERRUPTED and xcodebuild exits 65 for BUILD FAILED, so the verdict is in the log.
BUILD_INTERRUPTED = re.compile(r"\bBUILD INTERRUPTED\b")
BUILD_FAILED = re.compile(r"\*\* BUILD FAILED \*\*")
# A compiler diagnostic at a source location, or the linker: what makes a failure the commit's.
SOURCE_ERROR = re.compile(
    r"^.*?\.(?:swift|m|mm|c|cc|cpp|h|hpp|metal):\d+(?::\d+)?: (?:fatal )?error: .*$"
    r"|^ld: (?!warning).*$|^.*error: linker command failed.*$|^Undefined symbols? for .*$", re.M)
# From a forwarded signal to SIGKILL of what is left of the build's process group.
GROUP_GRACE_SECONDS = 20.0


class BuildError(ValueError):
    pass


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def check_config(config: str) -> str:
    if config not in CONFIGS:
        raise BuildError(f"config {config!r} is not a bench config; use one of {', '.join(CONFIGS)}")
    return config


def check_sha(sha: str) -> str:
    if not SHA.fullmatch(sha):
        raise BuildError(f"sha {sha!r} must be a full 40-hex commit id")
    return sha


def build_key(sha: str, config: str) -> str:
    """The cache key: the commit and the config, so bench and bench-checks of one commit never collide."""
    return f"{check_sha(sha)}-{check_config(config)}"


@dataclass(frozen=True)
class BuildRecord:
    sha: str
    config: str
    status: str
    seconds: int
    digest: str | None = None
    reason: str | None = None
    defines: tuple[str, ...] = ()
    app: str | None = None
    job: str | None = None
    recorded_at: str = ""
    schema: str = field(default=SCHEMA)

    def __post_init__(self) -> None:
        check_sha(self.sha)
        check_config(self.config)
        if self.status not in STATUSES:
            raise BuildError(f"status {self.status!r} is not one of {STATUSES}")
        if self.status == "ok" and not (self.digest and DIGEST.fullmatch(self.digest)):
            raise BuildError(f"{self.sha} ({self.config}): an ok build needs a 64-hex digest, got {self.digest!r}")
        if self.status == "failed" and self.digest is not None:
            raise BuildError(f"{self.sha} ({self.config}): a failed build has no artifact digest")
        if self.status == "failed" and not self.reason:
            raise BuildError(f"{self.sha} ({self.config}): a failed build needs a reason")
        if self.status == "ok" and not (self.app and self.app.endswith(".app") and "/" not in self.app):
            raise BuildError(f"{self.sha} ({self.config}): an ok build needs the app bundle name, got {self.app!r}")
        if self.seconds < 0:
            raise BuildError(f"{self.sha} ({self.config}): seconds must be >= 0")
        bad = [name for name in self.defines if not DEFINE.fullmatch(name)]
        if bad:
            raise BuildError(f"{self.sha} ({self.config}): not Swift define names: {bad}")

    def to_json(self) -> dict[str, object]:
        return {**asdict(self), "defines": list(self.defines)}

    @classmethod
    def from_json(cls, data: dict[str, object]) -> BuildRecord:
        if data.get("schema") != SCHEMA:
            raise BuildError(f"record schema {data.get('schema')!r} is not {SCHEMA}")
        try:
            return cls(sha=str(data["sha"]), config=str(data["config"]), status=str(data["status"]),
                       seconds=int(data["seconds"]), digest=data.get("digest"), reason=data.get("reason"),
                       defines=tuple(data.get("defines") or ()), app=data.get("app"), job=data.get("job"),
                       recorded_at=str(data.get("recorded_at") or ""))
        except (KeyError, TypeError, ValueError) as error:
            raise BuildError(f"malformed build record: {error}") from error


class BuildLedger:
    """Records under ROOT/records/<sha>-<config>.json, decided by status.

    A failed record is final: a replayed failed report returns it, an ok one is refused. An ok record is
    replaced by an ok build with another digest (a rebuild after its zip was evicted, or another builder's
    build of the key), and a replay with the same digest returns it. A failed report of an ok key is refused:
    the commit built, so a later failure is the builder's."""

    def __init__(self, root: Path | str, *, clock: Callable[[], datetime] = utc_now) -> None:
        self._root = Path(root)
        self._records = self._root / "records"
        self._clock = clock

    def _path(self, sha: str, config: str) -> Path:
        return self._records / f"{build_key(sha, config)}.json"

    def _stamp(self) -> str:
        return self._clock().astimezone(timezone.utc).isoformat(timespec="seconds")

    def get(self, sha: str, config: str) -> BuildRecord | None:
        path = self._path(sha, config)
        try:
            text = path.read_text()
        except FileNotFoundError:
            return None
        try:
            return BuildRecord.from_json(json.loads(text))
        except json.JSONDecodeError as error:
            raise BuildError(f"{path}: not JSON ({error})") from error

    def has_build(self, sha: str, config: str) -> bool:
        record = self.get(sha, config)
        return record is not None and record.status == "ok"

    def should_build(self, sha: str, config: str) -> bool:
        return self.get(sha, config) is None

    def record(self, record: BuildRecord) -> BuildRecord:
        if not record.recorded_at:
            record = BuildRecord(**{**asdict(record), "recorded_at": self._stamp()})
        path = self._path(record.sha, record.config)
        self._records.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(dir=self._records, prefix=".record-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(record.to_json(), handle, sort_keys=True, indent=1)
                handle.write("\n")
            try:
                os.link(temp, path)  # fails when the key has a record: no failed record is ever overwritten
            except FileExistsError:
                stored = self.get(record.sha, record.config)
                if stored is None or stored.status != record.status:
                    raise BuildError(f"{record.sha} ({record.config}) is already recorded as "
                                     f"{stored.status if stored else 'unreadable'}; a failed build is never "
                                     "retried and a built commit never becomes failed")
                if stored.status == "failed" or stored.digest == record.digest:
                    return stored
                os.replace(temp, path)  # a rebuilt artifact: the newest digest is the one that still exists
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        return record

    def forget(self, sha: str, config: str, *, reason: str) -> BuildRecord | None:
        """The operator's undo of a record written by mistake (a failure that was the builder's, not the commit's).

        Drops the record so the key builds again and appends it, with the reason, to ROOT/forgotten.jsonl."""
        if not reason.strip():
            raise BuildError("forget needs a --reason")
        record = self.get(sha, config)
        if record is None:
            return None
        with open(self._root / "forgotten.jsonl", "a") as log:
            log.write(json.dumps({"forgotten_at": self._stamp(), "reason": reason, "record": record.to_json()},
                                 sort_keys=True) + "\n")
        self._path(sha, config).unlink()
        return record


def file_digest(path: Path | str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def reload_supports(reload_text: str, config: str) -> bool:
    """Whether a commit's reload.sh takes `--config CONFIG` (its option case has the arm `CONFIG)`).

    `bench` arrived before this script and `bench-checks` with task 147, so an older commit refuses
    bench-checks, and the ledger records that once instead of a reload.sh usage error per attempt.
    """
    check_config(config)
    return re.search(rf"^\s*{re.escape(config)}\)\s", reload_text, re.M) is not None


def bench_defines(log_text: str) -> tuple[str, ...]:
    """The -D names reload.sh says it compiled the bench app with (empty when it printed no such line)."""
    lines = BENCH_CONFIGURATION_LINE.findall(log_text)
    if not lines:
        return ()
    return tuple(dict.fromkeys(re.findall(r"-D([A-Z][A-Z0-9_]*)", lines[-1])))


def config_defines_mismatch(config: str, defines: Sequence[str]) -> str | None:
    """Why DEFINES are not CONFIG's bench app (task 147), or None: bench is CMUX_BENCH_HOOKS without DEBUG and
    without CMUX_BLOCKING_CHECKS, bench-checks adds CMUX_BLOCKING_CHECKS. A commit before task 147 compiles
    `bench` with CMUX_BLOCKING_CHECKS, and the first bench commits compiled it with DEBUG."""
    check_config(config)
    if BENCH_HOOKS not in defines:
        return f"no -D{BENCH_HOOKS}"
    if "DEBUG" in defines:
        return "-DDEBUG"
    if (BLOCKING_CHECKS in defines) != (config == "bench-checks"):
        return f"-D{BLOCKING_CHECKS} {'present' if BLOCKING_CHECKS in defines else 'missing'}"
    return None


@dataclass(frozen=True)
class BuildOutcome:
    """How a reload.sh run ended: `ok`, `commit` (the commit's fault: record failed) or `infra` (record nothing)."""

    kind: str
    reason: str = ""
    defines: tuple[str, ...] = ()


def build_outcome(config: str, rc: int, log_text: str) -> BuildOutcome:
    """Sorts a reload.sh run of CONFIG by its exit code and its logs (the step's capture and reload.sh's own).

    The code alone sorts nothing: 65 is xcodebuild's BUILD FAILED and reload.sh's BUILD INTERRUPTED, and 1 is
    a compile error as well as a full disk, the network or signing. A run is the commit's only when xcodebuild
    says BUILD FAILED with a compiler or linker error at a source, or when it built an app whose defines are
    not CONFIG's. Everything else that is not a success is the builder's.
    """
    check_config(config)
    if rc == 124 or rc >= 128:
        return BuildOutcome("infra", f"reload.sh ended with {rc} (timed out or killed by a signal)")
    if BUILD_INTERRUPTED.search(log_text):
        return BuildOutcome("infra", f"reload.sh ended with {rc}: xcodebuild reported BUILD INTERRUPTED")
    if rc != 0:
        errors = list(dict.fromkeys(match.strip() for match in SOURCE_ERROR.findall(log_text)))
        if BUILD_FAILED.search(log_text) and errors:
            return BuildOutcome("commit", f"reload.sh exit {rc}: {' '.join(errors[:5])}"[:600])
        said = [line.strip() for line in log_text.splitlines() if re.search(r"\berror\b", line, re.I)]
        return BuildOutcome("infra", f"reload.sh ended with {rc} without a compile or link error"
                                     f"{': ' + said[-1][:300] if said else ''}")
    defines = bench_defines(log_text)
    if not defines:
        return BuildOutcome("infra", "reload.sh succeeded, but no log it named has its `==> bench configuration` line")
    mismatch = config_defines_mismatch(config, defines)
    if mismatch:
        return BuildOutcome("commit", f"reload.sh --config {config} at this commit compiles "
                                      f"{' '.join('-D' + name for name in defines)} ({mismatch}): not the "
                                      f"{config} config", defines)
    return BuildOutcome("ok", "", defines)


def _group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _signal_group(pgid: int, signum: int) -> None:
    try:
        os.killpg(pgid, signum)
    except (ProcessLookupError, PermissionError):
        pass


def _wait_for_group(pgid: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while _group_alive(pgid):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)
    return True


def _started(pid: int) -> str:
    """The start time ps prints for PID ('' when there is no such process): with the pid, a process identity."""
    done = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, check=False)
    return " ".join(done.stdout.split())


def _left_group(note: str) -> int | None:
    """The process group a killed runner left running, from its lock note `PGID START`, or None.

    The group is the build's only if its leader has exited (a live group's id is never given to a new
    process) or still has the start time in the note; otherwise the id now names someone else's group."""
    pgid, _, start = note.partition(" ")
    if not pgid.isdigit() or not _group_alive(int(pgid)):
        return None
    now = _started(int(pgid))
    return int(pgid) if now in ("", start) else None


def _stop_group(pgid: int, grace_seconds: float) -> None:
    _signal_group(pgid, signal.SIGTERM)
    if not _wait_for_group(pgid, grace_seconds):
        _signal_group(pgid, signal.SIGKILL)
        _wait_for_group(pgid, 5.0)


def run_locked(lock_path: str, command: Sequence[str], *, grace_seconds: float = GROUP_GRACE_SECONDS) -> int:
    """Runs COMMAND as a child while this process holds an exclusive flock on LOCK_PATH; returns its exit code.

    Only this process holds the lock (the child gets no copy of the descriptor), so a build service xcodebuild
    leaves running never keeps it. A second build on the same builder cache exits 75 (EX_TEMPFAIL: run the
    step again later) instead of sharing the source checkout.

    The child leads a process group of its own, and TERM, INT and HUP go to the whole group, so reload.sh and
    xcodebuild stop with it: bash defers its own trap until its foreground command ends. After a signal the
    lock stays held until the group is gone, and what is left after GRACE_SECONDS is killed. The group id is
    kept in the lock file while the build runs, so if this process itself is killed, the next run stops that
    group before it builds in the same tree.
    """
    if not command:
        raise BuildError("run-locked needs a command after --")
    Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"builds.py: another bench build holds {lock_path}; run this step again later", file=sys.stderr)
            return 75
        lock.seek(0)
        left = _left_group(lock.read().strip())
        if left is not None:
            print(f"builds.py: stopping process group {left}, left by a build whose runner was killed",
                  file=sys.stderr)
            _stop_group(left, grace_seconds)
        received: list[int] = []
        group: list[int] = []

        def forward(signum: int, _frame: object) -> None:
            received.append(signum)
            if group:
                _signal_group(group[0], signum)

        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, forward)
        child = subprocess.Popen(list(command), close_fds=True, start_new_session=True)
        group.append(child.pid)  # a session leader's pid is its process group id
        lock.truncate(0)
        lock.write(f"{child.pid} {_started(child.pid)}\n")
        lock.flush()
        for signum in list(received):  # a signal that came before the group existed
            _signal_group(child.pid, signum)
        code = child.wait()
        if received and not _wait_for_group(child.pid, grace_seconds):
            print(f"builds.py: killing what is left of the cancelled build (process group {child.pid})",
                  file=sys.stderr)
            _signal_group(child.pid, signal.SIGKILL)
            _wait_for_group(child.pid, 5.0)
        lock.truncate(0)
        return code


def _main(argv: Sequence[str]) -> int:
    if argv[:1] == ["run-locked"]:
        rest = list(argv[1:])
        grace = GROUP_GRACE_SECONDS
        if rest[:1] == ["--grace"] and len(rest) > 1:
            try:
                grace = float(rest[1])
            except ValueError:
                grace = -1.0
            rest = rest[2:]
        if len(rest) < 2 or rest[1] != "--" or grace < 0:
            print("usage: builds.py run-locked [--grace SECONDS] LOCKFILE -- CMD ARGS...", file=sys.stderr)
            return 2
        try:
            code = run_locked(rest[0], rest[2:], grace_seconds=grace)
            return code if code >= 0 else 128 - code  # a child killed by signal N exits 128 + N, as in a shell
        except (BuildError, OSError) as error:
            print(f"builds.py: {error}", file=sys.stderr)
            return 2
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="op", required=True)
    for name in ("status", "record", "receipt", "forget"):
        p = sub.add_parser(name)
        p.add_argument("--ledger", required=True)
        p.add_argument("--sha", required=True)
        p.add_argument("--config", required=True)
        if name == "record":
            p.add_argument("--status", required=True, choices=STATUSES)
            p.add_argument("--seconds", type=int, required=True)
            p.add_argument("--digest")
            p.add_argument("--reason")
            p.add_argument("--define", action="append", default=[])
            p.add_argument("--app")
            p.add_argument("--job")
        if name == "receipt":
            p.add_argument("--cached", action="store_true")
        if name == "forget":
            p.add_argument("--reason", required=True)
    p = sub.add_parser("digest")
    p.add_argument("file")
    p = sub.add_parser("supports")
    p.add_argument("--reload", required=True)
    p.add_argument("--config", required=True)
    p = sub.add_parser("outcome", help="prints three lines: ok|commit|infra, the reason, the defines")
    p.add_argument("--config", required=True)
    p.add_argument("--rc", type=int, required=True)
    p.add_argument("--log", action="append", default=[], help="a log to read; a missing file is skipped")
    args = parser.parse_args(argv)
    try:
        if args.op == "digest":
            print(file_digest(args.file))
            return 0
        if args.op == "supports":
            return 0 if reload_supports(Path(args.reload).read_text(errors="replace"), args.config) else 1
        if args.op == "outcome":
            texts = [Path(log).read_text(errors="replace") for log in args.log if Path(log).is_file()]
            outcome = build_outcome(args.config, args.rc, "\n".join(texts))
            print(outcome.kind)
            print(" ".join(outcome.reason.split()))
            print(" ".join(outcome.defines))
            return 0
        ledger = BuildLedger(args.ledger)
        if args.op == "status":
            record = ledger.get(args.sha, args.config)
            print(record.status if record else "missing")
            return 0
        if args.op == "forget":
            dropped = ledger.forget(args.sha, args.config, reason=args.reason)
            print(f"forgot the {dropped.status} record" if dropped else "no record")
            return 0
        if args.op == "receipt":
            record = ledger.get(args.sha, args.config)
            if record is None:
                raise BuildError(f"{args.sha} ({args.config}) has no build record")
            print(json.dumps(receipt(record, cached=args.cached), sort_keys=True))
            return 0
        stored = ledger.record(BuildRecord(sha=args.sha, config=args.config, status=args.status,
                                           seconds=args.seconds, digest=args.digest, reason=args.reason,
                                           defines=tuple(args.define), app=args.app, job=args.job or None))
        print(json.dumps(stored.to_json(), sort_keys=True))
        return 0
    except (BuildError, OSError) as error:
        print(f"builds.py: {error}", file=sys.stderr)
        return 2


def receipt(record: BuildRecord, *, cached: bool) -> dict[str, object]:
    """What the step prints: {sha, config, digest, seconds} plus the status and how it was produced."""
    return {"sha": record.sha, "config": record.config, "digest": record.digest, "seconds": record.seconds,
            "status": record.status, "reason": record.reason, "defines": list(record.defines), "app": record.app,
            "cached": cached, "schema": SCHEMA}


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
