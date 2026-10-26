#!/usr/bin/env python3
"""Sheriff states, the `lab.py sheriff` commands and the sheriff SLO report (p12-perf-process.md 3.7).

An alert group moves new -> triaged -> bisecting -> culprit -> assigned and ends fixed, flag-off,
accepted, invalid or lab-drift. Every move is one row in sheriff_history with its actor, reason and
time, written in the same transaction that checks the move, so two sessions cannot both move a group.
A take is not a move: the claim lives on the group (holder, held_at; store migration 2), so
sheriff_history, and the one issue comment per row that alerts.sync_issues posts, holds only real moves.

Chromeperf keeps the same split: catapult `dashboard/dashboard/models/alert_group.py` gives an
AlertGroup a status (untriaged, triaged, bisected, closed) that `alert_group_workflow.py` advances,
and `dashboard/dashboard/mark_recovered_alerts.py` marks an anomaly recovered from the series after
its end revision; the group closes only when its anomalies recovered. Here `fixed` likewise needs the
series to recover: the 2 newest judged batches after every regression alert of the group are back on
the good side of the alert's step. Two batches are too few for a change-point search (E-Divisive needs
MIN_SEGMENT_SIZE = 6 points), so a batch counts as recovered when its median is nearer the alert's
median_before than its median_after.

The acting session is the caller's own agent session from its environment (CMUX_AGENT_SESSION, else
CLAUDE_CODE_SESSION_ID, else CODEX_THREAD_ID), never an argument. `accepted` needs a reason and the
Performance Lead's session, which the lab host names in the file `perf-lead-session` beside the store.

The CLI opens an existing, migrated store only: labd creates and migrates it, and a read-only report
must not create an empty store whose fresh schema_version would claim the lab just went live.

SLOs (counted from the alert, groups created since the lab went live): triage <= 1 h, culprit <= 4 h
(median), fix or flag-off <= 12 h; no group older than 12 h may wait in new, triaged, bisecting or culprit.

lab.py wires it as `sheriff.add_arguments(subparsers.add_parser("sheriff"))` with `run=sheriff.run`;
`python3 scripts/perf-lab/sheriff.py ...` runs the same commands on its own.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sqlite3
import statistics
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType

_HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", "store.py")
perf_stats = _load("perf_lab_perf_stats", "perf_stats.py")

STATES: tuple[str, ...] = store.ALERT_GROUP_STATES
TERMINAL = frozenset({"fixed", "flag-off", "accepted", "invalid", "lab-drift"})
TRANSITIONS: dict[str, frozenset[str]] = {
    "new": frozenset({"triaged", "invalid", "lab-drift"}),
    "triaged": frozenset({"bisecting", "accepted", "invalid", "lab-drift"}),
    "bisecting": frozenset({"culprit", "triaged", "invalid", "lab-drift"}),
    "culprit": frozenset({"assigned", "bisecting", "flag-off", "accepted", "invalid"}),
    "assigned": frozenset({"fixed", "flag-off", "accepted", "invalid"}),
}
# A step back (a failed bisect, a culprit that did not verify) says why.
BACKWARD = frozenset({("bisecting", "triaged"), ("culprit", "bisecting")})
REASON_REQUIRED = frozenset({"assigned", "flag-off", "accepted", "invalid", "lab-drift"})
RECOVERY_BATCHES = 2
TAKE_LEASE = timedelta(hours=2)
SESSION_ENVS = ("CMUX_AGENT_SESSION", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")
LEAD_FILE = "perf-lead-session"
DB_ENV = "CMUX_PERF_LAB_DB"

TRIAGE_SLO = timedelta(hours=1)
CULPRIT_SLO = timedelta(hours=4)
FIX_SLO = timedelta(hours=12)
STALE_STATES = frozenset({"new", "triaged", "bisecting", "culprit"})
_SHA = re.compile(r"[0-9a-f]{7,40}")


class SheriffError(Exception):
    """A refused sheriff command; the message says why."""


class NoSuchGroup(SheriffError):
    pass


class IllegalTransition(SheriffError):
    pass


class MissingReason(SheriffError):
    pass


class NotPerformanceLead(SheriffError):
    pass


class NotRecovered(SheriffError):
    pass


class Claimed(SheriffError):
    pass


class NoSession(SheriffError):
    pass


def _stamp(moment: datetime) -> str:
    """The store's stamp format: fixed-width UTC ISO-8601, so stamps compare as text in time order."""
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise SheriffError(f"{moment.isoformat()}: a sheriff time needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


def _parse(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp).astimezone(timezone.utc)


def _hours(delta: timedelta) -> float:
    return round(delta.total_seconds() / 3600, 3)


@dataclass(frozen=True)
class HistoryEntry:
    group_id: int
    from_state: str | None
    to_state: str
    actor: str
    reason: str | None
    at: str

    def describe(self) -> str:
        if self.from_state is None:
            return "created"
        if self.from_state == self.to_state:
            return f"{self.to_state} (no move)"
        return f"{self.from_state} -> {self.to_state}"


@dataclass(frozen=True)
class Claim:
    group_id: int
    holder: str
    held_at: str


@dataclass(frozen=True)
class Group:
    id: int
    state: str
    start_pos: int
    end_pos: int
    culprit_sha: str | None
    culprit_verified: bool
    issue_number: int | None
    reason: str | None
    created_at: str
    updated_at: str
    age_hours: float
    holder: str | None
    stories: tuple[str, ...]


@dataclass(frozen=True)
class AlertRecovery:
    alert_id: int
    story: str
    metric: str
    rule: str
    median_before: float | None
    median_after: float | None
    batches: tuple[tuple[int, float], ...]
    recovered: bool
    why: str


@dataclass(frozen=True)
class Recovery:
    group_id: int
    recovered: bool
    alerts: tuple[AlertRecovery, ...]

    def explain(self) -> str:
        if not self.alerts:
            return f"group {self.group_id} has no regression alert to judge recovery on"
        return "; ".join(f"{a.story}/{a.metric}: {a.why}" for a in self.alerts if not a.recovered)


def _point_median(samples: Sequence[float]) -> float | None:
    return perf_stats.pct(samples, 0.5)


def judged_batches(points: Sequence[object], *, after_pos: int) -> list[tuple[int, float]]:
    """(commit position, median of its points' medians) for each batch after `after_pos`, oldest first.

    A batch is one built commit; its shards and repeats are points at the same position. A batch is
    judged when at least one of its points has samples.
    """
    by_pos: dict[int, list[float]] = {}
    for point in points:
        if point.commit_pos <= after_pos:
            continue
        value = _point_median(point.samples)
        if value is not None:
            by_pos.setdefault(point.commit_pos, []).append(value)
    return [(pos, statistics.median(values)) for pos, values in sorted(by_pos.items())]


def batch_recovered(value: float, *, before: float, after: float, better: str) -> bool:
    """Nearer the pre-step median than the post-step one, judged in the series' good direction."""
    midpoint = (before + after) / 2
    return value <= midpoint if better == "lower" else value >= midpoint


class Sheriff:
    """Sheriff commands over one lab store. The store owns the schema, the WAL connection and migrations."""

    def __init__(self, lab: store.Store, *, session: str | None, lead_session: str | None,
                 clock: Callable[[], datetime] = store.utc_now, take_lease: timedelta = TAKE_LEASE) -> None:
        """`session` is the caller's own agent session (caller_session()); None allows reads only."""
        self._lab = lab
        # The store's one connection and its BEGIN IMMEDIATE writer: the lab keeps one WAL connection per thread.
        self._db: sqlite3.Connection = lab._db
        self._write = lab._write
        self._clock = clock
        self._session = (session or "").strip() or None
        self._lead_session = (lead_session or "").strip() or None
        self._take_lease = take_lease

    def _now(self) -> datetime:
        return self._clock().astimezone(timezone.utc)

    def _group_row(self, group_id: int) -> sqlite3.Row:
        row = self._db.execute("SELECT * FROM alert_groups WHERE id = ?", (group_id,)).fetchone()
        if row is None:
            raise NoSuchGroup(f"no alert group {group_id}")
        return row

    def history(self, group_id: int) -> list[HistoryEntry]:
        self._group_row(group_id)
        rows = self._db.execute(
            "SELECT group_id, from_state, to_state, actor, reason, at FROM sheriff_history "
            "WHERE group_id = ? ORDER BY at, id", (group_id,)).fetchall()
        return [HistoryEntry(*row) for row in rows]

    def _actor(self) -> str:
        if self._session is None:
            raise NoSession(f"no agent session in the environment ({', '.join(SESSION_ENVS)}); "
                            "a sheriff acts as its own session")
        return self._session

    def _holder(self, row: sqlite3.Row, now: datetime) -> str | None:
        """The session that took the group, while its take or its last move is within the lease."""
        if row["holder"] is None or row["held_at"] is None:
            return None
        return row["holder"] if now - _parse(row["held_at"]) < self._take_lease else None

    def groups(self, states: Sequence[str] | None = None) -> list[Group]:
        unknown = set(states or ()) - set(STATES)
        if unknown:
            raise SheriffError(f"unknown state {', '.join(sorted(unknown))}; states are {', '.join(STATES)}")
        sql, args = "SELECT * FROM alert_groups", ()
        if states:
            sql += f" WHERE state IN ({', '.join('?' for _ in states)})"
            args = tuple(states)
        now = self._now()
        result = []
        for row in self._db.execute(sql + " ORDER BY created_at, id", args).fetchall():
            stories = tuple(story for (story,) in self._db.execute(
                "SELECT DISTINCT s.story FROM alerts a JOIN series s ON s.id = a.series_id "
                "WHERE a.group_id = ? ORDER BY s.story", (row["id"],)))
            result.append(Group(
                id=row["id"], state=row["state"], start_pos=row["start_pos"], end_pos=row["end_pos"],
                culprit_sha=row["culprit_sha"], culprit_verified=bool(row["culprit_verified"]),
                issue_number=row["issue_number"], reason=row["reason"], created_at=row["created_at"],
                updated_at=row["updated_at"], age_hours=_hours(now - _parse(row["created_at"])),
                holder=self._holder(row, now), stories=stories))
        return result

    def _append(self, group_id: int, from_state: str, to_state: str, actor: str, reason: str | None,
                now: datetime) -> HistoryEntry:
        at = _stamp(now)
        self._db.execute(
            "INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) VALUES (?, ?, ?, ?, ?, ?)",
            (group_id, from_state, to_state, actor, reason, at))
        return HistoryEntry(group_id, from_state, to_state, actor, reason, at)

    def take(self, group_id: int) -> Claim:
        """Claims an open group for this session; another session's live claim refuses it. No history row."""
        session = self._actor()

        def write() -> Claim:
            row = self._group_row(group_id)
            if row["state"] in TERMINAL:
                raise IllegalTransition(f"group {group_id} is {row['state']}; a closed group cannot be taken")
            now = self._now()
            holder = self._holder(row, now)
            if holder not in (None, session):
                raise Claimed(f"group {group_id} is held by {holder}")
            held_at = _stamp(now)
            self._db.execute("UPDATE alert_groups SET holder = ?, held_at = ? WHERE id = ?",
                             (session, held_at, group_id))
            return Claim(group_id, session, held_at)

        return self._write(write)

    def set_state(self, group_id: int, to_state: str, *, reason: str | None = None,
                  culprit_sha: str | None = None) -> HistoryEntry:
        """Moves a group one legal step and records it; refuses anything else with a typed error."""
        return self._write(lambda: self.apply_state(group_id, to_state, reason=reason, culprit_sha=culprit_sha))

    def apply_state(self, group_id: int, to_state: str, *, reason: str | None = None,
                    culprit_sha: str | None = None) -> HistoryEntry:
        """set_state inside the caller's open write transaction (the store's `_write`), so an automatic actor
        (pinpoint_exec.py) moves a group with the same rules and in the same transaction as its own rows."""
        session = self._actor()
        reason = (reason or "").strip() or None
        if to_state not in STATES:
            raise IllegalTransition(f"unknown state {to_state!r}; states are {', '.join(STATES)}")
        row = self._group_row(group_id)
        from_state = row["state"]
        if to_state not in TRANSITIONS.get(from_state, frozenset()):
            allowed = ", ".join(sorted(TRANSITIONS.get(from_state, ()))) or "nothing (closed)"
            raise IllegalTransition(f"group {group_id}: {from_state} -> {to_state} is not allowed; "
                                    f"{from_state} goes to {allowed}")
        if reason is None and (to_state in REASON_REQUIRED or (from_state, to_state) in BACKWARD):
            raise MissingReason(f"group {group_id}: {from_state} -> {to_state} needs --reason")
        if to_state == "accepted" and (self._lead_session is None or session != self._lead_session):
            lead = self._lead_session or f"none configured ({LEAD_FILE} beside the store)"
            raise NotPerformanceLead(f"group {group_id}: only the Performance Lead's session accepts a "
                                     f"regression; {session} is not {lead}")
        culprit, verified = row["culprit_sha"], bool(row["culprit_verified"])
        if to_state == "culprit":
            named = (culprit_sha or "").strip().lower()
            if not _SHA.fullmatch(named):
                raise SheriffError(f"group {group_id}: culprit needs --culprit SHA (7-40 hex digits)")
            # Verification (verify.py) belongs to one commit; any other commit starts unverified.
            same = culprit is not None and (culprit.startswith(named) or named.startswith(culprit))
            culprit, verified = (max(culprit, named, key=len), verified) if same else (named, False)
        elif culprit_sha is not None:
            raise SheriffError(f"group {group_id}: --culprit goes only with the culprit state")
        elif (from_state, to_state) == ("culprit", "bisecting"):
            culprit, verified = None, False  # the culprit did not hold
        now = self._now()
        holder = self._holder(row, now)
        if holder not in (None, session) and session != self._lead_session:
            raise Claimed(f"group {group_id} is held by {holder}; take it after the lease or ask that session")
        if to_state == "fixed":
            recovery = self._recovery(group_id)
            if not recovery.recovered:
                raise NotRecovered(f"group {group_id} stays {from_state}: the series has not recovered "
                                   f"({recovery.explain()})")
        closing_reason = reason if to_state in TERMINAL else row["reason"]
        if to_state in TERMINAL:
            claim = (None, None)
        elif holder == session:
            claim = (session, _stamp(now))  # the holder's own move renews its lease
        else:
            claim = (row["holder"], row["held_at"])
        self._db.execute(
            "UPDATE alert_groups SET state = ?, culprit_sha = ?, culprit_verified = ?, reason = ?, "
            "holder = ?, held_at = ?, updated_at = ? WHERE id = ?",
            (to_state, culprit, int(verified), closing_reason, *claim, _stamp(now), group_id))
        return self._append(group_id, from_state, to_state, session, reason, now)

    def recovery(self, group_id: int) -> Recovery:
        self._group_row(group_id)
        return self._recovery(group_id)

    def _recovery(self, group_id: int) -> Recovery:
        alerts = self._db.execute(
            """SELECT a.id, a.rule, a.end_pos, a.median_before, a.median_after, s.series_key, s.story,
                      s.metric, s.better
               FROM alerts a JOIN series s ON s.id = a.series_id
               WHERE a.group_id = ? AND a.is_improvement = 0 ORDER BY a.id""", (group_id,)).fetchall()
        judged = tuple(self._alert_recovery(alert) for alert in alerts)
        return Recovery(group_id, bool(judged) and all(a.recovered for a in judged), judged)

    def _alert_recovery(self, alert: sqlite3.Row) -> AlertRecovery:
        batches = judged_batches(self._lab.series_points(alert["series_key"]), after_pos=alert["end_pos"])
        newest = tuple(batches[-RECOVERY_BATCHES:])
        before, after = alert["median_before"], alert["median_after"]

        def result(recovered: bool, why: str) -> AlertRecovery:
            return AlertRecovery(alert["id"], alert["story"], alert["metric"], alert["rule"], before, after,
                                 newest, recovered, why)

        if len(newest) < RECOVERY_BATCHES:
            return result(False, f"{len(newest)} of {RECOVERY_BATCHES} judged batches after position "
                                 f"{alert['end_pos']}")
        if alert["rule"] == "harness_broken":
            return result(True, f"the story ran in {RECOVERY_BATCHES} batches after the break")
        if before is None or after is None:
            return result(False, "the alert has no median before or after its step")
        missed = [(pos, value) for pos, value in newest
                  if not batch_recovered(value, before=before, after=after, better=alert["better"])]
        if missed:
            shown = ", ".join(f"{value:g} at {pos}" for pos, value in missed)
            return result(False, f"batch median {shown} is nearer {after:g} (after) than {before:g} (before)")
        return result(True, f"last {RECOVERY_BATCHES} batch medians back near {before:g}")

    def live_at(self) -> datetime:
        """When the lab went live: the store's first migration, applied when labd first opened the database."""
        row = self._db.execute("SELECT applied_at FROM schema_version WHERE version = 1").fetchone()
        if row is None:
            raise SheriffError("the lab store is not migrated; the lab has not gone live")
        return _parse(row["applied_at"])

    def slo(self, since: datetime) -> dict[str, object]:
        """The sheriff SLO report over groups created at or after `since`."""
        now = self._now()
        triage = {"met": [], "missed": [], "pending": []}
        culprit = {"reached": [], "overdue": [], "pending": []}
        fix = {"met": [], "missed": [], "pending": []}
        stale, culprit_hours = [], []
        groups = self._db.execute("SELECT id, state, created_at FROM alert_groups WHERE created_at >= ? "
                                  "ORDER BY created_at, id", (_stamp(since),)).fetchall()
        for row in groups:
            gid, state, created = row["id"], row["state"], _parse(row["created_at"])
            moves = self.history(gid)
            age = now - created
            triaged_at = next((_parse(m.at) for m in moves if m.from_state == "new" and m.to_state != "new"), None)
            culprit_at = next((_parse(m.at) for m in moves if m.to_state == "culprit"), None)
            resolved_at = next((_parse(m.at) for m in moves if m.to_state in ("fixed", "flag-off")), None)

            if triaged_at is not None:
                triage["met" if triaged_at - created <= TRIAGE_SLO else "missed"].append(gid)
            elif age > TRIAGE_SLO:
                triage["missed"].append(gid)
            else:
                triage["pending"].append(gid)

            if culprit_at is not None:
                culprit["reached"].append(gid)
                culprit_hours.append(_hours(culprit_at - created))
            elif state not in TERMINAL and age > CULPRIT_SLO:
                # Still looking: its age is a lower bound of its time to culprit, so it counts in the median.
                culprit["overdue"].append(gid)
                culprit_hours.append(_hours(age))
            elif state not in TERMINAL:
                culprit["pending"].append(gid)

            if culprit_at is not None:
                if resolved_at is not None:
                    fix["met" if resolved_at - created <= FIX_SLO else "missed"].append(gid)
                elif state not in TERMINAL:
                    fix["missed" if age > FIX_SLO else "pending"].append(gid)

            if state in STALE_STATES and age > FIX_SLO:
                stale.append({"group": gid, "state": state, "age_hours": _hours(age)})

        triage_judged = len(triage["met"]) + len(triage["missed"])
        fix_judged = len(fix["met"]) + len(fix["missed"])
        median = statistics.median(culprit_hours) if culprit_hours else None
        checks = {
            "triage": not triage["missed"],
            "culprit": median is None or median <= _hours(CULPRIT_SLO),
            "fix": not fix["missed"],
            "stale": not stale,
        }
        return {
            "since": _stamp(since),
            "now": _stamp(now),
            "groups": len(groups),
            "triage": {**triage, "slo_hours": _hours(TRIAGE_SLO), "ok": checks["triage"],
                       "pct": round(100 * len(triage["met"]) / triage_judged, 1) if triage_judged else None},
            "culprit": {**culprit, "slo_hours": _hours(CULPRIT_SLO), "ok": checks["culprit"],
                        "median_hours": median},
            "fix": {**fix, "slo_hours": _hours(FIX_SLO), "ok": checks["fix"],
                    "pct": round(100 * len(fix["met"]) / fix_judged, 1) if fix_judged else None},
            "stale": stale,
            "pass": all(checks.values()),
        }


def caller_session(environ: Mapping[str, str]) -> str | None:
    """The caller's own agent session, the first of SESSION_ENVS its harness set."""
    return next((value.strip() for name in SESSION_ENVS if (value := environ.get(name, "")).strip()), None)


def read_lead_session(db_path: Path) -> str | None:
    """The Performance Lead's session as the lab host names it in LEAD_FILE beside the store."""
    try:
        return (db_path.parent / LEAD_FILE).read_text(encoding="utf-8").strip() or None
    except FileNotFoundError:
        return None


def open_store(db_path: Path, clock: Callable[[], datetime]) -> store.Store:
    """An existing store at this checkout's schema. labd creates and migrates it; the CLI never does."""
    if not db_path.is_file():
        raise SheriffError(f"{db_path}: no lab store there; labd creates it")
    lab = store.Store(db_path, clock=clock)
    try:
        version, known = lab.schema_version(), len(store.MIGRATIONS)
        if version != known:
            fix = "labd migrates it" if version < known else "update the checkout"
            relation = "older" if version < known else "newer"
            raise SheriffError(f"{db_path}: schema {version} is {relation} than this checkout ({known}); {fix}")
    except BaseException:
        lab.close()
        raise
    return lab


_RELATIVE = re.compile(r"(\d+)([hd])")


def parse_since(text: str, now: datetime) -> datetime:
    """`24h`, `7d` or an ISO-8601 time with a timezone."""
    match = _RELATIVE.fullmatch(text.strip())
    if match:
        amount, unit = int(match.group(1)), match.group(2)
        return now - (timedelta(hours=amount) if unit == "h" else timedelta(days=amount))
    try:
        moment = datetime.fromisoformat(text.strip())
    except ValueError as error:
        raise SheriffError(f"--since {text!r}: use 24h, 7d or an ISO-8601 time") from error
    if moment.tzinfo is None:
        raise SheriffError(f"--since {text!r}: an ISO-8601 time needs a timezone")
    return moment.astimezone(timezone.utc)


def add_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", default=os.environ.get(DB_ENV), help=f"lab store path (default ${DB_ENV})")
    parser.add_argument("--slo", action="store_true", help="print the sheriff SLO report")
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--since-live", action="store_true", help="SLO window from the time the lab went live")
    window.add_argument("--since", help="SLO window start: 24h, 7d or an ISO-8601 time")
    parser.add_argument("--json", action="store_true", help="print JSON")
    commands = parser.add_subparsers(dest="sheriff_command")
    listing = commands.add_parser("list", help="alert groups with state, age and holder")
    listing.add_argument("--state", help="comma-separated states, for example new,triaged,culprit")
    listing.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    take = commands.add_parser("take", help="claim a group for this agent session")
    take.add_argument("group", type=int)
    take.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    move = commands.add_parser("set", help="move a group to its next state as this agent session")
    move.add_argument("group", type=int)
    move.add_argument("state", choices=STATES)
    move.add_argument("--reason")
    move.add_argument("--culprit", help="the culprit commit, with the culprit state")
    move.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    history = commands.add_parser("history", help="a group's timestamped state history")
    history.add_argument("group", type=int)
    history.add_argument("--json", action="store_true", default=argparse.SUPPRESS)


def _print_slo(report: dict[str, object]) -> None:
    triage, culprit, fix = report["triage"], report["culprit"], report["fix"]
    mark = {True: "ok", False: "MISSED"}
    print(f"sheriff SLO since {report['since']}: {report['groups']} groups, {'PASS' if report['pass'] else 'FAIL'}")
    print(f"  triage <= 1 h: {mark[triage['ok']]}, met {len(triage['met'])}, missed {triage['missed']}, "
          f"pending {len(triage['pending'])}")
    print(f"  culprit <= 4 h (median): {mark[culprit['ok']]}, median {culprit['median_hours']} h, "
          f"reached {len(culprit['reached'])}, overdue {culprit['overdue']}, pending {len(culprit['pending'])}")
    print(f"  fix or flag-off <= 12 h: {mark[fix['ok']]}, met {len(fix['met'])}, missed {fix['missed']}, "
          f"pending {len(fix['pending'])}")
    stale = ", ".join(f"#{row['group']} {row['state']} {row['age_hours']} h" for row in report["stale"])
    print(f"  older than 12 h in new, triaged, bisecting or culprit: {stale or 'none'}")


def run(args: argparse.Namespace, *, clock: Callable[[], datetime] = store.utc_now,
        environ: Mapping[str, str] | None = None) -> int:
    """Runs one sheriff command; 0 done, 1 SLO missed, 2 refused or the store failed."""
    environ = os.environ if environ is None else environ
    if not args.db:
        print(f"sheriff: no lab store; pass --db or set {DB_ENV}", file=sys.stderr)
        return 2
    db_path = Path(args.db)
    try:
        lab = open_store(db_path, clock)
        try:
            sheriff = Sheriff(lab, clock=clock, session=caller_session(environ),
                              lead_session=read_lead_session(db_path))
            return _dispatch(sheriff, args, clock)
        finally:
            lab.close()
    except (SheriffError, store.StoreError, sqlite3.Error, OSError) as error:
        print(f"sheriff: {error}", file=sys.stderr)
        return 2


def _dispatch(sheriff: Sheriff, args: argparse.Namespace, clock: Callable[[], datetime]) -> int:
    if args.slo:
        if args.sheriff_command:
            raise SheriffError("--slo is a report of its own; drop the subcommand")
        since = sheriff.live_at() if args.since_live or not args.since else parse_since(args.since, clock())
        report = sheriff.slo(since)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            _print_slo(report)
        return 0 if report["pass"] else 1
    if args.since_live or args.since:
        raise SheriffError("--since and --since-live go with --slo")
    command = args.sheriff_command or "list"
    if command == "list":
        states = [s.strip() for s in (getattr(args, "state", None) or "").split(",") if s.strip()]
        groups = sheriff.groups(states or None)
        if args.json:
            print(json.dumps([asdict(group) for group in groups], indent=2))
            return 0
        for group in groups:
            print(f"#{group.id} {group.state:<9} {group.age_hours:>7.2f} h  pos {group.start_pos}-{group.end_pos}  "
                  f"holder {group.holder or '-'}  culprit {group.culprit_sha or '-'}  "
                  f"{', '.join(group.stories)}".rstrip())
        return 0
    if command == "history":
        entries = sheriff.history(args.group)
        if args.json:
            print(json.dumps([asdict(entry) for entry in entries], indent=2))
            return 0
        for entry in entries:
            print(f"{entry.at}  {entry.describe():<22} {entry.actor}  {entry.reason or ''}".rstrip())
        return 0
    if command == "take":
        claim = sheriff.take(args.group)
        print(json.dumps(asdict(claim)) if args.json
              else f"group {claim.group_id}: taken by {claim.holder} at {claim.held_at}")
        return 0
    entry = sheriff.set_state(args.group, args.state, reason=args.reason, culprit_sha=args.culprit)
    print(json.dumps(asdict(entry)) if args.json
          else f"group {entry.group_id}: {entry.describe()} by {entry.actor} at {entry.at}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lab.py sheriff", description=__doc__.splitlines()[0])
    add_arguments(parser)
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
