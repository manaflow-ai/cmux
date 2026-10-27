"""Medians, result-v1 series and the story contract of the motion benches (p12-perf-process-061).

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_motion_bench_report.py checks the
statistics, the series names the lab stories match and the perf-cron row names on any host. Every statistic comes from
scripts/perf-lab/perf_stats.py (linear interpolation, catapult's definition), loaded by file path.

| Bench | Story (scripts/perf-lab/stories.d) | Series |
| --- | --- | --- |
| pane-perf-terminal.py | pane-stress, pane-chromium (--browser) | `panes.<action>.<layout>.{frame,missed,posts_per_frame}` |
| pane-zoom-terminal.py | pane-zoom | `panes.<zoom|unzoom>.<layout>.{frame,missed,resizes_sent}` |
| split-spring-terminal.py | split-spring | `split_spring.<right|down>.{frame,missed,resizes_sent}` |
| anim-perf-terminal.py | anim-perf | `anim.<anim>.{frame,dropped,over_8_33,main_ms_max}` |

The pane and anim names are the perf cron's row names (perf-budgets.py rows_panes and rows_anim; pane-zoom uses
pane-perf-terminal.py's zoom and unzoom action names), so a lab series and a cron row of one gesture read the same and
the stories can claim the motion-dropped target's checks. `frame` holds every display frame interval of each gesture
(`debug.frames` stop with `raw`: intervals_ms), all rounds together, as Chrome hands raw samples to one histogram
(third_party/catapult/tracing/tracing/value/histogram.py); every other series holds one value per gesture. A gesture
that the app refused (its reply carried an error) is left out of every series: it moved nothing, so its frames are
idle ones. A bench records result-v1 only with an explicit --story, whose engine and session the run must have
(bench_story.story_problem), and only the series that story declares.
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, load_by_path  # noqa: E402
from bench_story import STORIES, story_problem  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))

PANE_STRESS_STORY = "pane-stress"
PANE_CHROMIUM_STORY = "pane-chromium"
PANE_ZOOM_STORY = "pane-zoom"
SPLIT_SPRING_STORY = "split-spring"
ANIM_STORY = "anim-perf"
INACTIVE_SUFFIX = "-inactive"  # pane-perf-terminal.py: a layout measured while its window was not key

Series = collections.namedtuple("Series", "story metric unit engine session samples")
# One series of a gesture group: its metric suffix, unit, and the values one gesture adds.
Field = collections.namedtuple("Field", "suffix unit values")


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def median(values):
    """The median of the numeric values (perf_stats.pct at 0.5, linear interpolation); None when there is none. A
    median of integers that lands on an integer stays an int, so a count prints as before."""
    numbers = [v for v in values if is_number(v)]
    value = perf_stats.pct(numbers, 0.5)
    if value is not None and all(isinstance(v, int) for v in numbers) and value == int(value):
        return int(value)
    return value


def frame_intervals(frames):
    """A `debug.frames` stop reply's raw frame intervals (ms), or [] when the build did not send them."""
    values = frames.get("intervals_ms") if isinstance(frames, dict) else None
    return [v for v in values if is_number(v)] if isinstance(values, list) else []


def frames_field():
    return Field("frame", "ms", lambda run: run.get("frame_intervals_ms") or [])


def per_gesture(suffix, unit, key=None):
    """A series of one value per gesture: the run's `key` (default the suffix)."""
    return Field(suffix, unit, lambda run: [run.get(key or suffix)])


class StoryError(ValueError):
    """Why a run must not record result-v1 under a story."""


class Story:
    """A lab story's result-v1 contract (stories.d/<id>.json): its one engine and session (perf-lab ingest refuses a
    run whose results differ on either), and the metric patterns it declares."""

    def __init__(self, story_id, engine, session, patterns):
        self.id, self.engine, self.session = story_id, engine, session
        self.patterns = [re.compile(p) for p in patterns]

    @classmethod
    def load(cls, story_id, engine, stories=STORIES):
        """The story `story_id` for a run that measures `engine`; raises StoryError when the story is unknown, names
        another engine or has no session or metrics."""
        problem = story_problem(story_id, engine, stories)
        if problem:
            raise StoryError(problem)
        path = os.path.join(stories, f"{story_id}.json")
        try:
            with open(path) as handle:
                doc = json.load(handle)
            return cls(story_id, doc["engine"], doc["session"], [metric["name"] for metric in doc["metrics"]])
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise StoryError(f"--story {story_id!r}: {path} is not a story file ({error!r})")

    def declares(self, metric):
        return any(pattern.fullmatch(metric) for pattern in self.patterns)

    def check_sessions(self, sessions):
        """Raises StoryError unless one of the run's `sessions` is the story's."""
        if self.session not in sessions:
            raise StoryError(f"--story {self.id!r} records session {self.session!r}; this run measures "
                             f"{', '.join(sorted(sessions)) or 'nothing'}")


def series_of(story, groups, fields):
    """Series for `groups` ([(metric prefix, runs)]), one per field the story declares; returns (series, skipped),
    skipped {metric: why it is not recorded}. A run with an `error` (the app refused the gesture) adds no value."""
    out, skipped = [], {}
    for prefix, runs in groups:
        kept = [run for run in runs if not run.get("error")]
        for field in fields:
            metric = f"{prefix}.{field.suffix}"
            if not story.declares(metric):
                continue
            samples = [v for run in kept for v in field.values(run) if is_number(v)]
            if samples:
                out.append(Series(story.id, metric, field.unit, story.engine, story.session, samples))
            else:
                skipped[metric] = (f"no {field.suffix} value in {len(kept)} gesture(s)"
                                   + (f" ({len(runs) - len(kept)} refused)" if len(kept) < len(runs) else ""))
    return out, skipped


def grouped(runs, key):
    """[(key value, runs)] in first-seen order."""
    groups = {}
    for run in runs:
        groups.setdefault(key(run), []).append(run)
    return list(groups.items())


def layout_session(layout):
    """The session of a pane-perf-terminal.py layout: `stress` is the STRESS session, a COLSxROWS grid is light."""
    return "stress" if layout.removesuffix(INACTIVE_SUFFIX) == "stress" else "light"


PANE_FIELDS = (frames_field(), per_gesture("missed", "count"), per_gesture("posts_per_frame", "unitless"))


def pane_series(runs, story):
    """pane-perf-terminal.py report runs -> `panes.<action>.<layout>.*` of the layouts of the story's session. A
    layout whose window was not key (`<layout>-inactive`) is not a person's frame pacing, so it is not recorded."""
    groups, skipped = [], {}
    for (layout, action), sel in grouped(runs, lambda r: (r.get("layout"), r.get("action"))):
        prefix = f"panes.{action}.{layout}"
        if layout.endswith(INACTIVE_SUFFIX):
            skipped[prefix] = "the window was not key"
        elif layout_session(layout) == story.session:
            groups.append((prefix, sel))
    series, missing = series_of(story, groups, PANE_FIELDS)
    return series, {**skipped, **missing}


ZOOM_FIELDS = (frames_field(), per_gesture("missed", "count"), per_gesture("resizes_sent", "count"))


def zoom_series(runs, story):
    """pane-zoom-terminal.py report runs -> `panes.<zoom|unzoom>.<layout>.*`, pane-perf-terminal.py's action names."""
    rows = [{**r, "error": r.get("reply_error")} for r in runs]
    return series_of(story, [(f"panes.{direction}.{layout}", sel) for (layout, direction), sel in
                             grouped(rows, lambda r: (r.get("layout"), r.get("direction")))], ZOOM_FIELDS)


def split_series(runs, story):
    """split-spring-terminal.py report runs -> `split_spring.<direction>.*`; a gesture with a refused press is out."""
    rows = [{**r, "error": "; ".join(r.get("errors") or [])} for r in runs]
    return series_of(story, [(f"split_spring.{direction}", sel) for direction, sel in
                             grouped(rows, lambda r: r.get("direction"))], ZOOM_FIELDS)


ANIM_FIELDS = (frames_field(), per_gesture("dropped", "count"), per_gesture("over_8_33", "count"),
               per_gesture("main_ms_max", "ms"))


def anim_series(runs, story):
    """anim-perf-terminal.py report runs -> `anim.<anim>.*`."""
    return series_of(story, [(f"anim.{name}", sel) for name, sel in grouped(runs, lambda r: r.get("anim"))],
                     ANIM_FIELDS)


def record(launcher, series, skipped):
    """Writes each series through BenchApp.record (new_tab_bench_report.record_all: one run per session); prints the
    skipped series. Returns {`story/metric`: path or `not recorded: <reason>`}, the skipped ones included."""
    from new_tab_bench_report import record_all
    for metric, why in skipped.items():
        print(f"result-v1 {metric}: not recorded: {why}", flush=True)
    written = record_all(launcher, series) if series else {}
    return {**written, **{metric: f"not recorded: {why}" for metric, why in skipped.items()}}


def written_count(written):
    return sum(1 for value in written.values() if not value.startswith("not recorded"))
