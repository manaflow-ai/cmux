#!/usr/bin/env python3
"""A/A noise report: how noisy each monitored series is when nothing changed (p12-perf-process-024).

Each lab host runs T0 twice on one artifact every night (the scheduler's `aa` job, task 011). The two
runs are stored as kind `aa` with the build, host and story of a waterfall point, so each pair is an
A/A experiment on the same series key. For each monitored series this module reports:

- CV of the per-run median and of the per-run p99: the root-mean-square CV of duplicate measurements,
  sqrt(sum(((a - b) / mean(a, b))^2) / 2k) over the k pairs. Each pair compares runs of one artifact,
  so the nightly change of artifact does not count as noise.
- False alerts: the alerts the lab would raise on data with no change.
  - compare: catapult Pinpoint's compare (perf_stats.compare, compare/compare.py) on the raw samples of
    A and B. A DIFFERENT by the strict rule (p <= 0.01, the culprit-verification rule) is one false
    alert. The bisect rule's DIFFERENT count (p <= 0.05) is reported beside it.
  - anomaly: catapult's find_change_points (task 003, anomaly.py) on the pair ratio series B/A of the
    per-run median and of the per-run p99, run on every prefix as ingest does, each change point
    counted once. A/B order is arbitrary, so a change point in either direction is a false alert.
  The rate is false alerts per 100 series-days (one series-day = one A/A pair).

`lab.py aa --since-live|--days N [--json]` prints the report; `--cv-over X --json` prints only the
noisy series (MQ11, one de-noise task each). The thresholds of done check 9 (p12-perf-process.md 5)
are the module constants below; this module never widens a threshold to clear a series.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import sqlite3
import sys
from collections import defaultdict
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import TextIO

HERE = Path(__file__).resolve().parent

DB_ENV = "CMUX_PERF_LAB_DB"
LATENCY_UNITS = frozenset({"ms", "us", "ns", "s"})
# Done check 9 (p12-perf-process.md section 5).
DONE_FALSE_ALERTS_PER_100 = 1.0
DONE_MEDIAN_CV = 0.05
DONE_MEDIAN_SHARE = 0.90
DONE_P99_CV = 0.10
DONE_P99_SHARE = 0.80
DONE_MIN_AA_RUNS_PER_HOST = 3
# A series needs this many pairs before its CV is judged or listed as noisy.
MIN_PAIRS = 3


class AAError(RuntimeError):
    pass


def _load(module_name: str, filename: str):
    if module_name in sys.modules:
        return sys.modules[module_name]
    path = HERE / filename
    if not path.exists():
        raise AAError(f"{path.name} is missing; the A/A report needs it")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load("perf_lab_perf_stats", "perf_stats.py")


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


@dataclass(frozen=True)
class AARun:
    series: SeriesInfo
    host: str
    build_id: int
    sha: str
    job_id: int | None
    run_uuid: str
    started_at: str
    samples: tuple[float, ...]


@dataclass(frozen=True)
class Pair:
    series: SeriesInfo
    host: str
    sha: str
    started_at: str
    a: tuple[float, ...]
    b: tuple[float, ...]


@dataclass(frozen=True)
class SeriesNoise:
    key: str
    story: str
    metric: str
    engine: str
    host_class: str
    macos_major: int
    build_config: str
    unit: str
    pairs: int
    pairs_by_host: dict[str, int]
    cv_median: float | None
    cv_p99: float | None
    compare_different_strict: int
    compare_different_bisect: int
    anomaly_alerts_median: int
    anomaly_alerts_p99: int
    false_alerts: int
    false_alerts_per_100: float


# The detector takes catapult's series form, (x, y) pairs oldest first, and returns change points that
# carry catapult's ChangePoint.x_value. Monitored answers whether subscriptions.json matches a series.
Detector = Callable[[Sequence[tuple[int, float]]], Sequence[object]]
Monitored = Callable[[SeriesInfo], bool]


def catapult_detector() -> Detector:
    """anomaly.find_change_points (task 003), catapult's FindChangePoints with catapult's defaults."""
    return _load("perf_lab_anomaly", "anomaly.py").find_change_points


def subscribed() -> Monitored:
    """alerts.is_monitored (task 014): True when a subscriptions.json entry matches the series."""
    alerts = _load("perf_lab_alerts", "alerts.py")

    def monitored(series: SeriesInfo) -> bool:
        return bool(alerts.is_monitored(story=series.story, metric=series.metric, engine=series.engine,
                                        host_class=series.host_class, macos_major=series.macos_major,
                                        build_config=series.build_config))

    return monitored


def _connect(db_path: Path | str) -> sqlite3.Connection:
    path = Path(db_path)
    if not path.exists():
        raise AAError(f"{path}: no lab store")
    db = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def _stamp(moment: datetime) -> str:
    """The store's fixed-width UTC stamp (store._stamp), so a bound compares as text."""
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise AAError(f"{moment.isoformat()}: a window bound needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


def live_since(db_path: Path | str) -> datetime:
    """When the lab went live: the first stored waterfall run."""
    db = _connect(db_path)
    try:
        first = db.execute("SELECT MIN(started_at) FROM runs WHERE kind = 'waterfall'").fetchone()[0]
    finally:
        db.close()
    if first is None:
        raise AAError("the lab has no waterfall run yet, so it is not live; use --days N")
    return datetime.fromisoformat(first)


def read_aa_runs(db_path: Path | str, since: datetime) -> list[AARun]:
    """Every A/A run result started at or after `since`, oldest first."""
    db = _connect(db_path)
    try:
        rows = db.execute(
            """SELECT s.series_key, s.story, s.metric, s.engine, s.host_class, s.macos_major, s.build_config,
                      s.unit, s.better, h.name AS host, u.build_id, b.sha, u.job_id, u.run_uuid, u.started_at,
                      r.samples_json
               FROM results r JOIN runs u ON u.id = r.run_id JOIN series s ON s.id = r.series_id
               JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
               WHERE u.kind = 'aa' AND u.started_at >= ?
               ORDER BY u.started_at, u.id, r.id""", (_stamp(since),)).fetchall()
    finally:
        db.close()
    return [AARun(SeriesInfo(row["series_key"], row["story"], row["metric"], row["engine"], row["host_class"],
                             row["macos_major"], row["build_config"], row["unit"], row["better"]),
                  row["host"], row["build_id"], row["sha"], row["job_id"], row["run_uuid"], row["started_at"],
                  tuple(float(v) for v in json.loads(row["samples_json"])))
            for row in rows]


def pair_runs(runs: Sequence[AARun]) -> list[Pair]:
    """A/A pairs: consecutive runs of one series on one host and one artifact, within one job.

    A run without a job id belongs to its UTC day's experiment. An unpaired last run is dropped.
    """
    groups: dict[tuple, list[AARun]] = defaultdict(list)
    for run in runs:
        experiment = run.job_id if run.job_id is not None else run.started_at[:10]
        groups[(run.series.key, run.host, run.build_id, experiment)].append(run)
    pairs = []
    for members in groups.values():
        members.sort(key=lambda run: (run.started_at, run.run_uuid))
        for a, b in zip(members[0::2], members[1::2]):
            pairs.append(Pair(a.series, a.host, a.sha, a.started_at, a.samples, b.samples))
    pairs.sort(key=lambda pair: (pair.started_at, pair.series.key, pair.host))
    return pairs


def duplicate_cv(values: Sequence[tuple[float, float]]) -> float | None:
    """Root-mean-square CV of duplicate measurements; None without a usable pair.

    A pair whose mean is 0 counts as 0 when both values are 0 and is skipped otherwise (no CV exists).
    """
    terms = []
    for a, b in values:
        if a == b:
            terms.append(0.0)
            continue
        mean = (a + b) / 2
        if mean == 0:
            continue
        terms.append(((a - b) / mean) ** 2)
    if not terms:
        return None
    return math.sqrt(sum(terms) / (2 * len(terms)))


def _ratio_series(values: Sequence[tuple[float, float]]) -> list[tuple[int, float]]:
    return [(index, b / a) for index, (a, b) in enumerate(values) if a != 0]


def change_points(series: Sequence[tuple[int, float]], detector: Detector) -> int:
    """Distinct change points the detector finds over every prefix of the series, as ingest would."""
    found = set()
    for end in range(1, len(series) + 1):
        for point in detector(series[:end]):
            found.add(point.x_value)
    return len(found)


def _stats(pairs: Sequence[Pair], q: float) -> list[tuple[float, float]]:
    out = []
    for pair in pairs:
        a, b = perf_stats.pct(pair.a, q), perf_stats.pct(pair.b, q)
        if a is not None and b is not None:
            out.append((a, b))
    return out


def series_noise(series: SeriesInfo, pairs: Sequence[Pair], detector: Detector) -> SeriesNoise:
    by_host: dict[str, list[Pair]] = defaultdict(list)
    for pair in pairs:
        by_host[pair.host].append(pair)
    strict = bisect = 0
    for pair in pairs:
        comparison = perf_stats.compare(pair.a, pair.b)
        strict += comparison.original.result == perf_stats.DIFFERENT
        bisect += comparison.floored.result == perf_stats.DIFFERENT
    # A ratio series per host: a host's noise level is its own, and hosts never share a series point.
    anomaly_median = sum(change_points(_ratio_series(_stats(host_pairs, 0.50)), detector)
                         for host_pairs in by_host.values())
    anomaly_p99 = sum(change_points(_ratio_series(_stats(host_pairs, 0.99)), detector)
                      for host_pairs in by_host.values())
    false_alerts = strict + anomaly_median + anomaly_p99
    return SeriesNoise(
        key=series.key, story=series.story, metric=series.metric, engine=series.engine,
        host_class=series.host_class, macos_major=series.macos_major, build_config=series.build_config,
        unit=series.unit, pairs=len(pairs), pairs_by_host={host: len(p) for host, p in sorted(by_host.items())},
        cv_median=duplicate_cv(_stats(pairs, 0.50)), cv_p99=duplicate_cv(_stats(pairs, 0.99)),
        compare_different_strict=strict, compare_different_bisect=bisect,
        anomaly_alerts_median=anomaly_median, anomaly_alerts_p99=anomaly_p99,
        false_alerts=false_alerts, false_alerts_per_100=100.0 * false_alerts / len(pairs))


def _share(values: Sequence[float | None], limit: float) -> float | None:
    judged = [value for value in values if value is not None]
    if not judged:
        return None
    return sum(value <= limit for value in judged) / len(judged)


def report(pairs: Sequence[Pair], *, since: datetime, monitored: Monitored, detector: Detector,
           min_pairs: int = MIN_PAIRS) -> dict:
    """The A/A report over monitored series: one row per series and the done-check summary."""
    by_series: dict[str, list[Pair]] = defaultdict(list)
    infos: dict[str, SeriesInfo] = {}
    verdicts: dict[str, bool] = {}
    for pair in pairs:
        key = pair.series.key
        if key not in verdicts:
            verdicts[key] = monitored(pair.series)
        if verdicts[key]:
            by_series[key].append(pair)
            infos[key] = pair.series
    rows = [series_noise(infos[key], by_series[key], detector) for key in sorted(by_series)]
    rows.sort(key=lambda row: (row.story, row.metric, row.host_class, row.engine, row.key))

    experiments: dict[str, set] = defaultdict(set)
    for key in by_series:
        for pair in by_series[key]:
            experiments[pair.host].add((pair.sha, pair.started_at[:10]))
    series_days = sum(row.pairs for row in rows)
    false_alerts = sum(row.false_alerts for row in rows)
    judged = [row for row in rows if row.pairs >= min_pairs and row.unit in LATENCY_UNITS]
    per_100 = 100.0 * false_alerts / series_days if series_days else None
    median_share = _share([row.cv_median for row in judged], DONE_MEDIAN_CV)
    p99_share = _share([row.cv_p99 for row in judged], DONE_P99_CV)
    runs_by_host = {host: len(found) for host, found in sorted(experiments.items())}
    summary = {
        "since": _stamp(since),
        "series": len(rows),
        "series_days": series_days,
        "false_alerts": false_alerts,
        "false_alerts_per_100_series_days": per_100,
        "latency_series_judged": len(judged),
        "median_cv_share_within": median_share,
        "p99_cv_share_within": p99_share,
        "aa_runs_by_host": runs_by_host,
        "hosts_under_min_aa_runs": [host for host, n in runs_by_host.items() if n < DONE_MIN_AA_RUNS_PER_HOST],
        "checks": {
            "false_alerts": per_100 is not None and per_100 <= DONE_FALSE_ALERTS_PER_100,
            "median_cv": median_share is not None and median_share >= DONE_MEDIAN_SHARE,
            "p99_cv": p99_share is not None and p99_share >= DONE_P99_SHARE,
        },
        "thresholds": {
            "false_alerts_per_100": DONE_FALSE_ALERTS_PER_100, "median_cv": DONE_MEDIAN_CV,
            "median_share": DONE_MEDIAN_SHARE, "p99_cv": DONE_P99_CV, "p99_share": DONE_P99_SHARE,
            "min_aa_runs_per_host": DONE_MIN_AA_RUNS_PER_HOST, "min_pairs": min_pairs,
        },
    }
    return {"summary": summary, "series": [asdict(row) for row in rows]}


def noisy(rows: Sequence[dict], *, cv_over: float, p99_cv_over: float, min_pairs: int = MIN_PAIRS) -> list[dict]:
    """Series with enough pairs whose median CV exceeds cv_over or whose p99 CV exceeds p99_cv_over (MQ11)."""
    def over(row: dict) -> bool:
        return ((row["cv_median"] is not None and row["cv_median"] > cv_over)
                or (row["cv_p99"] is not None and row["cv_p99"] > p99_cv_over))

    listed = [row for row in rows if row["pairs"] >= min_pairs and over(row)]
    listed.sort(key=lambda row: (-(row["cv_median"] or 0.0), -(row["cv_p99"] or 0.0), row["key"]))
    return listed


def _pct(value: float | None) -> str:
    return "-" if value is None else f"{100 * value:.1f}%"


def _print_rows(rows: Sequence[dict], out: TextIO) -> None:
    for row in rows:
        print(f"{row['story']}  {row['metric']}  {row['host_class']}  {row['engine']}  pairs={row['pairs']}  "
              f"cv_median={_pct(row['cv_median'])}  cv_p99={_pct(row['cv_p99'])}  "
              f"false_alerts={row['false_alerts']}", file=out)


def _print_summary(summary: dict, out: TextIO) -> None:
    per_100 = summary["false_alerts_per_100_series_days"]
    checks = summary["checks"]
    print(f"A/A since {summary['since']}: {summary['series']} monitored series, "
          f"{summary['series_days']} series-days", file=out)
    print(f"false alerts: {summary['false_alerts']} "
          f"({'-' if per_100 is None else f'{per_100:.2f}'} per 100 series-days, limit "
          f"{DONE_FALSE_ALERTS_PER_100:g}) {'ok' if checks['false_alerts'] else 'FAIL'}", file=out)
    print(f"median CV <= {_pct(DONE_MEDIAN_CV)}: {_pct(summary['median_cv_share_within'])} of "
          f"{summary['latency_series_judged']} latency series (need {_pct(DONE_MEDIAN_SHARE)}) "
          f"{'ok' if checks['median_cv'] else 'FAIL'}", file=out)
    print(f"p99 CV <= {_pct(DONE_P99_CV)}: {_pct(summary['p99_cv_share_within'])} "
          f"(need {_pct(DONE_P99_SHARE)}) {'ok' if checks['p99_cv'] else 'FAIL'}", file=out)
    for host, runs in summary["aa_runs_by_host"].items():
        print(f"host {host}: {runs} A/A runs", file=out)


def add_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", default=os.environ.get(DB_ENV),
                        help=f"the lab SQLite store (default: ${DB_ENV})")
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--since-live", action="store_true",
                        help="since the first stored waterfall run (the default)")
    window.add_argument("--days", type=int, metavar="N", help="the last N days")
    parser.add_argument("--cv-over", type=float, metavar="X",
                        help="list only series whose median CV is over X (MQ11)")
    parser.add_argument("--p99-cv-over", type=float, metavar="Y",
                        help="with --cv-over: the p99 CV limit (default 2X, the done check's 5 %% to 10 %% ratio)")
    parser.add_argument("--min-pairs", type=int, default=MIN_PAIRS,
                        help=f"pairs a series needs to be judged (default {MIN_PAIRS})")
    parser.add_argument("--json", action="store_true", help="print JSON")


def run(args: argparse.Namespace, *, clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        detector: Detector | None = None, monitored: Monitored | None = None, out: TextIO = sys.stdout) -> int:
    if not args.db:
        raise AAError(f"no lab store: pass --db or set {DB_ENV}")
    if args.days is not None and args.days <= 0:
        raise AAError("--days needs a positive number")
    if args.p99_cv_over is not None and args.cv_over is None:
        raise AAError("--p99-cv-over needs --cv-over")
    since = clock() - timedelta(days=args.days) if args.days is not None else live_since(args.db)
    result = report(pair_runs(read_aa_runs(args.db, since)), since=since,
                    monitored=monitored or subscribed(), detector=detector or catapult_detector(),
                    min_pairs=args.min_pairs)
    if args.cv_over is not None:
        p99_limit = args.p99_cv_over if args.p99_cv_over is not None else 2 * args.cv_over
        listed = noisy(result["series"], cv_over=args.cv_over, p99_cv_over=p99_limit, min_pairs=args.min_pairs)
        if args.json:
            json.dump(listed, out, indent=2, sort_keys=True)
            out.write("\n")
        else:
            _print_rows(listed, out)
        return 0
    if args.json:
        json.dump(result, out, indent=2, sort_keys=True)
        out.write("\n")
    else:
        _print_summary(result["summary"], out)
        _print_rows(result["series"], out)
    return 0


def _run_cli(args: argparse.Namespace) -> int:
    try:
        return run(args)
    except AAError as error:
        print(f"lab.py aa: {error}", file=sys.stderr)
        return 2


def register(subparsers) -> None:
    """lab.py's subcommand hook (task 005): `lab.py aa ...`."""
    parser = subparsers.add_parser("aa", help="A/A noise: CV and false-alert rate of monitored series")
    add_arguments(parser)
    parser.set_defaults(func=_run_cli)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="aa.py", description=__doc__.splitlines()[0])
    add_arguments(parser)
    return _run_cli(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
