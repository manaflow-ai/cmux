"""The result-v1 series of the CLI and daemon storm benches (p12-perf-process-056).

Plain data in, plain data out (no app, no socket, no daemon), so scripts/cmux-next/tests/test_storm_bench_results.py
checks the names the lab stories match on any host. Percentiles come only from scripts/perf-lab/perf_stats.py.

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| cli-storm-session.py (runs bench_cli_storm.py) | cli-storm, cli-storm-stress | `cli_storm.request.<category>` (ms, answered requests only), `cli_storm.frame_interval`, `cli_storm.main_busy` (ms); `cli_storm.{stalls,unanswered,request_errors,pty_leaked}` (count); `cli_storm.footprint_growth` (ratio); `cli_storm.throughput` (per_s) | light none, stress chromium |
| script-storm-bench.py | script-storm, script-storm-stress | `script_storm.<phase>.{key_to_contents,frame_interval,main_busy}` (ms); `script_storm.<phase>.{missed_frames,stalls}` (count), valid phases only | light none, stress chromium |
| bench_daemon_spawn.py | daemon-spawn | `daemon_spawn.create`, `daemon_spawn.read` (ms); `daemon_spawn.all_reaped` (s); `daemon_spawn.{create_errors,hosts_left,hosts_leaked}` (count) | none |

The STRESS session (perf-stress-session.py) holds Chromium pages, so its stories say chromium; the light sessions
open no browser. Each bench run writes one session, so every result of a run shares one engine and one session
(perf-lab ingest groups a run's results by story and refuses a mix).
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, RecordError, load_by_path  # noqa: E402
from typing_report import is_sample  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

CLI_STORM_STORIES = {"light": "cli-storm", "stress": "cli-storm-stress"}
SCRIPT_STORM_STORIES = {"light": "script-storm", "stress": "script-storm-stress"}
DAEMON_SPAWN_STORY = "daemon-spawn"
SESSION_ENGINES = {"light": "none", "stress": "chromium"}

Series = collections.namedtuple("Series", "metric unit better samples")


def latency_row(values):
    """{count, p50_ms, p95_ms, p99_ms, max_ms} of `values` (ms) through perf_stats.pct; None for a statistic of no
    values."""
    values = [v for v in values if is_sample(v)]
    return {"count": len(values), "p50_ms": perf_stats.pct(values, 0.5), "p95_ms": perf_stats.pct(values, 0.95),
            "p99_ms": perf_stats.pct(values, 0.99), "max_ms": max(values) if values else None}


def _count(value):
    return [value] if is_sample(value) else []


def _kept(series):
    return [s for s in series if s.samples]


def cli_storm_series(storm):
    """bench_cli_storm.py's report (`samples`, `criteria`, `throughput_rps`) as series. The request latencies are the
    answered (ok) requests only: a fast error reply or a timeout is counted (request_errors, unanswered), never a
    latency, so refusing requests cannot read as faster. A criterion the profile cannot see (legacy: no stalls) or a
    footprint(1) that failed gives no series, never a 0."""
    samples = storm.get("samples") or {}
    criteria = storm.get("criteria") or {}
    series = [Series(f"cli_storm.request.{category}", "ms", "lower", list(values))
              for category, values in sorted((samples.get("latency_ms") or {}).items())]
    series += [Series("cli_storm.frame_interval", "ms", "lower", list(samples.get("frame_interval_ms") or [])),
               Series("cli_storm.main_busy", "ms", "lower", list(samples.get("main_busy_ms") or [])),
               Series("cli_storm.stalls", "count", "lower", _count(criteria.get("stalls_over_50ms"))),
               Series("cli_storm.unanswered", "count", "lower", _count(criteria.get("unanswered"))),
               Series("cli_storm.request_errors", "count", "lower", _count(criteria.get("request_errors"))),
               Series("cli_storm.pty_leaked", "count", "lower", _count(criteria.get("pty_leaked"))),
               Series("cli_storm.footprint_growth", "ratio", "lower", _count(criteria.get("footprint_after_vs_baseline"))),
               Series("cli_storm.throughput", "per_s", "higher", _count(storm.get("throughput_rps")))]
    return _kept(series)


def script_storm_series(phase, key_samples, frames_raw, missed, stalls):
    """One valid phase of script-storm-bench.py (an invalid phase is not the asked load and records nothing): its
    closed keys' key_to_contents ms, the raw frame arrays (bench_frames.split_raw_frames), missed frames and stalls over 8 ms."""
    prefix = f"script_storm.{phase}"
    return _kept([Series(f"{prefix}.key_to_contents", "ms", "lower", list(key_samples)),
                  Series(f"{prefix}.frame_interval", "ms", "lower", list(frames_raw.get("intervals_ms") or [])),
                  Series(f"{prefix}.main_busy", "ms", "lower", list(frames_raw.get("main_ms") or [])),
                  Series(f"{prefix}.missed_frames", "count", "lower", _count(missed)),
                  Series(f"{prefix}.stalls", "count", "lower", _count(stalls))])


def daemon_spawn_series(rounds, leaked):
    """bench_daemon_spawn.py's rounds ({create, reap, samples}) and the hosts that outlived `server stop`. Create and
    read latencies pool every round's raw samples; all_reaped has one sample per round that reaped everything."""
    create = [v for r in rounds for v in r["samples"]["create_ms"]]
    read = [v for r in rounds for v in r["samples"]["read_ms"]]
    reaped = [r["reap"]["all_reaped_seconds"] for r in rounds if is_sample(r["reap"]["all_reaped_seconds"])]
    return _kept([Series("daemon_spawn.create", "ms", "lower", create),
                  Series("daemon_spawn.read", "ms", "lower", read),
                  Series("daemon_spawn.all_reaped", "s", "lower", reaped),
                  Series("daemon_spawn.create_errors", "count", "lower",
                         [sum(r["create"]["errors"].values()) for r in rounds]),
                  Series("daemon_spawn.hosts_left", "count", "lower", [r["reap"]["hosts_left"] for r in rounds]),
                  Series("daemon_spawn.hosts_leaked", "count", "lower", [len(leaked)])])


def record_all(bench_app, story, engine, series, log=print):
    """Writes each series as one cmux-perf-result/v1 file through ``BenchApp.record``; returns {metric: path, or
    `not recorded: <reason>`}. A series the bench cannot describe truthfully (no build sha, no features snapshot) is
    not written, and its reason is logged."""
    written = {}
    for entry in series:
        try:
            written[entry.metric] = str(bench_app.record(story, entry.metric, entry.unit, entry.samples,
                                                         better=entry.better, engine=engine))
        except (RecordError, perf_result.ResultError) as error:
            written[entry.metric] = f"not recorded: {error}"
            log(f"result-v1 {story}/{entry.metric}: {written[entry.metric]}")
    return written


def write_headless(out, story, session, series, build, host, run=None, root=None):
    """For a bench with no app (bench_daemon_spawn.py): every series into one result-v1 file in `out` through
    perf_result (validated first; nothing is written when one is invalid), all in one run. No features: no app ran."""
    run = run or perf_result.Run.start()
    results = [perf_result.Result(story=story, metric=s.metric, unit=s.unit, better=s.better, samples=list(s.samples),
                                  build=build, host=host, engine="none", session=session, run=run)
               for s in series]
    return perf_result.write_ndjson(out, results, repo_root=root)
