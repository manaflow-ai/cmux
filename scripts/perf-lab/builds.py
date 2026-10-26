#!/usr/bin/env python3
"""The perf lab's build ledger: one record per (sha, config), ok or failed, written once.

Chrome's perf waterfall measures only what a builder produced (docs/speed/perf_waterfall.md: a
tester takes the newest built commit), and Pinpoint's build quest (catapult
`dashboard/dashboard/pinpoint/models/quest/find_isolate.py`) reuses the isolate it already has for
a (change, target) instead of building it again. This ledger is that rule for cmux bench builds:

- `has_build(sha, config)`: an ok record with a 64-hex artifact digest exists, so a lab host can
  download the app by that digest.
- `should_build(sha, config)`: no record at all. A failed build is recorded once and never retried;
  a bisect skips that commit (p12-perf-process.md 3.6).

Configs are only `bench` and `bench-checks` (task 147): a Debug result is never a bench point.
`scripts/measure/perf-lab-build.sh` keeps a ledger in the builder's cache next to the zips (named
by digest), and labd keeps one built from the step receipts the same script prints.

    python3 -I scripts/perf-lab/builds.py status --ledger DIR --sha SHA --config bench
    python3 -I scripts/perf-lab/builds.py record --ledger DIR --sha SHA --config bench --status ok \\
        --digest HEX --seconds 812 --app "cmux DEV perf-lab.app" [--define CMUX_BENCH_HOOKS] [--job ID]
    python3 -I scripts/perf-lab/builds.py receipt --ledger DIR --sha SHA --config bench [--cached]
    python3 -I scripts/perf-lab/builds.py forget --ledger DIR --sha SHA --config bench   # an ok record only
    python3 -I scripts/perf-lab/builds.py digest FILE
    python3 -I scripts/perf-lab/builds.py supports --reload scripts/reload.sh --config bench-checks
    python3 -I scripts/perf-lab/builds.py defines --log reload.log
    python3 -I scripts/perf-lab/builds.py run-locked LOCKFILE -- CMD ARGS...   # exit 75 when held

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
# reload.sh prints the Swift defines of a bench build on this line (reload.sh, `BENCH_HOOKS`).
BENCH_CONFIGURATION_LINE = re.compile(r"^==> bench configuration:.*$", re.M)


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

    def identity(self) -> dict[str, object]:
        """What two records of one key must agree on; the stamp and the job that reported it may differ."""
        return {k: v for k, v in asdict(self).items() if k not in ("recorded_at", "job")}

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
    """Records under ROOT/records/<sha>-<config>.json. The first record of a key wins: a replay with the same
    content returns it, a different one is refused, so a failed build stays failed."""

    def __init__(self, root: Path | str, *, clock: Callable[[], datetime] = utc_now) -> None:
        self._records = Path(root) / "records"
        self._clock = clock

    def _path(self, sha: str, config: str) -> Path:
        return self._records / f"{build_key(sha, config)}.json"

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
            stamp = self._clock().astimezone(timezone.utc).isoformat(timespec="seconds")
            record = BuildRecord(**{**asdict(record), "recorded_at": stamp})
        path = self._path(record.sha, record.config)
        self._records.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(dir=self._records, prefix=".record-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(record.to_json(), handle, sort_keys=True, indent=1)
                handle.write("\n")
            try:
                os.link(temp, path)  # fails when the key has a record: first writer wins, no overwrite
            except FileExistsError:
                stored = self.get(record.sha, record.config)
                if stored is None or stored.identity() != record.identity():
                    raise BuildError(f"{record.sha} ({record.config}) is already recorded as "
                                     f"{stored.status if stored else 'unreadable'}; a build record is written once")
                return stored
        finally:
            os.unlink(temp)
        return record

    def forget(self, sha: str, config: str) -> None:
        """Drops an ok record whose cached artifact is gone, so the builder builds it again. A failed record stays."""
        record = self.get(sha, config)
        if record is None:
            return
        if record.status != "ok":
            raise BuildError(f"{sha} ({config}) failed to build; a failed build is never retried")
        self._path(sha, config).unlink()


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


def receipt(record: BuildRecord, *, cached: bool) -> dict[str, object]:
    """What the step prints: {sha, config, digest, seconds} plus the status and how it was produced."""
    return {"sha": record.sha, "config": record.config, "digest": record.digest, "seconds": record.seconds,
            "status": record.status, "reason": record.reason, "defines": list(record.defines), "app": record.app,
            "cached": cached,
            "schema": SCHEMA}


def run_locked(lock_path: str, command: Sequence[str]) -> int:
    """Runs COMMAND as a child while this process holds an exclusive flock on LOCK_PATH; returns its exit code.

    Only this process holds the lock (the child gets no copy of the descriptor), so a build service xcodebuild
    leaves running never keeps it. A second build on the same builder cache exits 75 (EX_TEMPFAIL: run the
    step again later) instead of sharing the source checkout. TERM, INT and HUP go on to the child, whose
    own traps decide what it records; the lock is freed when this process ends.
    """
    if not command:
        raise BuildError("run-locked needs a command after --")
    Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"builds.py: another bench build holds {lock_path}; run this step again later", file=sys.stderr)
            return 75
        child = subprocess.Popen(list(command), close_fds=True)

        def forward(signum: int, _frame: object) -> None:
            child.send_signal(signum)

        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, forward)
        return child.wait()


def _main(argv: Sequence[str]) -> int:
    if argv[:1] == ["run-locked"]:
        rest = list(argv[1:])
        if len(rest) < 2 or rest[1] != "--":
            print("usage: builds.py run-locked LOCKFILE -- CMD ARGS...", file=sys.stderr)
            return 2
        try:
            code = run_locked(rest[0], rest[2:])
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
    p = sub.add_parser("digest")
    p.add_argument("file")
    p = sub.add_parser("supports")
    p.add_argument("--reload", required=True)
    p.add_argument("--config", required=True)
    p = sub.add_parser("defines")
    p.add_argument("--log", required=True)
    args = parser.parse_args(argv)
    try:
        if args.op == "digest":
            print(file_digest(args.file))
            return 0
        if args.op == "supports":
            return 0 if reload_supports(Path(args.reload).read_text(errors="replace"), args.config) else 1
        if args.op == "defines":
            print(" ".join(bench_defines(Path(args.log).read_text(errors="replace"))))
            return 0
        ledger = BuildLedger(args.ledger)
        if args.op == "status":
            record = ledger.get(args.sha, args.config)
            print(record.status if record else "missing")
            return 0
        if args.op == "forget":
            ledger.forget(args.sha, args.config)
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


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
