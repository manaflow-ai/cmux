#!/usr/bin/env python3
"""The perf lab dashboard: server-rendered HTML pages with inline SVG charts, no JavaScript.

chromeperf is the model (catapult `dashboard/dashboard/elements/chart-container.html` and
`alerts-page.html`): a chart per series with alert bands and annotations, an alert-group list and
the Pinpoint job list. Here every page is built on the server from the lab store, so a page is one
HTML document that loads nothing else: its Content-Security-Policy is `default-src 'none'` with
inline styles only, hover readouts are SVG <title> elements, and every value a hover shows is also
in a table.

Pages (labd, task 012, serves them; `Dashboard.handle(path)` is its whole interface):

  /  and /status     12 target tiles: the newest point's statistic against the fixed target; a row
                     that names an hz is judged only from series at that Hz (task 160), a row
                     without one from any host; a series with no point in TILE_STALE_AFTER is stale
  /series[?q=]       series list with sparklines and change-point ticks
  /series/<key>      one series: p50 and p99 lines, change points, annotations (features hash,
                     macOS build and safe-mode changes, stored notes, reference drift), the
                     reference artifact's runs, and every point as a table
  /alerts            alert groups with their alerts, culprit and issue
  /jobs              Pinpoint bisect, verify and try jobs with trace links
  /coverage          newest waterfall run per tier, story and host, its age, and a harness-broken story
  /field, /stability Nightly field and Sentry rows (tasks 042, 223, 225), passed in by labd

The targets come from the lab catalog (catalog.py, task 007: `targets.json` and `stories.d`), the same
reader `lab.py targets --check` uses. A series feeds a target row only when its stored target_ref
claims that row ({"target": <row id>}, as the story's metric does); each of the row's checks whose
metric pattern full-matches the series metric is one tile line. The row's engine, config and hz
constrain the series (hz is read from the host class, so key-frame, whose rows say hz 120, judges only
120 Hz hosts), and debug-config series never feed a tile (p12-perf-process.md 3.2). A series whose newest
point is older than TILE_STALE_AFTER (a retired host class, an old macOS major) feeds a check only when no
current series does, and then as a stale row, never as a pass or a miss.

Colors follow the dataviz reference palette (categorical slots 1 and 2, status good and critical
with an icon and a label, never color alone), selected separately for light and dark surfaces.
"""
from __future__ import annotations

import argparse
import bisect
import html
import re
import importlib.util
import json
import math
import sqlite3
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Protocol
from urllib.parse import parse_qs, quote, unquote, urlsplit


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, Path(__file__).resolve().parent / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load_sibling("perf_stats")
catalog = _load_sibling("catalog")

Target = catalog.Target
TargetRow = catalog.Row
TargetCheck = catalog.Check
OP_TEXT = {"<=": "≤", "<": "<", ">=": "≥", ">": ">"}
# Group states after which an alert no longer needs attention (store.ALERT_GROUP_STATES).
CLOSED_GROUP_STATES = frozenset({"fixed", "flag-off", "accepted", "invalid", "lab-drift"})
# The coverage done checks (p12-perf-process.md 6.1 and 6.2): T0 within 60 min, T1 within 3 h; T2 is nightly.
STALE_AFTER = {"T0": timedelta(minutes=60), "T1": timedelta(hours=3), "T2": timedelta(hours=26)}
# A tile ignores a series with no waterfall point in this long: nearly three missed T2 nightly windows.
TILE_STALE_AFTER = timedelta(hours=72)
PINPOINT_KINDS = ("bisect", "verify", "try")
SERIES_LIST_LIMIT = 500
SERIES_POINTS_DEFAULT = 100
SERIES_POINTS_MAX = 500
SPARKLINE_POINTS = 50
JOBS_LIMIT = 200
ALERT_GROUPS_LIMIT = 200
ISSUE_URL = "https://github.com/manaflow-ai/cmux/issues/{number}"
CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"


class DashboardError(RuntimeError):
    pass


# ---------- view models ----------


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
        """The display Hz from the host class (store.host_class: chip/memory/<n>hz)."""
        tail = self.host_class.rsplit("/", 1)[-1]
        return int(tail[:-2]) if tail.endswith("hz") and tail[:-2].isdigit() else None

    @property
    def target_id(self) -> str | None:
        """The targets.json id named by the stored target_ref: a bare id or result-v1's {"target": id}."""
        if not self.target_ref:
            return None
        try:
            ref = json.loads(self.target_ref)
        except ValueError:
            return self.target_ref
        return ref.get("target") if isinstance(ref, dict) else None


@dataclass(frozen=True)
class PointView:
    commit_pos: int
    sha: str
    started_at: str
    p50: float | None
    p99: float | None
    n: int
    features_hash: str
    macos_build: str
    safe_mode: str
    host_name: str

    def stat(self, name: str) -> float | None:
        return self.p50 if name == "p50" else self.p99 if name == "p99" else None


def sample_stat(samples: Sequence[float], stat: str) -> float | None:
    """One catalog statistic (catalog.STATS) of a result's samples, as perf_stats computes percentiles."""
    values = [v for v in samples if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if not values:
        return None
    if stat in ("p50", "p95", "p99"):
        return perf_stats.pct(values, int(stat[1:]) / 100)
    if stat == "max":
        return max(values)
    if stat == "min":
        return min(values)
    if stat == "mean":
        return sum(values) / len(values)
    raise DashboardError(f"statistic {stat!r} is not one of {', '.join(catalog.STATS)}")


@dataclass(frozen=True)
class ChangePointView:
    rule: str
    start_pos: int
    end_pos: int
    median_before: float | None
    median_after: float | None
    is_improvement: bool
    group_id: int | None


@dataclass(frozen=True)
class AnnotationView:
    kind: str
    start_pos: int
    end_pos: int
    text: str


@dataclass(frozen=True)
class SeriesView:
    info: SeriesInfo
    points: Sequence[PointView]
    change_points: Sequence[ChangePointView]
    annotations: Sequence[AnnotationView]
    reference_points: Sequence[PointView] = ()


@dataclass(frozen=True)
class SeriesListRow:
    info: SeriesInfo
    points: Sequence[PointView]
    change_ranges: Sequence[tuple[int, int]]  # (start_pos, end_pos) of each regression change point
    annotation_count: int


def window_span(positions: Sequence[int], start: int, end: int) -> tuple[int, int] | None:
    """The indices of the shown points that a commit range [start, end] covers, or None when it is outside them.

    `positions` are the shown points' commit positions, ascending. A stored range starts after the last point
    before the step (alerts._candidate_range), so its first index is the first point at or after `start`; a range
    between two points lands on the later one, the first run that includes it.
    """
    if not positions or end < positions[0] or start > positions[-1]:
        return None
    first = bisect.bisect_left(positions, start)
    last = bisect.bisect_right(positions, end) - 1
    return first, max(first, last)


def judged_checks(row: TargetRow, info: SeriesInfo) -> list[TargetCheck]:
    """The checks of a target row that judge this series: none unless the series claims the row and fits it."""
    if info.target_id != row.id or info.build_config == "debug":
        return []
    if row.config is not None and info.build_config != row.config:
        return []
    if row.hz is not None and info.hz != row.hz:
        return []
    if row.engine is not None and info.engine != row.engine:
        return []
    return [check for check in row.checks if re.fullmatch(check.metric, info.metric)]


def literal_prefix(pattern: str) -> str:
    """The plain text a metric pattern starts with (`terminal\\.key_to_frame` -> `terminal.key_to_frame`)."""
    out, index = [], 0
    while index < len(pattern):
        char = pattern[index]
        if char == "\\" and index + 1 < len(pattern) and not pattern[index + 1].isalnum():
            out.append(pattern[index + 1])
            index += 2
            continue
        if char in ".^$*+?()[]{}|\\":
            break
        out.append(char)
        index += 1
    return "".join(out)


@dataclass(frozen=True)
class TileRow:
    row: TargetRow
    check: TargetCheck
    series: SeriesInfo | None
    point: PointView | None
    value: float | None
    status: str  # pass | miss | no-data
    target_miss_open: bool = False


@dataclass(frozen=True)
class Tile:
    target: Target
    rows: Sequence[TileRow]

    @property
    def status(self) -> str:
        """miss when a current series misses; no-data when a check has no current series (no-data or stale)."""
        states = {row.status for row in self.rows}
        if "miss" in states:
            return "miss"
        return "no-data" if not states or states & {"no-data", "stale"} else "pass"


@dataclass(frozen=True)
class AlertView:
    id: int
    series: SeriesInfo
    rule: str
    start_pos: int
    end_pos: int
    median_before: float | None
    median_after: float | None
    is_improvement: bool


@dataclass(frozen=True)
class AlertGroupView:
    id: int
    state: str
    start_pos: int
    end_pos: int
    culprit_sha: str | None
    culprit_verified: bool
    issue_number: int | None
    reason: str | None
    updated_at: str
    alerts: Sequence[AlertView]


@dataclass(frozen=True)
class TraceView:
    kind: str
    digest: str
    url: str
    attempt: int


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
    traces: Sequence[TraceView]


@dataclass(frozen=True)
class CoverageRow:
    tier: str
    story: str
    host_name: str
    host_class: str
    last_run_at: datetime
    runs_24h: int
    builds_24h: int
    broken: bool = False  # harness-broken on its host class now (harness_alerts.broken_stories): measured nothing



@dataclass(frozen=True)
class FieldRow:
    """One field aggregate (field.py, task 042; field_metrickit.py, task 223)."""
    build: str
    hardware_class: str
    metric: str
    value: float | None
    unit: str
    samples: int
    arm: str = "default"


@dataclass(frozen=True)
class StabilityRow:
    """One release's Sentry numbers (stability.py, task 225)."""
    release: str
    crash_free_sessions: float | None
    crash_free_installs: float | None
    new_signatures: int


class DashboardSource(Protocol):
    def all_series(self) -> list[SeriesInfo]: ...
    def latest_points(self, keys: Sequence[str]) -> dict[str, PointView]: ...
    def latest_samples(self, key: str) -> list[float]: ...
    def target_miss_series(self) -> set[str]: ...
    def series_list(self, query: str, limit: int) -> tuple[list[SeriesListRow], int]: ...
    def series(self, key: str, limit: int) -> SeriesView | None: ...
    def alert_groups(self) -> list[AlertGroupView]: ...
    def jobs(self, limit: int) -> list[JobView]: ...
    def coverage(self, since: datetime) -> list[CoverageRow]: ...
    def field_rows(self) -> list[FieldRow]: ...
    def stability_rows(self) -> list[StabilityRow]: ...


# ---------- targets ----------


def load_targets(root: Path) -> tuple[list[Target], tuple[str, ...]]:
    """The catalog's targets under the repository root, and the catalog's problems (shown, never fatal)."""
    try:
        loaded = catalog.load_catalog(root)
    except (catalog.CatalogError, OSError) as error:
        raise DashboardError(str(error)) from error
    return list(loaded.targets), loaded.problems


def build_tiles(targets: Sequence[Target], series: Sequence[SeriesInfo], latest: dict[str, PointView],
                stat_of: Callable[[str, str], float | None], target_misses: set[str], *,
                fresh_since: datetime | None = None) -> list[Tile]:
    """One tile per target; one tile row per (row check, current claiming series), or a no-data row for a check
    none feeds.

    `stat_of(series_key, stat)` gives the newest point's statistic (catalog.STATS over its samples). A series is
    current when its newest point started at or after `fresh_since` (None: every series with a point is). When no
    series feeding a check is current, the check shows each claiming series as a stale or no-data row instead.
    `target_misses` are the series with a stored target_miss alert; a row says it is open only while it misses.
    """
    ordered = sorted(series, key=lambda info: info.key)

    def current(info: SeriesInfo) -> bool:
        point = latest.get(info.key)
        return point is not None and (fresh_since is None or parse_stamp(point.started_at) >= fresh_since)

    tiles = []
    for target in targets:
        rows: list[TileRow] = []
        for target_row in target.rows:
            fed: dict[TargetCheck, list[SeriesInfo]] = {check: [] for check in target_row.checks}
            for info in ordered:
                for check in judged_checks(target_row, info):
                    fed[check].append(info)
            for check, infos in fed.items():
                if not infos:
                    rows.append(TileRow(target_row, check, None, None, None, "no-data"))
                fresh = [info for info in infos if current(info)]
                for info in fresh or infos:
                    point = latest.get(info.key)
                    value = stat_of(info.key, check.stat) if point is not None else None
                    if value is None:
                        status = "no-data"
                    elif not fresh:
                        status = "stale"
                    else:
                        status = "pass" if catalog.OPS[check.op](value, check.value) else "miss"
                    rows.append(TileRow(target_row, check, info, point, value, status,
                                        status == "miss" and info.key in target_misses))
        tiles.append(Tile(target, tuple(rows)))
    return tiles


# ---------- formatting ----------


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def fmt_value(value: float | None, unit: str = "") -> str:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "–"
    magnitude = abs(value)
    if float(value).is_integer() and magnitude < 1e9:
        text = str(int(value))
    elif magnitude >= 100:
        text = f"{value:.0f}"
    elif magnitude >= 10:
        text = f"{value:.1f}"
    else:
        text = f"{value:.2f}"
    return f"{text} {unit}" if unit and unit != "count" else text


def short_sha(sha: str | None) -> str:
    return (sha or "")[:10]


def series_href(key: str) -> str:
    return f"/series/{quote(key, safe='')}"


def safe_url(url: str) -> str | None:
    """An http(s) URL for an anchor, or None: a stored URL never becomes javascript: or data: navigation."""
    parts = urlsplit(url)
    return url if parts.scheme in ("http", "https") and parts.netloc else None


def nice_ticks(low: float, high: float, count: int = 5) -> list[float]:
    """Round axis ticks covering [low, high] (Heckbert's nice numbers)."""
    if not math.isfinite(low) or not math.isfinite(high):
        return [0.0, 1.0]
    if high <= low:
        high = low + (abs(low) or 1.0)
    raw = (high - low) / max(count - 1, 1)
    exponent = math.floor(math.log10(raw))
    fraction = raw / 10 ** exponent
    step = (1 if fraction <= 1 else 2 if fraction <= 2 else 2.5 if fraction <= 2.5 else 5 if fraction <= 5 else 10) * 10 ** exponent
    start = math.floor(low / step) * step
    ticks = []
    value = start
    while value < high + step * 0.5 and len(ticks) < 50:
        ticks.append(round(value, 10))
        value += step
    if ticks[-1] < high:
        ticks.append(round(value, 10))
    return ticks


def age_text(now: datetime, then: datetime) -> str:
    seconds = max(0, int((now - then).total_seconds()))
    if seconds < 3600:
        return f"{seconds // 60} min"
    if seconds < 86400 * 2:
        return f"{seconds // 3600} h {seconds % 3600 // 60} min"
    return f"{seconds // 86400} d"


def parse_stamp(text: str) -> datetime:
    moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


# ---------- SVG ----------

STATUS_LABEL = {"pass": "Pass", "miss": "Miss", "no-data": "No data", "stale": "Stale", "fresh": "Fresh",
                "broken": "Harness broken"}


def status_icon(status: str) -> str:
    """A status mark: color and shape together, always next to a text label."""
    if status in ("pass", "fresh"):
        glyph = '<path d="M4.6 8.3l2.2 2.2 4.6-4.8" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'
        return f'<svg class="icon good" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="8" cy="8" r="7"/>{glyph}</svg>'
    if status in ("miss", "stale", "broken"):
        glyph = '<path d="M5.5 5.5l5 5M10.5 5.5l-5 5" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/>'
        return f'<svg class="icon critical" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="8" cy="8" r="7"/>{glyph}</svg>'
    return ('<svg class="icon none" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
            '<circle cx="8" cy="8" r="6" fill="none" stroke-width="2"/></svg>')


def status_badge(status: str) -> str:
    return f'<span class="status {esc(status)}">{status_icon(status)}{esc(STATUS_LABEL.get(status, status))}</span>'


def _path(coords: Sequence[tuple[float, float] | None]) -> str:
    """An SVG path through the coordinates; a None breaks the line (a point with no value)."""
    parts, pen_down = [], False
    for coord in coords:
        if coord is None:
            pen_down = False
            continue
        parts.append(f"{'L' if pen_down else 'M'}{coord[0]:.1f},{coord[1]:.1f}")
        pen_down = True
    return "".join(parts)


def sparkline(values: Sequence[float | None], *, marks: Sequence[int] = (), width: int = 140, height: int = 28,
              label: str = "") -> str:
    """A trend line in the de-emphasis ink, the newest point in the accent, change points as ticks."""
    present = [value for value in values if value is not None]
    if not present:
        return f'<svg class="spark" width="{width}" height="{height}" role="img" aria-label="no points"></svg>'
    pad = 4
    low, high = min(present), max(present)
    span = high - low or 1.0
    step = (width - 2 * pad) / max(len(values) - 1, 1)

    def at(index: int, value: float) -> tuple[float, float]:
        y = height / 2 if high == low else height - pad - (value - low) / span * (height - 2 * pad)
        return pad + index * step, y

    coords = [None if value is None else at(index, value) for index, value in enumerate(values)]
    ticks = "".join(f'<line class="cp" x1="{pad + index * step:.1f}" x2="{pad + index * step:.1f}" y1="0" y2="{height}"/>'
                    for index in marks if 0 <= index < len(values))
    last = next(((index, coord) for index, coord in reversed(list(enumerate(coords))) if coord is not None))
    return (f'<svg class="spark" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
            f'aria-label="{esc(label or "trend")}">{ticks}'
            f'<path class="spark-line" d="{_path(coords)}"/>'
            f'<circle class="dot s1" cx="{last[1][0]:.1f}" cy="{last[1][1]:.1f}" r="3"/></svg>')


def series_chart(view: SeriesView, *, limits: Sequence[tuple[str, float]] = (), width: int = 760,
                 height: int = 260) -> str:
    """p50 and p99 per point in commit order (one point per waterfall run), change-point bands,
    annotation marks and target lines; each x column carries a <title> readout of every value."""
    points = view.points
    if not points:
        return '<p class="empty">No waterfall points yet.</p>'
    left, right, top, bottom = 56, 16, 18, 30
    plot_w, plot_h = width - left - right, height - top - bottom
    values = [value for point in points for value in (point.p50, point.p99) if value is not None]
    values += [limit for _, limit in limits]
    ticks = nice_ticks(min(0.0, min(values, default=0.0)), max(values, default=1.0))
    y_low, y_high = ticks[0], ticks[-1]
    step = plot_w / max(len(points) - 1, 1)

    def x(index: int) -> float:
        return left + (index * step if len(points) > 1 else plot_w / 2)

    def y(value: float) -> float:
        return top + plot_h - (value - y_low) / ((y_high - y_low) or 1.0) * plot_h

    positions = [point.commit_pos for point in points]

    unit = view.info.unit
    out = [f'<svg class="chart" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{esc(view.info.story)} {esc(view.info.metric)} p50 and p99 by commit">']
    for tick in ticks:
        out.append(f'<line class="grid" x1="{left}" x2="{width - right}" y1="{y(tick):.1f}" y2="{y(tick):.1f}"/>'
                   f'<text class="tick" x="{left - 6}" y="{y(tick) + 4:.1f}" text-anchor="end">{esc(fmt_value(tick))}</text>')
    for cp in view.change_points:
        span = window_span(positions, cp.start_pos, cp.end_pos)
        if span is None:
            continue  # older or newer than the shown points; the change-point table still lists it
        first, last = span
        x0, x1 = x(first) - step / 2, x(last) + step / 2
        x0, x1 = max(left, x0), min(width - right, max(x1, x0 + 2))
        kind = "improvement" if cp.is_improvement else "regression"
        out.append(f'<rect class="band {kind}" x="{x0:.1f}" y="{top}" width="{x1 - x0:.1f}" height="{plot_h}">'
                   f'<title>{esc(cp.rule)} {kind} {cp.start_pos}..{cp.end_pos}: '
                   f'{esc(fmt_value(cp.median_before, unit))} → {esc(fmt_value(cp.median_after, unit))}</title></rect>')
    for name, limit in limits:
        out.append(f'<line class="limit" x1="{left}" x2="{width - right}" y1="{y(limit):.1f}" y2="{y(limit):.1f}"/>'
                   f'<text class="tick" x="{width - right}" y="{y(limit) - 4:.1f}" text-anchor="end">{esc(name)}</text>')
    out.append(f'<line class="axis" x1="{left}" x2="{width - right}" y1="{top + plot_h}" y2="{top + plot_h}"/>')
    for stat, slot in (("p99", "s2"), ("p50", "s1")):
        coords = [None if point.stat(stat) is None else (x(i), y(point.stat(stat))) for i, point in enumerate(points)]
        out.append(f'<path class="line {slot}" d="{_path(coords)}"/>')
        last = next((coord for coord in reversed(coords) if coord is not None), None)
        if last is not None:
            out.append(f'<circle class="dot {slot}" cx="{last[0]:.1f}" cy="{last[1]:.1f}" r="4"/>')
    for annotation in view.annotations:
        span = window_span(positions, annotation.start_pos, annotation.end_pos)
        if span is None:
            continue
        ax = x(span[0])
        out.append(f'<path class="mark" d="M{ax - 4:.1f},{top - 10} L{ax + 4:.1f},{top - 10} L{ax:.1f},{top - 3} Z">'
                   f'<title>{esc(annotation.kind)} at {annotation.start_pos}: {esc(annotation.text)}</title></path>')
    for i, point in enumerate(points):
        readout = (f"{point.commit_pos} {short_sha(point.sha)}\np50 {fmt_value(point.p50, unit)}\n"
                   f"p99 {fmt_value(point.p99, unit)}\nn {point.n}\nfeatures {point.features_hash}\n"
                   f"macOS {point.macos_build}\nhost {point.host_name}")
        # Each point owns the full-height column nearest to it, so the pointer only has to find the x.
        half = step / 2 if len(points) > 1 else plot_w / 2
        x0, x1 = max(left, x(i) - half), min(width - right, x(i) + half)
        out.append(f'<rect class="hit" x="{x0:.1f}" y="{top}" width="{x1 - x0:.1f}" '
                   f'height="{plot_h}"><title>{esc(readout)}</title></rect>')
    out.append(f'<text class="tick" x="{left}" y="{height - 8}">{points[0].commit_pos}</text>'
               f'<text class="tick" x="{width - right}" y="{height - 8}" text-anchor="end">{points[-1].commit_pos}</text>'
               f'<text class="tick" x="{left + plot_w / 2:.1f}" y="{height - 8}" text-anchor="middle">commit position</text>')
    out.append("</svg>")
    return "".join(out)


def derived_annotations(points: Sequence[PointView]) -> list[AnnotationView]:
    """Point-metadata changes between consecutive points: they are never part of the series key (3.1)."""
    notes = []
    for before, after in zip(points, points[1:]):
        for kind, old, new in (("features_hash", before.features_hash, after.features_hash),
                               ("macos_build", before.macos_build, after.macos_build),
                               ("safe_mode", before.safe_mode, after.safe_mode)):
            if old != new:
                notes.append(AnnotationView(kind, after.commit_pos, after.commit_pos, f"{old} → {new}"))
    return notes


# ---------- pages ----------

STYLE = """
:root{color-scheme:light;--surface:#fcfcfb;--page:#f9f9f7;--ink:#0b0b0b;--ink-2:#52514e;--muted:#898781;
--grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,.10);--band:#f0efec;--s1:#2a78d6;--s2:#eb6834;
--good:#0ca30c;--critical:#d03b3b}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--surface:#1a1a19;--page:#0d0d0d;--ink:#f0efec;
--ink-2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);--band:#383835;
--s1:#3987e5;--s2:#d95926}}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
header{display:flex;gap:16px;align-items:baseline;padding:12px 24px;border-bottom:1px solid var(--border);background:var(--surface)}
header h1{font-size:16px;margin:0}
nav a{color:var(--ink-2);text-decoration:none;margin-right:14px}
nav a.on{color:var(--ink);font-weight:600}
main{padding:20px 24px;max-width:1280px}
h2{font-size:15px;margin:24px 0 8px}
a{color:inherit}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}
.tile{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:12px 14px}
.tile h3{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between;gap:8px}
.tile ul{list-style:none;margin:0;padding:0}
.tile li{display:grid;grid-template-columns:1fr auto;gap:2px 8px;padding:6px 0;border-top:1px solid var(--grid)}
.tile .value{font-size:20px;font-weight:600}
.tile .meta,.meta{color:var(--muted);font-size:12px}
.status{display:inline-flex;gap:4px;align-items:center;color:var(--ink-2);font-size:12px;font-weight:600}
.icon.good circle{fill:var(--good)}.icon.critical circle{fill:var(--critical)}.icon.none circle{stroke:var(--muted)}
table{border-collapse:collapse;background:var(--surface);border:1px solid var(--border);font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:5px 10px;border-bottom:1px solid var(--grid);vertical-align:middle}
th{color:var(--ink-2);font-weight:600;font-size:12px}
td.num,th.num{text-align:right}
.empty{color:var(--muted)}
.legend{display:flex;gap:16px;color:var(--ink-2);font-size:12px;margin:4px 0}
.key{display:inline-block;width:14px;height:2px;vertical-align:middle;margin-right:6px}
.key.s1{background:var(--s1)}.key.s2{background:var(--s2)}
svg text{fill:var(--muted);font-size:11px;font-family:inherit}
.grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--axis);stroke-width:1}.limit{stroke:var(--ink-2);stroke-width:1}
.line{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
.line.s1{stroke:var(--s1)}.line.s2{stroke:var(--s2)}
.dot{stroke:var(--surface);stroke-width:2}.dot.s1{fill:var(--s1)}.dot.s2{fill:var(--s2)}
.spark-line{fill:none;stroke:var(--ink-2);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
.cp{stroke:var(--critical);stroke-width:1}
.band{fill:var(--band)}.band.regression{fill:var(--critical);fill-opacity:.12}.band.improvement{fill:var(--good);fill-opacity:.12}
.mark{fill:var(--ink-2)}
.hit{fill:transparent}.hit:hover{fill:var(--grid);fill-opacity:.35}
form{margin:0 0 12px}input{font:inherit;padding:4px 8px;background:var(--surface);color:var(--ink);border:1px solid var(--border);border-radius:6px}
"""

TABS = (("/", "Targets"), ("/series", "Series"), ("/alerts", "Alerts"), ("/jobs", "Pinpoint"),
        ("/coverage", "Coverage"), ("/field", "Field"), ("/stability", "Stability"))


def page(title: str, active: str, body: str) -> str:
    nav = "".join(f'<a href="{href}"{" class=on" if href == active else ""}>{esc(name)}</a>' for href, name in TABS)
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
            f"<meta http-equiv=\"Content-Security-Policy\" content=\"{CSP}\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            f"<title>{esc(title)} · cmux perf lab</title><style>{STYLE}</style></head>"
            f"<body><header><h1>cmux perf lab</h1><nav>{nav}</nav></header><main>{body}</main></body></html>\n")


def render_tile(tile: Tile) -> str:
    items = []
    for row in tile.rows:
        check = row.check
        limit = f"target {check.stat} {OP_TEXT[check.op]} {fmt_value(check.value, check.unit)}"
        title = f"{row.row.id} {check.stat}"
        if row.series is None:
            href = f"/series?q={quote(literal_prefix(check.metric))}"
            where = f"no series claims {row.row.id} for {check.metric}" + (
                f" at {row.row.hz} Hz" if row.row.hz is not None else "")
        else:
            href = series_href(row.series.key)
            where = f"{row.series.engine} · {row.series.host_class} · macOS {row.series.macos_major}"
            if row.point is not None:
                where += f" · {short_sha(row.point.sha)}"
                if row.status == "stale":
                    where += f" · newest point {row.point.started_at[:10]}, no current series"
        badge = ' <span class="meta">target_miss open</span>' if row.target_miss_open else ""
        items.append(f'<li><a href="{esc(href)}">{esc(title)}</a>{status_badge(row.status)}'
                     f'<span class="value">{esc(fmt_value(row.value, check.unit))}</span>'
                     f'<span class="meta">{esc(limit)}</span>'
                     f'<span class="meta">{esc(where)}{badge}</span></li>')
    return (f'<section class="tile {esc(tile.status)}" id="target-{esc(tile.target.id)}">'
            f'<h3><span>{esc(tile.target.id)}</span>{status_badge(tile.status)}</h3>'
            f'<p class="meta">{esc(tile.target.text)}</p><ul>{"".join(items)}</ul></section>')


def render_targets(tiles: Sequence[Tile], problem: str | None = None, catalog_problems: Sequence[str] = ()) -> str:
    if problem:
        return page("Targets", "/", f'<p class="empty">{esc(problem)}</p>')
    counts = {status: sum(1 for tile in tiles if tile.status == status) for status in ("pass", "miss", "no-data")}
    summary = (f'<p class="meta">{counts["pass"]} of {len(tiles)} targets pass · {counts["miss"]} miss · '
               f'{counts["no-data"]} without data. Newest point of each claiming series, at the Hz a row names.</p>')
    if catalog_problems:
        listed = "".join(f"<li>{esc(text)}</li>" for text in catalog_problems)
        summary += (f'<p class="meta">{len(catalog_problems)} catalog problems (<code>lab.py targets --check</code>):'
                    f'</p><ul class="problems">{listed}</ul>')
    return page("Targets", "/", summary + '<div class="tiles">' + "".join(render_tile(tile) for tile in tiles) + "</div>")


def render_series_list(rows: Sequence[SeriesListRow], total: int, query: str) -> str:
    form = (f'<form method="get" action="/series"><input name="q" value="{esc(query)}" placeholder="story or metric" '
            f'aria-label="Filter series"></form>')
    if not rows:
        return page("Series", "/series", form + '<p class="empty">No series match.</p>')
    body = ['<table><thead><tr><th>Story</th><th>Metric</th><th>Engine</th><th>Host class</th><th>macOS</th>'
            '<th>Config</th><th class="num">Latest p50</th><th>Last 50 points (p50)</th><th class="num">Notes</th></tr></thead><tbody>']
    for row in rows:
        info, points = row.info, row.points
        positions = [point.commit_pos for point in points]
        spans = (window_span(positions, start, end) for start, end in row.change_ranges)
        marks = sorted({span[0] for span in spans if span is not None})
        latest = points[-1].p50 if points else None
        body.append(f'<tr><td><a href="{series_href(info.key)}">{esc(info.story)}</a></td><td>{esc(info.metric)}</td>'
                    f'<td>{esc(info.engine)}</td><td>{esc(info.host_class)}</td><td>{info.macos_major}</td>'
                    f'<td>{esc(info.build_config)}</td><td class="num">{esc(fmt_value(latest, info.unit))}</td>'
                    f'<td>{sparkline([point.p50 for point in points], marks=marks, label=info.story + " p50")}</td>'
                    f'<td class="num">{row.annotation_count}</td></tr>')
    body.append("</tbody></table>")
    shown = f'<p class="meta">{len(rows)} of {total} series{" (refine the filter)" if total > len(rows) else ""}.</p>'
    return page("Series", "/series", form + shown + "".join(body))


def render_series(view: SeriesView, limits: Sequence[tuple[str, float]] = ()) -> str:
    info = view.info
    notes = sorted([*view.annotations, *derived_annotations(view.points)], key=lambda note: (note.start_pos, note.kind))
    chart_view = SeriesView(info, view.points, view.change_points, notes, view.reference_points)
    head = (f'<h2>{esc(info.story)} · {esc(info.metric)}</h2><p class="meta">{esc(info.engine)} · '
            f'{esc(info.host_class)} · macOS {info.macos_major} · {esc(info.build_config)} · '
            f'{esc(info.unit)}, {esc(info.better)} is better · key {esc(info.key)}</p>')
    legend = '<div class="legend"><span><i class="key s1"></i>p50</span><span><i class="key s2"></i>p99</span></div>'
    parts = [head, legend, series_chart(chart_view, limits=limits)]
    parts.append("<h2>Change points</h2>")
    if view.change_points:
        parts.append('<table><thead><tr><th>Rule</th><th>Range</th><th class="num">Before</th><th class="num">After</th>'
                     '<th>Direction</th><th>Group</th></tr></thead><tbody>')
        for cp in view.change_points:
            group = f'<a href="/alerts#group-{cp.group_id}">#{cp.group_id}</a>' if cp.group_id is not None else "–"
            parts.append(f'<tr><td>{esc(cp.rule)}</td><td>{cp.start_pos}..{cp.end_pos}</td>'
                         f'<td class="num">{esc(fmt_value(cp.median_before, info.unit))}</td>'
                         f'<td class="num">{esc(fmt_value(cp.median_after, info.unit))}</td>'
                         f'<td>{"improvement" if cp.is_improvement else "regression"}</td><td>{group}</td></tr>')
        parts.append("</tbody></table>")
    else:
        parts.append('<p class="empty">None.</p>')
    parts.append("<h2>Annotations</h2>")
    if notes:
        parts.append('<table><thead><tr><th>Kind</th><th>Range</th><th>Text</th></tr></thead><tbody>')
        parts.extend(f'<tr><td>{esc(note.kind)}</td><td>{note.start_pos}..{note.end_pos}</td><td>{esc(note.text)}</td></tr>'
                     for note in notes)
        parts.append("</tbody></table>")
    else:
        parts.append('<p class="empty">None.</p>')
    parts.append("<h2>Reference artifact</h2>")
    if view.reference_points:
        ref = view.reference_points
        parts.append(f'<p class="meta">{len(ref)} runs of the weekly-frozen build {esc(short_sha(ref[-1].sha))}, '
                     f'in time order; newest p50 {esc(fmt_value(ref[-1].p50, info.unit))}.</p>'
                     + sparkline([point.p50 for point in ref], width=320, height=40, label="reference p50"))
    else:
        parts.append('<p class="empty">No reference runs for this series.</p>')
    parts.append("<h2>Points</h2>")
    parts.append('<table><thead><tr><th class="num">Commit</th><th>SHA</th><th class="num">p50</th><th class="num">p99</th>'
                 '<th class="num">n</th><th>Features</th><th>macOS build</th><th>Safe mode</th><th>Host</th><th>Started</th>'
                 '</tr></thead><tbody>')
    for point in reversed(view.points):
        parts.append(f'<tr><td class="num">{point.commit_pos}</td><td>{esc(short_sha(point.sha))}</td>'
                     f'<td class="num">{esc(fmt_value(point.p50, info.unit))}</td>'
                     f'<td class="num">{esc(fmt_value(point.p99, info.unit))}</td><td class="num">{point.n}</td>'
                     f'<td>{esc(point.features_hash)}</td><td>{esc(point.macos_build)}</td><td>{esc(point.safe_mode)}</td>'
                     f'<td>{esc(point.host_name)}</td><td>{esc(point.started_at)}</td></tr>')
    parts.append("</tbody></table>")
    return page(f"{info.story} {info.metric}", "/series", "".join(parts))


def render_alerts(groups: Sequence[AlertGroupView]) -> str:
    if not groups:
        return page("Alerts", "/alerts", '<p class="empty">No alert groups.</p>')
    parts = []
    for group in groups:
        culprit = "–"
        if group.culprit_sha:
            culprit = f"{esc(short_sha(group.culprit_sha))} ({'verified' if group.culprit_verified else 'unverified'})"
        issue = (f'<a href="{esc(ISSUE_URL.format(number=group.issue_number))}">#{group.issue_number}</a>'
                 if group.issue_number is not None else "no issue")
        reason = f" · {esc(group.reason)}" if group.reason else ""
        parts.append(f'<h2 id="group-{group.id}">Group #{group.id} · {esc(group.state)}</h2>'
                     f'<p class="meta">range {group.start_pos}..{group.end_pos} · culprit {culprit} · {issue}'
                     f' · updated {esc(group.updated_at)}{reason}</p>')
        parts.append('<table><thead><tr><th>Series</th><th>Host class</th><th>Rule</th><th>Range</th>'
                     '<th class="num">Before</th><th class="num">After</th><th>Direction</th></tr></thead><tbody>')
        for alert in group.alerts:
            parts.append(f'<tr><td><a href="{series_href(alert.series.key)}">{esc(alert.series.story)} · '
                         f'{esc(alert.series.metric)}</a></td><td>{esc(alert.series.host_class)}</td><td>{esc(alert.rule)}</td>'
                         f'<td>{alert.start_pos}..{alert.end_pos}</td>'
                         f'<td class="num">{esc(fmt_value(alert.median_before, alert.series.unit))}</td>'
                         f'<td class="num">{esc(fmt_value(alert.median_after, alert.series.unit))}</td>'
                         f'<td>{"improvement" if alert.is_improvement else "regression"}</td></tr>')
        parts.append("</tbody></table>")
    return page("Alerts", "/alerts", "".join(parts))


def render_jobs(jobs: Sequence[JobView]) -> str:
    if not jobs:
        return page("Pinpoint", "/jobs", '<p class="empty">No Pinpoint jobs.</p>')
    parts = ['<table><thead><tr><th>Job</th><th>Kind</th><th>State</th><th>Story</th><th>Host class</th>'
             '<th>Base</th><th>Head</th><th>Group</th><th>Traces</th><th>Updated</th></tr></thead><tbody>']
    for job in jobs:
        traces = []
        for trace in job.traces:
            text = f"{trace.kind} #{trace.attempt}"
            url = safe_url(trace.url)
            traces.append(f'<a href="{esc(url)}">{esc(text)}</a>' if url else f'<span title="{esc(trace.digest)}">{esc(text)}</span>')
        group = f'<a href="/alerts#group-{job.alert_group_id}">#{job.alert_group_id}</a>' if job.alert_group_id else "–"
        trace_cell = ", ".join(traces) or "–"
        parts.append(f'<tr><td>{esc(job.controller_job_id or job.id)}</td><td>{esc(job.kind)}</td><td>{esc(job.state)}</td>'
                     f'<td>{esc(job.story or "")}</td><td>{esc(job.host_class or "")}</td>'
                     f'<td>{esc(short_sha(job.base_sha))}</td><td>{esc(short_sha(job.head_sha))}</td><td>{group}</td>'
                     f'<td>{trace_cell}</td><td>{esc(job.updated_at)}</td></tr>')
    parts.append("</tbody></table>")
    return page("Pinpoint", "/jobs", "".join(parts))


def render_coverage(rows: Sequence[CoverageRow], now: datetime) -> str:
    if not rows:
        return page("Coverage", "/coverage", '<p class="empty">No tiered waterfall runs yet.</p>')
    parts = ['<p class="meta">Newest waterfall run per tier, story and host. Stale: T0 over 60 min, T1 over 3 h, '
             'T2 over 26 h. Harness broken: the story errored on its last consecutive batches, so it measures '
             'nothing. Counts are the last 24 h.</p>',
             '<table><thead><tr><th>Tier</th><th>Story</th><th>Host</th><th>Host class</th><th>Newest run</th>'
             '<th>Age</th><th>State</th><th class="num">Runs</th><th class="num">Builds</th></tr></thead><tbody>']
    for row in rows:
        limit = STALE_AFTER.get(row.tier)
        state = ("broken" if row.broken else
                 "stale" if limit is not None and now - row.last_run_at > limit else "fresh")
        parts.append(f'<tr><td>{esc(row.tier)}</td><td>{esc(row.story)}</td><td>{esc(row.host_name)}</td>'
                     f'<td>{esc(row.host_class)}</td><td>{esc(row.last_run_at.isoformat(timespec="seconds"))}</td>'
                     f'<td>{esc(age_text(now, row.last_run_at))}</td><td>{status_badge(state)}</td>'
                     f'<td class="num">{row.runs_24h}</td><td class="num">{row.builds_24h}</td></tr>')
    parts.append("</tbody></table>")
    return page("Coverage", "/coverage", "".join(parts))


def render_field(rows: Sequence[FieldRow]) -> str:
    intro = ('<p class="meta">Opt-in Nightly hang reports, per build and hardware class, split by features arm. '
             'Reported, not judged.</p>')
    if not rows:
        return page("Field", "/field", intro + '<p class="empty">No field data imported yet.</p>')
    parts = [intro, '<table><thead><tr><th>Build</th><th>Hardware class</th><th>Metric</th><th>Arm</th>'
             '<th class="num">Value</th><th class="num">Samples</th></tr></thead><tbody>']
    for row in sorted(rows, key=lambda r: (r.build, r.hardware_class, r.metric, r.arm)):
        parts.append(f'<tr><td>{esc(row.build)}</td><td>{esc(row.hardware_class)}</td><td>{esc(row.metric)}</td>'
                     f'<td>{esc(row.arm)}</td><td class="num">{esc(fmt_value(row.value, row.unit))}</td>'
                     f'<td class="num">{row.samples}</td></tr>')
    parts.append("</tbody></table>")
    return page("Field", "/field", "".join(parts))


def render_stability(rows: Sequence[StabilityRow]) -> str:
    intro = '<p class="meta">Sentry crash-free rates per Nightly release and new top signatures. Reported, not judged.</p>'
    if not rows:
        return page("Stability", "/stability", intro + '<p class="empty">No stability data imported yet.</p>')

    def percent(value: float | None) -> str:
        return "–" if value is None else f"{value * 100:.2f} %"

    parts = [intro, '<table><thead><tr><th>Release</th><th class="num">Crash-free sessions</th>'
             '<th class="num">Crash-free installs</th><th class="num">New signatures</th></tr></thead><tbody>']
    for row in rows:
        parts.append(f'<tr><td>{esc(row.release)}</td><td class="num">{percent(row.crash_free_sessions)}</td>'
                     f'<td class="num">{percent(row.crash_free_installs)}</td><td class="num">{row.new_signatures}</td></tr>')
    parts.append("</tbody></table>")
    return page("Stability", "/stability", "".join(parts))


@dataclass(frozen=True)
class Page:
    status: int
    body: str
    content_type: str = "text/html; charset=utf-8"


def not_found(what: str) -> Page:
    return Page(404, page("Not found", "", f'<p class="empty">{esc(what)}</p>'))


@dataclass
class Dashboard:
    """Routes a GET path to a page. labd builds one per request thread with that thread's source."""
    source: DashboardSource
    targets: Sequence[Target] | None
    clock: Callable[[], datetime] = field(default=lambda: datetime.now(timezone.utc))
    targets_problem: str | None = None
    catalog_problems: Sequence[str] = ()

    def tiles(self) -> list[Tile]:
        series = self.source.all_series()
        targets = self.targets or ()
        keys = sorted({info.key for target in targets for row in target.rows for info in series
                       if judged_checks(row, info)})
        latest = self.source.latest_points(keys)
        samples: dict[str, list[float]] = {}

        def stat_of(key: str, stat: str) -> float | None:
            point = latest[key]
            if stat in ("p50", "p99"):
                return point.stat(stat)
            if key not in samples:
                samples[key] = self.source.latest_samples(key)
            return sample_stat(samples[key], stat)

        return build_tiles(targets, series, latest, stat_of, self.source.target_miss_series(),
                           fresh_since=self.clock() - TILE_STALE_AFTER)

    def limits_for(self, info: SeriesInfo) -> list[tuple[str, float]]:
        return [(f"{row.id}: {check.stat} {OP_TEXT[check.op]} {fmt_value(check.value, check.unit)}", check.value)
                for target in self.targets or () for row in target.rows for check in judged_checks(row, info)]

    def handle(self, raw_path: str) -> Page:
        parts = urlsplit(raw_path)
        path = parts.path.rstrip("/") or "/"
        query = parse_qs(parts.query)
        try:
            if path in ("/", "/status"):
                if self.targets is None:
                    return Page(200, render_targets((), self.targets_problem or "No targets.json loaded."))
                return Page(200, render_targets(self.tiles(), catalog_problems=self.catalog_problems))
            if path == "/series":
                text = query.get("q", [""])[0][:200]
                rows, total = self.source.series_list(text, SERIES_LIST_LIMIT)
                return Page(200, render_series_list(rows, total, text))
            if path.startswith("/series/"):
                key = unquote(path[len("/series/"):])
                try:
                    limit = min(max(int(query.get("n", [SERIES_POINTS_DEFAULT])[0]), 2), SERIES_POINTS_MAX)
                except ValueError:
                    limit = SERIES_POINTS_DEFAULT
                view = self.source.series(key, limit)
                if view is None:
                    return not_found(f"No series {key}.")
                return Page(200, render_series(view, self.limits_for(view.info)))
            if path == "/alerts":
                return Page(200, render_alerts(self.source.alert_groups()))
            if path == "/jobs":
                return Page(200, render_jobs(self.source.jobs(JOBS_LIMIT)))
            if path == "/coverage":
                now = self.clock()
                return Page(200, render_coverage(self.source.coverage(now - timedelta(hours=24)), now))
            if path == "/field":
                return Page(200, render_field(self.source.field_rows()))
            if path == "/stability":
                return Page(200, render_stability(self.source.stability_rows()))
        except DashboardError as error:
            return Page(503, page("Unavailable", "", f'<p class="empty">{esc(error)}</p>'))
        return not_found(f"No page {path}.")


# ---------- the store as a source ----------


def _point(row: sqlite3.Row) -> PointView:
    samples = [value for value in json.loads(row["samples_json"]) if isinstance(value, (int, float))]
    summary = json.loads(row["summary_json"]) if row["summary_json"] else {}
    p50 = perf_stats.pct(samples, 0.50) if samples else summary.get("p50")
    p99 = perf_stats.pct(samples, 0.99) if samples else summary.get("p99")
    return PointView(row["commit_pos"], row["sha"], row["started_at"], p50, p99, len(samples), row["features_hash"],
                     row["macos_build"], row["safe_mode"], row["host_name"])


def _series_info(row: sqlite3.Row) -> SeriesInfo:
    return SeriesInfo(row["series_key"], row["story"], row["metric"], row["engine"], row["host_class"],
                      row["macos_major"], row["build_config"], row["unit"], row["better"], row["target_ref"])


_POINTS_SQL = """
SELECT * FROM (
  SELECT r.series_id, s.series_key, b.commit_pos, b.sha, u.started_at, r.samples_json, r.summary_json,
         u.features_hash, u.macos_build, u.safe_mode, h.name AS host_name,
         ROW_NUMBER() OVER (PARTITION BY r.series_id ORDER BY {order}) AS rn
  FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
  JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
  WHERE u.kind = ? AND s.series_key IN ({keys}))
WHERE rn <= ? ORDER BY series_key, rn DESC"""
# Waterfall points follow store.Store.series_points: commit order, then start time, then row id.
_WATERFALL_ORDER = "b.commit_pos DESC, u.started_at DESC, r.id DESC"
# Reference runs all measure one frozen build, so they go in time order.
_REFERENCE_ORDER = "u.started_at DESC, r.id DESC"


class StoreSource:
    """Reads the lab store (store.py schema) through its own read-only connection, one per thread like Store.

    Field and stability rows come from the providers labd passes in (tasks 042, 223, 225 own those reads).
    """

    def __init__(self, path: Path | str, *, field_rows: Callable[[], Sequence[FieldRow]] = lambda: (),
                 stability_rows: Callable[[], Sequence[StabilityRow]] = lambda: ()) -> None:
        if not Path(path).exists():
            raise DashboardError(f"{path}: no lab store")
        self._db = sqlite3.connect(f"file:{quote(str(Path(path).resolve()))}?mode=ro", uri=True)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA query_only=ON")
        self._field_rows = field_rows
        self._stability_rows = stability_rows

    def close(self) -> None:
        self._db.close()

    def _query(self, sql: str, args: Sequence[object] = ()) -> list[sqlite3.Row]:
        try:
            return self._db.execute(sql, tuple(args)).fetchall()
        except sqlite3.OperationalError as error:
            raise DashboardError(f"lab store not readable ({error}); run the store migrations") from error

    def _points(self, keys: Sequence[str], limit: int, *, kind: str = "waterfall") -> dict[str, list[PointView]]:
        if not keys:
            return {}
        order = _REFERENCE_ORDER if kind == "reference" else _WATERFALL_ORDER
        sql = _POINTS_SQL.format(order=order, keys=",".join("?" * len(keys)))
        points: dict[str, list[PointView]] = {}
        for row in self._query(sql, [kind, *keys, limit]):
            points.setdefault(row["series_key"], []).append(_point(row))
        return points

    def all_series(self) -> list[SeriesInfo]:
        return [_series_info(row) for row in self._query("SELECT * FROM series ORDER BY story, metric, series_key")]

    def latest_points(self, keys: Sequence[str]) -> dict[str, PointView]:
        return {key: points[-1] for key, points in self._points(keys, 1).items()}

    def latest_samples(self, key: str) -> list[float]:
        rows = self._query(
            """SELECT r.samples_json FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
               JOIN builds b ON b.id = u.build_id WHERE s.series_key = ? AND u.kind = 'waterfall'
               ORDER BY """ + _WATERFALL_ORDER + " LIMIT 1", [key])
        return list(json.loads(rows[0]["samples_json"])) if rows else []

    def target_miss_series(self) -> set[str]:
        """Series with a stored target_miss alert. alerts.py never groups or closes one, so a tile row calls it
        open only while the row itself misses."""
        rows = self._query("""SELECT DISTINCT s.series_key FROM alerts a JOIN series s ON s.id = a.series_id
                              WHERE a.rule = 'target_miss'""")
        return {row["series_key"] for row in rows}

    def series_list(self, query: str, limit: int) -> tuple[list[SeriesListRow], int]:
        literal = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        like = f"%{literal}%"
        where = "WHERE story LIKE ? ESCAPE '\\' OR metric LIKE ? ESCAPE '\\' OR host_class LIKE ? ESCAPE '\\'"
        total = self._query(f"SELECT COUNT(*) FROM series {where}", [like] * 3)[0][0]
        infos = [_series_info(row) for row in self._query(
            f"SELECT * FROM series {where} ORDER BY story, metric, host_class, series_key LIMIT ?", [like] * 3 + [limit])]
        keys = [info.key for info in infos]
        points = self._points(keys, SPARKLINE_POINTS)
        marks: dict[str, list[tuple[int, int]]] = {}
        notes: dict[str, int] = {}
        if keys:
            holders = ",".join("?" * len(keys))
            for row in self._query(f"""SELECT s.series_key, a.start_pos, a.end_pos FROM alerts a
                                       JOIN series s ON s.id = a.series_id
                                       WHERE a.rule = 'edivisive' AND a.is_improvement = 0
                                       AND s.series_key IN ({holders})""", keys):
                marks.setdefault(row["series_key"], []).append((row["start_pos"], row["end_pos"]))
            shared = self._query("SELECT COUNT(*) FROM annotations WHERE series_id IS NULL")[0][0]
            for row in self._query(f"""SELECT s.series_key, COUNT(a.id) AS n FROM series s
                                       LEFT JOIN annotations a ON a.series_id = s.id
                                       WHERE s.series_key IN ({holders}) GROUP BY s.series_key""", keys):
                notes[row["series_key"]] = row["n"] + shared
        rows = [SeriesListRow(info, points.get(info.key, []), marks.get(info.key, []), notes.get(info.key, 0))
                for info in infos]
        return rows, total

    def series(self, key: str, limit: int) -> SeriesView | None:
        found = self._query("SELECT * FROM series WHERE series_key = ?", [key])
        if not found:
            return None
        info = _series_info(found[0])
        change_points = [ChangePointView(row["rule"], row["start_pos"], row["end_pos"], row["median_before"],
                                         row["median_after"], bool(row["is_improvement"]), row["group_id"])
                         for row in self._query("""SELECT a.* FROM alerts a JOIN series s ON s.id = a.series_id
                                                   WHERE s.series_key = ? ORDER BY a.start_pos, a.id""", [key])]
        annotations = [AnnotationView(row["kind"], row["start_pos"], row["end_pos"], row["text"])
                       for row in self._query("""SELECT a.* FROM annotations a LEFT JOIN series s ON s.id = a.series_id
                                                 WHERE a.series_id IS NULL OR s.series_key = ?
                                                 ORDER BY a.start_pos, a.id""", [key])]
        return SeriesView(info, self._points([key], limit).get(key, []), change_points, annotations,
                          self._points([key], SPARKLINE_POINTS, kind="reference").get(key, []))

    def alert_groups(self) -> list[AlertGroupView]:
        """The newest ALERT_GROUPS_LIMIT groups, open ones first: newer closed groups never push out an open one."""
        closed = ",".join("?" * len(CLOSED_GROUP_STATES))
        groups = self._query(f"""SELECT * FROM alert_groups ORDER BY state IN ({closed}), updated_at DESC, id DESC
                                 LIMIT ?""", [*sorted(CLOSED_GROUP_STATES), ALERT_GROUPS_LIMIT])
        if not groups:
            return []
        ids = [row["id"] for row in groups]
        alerts: dict[int, list[AlertView]] = {}
        holders = ",".join("?" * len(ids))
        for row in self._query(f"""SELECT a.id AS alert_id, a.group_id, a.rule, a.start_pos, a.end_pos, a.median_before,
                                          a.median_after, a.is_improvement, s.*
                                   FROM alerts a JOIN series s ON s.id = a.series_id
                                   WHERE a.group_id IN ({holders}) ORDER BY a.id""", ids):
            alerts.setdefault(row["group_id"], []).append(AlertView(
                row["alert_id"], _series_info(row), row["rule"], row["start_pos"], row["end_pos"], row["median_before"],
                row["median_after"], bool(row["is_improvement"])))
        return [AlertGroupView(row["id"], row["state"], row["start_pos"], row["end_pos"], row["culprit_sha"],
                               bool(row["culprit_verified"]), row["issue_number"], row["reason"], row["updated_at"],
                               alerts.get(row["id"], [])) for row in groups]

    def jobs(self, limit: int) -> list[JobView]:
        kinds = ",".join("?" * len(PINPOINT_KINDS))
        rows = self._query(f"SELECT * FROM jobs WHERE kind IN ({kinds}) ORDER BY updated_at DESC, id DESC LIMIT ?",
                           [*PINPOINT_KINDS, limit])
        traces: dict[int, list[TraceView]] = {}
        if rows:
            ids = [row["id"] for row in rows]
            holders = ",".join("?" * len(ids))
            for trace in self._query(f"""SELECT * FROM traces WHERE job_id IN ({holders})
                                         ORDER BY attempt, id""", ids):
                traces.setdefault(trace["job_id"], []).append(
                    TraceView(trace["kind"], trace["digest"], trace["url"], trace["attempt"]))
        return [JobView(row["id"], row["controller_job_id"], row["kind"], row["state"], row["story"], row["host_class"],
                        row["base_sha"], row["head_sha"], row["alert_group_id"], row["updated_at"],
                        traces.get(row["id"], [])) for row in rows]

    def coverage(self, since: datetime) -> list[CoverageRow]:
        stamp = since.astimezone(timezone.utc).isoformat(timespec="microseconds")
        rows = self._query(
            """SELECT u.tier, u.story, h.name AS host_name, h.host_class, MAX(u.started_at) AS last_run,
                      SUM(u.started_at >= ?) AS runs, COUNT(DISTINCT CASE WHEN u.started_at >= ? THEN u.build_id END) AS builds
               FROM runs u JOIN hosts h ON h.id = u.host_id
               WHERE u.kind = 'waterfall' AND u.tier IS NOT NULL
               GROUP BY u.tier, u.story, h.name, h.host_class ORDER BY u.tier, u.story, h.name""", [stamp, stamp])
        try:
            broken = _load_sibling("harness_alerts").broken_stories(self._db)
        except sqlite3.OperationalError as error:
            raise DashboardError(f"lab store not readable ({error}); run the store migrations") from error
        return [CoverageRow(row["tier"], row["story"], row["host_name"], row["host_class"], parse_stamp(row["last_run"]),
                            row["runs"] or 0, row["builds"] or 0, broken=(row["story"], row["host_class"]) in broken)
                for row in rows]

    def field_rows(self) -> list[FieldRow]:
        return list(self._field_rows())

    def stability_rows(self) -> list[StabilityRow]:
        return list(self._stability_rows())


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render one perf lab dashboard page from a lab store to stdout.")
    parser.add_argument("--db", required=True, type=Path, help="the lab store (SQLite)")
    parser.add_argument("--root", type=Path, default=catalog.REPO_ROOT,
                        help="the repository root whose targets.json and stories.d define the tiles")
    parser.add_argument("--path", default="/", help="the page path, for example /series?q=launch")
    args = parser.parse_args(argv)
    targets, problem, problems = None, None, ()
    try:
        targets, problems = load_targets(args.root)
    except DashboardError as error:
        problem = str(error)
    try:
        source = StoreSource(args.db)
    except DashboardError as error:
        print(error, file=sys.stderr)
        return 2
    try:
        result = Dashboard(source, targets, targets_problem=problem, catalog_problems=problems).handle(args.path)
    finally:
        source.close()
    sys.stdout.write(result.body)
    return 0 if result.status == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
