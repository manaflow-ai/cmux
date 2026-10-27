#!/usr/bin/env python3
"""A/A noise report: how noisy each monitored series is when nothing changed (p12-perf-process-024).

Each lab host runs T0 twice on one artifact every night (the scheduler's `aa` item, AA_PASSES, task 011). The
runs are stored as kind `aa` with the build, host and story of a waterfall point, so each pair is an A/A
experiment on the same series key. For each monitored series (a subscriptions.json entry matches it, as
alerts.detect decides) this module reports:

- CV of the per-run median and of the per-run p99: the root-mean-square CV of duplicate measurements,
  sqrt(sum(((a - b) / mean(a, b))^2) / 2k) over the k pairs. Each pair compares runs of one artifact,
  so the nightly change of artifact does not count as noise.
- False alerts: the regression alerts the lab would raise on data with no change. The lab alerts only a
  regression, so B worse than A is one; each count's two-sided figure is reported beside it, never judged.
  - compare: catapult Pinpoint's compare (perf_stats.compare, catapult pinpoint/compare/compare.py) on the
    raw samples of A and B. DIFFERENT by the strict rule (the culprit-verification rule) with B's median worse
    than A's is one false alert, as pinpoint._direction_ok keeps a verify verdict; the bisect rule's count
    (DIFFERENT unless B's mean is better) is reported beside it.
  - anomaly: alerts.detect's detector (catapult find_change_points, task 003) with the config alerts.detect
    gives the series (its subscription's anomaly_config and the catalog noise floor), on the per-host series
    of B's median at A's level, median(B) / median(A) * the host's median of median(A). That series moves
    only with run-to-run noise. It runs on the max_window_size window ending at each point, as ingest does
    after each new point; a change point whose range overlaps one already found is the same alert, as
    alerts._record drops it, and only a step alerts.is_regression calls a regression counts.
  The rate is false alerts per 100 series-days (one series-day = one A/A pair).
- A/A runs per waterfall host (a host with a waterfall run in the window): one run is one A/A job, or for a run
  stored without a job id, one artifact on one scheduler lab day (scheduler.lab_day, 09:00 UTC).

`lab.py aa --since-live|--days N [--json]` prints the report; `--cv-over X --json` prints only the
noisy series (MQ11, one de-noise task each) and skips the detector, since the list uses only the CVs.
The thresholds of done check 9 (p12-perf-process.md 5) are the module constants below; this module never
widens a threshold to clear a series.
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
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Protocol, TextIO

HERE = Path(__file__).resolve().parent

DB_ENV = "CMUX_PERF_LAB_DB"
LAB_COMMANDS = {"aa": "A/A noise: CV of median and p99 and false-alert rate of monitored series (MQ11: --cv-over)."}
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
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


perf_stats = _load("perf_lab_perf_stats", "perf_stats.py")


@dataclass(frozen=True)
class SeriesInfo:
    """A series row with the fields of alerts.SeriesInfo, so the subscription and floor seams take it as is."""

    id: int
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
class HostRuns:
    """The waterfall hosts of the window and each host's A/A run count (0 for a waterfall host without one)."""

    waterfall: tuple[str, ...]
    aa_runs: dict[str, int]


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
    compare_different_two_sided: int
    anomaly_alerts: int | None
    anomaly_steps_two_sided: int | None
    false_alerts: int | None
    false_alerts_per_100: float | None


class Detector(Protocol):
    """alerts.Detector's change_points: steps with extended_start and extended_end (value indexes),
    median_before and median_after, newest first."""

    def change_points(self, values: Sequence[float], config: Mapping[str, float]) -> Sequence[object]:
        ...


# The AnomalyConfig alerts.detect would use on a series, or None when no subscription matches it (unmonitored).
SeriesConfig = Callable[[SeriesInfo], "Mapping[str, float] | None"]


def _alerts():
    return _load("perf_lab_alerts", "alerts.py")


def _scheduler():
    return _load("perf_lab_scheduler", "scheduler.py")


class ScreenedDetector:
    """A catapult detector that skips the E-Divisive permutation test on a window with no possible change point.

    find_change_points keeps a candidate only when its split passes the segment-size, absolute-change and
    relative-change filters of anomaly.passes_thresholds (catapult find_change_points.py _PassesThresholds 1-3).
    When no split of the window passes them, the answer is [] whatever E-Divisive finds, and A/A noise is almost
    always such a window.
    """

    def __init__(self, inner: Detector, anomaly) -> None:
        self._inner = inner
        self._anomaly = anomaly

    def _possible(self, values: Sequence[float], config: Mapping[str, float]) -> bool:
        anomaly = self._anomaly
        values = list(values)[-int(config.get("max_window_size", anomaly.MAX_WINDOW_SIZE)):]
        if len(values) < 2:
            return False
        segment = config.get("min_segment_size", anomaly.MIN_SEGMENT_SIZE)
        absolute = config.get("min_absolute_change", anomaly.MIN_ABSOLUTE_CHANGE)
        relative = config.get("min_relative_change", anomaly.MIN_RELATIVE_CHANGE)
        median, relative_change = anomaly.edivisive.Median, anomaly.edivisive.RelativeChange
        for split in range(len(values)):
            left, right = values[:split], values[split:]
            if len(left) < segment or len(right) < segment:
                continue
            before, after = median(left), median(right)
            # Written as passes_thresholds' rejections, so a NaN median (an empty side) is a possible step too.
            if not abs(before - after) < absolute and not relative_change(before, after) < relative:
                return True
        return False

    def change_points(self, values: Sequence[float], config: Mapping[str, float]) -> Sequence[object]:
        if not self._possible(values, config):
            return []
        return self._inner.change_points(values, config)


def catapult_detector() -> Detector:
    """alerts.CatapultDetector (anomaly.find_change_points, task 003, behind the alerts Detector seam), screened."""
    alerts = _alerts()
    try:
        inner = alerts.CatapultDetector()
    except alerts.AlertsError as error:
        raise AAError(str(error)) from None
    return ScreenedDetector(inner, _load("perf_lab_anomaly", "anomaly.py"))


def subscription_configs(subscriptions_path: Path | str | None = None, root: Path | None = None) -> SeriesConfig:
    """Each series' AnomalyConfig as alerts.detect builds it: the first matching subscription's anomaly_config
    with min_absolute_change raised to the catalog noise floor; None when no subscription matches."""
    alerts = _alerts()
    try:
        subscriptions = alerts.Subscriptions.load(subscriptions_path or alerts.DEFAULT_SUBSCRIPTIONS)
        floors = alerts.load_floors(root or alerts.REPO_ROOT)
    except alerts.AlertsError as error:
        raise AAError(str(error)) from None

    def config(series: SeriesInfo) -> Mapping[str, float] | None:
        info = alerts.SeriesInfo(**asdict(series))
        subscription = subscriptions.match(info)
        if subscription is None:
            return None
        found = dict(subscription.anomaly_config)
        floor = floors(info)
        if floor is not None:
            found["min_absolute_change"] = max(floor, found.get("min_absolute_change", floor))
        return found

    return config


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
            """SELECT s.id AS series_id, s.series_key, s.story, s.metric, s.engine, s.host_class, s.macos_major, s.build_config,
                      s.unit, s.better, h.name AS host, u.build_id, b.sha, u.job_id, u.run_uuid, u.started_at,
                      r.samples_json
               FROM results r JOIN runs u ON u.id = r.run_id JOIN series s ON s.id = r.series_id
               JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
               WHERE u.kind = 'aa' AND u.started_at >= ?
               ORDER BY u.started_at, u.id, r.id""", (_stamp(since),)).fetchall()
    finally:
        db.close()
    return [AARun(SeriesInfo(row["series_id"], row["series_key"], row["story"], row["metric"], row["engine"], row["host_class"],
                             row["macos_major"], row["build_config"], row["unit"], row["better"]),
                  row["host"], row["build_id"], row["sha"], row["job_id"], row["run_uuid"], row["started_at"],
                  tuple(float(v) for v in json.loads(row["samples_json"])))
            for row in rows]


def _experiment(job_id: int | None, build_id: int, started_at: str) -> tuple:
    """One A/A job: its job id, or for a run stored without one, its artifact on the scheduler's lab day (09:00 UTC),
    so the two passes of a job that runs past midnight UTC stay one experiment."""
    if job_id is not None:
        return ("job", job_id)
    return ("day", build_id, _scheduler().lab_day(datetime.fromisoformat(started_at)))


def read_host_runs(db_path: Path | str, since: datetime) -> HostRuns:
    """The hosts with a waterfall run started at or after `since`, and each host's A/A run count in the window."""
    db = _connect(db_path)
    try:
        bound = _stamp(since)
        waterfall = tuple(row["name"] for row in db.execute(
            """SELECT DISTINCT h.name FROM runs u JOIN hosts h ON h.id = u.host_id
               WHERE u.kind = 'waterfall' AND u.started_at >= ? ORDER BY h.name""", (bound,)))
        rows = db.execute(
            """SELECT h.name AS host, u.job_id, u.build_id, u.started_at FROM runs u JOIN hosts h ON h.id = u.host_id
               WHERE u.kind = 'aa' AND u.started_at >= ?""", (bound,)).fetchall()
    finally:
        db.close()
    experiments: dict[str, set] = {host: set() for host in waterfall}
    for row in rows:
        experiments.setdefault(row["host"], set()).add(_experiment(row["job_id"], row["build_id"], row["started_at"]))
    return HostRuns(waterfall, {host: len(found) for host, found in sorted(experiments.items())})


def pair_runs(runs: Sequence[AARun]) -> list[Pair]:
    """A/A pairs: consecutive runs of one series on one host and one artifact, within one A/A job (_experiment).

    An unpaired last run is dropped.
    """
    groups: dict[tuple, list[AARun]] = defaultdict(list)
    for run in runs:
        experiment = _experiment(run.job_id, run.build_id, run.started_at)
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


def level_series(values: Sequence[tuple[float, float]]) -> list[float]:
    """B at A's level: b / a * median(a) per (a, b) pair, in the series' own unit; pairs with a == 0 dropped."""
    usable = [(a, b) for a, b in values if a != 0]
    if not usable:
        return []
    level = perf_stats.pct([a for a, _ in usable], 0.50)
    return [b / a * level for a, b in usable]


@dataclass(frozen=True)
class Steps:
    regressions: int
    two_sided: int


def change_points(values: Sequence[float], detector: Detector, config: Mapping[str, float],
                  better: str = "lower") -> Steps:
    """The alerts the detector raises when it runs after each new point, as ingest runs alerts.detect.

    Each run sees the max_window_size points ending at the new one (alerts.detect's series_points limit), so
    the replay is one detector call per point on at most that many values. A step with equal medians is
    skipped, a step whose range overlaps one already found is that same alert (alerts._record), and only a
    regression (alerts.is_regression) is alerted.
    """
    alerts = _alerts()
    window = int(config.get("max_window_size", alerts.DEFAULT_MAX_WINDOW_SIZE))
    found: list[tuple[int, int]] = []
    regressions = 0
    for end in range(1, len(values) + 1):
        offset = max(0, end - window)
        for point in detector.change_points(list(values[offset:end]), config):
            if point.median_before == point.median_after:
                continue
            start, stop = offset + int(point.extended_start), offset + int(point.extended_end)
            if any(start <= old_stop and stop >= old_start for old_start, old_stop in found):
                continue
            found.append((start, stop))
            regressions += alerts.is_regression(better, point.median_before, point.median_after)
    return Steps(regressions, len(found))


def _stats(pairs: Sequence[Pair], q: float) -> list[tuple[float, float]]:
    out = []
    for pair in pairs:
        a, b = perf_stats.pct(pair.a, q), perf_stats.pct(pair.b, q)
        if a is not None and b is not None:
            out.append((a, b))
    return out


def _mean(values: Sequence[float]) -> float | None:
    return sum(values) / len(values) if values else None


def series_noise(series: SeriesInfo, pairs: Sequence[Pair], detector: Detector | None,
                 config: Mapping[str, float]) -> SeriesNoise:
    """One series' noise; without a detector (the --cv-over list) the anomaly and false-alert counts are None."""
    by_host: dict[str, list[Pair]] = defaultdict(list)
    for pair in pairs:
        by_host[pair.host].append(pair)
    regression = _alerts().is_regression
    strict = bisect = two_sided = 0
    for pair in pairs:
        comparison = perf_stats.compare(pair.a, pair.b)
        different = comparison.original.result == perf_stats.DIFFERENT
        two_sided += different
        # pinpoint._direction_ok: a verify verdict stays DIFFERENT only for a regression of the median, a bisect
        # verdict for anything but an improvement of the mean.
        median_a, median_b = perf_stats.pct(pair.a, 0.50), perf_stats.pct(pair.b, 0.50)
        strict += different and median_a is not None and median_b is not None and regression(
            series.better, median_a, median_b)
        mean_a, mean_b = _mean(pair.a), _mean(pair.b)
        bisect += comparison.floored.result == perf_stats.DIFFERENT and not (
            mean_a is not None and mean_b is not None and regression(series.better, mean_b, mean_a))
    anomaly = steps = false_alerts = per_100 = None
    if detector is not None:
        # One series per host, since a host's level and noise are its own. alerts.detect judges the p50 only.
        found = [change_points(level_series(_stats(host_pairs, 0.50)), detector, config, series.better)
                 for host_pairs in by_host.values()]
        anomaly = sum(item.regressions for item in found)
        steps = sum(item.two_sided for item in found)
        false_alerts = strict + anomaly
        per_100 = 100.0 * false_alerts / len(pairs)
    return SeriesNoise(
        key=series.key, story=series.story, metric=series.metric, engine=series.engine,
        host_class=series.host_class, macos_major=series.macos_major, build_config=series.build_config,
        unit=series.unit, pairs=len(pairs), pairs_by_host={host: len(p) for host, p in sorted(by_host.items())},
        cv_median=duplicate_cv(_stats(pairs, 0.50)), cv_p99=duplicate_cv(_stats(pairs, 0.99)),
        compare_different_strict=strict, compare_different_bisect=bisect, compare_different_two_sided=two_sided,
        anomaly_alerts=anomaly, anomaly_steps_two_sided=steps,
        false_alerts=false_alerts, false_alerts_per_100=per_100)


def _share(values: Sequence[float | None], limit: float) -> float | None:
    judged = [value for value in values if value is not None]
    if not judged:
        return None
    return sum(value <= limit for value in judged) / len(judged)


def report(pairs: Sequence[Pair], *, since: datetime, configs: SeriesConfig, detector: Detector | None,
           host_runs: HostRuns, min_pairs: int = MIN_PAIRS) -> dict:
    """The A/A report over monitored series: one row per series and the done-check summary.

    Without a detector (the --cv-over list) the false-alert figures are None and their check fails.
    """
    by_series: dict[str, list[Pair]] = defaultdict(list)
    infos: dict[str, SeriesInfo] = {}
    found: dict[str, Mapping[str, float] | None] = {}
    for pair in pairs:
        key = pair.series.key
        if key not in found:
            found[key] = configs(pair.series)
        if found[key] is not None:
            by_series[key].append(pair)
            infos[key] = pair.series
    rows = [series_noise(infos[key], by_series[key], detector, found[key]) for key in sorted(by_series)]
    rows.sort(key=lambda row: (row.story, row.metric, row.host_class, row.engine, row.key))

    series_days = sum(row.pairs for row in rows)
    false_alerts = None if detector is None else sum(row.false_alerts for row in rows)
    judged = [row for row in rows if row.pairs >= min_pairs and row.unit in LATENCY_UNITS]
    per_100 = 100.0 * false_alerts / series_days if series_days and false_alerts is not None else None
    median_share = _share([row.cv_median for row in judged], DONE_MEDIAN_CV)
    p99_share = _share([row.cv_p99 for row in judged], DONE_P99_CV)
    under_min = [host for host in host_runs.waterfall if host_runs.aa_runs[host] < DONE_MIN_AA_RUNS_PER_HOST]
    summary = {
        "since": _stamp(since),
        "series": len(rows),
        "unmonitored_series": sum(config is None for config in found.values()),
        "series_days": series_days,
        "false_alerts": false_alerts,
        "false_alerts_per_100_series_days": per_100,
        "latency_series_judged": len(judged),
        "median_cv_share_within": median_share,
        "p99_cv_share_within": p99_share,
        "waterfall_hosts": list(host_runs.waterfall),
        "aa_runs_by_host": dict(host_runs.aa_runs),
        "hosts_under_min_aa_runs": under_min,
        "checks": {
            "aa_runs_per_host": bool(host_runs.waterfall) and not under_min,
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
              f"false_alerts={'-' if row['false_alerts'] is None else row['false_alerts']}", file=out)


def _print_summary(summary: dict, out: TextIO) -> None:
    per_100 = summary["false_alerts_per_100_series_days"]
    checks = summary["checks"]
    print(f"A/A since {summary['since']}: {summary['series']} monitored series "
          f"({summary['unmonitored_series']} unmonitored left out), {summary['series_days']} series-days", file=out)
    hosts = summary["waterfall_hosts"]
    print(f"A/A runs: {len(hosts)} waterfall hosts, need >= {DONE_MIN_AA_RUNS_PER_HOST} each"
          f"{'' if hosts else ' (no waterfall host in the window)'} "
          f"{'ok' if checks['aa_runs_per_host'] else 'FAIL'}", file=out)
    print(f"false alerts: {summary['false_alerts']} "
          f"({'-' if per_100 is None else f'{per_100:.2f}'} per 100 series-days, limit "
          f"{DONE_FALSE_ALERTS_PER_100:g}) {'ok' if checks['false_alerts'] else 'FAIL'}", file=out)
    print(f"median CV <= {_pct(DONE_MEDIAN_CV)}: {_pct(summary['median_cv_share_within'])} of "
          f"{summary['latency_series_judged']} latency series (need {_pct(DONE_MEDIAN_SHARE)}) "
          f"{'ok' if checks['median_cv'] else 'FAIL'}", file=out)
    print(f"p99 CV <= {_pct(DONE_P99_CV)}: {_pct(summary['p99_cv_share_within'])} "
          f"(need {_pct(DONE_P99_SHARE)}) {'ok' if checks['p99_cv'] else 'FAIL'}", file=out)
    under = set(summary["hosts_under_min_aa_runs"])
    for host, runs in summary["aa_runs_by_host"].items():
        print(f"host {host}: {runs} A/A runs{' (under the minimum)' if host in under else ''}", file=out)


def aa_report(args: argparse.Namespace, *, clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
              detector: Detector | None = None, configs: SeriesConfig | None = None, out: TextIO | None = None) -> int:
    """`lab.py aa` with its seams injected; raises AAError on a bad argument, a missing store or a seam error."""
    out = out or sys.stdout
    if not args.db:
        raise AAError(f"no lab store: pass --db or set {DB_ENV}")
    if args.days is not None and args.days <= 0:
        raise AAError("--days needs a positive number")
    if args.p99_cv_over is not None and args.cv_over is None:
        raise AAError("--p99-cv-over needs --cv-over")
    since = clock() - timedelta(days=args.days) if args.days is not None else live_since(args.db)
    pairs = pair_runs(read_aa_runs(args.db, since))
    listing = args.cv_over is not None  # the noisy list uses only the CVs, so it never runs the detector
    if not listing:
        detector = detector or catapult_detector()
    result = report(pairs, since=since, configs=configs or subscription_configs(),
                    detector=None if listing else detector, host_runs=read_host_runs(args.db, since),
                    min_pairs=args.min_pairs)
    if listing:
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


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    """lab.py's command hook (task 005): the arguments of `lab.py aa`."""
    parser.add_argument("--db", default=os.environ.get(DB_ENV),
                        help=f"the lab SQLite store (default: ${DB_ENV})")
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--since-live", action="store_true",
                        help="since the first stored waterfall run (the default)")
    window.add_argument("--days", type=int, metavar="N", help="the last N days")
    parser.add_argument("--cv-over", type=float, metavar="X",
                        help="list only the series whose median CV is over X or whose p99 CV is over "
                             "--p99-cv-over (MQ11); the list has no false-alert counts")
    parser.add_argument("--p99-cv-over", type=float, metavar="Y",
                        help="with --cv-over: the p99 CV limit (default 2X, the done check's 5 %% to 10 %% ratio)")
    parser.add_argument("--min-pairs", type=int, default=MIN_PAIRS,
                        help=f"pairs a series needs to be judged (default {MIN_PAIRS})")
    parser.add_argument("--json", action="store_true", help="print JSON")


def run(command: str, args: argparse.Namespace) -> int:
    """lab.py's command hook (task 005): runs `lab.py aa`; a typed error exits 2."""
    try:
        return aa_report(args)
    except AAError as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="aa.py", description=LAB_COMMANDS["aa"])
    add_arguments("aa", parser)
    return run("aa", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())


