#!/usr/bin/env python3
"""Culprit verification: a try job C^ vs C on one pinpoint host, judged by Pinpoint's strict rule.

A bisect (pinpoint.py, task 015) names a culprit C with the floored verdict (DIFFERENT at p <= 0.05).
Before an alert group may open an issue, its culprit must hold up under the strict rule
(p12-perf-process.md 3.6, R5): the parent C^ (arm A) and C (arm B) each get `attempts` runs (20 by
default) in ABBA order (A B B A, A B B A, ...) on one pinpoint host, so a slow drift of the host
weighs on both arms equally. The culprit is `verified` only when catapult's original verdict is
DIFFERENT (p <= LowThreshold() = 0.01) and the median moved in the regression direction; else it is
`unverified` and the sheriff is told through the group's history.

Statistics come only from perf_stats.py. The samples of all attempts of an arm are pooled, and
compare() gets catapult's sample count, as catapult job_state.py _Compare does:
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/job_state.py
A shift in the improvement direction is never a regression, as there (015's "improvement-direction
shift = SAME").

- plan(): pure; picks the one host and lays out the ABBA attempts.
- judge(): pure; turns the attempts' samples into a Verification with the median and p99 shift.
- run(): drives a plan through an injected runner (the executor's story run, or a fake).
- GroupRecorder: stores the verify job, its Verification and the group's culprit fields in the lab store.

Stdlib only; loaded by file path, with perf_stats.py next to it.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path


def _load_perf_stats():
    name = "perf_lab_perf_stats"
    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_stats.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load_perf_stats()

DEFAULT_ATTEMPTS = 20
PARENT = "A"  # C^, the base arm
CULPRIT = "B"  # C, the head arm
VERIFIED = "verified"
UNVERIFIED = "unverified"
ACTOR = "perf-lab-verify"
JOB_KIND = "verify"


class VerifyError(ValueError):
    """A plan that cannot pin one pinpoint host, or results that do not match their plan."""


@dataclass(frozen=True)
class LabHost:
    name: str
    host_class: str
    role: str  # "waterfall" or "pinpoint"


@dataclass(frozen=True)
class Request:
    group_id: int
    parent_sha: str
    culprit_sha: str
    story: str
    metric: str
    host_class: str
    better: str  # "lower" or "higher": the series direction
    attempts: int = DEFAULT_ATTEMPTS
    magnitude: float = 1.0  # the bisect's magnitude in IQRs; it only moves HighThreshold (SAME vs UNKNOWN)

    def __post_init__(self) -> None:
        if self.better not in ("lower", "higher"):
            raise VerifyError(f"better is {self.better!r}, not 'lower' or 'higher'")
        if self.attempts < 1:
            raise VerifyError(f"attempts is {self.attempts}; a verification needs at least 1 per arm")
        if self.parent_sha == self.culprit_sha:
            raise VerifyError(f"{self.culprit_sha}: the parent and the culprit are the same commit")


@dataclass(frozen=True)
class Attempt:
    index: int
    arm: str
    sha: str
    host: str


@dataclass(frozen=True)
class Plan:
    request: Request
    host: str
    attempts: tuple[Attempt, ...]


@dataclass(frozen=True)
class AttemptResult:
    attempt: Attempt
    host: str  # where it ran; it must be the plan's host
    samples: tuple[float, ...] | None  # None: the attempt failed and measured nothing


@dataclass(frozen=True)
class Verification:
    state: str  # VERIFIED or UNVERIFIED
    reason: str
    strict: str  # catapult's original verdict: different, same or unknown
    floored: str  # the bisect's verdict on the same samples
    p_value: float | None
    ks_p_value: float | None
    mwu_p_value: float | None
    host: str
    parent_sha: str
    culprit_sha: str
    parent_attempts: int  # completed attempts
    culprit_attempts: int
    parent_p50: float | None
    culprit_p50: float | None
    parent_p99: float | None
    culprit_p99: float | None
    median_shift: float | None  # culprit p50 - parent p50, in the metric's unit
    p99_shift: float | None
    median_shift_pct: float | None  # relative to the parent's p50; None when that is 0
    p99_shift_pct: float | None
    magnitude_iqr: float | None  # |median shift| / max(IQR_A, IQR_B, 0.001), catapult's magnitude

    @property
    def verified(self) -> bool:
        return self.state == VERIFIED

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)


def abba(attempts: int) -> tuple[str, ...]:
    """A B B A repeated: `attempts` runs of each arm, every arm equally early and late in the run."""
    block = (PARENT, CULPRIT, CULPRIT, PARENT)
    order = [block[i % 4] for i in range(2 * attempts)]
    return tuple(order)


def plan(request: Request, hosts: Sequence[LabHost], *, prefer: str | None = None) -> Plan:
    """Every attempt of both arms on one pinpoint host of the request's class; `prefer` (the bisect's host) first."""
    candidates = sorted((h for h in hosts if h.role == "pinpoint" and h.host_class == request.host_class),
                        key=lambda h: h.name)
    if not candidates:
        raise VerifyError(f"no pinpoint host of class {request.host_class}")
    host = next((h for h in candidates if h.name == prefer), candidates[0])
    shas = {PARENT: request.parent_sha, CULPRIT: request.culprit_sha}
    attempts = tuple(Attempt(index, arm, shas[arm], host.name) for index, arm in enumerate(abba(request.attempts)))
    return Plan(request, host.name, attempts)


def _shift(after: float | None, before: float | None) -> tuple[float | None, float | None]:
    if after is None or before is None:
        return None, None
    delta = after - before
    return delta, (100.0 * delta / before if before else None)


def judge(plan_: Plan, results: Sequence[AttemptResult]) -> Verification:
    """The strict verdict on the plan's attempts; verified only for DIFFERENT (p <= 0.01) in the regression direction."""
    request = plan_.request
    by_index = {result.attempt.index: result for result in results}
    if len(by_index) != len(results) or set(by_index) != {a.index for a in plan_.attempts}:
        raise VerifyError("results do not cover each planned attempt exactly once")
    values = {PARENT: [], CULPRIT: []}
    completed = {PARENT: 0, CULPRIT: 0}
    for attempt in plan_.attempts:
        result = by_index[attempt.index]
        if result.attempt != attempt:
            raise VerifyError(f"attempt {attempt.index}: result is for {result.attempt}, plan has {attempt}")
        if result.host != plan_.host:
            raise VerifyError(f"attempt {attempt.index} ran on {result.host}; the plan pins {plan_.host}")
        if result.samples:
            values[attempt.arm].extend(result.samples)
            completed[attempt.arm] += 1

    comparison = perf_stats.compare(values[PARENT], values[CULPRIT], mode="performance", magnitude=request.magnitude)
    before, after = perf_stats.summary(values[PARENT]), perf_stats.summary(values[CULPRIT])
    median_shift, median_pct = _shift(after["p50"], before["p50"])
    p99_shift, p99_pct = _shift(after["p99"], before["p99"])
    magnitude = (perf_stats.magnitude_from(median_shift, values[PARENT], values[CULPRIT])
                 if median_shift is not None else None)

    strict, floored, p = comparison.original.result, comparison.floored.result, comparison.p_value
    regressed = median_shift is not None and (median_shift > 0 if request.better == "lower" else median_shift < 0)
    if strict == perf_stats.DIFFERENT and regressed:
        state, reason = VERIFIED, f"strict DIFFERENT p={p:.4g}, median {median_shift:+.4g} (regression)"
    elif strict == perf_stats.DIFFERENT:
        state, reason = UNVERIFIED, f"strict DIFFERENT p={p:.4g}, but median {median_shift:+.4g} is not a regression"
    elif p is None:
        state, reason = UNVERIFIED, (f"no samples (completed attempts: parent {completed[PARENT]}, "
                                     f"culprit {completed[CULPRIT]})")
    else:
        state, reason = UNVERIFIED, f"strict {strict.upper()} p={p:.4g} (floored {floored.upper()}), not p <= 0.01"

    return Verification(
        state=state, reason=reason, strict=strict, floored=floored, p_value=p,
        ks_p_value=comparison.ks_p_value, mwu_p_value=comparison.mwu_p_value, host=plan_.host,
        parent_sha=request.parent_sha, culprit_sha=request.culprit_sha,
        parent_attempts=completed[PARENT], culprit_attempts=completed[CULPRIT],
        parent_p50=before["p50"], culprit_p50=after["p50"], parent_p99=before["p99"], culprit_p99=after["p99"],
        median_shift=median_shift, p99_shift=p99_shift, median_shift_pct=median_pct, p99_shift_pct=p99_pct,
        magnitude_iqr=magnitude)


Runner = Callable[[Attempt], Sequence[float] | None]


def run(plan_: Plan, runner: Runner) -> Verification:
    """Runs the attempts in plan order (ABBA) through `runner` and judges them; a runner returns None for a failure."""
    results = []
    for attempt in plan_.attempts:
        samples = runner(attempt)
        results.append(AttemptResult(attempt, attempt.host, None if samples is None else tuple(samples)))
    return judge(plan_, results)


def _stamp(moment: datetime) -> str:
    """The lab store's stamp: fixed-width UTC ISO-8601 (store.py _stamp)."""
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise VerifyError(f"{moment.isoformat()}: a stored time needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


class GroupRecorder:
    """Writes verify jobs and their outcome into a migrated lab store (store.py schema 1).

    One connection, owned by the opening thread, like store.Store; every write is BEGIN IMMEDIATE so it
    waits for labd's writer instead of interleaving.

    The group keeps one culprit: a verified culprit sets culprit_sha and culprit_verified = 1, and a
    later unverified one (a second culprit of the same group) never replaces it. The median and p99
    shift live in the verify job's result_json, linked by alert_group_id; verification_of() reads them.
    """

    def __init__(self, path: Path | str, *, clock: Callable[[], datetime],
                 busy_timeout_ms: int = 5000) -> None:
        self._clock = clock
        self._db = sqlite3.connect(str(path), isolation_level=None, timeout=busy_timeout_ms / 1000)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA foreign_keys=ON")

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

    def start(self, plan_: Plan) -> int:
        """The verify job row for the plan; a restart finds the unfinished job for the same culprit and reuses it."""
        request = plan_.request
        params = json.dumps({"metric": request.metric, "better": request.better, "attempts": request.attempts,
                             "magnitude": request.magnitude, "host": plan_.host,
                             "order": "".join(abba(request.attempts))}, sort_keys=True)

        def write() -> int:
            if self._db.execute("SELECT 1 FROM alert_groups WHERE id = ?", (request.group_id,)).fetchone() is None:
                raise VerifyError(f"no alert group {request.group_id}")
            existing = self._db.execute(
                """SELECT id FROM jobs WHERE kind = ? AND alert_group_id = ? AND base_sha = ? AND head_sha = ?
                   AND story = ? AND params_json = ? AND state != 'done' ORDER BY id DESC LIMIT 1""",
                (JOB_KIND, request.group_id, request.parent_sha, request.culprit_sha, request.story,
                 params)).fetchone()
            if existing is not None:
                return existing["id"]
            now = _stamp(self._clock())
            return self._db.execute(
                """INSERT INTO jobs (kind, state, story, host_class, base_sha, head_sha, alert_group_id, params_json,
                                     created_at, updated_at) VALUES (?, 'running', ?, ?, ?, ?, ?, ?, ?, ?)""",
                (JOB_KIND, request.story, request.host_class, request.parent_sha, request.culprit_sha,
                 request.group_id, params, now, now)).lastrowid

        return self._write(write)

    def finish(self, job_id: int, verification: Verification) -> None:
        """Stores the outcome on the job and the group and tells the sheriff (a group history row). Idempotent."""
        result_json = verification.to_json()

        def write() -> None:
            job = self._db.execute("SELECT * FROM jobs WHERE id = ? AND kind = ?", (job_id, JOB_KIND)).fetchone()
            if job is None:
                raise VerifyError(f"no verify job {job_id}")
            if (job["base_sha"], job["head_sha"]) != (verification.parent_sha, verification.culprit_sha):
                raise VerifyError(f"job {job_id} verifies {job['head_sha']}, not {verification.culprit_sha}")
            if job["state"] == "done":
                if job["result_json"] != result_json:
                    raise VerifyError(f"job {job_id} already finished with another result")
                return
            now = _stamp(self._clock())
            self._db.execute("UPDATE jobs SET state = 'done', result_json = ?, updated_at = ? WHERE id = ?",
                             (result_json, now, job_id))
            group = self._db.execute("SELECT * FROM alert_groups WHERE id = ?", (job["alert_group_id"],)).fetchone()
            to_state = "culprit" if group["state"] == "bisecting" else group["state"]
            if verification.verified or not group["culprit_verified"]:
                self._db.execute("UPDATE alert_groups SET culprit_sha = ?, culprit_verified = ? WHERE id = ?",
                                 (verification.culprit_sha, int(verification.verified), group["id"]))
            self._db.execute("UPDATE alert_groups SET state = ?, updated_at = ? WHERE id = ?",
                             (to_state, now, group["id"]))
            self._db.execute(
                """INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (group["id"], group["state"], to_state, ACTOR,
                 f"culprit {verification.culprit_sha[:12]} {verification.state} (job {job_id}): "
                 f"{verification.reason}", now))

        self._write(write)

    def verification_of(self, group_id: int) -> list[dict]:
        """The finished verify jobs of a group, oldest first, each with its Verification fields and job id."""
        rows = self._db.execute(
            "SELECT id, result_json FROM jobs WHERE kind = ? AND alert_group_id = ? AND state = 'done' ORDER BY id",
            (JOB_KIND, group_id)).fetchall()
        return [{"job_id": row["id"], **json.loads(row["result_json"])} for row in rows]
