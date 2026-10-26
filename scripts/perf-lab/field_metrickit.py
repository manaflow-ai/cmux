#!/usr/bin/env python3
"""Field MetricKit series: schema-2 hang reports to per-Nightly launch, hitch, hang and action rows.

Opt-in NIGHTLY hang reports (plans/cmux-next/hang-reports-DESIGN.md section 4, `HangReport.swift`)
carry MetricKit's aggregated histograms and the watchdog's stall histogram. This module decodes
every metric field of a stored `hang_reports.payload` and folds the reports of one Nightly build
and hardware class into field rows (p12-perf-process.md 3.10):

- launch: `launchFirstDraw`, `launchResume`, `launchOptimizedFirstDraw`, `launchExtended`
  (merged histograms, p50 and p95)
- hitch: `scrollHitchMsPerS`, `hitchMsPerS` (one value per report; p50 and p95 over reports)
- hang: `hangTime` (MetricKit) and `stallHistogram` (watchdog): p50, p95 and the count of
  stalls of 250 ms or more
- intervals: each allowlisted signpost interval (`action.commit`, `switch.workspace`, ...):
  p50, p95 and its hitch ms/s

Chromium's field model: UMA keeps bucketed histograms, never raw samples, and its dashboards
read percentiles from the buckets. The estimate here is catapult's
(`tracing/tracing/value/histogram.py` `Histogram.GetApproximatePercentile`): skip
floor((n - 1) * q) values, then report the center of the bucket that holds the next one, or its
finite edge when the bucket is open. Values that are one number per report (hitch ratios) are
real samples and use `perf_stats.pct`, the lab's one percentile definition.

A report that is not schema 2 or breaks the wire limits is skipped and counted by reason; it is
never partly used. Field rows are reported on the dashboard's Field tab, never judged.

Read: one `BEGIN READ ONLY` SELECT on `hang_reports` through `psql`, connected by libpq
environment variables made from `CMUX_FIELD_DATABASE_URL` (a read-only role on `cmux-prod`
branch `main`). The credential is never in argv or output.

  CMUX_FIELD_DATABASE_URL=... python3 scripts/perf-lab/field_metrickit.py --since 7d
  python3 scripts/perf-lab/field_metrickit.py --rows rows.ndjson --json
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

SCHEMA_VERSION = 2
# HistogramBucket.maxBuckets / maxMs, HangReport.maxIntervals, HangReportSignposts.
MAX_BUCKETS = 32
MAX_MS = 86_400_000
MAX_INTERVALS = 64
INTERVAL_CATEGORIES = frozenset({"action", "motion", "key", "switch", "create", "cef", "launch"})
INTERVAL_NAME = re.compile(r"^[a-z0-9_.\-]{1,48}$")
CHANNELS = ("nightly", "dev", "rc", "release")
STALL_COUNT_FLOOR_MS = 250
DATABASE_URL_ENV = "CMUX_FIELD_DATABASE_URL"
DEFAULT_ARM = "default"

# The histogram metrics of `metrics`: wire key -> series name.
HISTOGRAM_METRICS = (
    ("hangTime", "hang.time"),
    ("launchFirstDraw", "launch.first_draw"),
    ("launchResume", "launch.resume"),
    ("launchOptimizedFirstDraw", "launch.optimized_first_draw"),
    ("launchExtended", "launch.extended"),
)
# The ratio metrics of `metrics`: wire key -> series name.
RATIO_METRICS = (
    ("scrollHitchMsPerS", "hitch.scroll"),
    ("hitchMsPerS", "hitch.all"),
)
METRICS_KEYS = frozenset(key for key, _ in HISTOGRAM_METRICS + RATIO_METRICS)
BUCKET_KEYS = frozenset({"lowMs", "highMs", "count"})
INTERVAL_KEYS = frozenset({"category", "name", "count", "buckets", "hitchMsPerS"})
QUANTILES = (("p50", 0.5), ("p95", 0.95))


def _load_perf_stats():
    name = "perf_lab_perf_stats"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "perf_stats.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load_perf_stats()


class FieldDecodeError(ValueError):
    """A stored report that this module refuses; `reason` is the skip-count key."""

    def __init__(self, reason: str, detail: str = ""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason


class FieldReadError(RuntimeError):
    """The read-only query could not run (no credential, psql failed, bad output)."""


@dataclass(frozen=True)
class Bucket:
    low_ms: int
    high_ms: int
    count: int


@dataclass(frozen=True)
class Interval:
    category: str
    name: str
    count: int
    buckets: tuple[Bucket, ...]
    hitch_ms_per_s: float | None


@dataclass(frozen=True)
class MetricKitReport:
    """Every MetricKit and watchdog aggregate of one schema-2 report."""
    histograms: Mapping[str, tuple[Bucket, ...]]  # HISTOGRAM_METRICS wire key -> buckets
    ratios: Mapping[str, float | None]  # RATIO_METRICS wire key -> ms per s
    stall_histogram: tuple[Bucket, ...]
    intervals: tuple[Interval, ...]


@dataclass(frozen=True)
class FieldRow:
    """One field aggregate; the same fields as dashboard.py's FieldRow, which the Field tab renders."""
    build: str
    hardware_class: str
    metric: str
    value: float | None
    unit: str
    samples: int
    arm: str = DEFAULT_ARM


@dataclass
class FieldAggregate:
    rows: list[FieldRow]
    reports: int
    skipped: dict[str, int] = field(default_factory=dict)


# ---------- decode ----------


def _int(value: object, what: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise FieldDecodeError("bad_type", f"{what} is not an integer")
    return value


def _ratio(value: object, what: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise FieldDecodeError("bad_type", f"{what} is not a finite ratio")
    return float(value)


def _exact_keys(obj: object, allowed: frozenset[str], what: str, required: frozenset[str]) -> Mapping:
    if not isinstance(obj, Mapping):
        raise FieldDecodeError("bad_type", f"{what} is not an object")
    unknown = set(obj) - allowed
    if unknown:
        raise FieldDecodeError("unknown_key", f"{what}.{sorted(unknown)[0]}")
    missing = required - set(obj)
    if missing:
        raise FieldDecodeError("missing_key", f"{what}.{sorted(missing)[0]}")
    return obj


def decode_buckets(value: object, what: str) -> tuple[Bucket, ...]:
    """A wire histogram (`[{lowMs, highMs, count}]`), checked against HistogramBucket's limits."""
    if not isinstance(value, list):
        raise FieldDecodeError("bad_type", f"{what} is not a list")
    if len(value) > MAX_BUCKETS:
        raise FieldDecodeError("over_limit", f"{what} has {len(value)} buckets")
    buckets = []
    for index, raw in enumerate(value):
        item = _exact_keys(raw, BUCKET_KEYS, f"{what}[{index}]", BUCKET_KEYS)
        low, high, count = (_int(item[key], f"{what}[{index}].{key}") for key in ("lowMs", "highMs", "count"))
        if not 0 <= low <= high <= MAX_MS or count < 0:
            raise FieldDecodeError("out_of_range", f"{what}[{index}]")
        buckets.append(Bucket(low, high, count))
    return tuple(sorted(buckets, key=lambda b: (b.low_ms, b.high_ms)))


def decode_interval(value: object, index: int) -> Interval:
    what = f"intervals[{index}]"
    item = _exact_keys(value, INTERVAL_KEYS, what, INTERVAL_KEYS - {"hitchMsPerS"})
    category, name = item["category"], item["name"]
    if category not in INTERVAL_CATEGORIES or not isinstance(name, str) or not INTERVAL_NAME.match(name):
        raise FieldDecodeError("bad_interval", what)
    count = _int(item["count"], f"{what}.count")
    if count < 0:
        raise FieldDecodeError("out_of_range", f"{what}.count")
    return Interval(category, name, count, decode_buckets(item["buckets"], f"{what}.buckets"),
                    _ratio(item.get("hitchMsPerS"), f"{what}.hitchMsPerS"))


def decode_payload(payload: object) -> MetricKitReport:
    """The metric fields of one stored report; FieldDecodeError when it is not a valid schema-2 report."""
    if not isinstance(payload, Mapping):
        raise FieldDecodeError("bad_type", "payload is not an object")
    if payload.get("schema") != SCHEMA_VERSION:
        raise FieldDecodeError("schema", f"schema {payload.get('schema')!r}")
    metrics = _exact_keys(payload.get("metrics", {}), METRICS_KEYS, "metrics", frozenset())
    histograms = {key: decode_buckets(metrics.get(key, []), f"metrics.{key}") for key, _ in HISTOGRAM_METRICS}
    ratios = {key: _ratio(metrics.get(key), f"metrics.{key}") for key, _ in RATIO_METRICS}
    raw_intervals = payload.get("intervals", [])
    if not isinstance(raw_intervals, list):
        raise FieldDecodeError("bad_type", "intervals is not a list")
    if len(raw_intervals) > MAX_INTERVALS:
        raise FieldDecodeError("over_limit", f"{len(raw_intervals)} intervals")
    return MetricKitReport(
        histograms=histograms,
        ratios=ratios,
        stall_histogram=decode_buckets(payload.get("stallHistogram", []), "stallHistogram"),
        intervals=tuple(decode_interval(raw, index) for index, raw in enumerate(raw_intervals)),
    )


def build_key(row: Mapping) -> str:
    """`<version>+<build>` from the row's app columns (a Nightly's build number is unique per cut)."""
    version, build = row.get("app_version"), row.get("app_build")
    if not isinstance(version, str) or not isinstance(build, str) or not version or not build:
        raise FieldDecodeError("no_build", "app_version or app_build missing")
    return f"{version}+{build}"


def hardware_class(row: Mapping) -> str:
    """`<arch>/<chip>/<memory>gb/<cores>c` from the row's hardware columns (HardwareClass.swift)."""
    arch, chip, memory, cores = (row.get(key) for key in ("arch", "chip", "memory_gb", "cores"))
    if not isinstance(arch, str) or not isinstance(chip, str):
        raise FieldDecodeError("no_hardware", "arch or chip missing")
    memory, cores = _int(memory, "memory_gb"), _int(cores, "cores")
    return f"{arch}/{chip.strip().lower().replace(' ', '-')}/{memory}gb/{cores}c"


# ---------- statistics ----------


def merge_buckets(histograms: Iterable[Sequence[Bucket]]) -> tuple[Bucket, ...]:
    """Histograms summed by edge pair (MetricKit repeats edge pairs across payloads), nonzero only, sorted."""
    counts: dict[tuple[int, int], int] = {}
    for buckets in histograms:
        for bucket in buckets:
            if bucket.count > 0:
                edges = (bucket.low_ms, bucket.high_ms)
                counts[edges] = counts.get(edges, 0) + bucket.count
    return tuple(Bucket(low, high, counts[(low, high)]) for low, high in sorted(counts))


def histogram_percentile(buckets: Sequence[Bucket], q: float) -> float | None:
    """catapult Histogram.GetApproximatePercentile on sorted buckets; None when empty.

    The bucket holding value number floor((n - 1) * q) gives its center, or its low edge when it
    is open at the top (high is MAX_MS, as StallAggregate's last bucket).
    """
    if not 0 <= q <= 1:
        raise ValueError("q must be in [0, 1]")
    total = sum(bucket.count for bucket in buckets)
    if total == 0:
        return None
    to_skip = math.floor((total - 1) * q)
    for bucket in buckets:
        to_skip -= bucket.count
        if to_skip >= 0:
            continue
        if bucket.high_ms >= MAX_MS:
            return float(bucket.low_ms)
        return (bucket.low_ms + bucket.high_ms) / 2
    return float(buckets[-1].low_ms)


def _histogram_rows(series: str, buckets: Sequence[Bucket]) -> list[tuple[str, float | None, str, int]]:
    samples = sum(bucket.count for bucket in buckets)
    if samples == 0:
        return []
    return [(f"{series}.{label}", histogram_percentile(buckets, q), "ms", samples) for label, q in QUANTILES]


def _ratio_rows(series: str, values: Sequence[float]) -> list[tuple[str, float | None, str, int]]:
    if not values:
        return []
    return [(f"{series}.{label}", perf_stats.pct(values, q), "ms/s", len(values)) for label, q in QUANTILES]


@dataclass
class _Group:
    reports: int = 0
    histograms: dict[str, list[tuple[Bucket, ...]]] = field(default_factory=dict)
    ratios: dict[str, list[float]] = field(default_factory=dict)
    intervals: dict[str, list[tuple[Bucket, ...]]] = field(default_factory=dict)
    interval_hitch: dict[str, list[float]] = field(default_factory=dict)

    def add(self, report: MetricKitReport) -> None:
        self.reports += 1
        for key, buckets in report.histograms.items():
            self.histograms.setdefault(key, []).append(buckets)
        self.histograms.setdefault("stallHistogram", []).append(report.stall_histogram)
        for key, value in report.ratios.items():
            if value is not None:
                self.ratios.setdefault(key, []).append(value)
        for interval in report.intervals:
            self.intervals.setdefault(interval.name, []).append(interval.buckets)
            if interval.hitch_ms_per_s is not None:
                self.interval_hitch.setdefault(interval.name, []).append(interval.hitch_ms_per_s)

    def metrics(self) -> list[tuple[str, float | None, str, int]]:
        out: list[tuple[str, float | None, str, int]] = []
        for key, series in HISTOGRAM_METRICS:
            out += _histogram_rows(series, merge_buckets(self.histograms.get(key, ())))
        stalls = merge_buckets(self.histograms.get("stallHistogram", ()))
        out += _histogram_rows("hang.stall", stalls)
        long_stalls = sum(b.count for b in stalls if b.low_ms >= STALL_COUNT_FLOOR_MS)
        out.append(("hang.stalls_over_250ms", float(long_stalls), "count", self.reports))
        for key, series in RATIO_METRICS:
            out += _ratio_rows(series, self.ratios.get(key, []))
        for name in sorted(self.intervals):
            out += _histogram_rows(f"interval.{name}", merge_buckets(self.intervals[name]))
            out += _ratio_rows(f"interval.{name}.hitch", self.interval_hitch.get(name, []))
        return out


def aggregate(rows: Iterable[Mapping], *, channel: str | None = "nightly") -> FieldAggregate:
    """Field rows per build and hardware class from stored `hang_reports` rows (payload as an object or JSON text).

    Rows of another channel are skipped as `channel`; a refused report is skipped by its decode reason.
    """
    groups: dict[tuple[str, str], _Group] = {}
    skipped: dict[str, int] = {}
    used = 0
    for row in rows:
        try:
            if channel is not None and row.get("channel") != channel:
                raise FieldDecodeError("channel")
            payload = row.get("payload")
            if isinstance(payload, str):
                try:
                    payload = json.loads(payload)
                except json.JSONDecodeError as error:
                    raise FieldDecodeError("bad_json") from error
            report = decode_payload(payload)
            key = (build_key(row), hardware_class(row))
        except FieldDecodeError as error:
            skipped[error.reason] = skipped.get(error.reason, 0) + 1
            continue
        used += 1
        groups.setdefault(key, _Group()).add(report)
    out = [FieldRow(build=build, hardware_class=hw, metric=metric, value=value, unit=unit, samples=samples)
           for (build, hw), group in sorted(groups.items())
           for metric, value, unit, samples in group.metrics()]
    return FieldAggregate(rows=out, reports=used, skipped=dict(sorted(skipped.items())))


# ---------- read ----------

SELECT_COLUMNS = ("app_version", "app_build", "channel", "arch", "chip", "cores", "memory_gb", "payload")


def select_sql(*, since_days: int, channel: str | None) -> str:
    """The one read: a read-only transaction around a SELECT; every inlined value is validated first."""
    if isinstance(since_days, bool) or not isinstance(since_days, int) or not 1 <= since_days <= 90:
        raise ValueError("since_days must be an integer in [1, 90]")
    if channel is not None and channel not in CHANNELS:
        raise ValueError(f"channel must be one of {CHANNELS}")
    where = f"received_at >= now() - interval '{since_days} days'"
    if channel is not None:
        where += f" AND channel = '{channel}'"
    return ("BEGIN READ ONLY;\n"
            f"SELECT row_to_json(r) FROM (SELECT {', '.join(SELECT_COLUMNS)} FROM hang_reports WHERE {where}) r;\n"
            "COMMIT;\n")


def libpq_environment(database_url: str) -> dict[str, str]:
    """libpq variables for a `postgres://` URL, so psql gets the credential from its environment, not argv.

    TLS checks the server against the system CAs (`sslrootcert=system`, libpq 16) unless the URL names an sslmode.
    """
    parts = urlsplit(database_url)
    if parts.scheme not in ("postgres", "postgresql") or not parts.hostname:
        raise FieldReadError(f"{DATABASE_URL_ENV} is not a postgres:// URL")
    env = {"PGHOST": parts.hostname, "PGSSLMODE": "verify-full", "PGSSLROOTCERT": "system",
           "PGOPTIONS": "-c default_transaction_read_only=on"}
    if parts.port:
        env["PGPORT"] = str(parts.port)
    if parts.username:
        env["PGUSER"] = unquote(parts.username)
    if parts.password:
        env["PGPASSWORD"] = unquote(parts.password)
    if parts.path.strip("/"):
        env["PGDATABASE"] = unquote(parts.path.strip("/"))
    sslmode = parse_qs(parts.query).get("sslmode")
    if sslmode and sslmode[-1] != "verify-full":
        env["PGSSLMODE"] = sslmode[-1]
        del env["PGSSLROOTCERT"]  # libpq refuses sslrootcert=system with a weaker sslmode
    return env


Runner = Callable[..., subprocess.CompletedProcess]


def read_rows(*, since_days: int, channel: str | None, environ: Mapping[str, str] = os.environ,
              run: Runner = subprocess.run) -> list[dict]:
    """The rows of the read-only query, run by `psql` with the credential in its environment only."""
    url = environ.get(DATABASE_URL_ENV)
    if not url:
        raise FieldReadError(f"{DATABASE_URL_ENV} is not set")
    pg_env = libpq_environment(url)
    env = {key: value for key, value in environ.items() if key != DATABASE_URL_ENV and not key.startswith("PG")}
    env.update(pg_env)
    result = run(["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-f", "-"],
                 input=select_sql(since_days=since_days, channel=channel), env=env,
                 capture_output=True, text=True, check=False)
    if result.returncode != 0:
        message = (result.stderr or "").strip().splitlines()[:1]
        detail = message[0] if message else ""
        password = pg_env.get("PGPASSWORD")
        if password:
            detail = detail.replace(password, "***")
        raise FieldReadError(f"psql exited {result.returncode}: {detail}")
    rows = []
    for line in result.stdout.splitlines():
        if line.strip():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise FieldReadError("psql printed a line that is not a JSON row") from error
    return rows


def load_rows_file(path: Path) -> list[dict]:
    """Rows from a file: a JSON array, or one JSON object per line."""
    text = path.read_text()
    stripped = text.lstrip()
    if stripped.startswith("["):
        return json.loads(stripped)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


# ---------- CLI ----------


def _since_days(text: str) -> int:
    match = re.fullmatch(r"([0-9]{1,2})d", text)
    if not match:
        raise argparse.ArgumentTypeError("use Nd, for example 7d")
    return int(match.group(1))


def render_text(result: FieldAggregate) -> str:
    lines = [f"reports used: {result.reports}"]
    lines += [f"skipped {reason}: {count}" for reason, count in result.skipped.items()]
    for row in result.rows:
        value = "-" if row.value is None else f"{row.value:g}"
        lines.append(f"{row.build}\t{row.hardware_class}\t{row.arm}\t{row.metric}\t{value} {row.unit}\tn={row.samples}")
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="MetricKit field series from opt-in Nightly hang reports (read only).")
    parser.add_argument("--since", type=_since_days, default=7, help="window, Nd (default 7d)")
    parser.add_argument("--channel", choices=CHANNELS, default="nightly")
    parser.add_argument("--rows", type=Path, help="read stored rows from this file instead of the database")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        rows = load_rows_file(args.rows) if args.rows else read_rows(since_days=args.since, channel=args.channel)
    except (FieldReadError, ValueError, OSError) as error:
        print(f"field_metrickit: {error}", file=sys.stderr)
        return 2
    result = aggregate(rows, channel=args.channel)
    if args.json:
        print(json.dumps({"reports": result.reports, "skipped": result.skipped,
                          "rows": [asdict(row) for row in result.rows]}, indent=2))
    else:
        sys.stdout.write(render_text(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
