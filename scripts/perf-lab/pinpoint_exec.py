#!/usr/bin/env python3
"""Pinpoint's executor: carries out the pure core's actions (pinpoint.py, task 015) on the lab.

labd (task 012) runs one executor tick before each scheduler plan (scheduler.py, task 011):

    report = executor.tick()
    driver.tick(hosts, builds, submit=submit, pinpoint=executor.pinpoint_work())

and its submit callback starts each plan job whose `work_id` names a story request with
`executor.story_request(work_id)` (scripts/measure/perf-lab.sh, task 008, on the plan job's host). The executor never
picks a host and never sends a request to the controller: the scheduler alone places work (one job per host, the
T0 > bisect > verify > T1 order, borrowing a waterfall host only far from its next T0) and orders builds (batch tips,
then tiers, then Pinpoint). One tick:

1. starts a bisect for each new monitored alert group (state new or triaged, no bisect job yet), pinned to the
   group's largest regression (alerts.group_alerts): its story, metric, build config and host class, over the
   commits between the range ends that the group's issue links (alerts.waterfall_sha). Magnitude = the alert's
   delta (median_after - median_before, in the metric's unit); pinpoint.py turns it into IQRs (3.6). A
   harness-broken group (harness_alerts.py, task 214) gets a functional-mode bisect of its story's pass/fail rate
   instead (catapult job_state.py's comparison_mode `functional`), from the story's newest stored waterfall pass
   before the range (harness_alerts.functional_target). The group
   moves new -> triaged -> bisecting through sheriff.Sheriff.apply_state with ACTOR as the session, in the same
   transaction as the job row, so the sheriff's transitions, reasons and claims hold for the executor too.
2. for each running bisect: stops it when its group is no longer bisecting (catapult cancels a Pinpoint job whose
   alert was triaged away), else reads the answers to its outstanding actions, steps the core until it waits and
   persists the job state:
   - Build(change): the build ledger (builds.py, task 009) answers it. Until it does, the Build is published as
     `PinpointWork(build_only=True)`, so the scheduler requests (sha, config) once. Only a `failed` ledger record
     makes the commit unbuildable; a build with no record stays outstanding and is reported after BUILD_WAIT,
     because a builder that recorded nothing failed for a reason the commit did not cause.
   - Run(change, start, count): one story job of `--repeats count`, published as PinpointWork with a key that
     changes per try (`perf-lab-pinpoint:<job>:<action>:<try>`, the work id) and the job's last host as
     `prefer_host`. `Controller.find(key)` reports the controller job once labd started it. When it ends, the
     executor ingests its artifact (ControllerJob.artifact) with ingest.ingest_paths(kind="bisect",
     job_id=<the story job's row>) and reads the runs back by that id: repeat i is the i-th run by start time; a
     repeat with no run, or a run without the metric, is a failed attempt. A job that measured nothing (another
     exit code, an exit-0 artifact that stored no run, or no artifact RESULT_WAIT after the end) is run again with
     a new key, at most RUN_RETRIES more times, then its attempts are failed.
   - Done(result): stores the result on the job and moves the group: a culprit -> `culprit` (unverified;
     verify.py, task 017, decides), no culprit -> back to `triaged` with the outcome as the reason. A move the
     sheriff rules refuse (a claim) rolls the whole write back; the job stays running and is tried next tick.

Restart. Catapult stores a Pinpoint job after every pass of Job.Run (dashboard/dashboard/pinpoint/models/job.py:
explore, schedule, put()). Here the job state is a journal in STATE_DIR/bisect-<id>.json, replaced atomically after
every step: every step() call with the actions it returned, and every result in the order it was recorded. A restart
replays the journal through a fresh pinpoint.JobState; step() is deterministic, so the replay reproduces the same
state, and a replayed step that returns other actions is refused. A story job's key is on disk before it is
published, so a job the controller started before a crash is found by its key, never started again.

Failures stay with their job: a controller, ledger, ingest, journal or core error becomes an ExecError on that job's
line of TickReport.problems, and every other job still advances in the same tick.

Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
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
from datetime import datetime, timedelta
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


store = _load_sibling("perf_lab_store", "store.py")
pinpoint = _load_sibling("perf_lab_pinpoint", "pinpoint.py")
builds = _load_sibling("perf_lab_builds", "builds.py")
ingest = _load_sibling("perf_lab_ingest", "ingest.py")
alerts = _load_sibling("perf_lab_alerts", "alerts.py")
sheriff = _load_sibling("perf_lab_sheriff", "sheriff.py")
harness_alerts = _load_sibling("perf_lab_harness_alerts", "harness_alerts.py")
scheduler = _load_sibling("perf_lab_scheduler", "scheduler.py")

CHECKPOINT_SCHEMA = "cmux-perf-pinpoint-exec/v2"
JOB_KIND = "bisect"
ACTOR = "perf-lab-pinpoint"  # the sheriff session the executor's group moves are recorded under
RUN_RETRIES = 3  # a story job that measured nothing (env-invalid, no artifact, a signal) is run again this often
RESULT_WAIT = timedelta(minutes=30)  # a finished story job's artifact must reach the executor within this
BUILD_WAIT = timedelta(hours=2)  # a requested build with no ledger record after this is reported each tick
UNKNOWN_RUN_SECONDS = 6 * 3600  # a story job of unknown length borrows only a waterfall host with no T0 due
START_STATES = ("new", "triaged")
# run_story.py exit codes (task 008): 0 every repeat wrote results, 1 a repeat failed; anything else measured nothing.
MEASURED_EXITS = (0, 1)

# Action states: PENDING (a story job without its row yet), QUEUED (published to the scheduler),
# SUBMITTED (the controller has it), DONE (its answer is in the journal).
PENDING, QUEUED, SUBMITTED, DONE = "pending", "queued", "submitted", "done"


class ExecError(RuntimeError):
    """A bisect the executor cannot advance this tick: a journal that does not replay, a store it cannot use, or a
    failure of one of its seams. It is reported on the job's line; other jobs go on."""


class ControllerError(ExecError):
    """The controller client failed (network, a refused request, an unknown id)."""


# ---------- seams ----------

@dataclass(frozen=True)
class StoryRequest:
    """What labd's submit callback starts for a plan job whose work_id is `key` (perf-lab.sh, task 008)."""

    key: str
    story: str
    sha: str
    config: str
    digest: str  # "sha256:<64 hex>", perf-lab.sh --digest
    repeats: int
    lab_job_id: int  # the story job's row in the lab store; its runs are ingested with Run.job_id = this


@dataclass(frozen=True)
class ControllerJob:
    """finished: the job ended; exit_code: the entry's exit status (None for a job that never ran).
    not_measurable: the build lacks a capability the story needs (task 211's debug.capabilities check).
    host: the lab host it runs on. artifact: the job's result folder (`*.ndjson`) on labd's disk, once fetched."""

    finished: bool
    exit_code: int | None = None
    not_measurable: bool = False
    host: str | None = None
    artifact: Path | None = None


class Controller(Protocol):
    def find(self, key: str) -> str | None: ...

    def status(self, controller_job_id: str) -> ControllerJob: ...

    def cancel(self, controller_job_id: str) -> None: ...


class Ledger(Protocol):
    def get(self, sha: str, config: str): ...  # builds.BuildRecord | None


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
    """A bisect's persisted progress: the journal (steps and results, in order) and its actions."""

    job_id: int
    events: list[dict] = field(default_factory=list)
    actions: list[dict] = field(default_factory=list)
    host: str | None = None  # the host its last story job ran on; the next one prefers it

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
    try:
        if event["t"] == "build":
            state.record_build(change_of(event["change"]), bool(event["ok"]))
        elif event["t"] == "attempt":
            state.record_attempt(attempt_of(event["attempt"]))
        else:
            raise ExecError(f"journal event kind {event['t']!r} is not a result")
    except pinpoint.PinpointError as error:
        raise ExecError(f"journal result {dict(event)}: {error}") from error


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
    cancelled: list[int] = field(default_factory=list)
    work: int = 0  # PinpointWork items published for the next plan
    problems: list[str] = field(default_factory=list)


FirstParent = Callable[[str, str], Sequence[str] | None]


def _seam(what: str, call: Callable, *args, error: type[ExecError] = ExecError):
    """Calls an injected client. Its own failures (network, a refused request, a bad file) become a typed error
    naming the call, so they stop only the job that made it."""
    try:
        return call(*args)
    except ExecError:
        raise
    except Exception as failure:  # the client's exception types are its own; this is the typed boundary
        raise error(f"{what}: {type(failure).__name__}: {failure}") from failure


class Executor:
    """Drives every running bisect of a lab store at the current schema (store.MIGRATIONS).

    first_parent(good, bad): the first-parent commits after good up to bad, oldest first (None: unknown now).
    commit_positions: ingest.CommitPositions for the story jobs' commits (labd's GitCommitPositions).
    repeat_seconds(story): one repeat's wall time, or None (UNKNOWN_RUN_SECONDS per job).
    One store.Store connection, owned by the opening thread; every write is the store's BEGIN IMMEDIATE."""

    def __init__(self, db_path: Path | str, state_dir: Path | str, *, controller: Controller, ledger: Ledger,
                 first_parent: FirstParent, commit_positions: Callable[[str], object],
                 repeat_seconds: Callable[[str], float | None] = lambda story: None,
                 clock: Callable[[], datetime] = store.utc_now) -> None:
        self._controller = controller
        self._ledger = ledger
        self._first_parent = first_parent
        self._commit_positions = commit_positions
        self._repeat_seconds = repeat_seconds
        self._clock = clock
        self._state_dir = Path(state_dir)
        self._lab = store.Store(db_path, clock=clock)
        version, known = self._lab.schema_version(), len(store.MIGRATIONS)
        if version != known:
            self._lab.close()
            raise ExecError(f"{db_path}: schema {version}, this checkout needs {known} (labd migrates the store)")
        self._db = self._lab._db
        self._sheriff = sheriff.Sheriff(self._lab, session=ACTOR, lead_session=None, clock=clock)
        self._work: tuple = ()
        self._requests: dict[str, StoryRequest] = {}

    def close(self) -> None:
        self._lab.close()

    def _write(self, statements: Callable[[], object]) -> object:
        return self._lab._write(statements)

    def _now(self) -> str:
        return store._stamp(self._clock())

    # --- what labd hands the scheduler ---

    def pinpoint_work(self) -> tuple:
        """The last tick's outstanding Build and Run actions as scheduler.PinpointWork, in job order."""
        return self._work

    def story_request(self, work_id: str) -> StoryRequest | None:
        """The story job a plan job of this work id starts; None for a build-only or unknown id."""
        return self._requests.get(work_id)

    # --- tick ---

    def tick(self) -> TickReport:
        report = TickReport()
        self.start_bisects(report)
        rows = self._db.execute(
            """SELECT j.*, g.state AS group_state FROM jobs j JOIN alert_groups g ON g.id = j.alert_group_id
               WHERE j.kind = ? AND j.state = 'running' ORDER BY j.id""", (JOB_KIND,)).fetchall()
        work: list = []
        requests: dict[str, StoryRequest] = {}
        for row in rows:
            try:  # one job that fails holds up no other; its work waits for a tick it advances in
                checkpoint = self._advance(row, report)
                if checkpoint is not None:
                    self._publish(row, checkpoint, work, requests)
            except (ExecError, sqlite3.Error) as error:
                report.problems.append(f"bisect {row['id']}: {error}")
        self._work, self._requests = tuple(work), requests
        report.work = len(work)
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
            except (ExecError, pinpoint.PinpointError, sqlite3.Error) as error:
                report.problems.append(f"group {group['id']}: {error}")
                continue
            if isinstance(job_id, str):
                report.problems.append(f"group {group['id']}: {job_id}")
            else:
                report.started.append(job_id)
        return report.started

    def _ledger_get(self, sha: str, config: str):
        return _seam(f"build ledger {sha[:12]} ({config})", self._ledger.get, sha, config)

    def _start(self, group: sqlite3.Row) -> int | str:
        """The new bisect's job id, or why the group cannot start yet."""
        top = next(iter(alerts.group_alerts(self._lab, group["id"])), None)
        if top is not None:
            series, mode, magnitude = top.series, pinpoint.PERFORMANCE, top.median_after - top.median_before
            good = alerts.waterfall_sha(self._lab, series.build_config, group["start_pos"], before=True)
            measured = f"delta {magnitude:+.4g}"
        else:
            target = harness_alerts.functional_target(self._lab, group["id"])
            if target is None:
                return "no regression or harness-broken alert"
            if target.good is None:
                return f"no stored waterfall pass of {target.series.story} before the range"
            series, mode, magnitude, good = target.series, pinpoint.FUNCTIONAL, None, target.good
            measured = "pass/fail rate"
        config = series.build_config
        bad = alerts.waterfall_sha(self._lab, config, group["end_pos"], before=False)
        if good is None or bad is None:
            return f"no waterfall point {'before' if good is None else 'at the end of'} the range"
        listed = _seam(f"first-parent {good[:12]}..{bad[:12]}", self._first_parent, good, bad)
        if listed is None:
            return f"first-parent commits {good[:12]}..{bad[:12]} are not known yet"
        shas = [good, *listed]
        if len(shas) < 2 or shas[-1] != bad or len(set(shas)) != len(shas):
            return f"first-parent commits {good[:12]}..{bad[:12]} do not end at {bad[:12]}"
        tips = self._batch_tips(config, shas)
        commits = []
        for sha in shas:
            stored = self._ledger_get(sha, config)
            commits.append(pinpoint.Commit(sha, batch_tip=sha in tips,
                                           stored_build=stored is not None and stored.status == "ok"))
        job = pinpoint.Job(kind=pinpoint.BISECT, mode=mode, story=series.story,
                           metric=series.metric, host_class=series.host_class, good=commits[0].change,
                           bad=commits[-1].change, magnitude=magnitude,
                           better=series.better, commits=tuple(commits))
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
            # catapult alert_group_workflow.py triages an untriaged group and bisects it: new -> triaged -> bisecting.
            if current["state"] == "new":
                self._sheriff.apply_state(
                    group["id"], "triaged",
                    reason=("monitored regression" if mode == pinpoint.PERFORMANCE else "harness broken")
                    + "; automatic bisect")
            self._sheriff.apply_state(
                group["id"], "bisecting",
                reason=f"{mode} bisect job {job_id}: {job.story} {job.metric} on {job.host_class}, "
                       f"{len(commits) - 1} commits {good[:12]}..{bad[:12]}, {measured}")
            return job_id

        try:
            job_id = self._write(write)
        except sheriff.SheriffError as error:
            return f"cannot move to bisecting: {error}"
        if not job_id:
            return "started elsewhere or closed"
        self._save(Checkpoint(job_id))
        return job_id

    def _batch_tips(self, config: str, shas: Sequence[str]) -> set[str]:
        """The commits the waterfall measured: batch tips, whose builds exist (3.6: bisect at batch granularity)."""
        marks = ",".join("?" * len(shas))
        rows = self._db.execute(
            f"""SELECT DISTINCT b.sha FROM builds b JOIN runs u ON u.build_id = b.id
                WHERE b.config = ? AND u.kind = 'waterfall' AND b.sha IN ({marks})""", (config, *shas)).fetchall()
        return {row["sha"] for row in rows}

    # --- one job ---

    def _path(self, job_id: int) -> Path:
        return self._state_dir / f"bisect-{job_id}.json"

    def _load(self, job_id: int) -> Checkpoint:
        """The job's checkpoint; none yet (a crash right after the job row) is an empty journal: nothing was sent."""
        try:
            return Checkpoint.from_document(json.loads(self._path(job_id).read_text(encoding="utf-8")))
        except FileNotFoundError:
            return Checkpoint(job_id)
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise ExecError(f"{self._path(job_id)}: {error}") from error

    def _save(self, checkpoint: Checkpoint) -> None:
        try:
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
        except OSError as error:
            raise ExecError(f"{self._path(checkpoint.job_id)}: {error}") from error

    @staticmethod
    def _job(row: sqlite3.Row) -> tuple[object, str]:
        try:
            params = json.loads(row["params_json"])["job"]
            return job_of(params), params["config"]
        except (ValueError, KeyError, TypeError, pinpoint.PinpointError) as error:
            raise ExecError(f"params_json is not a bisect job: {error!r}") from error

    def _advance(self, row: sqlite3.Row, report: TickReport) -> Checkpoint | None:
        """Steps one bisect; returns its checkpoint while it runs, None once it finished or was cancelled."""
        job, config = self._job(row)
        checkpoint = self._load(row["id"])
        state = replay(job, checkpoint.events)
        if state.result is None and row["group_state"] != "bisecting":
            self._cancel(row, checkpoint, report)
            return None
        if state.result is None:
            seen = len(checkpoint.events)
            self._collect(job, config, checkpoint, report)
            for event in checkpoint.events[seen:]:
                record(state, event)
            self._save(checkpoint)
            while checkpoint.dirty() and state.result is None:
                try:
                    actions = pinpoint.step(state)
                except pinpoint.PinpointError as error:
                    raise ExecError(f"step(): {error}") from error
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
            return None
        self._prepare(row, job, checkpoint)
        return checkpoint

    def _add_action(self, checkpoint: Checkpoint, action, config: str) -> None:
        """A new action; a Build the ledger already answers is recorded at once, so the next step sees it."""
        seq = len(checkpoint.actions)
        if isinstance(action, pinpoint.Build):
            entry = {"seq": seq, "type": "build", "change": change_doc(action.change), "status": QUEUED,
                     "tries": 0, "queued_at": self._now()}
            answer = self._ledger_get(action.change.sha, config)
            if answer is not None:
                entry["status"] = DONE
                checkpoint.events.append({"t": "build", "change": entry["change"], "ok": answer.status == "ok"})
        else:
            entry = {"seq": seq, "type": "run", "change": change_doc(action.change), "start": action.start,
                     "count": action.count, "status": PENDING, "tries": 0}
        checkpoint.actions.append(entry)

    @staticmethod
    def _key(checkpoint: Checkpoint, entry: Mapping) -> str:
        return f"perf-lab-pinpoint:{checkpoint.job_id}:{entry['seq']}:{entry['tries']}"

    # --- reading answers ---

    def _collect(self, job, config: str, checkpoint: Checkpoint, report: TickReport) -> None:
        for entry in checkpoint.actions:
            if entry["type"] == "build" and entry["status"] == QUEUED:
                self._collect_build(config, checkpoint, entry, report)
            elif entry["type"] == "run" and entry["status"] in (QUEUED, SUBMITTED):
                self._collect_run(job, checkpoint, entry, report)

    def _collect_build(self, config: str, checkpoint: Checkpoint, entry: dict, report: TickReport) -> None:
        sha = change_of(entry["change"]).sha
        answer = self._ledger_get(sha, config)
        if answer is None:
            waited = self._clock() - datetime.fromisoformat(entry["queued_at"])
            if waited > BUILD_WAIT:
                report.problems.append(
                    f"bisect {checkpoint.job_id}: {sha[:12]} ({config}) has no build ledger record after "
                    f"{waited.total_seconds() / 3600:.1f} h; a builder that records nothing needs the operator")
            return
        entry["status"] = DONE
        checkpoint.events.append({"t": "build", "change": entry["change"], "ok": answer.status == "ok"})

    def _collect_run(self, job, checkpoint: Checkpoint, entry: dict, report: TickReport) -> None:
        if entry["status"] == QUEUED:
            controller_id = _seam(f"controller find {self._key(checkpoint, entry)}", self._controller.find,
                                  self._key(checkpoint, entry), error=ControllerError)
            if controller_id is None:
                return  # the scheduler has not placed it yet
            self._update("UPDATE jobs SET controller_job_id = ?, state = 'running', updated_at = ? WHERE id = ?",
                         (controller_id, self._now(), entry["row_id"]))
            entry.update(status=SUBMITTED, controller_id=controller_id)
        status = _seam(f"controller status {entry['controller_id']}", self._controller.status,
                       entry["controller_id"], error=ControllerError)
        if status.host:
            entry["host"] = checkpoint.host = status.host
        if not status.finished:
            return
        change = change_of(entry["change"])
        indexes = range(entry["start"], entry["start"] + entry["count"])
        if status.not_measurable:
            attempts = [pinpoint.Attempt(change, i, measurable=False) for i in indexes]
        elif status.exit_code not in MEASURED_EXITS:
            self._failed_try(checkpoint, entry, f"exited {status.exit_code}", report)
            return
        elif status.artifact is None:
            ended = entry.setdefault("ended_at", self._now())
            if self._clock() - datetime.fromisoformat(ended) < RESULT_WAIT:
                return  # the controller has not handed over the artifact yet
            self._failed_try(checkpoint, entry, f"no artifact {RESULT_WAIT} after it ended", report)
            return
        else:
            values = self._ingest(job, checkpoint, entry, status, report)
            if values is None:
                self._failed_try(checkpoint, entry, f"exited 0 but its artifact stored no run of {job.story}",
                                 report)
                return
            attempts = [pinpoint.Attempt(change, i, values=v, failed=not v) for i, v in zip(indexes, values)]
        self._set_row_state(entry["row_id"], "done")
        entry["status"] = DONE
        checkpoint.events.extend({"t": "attempt", "attempt": attempt_doc(a)} for a in attempts)

    def _failed_try(self, checkpoint: Checkpoint, entry: dict, why: str, report: TickReport) -> None:
        """A story job that measured nothing: run it again under a new key, or fail its attempts after RUN_RETRIES."""
        self._set_row_state(entry["row_id"], "failed")
        retry = entry["tries"] < RUN_RETRIES
        report.problems.append(f"bisect {checkpoint.job_id}: story job {entry['controller_id']} on {entry.get('host')} "
                               f"{why}; " + ("running it again" if retry else "its attempts failed"))
        if retry:
            entry.update(status=PENDING, tries=entry["tries"] + 1, controller_id=None, row_id=None)
            entry.pop("ended_at", None)
            return
        change = change_of(entry["change"])
        entry["status"] = DONE
        checkpoint.events.extend({"t": "attempt", "attempt": attempt_doc(pinpoint.Attempt(change, i, failed=True))}
                                 for i in range(entry["start"], entry["start"] + entry["count"]))

    def _ingest(self, job, checkpoint: Checkpoint, entry: dict, status: ControllerJob,
                report: TickReport) -> list[tuple[float, ...]] | None:
        """Ingests a finished story job's artifact linked to its row; the metric's samples per repeat, `count` long
        (empty: a failed repeat), or None when an exit-0 job stored no run."""
        try:
            stored = ingest.ingest_paths(self._lab, [status.artifact], commit_positions=self._commit_positions,
                                         host_name=entry.get("host"), kind=JOB_KIND, job_id=entry["row_id"])
        except ingest.IngestError as error:
            raise ExecError(f"ingest of {status.artifact}: {error}") from error
        for rejection in stored.rejected:
            report.problems.append(f"bisect {checkpoint.job_id}: ingest rejected {rejection.line()}")
        runs = self._db.execute(
            """SELECT u.id, (SELECT r.samples_json FROM results r JOIN series s ON s.id = r.series_id
                             WHERE r.run_id = u.id AND s.metric = ? ORDER BY r.id LIMIT 1) AS samples
               FROM runs u WHERE u.job_id = ? AND u.story = ? ORDER BY u.started_at, u.id""",
            (job.metric, entry["row_id"], job.story)).fetchall()
        if not runs and status.exit_code == 0:
            return None
        values = [tuple(float(v) for v in json.loads(run["samples"])) if run["samples"] else () for run in runs]
        return (values + [()] * entry["count"])[:entry["count"]]

    def _update(self, sql: str, args: Sequence[object]) -> None:
        self._write(lambda: self._db.execute(sql, tuple(args)))

    def _set_row_state(self, row_id: int | None, state: str) -> None:
        if row_id is not None:
            self._update("UPDATE jobs SET state = ?, updated_at = ? WHERE id = ?", (state, self._now(), row_id))

    # --- publishing work ---

    def _prepare(self, row: sqlite3.Row, job, checkpoint: Checkpoint) -> None:
        """Gives each new story job its row (the ingest links its runs to it) and queues it under its key."""
        changed = False
        for entry in checkpoint.actions:
            if entry["type"] == "run" and entry["status"] == PENDING:
                key = self._key(checkpoint, entry)
                entry.update(status=QUEUED, row_id=self._story_row(row, job, entry, key))
                changed = True
        if changed:
            self._save(checkpoint)

    def _story_row(self, bisect: sqlite3.Row, job, entry: Mapping, key: str) -> int:
        """The story job's row, one per key."""
        sha = change_of(entry["change"]).sha
        params = json.dumps({"role": "story", "bisect_job": bisect["id"], "key": key, "start": entry["start"],
                             "count": entry["count"]}, sort_keys=True)

        def write() -> int:
            existing = self._db.execute(
                """SELECT id FROM jobs WHERE kind = ? AND alert_group_id IS NULL
                   AND json_extract(params_json, '$.key') = ?""", (JOB_KIND, key)).fetchone()
            if existing is not None:
                return existing["id"]
            now = self._now()
            return self._db.execute(
                """INSERT INTO jobs (kind, state, story, host_class, base_sha, head_sha, params_json, created_at,
                                     updated_at) VALUES (?, 'queued', ?, ?, ?, ?, ?, ?, ?)""",
                (JOB_KIND, job.story, job.host_class, sha, sha, params, now, now)).lastrowid

        return self._write(write)

    def _publish(self, row: sqlite3.Row, checkpoint: Checkpoint, work: list, requests: dict) -> None:
        """The job's queued actions as scheduler.PinpointWork; a Run's story request is kept for labd's submit."""
        job, config = self._job(row)
        for entry in checkpoint.actions:
            if entry["status"] != QUEUED:
                continue
            key = self._key(checkpoint, entry)
            sha = change_of(entry["change"]).sha
            if entry["type"] == "build":
                work.append(scheduler.PinpointWork(id=key, kind=scheduler.BISECT, host_class=job.host_class,
                                                   story=job.story, seconds=0, builds=((sha, config),),
                                                   build_only=True))
                continue
            answer = self._ledger_get(sha, config)
            if answer is None or answer.status != "ok":
                raise ExecError(f"{sha[:12]} ({config}) has a story job but no ok build in the ledger")
            each = self._repeat_seconds(job.story)
            seconds = UNKNOWN_RUN_SECONDS if each is None else math.ceil(each * entry["count"])
            work.append(scheduler.PinpointWork(id=key, kind=scheduler.BISECT, host_class=job.host_class,
                                               story=job.story, seconds=seconds, builds=((sha, config),),
                                               prefer_host=checkpoint.host))
            requests[key] = StoryRequest(key=key, story=job.story, sha=sha, config=config,
                                         digest=f"sha256:{answer.digest}", repeats=entry["count"],
                                         lab_job_id=entry["row_id"])

    # --- the end ---

    def _cancel(self, row: sqlite3.Row, checkpoint: Checkpoint, report: TickReport) -> None:
        """The group left bisecting: cancel the controller jobs still running, then the job and its story rows."""
        for entry in checkpoint.actions:
            if entry["type"] != "run" or entry["status"] not in (QUEUED, SUBMITTED):
                continue
            controller_id = entry.get("controller_id") or _seam(
                "controller find", self._controller.find, self._key(checkpoint, entry), error=ControllerError)
            if controller_id is None:
                continue  # never placed; it is no longer published
            if not _seam(f"controller status {controller_id}", self._controller.status, controller_id,
                         error=ControllerError).finished:
                _seam(f"controller cancel {controller_id}", self._controller.cancel, controller_id,
                      error=ControllerError)
        reason = json.dumps({"cancelled": f"group {row['alert_group_id']} is {row['group_state']}"})

        def write() -> None:
            now = self._now()
            self._db.execute("UPDATE jobs SET state = 'cancelled', result_json = ?, updated_at = ? WHERE id = ?",
                             (reason, now, row["id"]))
            self._db.execute(
                """UPDATE jobs SET state = 'cancelled', updated_at = ? WHERE kind = ? AND alert_group_id IS NULL
                   AND json_extract(params_json, '$.bisect_job') = ? AND state IN ('queued', 'running')""",
                (now, JOB_KIND, row["id"]))

        self._write(write)
        report.cancelled.append(row["id"])

    def _finish(self, row: sqlite3.Row, result) -> None:
        """Stores the result; a group still bisecting moves to culprit (unverified) or back to triaged."""
        culprit = max(result.culprits, default=None,
                      key=lambda c: abs((c.comparison.mean_change or 0.0) - (c.comparison.mean_parent or 0.0)))

        def write() -> None:
            current = self._db.execute("SELECT state FROM jobs WHERE id = ?", (row["id"],)).fetchone()
            if current["state"] != "running":
                return
            self._db.execute("UPDATE jobs SET state = 'done', result_json = ?, updated_at = ? WHERE id = ?",
                             (result.to_json(), self._now(), row["id"]))
            group = self._db.execute("SELECT state FROM alert_groups WHERE id = ?", (row["alert_group_id"],)).fetchone()
            if group["state"] != "bisecting":
                return  # a sheriff moved it after this tick read it; the job's result stays for the record
            if culprit is not None:
                others = len(result.culprits) - 1
                reason = (f"bisect job {row['id']}: culprit {culprit.change.sha[:12]} "
                          f"({len(culprit.commits)} commit{'s' if len(culprit.commits) != 1 else ''}, "
                          f"{culprit.comparison.verdict} p={culprit.comparison.p_value:.4g})"
                          + (f", {others} more" if others else "") + "; unverified until verify.py")
                self._sheriff.apply_state(row["alert_group_id"], "culprit", reason=reason,
                                          culprit_sha=culprit.change.sha)
            else:
                skipped = f", {len(result.skipped)} commits skipped" if result.skipped else ""
                self._sheriff.apply_state(row["alert_group_id"], "triaged",
                                          reason=f"bisect job {row['id']}: {result.outcome}, no culprit{skipped}")

        try:
            self._write(write)
        except sheriff.SheriffError as error:
            raise ExecError(f"result ready, but the group move was refused: {error}") from error


def catalog_repeat_seconds(root: Path | str = HERE.parents[1]) -> Callable[[str], float | None]:
    """repeat_seconds from the story catalog: a story's `seconds` (one run) over its `repeats`."""
    catalog = _load_sibling("perf_lab_catalog", "catalog.py").load_catalog(Path(root))
    seconds = {s.id: s.seconds / max(s.repeats, 1) for s in catalog.stories if s.seconds > 0}
    return seconds.get
