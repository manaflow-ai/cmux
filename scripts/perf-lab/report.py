#!/usr/bin/env python3
"""The weekly perf report (p12-perf-process-131): one Markdown document for the Performance Lead.

    python3 -I scripts/perf-lab/lab.py report --week [--db PATH] [--json | --append plans/cmux-next/perf-lead.md]

Sections, all over the 7 days that end at the report's clock:

- Targets: one table row per (target row, check, claiming series), the check's statistic at the start of the week
  and at its end. A series feeds a row exactly as on the dashboard's target tiles (dashboard.build_tiles), and the
  value at a bound is the newest waterfall point that started at or before it. A row whose series is older than
  dashboard.TILE_STALE_AFTER at a bound is stale there, never a pass or a miss; that holds for a series the tiles
  hide at one bound because a current sibling feeds the check (host classes that rotate in the week).
- Alert groups: every group opened or moved in the week or still open at its end, its state at the end of the
  week from the sheriff history, and the outcome counts.
- Sheriff SLO: sheriff.Sheriff.slo over groups opened in the week.
- A/A noise: aa.report over the week, and the noisiest series beyond done check 9's CV limits.

Catapult's Speed Releasing page is the model for the targets table (`dashboard/dashboard/speed_releasing.py`:
one row per test, its value at two revision ranges side by side). The report reads the store only; `--append`
writes the report into section 5 (Results log) of perf-lead.md, before the next `## ` heading, and refuses a
second report of the same ISO week (the week of the window's end) there.

Stdlib only; siblings load by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sqlite3
import sys
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import TextIO
from urllib.parse import quote

HERE = Path(__file__).resolve().parent


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[module_name]
        raise
    return module


store = _load_sibling("store")
dashboard = _load_sibling("dashboard")
sheriff = _load_sibling("sheriff")
aa = _load_sibling("aa")

LAB_COMMANDS = {"report": "Weekly perf report in Markdown (--week): each target at the start and end of the week, "
                          "alert groups and outcomes, sheriff SLO, A/A noise; --append adds it to perf-lead.md 5."}
DB_ENV = "CMUX_PERF_LAB_DB"
WEEK = timedelta(days=7)
NOISY_LIMIT = 10
RESULTS_SECTION = re.compile(r"^## 5\.")
TOP_HEADING = re.compile(r"^## ")


class ReportError(RuntimeError):
    """A report that cannot be made or written; the message says why."""


@dataclass(frozen=True)
class Window:
    start: datetime
    end: datetime

    @property
    def week(self) -> str:
        """The ISO week of the window's end, for example 2026-W44: one weekly report per week in the log."""
        year, week, _ = self.end.isocalendar()
        return f"{year}-W{week:02d}"

    @property
    def title(self) -> str:
        return f"{week_heading(self.week)} {self.start:%Y-%m-%d %H:%M} to {self.end:%Y-%m-%d %H:%M} UTC"


def week_heading(week: str) -> str:
    """The start of a weekly report's heading, the same for every report of that ISO week."""
    return f"Weekly perf report {week},"


@dataclass(frozen=True)
class TargetLine:
    target: str
    row: str
    check: str
    series: str | None  # the series key
    series_name: str | None  # story, metric and host class, as the dashboard lists a series
    start: float | None
    end: float | None
    unit: str
    start_status: str  # pass | miss | stale | no-data
    end_status: str


@dataclass(frozen=True)
class GroupLine:
    id: int
    opened: str
    stories: tuple[str, ...]
    start_pos: int
    end_pos: int
    regressions: int
    improvements: int
    moves: tuple[str, ...]  # "from -> to" for each move in the week, oldest first
    state: str  # at the end of the week
    culprit: str | None
    culprit_verified: bool
    issue: int | None
    reason: str | None


@dataclass(frozen=True)
class WeeklyReport:
    window: Window
    targets: tuple[TargetLine, ...]
    targets_problem: str | None
    catalog_problems: int
    groups: tuple[GroupLine, ...]
    outcomes: dict[str, int]  # state at the end of the week -> groups
    closed: dict[str, int]  # terminal state reached in the week -> groups
    slo: dict
    aa: dict
    noisy: tuple[dict, ...]

    def to_json(self) -> dict:
        found = asdict(self)
        found["window"] = {"start": _stamp(self.window.start), "end": _stamp(self.window.end),
                           "week": self.window.week}
        return found


def _stamp(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


# ---------- reading the store ----------

_POINTS_AT_SQL = """
SELECT * FROM (
  SELECT s.series_key, b.commit_pos, b.sha, u.started_at, r.samples_json, r.summary_json,
         u.features_hash, u.macos_build, u.safe_mode, h.name AS host_name,
         ROW_NUMBER() OVER (PARTITION BY r.series_id ORDER BY {order}) AS rn
  FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
  JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
  WHERE u.kind = 'waterfall' AND u.started_at <= ? AND s.series_key IN ({keys}))
WHERE rn = 1 ORDER BY series_key"""


@dataclass(frozen=True)
class PointAt:
    view: object  # dashboard.PointView
    samples: tuple[float, ...]

    def stat(self, name: str) -> float | None:
        if self.samples:
            return dashboard.sample_stat(self.samples, name)
        return self.view.stat(name)  # a legacy point keeps only its summary's p50 and p99


class WeekReader:
    """Read-only queries over the lab store for one report, through its own connection."""

    def __init__(self, db_path: Path) -> None:
        if not db_path.is_file():
            raise ReportError(f"{db_path}: no lab store there; labd creates it")
        self._db = sqlite3.connect(f"file:{quote(str(db_path.resolve()))}?mode=ro", uri=True)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA query_only=ON")

    def close(self) -> None:
        self._db.close()

    def series(self) -> list:
        return [dashboard._series_info(row)
                for row in self._db.execute("SELECT * FROM series ORDER BY story, metric, series_key")]

    def points_at(self, keys: Sequence[str], bound: datetime) -> dict[str, PointAt]:
        """Each series' newest waterfall point (store order: commit position, start time, row id) started at or
        before `bound`."""
        if not keys:
            return {}
        sql = _POINTS_AT_SQL.format(order=dashboard._WATERFALL_ORDER, keys=",".join("?" * len(keys)))
        found = {}
        for row in self._db.execute(sql, [_stamp(bound), *keys]):
            samples = tuple(float(v) for v in json.loads(row["samples_json"])
                            if isinstance(v, (int, float)) and not isinstance(v, bool))
            found[row["series_key"]] = PointAt(dashboard._point(row), samples)
        return found

    def groups(self, window: Window) -> list[GroupLine]:
        """Every group opened or moved in the week or still open at its end, with its state at the end."""
        start, end = _stamp(window.start), _stamp(window.end)
        rows = self._db.execute("SELECT * FROM alert_groups WHERE created_at <= ? ORDER BY created_at, id",
                                (end,)).fetchall()
        lines = []
        for row in rows:
            history = self._db.execute(
                "SELECT from_state, to_state, at FROM sheriff_history WHERE group_id = ? AND at <= ? ORDER BY at, id",
                (row["id"], end)).fetchall()
            alerts = self._db.execute(
                """SELECT s.story, a.is_improvement FROM alerts a JOIN series s ON s.id = a.series_id
                   WHERE a.group_id = ? AND a.created_at <= ?""", (row["id"], end)).fetchall()
            moves = tuple(f"{h['from_state']} -> {h['to_state']}" for h in history
                          if h["from_state"] is not None and h["at"] >= start)
            state = history[-1]["to_state"] if history else "new"
            if row["created_at"] < start and not moves and state in sheriff.TERMINAL:
                continue  # closed before the week
            lines.append(GroupLine(
                id=row["id"], opened=row["created_at"], stories=tuple(sorted({a["story"] for a in alerts})),
                start_pos=row["start_pos"], end_pos=row["end_pos"],
                regressions=sum(not a["is_improvement"] for a in alerts),
                improvements=sum(bool(a["is_improvement"]) for a in alerts),
                moves=moves, state=state,
                culprit=row["culprit_sha"], culprit_verified=bool(row["culprit_verified"]),
                issue=row["issue_number"], reason=row["reason"]))
        return lines


# ---------- building the report ----------


def _series_name(story: str, metric: str, host_class: str) -> str:
    return f"{story} {metric} on {host_class}"


def target_lines(targets: Sequence, series: Sequence, reader: WeekReader, window: Window) -> list[TargetLine]:
    """The targets table: the dashboard's tiles at the end of the week, with each row's value at its start."""
    keys = sorted({info.key for target in targets for row in target.rows for info in series
                   if dashboard.judged_checks(row, info)})

    def tiles_at(bound: datetime) -> tuple[list, dict[str, PointAt]]:
        points = reader.points_at(keys, bound)
        return dashboard.build_tiles(targets, series, {key: p.view for key, p in points.items()},
                                     lambda key, stat: points[key].stat(stat), set(),
                                     fresh_since=bound - dashboard.TILE_STALE_AFTER), points

    def key(tile_row) -> tuple:
        return tile_row.row.id, tile_row.check, tile_row.series.key if tile_row.series else None

    def hidden(shown_row, points: dict[str, PointAt], bound: datetime) -> tuple[float | None, str]:
        """The value and status at a bound whose tiles hide this row's series (a current sibling feeds the
        check): the series' own point at that bound, judged by the same staleness rule."""
        point = points.get(shown_row.series.key) if shown_row.series else None
        value = point.stat(shown_row.check.stat) if point else None
        if value is None:
            return None, "no-data"
        if dashboard.parse_stamp(point.view.started_at) < bound - dashboard.TILE_STALE_AFTER:
            return value, "stale"
        check = shown_row.check
        return value, "pass" if dashboard.catalog.OPS[check.op](value, check.value) else "miss"

    (start_tiles, start_points), (end_tiles, end_points) = tiles_at(window.start), tiles_at(window.end)
    lines = []
    for start_tile, end_tile in zip(start_tiles, end_tiles):
        at_start = {key(row): row for row in start_tile.rows}
        shown = [(at_start.pop(key(row), None), row) for row in end_tile.rows]
        shown += [(row, None) for row in at_start.values() if row.series is not None]
        for first, last in shown:
            either = last or first
            check = either.check
            start, start_status = ((first.value, first.status) if first
                                   else hidden(last, start_points, window.start))
            end, end_status = (last.value, last.status) if last else hidden(first, end_points, window.end)
            lines.append(TargetLine(
                target=end_tile.target.id, row=either.row.id,
                check=f"`{check.metric}` {check.stat} {check.op} {dashboard.fmt_value(check.value, check.unit)}",
                series=either.series.key if either.series else None,
                series_name=_series_name(either.series.story, either.series.metric, either.series.host_class)
                if either.series else None,
                start=start, end=end, unit=check.unit, start_status=start_status, end_status=end_status))
    return lines


def build_report(*, reader: WeekReader, lab: store.Store, db_path: Path, targets: Sequence | None,
                 targets_problem: str | None, catalog_problems: int, clock: Callable[[], datetime],
                 detector, configs) -> WeeklyReport:
    end = clock().astimezone(timezone.utc)
    window = Window(end - WEEK, end)
    lines = target_lines(targets, reader.series(), reader, window) if targets is not None else []
    groups = reader.groups(window)
    # A closed group never moves again, so a closed group with a move in the week closed in the week.
    closed = Counter(line.state for line in groups if line.state in sheriff.TERMINAL and line.moves)
    slo = sheriff.Sheriff(lab, session=None, lead_session=None, clock=lambda: end).slo(window.start)
    try:
        noise = aa.report(aa.pair_runs(aa.read_aa_runs(db_path, window.start)), since=window.start,
                          configs=configs, detector=detector, host_runs=aa.read_host_runs(db_path, window.start))
    except aa.AAError as error:
        raise ReportError(f"A/A: {error}") from error
    noisy = aa.noisy(noise["series"], cv_over=aa.DONE_MEDIAN_CV, p99_cv_over=aa.DONE_P99_CV)[:NOISY_LIMIT]
    return WeeklyReport(
        window=window, targets=tuple(lines), targets_problem=targets_problem, catalog_problems=catalog_problems,
        groups=tuple(groups), outcomes=dict(sorted(Counter(line.state for line in groups).items())),
        closed=dict(sorted(closed.items())), slo=slo, aa=noise["summary"], noisy=tuple(noisy))


# ---------- Markdown ----------


def _cell(value: object) -> str:
    text = "-" if value is None or value == "" else str(value)
    return " ".join(text.split()).replace("|", "\\|")


def _table(header: Sequence[str], rows: Sequence[Sequence[object]]) -> list[str]:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(_cell(value) for value in row) + " |" for row in rows]
    return out


def _value(value: float | None, unit: str, status: str) -> str:
    shown = "-" if value is None else dashboard.fmt_value(value, unit)
    return f"{shown} ({status})"


def _share_text(value: float | None) -> str:
    return "-" if value is None else f"{100 * value:.1f} %"


def _ok(passed: bool) -> str:
    return "ok" if passed else "MISSED"


def render_markdown(report: WeeklyReport) -> str:
    out = [f"### {report.window.title}", ""]

    out += ["#### Targets", ""]
    if report.targets_problem:
        out += [f"Targets not loaded: {_cell(report.targets_problem)}", ""]
    else:
        end_status = Counter(line.end_status for line in report.targets)
        summary = ", ".join(f"{status} {end_status[status]}" for status in ("pass", "miss", "stale", "no-data")
                            if end_status[status])
        out += [f"Checks at the end of the week: {len(report.targets)} ({summary or 'none'})."
                + (f" Catalog lint problems: {report.catalog_problems}." if report.catalog_problems else ""),
                ""]
        out += _table(("Target", "Row", "Check", "Series", "Start", "End"),
                      [(line.target, line.row, line.check, line.series_name,
                        _value(line.start, line.unit, line.start_status), _value(line.end, line.unit, line.end_status))
                       for line in report.targets])
        out.append("")

    out += ["#### Alert groups", ""]
    if report.groups:
        outcomes = ", ".join(f"{state} {count}" for state, count in report.outcomes.items())
        closed = ", ".join(f"{state} {count}" for state, count in report.closed.items()) or "none"
        out += [f"Groups opened, moved or open in the week: {len(report.groups)}. State at the end: {outcomes}. "
                f"Closed in the week: {closed}.", ""]
        out += _table(("Group", "Opened", "Stories", "Range", "Alerts", "Moves in the week", "State", "Culprit",
                       "Issue", "Reason"),
                      [(f"#{g.id}", g.opened[:16].replace("T", " "), ", ".join(g.stories), f"{g.start_pos}-{g.end_pos}",
                        f"regressions {g.regressions}, improvements {g.improvements}", "; ".join(g.moves), g.state,
                        f"{g.culprit[:10]} ({'verified' if g.culprit_verified else 'unverified'})" if g.culprit
                        else None, f"#{g.issue}" if g.issue else None, g.reason)
                       for g in report.groups])
    else:
        out.append("No alert group was opened, moved or open in the week.")
    out.append("")

    slo = report.slo
    triage, culprit, fix = slo["triage"], slo["culprit"], slo["fix"]
    stale = ", ".join(f"#{row['group']} {row['state']} {row['age_hours']} h" for row in slo["stale"])
    out += ["#### Sheriff SLO", "",
            f"Groups opened in the week: {slo['groups']}. {'PASS' if slo['pass'] else 'FAIL'}.", ""]
    out += _table(("SLO", "Result", "Numbers"), [
        ("triage <= 1 h", _ok(triage["ok"]),
         f"{_share_text(None if triage['pct'] is None else triage['pct'] / 100)} met; met {len(triage['met'])}, "
         f"missed {len(triage['missed'])}, pending {len(triage['pending'])}"),
        ("culprit <= 4 h (median)", _ok(culprit["ok"]),
         f"median {'-' if culprit['median_hours'] is None else culprit['median_hours']} h; reached "
         f"{len(culprit['reached'])}, overdue {len(culprit['overdue'])}, pending {len(culprit['pending'])}"),
        ("fix or flag-off <= 12 h", _ok(fix["ok"]),
         f"{_share_text(None if fix['pct'] is None else fix['pct'] / 100)} met; met {len(fix['met'])}, "
         f"missed {len(fix['missed'])}, pending {len(fix['pending'])}"),
        ("none older than 12 h before assigned", _ok(not slo["stale"]), stale or "none"),
    ])
    out.append("")

    noise = report.aa
    checks = noise["checks"]
    per_100 = noise["false_alerts_per_100_series_days"]
    out += ["#### A/A noise", "",
            f"Monitored series: {noise['series']}, series-days: {noise['series_days']}, "
            f"waterfall hosts: {len(noise['waterfall_hosts'])}.", ""]
    out += _table(("Check", "Result", "Numbers"), [
        (f"false alerts <= {aa.DONE_FALSE_ALERTS_PER_100:g} per 100 series-days", _ok(checks["false_alerts"]),
         f"{'-' if noise['false_alerts'] is None else noise['false_alerts']} false alerts, "
         f"{'-' if per_100 is None else f'{per_100:.2f}'} per 100"),
        (f"median CV <= {_share_text(aa.DONE_MEDIAN_CV)} on >= {_share_text(aa.DONE_MEDIAN_SHARE)} of latency series",
         _ok(checks["median_cv"]), f"{_share_text(noise['median_cv_share_within'])} of {noise['latency_series_judged']}"),
        (f"p99 CV <= {_share_text(aa.DONE_P99_CV)} on >= {_share_text(aa.DONE_P99_SHARE)} of latency series",
         _ok(checks["p99_cv"]), f"{_share_text(noise['p99_cv_share_within'])} of {noise['latency_series_judged']}"),
        (f">= {aa.DONE_MIN_AA_RUNS_PER_HOST} A/A runs per waterfall host", _ok(checks["aa_runs_per_host"]),
         (", ".join(noise["hosts_under_min_aa_runs"]) or "every host") if noise["waterfall_hosts"]
         else "no waterfall host in the week"),
    ])
    out.append("")
    if report.noisy:
        out += [f"Noisiest series (median CV over {_share_text(aa.DONE_MEDIAN_CV)} or p99 CV over {_share_text(aa.DONE_P99_CV)}):",
                ""]
        out += _table(("Series", "Pairs", "Median CV", "p99 CV"),
                      [(_series_name(row["story"], row["metric"], row["host_class"]), row["pairs"],
                        _share_text(row["cv_median"]), _share_text(row["cv_p99"]))
                       for row in report.noisy])
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def append_to_results(path: Path, markdown: str, week: str) -> None:
    """Writes the report as the last subsection of section 5 (Results log); refuses it when section 5 already has
    a report of the same ISO week."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        raise ReportError(f"{path}: no such file") from None
    section = next((index for index, line in enumerate(lines) if RESULTS_SECTION.match(line)), None)
    if section is None:
        raise ReportError(f"{path}: no '## 5.' Results log section")
    heading_at = next((index for index in range(section + 1, len(lines)) if TOP_HEADING.match(lines[index])),
                      len(lines))
    same_week = f"### {week_heading(week)}"
    already = next((line for line in lines[section + 1:heading_at] if line.startswith(same_week)), None)
    if already is not None:
        raise ReportError(f"{path} already has the report of {week}: {already!r}")
    end = heading_at
    while end > section + 1 and not lines[end - 1].strip():
        end -= 1
    block = ["", *markdown.splitlines()] + ([""] if heading_at < len(lines) else [])
    updated = lines[:end] + block + lines[heading_at:]
    temporary = path.with_name(f".{path.name}.report-tmp")
    temporary.write_text("\n".join(updated) + "\n", encoding="utf-8")
    temporary.replace(path)


# ---------- CLI ----------


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    """lab.py's command hook (task 005): the arguments of `lab.py report`."""
    window = parser.add_mutually_exclusive_group(required=True)
    window.add_argument("--week", action="store_true", help="the 7 days that end now")
    parser.add_argument("--db", default=os.environ.get(DB_ENV), help=f"the lab SQLite store (default: ${DB_ENV})")
    parser.add_argument("--root", type=Path, default=dashboard.catalog.REPO_ROOT,
                        help="the repository whose targets.json and stories.d define the targets")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="print the report as JSON")
    output.add_argument("--append", type=Path, metavar="PERF_LEAD_MD",
                        help="add the report to section 5 (Results log) of this file, for example "
                             "plans/cmux-next/perf-lead.md")


def weekly_report(args: argparse.Namespace, *, clock: Callable[[], datetime] = store.utc_now,
                  targets_loader: Callable[[Path], tuple] = dashboard.load_targets, detector=None, configs=None,
                  out: TextIO | None = None) -> int:
    """`lab.py report` with its seams injected; raises ReportError on a missing store or an unwritable file."""
    out = out or sys.stdout
    if not args.db:
        raise ReportError(f"no lab store: pass --db or set {DB_ENV}")
    db_path = Path(args.db)
    targets, problem, problems = None, None, ()
    try:
        loaded, problems = targets_loader(args.root)
        targets = list(loaded)
    except dashboard.DashboardError as error:
        problem = str(error)
    try:
        detector = detector or aa.catapult_detector()
        configs = configs or aa.subscription_configs()
    except aa.AAError as error:
        raise ReportError(f"A/A: {error}") from error
    reader = WeekReader(db_path)
    try:
        lab = sheriff.open_store(db_path, clock)
        try:
            report = build_report(reader=reader, lab=lab, db_path=db_path, targets=targets, targets_problem=problem,
                                  catalog_problems=len(problems), clock=clock, detector=detector, configs=configs)
        finally:
            lab.close()
    except (sheriff.SheriffError, store.StoreError, sqlite3.Error) as error:
        raise ReportError(str(error)) from error
    finally:
        reader.close()
    if args.json:
        json.dump(report.to_json(), out, indent=2, sort_keys=True)
        out.write("\n")
        return 0
    markdown = render_markdown(report)
    if args.append is not None:
        append_to_results(args.append, markdown, report.window.week)
        print(f"added {report.window.title!r} to {args.append}", file=out)
        return 0
    out.write(markdown)
    return 0


def run(command: str, args: argparse.Namespace) -> int:
    """lab.py's command hook (task 005): runs `lab.py report`; a refused report exits 2."""
    try:
        return weekly_report(args)
    except (ReportError, OSError) as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="report.py", description=LAB_COMMANDS["report"])
    add_arguments("report", parser)
    return run("report", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
