#!/usr/bin/env python3
"""Sheriff states, the `lab.py sheriff` commands and the sheriff SLO report (p12-perf-process.md 3.7).

An alert group moves new -> triaged -> bisecting -> culprit -> assigned and ends fixed, flag-off,
accepted, invalid or lab-drift. Every move is one row in sheriff_history with its actor, reason and
time, written in the same transaction that checks the move, so two sessions cannot both move a group.

Chromeperf keeps the same split: catapult `dashboard/dashboard/models/alert_group.py` gives an
AlertGroup a status (untriaged, triaged, bisected, closed) that `alert_group_workflow.py` advances,
and `dashboard/dashboard/mark_recovered_alerts.py` marks an anomaly recovered from the series after
its end revision; the group closes only when its anomalies recovered. Here `fixed` likewise needs the
series to recover: the 2 newest judged batches after every regression alert of the group are back on
the good side of the alert's step. Two batches are too few for a change-point search (E-Divisive needs
MIN_SEGMENT_SIZE = 6 points), so a batch counts as recovered when its median is nearer the alert's
median_before than its median_after.

`accepted` needs a reason and the Performance Lead's session (CMUX_PERF_LEAD_SESSION on the lab host).

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
from collections.abc import Callable, Sequence
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
LEAD_SESSION_ENV = "CMUX_PERF_LEAD_SESSION"
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

    @property
    def is_take(self) -> bool:
        """A take keeps the state; every real move changes it."""
        return self.from_state == self.to_state


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

    def __init__(self, lab: store.Store, *, clock: Callable[[], datetime] = store.utc_now,
                 lead_session: str | None = None, take_lease: timedelta = TAKE_LEASE) -> None:
        self._lab = lab
        # The store's one connection and its BEGIN IMMEDIATE writer: the lab keeps one WAL connection per thread.
        self._db: sqlite3.Connection = lab._db
        self._write = lab._write
        self._clock = clock
        self._lead_session = lead_session
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

    def _holder(self, history: Sequence[HistoryEntry], now: datetime) -> str | None:
        """The session of the newest take, while it has acted on the group within the lease."""
        takes = [entry for entry in history if entry.is_take]
        if not takes:
            return None
        holder = takes[-1].actor
        last = max(_parse(entry.at) for entry in history if entry.actor == holder)
        return holder if now - last < self._take_lease else None

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
                holder=self._holder(self.history(row["id"]), now), stories=stories))
        return result

    def _append(self, group_id: int, from_state: str, to_state: str, actor: str, reason: str | None,
                now: datetime) -> HistoryEntry:
        at = _stamp(now)
        self._db.execute(
            "INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) VALUES (?, ?, ?, ?, ?, ?)",
            (group_id, from_state, to_state, actor, reason, at))
        return HistoryEntry(group_id, from_state, to_state, actor, reason, at)

    def take(self, group_id: int, *, session: str) -> HistoryEntry:
        """Claims an open group for one sheriff session; another session's live claim refuses it."""
        session = _required(session, "a take needs the sheriff's session")

        def write() -> HistoryEntry:
            state = self._group_row(group_id)["state"]
            if state in TERMINAL:
                raise IllegalTransition(f"group {group_id} is {state}; a closed group cannot be taken")
            now = self._now()
            holder = self._holder(self.history(group_id), now)
            if holder not in (None, session):
                raise Claimed(f"group {group_id} is held by {holder}")
            return self._append(group_id, state, state, session, "take", now)

        return self._write(write)

    def set_state(self, group_id: int, to_state: str, *, session: str, reason: str | None = None,
                  culprit_sha: str | None = None) -> HistoryEntry:
        """Moves a group one legal step and records it; refuses anything else with a typed error."""
        session = _required(session, "a state change needs the sheriff's session")
        reason = (reason or "").strip() or None
        if to_state not in STATES:
            raise IllegalTransition(f"unknown state {to_state!r}; states are {', '.join(STATES)}")

        def write() -> HistoryEntry:
            row = self._group_row(group_id)
            from_state = row["state"]
            if to_state not in TRANSITIONS.get(from_state, frozenset()):
                allowed = ", ".join(sorted(TRANSITIONS.get(from_state, ()))) or "nothing (closed)"
                raise IllegalTransition(f"group {group_id}: {from_state} -> {to_state} is not allowed; "
                                        f"{from_state} goes to {allowed}")
            if reason is None and (to_state in REASON_REQUIRED or (from_state, to_state) in BACKWARD):
                raise MissingReason(f"group {group_id}: {from_state} -> {to_state} needs --reason")
            if to_state == "accepted" and (self._lead_session is None or session != self._lead_session):
                lead = self._lead_session or f"none configured ({LEAD_SESSION_ENV})"
                raise NotPerformanceLead(f"group {group_id}: only the Performance Lead's session accepts a "
                                         f"regression; {session} is not {lead}")
            culprit = row["culprit_sha"]
            if to_state == "culprit":
                if culprit_sha is None or not _SHA.fullmatch(culprit_sha.strip().lower()):
                    raise SheriffError(f"group {group_id}: culprit needs --culprit SHA (7-40 hex digits)")
                culprit = culprit_sha.strip().lower()
            elif culprit_sha is not None:
                raise SheriffError(f"group {group_id}: --culprit goes only with the culprit state")
            now = self._now()
            holder = self._holder(self.history(group_id), now)
            if holder not in (None, session) and session != self._lead_session:
                raise Claimed(f"group {group_id} is held by {holder}; take it after the lease or ask that session")
            if to_state == "fixed":
                recovery = self._recovery(group_id)
                if not recovery.recovered:
                    raise NotRecovered(f"group {group_id} stays {from_state}: the series has not recovered "
                                       f"({recovery.explain()})")
            closing_reason = reason if to_state in TERMINAL else row["reason"]
            self._db.execute(
                "UPDATE alert_groups SET state = ?, culprit_sha = ?, reason = ?, updated_at = ? WHERE id = ?",
                (to_state, culprit, closing_reason, _stamp(now), group_id))
            return self._append(group_id, from_state, to_state, session, reason, now)

        return self._write(write)

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
            moves = [entry for entry in self.history(gid) if not entry.is_take]
            age = now - created
            triaged_at = next((_parse(m.at) for m in moves if m.from_state == "new"), None)
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


def _required(value: str | None, message: str) -> str:
    value = (value or "").strip()
    if not value:
        raise SheriffError(message)
    return value


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
    take = commands.add_parser("take", help="claim a group for this sheriff session")
    take.add_argument("group", type=int)
    take.add_argument("--session", required=True)
    take.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    move = commands.add_parser("set", help="move a group to its next state")
    move.add_argument("group", type=int)
    move.add_argument("state", choices=STATES)
    move.add_argument("--session", required=True)
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
        environ: dict[str, str] | None = None) -> int:
    """Runs one sheriff command; 0 done, 1 SLO missed, 2 refused."""
    environ = os.environ if environ is None else environ
    if not args.db:
        print(f"sheriff: no lab store; pass --db or set {DB_ENV}", file=sys.stderr)
        return 2
    lab = store.Store(args.db, clock=clock)
    try:
        lab.migrate()
        sheriff = Sheriff(lab, clock=clock, lead_session=(environ.get(LEAD_SESSION_ENV) or "").strip() or None)
        return _dispatch(sheriff, args, clock)
    except SheriffError as error:
        print(f"sheriff: {error}", file=sys.stderr)
        return 2
    finally:
        lab.close()


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
            change = "take" if entry.is_take else f"{entry.from_state} -> {entry.to_state}"
            print(f"{entry.at}  {change:<22} {entry.actor}  {entry.reason or ''}".rstrip())
        return 0
    if command == "take":
        entry = sheriff.take(args.group, session=args.session)
    else:
        entry = sheriff.set_state(args.group, args.state, session=args.session, reason=args.reason,
                                  culprit_sha=args.culprit)
    if args.json:
        print(json.dumps(asdict(entry)))
    else:
        change = "taken" if entry.is_take else f"{entry.from_state} -> {entry.to_state}"
        print(f"group {entry.group_id}: {change} by {entry.actor} at {entry.at}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lab.py sheriff", description=__doc__.splitlines()[0])
    add_arguments(parser)
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
