"""The report of instant-new-surfaces-bench.py: its JSON summary keys and its cmux-perf-result/v1 series.

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_instant_new_surfaces_bench.py
checks the names that the lab stories and targets match. Percentiles come from scripts/perf-lab/perf_stats.py.

Series names: `<key>.<session>.<metric>` for the idle phase at the launched workspace count (`cmd_t.light.dropped`,
`cmd_w.stress.key_to_frame`) and `<key>.<session>.<phase>.<metric>` for the others (`cmd_t.light.load.dropped`,
`cmd_t.light.idle_10ws.dropped`). Every per-run series has a `<series>.missed_runs` count next to it: the runs
that gave no value (not visible within 5 s, a close that did not commit, frames that answered an error), so a
failed run shows in the lab instead of leaving the percentiles of the runs that worked.
"""
import collections
import os

from bench_launch import PERF_LAB, load_by_path

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
pct = perf_stats.pct

# The result-v1 key of each command: the perf-budgets.json row prefix (perf-budgets.py rows_new_surfaces).
SERIES_KEYS = {"new_workspace": "cmd_n", "new_tab": "cmd_t", "new_terminal": "ctrl_backtick",
               "split_right": "cmd_d", "split_down": "cmd_shift_d", "new_browser": "cmd_shift_l"}
CLOSE_KEY = "cmd_w"
# debug.new_tab's `engine` -> result-v1 engine.
ENGINES = {"cef": "chromium", "webkit": "webkit"}

Series = collections.namedtuple("Series", "story unit engine samples")


def is_sample(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def frame_of(row, key="visible_ms"):
    """Which display frame after the key showed it (1 = the first frame the display link drew).
    The app's `frames_to_visible` divides by the refresh period, which counts a late first frame
    (main thread busy, display link start) as several; this walks the frames actually drawn."""
    frames = row.get("frames") or {}
    at, seen = frames.get("first_tick_ms"), row.get(key)
    if at is None or seen is None:
        return None
    index, intervals = 1, frames.get("intervals_ms") or []
    while seen > at + 0.5 and index - 1 < len(intervals):
        at += intervals[index - 1]
        index += 1
    return index


def dropped(row):
    """A run's dropped frames: its frame intervals over 1.5 refresh periods (BenchFrames `missed`)."""
    return (row.get("frames") or {}).get("missed")


def summary(rows, commands):
    """`<phase>/<command>` -> the create runs' statistics (the keys perf-budgets.py and --budget-frames read)."""
    out = {}
    for phase in sorted({r["phase"] for r in rows}):
        for command in commands:
            sel = [r for r in rows if r["phase"] == phase and r.get("command") == command]
            vis = [r.get("visible_ms") for r in sel]
            keys = [r.get("key_ms") for r in sel]
            frames = [frame_of(r) for r in sel]
            confirmed = [r.get("confirmed_ms") for r in sel]
            out[f"{phase}/{command}"] = {
                "n": len(sel), "missed": sum(v is None for v in vis),
                "key_p50": pct(keys, .5), "key_p95": pct(keys, .95), "key_p99": pct(keys, .99), "key_max": pct(keys, 1),
                "visible_p50": pct(vis, .5), "visible_p95": pct(vis, .95), "visible_p99": pct(vis, .99),
                "visible_max": pct(vis, 1),
                "frames_p50": pct(frames, .5), "frames_p95": pct(frames, .95), "frames_p99": pct(frames, .99),
                "frames_max": pct(frames, 1),
                "dropped_max": pct([dropped(r) for r in sel], 1),
                "dropped_total": sum(d for d in (dropped(r) for r in sel) if is_sample(d)),
                "first_frame_ms_p50": pct([(r.get("frames") or {}).get("first_tick_ms") for r in sel], .5),
                "confirmed_p50": pct(confirmed, .5), "confirmed_p95": pct(confirmed, .95),
                "confirmed_p99": pct(confirmed, .99),
            }
    return out


def close_summary(rows):
    """`<phase>/cmd_w` -> the statistics of the Cmd-W leg after each Cmd-T (the bench's `close_leg`)."""
    out = {}
    for phase in sorted({r["phase"] for r in rows if r.get("close")}):
        legs = [r["close"] for r in rows if r["phase"] == phase and r.get("close")]
        keyed = [c.get("key_to_frame_ms") for c in legs]
        intervals = [i for c in legs for i in c.get("intervals_ms") or []]
        out[f"{phase}/{CLOSE_KEY}"] = {
            "n": len(legs), "missed": sum(v is None for v in keyed),
            **{f"key_to_frame_{k}": v for k, v in perf_stats.summary(keyed).items() if k != "n"},
            **{f"key_ms_{k}": v for k, v in perf_stats.summary([c.get("key_ms") for c in legs]).items() if k != "n"},
            **{f"commit_{k}": v for k, v in perf_stats.summary([c.get("commit_ms") for c in legs]).items() if k != "n"},
            "dropped_max": pct([c.get("dropped") for c in legs], 1),
            "dropped_total": sum(c["dropped"] for c in legs if is_sample(c.get("dropped"))),
            **{f"frame_{k}": v for k, v in perf_stats.summary(intervals).items()},
        }
    return out


def series_name(key, session, phase):
    """`<key>.<session>` for the idle phase at the launched workspace count, else `<key>.<session>.<phase>`
    (`idle@10ws` -> `idle_10ws`): the lab stories claim only the first form."""
    base = f"{key}.{session}"
    return base if phase == "idle" else f"{base}.{phase.replace('@', '_')}"


def browser_engine(rows):
    """The result-v1 engine of new_browser runs: the engine most of them showed ("none" when none showed one)."""
    engines = collections.Counter(ENGINES[r["engine"]] for r in rows if r.get("engine") in ENGINES)
    return engines.most_common(1)[0][0] if engines else "none"


def result_series(rows, commands, session, story):
    """{metric: Series} of every measured series, raw values in run order (None for a run that gave none).

    All results of one store run and story must agree on the engine (perf-lab ingest), so a new_browser series
    with a browser engine is its own story, `<story>-<engine>` (one story per engine, stories.d/README.md);
    every other series is engine "none" in `story`."""
    out = {}

    def add(name, unit, values, engine="none", series_story=story, per_run=True):
        out[name] = Series(series_story, unit, engine, list(values))
        if per_run:
            out[f"{name}.missed_runs"] = Series(series_story, "count", engine, [sum(not is_sample(v) for v in values)])

    for phase in sorted({r["phase"] for r in rows}):
        for command in commands:
            sel = [r for r in rows if r["phase"] == phase and r.get("command") == command]
            if not sel:
                continue
            name = series_name(SERIES_KEYS.get(command, command), session, phase)
            engine = browser_engine(sel) if command == "new_browser" else "none"
            where = {"engine": engine, "series_story": story if engine == "none" else f"{story}-{engine}"}
            add(f"{name}.key_to_frame", "ms", [r.get("visible_ms") for r in sel], **where)
            add(f"{name}.dropped", "count", [dropped(r) for r in sel], **where)
            add(f"{name}.key_ms", "ms", [r.get("key_ms") for r in sel], **where)
            add(f"{name}.confirmed", "ms", [r.get("confirmed_ms") for r in sel], **where)
        legs = [r["close"] for r in rows if r["phase"] == phase and r.get("close")]
        if legs:
            name = series_name(CLOSE_KEY, session, phase)
            add(f"{name}.key_to_frame", "ms", [c.get("key_to_frame_ms") for c in legs])
            add(f"{name}.dropped", "count", [c.get("dropped") for c in legs])
            add(f"{name}.key_ms", "ms", [c.get("key_ms") for c in legs])
            add(f"{name}.commit", "ms", [c.get("commit_ms") for c in legs])
            add(f"{name}.frame", "ms", [i for c in legs for i in c.get("intervals_ms") or []], per_run=False)
    return out


def recordable(series):
    """(metric, Series with only its numeric samples) of each series that has one, and {metric: reason} of the rest
    (result-v1 needs at least one raw sample; the series' `missed_runs` still records how many runs failed)."""
    kept, skipped = [], {}
    for metric, entry in series.items():
        samples = [s for s in entry.samples if is_sample(s)]
        if samples:
            kept.append((metric, entry._replace(samples=samples)))
        else:
            skipped[metric] = "not recorded: no samples"
    return kept, skipped
