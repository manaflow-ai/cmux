#!/usr/bin/env python3
"""Field MetricKit series: the schema-2 metrics of Nightly hang reports per build and hardware class
(p12-perf-process-223, p12-perf-process.md 3.10).

    CMUX_FIELD_DATABASE_URL=... python3 -I scripts/perf-lab/lab.py field-metrickit --since 7d [--json] [--out PATH]
    python3 -I scripts/perf-lab/lab.py field-metrickit --fixture rows.jsonl --json

Every hang report (`HangReport.swift`; schema 2, and schema 3 which keeps every schema-2 field) carries MetricKit's
aggregated histograms and ratios, the watchdog's stall histogram and the allowlisted signpost intervals
(`HangReportSignposts`). This module decodes each of those fields with the server's wire limits
(web/services/hangReports/wireSchema.ts) and folds the reports of one Nightly build, hardware class and features
arm into field series for the launch, hang, hitch and action targets (targets.json):

- launch: `launchFirstDraw`, `launchResume`, `launchOptimizedFirstDraw`, `launchExtended` (merged histograms)
- hang: `hangTime` (MetricKit) and `stallHistogram` (the watchdog's stalls of 50 ms and up)
- hitch: `scrollHitchMsPerS`, `hitchMsPerS`, one ratio per report
- interval: each signpost interval of a schema-2 category (`action.commit`, `switch.workspace`, ...) and its
  hitch ms/s; the schema-3 `main` intervals are field.py's turn histograms

Chrome's field data is UMA histograms per channel, version and hardware class, read as percentiles of the merged
buckets (docs/speed/how_does_chrome_measure_performance.md, base/metrics/histogram.h). Histograms here merge and
read their p50, p95 and p99 (field.py's PERCENTILES: the field targets are stated at the tail, as Chrome's speed
metrics are) with field.py's `percentile` (one bucket model for every field series); an open top bucket
(`highMs` = 86 400 000, the watchdog's last stall bucket) counts at its low edge, as catapult's overflow bin
(tracing/tracing/value/histogram.py, Histogram.GetApproximatePercentile). A ratio is one real sample per report,
so its percentiles use perf_stats.pct, the lab's percentile. A p99 of few samples is the top sample; each row
carries its sample count, so a reader (or an alert) can require enough of them.

A report whose metric fields break the wire limits is skipped whole and counted by reason, never partly used.
The read is field.py's: one read-only SELECT on `hang_reports` after the role's write-privilege check, the
credential (CMUX_FIELD_DATABASE_URL) only in psql's PG* environment. The SELECT reads no frames and no install id.
Rows have dashboard.FieldRow's fields, so the Field tab shows them beside field.py's; they are reported, never
judged.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field as dataclass_field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent


def _sibling(stem: str):
    """A sibling module under lab.py's name for it (perf_lab_<stem>), so both share one copy."""
    name = f"perf_lab_{stem}"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / f"{stem}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


field = _sibling("field")
perf_stats = _sibling("perf_stats")

LAB_COMMANDS = {"field-metrickit": "Nightly field MetricKit series: launch p50/p95/p99, hitch ms/s, hang time and "
                                   "signpost intervals per build and hardware class (read-only hang_reports)."}

SCHEMAS = frozenset({2, 3})
# wireSchema.ts / wirePrimitives.ts: MAX_BUCKETS, MAX_INTERVALS, MAX_DURATION_MS, MAX_COUNT, MAX_MS_PER_S.
MAX_BUCKETS = 32
MAX_INTERVALS = 64
MAX_MS = 86_400_000
MAX_COUNT = 1_000_000_000
MAX_MS_PER_S = 1000
# HangReportSignposts.categories (schema 2); schema 3 adds `main`, the turn histograms field.py reports.
INTERVAL_CATEGORIES = frozenset({"action", "motion", "key", "switch", "create", "cef", "launch"})
TURN_CATEGORY = "main"
INTERVAL_NAME = re.compile(r"^[a-z0-9_.\-]{1,48}$")

# Wire key of `metrics` -> series.
HISTOGRAM_METRICS = (
    ("launchFirstDraw", "launch.first_draw"),
    ("launchResume", "launch.resume"),
    ("launchOptimizedFirstDraw", "launch.optimized_first_draw"),
    ("launchExtended", "launch.extended"),
    ("hangTime", "hang.time"),
)
RATIO_METRICS = (
    ("scrollHitchMsPerS", "hitch.scroll_ms_per_s"),
    ("hitchMsPerS", "hitch.ms_per_s"),
)
STALL_SERIES = "hang.stall"
INTERVAL_PREFIX = "interval"
# The field percentiles, field.py's (its action and turn histograms read the same three).
QUANTILES = field.PERCENTILES
# Series prefix -> the targets.json target it is the field view of (the action budget has no target there).
SERIES_TARGETS = {"launch.": "launch", "hang.": "hangs", "hitch.": "motion-dropped"}

Bucket = tuple[int, int, int]  # (lowMs, highMs, count), field.py's shape


class MetricKitDecodeError(ValueError):
    """A stored report this module refuses; `reason` is its skip-count key."""

    def __init__(self, reason: str, detail: str):
        super().__init__(f"{reason}: {detail}")
        self.reason = reason


@dataclass(frozen=True)
class Interval:
    name: str
    buckets: tuple[Bucket, ...]
    hitch_ms_per_s: float | None


@dataclass(frozen=True)
class MetricKitReport:
    """The schema-2 metric fields of one report."""
    histograms: Mapping[str, tuple[Bucket, ...]]  # HISTOGRAM_METRICS wire key -> buckets
    ratios: Mapping[str, float | None]  # RATIO_METRICS wire key -> ms per s
    stalls: tuple[Bucket, ...]
    intervals: tuple[Interval, ...]


# --- decode -----------------------------------------------------------------------------------------------------------

def _bounded_int(value: object, limit: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= limit


def decode_buckets(value: object, what: str) -> tuple[Bucket, ...]:
    """A wire histogram, absent or null as empty. An open top bucket becomes a point at its low edge."""
    if value is None:
        return ()
    if not isinstance(value, list):
        raise MetricKitDecodeError("bad_bucket", f"{what} is not a list")
    if len(value) > MAX_BUCKETS:
        raise MetricKitDecodeError("over_limit", f"{what} has {len(value)} buckets")
    out = []
    for index, raw in enumerate(value):
        if not isinstance(raw, Mapping):
            raise MetricKitDecodeError("bad_bucket", f"{what}[{index}] is not an object")
        low, high, count = raw.get("lowMs"), raw.get("highMs"), raw.get("count")
        if not (_bounded_int(low, MAX_MS) and _bounded_int(high, MAX_MS) and _bounded_int(count, MAX_COUNT)
                and low <= high):
            raise MetricKitDecodeError("bad_bucket", f"{what}[{index}]")
        if count:
            out.append((low, low if high == MAX_MS else high, count))
    return tuple(out)


def decode_ratio(value: object, what: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) \
            or not 0 <= value <= MAX_MS_PER_S:
        raise MetricKitDecodeError("bad_ratio", what)
    return float(value)


def decode_intervals(value: object) -> tuple[Interval, ...]:
    """The schema-2 category intervals; a `main` interval is skipped (field.py's turn histograms)."""
    if value is None:
        return ()
    if not isinstance(value, list):
        raise MetricKitDecodeError("bad_interval", "intervals is not a list")
    if len(value) > MAX_INTERVALS:
        raise MetricKitDecodeError("over_limit", f"{len(value)} intervals")
    out = []
    for index, raw in enumerate(value):
        what = f"intervals[{index}]"
        if not isinstance(raw, Mapping):
            raise MetricKitDecodeError("bad_interval", f"{what} is not an object")
        category, name = raw.get("category"), raw.get("name")
        if category == TURN_CATEGORY:
            continue
        if category not in INTERVAL_CATEGORIES or not isinstance(name, str) or not INTERVAL_NAME.match(name) \
                or not _bounded_int(raw.get("count"), MAX_COUNT):
            raise MetricKitDecodeError("bad_interval", what)
        out.append(Interval(name, decode_buckets(raw.get("buckets"), f"{what}.buckets"),
                            decode_ratio(raw.get("hitchMsPerS"), f"{what}.hitchMsPerS")))
    return tuple(out)


def decode_report(row: Mapping[str, Any]) -> MetricKitReport:
    """The metric fields of one query row (or a stored payload's fields under the same keys)."""
    schema = row.get("schema")
    if isinstance(schema, bool) or schema not in SCHEMAS:
        raise MetricKitDecodeError("schema", f"schema {schema!r}")
    metrics = row.get("metrics")
    if metrics is None:
        metrics = {}
    if not isinstance(metrics, Mapping):
        raise MetricKitDecodeError("bad_metrics", "metrics is not an object")
    return MetricKitReport(
        histograms={key: decode_buckets(metrics.get(key), f"metrics.{key}") for key, _ in HISTOGRAM_METRICS},
        ratios={key: decode_ratio(metrics.get(key), f"metrics.{key}") for key, _ in RATIO_METRICS},
        stalls=decode_buckets(row.get("stall_histogram"), "stallHistogram"),
        intervals=decode_intervals(row.get("intervals")),
    )


# --- aggregation ------------------------------------------------------------------------------------------------------

@dataclass
class Group:
    build: str
    hardware_class: str
    arm: str
    reports: int = 0
    histograms: dict[str, dict[tuple[int, int], int]] = dataclass_field(default_factory=dict)
    ratios: dict[str, list[float]] = dataclass_field(default_factory=dict)
    intervals: dict[str, dict[tuple[int, int], int]] = dataclass_field(default_factory=dict)
    interval_hitch: dict[str, list[float]] = dataclass_field(default_factory=dict)

    def add(self, report: MetricKitReport) -> None:
        self.reports += 1
        for key, series in HISTOGRAM_METRICS:
            field.merge(self.histograms.setdefault(series, {}), report.histograms[key])
        field.merge(self.histograms.setdefault(STALL_SERIES, {}), report.stalls)
        for key, series in RATIO_METRICS:
            if report.ratios[key] is not None:
                self.ratios.setdefault(series, []).append(report.ratios[key])
        for interval in report.intervals:
            series = f"{INTERVAL_PREFIX}.{interval.name}"
            field.merge(self.intervals.setdefault(series, {}), interval.buckets)
            if interval.hitch_ms_per_s is not None:
                self.interval_hitch.setdefault(f"{series}.hitch_ms_per_s", []).append(interval.hitch_ms_per_s)


@dataclass
class Aggregate:
    groups: list[Group]
    skipped: dict[str, int]

    @property
    def reports(self) -> int:
        return sum(group.reports for group in self.groups)


def aggregate(rows: Iterable[Mapping[str, Any]]) -> Aggregate:
    """Groups by (build, hardware class, features arm), field.py's keys, so the rows line up on the Field tab."""
    groups: dict[tuple[str, str, str], Group] = {}
    skipped: dict[str, int] = {}
    for row in rows:
        try:
            report = decode_report(row)
        except MetricKitDecodeError as error:
            skipped[error.reason] = skipped.get(error.reason, 0) + 1
            continue
        arm = row.get("features_hash")
        key = (field.build_label(row.get("app_version"), row.get("app_build")),
               field.hardware_class(row.get("chip"), row.get("memory_gb")),
               arm if isinstance(arm, str) and arm else field.NO_ARM)
        group = groups.get(key)
        if group is None:
            group = groups[key] = Group(*key)
        group.add(report)
    return Aggregate([groups[key] for key in sorted(groups)], dict(sorted(skipped.items())))


def field_rows(groups: Sequence[Group]) -> list[dict[str, Any]]:
    """dashboard.FieldRow-shaped rows; a series with no sample in a group has no row."""
    rows = []

    def add(group: Group, metric: str, value: float | None, unit: str, samples: int) -> None:
        rows.append({"build": group.build, "hardware_class": group.hardware_class, "metric": metric,
                     "value": None if value is None else round(value, 4), "unit": unit, "samples": samples,
                     "arm": group.arm})

    for group in groups:
        add(group, "metrickit.reports", group.reports, "count", group.reports)
        for histograms in (group.histograms, group.intervals):
            for series, histogram in sorted(histograms.items()):
                samples = sum(histogram.values())
                if samples:
                    for label, q in QUANTILES:
                        add(group, f"{series}.{label}", field.percentile(histogram, q), "ms", samples)
        for ratios in (group.ratios, group.interval_hitch):
            for series, values in sorted(ratios.items()):
                for label, q in QUANTILES:
                    add(group, f"{series}.{label}", perf_stats.pct(values, q), "ms/s", len(values))
    return rows


def target_of(metric: str) -> str | None:
    """The targets.json id a field series is the field view of, or None."""
    for prefix, target in SERIES_TARGETS.items():
        if metric.startswith(prefix):
            return target
    return None


def report(result: Aggregate, *, since_hours: int | None, channel: str, source: str) -> dict[str, Any]:
    rows = field_rows(result.groups)
    return {
        "source": source,
        "channel": channel,
        "since_hours": since_hours,
        "reports": result.reports,
        "skipped": result.skipped,
        "targets": {metric: target for metric in sorted({row["metric"] for row in rows})
                    if (target := target_of(metric)) is not None},
        "rows": rows,
    }


# --- the read ---------------------------------------------------------------------------------------------------------

def reports_query(*, since_hours: int, channel: str) -> str:
    """One JSON row per report of the window: the build, hardware and features keys and the metric fields only."""
    if isinstance(since_hours, bool) or not isinstance(since_hours, int) \
            or not 1 <= since_hours <= field.MAX_SINCE_HOURS:
        raise field.FieldError(f"since must be 1 h to {field.MAX_SINCE_HOURS} h")
    if channel not in field.CHANNELS:
        raise field.FieldError(f"channel must be one of {', '.join(field.CHANNELS)}")
    columns = ", ".join([
        "'app_version', app_version", "'app_build', app_build", "'chip', chip", "'memory_gb', memory_gb",
        f"'features_hash', {field._FEATURES_HASH}", "'schema', payload->'schema'", "'metrics', payload->'metrics'",
        "'stall_histogram', payload->'stallHistogram'", "'intervals', payload->'intervals'"])
    return field._read_only(
        f"SELECT json_build_object({columns})::text FROM {field.TABLE} "
        f"WHERE received_at >= now() - make_interval(hours => {since_hours}) AND channel = '{channel}' "
        "ORDER BY received_at")


def fetch_rows(*, since_hours: int, channel: str, credential: field.Credential,
               runner: field.PsqlRunner | None = None,
               environ: Mapping[str, str] | None = None) -> list[dict[str, Any]]:
    runner = field.subprocess_runner if runner is None else runner
    field.check_read_only(credential, runner=runner, environ=environ)
    return field.run_select(reports_query(since_hours=since_hours, channel=channel), credential, runner=runner,
                            environ=environ)


# --- the command ------------------------------------------------------------------------------------------------------

def render_text(result: Mapping[str, Any]) -> str:
    lines = [f"field-metrickit: {result['reports']} {result['channel']} reports"
             + (f" in the last {result['since_hours']} h" if result.get("since_hours") else "")
             + f" ({result['source']})"]
    lines += [f"  skipped {reason}: {count}" for reason, count in result["skipped"].items()]
    for row in result["rows"]:
        value = "-" if row["value"] is None else f"{row['value']:g}"
        lines.append(f"  {row['build']}  {row['hardware_class']}  {row['arm']}  {row['metric']}: "
                     f"{value} {row['unit']} (n={row['samples']})")
    return "\n".join(lines)


def metrickit_command(args: argparse.Namespace, *, runner: field.PsqlRunner | None = None,
                      environ: Mapping[str, str] | None = None, out: Any = None) -> int:
    environ = os.environ if environ is None else environ
    out = sys.stdout if out is None else out
    if args.fixture:
        try:
            rows = field.parse_rows(Path(args.fixture).read_text(encoding="utf-8"))
        except OSError as error:
            raise field.FieldError(f"cannot read the fixture: {error.strerror or error}") from None
        except UnicodeDecodeError as error:
            raise field.FieldError(f"the fixture is not UTF-8 (byte {error.start})") from None
        result = report(aggregate(rows), since_hours=None, channel=args.channel, source="fixture")
    else:
        since_hours = field.parse_since(args.since)
        credential = field.credential_from_environment(environ)
        rows = fetch_rows(since_hours=since_hours, channel=args.channel, credential=credential, runner=runner,
                          environ=environ)
        result = report(aggregate(rows), since_hours=since_hours, channel=args.channel, source=field.SOURCE)
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        try:
            field.write_atomically(Path(args.out), text + "\n")
        except OSError as error:
            raise field.FieldError(f"cannot write --out: {error.strerror or error}") from None
    print(text if args.json else render_text(result), file=out)
    return 0


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    field.add_arguments(command, parser)


def run(command: str, args: argparse.Namespace) -> int:
    """lab.py's command hook: `lab.py field-metrickit`; a typed error exits 2."""
    try:
        return metrickit_command(args)
    except field.FieldError as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="field_metrickit.py", description=LAB_COMMANDS["field-metrickit"])
    add_arguments("field-metrickit", parser)
    return run("field-metrickit", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
