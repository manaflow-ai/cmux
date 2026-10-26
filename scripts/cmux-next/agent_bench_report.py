"""Percentiles and result-v1 series of the agent and Home benches (p12-perf-process-057).

Plain data in, plain data out (no app, no socket, no daemon), so scripts/cmux-next/tests/test_agent_bench_report.py
checks the statistics, the names the lab stories match and the report keys on any host. Every percentile comes from
scripts/perf-lab/perf_stats.py (linear interpolation, Chromium's perf dashboard and catapult definition).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| acpmux-overhead-bench.py | acpmux-overhead | `acpmux_overhead.<harness>.<raw,acpmux,overhead>.<metric>` | none (no app) |
| agent-engine-bench.py | agent-engine, agent-engine-webkit | `agent_engine.<metric>` | the mode's |
| agent-stream-e2e.py | agent-stream, agent-stream-webkit | `agent_stream.<metric>` | the --engine's |
| home-perf.py | home-perf | `home_perf.<stage>.<metric>` | none (native classic Home) |

A value measured once per run (a chat, a fling, a stream, a turn) has a `<metric>.missed_runs` count next to it (the
runs that gave no value), so a failed run shows in the lab instead of leaving the percentiles of the runs that worked
(as new_tab_bench_report.py). A per-frame series holds every frame of every run. A story names one engine
(bench_story.py); a run whose page showed in another engine than its story's, or whose engine could not be read,
counts in `engine_fallback` and its samples never enter the story's series: its once-per-run values count as missed
runs (as new_tab_bench_report.case_value drops a fallback case).
"""
import collections
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, RecordError, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

ACPMUX_STORY = "acpmux-overhead"
AGENT_ENGINE_STORIES = {"chromium": "agent-engine", "webkit": "agent-engine-webkit"}
AGENT_STREAM_STORIES = {"chromium": "agent-stream", "webkit": "agent-stream-webkit"}
HOME_STORY = "home-perf"

# acpmux-overhead-bench.py: the per-run times (ms from the session start, or from the second prompt's send).
ACPMUX_TIMES = ("ready", "first", "end", "warm_first", "warm_end")
ACPMUX_SIDES = ("raw", "acpmux")
# The raw frame arrays debug.frames adds with `raw: true` (DebugFrameProbe.stats, RenderFrameLog.report).
RAW_FRAME_KEYS = ("intervals_ms", "main_ms")
RAW_FRAME_SUFFIX = "_per_frame"
HOME_FRAME_STAGES = ("scroll", "send", "typing")
HOME_MEMORY_STAGES = ("memory_launch", "memory_open", "memory_end")
MB = 1024 * 1024

Series = collections.namedtuple("Series", "story metric unit samples")


def is_sample(value):
    """A finite number that is not a bool."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def numbers(values):
    return [v for v in values if is_sample(v)]


def pct(values, q, digits=2):
    """perf_stats.pct at quantile `q` (0-1), rounded to `digits`; None when no value is a number."""
    value = perf_stats.pct(numbers(values), q)
    return None if value is None else round(value, digits)


def median(values, digits=1):
    """perf_stats p50 (equal to statistics.median), rounded; None when no value is a number."""
    value = perf_stats.pct(numbers(values), 0.5)
    return None if value is None else round(value, digits)


def series(story, metric, unit, samples):
    """[Series] for the numeric samples, or [] when there is none (result-v1 needs one sample)."""
    samples = numbers(samples)
    return [Series(story, metric, unit, samples)] if samples else []


def per_run(story, metric, unit, values):
    """A once-per-run value's series (its numeric samples, in run order) and its `<metric>.missed_runs` count. No
    series for a value with no sample; the count is there whenever a run was made."""
    values = list(values)
    out = series(story, metric, unit, values)
    if values:
        out.append(Series(story, f"{metric}.missed_runs", "count", [len(values) - len(numbers(values))]))
    return out


def page_engine(name):
    """result-v1's engine of a `debug.agent_pane engine` answer: `cef` is chromium, `webkit:<reason>` webkit."""
    if name == "cef":
        return "chromium"
    if isinstance(name, str) and (name == "webkit" or name.startswith("webkit:")):
        return "webkit"
    return None


def fallbacks(engine, shown):
    """How many of the engine names `shown` (one per opened chat) are not `engine` (a missing name counts too)."""
    return sum(1 for name in shown if page_engine(name) != engine)


def shown_in(engine, name):
    """Whether the page showed in `engine`: a missing or unknown name is not, since its samples' engine is unknown."""
    return page_engine(name) == engine


def frame_samples(reply, key="interval_ms"):
    """One field of each sample of a `debug.agent_pane perf_stats raw` answer (acpmuxPerf.stats(true).samples) or
    of a `typing_stats raw` one (typingSummary's per-key `samples`)."""
    rows = reply.get("samples") if isinstance(reply, dict) else None
    return numbers(row.get(key) for row in rows or [] if isinstance(row, dict))


def run_frames(reply, frames):
    """The per-frame samples of one fling or stream: `frames` (the `perf_stats raw` answer read after it) only when
    the run's `reply` has no error and counted the frames the page's ring holds (the ring takes an interval from
    the second frame on, so it holds `reply.frames - 1`). A run that failed before it reset the ring, or a read that
    got another run's or a partial ring, gives {} (no frames), so no stale frame enters a series."""
    if not isinstance(reply, dict) or "error" in reply or not isinstance(frames, dict) or "error" in frames:
        return {}
    count, rows = reply.get("frames"), frames.get("samples")
    if not is_sample(count) or not isinstance(rows, list) or count - 1 != len(rows):
        return {}
    return frames


def any_written(written):
    """Whether a bench's {`story/metric`: path or `not recorded: ...`} holds at least one written file."""
    return any(not str(path).startswith("not recorded") for path in (written or {}).values())


# ---------- acpmux-overhead-bench.py ----------

def acpmux_summary(runs, metrics):
    """One side's block: {metric: {p50, p95, p99, n}} (1 decimal, as the bench always printed)."""
    return {m: {"p50": pct([r.get(m) for r in runs], 0.5, 1), "p95": pct([r.get(m) for r in runs], 0.95, 1),
                "p99": pct([r.get(m) for r in runs], 0.99, 1), "n": len(runs)} for m in metrics}


def acpmux_series(harness, pairs, errors):
    """`pairs`: per measured run {raw: run or None, acpmux: run or None} (None: that side failed); `errors`: per side
    the count of failed runs, warmups included. Per side, each time (ms), the model requests (count) and the request
    bytes; `overhead.<time>` is acpmux minus raw of the same run (the two sides run back to back, so machine load hits
    both alike), for the runs where both sides worked."""
    name = f"acpmux_overhead.{harness}"
    out = []
    for side in ACPMUX_SIDES:
        runs = [p.get(side) or {} for p in pairs]
        for m in ACPMUX_TIMES:
            out += per_run(ACPMUX_STORY, f"{name}.{side}.{m}", "ms", [r.get(m) for r in runs])
        out += series(ACPMUX_STORY, f"{name}.{side}.requests", "count", [r.get("requests") for r in runs])
        out += series(ACPMUX_STORY, f"{name}.{side}.request_bytes", "bytes", [r.get("request_bytes") for r in runs])
        out.append(Series(ACPMUX_STORY, f"{name}.{side}.errors", "count", [errors.get(side, 0)]))
    for m in ACPMUX_TIMES:
        both = [(p.get("raw") or {}).get(m) for p in pairs], [(p.get("acpmux") or {}).get(m) for p in pairs]
        out += series(ACPMUX_STORY, f"{name}.overhead.{m}", "ms",
                      [b - a for a, b in zip(*both) if is_sample(a) and is_sample(b)])
    return out


# ---------- agent-engine-bench.py ----------

def agent_engine_summary_stats(first, more):
    """The chat-open part of agent-engine-bench's summary (its keys unchanged; medians through perf_stats)."""
    return {"first_content_ms": first.get("content_ms"), "first_interactive_ms": first.get("interactive_ms"),
            "next_content_ms_median": median(c.get("content_ms") for c in more),
            "next_interactive_ms_median": median(c.get("interactive_ms") for c in more)}


def agent_engine_series(engine, result, chats, story=None):
    """agent-engine-bench.py, one mode's `result`: the first chat and each next one (content and interactive ms), the
    session's composer, each composer key's time to the next frame and to its paint (the raw typing samples), every
    fling frame (the raw `frames_ms` the bench reads after each fling) and each fling's dropped frames, the footprint
    at each stage, and the chats that showed in another engine. A chat that showed in another engine is a missed run;
    the session, typing, flings and memory run in the first chat's page, so none of them records when it did not
    show in `engine`. `story` defaults to the engine's (AGENT_ENGINE_STORIES)."""
    story = story or AGENT_ENGINE_STORIES[engine]
    first, more = result.get("first_chat") or {}, result.get("more_chats") or []

    def value(chat, key):
        return chat.get(key) if shown_in(engine, chat.get("engine")) else None

    in_engine = shown_in(engine, first.get("engine"))
    out = []
    for key, metric in (("content_ms", "content"), ("interactive_ms", "interactive")):
        out += per_run(story, f"agent_engine.first_{metric}", "ms", [value(first, key)])
        out += per_run(story, f"agent_engine.next_{metric}", "ms", [value(c, key) for c in more])
    composer = (result.get("session") or {}).get("composer_ms")
    out += per_run(story, "agent_engine.session_composer", "ms", [composer if in_engine else None])
    flings = result.get("flings") or []
    out += per_run(story, "agent_engine.fling.dropped_frames", "count",
                   [f.get("dropped_frames") if in_engine else None for f in flings])
    if in_engine:
        typing = result.get("typing") or {}
        for key, metric in (("to_frame_samples_ms", "to_frame"), ("to_paint_samples_ms", "to_paint")):
            out += series(story, f"agent_engine.typing.{metric}", "ms", typing.get(key) or [])
        out += series(story, "agent_engine.fling.frame_interval", "ms",
                      [v for f in flings for v in f.get("frames_ms") or []])
        for stage in ("baseline", "one_chat", f"chats_{chats}"):
            out += series(story, f"agent_engine.memory.{stage}.footprint", "bytes",
                          [(result.get(stage) or {}).get("total_footprint_bytes")])
    shown = [c.get("engine") for c in [first] + list(more) if "error" not in c]
    if shown:
        out.append(Series(story, "agent_engine.engine_fallback", "count", [fallbacks(engine, shown)]))
    return out


# ---------- agent-stream-e2e.py ----------

# The printed table's columns, as before the migration; p99_ms is new.
STREAM_COLUMNS = [("nominal_ms",), ("frames",), ("p95_ms",), ("p99_ms",), ("max_ms",), ("dropped_frames",),
                  ("detached_frames",), ("growing_frames",), ("growth_px", "p95"), ("growth_px", "max"),
                  ("layout_ms", "p95_ms"), ("react_ms", "p95_ms"), ("other_ms", "p95_ms"), ("deltas",)]


def column_values(results, *path):
    values = []
    for result in results:
        value = result
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        values.append(value)
    return numbers(values)


def stream_median(results, *path):
    """The median over the runs of one reply field (2 decimals, as the bench always printed)."""
    return median(column_values(results, *path), 2)


def stream_series(engine, runs, shown=None, story=None):
    """agent-stream-e2e.py, the runs of one launch: per run its stream `reply` and the frames read after it
    (`interval_ms`, `layout_ms`, `react_ms`: frame_samples of the page's per-frame samples). Every frame's interval,
    layout and React time, and per run the dropped, detached-from-bottom and content-growing frames. `shown` is the
    engine name the agent tab showed in (`debug.agent_pane engine`; None when it could not be read). A tab that did
    not show in `engine` records no frame and makes every run a missed one; `engine_fallback` says so. `story`
    defaults to the engine's."""
    story = story or AGENT_STREAM_STORIES[engine]
    in_engine = shown_in(engine, shown)
    replies = [(r.get("reply") or {}) if in_engine else {} for r in runs]
    out = []
    if in_engine:
        for key, metric in (("interval_ms", "frame_interval"), ("layout_ms", "layout"), ("react_ms", "react")):
            out += series(story, f"agent_stream.{metric}", "ms", [v for r in runs for v in r.get(key) or []])
    for key in ("dropped_frames", "detached_frames", "growing_frames"):
        out += per_run(story, f"agent_stream.{key}", "count", [r.get(key) for r in replies])
    out.append(Series(story, "agent_stream.engine_fallback", "count", [fallbacks(engine, [shown])]))
    return out


# ---------- home-perf.py ----------

def split_raw_frames(stats):
    """A debug.frames `stop` answer with `raw: true` -> (the answer without its per-frame arrays, {key: array}), so
    the report keeps the keys it had and the arrays go to result-v1."""
    stats = dict(stats) if isinstance(stats, dict) else {}
    raw = {k: stats.pop(k) for k in list(stats) if k in RAW_FRAME_KEYS or k.endswith(RAW_FRAME_SUFFIX)}
    return stats, raw


def key_dispatch(trips):
    """home-perf.py's `key_dispatch_ms` block: {count, p50, p95, p99, max} of the `debug.key` round trips (ms)."""
    trips = numbers(trips)
    return {"count": len(trips), "p50": pct(trips, 0.5), "p95": pct(trips, 0.95), "p99": pct(trips, 0.99),
            "max": round(max(trips), 2) if trips else None}


def home_series(raw, trips, results):
    """home-perf.py: every frame interval and main-thread ms of each stage (`raw`: {stage: split_raw_frames' arrays}),
    each key's round trip, and the footprint and resident size at each memory stage."""
    out = []
    for stage in HOME_FRAME_STAGES:
        arrays = raw.get(stage) or {}
        out += series(HOME_STORY, f"home_perf.{stage}.frame_interval", "ms", arrays.get("intervals_ms") or [])
        out += series(HOME_STORY, f"home_perf.{stage}.main", "ms", arrays.get("main_ms") or [])
    out += series(HOME_STORY, "home_perf.typing.key_dispatch", "ms", trips)
    for stage in HOME_MEMORY_STAGES:
        block = results.get(stage) or {}
        name = stage[len("memory_"):]
        for key, metric in (("footprint_mb", "footprint"), ("rss_mb", "rss")):
            value = block.get(key)
            out += series(HOME_STORY, f"home_perf.memory.{name}.{metric}", "bytes",
                          [round(value * MB)] if is_sample(value) else [])
    return out


# ---------- writing ----------

def record_all(bench, entries, engine, session="light"):
    """Writes each series as one cmux-perf-result/v1 file through ``BenchApp.record``; returns {`story/metric`: path,
    or `not recorded: <reason>`}. A series the bench cannot describe truthfully (no build sha, no features snapshot)
    is not written, and its reason is printed."""
    written = {}
    bench.perf_session = session
    for entry in entries:
        key = f"{entry.story}/{entry.metric}"
        try:
            written[key] = str(bench.record(entry.story, entry.metric, entry.unit, entry.samples, better="lower",
                                            engine=engine))
        except (RecordError, perf_result.ResultError) as error:
            written[key] = f"not recorded: {error}"
            print(f"result-v1 {key}: {written[key]}", flush=True)
    return written


def write_all(out, entries, build, host, engine="none", session="light", run=None, root=None):
    """For a bench with no app (acpmux-overhead-bench.py): every series into one result-v1 file in `out` through
    perf_result (validated first; nothing is written when one is invalid). No features: no app ran."""
    run = run or perf_result.Run.start()
    results = [perf_result.Result(story=e.story, metric=e.metric, unit=e.unit, better="lower", samples=list(e.samples),
                                  build=build, host=host, engine=engine, session=session, run=run)
               for e in entries]
    return perf_result.write_ndjson(out, results, repo_root=root)
