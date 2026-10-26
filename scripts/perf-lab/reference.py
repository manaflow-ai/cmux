#!/usr/bin/env python3
"""The reference build series and lab drift (p12-perf-process.md 3.5, task 146).

Chrome runs a pinned reference build next to tip on the same bots (`run_reference_build` in
tools/perf/core/bot_platforms.py), so a sheriff can tell a regression in Chrome from a change in the lab:
when tip and the reference move together, the bot moved, not the code. Here:

- reference.json pins one bench artifact for a week: {sha, config, digest, week_of, pinned_by}. An operator
  re-pins it each Monday with `reference.py pin`; the pin only moves forward. A pin older than PIN_DAYS is
  stale: it still runs (a frozen artifact stays a valid baseline) and `check` exits 1 until it is re-pinned.
- The scheduler (task 011) runs the pin on each waterfall host every REFERENCE_EVERY-th T0 job, in the same
  job as tip; those results are `reference` runs, stored under the tip series' key. scheduler_reference()
  is the scheduler's `reference` input: the pin's digest.
- classify() looks at each open alert group (new, triaged, bisecting). For every regression alert it reads the
  `.ref` series of the same series on the host that measured the alert, cut into runs of one pinned artifact
  (a re-pin is not drift), and runs the same detector with the same AnomalyConfig on it. A `.ref` step in the
  regression direction whose time window overlaps the alert's is lab drift. When every alert of a group is lab
  drift, the group moves to `lab-drift` (sheriff.apply_state; a bisecting group's bisect is then cancelled by
  pinpoint_exec), routed to the lab owner in the move's reason, and each alert series gets a
  `reference_drift` annotation. A `lab-drift` group is never bisected and never gets an issue (alerts.py).
- annotate_host_changes() stores a dashboard annotation (kind note) where a host's fingerprint changed between
  two reference runs of a series, at the first tip point that host measured with the new fingerprint. A macOS
  build change needs no stored note: it is point metadata, and dashboard.derived_annotations marks it there.

The window is time, not commit position: the reference artifact never changes, so the only axis on which it
can step is when it ran.

  python3 -I scripts/perf-lab/reference.py check [--today YYYY-MM-DD]
  python3 -I scripts/perf-lab/reference.py current [--today YYYY-MM-DD]
  python3 -I scripts/perf-lab/reference.py pin --sha SHA --config bench --digest sha256:HEX --by NAME [--week-of D]
  python3 -I scripts/perf-lab/reference.py classify --db lab.sqlite [--dry-run]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sqlite3
import sys
import tempfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REFERENCE_PATH = HERE / "reference.json"
SCHEMA = "cmux-perf-reference/v1"
PIN_DAYS = 7
ACTOR = "perf-lab-reference"  # the sheriff session lab-drift moves and annotations are recorded under
# Groups that may still turn out to be lab drift: sheriff.TRANSITIONS allows new, triaged and bisecting -> lab-drift.
DRIFT_STATES = ("new", "triaged", "bisecting")
REF_HISTORY = 4  # read this many detector windows of .ref points, so a window of one pin survives a re-pin
CONFIGS = ("bench", "bench-checks", "release")  # store builds configs that alert (subscriptions.json build_configs)
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")  # perf-lab.sh --digest form


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


store_mod = _load_sibling("perf_lab_store", "store.py")
alerts = _load_sibling("perf_lab_alerts", "alerts.py")
sheriff = _load_sibling("perf_lab_sheriff", "sheriff.py")


class PinError(ValueError):
    """reference.json is missing, malformed, or a pin request breaks a rule."""


# ---------- the pin (reference.json) ----------


@dataclass(frozen=True)
class Pin:
    sha: str
    config: str
    digest: str
    week_of: date
    pinned_by: str

    def stale(self, today: date) -> bool:
        return today >= self.week_of + timedelta(days=PIN_DAYS)

    def to_json(self) -> dict[str, str]:
        return {"sha": self.sha, "config": self.config, "digest": self.digest,
                "week_of": self.week_of.isoformat(), "pinned_by": self.pinned_by}


@dataclass(frozen=True)
class ReferenceConfig:
    lab_owner: str
    pin: Pin | None
    doc: str = ""

    def problems(self, today: date) -> list[str]:
        if self.pin is None:
            return ["reference.json has no pin: no reference runs, no lab-drift checks; pin one with "
                    "`reference.py pin`"]
        if self.pin.week_of > today:
            return [f"reference.json: week_of {self.pin.week_of} is after {today}"]
        if self.pin.stale(today):
            return [f"reference.json: the pin of the week of {self.pin.week_of} is stale "
                    f"(over {PIN_DAYS} days); re-pin it this Monday"]
        return []

    def to_json(self) -> dict[str, object]:
        document: dict[str, object] = {"_doc": self.doc} if self.doc else {}
        document.update(schema=SCHEMA, lab_owner=self.lab_owner, pin=None if self.pin is None else self.pin.to_json())
        return document


def _parse_pin(raw: object) -> Pin:
    fields = ("sha", "config", "digest", "week_of", "pinned_by")
    if not isinstance(raw, dict) or set(raw) != set(fields) or not all(isinstance(raw[k], str) for k in fields):
        raise PinError(f"reference.json: pin must be null or an object of strings {list(fields)}")
    try:
        week_of = date.fromisoformat(raw["week_of"])
    except ValueError:
        raise PinError(f"reference.json: pin week_of {raw['week_of']!r} is not a YYYY-MM-DD date") from None
    pin = Pin(raw["sha"], raw["config"], raw["digest"], week_of, raw["pinned_by"].strip())
    _check_pin(pin)
    return pin


def _check_pin(pin: Pin) -> None:
    if not SHA.fullmatch(pin.sha):
        raise PinError(f"reference pin: sha {pin.sha!r} is not a full 40-hex commit")
    if pin.config not in CONFIGS:
        raise PinError(f"reference pin: config {pin.config!r} is not one of {CONFIGS}")
    if not DIGEST.fullmatch(pin.digest):
        raise PinError(f"reference pin: digest {pin.digest!r} is not sha256:<64 hex>")
    if pin.week_of.weekday() != 0:
        raise PinError(f"reference pin: week_of {pin.week_of} is not a Monday")
    if not pin.pinned_by:
        raise PinError("reference pin: pinned_by names the operator who pinned it")


def load(path: Path | str = REFERENCE_PATH) -> ReferenceConfig:
    try:
        document = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PinError(f"{path}: {error}") from None
    if (not isinstance(document, dict) or document.get("schema") != SCHEMA
            or set(document) - {"_doc", "schema", "lab_owner", "pin"}):
        raise PinError(f"{path}: expected {{schema: {SCHEMA}, lab_owner, pin}}")
    owner = document.get("lab_owner")
    if not isinstance(owner, str) or not owner.strip():
        raise PinError(f"{path}: lab_owner names the owner lab-drift groups go to")
    raw_pin = document.get("pin")
    return ReferenceConfig(owner.strip(), None if raw_pin is None else _parse_pin(raw_pin),
                           str(document.get("_doc", "")))


def monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def repin(config: ReferenceConfig, pin: Pin, today: date) -> ReferenceConfig:
    """The config with `pin` as this week's artifact. A pin never moves back or into a future week."""
    _check_pin(pin)
    if pin.week_of > monday_of(today):
        raise PinError(f"reference pin: week_of {pin.week_of} is after this week ({monday_of(today)})")
    if config.pin is not None and pin.week_of < config.pin.week_of:
        raise PinError(f"reference pin: week_of {pin.week_of} is before the current pin's {config.pin.week_of}")
    return ReferenceConfig(config.lab_owner, pin, config.doc)


def save(config: ReferenceConfig, path: Path | str = REFERENCE_PATH) -> None:
    path = Path(path)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        json.dump(config.to_json(), handle, indent=1)
        handle.write("\n")
    os.replace(handle.name, path)


@dataclass(frozen=True)
class SchedulerReference:
    digest: str | None
    problems: tuple[str, ...] = ()


def scheduler_reference(path: Path | str, now: datetime) -> SchedulerReference:
    """scheduler.plan()'s `reference` input at `now`: the pinned digest, or None with no usable pin.

    A stale pin keeps running (the series stays continuous) and says so; a file that cannot be read runs no
    reference and says why, so a bad edit never stops the lab."""
    try:
        config = load(path)
    except PinError as error:
        return SchedulerReference(None, (str(error),))
    today = now.astimezone(timezone.utc).date()
    problems = tuple(config.problems(today))
    usable = config.pin is not None and config.pin.week_of <= today
    return SchedulerReference(config.pin.digest if usable else None, problems)


# ---------- the .ref series ----------


@dataclass(frozen=True)
class RefPoint:
    """One reference run's result; samples, summary and measure_version are what alerts.judged_points reads."""

    started_at: str
    samples: list[float]
    summary: dict[str, float] | None
    measure_version: str
    artifact: tuple[str, str | None]  # (build sha, artifact digest): one pinned artifact


@dataclass(frozen=True)
class DriftWindow:
    """A .ref step: after the run at `after_start` (None: the series start), at the latest at `step_at`."""

    after_start: str | None
    step_at: str
    median_before: float
    median_after: float
    artifact: tuple[str, str | None]


def reference_points(store, series_id: int, host_name: str, limit: int) -> list[RefPoint]:
    """The newest `limit` reference runs of a series on one host, oldest first: they all measure frozen builds,
    so they go in time order (dashboard.py does the same)."""
    rows = store._db.execute(
        """SELECT u.started_at, u.measure_version, r.samples_json, r.summary_json, b.sha, b.artifact_digest
           FROM results r JOIN runs u ON u.id = r.run_id JOIN builds b ON b.id = u.build_id
           JOIN hosts h ON h.id = u.host_id
           WHERE r.series_id = ? AND u.kind = 'reference' AND h.name = ?
           ORDER BY u.started_at DESC, r.id DESC LIMIT ?""", (series_id, host_name, limit)).fetchall()
    return [RefPoint(row["started_at"], json.loads(row["samples_json"]),
                     json.loads(row["summary_json"]) if row["summary_json"] is not None else None,
                     row["measure_version"], (row["sha"], row["artifact_digest"]))
            for row in reversed(rows)]


def drift_windows(points: Sequence[RefPoint], detector, config: Mapping[str, float]) -> list[DriftWindow]:
    """The steps in each run of one artifact, over its newest detector window."""
    window = int(config.get("max_window_size", alerts.DEFAULT_MAX_WINDOW_SIZE))
    segments: list[list[RefPoint]] = []
    for point in alerts.judged_points(points):
        if segments and segments[-1][-1].artifact == point.artifact:
            segments[-1].append(point)
        else:
            segments.append([point])
    found = []
    for segment in segments:
        segment = segment[-window:]
        values = [alerts.point_stat(point.samples, "p50") for point in segment]
        for change in detector.change_points(values, config):
            start = min(max(change.extended_start, 0), len(segment) - 1)
            end = min(max(change.extended_end, start), len(segment) - 1)
            found.append(DriftWindow(segment[start - 1].started_at if start > 0 else None, segment[end].started_at,
                                     change.median_before, change.median_after, segment[0].artifact))
    return found


@dataclass(frozen=True)
class AlertWindow:
    host_name: str
    after_start: str | None  # the newest waterfall run before the alert range
    step_at: str  # the first waterfall run at or after the range's end


def alert_window(store, series_id: int, start_pos: int, end_pos: int) -> AlertWindow | None:
    """When the alert's step happened, as the start times of the waterfall points around it; None when the
    point at the range's end is not stored."""
    db = store._db
    base = """SELECT u.started_at, h.name FROM results r JOIN runs u ON u.id = r.run_id
              JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
              WHERE r.series_id = ? AND u.kind = 'waterfall' AND """
    after = db.execute(base + "b.commit_pos >= ? ORDER BY b.commit_pos, u.started_at, r.id LIMIT 1",
                       (series_id, end_pos)).fetchone()
    if after is None:
        return None
    before = db.execute(base + "b.commit_pos < ? ORDER BY b.commit_pos DESC, u.started_at DESC, r.id DESC LIMIT 1",
                        (series_id, start_pos)).fetchone()
    return AlertWindow(after["name"], None if before is None else before["started_at"], after["started_at"])


def overlaps(alert: AlertWindow, drift: DriftWindow) -> bool:
    """(alert.after_start, alert.step_at] and (drift.after_start, drift.step_at] share a moment."""
    return ((drift.after_start is None or drift.after_start < alert.step_at)
            and (alert.after_start is None or alert.after_start < drift.step_at))


def series_config(subscriptions, floors, series) -> dict[str, float]:
    """The AnomalyConfig alerts.detect uses for the tip series; the .ref series is judged by the same one."""
    subscription = subscriptions.match(series)
    config = dict(subscription.anomaly_config) if subscription is not None else {}
    floor = floors(series) if floors is not None else None
    if floor is not None:
        config["min_absolute_change"] = max(floor, config.get("min_absolute_change", floor))
    return config


def alert_drift(store, alert, detector, config: Mapping[str, float]) -> DriftWindow | None:
    """The .ref step that explains a regression alert: same host, overlapping window, regression direction."""
    window = alert_window(store, alert.series.id, alert.start_pos, alert.end_pos)
    if window is None:
        return None
    limit = REF_HISTORY * int(config.get("max_window_size", alerts.DEFAULT_MAX_WINDOW_SIZE))
    for drift in drift_windows(reference_points(store, alert.series.id, window.host_name, limit), detector, config):
        if (drift.median_before != drift.median_after and overlaps(window, drift)
                and alerts.is_regression(alert.series.better, drift.median_before, drift.median_after)):
            return drift
    return None


# ---------- classify ----------


@dataclass
class ClassifyReport:
    groups: int = 0
    lab_drift: list[int] = field(default_factory=list)
    annotations: int = 0
    problems: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def classify(store, subscriptions, detector, *, lab_owner: str, floors=None,
             clock: Callable[[], datetime] | None = None) -> ClassifyReport:
    """Moves each open group whose every regression alert is lab drift to `lab-drift`; run it after
    alerts.detect and before pinpoint_exec starts bisects."""
    report = ClassifyReport()
    marks = ",".join("?" * len(DRIFT_STATES))
    groups = store._db.execute(f"SELECT id FROM alert_groups WHERE state IN ({marks}) ORDER BY id",
                               DRIFT_STATES).fetchall()
    actor = sheriff.Sheriff(store, session=ACTOR, lead_session=None, clock=clock or store._clock)
    for group in groups:
        report.groups += 1
        members = alerts.group_alerts(store, group["id"])
        drifts = [alert_drift(store, alert, detector, series_config(subscriptions, floors, alert.series))
                  for alert in members]
        if not members or None in drifts:
            continue
        try:
            store._write(lambda: _mark(store, actor, group["id"], members, drifts, lab_owner))
        except sheriff.SheriffError as error:
            report.problems.append(f"group {group['id']}: lab drift, not moved: {error}")
            continue
        report.lab_drift.append(group["id"])
        report.annotations += len(members)
    return report


def _mark(store, actor, group_id: int, members, drifts: Sequence[DriftWindow], lab_owner: str) -> None:
    top, drift = members[0], drifts[0]
    unit = top.series.unit
    actor.apply_state(group_id, "lab-drift", reason=(
        f"lab drift: the reference artifact {drift.artifact[0][:12]} moved {drift.median_before:.4g} -> "
        f"{drift.median_after:.4g} {unit} in the window of {top.series.story} {top.series.metric} "
        f"({top.series.host_class}) and of all {len(members)} alerts; routed to {lab_owner}, not bisected"))
    now = store._now()
    for alert, window in zip(members, drifts):
        store._db.execute(
            """INSERT INTO annotations (series_id, kind, start_pos, end_pos, text, created_by, created_at)
               VALUES (?, 'reference_drift', ?, ?, ?, ?, ?)""",
            (alert.series.id, alert.start_pos, alert.end_pos,
             f"reference {window.artifact[0][:12]}: {window.median_before:.4g} -> {window.median_after:.4g} "
             f"{alert.series.unit}; group {group_id} lab-drift ({lab_owner})", ACTOR, now))


# ---------- host changes ----------


_HOST_CHANGES = """
SELECT * FROM (
  SELECT r.series_id, h.name AS host_name, h.fingerprint,
         LAG(h.fingerprint) OVER w AS prev_fingerprint, LAG(u.started_at) OVER w AS prev_started_at
  FROM results r JOIN runs u ON u.id = r.run_id JOIN hosts h ON h.id = u.host_id
  WHERE u.kind = 'reference'
  WINDOW w AS (PARTITION BY r.series_id, h.name ORDER BY u.started_at, r.id))
WHERE prev_fingerprint IS NOT NULL AND prev_fingerprint != fingerprint
ORDER BY series_id, prev_started_at"""

# The first tip point of the series on that host, after the older reference run, with the new fingerprint.
_FIRST_TIP_WITH = """
SELECT b.commit_pos FROM results r JOIN runs u ON u.id = r.run_id JOIN builds b ON b.id = u.build_id
JOIN hosts h ON h.id = u.host_id
WHERE r.series_id = ? AND u.kind = 'waterfall' AND h.name = ? AND h.fingerprint = ? AND u.started_at > ?
ORDER BY u.started_at, r.id LIMIT 1"""


def annotate_host_changes(store) -> int:
    """A note annotation for each host fingerprint change between two reference runs of a series on one host,
    at the first tip point measured with the new fingerprint; returns how many it added (a stored one is not
    added again)."""
    def write() -> int:
        db, now, added = store._db, store._now(), 0
        for row in db.execute(_HOST_CHANGES).fetchall():
            tip = db.execute(_FIRST_TIP_WITH, (row["series_id"], row["host_name"], row["fingerprint"],
                                               row["prev_started_at"])).fetchone()
            if tip is None:
                continue
            text = (f"reference on {row['host_name']}: host fingerprint "
                    f"{row['prev_fingerprint'][:12]} -> {row['fingerprint'][:12]}")
            values = (row["series_id"], "note", tip["commit_pos"], tip["commit_pos"], text, ACTOR)
            if db.execute("""SELECT 1 FROM annotations WHERE series_id = ? AND kind = ? AND start_pos = ?
                             AND end_pos = ? AND text = ? AND created_by = ?""", values).fetchone():
                continue
            db.execute("""INSERT INTO annotations (series_id, kind, start_pos, end_pos, text, created_by, created_at)
                          VALUES (?, ?, ?, ?, ?, ?, ?)""", (*values, now))
            added += 1
        return added

    return store._write(write)


# ---------- CLI ----------


def utc_today() -> date:
    return datetime.now(timezone.utc).date()


def main(argv: Sequence[str] | None = None, *, detector=None, floors=None, out=None, err=None) -> int:
    out, err = out or sys.stdout, err or sys.stderr
    parser = argparse.ArgumentParser(prog="reference.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--file", type=Path, default=REFERENCE_PATH, help="the reference file")
    parser.add_argument("--subscriptions", type=Path, default=alerts.DEFAULT_SUBSCRIPTIONS)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, text in (("check", "exit 1 when the pin is missing, stale or malformed"),
                       ("current", "print the pinned digest the scheduler runs (nothing without a usable pin)")):
        command = commands.add_parser(name, help=text)
        command.add_argument("--today", type=date.fromisoformat)
    pin_cmd = commands.add_parser("pin", help="pin this week's reference artifact (operator, Mondays)")
    pin_cmd.add_argument("--sha", required=True)
    pin_cmd.add_argument("--config", default="bench", choices=CONFIGS)
    pin_cmd.add_argument("--digest", required=True, help="sha256:<hex> from perf-lab-build.sh")
    pin_cmd.add_argument("--by", required=True, help="the operator pinning it")
    pin_cmd.add_argument("--week-of", type=date.fromisoformat, help="a Monday (default: this week's)")
    pin_cmd.add_argument("--today", type=date.fromisoformat)
    classify_cmd = commands.add_parser("classify", help="host-change annotations, then lab-drift groups")
    classify_cmd.add_argument("--db", type=Path, required=True)
    classify_cmd.add_argument("--dry-run", action="store_true", help="run on a copy of the store")
    args = parser.parse_args(argv)

    try:
        config = load(args.file)
        if args.command in ("check", "current"):
            today = args.today or utc_today()
            problems = config.problems(today)
            if args.command == "current":
                if config.pin is not None and config.pin.week_of <= today:
                    print(config.pin.digest, file=out)
                for problem in problems:
                    print(f"reference.py: {problem}", file=err)
                return 0
            for problem in problems:
                print(f"reference.py: {problem}", file=err)
            if not problems:
                print(f"reference ok: {config.pin.sha[:12]} ({config.pin.config}) week of {config.pin.week_of}",
                      file=out)
            return 1 if problems else 0
        if args.command == "pin":
            today = args.today or utc_today()
            pin = Pin(args.sha.strip().lower(), args.config, args.digest.strip().lower(),
                      args.week_of or monday_of(today), args.by.strip())
            save(repin(config, pin, today), args.file)
            print(f"pinned {pin.sha[:12]} ({pin.config}) for the week of {pin.week_of}; commit {args.file.name}",
                  file=out)
            return 0
        subscriptions = alerts.Subscriptions.load(args.subscriptions)
        with tempfile.TemporaryDirectory(prefix="perf-lab-reference-") as scratch:
            store = alerts._open(args.db, Path(scratch) if args.dry_run else None)
            try:
                added = annotate_host_changes(store)
                report = classify(store, subscriptions, detector or alerts.CatapultDetector(),
                                  lab_owner=config.lab_owner, floors=floors or alerts.load_floors())
            finally:
                store.close()
        print(json.dumps({"dry_run": args.dry_run, "host_change_annotations": added, **report.to_dict()}, indent=2),
              file=out)
        return 0
    except (PinError, alerts.AlertsError, store_mod.StoreError, sqlite3.Error) as error:
        print(f"reference.py: {error}", file=err)
        return 1


if __name__ == "__main__":
    sys.exit(main())
