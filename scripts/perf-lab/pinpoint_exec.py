#!/usr/bin/env python3
"""Pinpoint's executor: carries out the pure core's actions (pinpoint.py, task 015) on the lab.

labd (task 012) calls `Executor.tick()` every scheduler poll and on controller callbacks. One tick:

1. starts a bisect for each new monitored alert group (state new or triaged, no bisect job yet), pinned to
   the group's largest regression: its story, metric, build config and host class, over the commits between
   the last waterfall point before the alert and the first one at its end. Magnitude = the alert's delta
   (median_after - median_before, in the metric's unit); pinpoint.py turns it into IQRs (3.6).
2. for each running bisect job: reads the answers to its outstanding actions, steps the core until it waits,
   persists the job state, and submits the new actions:
   - Build(change): no stored build, so a perf-lab-build request (scripts/measure/perf-lab-build.sh, task
     009) for (sha, config). The build ledger (builds.py) answers it: ok -> built, failed -> unbuildable
     (the core skips that commit). A builder job that ends with no ledger record failed for a reason the
     commit did not cause and is requested again, at most BUILD_RETRIES more times.
   - Run(change, start, count): one story job (scripts/measure/perf-lab.sh, task 008) of `--repeats count`
     on one host of the job's class: an idle pinpoint host, preferably the one the job used before, else a
     waterfall host of the class that is idle with its next T0 more than BORROW_LEAD away and that the run
     ends before (3.1). Never a host of another class, never a busy or down one.
   - Done(result): stores the result on the job and moves the group: a culprit -> `culprit` (unverified;
     verify.py, task 017, decides), no culprit -> back to `triaged` with the outcome as the reason.

Results come from the lab store. Each story job has its own jobs row (kind bisect, alert_group_id NULL,
params_json.bisect_job = the bisect's row, controller_job_id = the controller's id). labd's job-finished
hook (task 012) ingests the job's artifact with Run.job_id = that row and sets the row's state to `ingested`;
repeat i of the job is the i-th of its runs by start time. A repeat with no run, or a run without the metric,
is a failed attempt.

Restart. Catapult stores a Pinpoint job after every pass of Job.Run (dashboard/dashboard/pinpoint/models/
job.py: explore, schedule, put()). Here the job state is a journal in STATE_DIR/bisect-<id>.json, replaced
atomically after every step: every step() call with the actions it returned, and every result in the order it
was recorded. A restart replays the journal through a fresh pinpoint.JobState; step() is deterministic, so the
replay reproduces the same state, and a replayed step that returns other actions is refused. Each controller
request carries a key derived from the job, the action and its try; the key is saved before the request and
`Controller.find(key)` is asked first after a restart, so a request that was sent before a crash is adopted,
never sent again.

The controller (task 010: the perf-lab label, host roles, affinity) is the injected `Controller`; labd
provides the client. Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import importlib.util
import json
import math
import os
import sqlite3
import sys
import tempfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Protocol

HERE = Path(__file__).resolve().parent


def _load_sibling(module_name: str, filename: str):
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


pinpoint = _load_sibling("perf_lab_pinpoint", "pinpoint.py")
builds = _load_sibling("perf_lab_builds", "builds.py")

CHECKPOINT_SCHEMA = "cmux-perf-pinpoint-exec/v1"
JOB_KIND = "bisect"
ACTOR = "perf-lab-pinpoint"
BORROW_LEAD = timedelta(minutes=10)  # the scheduler's rule (task 011): a borrowed waterfall host keeps its T0
BUILD_RETRIES = 2  # a builder job that recorded nothing is requested again this many times
RUN_RETRIES = 3  # a story job refused by its host (env-invalid, no artifact, a signal) is run again this often
WATERFALL, PINPOINT = "waterfall", "pinpoint"
START_STATES = ("new", "triaged")
# run_story.py exit codes (task 008): 0 every repeat wrote results, 1 a repeat failed; anything else measured nothing.
MEASURED_EXITS = (0, 1)

# Journal and action states.
PENDING, SUBMITTING, SUBMITTED, DONE = "pending", "submitting", "submitted", "done"


class ExecError(RuntimeError):
    """A job the executor cannot carry on: a journal that does not replay, or a store it cannot use."""


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(moment: datetime) -> str:
    """The lab store's stamp: fixed-width UTC ISO-8601 (store.py _stamp)."""
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise ExecError(f"{moment.isoformat()}: a stored time needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


# ---------- the controller seam ----------

@dataclass(frozen=True)
class LabHost:
    """A lab host as the controller's status shows it. next_t0_at: the scheduler's next T0 start for a
    waterfall host; None means unknown, and an unknown host is never borrowed."""

    name: str
    role: str  # WATERFALL or PINPOINT
    host_class: str
    up: bool = True
    busy: bool = False
    next_t0_at: datetime | None = None


@dataclass(frozen=True)
class BuildRequest:
    key: str
    sha: str
    config: str


@dataclass(frozen=True)
class StoryRequest:
    key: str
    host: str
    story: str
    sha: str
    config: str
    digest: str  # "sha256:<64 hex>", perf-lab.sh --digest
    repeats: int
    lab_job_id: int  # the story job's row in the lab store; the ingest links its runs to it


@dataclass(frozen=True)
class ControllerJob:
    """finished: the job ended; exit_code: the entry's exit status (None for a job that never ran).
    not_measurable: the build lacks a capability the story needs (task 211's debug.capabilities check)."""

    finished: bool
    exit_code: int | None = None
    not_measurable: bool = False


class Controller(Protocol):
    def hosts(self) -> Sequence[LabHost]: ...

    def find(self, key: str) -> str | None: ...

    def submit_build(self, request: BuildRequest) -> str: ...

    def submit_story(self, request: StoryRequest) -> str: ...

    def status(self, controller_job_id: str) -> ControllerJob: ...


class Ledger(Protocol):
    def get(self, sha: str, config: str): ...  # builds.BuildRecord | None


def pick_host(hosts: Sequence[LabHost], host_class: str, *, now: datetime, seconds: float | None,
              taken: set[str], prefer: str | None = None) -> LabHost | None:
    """The host for one story job of `host_class`, or None to wait.

    An idle pinpoint host of the class first (`prefer` before the others). A waterfall host of the class only
    when it is idle, its next T0 is known and more than BORROW_LEAD away, and the run's known length ends
    before it. A host of another class is never a candidate."""
    def idle(host: LabHost) -> bool:
        return host.up and not host.busy and host.name not in taken

    same = sorted((h for h in hosts if h.host_class == host_class and idle(h)), key=lambda h: h.name)
    own = [h for h in same if h.role == PINPOINT]
    if own:
        return next((h for h in own if h.name == prefer), own[0])
    if seconds is None:
        return None
    for host in same:
        if host.role != WATERFALL or host.next_t0_at is None:
            continue
        if host.next_t0_at - now > BORROW_LEAD and now + timedelta(seconds=seconds) <= host.next_t0_at:
            return host
    return None


# ---------- serialization ----------

def change_doc(change) -> dict:
    return {"sha": change.sha, "deps": [list(dep) for dep in change.deps]}


def change_of(doc: Mapping) -> object:
    return pinpoint.Change(doc["sha"], tuple(tuple(dep) for dep in doc.get("deps", ())))


def attempt_doc(attempt) -> dict:
    return {"change": change_doc(attempt.change), "index": attempt.index, "values": list(attempt.values),
            "failed": attempt.failed, "measurable": attempt.measurable}


def attempt_of(doc: Mapping) -> object:
    return pinpoint.Attempt(change_of(doc["change"]), int(doc["index"]), tuple(float(v) for v in doc["values"]),
                            bool(doc["failed"]), bool(doc["measurable"]))


def action_doc(action) -> dict:
    if isinstance(action, pinpoint.Build):
        return {"build": change_doc(action.change)}
    if isinstance(action, pinpoint.Run):
        return {"run": change_doc(action.change), "start": action.start, "count": action.count}
    if isinstance(action, pinpoint.Done):
        return {"done": action.result.outcome}
    raise ExecError(f"unknown pinpoint action {action!r}")


def job_doc(job, *, config: str) -> dict:
    return {"kind": job.kind, "mode": job.mode, "story": job.story, "metric": job.metric,
            "host_class": job.host_class, "config": config, "magnitude": job.magnitude, "better": job.better,
            "good": change_doc(job.good), "bad": change_doc(job.bad),
            "commits": [{"sha": c.sha, "batch_tip": c.batch_tip, "stored_build": c.stored_build,
                         "deps": [list(dep) for dep in c.deps]} for c in job.commits]}


def job_of(doc: Mapping) -> object:
    commits = tuple(pinpoint.Commit(c["sha"], bool(c["batch_tip"]), bool(c["stored_build"]),
                                    tuple(tuple(dep) for dep in c.get("deps", ()))) for c in doc["commits"])
    return pinpoint.Job(kind=doc["kind"], mode=doc["mode"], story=doc["story"], metric=doc["metric"],
                        host_class=doc["host_class"], good=change_of(doc["good"]), bad=change_of(doc["bad"]),
                        magnitude=doc["magnitude"], better=doc["better"], commits=commits)


# ---------- the journal ----------

@dataclass
class Checkpoint:
    """A bisect's persisted progress: the journal (steps and results, in order) and its controller requests."""

    job_id: int
    events: list[dict] = field(default_factory=list)
    actions: list[dict] = field(default_factory=list)
    host: str | None = None  # the host the job ran on last; its next story job prefers it

    def dirty(self) -> bool:
        """A result was recorded since the last step, or the job never stepped."""
        return not self.events or self.events[-1]["t"] != "step"

    def to_document(self) -> dict:
        return {"schema": CHECKPOINT_SCHEMA, "job_id": self.job_id, "events": self.events,
                "actions": self.actions, "host": self.host}

    @classmethod
    def from_document(cls, document: Mapping) -> "Checkpoint":
        if document.get("schema") != CHECKPOINT_SCHEMA:
            raise ExecError(f"checkpoint schema {document.get('schema')!r} is not {CHECKPOINT_SCHEMA}")
        return cls(int(document["job_id"]), list(document["events"]), list(document["actions"]), document.get("host"))


def record(state, event: Mapping) -> None:
    """Applies one journaled result (a build answer or an attempt) to the job state."""
    if event["t"] == "build":
        state.record_build(change_of(event["change"]), bool(event["ok"]))
    elif event["t"] == "attempt":
        state.record_attempt(attempt_of(event["attempt"]))
    else:
        raise ExecError(f"journal event kind {event['t']!r} is not a result")


def replay(job, events: Sequence[Mapping]):
    """A JobState with the journal applied: the same step() calls and results, in the same order."""
    state = pinpoint.JobState(job)
    for number, event in enumerate(events):
        if event["t"] != "step":
            record(state, event)
            continue
        actions = [action_doc(action) for action in pinpoint.step(state)]
        if actions != event["actions"]:
            raise ExecError(f"journal event {number}: step() now returns {actions}, the journal has "
                            f"{event['actions']}; the job cannot resume on this pinpoint.py")
    return state


# ---------- the executor ----------

@dataclass
class TickReport:
    started: list[int] = field(default_factory=list)  # new bisect job ids
    finished: list[int] = field(default_factory=list)
    builds_requested: int = 0
    stories_requested: int = 0
    problems: list[str] = field(default_factory=list)


FirstParent = Callable[[str, str], Sequence[str] | None]


class Executor:
    """Drives every running bisect of a migrated lab store (store.py schema >= 1).

    first_parent(good, bad): the first-parent commits after good up to bad, oldest first (None: unknown now).
    repeat_seconds(story): one repeat's wall time, or None; a waterfall host is borrowed only for a known length.
    One sqlite connection, owned by the opening thread like store.Store; every write is BEGIN IMMEDIATE."""

    def __init__(self, db_path: Path | str, state_dir: Path | str, *, controller: Controller, ledger: Ledger,
                 first_parent: FirstParent, repeat_seconds: Callable[[str], float | None] = lambda story: None,
                 clock: Callable[[], datetime] = utc_now, busy_timeout_ms: int = 5000) -> None:
        self._controller = controller
        self._ledger = ledger
        self._first_parent = first_parent
        self._repeat_seconds = repeat_seconds
        self._clock = clock
        self._state_dir = Path(state_dir)
        self._db = sqlite3.connect(str(db_path), isolation_level=None, timeout=busy_timeout_ms / 1000)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA foreign_keys=ON")
        if self._db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'jobs'").fetchone() is None:
            self._db.close()
            raise ExecError(f"{db_path}: not a migrated lab store")

    def close(self) -> None:
        self._db.close()

    def _write(self, statements: Callable[[], object]) -> object:
        self._db.execute("BEGIN IMMEDIATE")
        try:
            result = statements()
        except BaseException:
            self._db.execute("ROLLBACK")
            raise
        self._db.execute("COMMIT")
        return result

    def _now(self) -> str:
        return _stamp(self._clock())

    # --- tick ---

    def tick(self) -> TickReport:
        report = TickReport()
        self.start_bisects(report)
        hosts = tuple(self._controller.hosts())
        taken: set[str] = set()
        jobs = self._db.execute(
            "SELECT * FROM jobs WHERE kind = ? AND alert_group_id IS NOT NULL AND state = 'running' ORDER BY id",
            (JOB_KIND,)).fetchall()
        checkpoints: dict[int, Checkpoint] = {}
        for row in jobs:
            try:
                checkpoints[row["id"]] = self._load(row["id"])
            except ExecError as error:
                report.problems.append(f"bisect {row['id']}: {error}")
        for checkpoint in checkpoints.values():  # hosts our submitted story jobs hold, whatever the controller says
            taken.update(a["host"] for a in checkpoint.actions
                         if a["type"] == "run" and a["status"] == SUBMITTED and not a.get("ended"))
        for row in jobs:
            if row["id"] not in checkpoints:
                continue
            try:  # one job that cannot resume holds up no other
                self._advance(row, checkpoints[row["id"]], hosts, taken, report)
            except ExecError as error:
                report.problems.append(f"bisect {row['id']}: {error}")
        return report

    # --- starting bisects ---

    def start_bisects(self, report: TickReport | None = None) -> list[int]:
        """One bisect per new monitored alert group that has none; groups that cannot start yet are reported."""
        report = report or TickReport()
        marks = ",".join("?" * len(START_STATES))
        groups = self._db.execute(
            f"""SELECT g.* FROM alert_groups g WHERE g.state IN ({marks}) AND NOT EXISTS
                (SELECT 1 FROM jobs j WHERE j.kind = ? AND j.alert_group_id = g.id) ORDER BY g.id""",
            (*START_STATES, JOB_KIND)).fetchall()
        for group in groups:
            try:
                job_id = self._start(group)
            except pinpoint.PinpointError as error:
                report.problems.append(f"group {group['id']}: {error}")
                continue
            if isinstance(job_id, str):
                report.problems.append(f"group {group['id']}: {job_id}")
            else:
                report.started.append(job_id)
        return report.started

    def _top_alert(self, group_id: int) -> sqlite3.Row | None:
        """The group's largest relative regression (alerts.group_alerts' order)."""
        rows = self._db.execute(
            """SELECT a.median_before, a.median_after, a.start_pos, a.end_pos, s.story, s.metric, s.host_class,
                      s.build_config, s.better
               FROM alerts a JOIN series s ON s.id = a.series_id
               WHERE a.group_id = ? AND a.rule = 'edivisive' AND a.is_improvement = 0
                 AND a.median_before IS NOT NULL AND a.median_after IS NOT NULL ORDER BY a.id""",
            (group_id,)).fetchall()

        def change(row: sqlite3.Row) -> float:
            before, after = row["median_before"], row["median_after"]
            return math.inf if before == 0 else abs(after - before) / abs(before)

        return max(rows, key=change, default=None)

    def _waterfall_sha(self, config: str, pos: int, *, before: bool) -> str | None:
        query = ("""SELECT b.sha FROM builds b WHERE b.config = ? AND b.commit_pos < ? AND EXISTS
                    (SELECT 1 FROM runs u WHERE u.build_id = b.id AND u.kind = 'waterfall')
                    ORDER BY b.commit_pos DESC LIMIT 1""" if before else
                 """SELECT b.sha FROM builds b WHERE b.config = ? AND b.commit_pos >= ? AND EXISTS
                    (SELECT 1 FROM runs u WHERE u.build_id = b.id AND u.kind = 'waterfall')
                    ORDER BY b.commit_pos LIMIT 1""")
        row = self._db.execute(query, (config, pos)).fetchone()
        return None if row is None else row["sha"]

    def _batch_tips(self, config: str, shas: Sequence[str]) -> set[str]:
        """The commits the waterfall measured: batch tips, whose builds exist (3.6: bisect at batch granularity)."""
        if not shas:
            return set()
        marks = ",".join("?" * len(shas))
        rows = self._db.execute(
            f"""SELECT DISTINCT b.sha FROM builds b JOIN runs u ON u.build_id = b.id
                WHERE b.config = ? AND u.kind = 'waterfall' AND b.sha IN ({marks})""", (config, *shas)).fetchall()
        return {row["sha"] for row in rows}

    def _stored(self, sha: str, config: str) -> bool:
        record = self._ledger.get(sha, config)
        return record is not None and record.status == "ok"

    def _start(self, group: sqlite3.Row) -> int | str:
        """The new bisect's job id, or why the group cannot start yet."""
        alert = self._top_alert(group["id"])
        if alert is None:
            return "no regression alert with medians"
        config = alert["build_config"]
        good = self._waterfall_sha(config, group["start_pos"], before=True)
        bad = self._waterfall_sha(config, group["end_pos"], before=False)
        if good is None or bad is None:
            return f"no waterfall point {'before' if good is None else 'at the end of'} the range"
        listed = self._first_parent(good, bad)
        if listed is None:
            return f"first-parent commits {good[:12]}..{bad[:12]} are not known yet"
        shas = [good, *listed]
        if len(shas) < 2 or shas[-1] != bad or len(set(shas)) != len(shas):
            return f"first-parent commits {good[:12]}..{bad[:12]} do not end at {bad[:12]}"
        tips = self._batch_tips(config, shas)
        commits = tuple(pinpoint.Commit(sha, batch_tip=sha in tips, stored_build=self._stored(sha, config))
                        for sha in shas)
        job = pinpoint.Job(kind=pinpoint.BISECT, mode=pinpoint.PERFORMANCE, story=alert["story"],
                           metric=alert["metric"], host_class=alert["host_class"], good=commits[0].change,
                           bad=commits[-1].change, magnitude=alert["median_after"] - alert["median_before"],
                           better=alert["better"], commits=commits)
        params = json.dumps({"role": "bisect", "job": job_doc(job, config=config)}, sort_keys=True)

        def write() -> int:
            current = self._db.execute("SELECT state FROM alert_groups WHERE id = ?", (group["id"],)).fetchone()
            if current is None or current["state"] not in START_STATES or self._db.execute(
                    "SELECT 1 FROM jobs WHERE kind = ? AND alert_group_id = ?", (JOB_KIND, group["id"])).fetchone():
                return 0  # another labd thread started it, or a sheriff closed the group meanwhile
            now = self._now()
            job_id = self._db.execute(
                """INSERT INTO jobs (kind, state, story, host_class, base_sha, head_sha, alert_group_id, params_json,
                                     created_at, updated_at) VALUES (?, 'running', ?, ?, ?, ?, ?, ?, ?, ?)""",
                (JOB_KIND, job.story, job.host_class, good, bad, group["id"], params, now, now)).lastrowid
            # catapult alert_group_workflow.py triages an untriaged group and bisects it; the legal path is
            # new -> triaged -> bisecting (sheriff.py TRANSITIONS), so an automatic start records both moves.
            moves = ([("new", "triaged", "monitored regression; automatic bisect")] if current["state"] == "new"
                     else [])
            moves.append(("triaged", "bisecting",
                          f"bisect job {job_id}: {job.story} {job.metric} on {job.host_class}, "
                          f"{len(commits) - 1} commits {good[:12]}..{bad[:12]}, delta {job.magnitude:+.4g}"))
            for from_state, to_state, reason in moves:
                self._history(group["id"], from_state, to_state, reason, now)
            self._db.execute("UPDATE alert_groups SET state = 'bisecting', updated_at = ? WHERE id = ?",
                             (now, group["id"]))
            return job_id

        job_id = self._write(write)
        if not job_id:
            return "started elsewhere or closed"
        self._save(Checkpoint(job_id))
        return job_id

    def _history(self, group_id: int, from_state: str, to_state: str, reason: str, now: str) -> None:
        self._db.execute(
            "INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) VALUES (?, ?, ?, ?, ?, ?)",
            (group_id, from_state, to_state, ACTOR, reason, now))

    # --- one job ---

    def _path(self, job_id: int) -> Path:
        return self._state_dir / f"bisect-{job_id}.json"

    def _load(self, job_id: int) -> Checkpoint:
        """The job's checkpoint; none yet (a crash right after the job row) is an empty journal: nothing was sent."""
        try:
            return Checkpoint.from_document(json.loads(self._path(job_id).read_text(encoding="utf-8")))
        except FileNotFoundError:
            return Checkpoint(job_id)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise ExecError(f"{self._path(job_id)}: {error}") from error

    def _save(self, checkpoint: Checkpoint) -> None:
        self._state_dir.mkdir(parents=True, exist_ok=True)
        handle, temp = tempfile.mkstemp(dir=self._state_dir, prefix=".bisect-", suffix=".json")
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as out:
                json.dump(checkpoint.to_document(), out, sort_keys=True)
                out.flush()
                os.fsync(out.fileno())
            os.replace(temp, self._path(checkpoint.job_id))
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def _advance(self, row: sqlite3.Row, checkpoint: Checkpoint, hosts: Sequence[LabHost], taken: set[str],
                 report: TickReport) -> None:
        params = json.loads(row["params_json"])["job"]
        job, config = job_of(params), params["config"]
        state = replay(job, checkpoint.events)
        if state.result is None:
            seen = len(checkpoint.events)
            self._collect(job, config, checkpoint, taken, report)
            for event in checkpoint.events[seen:]:
                record(state, event)
            self._save(checkpoint)
            while checkpoint.dirty() and state.result is None:
                actions = pinpoint.step(state)
                checkpoint.events.append({"t": "step", "actions": [action_doc(a) for a in actions]})
                seen = len(checkpoint.events)
                for action in actions:
                    if not isinstance(action, pinpoint.Done):
                        self._add_action(checkpoint, action, config)
                for event in checkpoint.events[seen:]:
                    record(state, event)
                self._save(checkpoint)
        if state.result is not None:
            self._finish(row, state.result)
            report.finished.append(row["id"])
            return
        self._submit(row, job, config, checkpoint, hosts, taken, report)

    def _add_action(self, checkpoint: Checkpoint, action, config: str) -> None:
        """A new action; a Build the ledger already answers is recorded at once, so the next step sees it."""
        seq = len(checkpoint.actions)
        if isinstance(action, pinpoint.Build):
            entry = {"seq": seq, "type": "build", "change": change_doc(action.change), "status": PENDING, "tries": 0}
            record = self._ledger.get(action.change.sha, config)
            if record is not None:
                entry["status"] = DONE
                checkpoint.events.append({"t": "build", "change": entry["change"], "ok": record.status == "ok"})
        else:
            entry = {"seq": seq, "type": "run", "change": change_doc(action.change), "start": action.start,
                     "count": action.count, "status": PENDING, "tries": 0}
        checkpoint.actions.append(entry)

    @staticmethod
    def _key(checkpoint: Checkpoint, entry: Mapping) -> str:
        return f"perf-lab-pinpoint:{checkpoint.job_id}:{entry['seq']}:{entry['tries']}"

    # --- reading answers ---

    def _collect(self, job, config: str, checkpoint: Checkpoint, taken: set[str], report: TickReport) -> None:
        for entry in checkpoint.actions:
            if entry["status"] != SUBMITTED:
                continue
            if entry["type"] == "build":
                self._collect_build(config, checkpoint, entry)
            else:
                self._collect_run(job, checkpoint, entry, taken, report)

    def _collect_build(self, config: str, checkpoint: Checkpoint, entry: dict) -> None:
        change = change_of(entry["change"])
        record = self._ledger.get(change.sha, config)
        if record is None:  # another builder may record it before ours finishes; the ledger is the answer
            if not self._controller.status(entry["controller_id"]).finished:
                return
            if entry["tries"] < BUILD_RETRIES:
                entry.update(status=PENDING, tries=entry["tries"] + 1, controller_id=None)
                return
        entry["status"] = DONE
        checkpoint.events.append({"t": "build", "change": entry["change"],
                                  "ok": record is not None and record.status == "ok"})

    def _collect_run(self, job, checkpoint: Checkpoint, entry: dict, taken: set[str], report: TickReport) -> None:
        status = self._controller.status(entry["controller_id"])
        if not status.finished:
            return
        entry["ended"] = True  # the host is free again even while labd's ingest is due
        taken.discard(entry["host"])
        change = change_of(entry["change"])
        indexes = range(entry["start"], entry["start"] + entry["count"])
        if status.not_measurable:
            attempts = [pinpoint.Attempt(change, i, measurable=False) for i in indexes]
        elif status.exit_code in MEASURED_EXITS:
            values = self._results(entry["row_id"], job, entry["count"], complete=status.exit_code == 0)
            if values is None:
                return  # labd has not ingested the job's artifact yet
            attempts = [pinpoint.Attempt(change, i, values=v, failed=not v) for i, v in zip(indexes, values)]
        elif entry["tries"] < RUN_RETRIES:
            report.problems.append(f"bisect {checkpoint.job_id}: story job {entry['controller_id']} on {entry['host']} "
                                   f"exited {status.exit_code}; running it again")
            self._set_row_state(entry["row_id"], "failed")
            entry.update(status=PENDING, tries=entry["tries"] + 1, controller_id=None, row_id=None, host=None,
                         ended=False)
            return
        else:
            attempts = [pinpoint.Attempt(change, i, failed=True) for i in indexes]
        self._set_row_state(entry["row_id"], "done")
        entry["status"] = DONE
        checkpoint.events.extend({"t": "attempt", "attempt": attempt_doc(a)} for a in attempts)

    def _results(self, row_id: int, job, count: int, *, complete: bool) -> list[tuple[float, ...]] | None:
        """The metric's samples per repeat of a story job, `count` long (empty: a failed repeat), or None while
        labd's ingest is still due: a full job is ready at `count` runs, a partial one when its row is ingested."""
        row = self._db.execute("SELECT state FROM jobs WHERE id = ?", (row_id,)).fetchone()
        runs = self._db.execute(
            """SELECT u.id, (SELECT r.samples_json FROM results r JOIN series s ON s.id = r.series_id
                             WHERE r.run_id = u.id AND s.metric = ? ORDER BY r.id LIMIT 1) AS samples
               FROM runs u WHERE u.job_id = ? AND u.story = ? ORDER BY u.started_at, u.id""",
            (job.metric, row_id, job.story)).fetchall()
        if row is None:
            raise ExecError(f"story job row {row_id} is gone")
        if row["state"] != "ingested" and not (complete and len(runs) >= count):
            return None
        values = [tuple(float(v) for v in json.loads(run["samples"])) if run["samples"] else () for run in runs]
        return (values + [()] * count)[:count]

    def _update(self, sql: str, args: Sequence[object]) -> None:
        def write() -> None:
            self._db.execute(sql, tuple(args))

        self._write(write)

    def _set_row_state(self, row_id: int | None, state: str) -> None:
        if row_id is not None:
            self._update("UPDATE jobs SET state = ?, updated_at = ? WHERE id = ? AND state != 'ingested'",
                         (state, self._now(), row_id))

    # --- sending requests ---

    def _submit(self, row: sqlite3.Row, job, config: str, checkpoint: Checkpoint, hosts: Sequence[LabHost],
                taken: set[str], report: TickReport) -> None:
        for entry in checkpoint.actions:
            if entry["status"] not in (PENDING, SUBMITTING):
                continue
            if entry["type"] == "build":
                self._submit_build(config, checkpoint, entry, report)
            else:
                self._submit_run(row, job, config, checkpoint, entry, hosts, taken, report)

    def _submit_build(self, config: str, checkpoint: Checkpoint, entry: dict, report: TickReport) -> None:
        key = self._key(checkpoint, entry)
        if entry["status"] == PENDING:
            entry["status"] = SUBMITTING
            self._save(checkpoint)  # the key is on disk before the request, so a restart asks for it first
        controller_id = self._controller.find(key)
        if controller_id is None:
            sha = change_of(entry["change"]).sha
            controller_id = self._controller.submit_build(BuildRequest(key, sha, config))
            report.builds_requested += 1
        entry.update(status=SUBMITTED, controller_id=controller_id)
        self._save(checkpoint)

    def _submit_run(self, row: sqlite3.Row, job, config: str, checkpoint: Checkpoint, entry: dict,
                    hosts: Sequence[LabHost], taken: set[str], report: TickReport) -> None:
        key = self._key(checkpoint, entry)
        change = change_of(entry["change"])
        controller_id = self._controller.find(key) if entry["status"] == SUBMITTING else None
        if controller_id is None:
            record = self._ledger.get(change.sha, config)
            if record is None or record.status != "ok":
                report.problems.append(f"bisect {checkpoint.job_id}: {change.sha[:12]} ({config}) has no ok build "
                                       "in the ledger; its story job waits")
                return
            seconds = self._repeat_seconds(job.story)
            host = pick_host(hosts, job.host_class, now=self._clock(), taken=taken, prefer=checkpoint.host,
                             seconds=None if seconds is None else seconds * entry["count"])
            if host is None:
                return
            entry.update(status=SUBMITTING, host=host.name, row_id=self._story_row(row, entry, key, change, host))
            taken.add(host.name)
            self._save(checkpoint)
            controller_id = self._controller.submit_story(StoryRequest(
                key=key, host=host.name, story=job.story, sha=change.sha, config=config,
                digest=f"sha256:{record.digest}", repeats=entry["count"], lab_job_id=entry["row_id"]))
            report.stories_requested += 1
        taken.add(entry["host"])
        self._update("UPDATE jobs SET controller_job_id = ?, state = 'running', updated_at = ? WHERE id = ?",
                     (controller_id, self._now(), entry["row_id"]))
        entry.update(status=SUBMITTED, controller_id=controller_id)
        checkpoint.host = entry["host"]
        self._save(checkpoint)

    def _story_row(self, bisect: sqlite3.Row, entry: Mapping, key: str, change, host: LabHost) -> int:
        """The story job's row (one per request key), which the ingest links its runs to."""
        params = json.dumps({"role": "story", "bisect_job": bisect["id"], "key": key, "start": entry["start"],
                             "count": entry["count"], "host": host.name}, sort_keys=True)

        def write() -> int:
            existing = self._db.execute(
                """SELECT id FROM jobs WHERE kind = ? AND alert_group_id IS NULL
                   AND json_extract(params_json, '$.key') = ?""", (JOB_KIND, key)).fetchone()
            now = self._now()
            if existing is not None:
                self._db.execute("UPDATE jobs SET params_json = ?, updated_at = ? WHERE id = ?",
                                 (params, now, existing["id"]))
                return existing["id"]
            return self._db.execute(
                """INSERT INTO jobs (kind, state, story, host_class, base_sha, head_sha, params_json, created_at,
                                     updated_at) VALUES (?, 'queued', ?, ?, ?, ?, ?, ?, ?)""",
                (JOB_KIND, bisect["story"], host.host_class, change.sha, change.sha, params, now, now)).lastrowid

        return self._write(write)

    # --- the end ---

    def _finish(self, row: sqlite3.Row, result) -> None:
        """Stores the result; a group still bisecting moves to culprit (unverified) or back to triaged."""
        culprit = max(result.culprits, default=None,
                      key=lambda c: abs((c.comparison.mean_change or 0.0) - (c.comparison.mean_parent or 0.0)))

        def write() -> None:
            current = self._db.execute("SELECT state FROM jobs WHERE id = ?", (row["id"],)).fetchone()
            if current["state"] == "done":
                return
            now = self._now()
            self._db.execute("UPDATE jobs SET state = 'done', result_json = ?, updated_at = ? WHERE id = ?",
                             (result.to_json(), now, row["id"]))
            group = self._db.execute("SELECT * FROM alert_groups WHERE id = ?", (row["alert_group_id"],)).fetchone()
            if group["state"] != "bisecting":
                return  # a sheriff moved it meanwhile (invalid, lab-drift); the job's result stays for the record
            if culprit is not None:
                others = len(result.culprits) - 1
                reason = (f"bisect job {row['id']}: culprit {culprit.change.sha[:12]} "
                          f"({len(culprit.commits)} commit{'s' if len(culprit.commits) != 1 else ''}, "
                          f"{culprit.comparison.verdict} p={culprit.comparison.p_value:.4g})"
                          + (f", {others} more" if others else "") + "; unverified until verify.py")
                self._db.execute("UPDATE alert_groups SET state = 'culprit', culprit_sha = ?, culprit_verified = 0, "
                                 "updated_at = ? WHERE id = ?", (culprit.change.sha, now, group["id"]))
                self._history(group["id"], "bisecting", "culprit", reason, now)
            else:
                skipped = f", {len(result.skipped)} commits skipped" if result.skipped else ""
                self._db.execute("UPDATE alert_groups SET state = 'triaged', updated_at = ? WHERE id = ?",
                                 (now, group["id"]))
                self._history(group["id"], "bisecting", "triaged",
                              f"bisect job {row['id']}: {result.outcome}, no culprit{skipped}", now)

        self._write(write)


def catalog_repeat_seconds(root: Path | str = HERE.parents[1]) -> Callable[[str], float | None]:
    """repeat_seconds from the story catalog: a story's `seconds` (one run) over its `repeats`."""
    catalog = _load_sibling("perf_lab_catalog", "catalog.py").load_catalog(Path(root))
    seconds = {s.id: s.seconds / max(s.repeats, 1) for s in catalog.stories if s.seconds > 0}
    return seconds.get
