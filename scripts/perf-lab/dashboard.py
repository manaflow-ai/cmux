#!/usr/bin/env python3
"""The perf lab dashboard: server-rendered HTML with inline SVG, no script, no fetches.

Chromeperf's pages (catapult `dashboard/dashboard/elements/`: the report page, chart-section with
its sparkline-compound, alerts-page with alert groups, and the Pinpoint job page with trace links)
are the model. labd (task 012) serves `Dashboard.route(path)`; this module only reads.

Pages:
  /                 12 target tiles (latest p50/p99 vs target, hz=120 rows only) and every series
                    with a sparkline, its change points and annotations
  /series/<key>     one series: p50 and p99 per point, target limits, change points, annotations
                    (features hash, macOS build, .ref drift) and a table view
  /alerts           alert groups and their alerts
  /jobs             Pinpoint jobs (bisect, verify, try, A/A, reference) with trace links
  /coverage         per target: matched series and newest point; per story: newest run, runs in 24 h
  /field, /stability  report tables from injected field and stability sources (tasks 042, 225)

Every page carries a Content-Security-Policy of `default-src 'none'` and has no src, link,
script or url(): a rendered page makes 0 network fetches. Hover detail is SVG <title>; every
chart has a table view. Colors are the dataviz reference palette (categorical slots 1 and 2,
status good/critical with an icon and a label, never color alone), light and dark.

  python3 scripts/perf-lab/dashboard.py render --db LAB.sqlite [--targets targets.json] [--path /]
"""
from __future__ import annotations

import argparse
import fnmatch
import html
import importlib.util
import json
import math
import re
import sqlite3
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, unquote

HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load("perf_lab_perf_stats", "perf_stats.py")

# catapult dashboard/common/defaults.py MAX_WINDOW_SIZE: the detector sees the newest 50 points.
MAX_WINDOW_SIZE = 50
# Frame targets are judged only from 120 Hz hosts (p12-perf-process.md 3.1, task 160).
TILE_HZ = 120
CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'"
STATS = ("p50", "p99")


class DashboardError(ValueError):
    pass


# ---------- targets ----------


@dataclass(frozen=True)
class Limit:
    stat: str
    op: str
    value: float

    def holds(self, measured: float) -> bool:
        return _OPS[self.op](measured, self.value)

    def label(self) -> str:
        return f"{self.stat} {_OP_TEXT[self.op]} {fmt(self.value)}"


_OPS: dict[str, Callable[[float, float], bool]] = {
    "<=": lambda a, b: a <= b, "<": lambda a, b: a < b,
    ">=": lambda a, b: a >= b, ">": lambda a, b: a > b, "==": lambda a, b: a == b,
}
_OP_TEXT = {"<=": "≤", "<": "<", ">=": "≥", ">": ">", "==": "="}


@dataclass(frozen=True)
class TargetRow:
    """One judged row of a target: series patterns ("story/metric" globs), an engine, its limits."""

    series: tuple[str, ...]
    limits: tuple[Limit, ...]
    engine: str | None = None


@dataclass(frozen=True)
class Target:
    id: str
    title: str
    unit: str
    rows: tuple[TargetRow, ...]
    hz: int | None = TILE_HZ


def load_targets(doc: dict) -> list[Target]:
    """The dashboard's read of targets.json (task 007).

    {"targets": [{"id", "title", "unit", "hz"?: 120 | null,
                  "rows": [{"engine"?, "series": ["story/metric" glob, ...],
                            "limits": [{"stat": "p50", "op": "<=", "value": 8.3}, ...]}]}]}
    A target without "rows" is one row from its own "series", "limits" and "engine".
    """
    targets = doc.get("targets") if isinstance(doc, dict) else None
    if not isinstance(targets, list):
        raise DashboardError("targets.json: 'targets' must be a list")
    out = []
    for index, entry in enumerate(targets):
        where = f"targets[{index}]"
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise DashboardError(f"{where}: needs a string id")
        rows = entry.get("rows", [entry])
        if not isinstance(rows, list) or not rows:
            raise DashboardError(f"{where} ({entry['id']}): rows must be a non-empty list")
        out.append(Target(
            id=entry["id"], title=str(entry.get("title", entry["id"])), unit=str(entry.get("unit", "")),
            hz=entry.get("hz", TILE_HZ), rows=tuple(_target_row(f"{where}.rows[{i}]", row) for i, row in enumerate(rows))))
    return out


def _target_row(where: str, row: object) -> TargetRow:
    if not isinstance(row, dict):
        raise DashboardError(f"{where}: must be an object")
    series, limits = row.get("series", []), row.get("limits", [])
    if not isinstance(series, list) or not all(isinstance(item, str) for item in series):
        raise DashboardError(f"{where}: series must be a list of 'story/metric' globs")
    if not isinstance(limits, list) or not limits:
        raise DashboardError(f"{where}: needs at least one limit")
    parsed = []
    for limit in limits:
        if not isinstance(limit, dict) or limit.get("op") not in _OPS or not _stat_known(limit.get("stat")) \
                or not isinstance(limit.get("value"), (int, float)) or isinstance(limit.get("value"), bool):
            raise DashboardError(f"{where}: limit {limit!r} needs stat (pNN|max|min|mean), op {sorted(_OPS)} and a number")
        parsed.append(Limit(stat=limit["stat"], op=limit["op"], value=float(limit["value"])))
    engine = row.get("engine")
    return TargetRow(series=tuple(series), limits=tuple(parsed), engine=engine if isinstance(engine, str) else None)


_PCT = re.compile(r"^p(\d{1,2}(?:\.\d+)?)$")


def _stat_known(stat: object) -> bool:
    return isinstance(stat, str) and (stat in ("max", "min", "mean") or _PCT.match(stat) is not None)


def stat_of(samples: Sequence[float], stat: str) -> float | None:
    """A point's statistic from its raw samples; percentiles come only from perf_stats.pct."""
    values = [value for value in samples if isinstance(value, (int, float))]
    if not values:
        return None
    if stat == "max":
        return max(values)
    if stat == "min":
        return min(values)
    if stat == "mean":
        return sum(values) / len(values)
    match = _PCT.match(stat)
    if match is None:
        raise DashboardError(f"unknown statistic {stat!r}")
    return perf_stats.pct(values, float(match.group(1)) / 100)


# ---------- the read model ----------


@dataclass(frozen=True)
class SeriesInfo:
    key: str
    story: str
    metric: str
    engine: str
    host_class: str
    macos_major: int
    build_config: str
    unit: str
    better: str
    target_ref: str | None = None

    @property
    def hz(self) -> int | None:
        match = re.search(r"/(\d+)hz$", self.host_class)
        return int(match.group(1)) if match else None

    @property
    def name(self) -> str:
        return f"{self.story}/{self.metric}"


@dataclass(frozen=True)
class PointView:
    commit_pos: int
    sha: str
    started_at: str
    samples: tuple[float, ...]
    features_hash: str
    macos_build: str
    safe_mode: str
    host_name: str


@dataclass(frozen=True)
class AlertView:
    id: int
    series_key: str
    rule: str
    start_pos: int
    end_pos: int
    median_before: float | None
    median_after: float | None
    is_improvement: bool
    created_at: str
    group_id: int | None = None
    group_state: str | None = None
    series_name: str = ""


@dataclass(frozen=True)
class AnnotationView:
    kind: str
    start_pos: int
    end_pos: int
    text: str
    created_by: str
    all_series: bool = False


@dataclass(frozen=True)
class GroupView:
    id: int
    state: str
    start_pos: int
    end_pos: int
    culprit_sha: str | None
    culprit_verified: bool
    issue_number: int | None
    reason: str | None
    updated_at: str
    alerts: tuple[AlertView, ...] = ()


@dataclass(frozen=True)
class TraceView:
    kind: str
    attempt: int
    url: str
    digest: str
    bytes: int


@dataclass(frozen=True)
class JobView:
    id: int
    controller_job_id: str | None
    kind: str
    state: str
    story: str | None
    host_class: str | None
    base_sha: str | None
    head_sha: str | None
    alert_group_id: int | None
    updated_at: str
    traces: tuple[TraceView, ...] = ()


@dataclass(frozen=True)
class StoryCoverage:
    story: str
    tier: str
    engine: str
    last_run: str
    runs_24h: int
    hosts: tuple[str, ...]


@dataclass(frozen=True)
class ReportTable:
    """One Field or Stability table: field.py and stability.py hand these to the dashboard."""

    title: str
    columns: tuple[str, ...]
    rows: tuple[tuple[object, ...], ...]
    note: str = ""


class DashboardSource(Protocol):
    def series(self) -> list[SeriesInfo]: ...
    def points(self, key: str, limit: int = MAX_WINDOW_SIZE) -> list[PointView]: ...
    def alerts(self, key: str | None = None) -> list[AlertView]: ...
    def annotations(self, key: str) -> list[AnnotationView]: ...
    def groups(self) -> list[GroupView]: ...
    def jobs(self) -> list[JobView]: ...
    def story_coverage(self, since: datetime) -> list[StoryCoverage]: ...
    def field_tables(self) -> list[ReportTable] | None: ...
    def stability_tables(self) -> list[ReportTable] | None: ...


ReportSource = Callable[[], list[ReportTable]]


class LabReader:
    """DashboardSource over the lab store's schema (store.py, migration 1), on a read-only connection."""

    def __init__(self, db: sqlite3.Connection, *, field: ReportSource | None = None,
                 stability: ReportSource | None = None) -> None:
        self._db = db
        self._db.row_factory = sqlite3.Row
        self._field, self._stability = field, stability

    @classmethod
    def open(cls, path: Path | str, **sources: ReportSource | None) -> "LabReader":
        uri = f"{Path(path).resolve().as_uri()}?mode=ro"
        return cls(sqlite3.connect(uri, uri=True), **sources)

    def close(self) -> None:
        self._db.close()

    def series(self) -> list[SeriesInfo]:
        rows = self._db.execute(
            """SELECT series_key, story, metric, engine, host_class, macos_major, build_config, unit, better,
                      target_ref FROM series ORDER BY story, metric, engine, host_class, macos_major, build_config""")
        return [SeriesInfo(*row) for row in rows]

    def points(self, key: str, limit: int = MAX_WINDOW_SIZE) -> list[PointView]:
        rows = self._db.execute(
            """SELECT b.commit_pos, b.sha, u.started_at, r.samples_json, u.features_hash, u.macos_build,
                      u.safe_mode, h.name
               FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
               JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
               WHERE s.series_key = ? AND u.kind = 'waterfall'
               ORDER BY b.commit_pos DESC, u.started_at DESC, r.id DESC LIMIT ?""", (key, limit)).fetchall()
        return [PointView(row[0], row[1], row[2], tuple(json.loads(row[3])), row[4], row[5], row[6], row[7])
                for row in reversed(rows)]

    def alerts(self, key: str | None = None) -> list[AlertView]:
        rows = self._db.execute(
            """SELECT a.id, s.series_key, a.rule, a.start_pos, a.end_pos, a.median_before, a.median_after,
                      a.is_improvement, a.created_at, a.group_id, g.state, s.story || '/' || s.metric
               FROM alerts a JOIN series s ON s.id = a.series_id LEFT JOIN alert_groups g ON g.id = a.group_id
               WHERE ? IS NULL OR s.series_key = ? ORDER BY a.start_pos, a.id""", (key, key))
        return [AlertView(row[0], row[1], row[2], row[3], row[4], row[5], row[6], bool(row[7]), row[8], row[9],
                          row[10], row[11]) for row in rows]

    def annotations(self, key: str) -> list[AnnotationView]:
        rows = self._db.execute(
            """SELECT a.kind, a.start_pos, a.end_pos, a.text, a.created_by, a.series_id IS NULL
               FROM annotations a LEFT JOIN series s ON s.id = a.series_id
               WHERE a.series_id IS NULL OR s.series_key = ? ORDER BY a.start_pos, a.id""", (key,))
        return [AnnotationView(row[0], row[1], row[2], row[3], row[4], bool(row[5])) for row in rows]

    def groups(self) -> list[GroupView]:
        by_group: dict[int, list[AlertView]] = {}
        for alert in self.alerts():
            if alert.group_id is not None:
                by_group.setdefault(alert.group_id, []).append(alert)
        rows = self._db.execute(
            """SELECT id, state, start_pos, end_pos, culprit_sha, culprit_verified, issue_number, reason, updated_at
               FROM alert_groups ORDER BY updated_at DESC, id DESC""")
        return [GroupView(row[0], row[1], row[2], row[3], row[4], bool(row[5]), row[6], row[7], row[8],
                          tuple(by_group.get(row[0], ()))) for row in rows]

    def jobs(self) -> list[JobView]:
        traces: dict[int, list[TraceView]] = {}
        for row in self._db.execute(
                """SELECT COALESCE(t.job_id, u.job_id), t.kind, t.attempt, t.url, t.digest, t.bytes
                   FROM traces t LEFT JOIN runs u ON u.id = t.run_id
                   WHERE COALESCE(t.job_id, u.job_id) IS NOT NULL ORDER BY t.attempt, t.id"""):
            traces.setdefault(row[0], []).append(TraceView(*row[1:]))
        rows = self._db.execute(
            """SELECT id, controller_job_id, kind, state, story, host_class, base_sha, head_sha, alert_group_id,
                      updated_at FROM jobs WHERE kind != 'waterfall' ORDER BY updated_at DESC, id DESC LIMIT 200""")
        return [JobView(*row, traces=tuple(traces.get(row[0], ()))) for row in rows]

    def story_coverage(self, since: datetime) -> list[StoryCoverage]:
        rows = self._db.execute(
            """SELECT u.story, COALESCE(u.tier, ''), u.engine, MAX(u.started_at), SUM(u.started_at >= ?),
                      GROUP_CONCAT(DISTINCT h.name)
               FROM runs u JOIN hosts h ON h.id = u.host_id WHERE u.kind = 'waterfall'
               GROUP BY u.story, u.tier, u.engine ORDER BY u.story, u.tier, u.engine""",
            (since.astimezone(timezone.utc).isoformat(timespec="microseconds"),))
        return [StoryCoverage(row[0], row[1], row[2], row[3], int(row[4] or 0),
                              tuple(sorted((row[5] or "").split(",")))) for row in rows]

    def field_tables(self) -> list[ReportTable] | None:
        return None if self._field is None else self._field()

    def stability_tables(self) -> list[ReportTable] | None:
        return None if self._stability is None else self._stability()


# ---------- tiles ----------


@dataclass(frozen=True)
class LimitCheck:
    limit: Limit
    measured: float | None

    @property
    def ok(self) -> bool:
        return self.measured is not None and self.limit.holds(self.measured)


@dataclass(frozen=True)
class TileRow:
    """The newest point of one matched series, judged against its row's limits."""

    series: SeriesInfo
    commit_pos: int
    sha: str
    checks: tuple[LimitCheck, ...]
    miss_since: int | None = None

    @property
    def ok(self) -> bool:
        return all(check.ok for check in self.checks)


@dataclass(frozen=True)
class Tile:
    target: Target
    rows: tuple[TileRow, ...]
    gaps: tuple[str, ...] = ()

    @property
    def status(self) -> str:
        if any(not row.ok for row in self.rows):
            return "miss"
        if self.gaps or not self.rows:
            return "gap"
        return "pass"


def _ref_target(target_ref: str | None) -> str | None:
    if not target_ref:
        return None
    try:
        parsed = json.loads(target_ref)
    except ValueError:
        return target_ref
    return parsed.get("target") if isinstance(parsed, dict) else None


def row_matches(target: Target, row: TargetRow, series: SeriesInfo) -> bool:
    if target.hz is not None and series.hz != target.hz:
        return False
    if row.engine is not None and series.engine != row.engine:
        return False
    if series.build_config not in ("bench", "bench-checks"):
        return False
    return _ref_target(series.target_ref) == target.id or any(
        fnmatch.fnmatchcase(series.name, pattern) for pattern in row.series)


def build_tile(target: Target, series: Sequence[SeriesInfo], source: DashboardSource) -> Tile:
    rows, gaps = [], []
    for row in target.rows:
        matched = [info for info in series if row_matches(target, row, info)]
        found = False
        for info in matched:
            points = source.points(info.key, limit=1)
            if not points:
                continue
            found = True
            newest = points[-1]
            checks = tuple(LimitCheck(limit, stat_of(newest.samples, limit.stat)) for limit in row.limits)
            misses = [alert.start_pos for alert in source.alerts(info.key) if alert.rule == "target_miss"]
            rows.append(TileRow(info, newest.commit_pos, newest.sha, checks,
                                miss_since=max(misses) if misses and not all(c.ok for c in checks) else None))
        if not found:
            gaps.append(row.engine or "all engines")
    return Tile(target, tuple(rows), tuple(gaps))


# ---------- formatting ----------


def esc(value: object) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def fmt(value: float | None, unit: str = "") -> str:
    if value is None or (isinstance(value, float) and not math.isfinite(value)):
        return "–"
    magnitude = abs(value)
    if magnitude >= 1000:
        text = f"{value / 1000:.1f}K" if magnitude < 1e6 else f"{value / 1e6:.1f}M"
    elif magnitude >= 100 or value == int(value):
        text = f"{value:.0f}"
    elif magnitude >= 10:
        text = f"{value:.1f}"
    else:
        text = f"{value:.2f}".rstrip("0").rstrip(".")
    return f"{text} {unit}" if unit else text


def series_href(key: str) -> str:
    return "/series/" + quote(key, safe=":")


def _short(sha: str | None) -> str:
    return (sha or "")[:10]


def _sha_link(sha: str | None) -> str:
    if not sha:
        return "–"
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        return esc(sha)
    return f'<a href="https://github.com/manaflow-ai/cmux/commit/{sha}"><code>{_short(sha)}</code></a>'


def _safe_url(url: str) -> str | None:
    return url if re.match(r"^https?://[^\s\"'<>]+$", url or "") else None


# ---------- SVG ----------


def nice_ticks(low: float, high: float, count: int = 4) -> list[float]:
    """Round axis ticks covering [low, high] (1, 2, 2.5 or 5 times a power of ten)."""
    if high <= low:
        high = low + (abs(low) or 1.0)
    raw = (high - low) / count
    power = 10 ** math.floor(math.log10(raw))
    step = next(m * power for m in (1, 2, 2.5, 5, 10) if m * power >= raw)
    start = math.floor(low / step) * step
    ticks = []
    value = start
    while value < high + step * 0.5:
        ticks.append(round(value, 10))
        value += step
    return ticks


def _scale(values: Sequence[float], top: float, bottom: float) -> Callable[[float], float]:
    low, high = min(values), max(values)
    if high == low:
        return lambda _value: (top + bottom) / 2
    return lambda value: bottom - (value - low) / (high - low) * (bottom - top)


def sparkline(values: Sequence[float | None], *, steps: Sequence[tuple[int, bool, str]] = (),
              marks: Sequence[tuple[int, str]] = (), label: str = "", width: int = 160, height: int = 36) -> str:
    """A 2px line with a ringed end dot; change points as hairlines, annotations as ticks on the top edge.

    steps: (point index, is_improvement, title); marks: (point index, title).
    """
    known = [(i, v) for i, v in enumerate(values) if v is not None]
    if not known:
        return f'<svg class="spark" width="{width}" height="{height}" role="img" aria-label="no points"></svg>'
    pad = 6
    x = (lambda i: pad + i * (width - 2 * pad) / max(len(values) - 1, 1))
    y = _scale([v for _, v in known], pad, height - pad)
    path = " ".join(f"{'M' if n == 0 else 'L'}{x(i):.1f},{y(v):.1f}" for n, (i, v) in enumerate(known))
    parts = [f'<svg class="spark" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
             f'role="img" aria-label="{esc(label)}">']
    for index, improvement, title in steps:
        cls = "step-good" if improvement else "step-bad"
        parts.append(f'<line class="{cls}" x1="{x(index):.1f}" x2="{x(index):.1f}" y1="2" y2="{height - 2}">'
                     f'<title>{esc(title)}</title></line>')
    for index, title in marks:
        parts.append(f'<path class="mark" d="M{x(index):.1f},1 l3,4 l-6,0 z"><title>{esc(title)}</title></path>')
    parts.append(f'<path class="line s1" d="{path}"/>')
    last_i, last_v = known[-1]
    parts.append(f'<circle class="dot s1" cx="{x(last_i):.1f}" cy="{y(last_v):.1f}" r="4"/></svg>')
    return "".join(parts)


@dataclass(frozen=True)
class _Line:
    label: str
    css: str
    values: tuple[float | None, ...]


def series_chart(points: Sequence[PointView], unit: str, *, lines: Sequence[_Line],
                 limits: Sequence[Limit] = (), steps: Sequence[tuple[int, bool, str]] = (),
                 marks: Sequence[tuple[int, str]] = (), width: int = 760, height: int = 260) -> str:
    left, right, top, bottom = 56, 16, 20, height - 28
    values = [v for line in lines for v in line.values if v is not None] + [limit.value for limit in limits]
    if not values:
        return '<p class="muted">No points yet.</p>'
    ticks = nice_ticks(min(values), max(values))
    y = _scale([ticks[0], ticks[-1]], top, bottom)
    x = (lambda i: left + i * (width - left - right) / max(len(points) - 1, 1))
    out = [f'<svg class="chart" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{esc(", ".join(line.label for line in lines))} per commit">']
    for tick in ticks:
        out.append(f'<line class="grid" x1="{left}" x2="{width - right}" y1="{y(tick):.1f}" y2="{y(tick):.1f}"/>'
                   f'<text class="tick" x="{left - 6}" y="{y(tick) + 4:.1f}" text-anchor="end">{esc(fmt(tick))}</text>')
    out.append(f'<line class="axis" x1="{left}" x2="{width - right}" y1="{bottom}" y2="{bottom}"/>')
    if points:
        out.append(f'<text class="tick" x="{left}" y="{height - 8}">#{points[0].commit_pos}</text>'
                   f'<text class="tick" x="{width - right}" y="{height - 8}" text-anchor="end">#{points[-1].commit_pos}</text>')
    for limit in limits:
        out.append(f'<line class="limit" x1="{left}" x2="{width - right}" y1="{y(limit.value):.1f}" '
                   f'y2="{y(limit.value):.1f}"/><text class="tick" x="{width - right - 4}" '
                   f'y="{y(limit.value) - 4:.1f}" text-anchor="end">target {esc(limit.label())} {esc(unit)}</text>')
    for index, improvement, title in steps:
        out.append(f'<line class="{"step-good" if improvement else "step-bad"}" x1="{x(index):.1f}" '
                   f'x2="{x(index):.1f}" y1="{top - 8}" y2="{bottom}"><title>{esc(title)}</title></line>')
    for index, title in marks:
        out.append(f'<path class="mark" d="M{x(index):.1f},{top - 14} l4,6 l-8,0 z"><title>{esc(title)}</title></path>')
    for line in lines:
        known = [(i, v) for i, v in enumerate(line.values) if v is not None]
        path = " ".join(f"{'M' if n == 0 else 'L'}{x(i):.1f},{y(v):.1f}" for n, (i, v) in enumerate(known))
        out.append(f'<path class="line {line.css}" d="{path}"/>')
    for i, point in enumerate(points):
        tip = "\n".join([f"#{point.commit_pos} {_short(point.sha)}"]
                        + [f"{line.label} {fmt(line.values[i], unit)}" for line in lines]
                        + [f"n {len(point.samples)}", f"features {point.features_hash}",
                           f"macOS {point.macos_build}", f"host {point.host_name}"])
        for line in lines:
            if line.values[i] is not None:
                out.append(f'<circle class="dot {line.css}" cx="{x(i):.1f}" cy="{y(line.values[i]):.1f}" r="4"/>')
        out.append(f'<rect class="hit" x="{x(i) - 8:.1f}" y="{top}" width="16" height="{bottom - top}">'
                   f'<title>{esc(tip)}</title></rect>')
    out.append("</svg>")
    return "".join(out)


# ---------- change points and annotations on a series ----------


def _index_at(points: Sequence[PointView], pos: int) -> int | None:
    """The first point at or after commit position `pos` inside the window."""
    for index, point in enumerate(points):
        if point.commit_pos >= pos:
            return index
    return None


def change_steps(points: Sequence[PointView], alerts: Sequence[AlertView], unit: str) -> list[tuple[int, bool, str]]:
    steps = []
    for alert in alerts:
        if alert.rule != "edivisive":
            continue
        index = _index_at(points, alert.end_pos)
        if index is None:
            continue
        change = ""
        if alert.median_before and alert.median_after is not None:
            change = f" {100 * (alert.median_after - alert.median_before) / alert.median_before:+.1f}%"
        kind = "improvement" if alert.is_improvement else "regression"
        steps.append((index, alert.is_improvement,
                      f"{kind}{change} at #{alert.start_pos}..#{alert.end_pos}: "
                      f"{fmt(alert.median_before, unit)} → {fmt(alert.median_after, unit)}"))
    return steps


def annotation_marks(points: Sequence[PointView], annotations: Sequence[AnnotationView]) -> list[tuple[int, str]]:
    """Stored annotations, plus a mark where a point's features hash or macOS build differs from the last."""
    marks = []
    for note in annotations:
        index = _index_at(points, note.start_pos)
        if index is not None:
            label = {"reference_drift": ".ref drift", "features_hash": "features", "macos_build": "macOS build",
                     "safe_mode": "safe mode"}.get(note.kind, note.kind)
            marks.append((index, f"{label}: {note.text} (#{note.start_pos}..#{note.end_pos}, {note.created_by})"))
    for index in range(1, len(points)):
        before, after = points[index - 1], points[index]
        if before.features_hash != after.features_hash:
            marks.append((index, f"features hash {before.features_hash} → {after.features_hash}"))
        if before.macos_build != after.macos_build:
            marks.append((index, f"macOS build {before.macos_build} → {after.macos_build}"))
    return marks


# ---------- page shell ----------

_CSS = """
.viz-root{color-scheme:light;--surface-1:#fcfcfb;--page:#f9f9f7;--text-primary:#0b0b0b;--text-secondary:#52514e;
--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,.10);--series-1:#2a78d6;--series-2:#eb6834;
--good:#0ca30c;--good-text:#006300;--critical:#d03b3b}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])) .viz-root{color-scheme:dark;
--surface-1:#1a1a19;--page:#0d0d0d;--text-primary:#f0efec;--text-secondary:#c3c2b7;--grid:#2c2c2a;--axis:#383835;
--border:rgba(255,255,255,.10);--series-1:#3987e5;--series-2:#d95926;--good-text:#0ca30c}}
:root[data-theme="dark"] .viz-root{color-scheme:dark;--surface-1:#1a1a19;--page:#0d0d0d;--text-primary:#f0efec;
--text-secondary:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);--series-1:#3987e5;
--series-2:#d95926;--good-text:#0ca30c}
body{margin:0}
.viz-root{background:var(--page);color:var(--text-primary);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;
padding:16px 24px;min-height:100vh}
a{color:inherit}
nav{display:flex;gap:16px;border-bottom:1px solid var(--grid);margin-bottom:16px;padding-bottom:8px}
nav a{text-decoration:none;color:var(--text-secondary)}nav a[aria-current]{color:var(--text-primary);font-weight:600}
h1{font-size:18px;margin:0 0 12px}h2{font-size:15px;margin:24px 0 8px}
.muted,.tick{color:var(--muted);fill:var(--muted);font-size:12px}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}
.tile{background:var(--surface-1);border:1px solid var(--border);border-radius:8px;padding:12px}
.tile h3{font-size:13px;margin:0 0 6px;color:var(--text-secondary);font-weight:600}
.tile ul{list-style:none;margin:0;padding:0}.tile li{margin:4px 0}
.status{font-weight:600}.status-pass .status{color:var(--good-text)}.status-miss .status{color:var(--critical)}
.status-gap .status{color:var(--muted)}
.status-pass{box-shadow:inset 3px 0 0 var(--good)}.status-miss{box-shadow:inset 3px 0 0 var(--critical)}
table{border-collapse:collapse;background:var(--surface-1);font-size:13px}
th,td{text-align:left;padding:4px 10px;border-bottom:1px solid var(--grid);vertical-align:middle}
th{color:var(--text-secondary);font-weight:600}td.num{text-align:right;font-variant-numeric:tabular-nums}
.legend{display:flex;gap:16px;color:var(--text-secondary);font-size:12px;margin:4px 0}
.key{display:inline-block;width:14px;height:2px;vertical-align:middle;margin-right:6px}
.key.s1{background:var(--series-1)}.key.s2{background:var(--series-2)}
svg .grid{stroke:var(--grid);stroke-width:1}svg .axis{stroke:var(--axis);stroke-width:1}
svg .limit{stroke:var(--muted);stroke-width:1}
svg .line{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
svg .line.s1{stroke:var(--series-1)}svg .line.s2{stroke:var(--series-2)}
svg .dot{stroke:var(--surface-1);stroke-width:2}svg .dot.s1{fill:var(--series-1)}svg .dot.s2{fill:var(--series-2)}
svg .step-bad{stroke:var(--critical);stroke-width:1}svg .step-good{stroke:var(--good);stroke-width:1}
svg .mark{fill:var(--text-secondary)}svg .hit{fill:transparent}
svg.spark,svg.chart{display:block;background:var(--surface-1)}
details{margin-top:8px}
"""

NAV = (("/", "Targets and series"), ("/alerts", "Alert groups"), ("/jobs", "Pinpoint jobs"),
       ("/coverage", "Coverage"), ("/field", "Field"), ("/stability", "Stability"))


@dataclass(frozen=True)
class Page:
    status: int
    body: str
    content_type: str = "text/html; charset=utf-8"
    headers: dict[str, str] = field(default_factory=lambda: {"Content-Security-Policy": CSP})


def shell(title: str, current: str, body: str) -> str:
    current_attr = ' aria-current="page"'
    links = "".join(f'<a href="{href}"{current_attr if href == current else ""}>{esc(text)}</a>'
                    for href, text in NAV)
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f"<title>{esc(title)} – cmux perf lab</title><style>{_CSS}</style></head>"
            f'<body><div class="viz-root"><nav>{links}</nav><h1>{esc(title)}</h1>{body}</div></body></html>')


def table(columns: Sequence[str], rows: Sequence[Sequence[str]], numeric: Sequence[int] = ()) -> str:
    """Cells are already-escaped HTML."""
    head = "".join(f"<th>{esc(column)}</th>" for column in columns)
    num_attr = ' class="num"'
    body = "".join("<tr>" + "".join(f'<td{num_attr if i in numeric else ""}>{cell}</td>'
                                    for i, cell in enumerate(row)) + "</tr>" for row in rows)
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


# ---------- tiles HTML ----------

_STATUS_TEXT = {"pass": "✓ pass", "miss": "✕ miss", "gap": "○ no data"}


def check_text(check: LimitCheck, unit: str) -> str:
    """'p50 7.9 ms, pass icon, target <= 8.3 ms': the measured value, a pass or miss icon, then the target."""
    icon = "✓" if check.ok else "✕"
    limit = check.limit
    return f"{limit.stat} {fmt(check.measured, unit)} {icon} {_OP_TEXT[limit.op]} {fmt(limit.value, unit)}"


def render_tile(tile: Tile) -> str:
    target, items = tile.target, []
    for row in tile.rows:
        info = row.series
        checks = ", ".join(esc(check_text(check, target.unit)) for check in row.checks)
        miss = f' <span class="muted">missing since #{row.miss_since}</span>' if row.miss_since is not None else ""
        items.append(f'<li><a href="{series_href(info.key)}">{esc(info.engine)} · {esc(info.host_class)} '
                     f'· macOS {info.macos_major}</a><br>{checks} <span class="muted">at #{row.commit_pos}</span>'
                     f"{miss}</li>")
    for gap in tile.gaps:
        items.append(f'<li class="muted"><a href="/coverage">{esc(gap)}: no {target.hz or "any"}'
                     f'{" Hz" if target.hz else ""} point</a></li>')
    return (f'<section class="tile status-{tile.status}" id="target-{esc(target.id)}">'
            f'<h3>{esc(target.title)}</h3><div class="status">{_STATUS_TEXT[tile.status]}</div>'
            f'<ul>{"".join(items)}</ul></section>')


# ---------- the dashboard ----------


class Dashboard:
    def __init__(self, source: DashboardSource, targets: Sequence[Target], *,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self._source, self._targets, self._clock = source, tuple(targets), clock

    def route(self, path: str) -> Page:
        path = path.split("?", 1)[0].split("#", 1)[0]
        pages = {"/": self.overview, "/alerts": self.alerts_page, "/jobs": self.jobs_page,
                 "/coverage": self.coverage_page, "/field": self.field_page, "/stability": self.stability_page}
        if path in pages:
            return Page(200, pages[path]())
        if path.startswith("/series/"):
            key = unquote(path[len("/series/"):])
            info = next((s for s in self._source.series() if s.key == key), None)
            if info is not None:
                return Page(200, self.series_page(info))
        return Page(404, shell("Not found", "", f'<p class="muted">No page {esc(path)}.</p>'))

    def tiles(self) -> list[Tile]:
        series = self._source.series()
        return [build_tile(target, series, self._source) for target in self._targets]

    def overview(self) -> str:
        tiles = self.tiles()
        counts = {status: sum(tile.status == status for tile in tiles) for status in _STATUS_TEXT}
        summary = (f'<p class="muted">{counts["pass"]} pass, {counts["miss"]} miss, {counts["gap"]} without data '
                   f"of {len(tiles)} targets. Tiles judge the newest point of each {TILE_HZ} Hz bench series.</p>")
        body = [summary, '<div class="tiles">', *(render_tile(tile) for tile in tiles), "</div>",
                "<h2>Series</h2>", self._series_list()]
        return shell("Targets and series", "/", "".join(body))

    def _series_list(self) -> str:
        rows = []
        for info in self._source.series():
            points = self._source.points(info.key)
            alerts = self._source.alerts(info.key)
            steps = change_steps(points, alerts, info.unit)
            marks = annotation_marks(points, self._source.annotations(info.key))
            medians = [stat_of(point.samples, "p50") for point in points]
            spark = sparkline(medians, steps=steps, marks=marks,
                              label=f"{info.name} p50 over {len(points)} points")
            latest = fmt(medians[-1], info.unit) if medians else "–"
            regressions = sum(1 for alert in alerts if alert.rule == "edivisive" and not alert.is_improvement)
            rows.append([f'<a href="{series_href(info.key)}">{esc(info.name)}</a>',
                         esc(f"{info.engine} · {info.host_class} · macOS {info.macos_major} "
                             f"· {info.build_config}"),
                         spark, esc(latest), str(len(points)), str(regressions)])
        if not rows:
            return '<p class="muted">No series stored yet.</p>'
        return table(("Series", "Key", "p50, newest 50 points", "Newest p50", "Points", "Regressions"), rows,
                     numeric=(3, 4, 5))

    def series_page(self, info: SeriesInfo) -> str:
        points = self._source.points(info.key)
        alerts = self._source.alerts(info.key)
        notes = self._source.annotations(info.key)
        lines = [_Line(stat, f"s{n}", tuple(stat_of(p.samples, stat) for p in points))
                 for n, stat in enumerate(STATS, start=1)]
        limits = [limit for target in self._targets for row in target.rows if row_matches(target, row, info)
                  for limit in row.limits if limit.stat in STATS]
        legend = "".join(f'<span><span class="key {line.css}"></span>{esc(line.label)}</span>' for line in lines)
        chart = series_chart(points, info.unit, lines=lines, limits=limits,
                             steps=change_steps(points, alerts, info.unit), marks=annotation_marks(points, notes))
        rows = [[f"#{p.commit_pos}", _sha_link(p.sha), esc(fmt(lines[0].values[i], info.unit)),
                 esc(fmt(lines[1].values[i], info.unit)), str(len(p.samples)), esc(p.features_hash),
                 esc(p.macos_build), esc(p.safe_mode), esc(p.host_name)] for i, p in enumerate(points)]
        alert_rows = [[esc(a.rule), f"#{a.start_pos}..#{a.end_pos}", esc(fmt(a.median_before, info.unit)),
                       esc(fmt(a.median_after, info.unit)), "improvement" if a.is_improvement else "regression",
                       esc(a.group_state or "–")] for a in alerts]
        note_rows = [[esc(n.kind), f"#{n.start_pos}..#{n.end_pos}", esc(n.text), esc(n.created_by),
                      "all series" if n.all_series else "this series"] for n in notes]
        body = [f'<p class="muted">{esc(info.engine)} · {esc(info.host_class)} · macOS {info.macos_major} '
                f"· {esc(info.build_config)} · {esc(info.unit)}, {esc(info.better)} is better "
                f"· <code>{esc(info.key)}</code></p>",
                f'<div class="legend">{legend}<span>▲ annotation</span><span>| change point</span></div>', chart,
                f"<details><summary>Table view ({len(points)} points)</summary>"
                + table(("Commit", "Sha", "p50", "p99", "n", "Features", "macOS build", "Safe mode", "Host"),
                        rows, numeric=(2, 3, 4)) + "</details>",
                "<h2>Change points and alerts</h2>",
                table(("Rule", "Range", "Before", "After", "Kind", "Group"), alert_rows) if alert_rows
                else '<p class="muted">None.</p>',
                "<h2>Annotations</h2>",
                table(("Kind", "Range", "Text", "By", "Scope"), note_rows) if note_rows
                else '<p class="muted">None.</p>']
        return shell(info.name, "", "".join(body))

    def alerts_page(self) -> str:
        groups = self._source.groups()
        if not groups:
            return shell("Alert groups", "/alerts", '<p class="muted">No alert groups.</p>')
        sections = []
        for group in groups:
            issue = (f'<a href="https://github.com/manaflow-ai/cmux/issues/{group.issue_number}">'
                     f"#{group.issue_number}</a>" if group.issue_number else "no issue")
            verified = "verified" if group.culprit_verified else "unverified"
            culprit = f"{_sha_link(group.culprit_sha)} ({verified})" if group.culprit_sha else "no culprit yet"
            rows = [[f'<a href="{series_href(a.series_key)}">{esc(a.series_name)}</a>', esc(a.rule),
                     f"#{a.start_pos}..#{a.end_pos}", esc(fmt(a.median_before)), esc(fmt(a.median_after)),
                     "improvement" if a.is_improvement else "regression"] for a in group.alerts]
            sections.append(
                f'<section id="group-{group.id}"><h2>Group {group.id}: {esc(group.state)} '
                f'· #{group.start_pos}..#{group.end_pos}</h2><p class="muted">Culprit {culprit} · '
                f'{issue} · updated {esc(group.updated_at)}{" · " + esc(group.reason) if group.reason else ""}'
                "</p>" + table(("Series", "Rule", "Range", "Before", "After", "Kind"), rows) + "</section>")
        return shell("Alert groups", "/alerts", "".join(sections))

    def jobs_page(self) -> str:
        rows = []
        for job in self._source.jobs():
            traces = []
            for trace in job.traces:
                text = f"{trace.kind} #{trace.attempt}"
                url = _safe_url(trace.url)
                traces.append(f'<a href="{esc(url)}">{esc(text)}</a>' if url else esc(text))
            group = f'<a href="/alerts#group-{job.alert_group_id}">{job.alert_group_id}</a>' \
                if job.alert_group_id is not None else "–"
            rows.append([str(job.id), esc(job.controller_job_id or "–"), esc(job.kind), esc(job.state),
                         esc(job.story or "–"), esc(job.host_class or "–"),
                         f"{_sha_link(job.base_sha)} → {_sha_link(job.head_sha)}", group,
                         ", ".join(traces) or "–", esc(job.updated_at)])
        body = table(("Job", "Controller", "Kind", "State", "Story", "Host class", "Range", "Group", "Traces",
                      "Updated"), rows) if rows else '<p class="muted">No Pinpoint jobs.</p>'
        return shell("Pinpoint jobs", "/jobs", body)

    def coverage_page(self) -> str:
        now = self._clock()
        series = self._source.series()
        target_rows = []
        for tile in (build_tile(target, series, self._source) for target in self._targets):
            newest = max((row.commit_pos for row in tile.rows), default=None)
            target_rows.append([f'<a href="/#target-{esc(tile.target.id)}">{esc(tile.target.title)}</a>',
                                str(len(tile.rows)), f"#{newest}" if newest is not None else "–",
                                esc(", ".join(tile.gaps) or "–"), _STATUS_TEXT[tile.status]])
        story_rows = [[esc(c.story), esc(c.tier or "–"), esc(c.engine), esc(_age(c.last_run, now)),
                       str(c.runs_24h), esc(", ".join(c.hosts))]
                      for c in self._source.story_coverage(now - timedelta(hours=24))]
        body = ["<h2>Targets</h2>",
                table(("Target", "Series with points", "Newest commit", "Rows without data", "Status"),
                      target_rows, numeric=(1,)) if target_rows else '<p class="muted">No targets loaded.</p>',
                "<h2>Stories</h2>",
                table(("Story", "Tier", "Engine", "Newest run", "Runs in 24 h", "Hosts"), story_rows, numeric=(4,))
                if story_rows else '<p class="muted">No waterfall runs stored.</p>']
        return shell("Coverage", "/coverage", "".join(body))

    def field_page(self) -> str:
        return shell("Field", "/field", _report(self._source.field_tables(),
                                                "No field source is configured (field.py reads hang_reports)."))

    def stability_page(self) -> str:
        return shell("Stability", "/stability", _report(self._source.stability_tables(),
                                                        "No stability source is configured (stability.py reads Sentry)."))


def _report(tables: list[ReportTable] | None, missing: str) -> str:
    if tables is None:
        return f'<p class="muted">{esc(missing)}</p>'
    if not tables:
        return '<p class="muted">No rows yet.</p>'
    parts = ['<p class="muted">Reported only: opt-in Nightly data, never a pass/fail check.</p>']
    for report in tables:
        numeric = [i for i in range(len(report.columns))
                   if report.rows and all(isinstance(row[i], (int, float)) for row in report.rows)]
        rows = [[esc(fmt(cell) if isinstance(cell, float) else cell) for cell in row] for row in report.rows]
        parts.append(f"<h2>{esc(report.title)}</h2>" + table(report.columns, rows, numeric=numeric)
                     + (f'<p class="muted">{esc(report.note)}</p>' if report.note else ""))
    return "".join(parts)


def _age(stamp: str, now: datetime) -> str:
    try:
        seconds = (now - datetime.fromisoformat(stamp)).total_seconds()
    except ValueError:
        return stamp
    if seconds < 3600:
        return f"{max(int(seconds // 60), 0)} min ago"
    if seconds < 172800:
        return f"{int(seconds // 3600)} h ago"
    return f"{int(seconds // 86400)} d ago"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    render = sub.add_parser("render", help="print one page of a lab store to stdout")
    render.add_argument("--db", required=True, type=Path)
    render.add_argument("--targets", type=Path, default=HERE / "targets.json")
    render.add_argument("--path", default="/")
    args = parser.parse_args(argv)
    targets = load_targets(json.loads(args.targets.read_text())) if args.targets.exists() else []
    reader = LabReader.open(args.db)
    try:
        page = Dashboard(reader, targets).route(args.path)
    finally:
        reader.close()
    sys.stdout.write(page.body)
    return 0 if page.status == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
