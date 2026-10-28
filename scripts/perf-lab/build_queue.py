#!/usr/bin/env python3
"""The perf lab's build queue: which bench build each builder runs next (p12-perf-process.md 3.2, 3.11, task 234).

    python3 -I scripts/perf-lab/lab.py builds --enqueue PLAN.json   # the scheduler plan's BuildRequests
    python3 -I scripts/perf-lab/lab.py builds --tick [--dry-run]    # reap, backfill, start free builders
    python3 -I scripts/perf-lab/lab.py builds --document            # {ready, queued, failed, expected_seconds}
    python3 -I scripts/perf-lab/lab.py builds --coverage --since 24h
    python3 -I scripts/perf-lab/lab.py builds --status

Chrome's perf waterfall builds commits on dedicated builders and its testers take the newest built one
(docs/speed/perf_waterfall.md), and Pinpoint's build quest reuses the isolate it already has for a change
(catapult dashboard/dashboard/pinpoint/models/quest/find_isolate.py). This queue does both for bench builds:

- Order: batch tips (in commit order), then tier and lane builds, then bisect midpoints (the scheduler's
  BuildRequests, by their `reason`), then each other first-parent commit of the branch, newest first
  (`backfill`, per-commit builds), so a later bisect finds its midpoints built.
- A (sha, config) with a record in the lab's build ledger (builds.py: ok or failed) gets no job, and every ledger
  record is a build of its own commit: run_story.py measures an app only when its CMUXCommit is the record's sha.
- Each builder keeps one persistent build tree (scripts/measure/perf-lab-build.sh: a source checkout and one
  DerivedData per config). A job goes to the free builder whose tree holds a build of the same bench product key
  (the DEV Release product closure of scripts/ci/job_input_fingerprint.py dev-release-product, the key
  scripts/ci/dev_release_product_reuse.py reuses compiled apps by, plus that script's RECIPE and the config), so a
  docs or tests commit builds as a near no-op; else to the one whose last build of its config is nearest on the
  first-parent chain. The job keeps that sha as `incremental_from`.
- Per-commit builds run only on idle builders: never while a requested build waits, never on the last free
  builder (BACKFILL_RESERVE keeps it for the next tip), as fleet `--background` steps. They are not in the
  scheduler's `queued`, so they never put T0 into every-2nd-batch mode. A request for a pair whose per-commit
  step still waits in the fleet queue cancels that step and starts the pair again as a foreground step.
- A step that ends for a reason that is not the commit's (exit 75, a lost client, a client past
  STEP_TIMEOUT + QUEUE_TIMEOUT + LOST_MARGIN) builds again, up to INFRA_ATTEMPTS starts. Every start has its own
  step key and step directory, so a start never attaches to an earlier start's step. Then a requested pair is
  given up and the scheduler reads it as failed; a per-commit pair is not (only the fleet was busy): a request
  queues it again at once and the backfill after BACKFILL_RETRY_AFTER. Exit 2 (refused) gives up at once.
- Every finished job keeps its build seconds (the receipt's), its wall seconds and whether it was cached or
  incremental; capacity.py reports builder utilization and queue age from that history.
- The commands that change the state (--enqueue, --tick) hold an exclusive flock on STATE.lock from reading
  the state to writing it, so overlapping runs never lose each other's updates (builds.py run_locked's lock).

Stdlib only; loads siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import re
import statistics
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import asdict, dataclass, field, fields
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
SCHEMA = "cmux-perf-lab-build-queue/v1"
SCRIPT = "scripts/measure/perf-lab-build.sh"
ARTIFACT = "artifacts/perf-lab-build/app.zip"
DATA_DIR = Path.home() / "Library" / "Application Support" / "cmux-perf-lab"
DEFAULT_CLIENT = Path.home() / ".local" / "bin" / "cmux-ci"
DEFAULT_MAINLINE = "refs/perf-lab/feat-cmux-next"

KINDS = ("tip", "tier", "lane", "midpoint", "backfill")
PRIORITY = {kind: index for index, kind in enumerate(KINDS)}
BACKFILL_CONFIG = "bench"  # per-commit builds are for bisects of bench stories; bench-checks builds on request
BACKFILL_DEPTH = 200  # newest first-parent commits a per-commit build may go to
BACKFILL_RESERVE = 1  # free builders a per-commit build leaves for the next tip (0 with a single builder)
BACKFILL_RETRY_AFTER = timedelta(hours=12)  # a per-commit pair the busy fleet timed out waits this long
INFRA_ATTEMPTS = 3
HISTORY = 4000  # finished jobs kept for capacity and coverage
EXPECTED_FROM = 10  # recent built tips whose median wall time is the scheduler's expected_seconds
STEP_TIMEOUT = 3 * 3600
QUEUE_TIMEOUT = 2 * 3600
LOST_MARGIN = 3600  # past STEP_TIMEOUT + QUEUE_TIMEOUT + this, a step with no exit code is lost
RECEIPT = re.compile(r"perf-lab-build: (\{.*\})\s*$", re.M)

QUEUED, RUNNING = "queued", "running"
DONE, FAILED = "done", "failed"  # an ok build, a commit's failure
# an attempt the builder lost, its last one, a pair the ledger recorded meanwhile
INFRA, GAVE_UP, DROPPED = "infra", "gave-up", "dropped"
OPEN = (QUEUED, RUNNING)


class BuildQueueError(ValueError):
    pass


def _sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


builds = _sibling("builds")


def stamp(moment: datetime) -> str:
    if moment.tzinfo is None:
        raise BuildQueueError(f"{moment.isoformat()}: a queue time needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds")


def parse_stamp(text: str) -> datetime:
    return datetime.fromisoformat(text).astimezone(timezone.utc)


def kind_of(reason: str) -> str:
    """The queue class of a BuildRequest reason: batch-tip, tier, lane:NAME, backfill (the queue's own per-commit
    builds) or a pinpoint work id."""
    if reason == "batch-tip":
        return "tip"
    if reason in ("tier", "backfill"):
        return reason
    if reason.startswith("lane:"):
        return "lane"
    return "midpoint"


@dataclass
class Job:
    id: str
    sha: str
    config: str
    kind: str
    reason: str
    enqueued_at: str
    position: int | None = None  # on the first-parent chain, counted from the root; None off the chain
    state: str = QUEUED
    attempts: int = 0  # starts that count toward INFRA_ATTEMPTS
    starts: int = 0  # every start, withdrawn ones too: each start's step key and step directory
    background: bool = False  # the running start went out as a fleet --background step
    builder: str | None = None
    started_at: str | None = None
    ended_at: str | None = None
    incremental_from: str | None = None  # the builder's previous build of this config, when its tree had one
    seconds: int | None = None  # the receipt's build seconds
    cached: bool = False
    digest: str | None = None
    exit: int | None = None
    step: str | None = None
    pid: int | None = None
    product_key: str | None = None
    note: str | None = None

    @property
    def pair(self) -> tuple[str, str]:
        return self.sha, self.config

    @property
    def wall_seconds(self) -> int | None:
        if not (self.started_at and self.ended_at):
            return None
        return int((parse_stamp(self.ended_at) - parse_stamp(self.started_at)).total_seconds())

    @property
    def incremental(self) -> bool:
        return self.state in (DONE, FAILED) and not self.cached and self.incremental_from is not None

    @classmethod
    def from_json(cls, data: Mapping) -> Job:
        names = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in names})


@dataclass
class QueueState:
    seq: int = 0
    jobs: list[Job] = field(default_factory=list)
    last_built: dict[str, dict[str, str]] = field(default_factory=dict)  # builder -> config -> sha in its tree

    def to_document(self) -> dict:
        return {"schema": SCHEMA, "seq": self.seq, "jobs": [asdict(j) for j in self.jobs],
                "last_built": self.last_built}

    @classmethod
    def from_document(cls, document: Mapping) -> QueueState:
        if document.get("schema") != SCHEMA:
            raise BuildQueueError(f"queue state schema {document.get('schema')!r} is not {SCHEMA}")
        return cls(seq=int(document.get("seq", 0)), jobs=[Job.from_json(j) for j in document.get("jobs", ())],
                   last_built={b: dict(c) for b, c in document.get("last_built", {}).items()})


def load_state(path: Path) -> QueueState:
    return QueueState.from_document(json.loads(path.read_text())) if path.is_file() else QueueState()


def save_state(path: Path, state: QueueState) -> None:
    """Atomic: a reader sees the old state or the new one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=path.parent, prefix=".build-queue-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(state.to_document(), out, indent=1, sort_keys=True)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def ledger_records(root: Path) -> list:
    """Every record of the lab's build ledger (builds.py) under ROOT/records."""
    return [builds.BuildRecord.from_json(json.loads(path.read_text(encoding="utf-8")))
            for path in sorted((Path(root) / "records").glob("*.json"))]


class BuildQueue:
    """The queue over its state, the lab's build ledger and two git seams: `position(sha)` (first-parent index, or
    None) and `product_key(sha, config)` (bench product key, or None when it cannot be read). Pure besides the
    ledger: `now` is passed in."""

    def __init__(self, state: QueueState, ledger_root: Path | str, *,
                 position: Callable[[str], int | None] = lambda sha: None,
                 product_key: Callable[[str, str], str | None] = lambda sha, config: None) -> None:
        self.state = state
        self.ledger_root = Path(ledger_root)
        self.ledger = builds.BuildLedger(ledger_root)
        self.position = position
        self.product_key = product_key

    # ---- reading ----

    def open_jobs(self, *states: str) -> list[Job]:
        wanted = states or OPEN
        return [job for job in self.state.jobs if job.state in wanted]

    def _open(self, pair: tuple[str, str]) -> Job | None:
        return next((job for job in self.open_jobs() if job.pair == pair), None)

    def _gave_up(self) -> list[Job]:
        held = {job.pair for job in self.open_jobs()}
        return [job for job in self.state.jobs if job.state == GAVE_UP and job.pair not in held]

    def given_up(self) -> set[tuple[str, str]]:
        """Requested pairs given up (the scheduler's failed). A per-commit pair given up is not: its steps only
        waited on a busy fleet or lost their client, and nothing says the commit does not build."""
        return {job.pair for job in self._gave_up() if job.kind != "backfill"}

    def order(self) -> list[Job]:
        """Queued jobs in dispatch order, before builder affinity."""
        def key(job: Job) -> tuple:
            seq = int(job.id.lstrip("b"))
            position = job.position if job.position is not None else -1
            if job.kind == "tip":
                return PRIORITY["tip"], job.position is None, position, seq
            if job.kind == "backfill":
                return PRIORITY["backfill"], -position, seq
            return PRIORITY[job.kind], seq
        return sorted(self.open_jobs(QUEUED), key=key)

    # ---- adding work ----

    def enqueue(self, sha: str, config: str, reason: str, now: datetime) -> Job | None:
        """A job for (sha, config), or None when the ledger has it or a job already holds it. A requested pair that
        waits as a per-commit build moves up to the request's class; when its step already went out as a background
        step, the next tick withdraws that step (`promoted`)."""
        builds.build_key(sha, config)
        kind = kind_of(reason)
        pair = (sha, config)
        held = self._open(pair)
        if held is not None:
            if PRIORITY[kind] < PRIORITY[held.kind]:
                held.kind, held.reason = kind, reason
            return None
        if self.ledger.get(sha, config) is not None:
            return None
        self.state.seq += 1
        job = Job(id=f"b{self.state.seq:06d}", sha=sha, config=config, kind=kind, reason=reason,
                  enqueued_at=stamp(now), position=self.position(sha), product_key=self.product_key(sha, config))
        self.state.jobs.append(job)
        return job

    def enqueue_plan(self, document: Mapping, now: datetime) -> list[Job]:
        """The `builds` of a scheduler plan (scheduler.Plan.to_document())."""
        added = []
        for request in document.get("builds", ()):
            job = self.enqueue(str(request["sha"]), str(request["config"]), str(request["reason"]), now)
            if job is not None:
                added.append(job)
        return added

    def backfill(self, newest_first: Sequence[str], now: datetime, *, depth: int = BACKFILL_DEPTH) -> list[Job]:
        """A per-commit job for each first-parent commit (newest first) with no record and no job. A requested pair
        given up on stays given up; a per-commit one waits BACKFILL_RETRY_AFTER from its last end."""
        retry_from = now - BACKFILL_RETRY_AFTER
        skip = self.given_up() | {job.pair for job in self._gave_up()
                                  if job.ended_at is None or parse_stamp(job.ended_at) > retry_from}
        added = []
        for sha in newest_first[:depth]:
            if (sha, BACKFILL_CONFIG) in skip:
                continue
            job = self.enqueue(sha, BACKFILL_CONFIG, "backfill", now)
            if job is not None:
                added.append(job)
        return added

    def _history(self, job: Job) -> None:
        self.state.jobs.append(job)
        self._trim()

    def _trim(self) -> None:
        done = [j for j in self.state.jobs if j.state not in OPEN]
        if len(done) > HISTORY:
            drop = {id(j) for j in done[:len(done) - HISTORY]}
            self.state.jobs = [j for j in self.state.jobs if id(j) not in drop]

    # ---- dispatch ----

    def _tree_key(self, builder: str, config: str) -> str | None:
        """The product key of the ok build in BUILDER's tree of CONFIG, when its job is in the history."""
        last = self.state.last_built.get(builder, {}).get(config)
        built = next((job for job in reversed(self.state.jobs) if job.state == DONE and job.builder == builder
                      and job.pair == (last, config) and not job.cached), None)
        return built.product_key if built is not None else None

    def _distance(self, builder: str, job: Job) -> tuple[int, int]:
        last = self.state.last_built.get(builder, {}).get(job.config)
        if last is None:
            return 3, 0
        if job.product_key is not None and self._tree_key(builder, job.config) == job.product_key:
            return 0, 0  # the tree holds this product: the build only stamps and packages this commit
        at = self.position(last)
        if at is None or job.position is None:
            return 2, 0
        return 1, abs(job.position - at)

    def assign(self, builders: Sequence[str], now: datetime, *, busy: Iterable[str] = ()) -> list[Job]:
        """Starts queued jobs on free builders (in `builders`, not `busy`, running none of ours)."""
        for job in self.open_jobs(QUEUED):
            if self.ledger.get(job.sha, job.config) is not None:
                job.state, job.ended_at, job.note = DROPPED, stamp(now), "recorded in the ledger meanwhile"
        running = {job.builder for job in self.open_jobs(RUNNING)}
        free = [b for b in builders if b not in running and b not in set(busy)]
        reserve = BACKFILL_RESERVE if len(builders) > 1 else 0
        started = []
        queued = self.order()
        requested = sum(1 for job in queued if job.kind != "backfill")
        for job in queued:
            if not free:
                break
            if job.kind == "backfill" and (requested > 0 or len(free) <= reserve):
                break
            builder = min(free, key=lambda b: (self._distance(b, job), b))
            free.remove(builder)
            if job.kind != "backfill":
                requested -= 1
            job.state, job.builder, job.started_at = RUNNING, builder, stamp(now)
            job.attempts += 1
            job.starts += 1
            job.background = job.kind == "backfill"
            job.incremental_from = self.state.last_built.get(builder, {}).get(job.config)
            started.append(job)
        return started

    def finish(self, job_id: str, exit_code: int, receipt: Mapping | None, now: datetime, *,
               step: str | None = None) -> Job:
        """The step of a running job ended: record its receipt in the ledger, or build it again (INFRA)."""
        job = next((j for j in self.open_jobs(RUNNING) if j.id == job_id), None)
        if job is None:
            raise BuildQueueError(f"no running build job {job_id}")
        job.ended_at, job.exit, job.step = stamp(now), exit_code, step or job.step
        ours = receipt is not None and receipt.get("sha") == job.sha and receipt.get("config") == job.config
        status = receipt.get("status") if ours else None
        if (exit_code, status) in ((0, "ok"), (1, "failed")):
            job.seconds, job.cached = int(receipt.get("seconds") or 0), bool(receipt.get("cached"))
            job.digest = receipt.get("digest")
            try:
                self.ledger.record(builds.BuildRecord(
                    sha=job.sha, config=job.config, status=status, seconds=job.seconds, digest=job.digest,
                    reason=receipt.get("reason"), defines=tuple(receipt.get("defines") or ()),
                    app=receipt.get("app"), job=job.step))
            except builds.BuildError as error:
                job.state, job.note = GAVE_UP, f"the ledger refused the receipt: {error}"
                return job
            job.state = DONE if status == "ok" else FAILED
            if job.cached:
                job.incremental_from = None
            else:
                self.state.last_built.setdefault(job.builder, {})[job.config] = job.sha
            self._trim()
            return job
        why = f"exit {exit_code}" + ("" if ours else ", no receipt of this build")
        if exit_code == 2 or job.attempts >= INFRA_ATTEMPTS:
            job.state, job.note = GAVE_UP, f"{why} (attempt {job.attempts} of {INFRA_ATTEMPTS})"
            self._trim()
            return job
        attempt = Job.from_json({**asdict(job), "id": f"{job.id}.{job.starts}", "state": INFRA, "note": why})
        self._requeue(job)
        self._history(attempt)
        return attempt

    def promoted(self) -> list[Job]:
        """Running jobs a request moved up while their step waits as a fleet background step."""
        return [job for job in self.open_jobs(RUNNING) if job.background and job.kind != "backfill"]

    def withdraw(self, job_id: str) -> Job:
        """A promoted job whose background step was cancelled before a worker claimed it queues again in its
        requested class; the withdrawn start does not count toward INFRA_ATTEMPTS."""
        job = next((j for j in self.promoted() if j.id == job_id), None)
        if job is None:
            raise BuildQueueError(f"no promoted build job {job_id}")
        job.attempts -= 1
        self._requeue(job)
        return job

    @staticmethod
    def _requeue(job: Job) -> None:
        job.state, job.builder, job.started_at, job.ended_at, job.exit = QUEUED, None, None, None, None
        job.incremental_from, job.pid, job.step, job.background = None, None, None, False

    # ---- the scheduler's view ----

    def scheduler_document(self) -> dict:
        """scheduler.builds_from_document input: ok and failed ledger records, the requested builds the builders
        hold (queued or running; per-commit builds are not), given-up requested pairs as failed, and the median wall
        time of recent built tips as expected_seconds."""
        records = ledger_records(self.ledger_root)
        failed = {r_pair(r) for r in records if r.status == "failed"} | self.given_up()
        tips = [j.wall_seconds for j in self.state.jobs
                if j.state == DONE and j.kind == "tip" and not j.cached and j.wall_seconds is not None]
        return {"ready": sorted(list(r_pair(r)) for r in records if r.status == "ok"),
                "queued": sorted(list(j.pair) for j in self.open_jobs() if j.kind != "backfill"),
                "failed": sorted(list(pair) for pair in failed),
                "expected_seconds": int(statistics.median(tips[-EXPECTED_FROM:])) if tips else 0}


def r_pair(record) -> tuple[str, str]:
    return record.sha, record.config


# ---------- steps on the fleet ----------

def step_key(job: Job) -> str:
    """One key per start: the controller hands a known key its existing step back, finished or cancelled too."""
    return f"perf-lab-build-{job.sha[:12]}-{job.config}-{job.id}-s{job.starts}"


def step_argv(job: Job, tip: str) -> list[str]:
    """`cmux-ci run` of perf-lab-build.sh at the tip harness on the job's builder; per-commit builds go after every
    foreground job."""
    background = ["--background"] if job.background else []
    return ["run", "--class", "exclusive", *background, "--target-worker", job.builder, "--no-supersede",
            "--script", SCRIPT, "--ref", tip, "--key", step_key(job),
            "--artifact", ARTIFACT, "--timeout", str(STEP_TIMEOUT), "--queue-timeout", str(QUEUE_TIMEOUT),
            f"--arg=--build-sha={job.sha}", f"--arg=--config={job.config}"]


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class StepRunner:
    """Starts each `cmux-ci run` (it blocks until the step ends) in a detached subshell that writes its output to
    STEPS/<job>/step.log and then its exit code to STEPS/<job>/rc, so the queue's process can exit and a later tick
    reads the result."""

    # The subshell outlives the sh that starts it (which prints its pid and exits), so no caller reaps the step.
    WRAPPER = '( "$@" > "$CMUX_BUILD_STEP_DIR/step.log" 2>&1; echo $? > "$CMUX_BUILD_STEP_DIR/rc.tmp" && ' \
              'mv "$CMUX_BUILD_STEP_DIR/rc.tmp" "$CMUX_BUILD_STEP_DIR/rc" ) < /dev/null > /dev/null 2>&1 & echo $!'
    STEP_ID = re.compile(r"cmux-ci: step ([0-9a-f]{12,}) ")
    LOST_AFTER = timedelta(seconds=STEP_TIMEOUT + QUEUE_TIMEOUT + LOST_MARGIN)

    def __init__(self, steps_dir: Path | str, client: Path | str = DEFAULT_CLIENT, *,
                 spawn: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                 alive: Callable[[int], bool] = _pid_alive) -> None:
        self.steps_dir, self.client, self._spawn, self._alive = Path(steps_dir), str(client), spawn, alive

    def _dir(self, job: Job) -> Path:
        """One directory per start: an earlier start's client that still runs never writes into a later one's."""
        return self.steps_dir / f"{job.id}-s{job.starts}"

    def start(self, job: Job, argv: Sequence[str]) -> int:
        directory = self._dir(job)
        directory.mkdir(parents=True, exist_ok=True)
        for name in ("rc", "step.log"):
            (directory / name).unlink(missing_ok=True)
        done = self._spawn(["/bin/sh", "-c", self.WRAPPER, "sh", self.client, *argv],
                           env={**os.environ, "CMUX_BUILD_STEP_DIR": str(directory)}, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=30, start_new_session=True)
        pid = done.stdout.strip()
        if done.returncode != 0 or not pid.isdigit():
            raise OSError(f"could not start {self.client}: {done.stderr.strip()[-300:]}")
        return int(pid)

    def result(self, job: Job, now: datetime) -> tuple[int, dict | None, str | None] | None:
        """(exit code, receipt, step id) once the step ended, else None. A client that is gone without an exit
        code, or that has none past LOST_AFTER (its own timeouts bound it, so its pid now names another process),
        ended as 75: nothing recorded, built again."""
        directory = self._dir(job)
        rc = directory / "rc"
        if not rc.is_file():
            lost = job.started_at is not None and now - parse_stamp(job.started_at) > self.LOST_AFTER
            if job.pid is not None and not lost and self._alive(job.pid):
                return None
            code = 75
        else:
            text = rc.read_text().strip()
            code = int(text) if text.lstrip("-").isdigit() else 75
        log = (directory / "step.log").read_text(errors="replace") if (directory / "step.log").is_file() else ""
        found = RECEIPT.findall(log)
        try:
            receipt = json.loads(found[-1]) if found else None
        except ValueError:
            receipt = None
        step = self.STEP_ID.search(log)
        return code, receipt if isinstance(receipt, dict) else None, step.group(1) if step else None

    def withdraw(self, job: Job) -> bool:
        """Cancels the job's fleet step while no worker has claimed it; True when it was cancelled. A step whose
        id the client has not printed yet, or that a worker runs, stays (the next tick asks again)."""
        log = self._dir(job) / "step.log"
        found = self.STEP_ID.search(log.read_text(errors="replace")) if log.is_file() else None
        if found is None:
            return False
        step = found.group(1)
        try:
            if json.loads(self._client("status", step)).get("state") != "queued":
                return False
            self._client("cancel", step, "--reason", f"perf lab: {job.reason} builds {job.sha[:12]} in the foreground")
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return False
        return True

    def _client(self, *argv: str) -> str:
        done = self._spawn([self.client, *argv], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=60)
        if done.returncode != 0:
            raise OSError(f"{self.client} {argv[0]} exited {done.returncode}: {done.stderr.strip()[-300:]}")
        return done.stdout


def tick(queue: BuildQueue, runner: StepRunner, builders: Sequence[str], tip: str, newest_first: Sequence[str],
         now: datetime, *, busy: Iterable[str] = (), dry_run: bool = False) -> dict:
    """One builder round: reap ended steps, withdraw requested pairs' unclaimed background steps, queue per-commit
    builds, start the free builders."""
    reaped = []
    for job in list(queue.open_jobs(RUNNING)):
        ended = runner.result(job, now)
        if ended is not None:
            code, receipt, step = ended
            reaped.append(asdict(queue.finish(job.id, code, receipt, now, step=step)))
    withdrawn = []
    for job in queue.promoted():
        if not dry_run and runner.withdraw(job):
            withdrawn.append(queue.withdraw(job.id).id)
    added = queue.backfill(newest_first, now)
    started = queue.assign(builders, now, busy=busy)
    for job in started:
        if dry_run:
            continue
        try:
            job.pid = runner.start(job, step_argv(job, tip))
        except (OSError, subprocess.SubprocessError) as error:
            queue.finish(job.id, 75, None, now).note = f"could not start the step: {error}"
    started = [job for job in started if job.state == RUNNING]
    return {"reaped": reaped, "withdrawn": withdrawn, "backfilled": len(added),
            "started": [{"id": j.id, "sha": j.sha, "config": j.config, "kind": j.kind, "builder": j.builder,
                         "incremental_from": j.incremental_from, "argv": step_argv(j, tip)} for j in started]}


# ---------- coverage ----------

def coverage(commits: Sequence[tuple[str, datetime]], queue: BuildQueue, now: datetime, since: datetime) -> dict:
    """Of the first-parent commits in the window from `since` to `now` (newest first, with their commit times): how
    many have a bench build, failed, wait in the queue, were given up or have nothing, and how long the tips queued
    in the window waited for their builds. A commit's row is its job's: an attempt the builder lost and a job
    dropped for a ledger record are not the commit's."""
    jobs = {job.sha: job for job in queue.state.jobs
            if job.config == BACKFILL_CONFIG and job.state not in (*OPEN, INFRA, DROPPED)}
    jobs.update({job.sha: job for job in queue.open_jobs() if job.config == BACKFILL_CONFIG})
    rows = []
    for sha, committed in commits:
        record = queue.ledger.get(sha, BACKFILL_CONFIG)
        job = jobs.get(sha)
        if record is not None:
            status = "failed" if record.status == "failed" else "built"
        elif job is not None and job.state in OPEN:
            status = job.state
        elif job is not None and job.state == GAVE_UP:
            status = GAVE_UP
        else:
            status = "missing"
        rows.append({"sha": sha, "committed_at": stamp(committed), "status": status,
                     "kind": job.kind if job else None,
                     "seconds": job.seconds if job else None, "wall_seconds": job.wall_seconds if job else None})
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    covered = counts.get("built", 0)
    tip_waits = sorted(int((parse_stamp(j.ended_at) - parse_stamp(j.enqueued_at)).total_seconds())
                       for j in queue.state.jobs if j.kind == "tip" and j.state == DONE and j.ended_at
                       and parse_stamp(j.enqueued_at) >= since)
    return {"now": stamp(now), "since": stamp(since), "commits": len(rows), "counts": counts,
            "built_fraction": round(covered / len(rows), 4) if rows else None,
            "tip_build_wait_s": summary(tip_waits), "rows": rows}


def summary(values: Sequence[float]) -> dict | None:
    """p50, p95, max (nearest rank) and n of `values`, or None when empty."""
    if not values:
        return None
    ordered = sorted(values)

    def rank(q: float) -> float:
        return ordered[max(0, math.ceil(q * len(ordered)) - 1)]
    return {"n": len(ordered), "p50": rank(0.5), "p95": rank(0.95), "max": ordered[-1]}


def parse_window(text: str) -> timedelta:
    found = re.fullmatch(r"(\d+)([mhd])", text)
    if not found:
        raise BuildQueueError(f"--since {text!r}: write it as <n>m, <n>h or <n>d (for example 24h)")
    unit = {"m": "minutes", "h": "hours", "d": "days"}[found.group(2)]
    return timedelta(**{unit: int(found.group(1))})


# ---------- git seams ----------

class Git:
    """First-parent positions, recent commits and product keys from the lab's checkout."""

    def __init__(self, repo: Path | str, mainline: str = DEFAULT_MAINLINE, *,
                 run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
        self.repo, self.mainline, self._run = str(repo), mainline, run
        self._positions: dict[str, int] | None = None
        self._fingerprint = None

    def _git(self, *args: str) -> str | None:
        try:
            done = self._run(["git", "-C", self.repo, *args], capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout if done.returncode == 0 else None

    def tip(self) -> str | None:
        out = self._git("rev-parse", "--verify", "--quiet", f"{self.mainline}^{{commit}}")
        return out.strip() if out else None

    def position(self, sha: str) -> int | None:
        if self._positions is None:
            chain = self._git("rev-list", "--first-parent", "--reverse", self.mainline, "--") or ""
            self._positions = {s: i for i, s in enumerate(chain.split(), start=1)}
        return self._positions.get(sha)

    def commits(self, since: datetime | None = None, limit: int = BACKFILL_DEPTH) -> list[tuple[str, datetime]]:
        """First-parent commits newest first, with their committer times."""
        args = ["log", "--first-parent", "--format=%H %ct", f"--max-count={limit}"]
        if since is not None:
            args.append(f"--since=@{int(since.timestamp())}")
        out = self._git(*args, self.mainline, "--") or ""
        found = []
        for line in out.splitlines():
            sha, _, seconds = line.partition(" ")
            found.append((sha, datetime.fromtimestamp(int(seconds), timezone.utc)))
        return found

    def product_key(self, sha: str, config: str) -> str | None:
        """The bench product key: the DEV Release product closure at SHA, that script's RECIPE and the config."""
        if self._fingerprint is None:
            self._fingerprint = _load_path("perf_lab_job_input_fingerprint",
                                           REPO_ROOT / "scripts/ci/job_input_fingerprint.py")
            self._recipe = _load_path("perf_lab_dev_release_product_reuse",
                                      REPO_ROOT / "scripts/ci/dev_release_product_reuse.py").RECIPE
        try:
            inputs = self._fingerprint.product_inputs(self.repo, sha)
        except (self._fingerprint.Unresolved, subprocess.SubprocessError, OSError):
            return None
        raw = json.dumps({"recipe": self._recipe, "build": "perf-lab-bench/v1", "config": config, "inputs": inputs},
                         sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(raw.encode()).hexdigest()


def _load_path(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def pool_builders(pool: Path) -> list[str]:
    return [str(b["name"]) for b in json.loads(pool.read_text()).get("builders", ())]


# ---------- command (lab.py protocol, task 005) ----------

LAB_COMMANDS = {
    "builds": "The bench build queue (task 234): --enqueue PLAN | --tick | --document | --coverage --since 24h | "
              "--status",
}


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--enqueue", type=Path, metavar="PLAN", help="queue a scheduler plan's builds ('-': stdin)")
    mode.add_argument("--tick", action="store_true", help="reap ended steps, queue per-commit builds, start builders")
    mode.add_argument("--document", action="store_true", help="the scheduler's --builds JSON")
    mode.add_argument("--coverage", action="store_true", help="bench builds of the first-parent commits in --since")
    mode.add_argument("--status", action="store_true", help="open jobs and each builder's last build")
    parser.add_argument("--data-dir", type=Path, default=DATA_DIR)
    parser.add_argument("--state", type=Path, help="queue state (default DATA_DIR/build-queue.json)")
    parser.add_argument("--ledger", type=Path, help="the lab's build ledger (default DATA_DIR/builds)")
    parser.add_argument("--repo", type=Path, help="the lab's checkout (default DATA_DIR/repo)")
    parser.add_argument("--mainline", default=DEFAULT_MAINLINE)
    parser.add_argument("--pool", type=Path, default=HERE / "pool.json")
    parser.add_argument("--client", type=Path, default=DEFAULT_CLIENT)
    parser.add_argument("--busy", action="append", default=[], help="a builder the controller reports busy")
    parser.add_argument("--since", default="24h")
    parser.add_argument("--dry-run", action="store_true", help="--tick: print the starts, run nothing")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--now", help=argparse.SUPPRESS)


@contextlib.contextmanager
def state_lock(state_path: Path):
    """An exclusive flock on STATE.lock (a sidecar: os.replace swaps the state file itself) held over one whole
    read-change-write of the state."""
    lock_path = state_path.with_name(state_path.name + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out, err = out or sys.stdout, err or sys.stderr
    state_path = args.state or args.data_dir / "build-queue.json"
    mutates = args.enqueue is not None or args.tick
    try:
        with state_lock(state_path) if mutates else contextlib.nullcontext():
            return _run(args, state_path, out)
    except (BuildQueueError, builds.BuildError, OSError, ValueError, KeyError) as error:
        print(f"builds: {error}", file=err)
        return 2


def _run(args: argparse.Namespace, state_path: Path, out) -> int:
    now = parse_stamp(args.now) if args.now else datetime.now(timezone.utc)
    git = Git(args.repo or args.data_dir / "repo", args.mainline)
    queue = BuildQueue(load_state(state_path), args.ledger or args.data_dir / "builds",
                       position=git.position, product_key=git.product_key)
    if args.coverage:
        since = now - parse_window(args.since)
        report = coverage(git.commits(since, limit=100_000), queue, now, since)
        if args.json:
            json.dump(report, out, indent=1)
            print(file=out)
        else:
            print(format_coverage(report, args.since), file=out)
        return 0
    if args.document:
        json.dump(queue.scheduler_document(), out, indent=1)
        print(file=out)
        return 0
    if args.status:
        json.dump({"open": [asdict(j) for j in queue.order() + queue.open_jobs(RUNNING)],
                   "last_built": queue.state.last_built}, out, indent=1)
        print(file=out)
        return 0
    if args.enqueue is not None:
        text = sys.stdin.read() if str(args.enqueue) == "-" else args.enqueue.read_text()
        added = queue.enqueue_plan(json.loads(text), now)
        json.dump({"queued": [j.id for j in added], "builds": []}, out)
        print(file=out)
    else:
        tip = git.tip()
        if tip is None:
            raise BuildQueueError(f"{git.repo}: no {args.mainline}; the tick builds with the tip harness")
        report = tick(queue, StepRunner(args.data_dir / "build-steps", args.client), pool_builders(args.pool),
                      tip, [sha for sha, _ in git.commits()], now, busy=args.busy, dry_run=args.dry_run)
        json.dump(report, out, indent=1)
        print(file=out)
        if args.dry_run:
            return 0
    save_state(state_path, queue.state)
    return 0


def format_coverage(report: dict, since: str) -> str:
    counts = ", ".join(f"{n} {status}" for status, n in sorted(report["counts"].items())) or "none"
    fraction = report["built_fraction"]
    lines = [f"bench builds of the {report['commits']} first-parent commits since {since}: {counts}"
             + ("" if fraction is None else f" ({fraction:.0%} built)")]
    waits = report["tip_build_wait_s"]
    if waits:
        lines.append(f"batch tip build wait: p50 {waits['p50']} s, p95 {waits['p95']} s, max {waits['max']} s "
                     f"(n {waits['n']})")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="build_queue.py", description=LAB_COMMANDS["builds"])
    add_arguments("builds", parser)
    return run("builds", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
