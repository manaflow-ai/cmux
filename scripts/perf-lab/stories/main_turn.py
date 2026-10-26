#!/usr/bin/env python3
"""Story main-turn: main-thread turn p99 and input-queueing p99 during the STRESS storm and each corpus story.

The app's watchdog counts every main run-loop turn (wake to the end of beforeWaiting) and every input's queueing
(OS event time to dispatch) in two histograms of 69 exponential buckets, 50 us to 10 s, each edge at most 1.2x the
one below (task p12-perf-process-031, `debug.hangs` `turn_histogram`). This story reads both histograms when a
measured window opens and when it closes, and takes percentiles from the difference.

A bucketed histogram knows a percentile only up to its bucket, so each percentile is reported as the interval of
the bucket its rank falls in: `<h>.<pNN>` is the bucket's upper edge (capped by the histogram's max) and
`<h>.<pNN>.low` its lower edge. A pass of `main_turn.p99 <= 4 ms` is then a proven pass. Chrome reads its UMA and
Telemetry histograms the same way, from bins (third_party/catapult/tracing/tracing/value/histogram.py,
`Histogram.GetApproximatePercentile`, which returns a point inside the bin; the bin's bounds are the interval);
input queueing is the queue part of Chrome's kQueueAndExecution
(content/browser/scheduler/responsiveness/calculator.h).

Legs:
  storm         trace.py's stress-storm scenario (STRESS, a CLI storm at 10/s, keys every 0.12 s, action chords),
                in this process with no profiler (no xctrace, no `sample`, no Chromium trace: a profiler stops
                the main thread and would lengthen the turns it measures). The histograms are read at the start
                and the end of trace.py's measured window. Metrics main_turn.* (target `main-turn`) and
                input_queue.*.
  corpus:<id>   each recorded-session corpus story (perf-corpus/<id>.json, task 110; T2 soaks excluded), replayed
                by scripts/perf-lab/corpus/play.py (task 115) through its window hook:
                `play.replay(manifest, app=APP, out=DIR, window=W)` calls `W(bench)` for a context manager and
                runs its measured replay inside it. Metrics corpus.<id>.main_turn.* and corpus.<id>.input_queue.*.
                A checkout without the corpus or its player has no corpus legs; that is said, not a failure.

Results: one result-v1 file per leg in --out (BenchApp.record fills build, host and features), each result with
the leg's histogram attachment (kind `histogram`: the before, after and window counts and every interval), stored
content-addressed as --out/attachments/sha256-<hex>.json. main-turn-summary.json says what each leg measured.

A build without `turn_histogram` (before task 031) is not measurable: the story refuses before the STRESS build
with that reason (exit 4), and stores nothing. The catalog's `needs` names `debug.hangs` for the capability check.

Usage (the story runner appends --app, --tag and --out):
  python3 -I scripts/perf-lab/stories/main_turn.py --app APP --tag TAG --out DIR [--legs storm,corpus]
                                                   [--corpus all|ID,...] [--seconds 30] [--config bench]
Exit: 0 every leg measured; 1 a leg failed; 2 usage; 4 not measurable; 128+N stopped by signal N.
"""
from __future__ import annotations

import argparse
import dataclasses
import glob
import hashlib
import importlib.util
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from fractions import Fraction
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_LAB = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PERF_LAB))
CMUX_NEXT = os.path.join(ROOT, "scripts", "cmux-next")
TRACE = os.path.join(CMUX_NEXT, "trace.py")
BENCH_LAUNCH = os.path.join(CMUX_NEXT, "bench_launch.py")
PERF_RESULT = os.path.join(PERF_LAB, "perf_result.py")

STORY = "main-turn"
ENGINE = "none"
# (metric prefix, debug.hangs turn_histogram key)
HISTOGRAMS = (("main_turn", "main_turn"), ("input_queue", "input_queueing"))
QUANTILES = (("p50", Fraction(50, 100)), ("p95", Fraction(95, 100)), ("p99", Fraction(99, 100)))
TARGETS = {"main_turn.p99": "main-turn"}  # targets.json ids; only the storm leg claims a target row
ATTACHMENT_KIND = "histogram"
ATTACHMENT_SCHEMA = "cmux-turn-histogram/v1"
# trace.py stages before and including the measured window: an error in one means the window is not STRESS under
# the storm, so its numbers are not stored. Errors after it (the stop, the export, the build) do not touch them.
MEASURED_STAGES = ("preflight", "launch", "stress-build", "storm-setup", "recorders-start", "window")
TRACE_KEEP = ("trace.json.gz", "SUMMARY.txt", "summary.json", "meta.json", "hangs.json")

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_NOT_MEASURABLE = 0, 1, 2, 4


class NotMeasurable(Exception):
    """The build has no turn histogram: its Change is not-measurable, never a regression."""


class LegError(Exception):
    """A leg ran but measured nothing it can store."""


def load_by_path(name: str, path: str):
    """The module at `path` as `name`, once per process (python3 -I puts no script folder on sys.path)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"main-turn: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


# ---------------------------------------------------------------- histograms


@dataclasses.dataclass(frozen=True)
class Histogram:
    """One `turn_histogram` histogram: `counts[0]` is below `edges_ms[0]`, `counts[i]` is in
    `[edges_ms[i - 1], edges_ms[i])`, the last bucket is `edges_ms[-1]` or more. `max_ms` is the largest
    sample since launch or the last `debug.hangs clear`."""

    edges_ms: Tuple[float, ...]
    counts: Tuple[int, ...]
    max_ms: Optional[float]

    @property
    def count(self) -> int:
        return sum(self.counts)

    def to_dict(self) -> dict:
        return {"count": self.count, "buckets": list(self.counts), "max_ms": self.max_ms}


def parse_turn_histograms(reply) -> Dict[str, Histogram]:
    """{key: Histogram} for each of HISTOGRAMS from a `debug.hangs` reply. NotMeasurable when the reply has no
    `turn_histogram` (a build before task 031); LegError when the call failed or the histogram does not parse."""
    if not isinstance(reply, dict) or reply.get("error"):
        detail = reply.get("error") if isinstance(reply, dict) else reply
        raise LegError(f"debug.hangs failed: {json.dumps(detail)[:300]}")
    block = reply.get("turn_histogram")
    if block is None:
        raise NotMeasurable("the build's debug.hangs has no turn_histogram (p12-perf-process-031 is not in it)")
    if not isinstance(block, dict):
        raise LegError(f"turn_histogram is not an object: {json.dumps(block)[:200]}")
    edges_us = block.get("edges_us")
    if (not isinstance(edges_us, list) or not edges_us or not all(_is_number(e) for e in edges_us)
            or any(b <= a for a, b in zip(edges_us, edges_us[1:]))):
        raise LegError("turn_histogram.edges_us is not an increasing list of numbers")
    edges_ms = tuple(float(e) / 1000.0 for e in edges_us)
    parsed = {}
    for _, key in HISTOGRAMS:
        item = block.get(key)
        buckets = item.get("buckets") if isinstance(item, dict) else None
        if (not isinstance(buckets, list) or len(buckets) != len(edges_ms) + 1
                or not all(isinstance(c, int) and not isinstance(c, bool) and c >= 0 for c in buckets)):
            raise LegError(f"turn_histogram.{key}.buckets is not {len(edges_ms) + 1} counts")
        max_ms = item.get("max_ms")
        parsed[key] = Histogram(edges_ms, tuple(buckets), float(max_ms) if _is_number(max_ms) else None)
    return parsed


def window_delta(before: Histogram, after: Histogram) -> Histogram:
    """The window's own counts: `after - before` per bucket. LegError when a bucket went back (a `debug.hangs
    clear` or another app process inside the window): the difference would not be the window."""
    if before.edges_ms != after.edges_ms:
        raise LegError("the histogram's edges changed inside the window")
    counts = tuple(a - b for a, b in zip(after.counts, before.counts))
    if any(c < 0 for c in counts):
        raise LegError("the histogram went back inside the window (cleared, or another app process)")
    return Histogram(after.edges_ms, counts, after.max_ms)


def percentile_interval(histogram: Histogram, quantile: Fraction) -> Optional[Tuple[float, float]]:
    """(low, high) ms of the bucket that holds the `quantile` rank (nearest rank, ceil(n * q)); the true
    percentile is in it. The high edge is capped by `max_ms` (no sample is above it); the overflow bucket's
    high edge is `max_ms`. None for an empty histogram. LegError for an overflow rank with no max."""
    total = histogram.count
    if total == 0:
        return None
    rank = max(1, math.ceil(Fraction(total) * quantile))
    seen = 0
    edges = histogram.edges_ms
    for bucket, count in enumerate(histogram.counts):
        if count and seen + count >= rank:
            low = 0.0 if bucket == 0 else edges[bucket - 1]
            high = edges[bucket] if bucket < len(edges) else math.inf
            if histogram.max_ms is not None:
                high = min(high, histogram.max_ms)
            if math.isinf(high):
                raise LegError(f"the {float(quantile):g} rank is in the overflow bucket and the histogram has no max")
            return min(low, high), high
        seen += count
    raise AssertionError("unreachable: the ranks add up to the total")


class TurnWindow:
    """Reads `debug.hangs` `turn_histogram` when the measured window opens (`__enter__`) and when it closes
    (`__exit__`, only when the window ended normally). A read's failure is kept on `error` and raised, so the
    caller still sees it after a harness that catches its stage's exceptions."""

    def __init__(self, rpc: Callable):
        self.rpc = rpc
        self.before: Optional[Dict[str, Histogram]] = None
        self.after: Optional[Dict[str, Histogram]] = None
        self.error: Optional[Exception] = None

    def read(self) -> Dict[str, Histogram]:
        try:
            # limit 0: the histogram only, not the stall records (the read is one more short main-thread turn).
            return parse_turn_histograms(self.rpc("debug.hangs", {"limit": 0}, timeout=10))
        except (NotMeasurable, LegError) as error:
            self.error = self.error or error
            raise

    def __enter__(self) -> "TurnWindow":
        self.before = self.read()
        return self

    def __exit__(self, kind, error, _traceback) -> bool:
        if kind is None:
            self.after = self.read()
        return False

    def deltas(self) -> Dict[str, Histogram]:
        if self.error is not None:
            raise self.error
        if self.before is None or self.after is None:
            raise LegError("the measured window did not finish: no histogram read at its end")
        return {key: window_delta(self.before[key], self.after[key]) for _, key in HISTOGRAMS}


# ---------------------------------------------------------------- results


@dataclasses.dataclass
class Leg:
    name: str  # storm or corpus:<id>
    session: str  # result-v1 session
    metric_prefix: str  # "" for the storm, "corpus.<id>." for a corpus story
    ok: bool = False
    reason: Optional[str] = None
    intervals: Dict[str, List[float]] = dataclasses.field(default_factory=dict)
    counts: Dict[str, int] = dataclasses.field(default_factory=dict)
    notes: List[str] = dataclasses.field(default_factory=list)
    results: Optional[str] = None
    attachment: Optional[str] = None

    def summary(self) -> dict:
        return dataclasses.asdict(self)


def leg_intervals(leg: Leg, deltas: Dict[str, Histogram]) -> Dict[str, Tuple[float, float]]:
    """{metric: (low, high)} of the leg's window. LegError when the window counted no main turn; an empty input
    histogram (the window dispatched no OS input event) is a note, and its metrics are not written."""
    intervals = {}
    for prefix, key in HISTOGRAMS:
        histogram = deltas[key]
        leg.counts[prefix] = histogram.count
        if histogram.count == 0:
            if key == "main_turn":
                raise LegError("the window counted no main turn")
            leg.notes.append(f"{prefix}: no input event was dispatched in the window; no {prefix} metrics")
            continue
        for name, quantile in QUANTILES:
            intervals[f"{leg.metric_prefix}{prefix}.{name}"] = percentile_interval(histogram, quantile)
    return intervals


def write_attachment(out: str, leg: Leg, window: TurnWindow, deltas: Dict[str, Histogram],
                     intervals: Dict[str, Tuple[float, float]]) -> str:
    """Writes the leg's histogram blob under out/attachments/ named by its sha256; returns `sha256:<hex>`."""
    edges = next(iter(deltas.values())).edges_ms
    doc = {"schema": ATTACHMENT_SCHEMA, "story": STORY, "leg": leg.name, "session": leg.session,
           "edges_ms": list(edges),
           "before": {key: window.before[key].to_dict() for _, key in HISTOGRAMS},
           "after": {key: window.after[key].to_dict() for _, key in HISTOGRAMS},
           "window": {key: deltas[key].to_dict() for _, key in HISTOGRAMS},
           "intervals_ms": {metric: list(bounds) for metric, bounds in sorted(intervals.items())}}
    data = (json.dumps(doc, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    digest = hashlib.sha256(data).hexdigest()
    folder = os.path.join(out, "attachments")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"sha256-{digest}.json")
    if not os.path.exists(path):
        temporary = path + ".tmp"
        with open(temporary, "wb") as f:
            f.write(data)
        os.replace(temporary, path)
    return f"sha256:{digest}"


def record_leg(bench, writer, leg: Leg, window: TurnWindow, out: str, config: Optional[str]) -> None:
    """Writes the leg's results into `out`: BenchApp.record stages each result (it fills build, host and
    features), then the leg's results are written again as one file with the histogram attachment, as
    trace_quest.with_traces adds trace attachments; the staged files are removed."""
    deltas = window.deltas()
    intervals = leg_intervals(leg, deltas)
    digest = write_attachment(out, leg, window, deltas, intervals)
    bench.perf_session = leg.session
    if config:
        bench.build_config = config
    staged = []
    try:
        for metric, (low, high) in sorted(intervals.items()):
            target = TARGETS.get(metric)
            staged.append(bench.record(STORY, metric, "ms", [high], "lower", ENGINE, target_ref=target))
            staged.append(bench.record(STORY, f"{metric}.low", "ms", [low], "lower", ENGINE))
        attachment = writer.Attachment(digest=digest, kind=ATTACHMENT_KIND)
        results = [dataclasses.replace(result, attachments=[*result.attachments, attachment])
                   for path in staged for result in writer.read_file(path)]
        leg.results = os.path.relpath(str(writer.write_ndjson(out, results, repo_root=ROOT)), out)
    finally:
        for path in staged:
            _unlink(str(path))
    leg.intervals = {metric: list(bounds) for metric, bounds in sorted(intervals.items())}
    leg.attachment = digest
    leg.ok = True


# ---------------------------------------------------------------- the storm leg


def storm_recording(trace):
    """trace.py's Recording with the turn reads around its measured window, and a turn-histogram check right
    after the launch, before the minutes of the STRESS build."""

    class StormRecording(trace.Recording):
        turns: Optional[TurnWindow] = None

        def build_stress(self):
            self.turns = TurnWindow(self.rpc)
            self.turns.read()  # NotMeasurable here ends the run before the STRESS build
            return super().build_stress()

        def run_window(self):
            self.turns = TurnWindow(self.rpc)
            with self.turns:
                super().run_window()

    return StormRecording


def trace_options(app: str, out: str, seconds: float):
    """trace.py `record --app APP --scenario stress-storm` options with no profiler: `recorder` is set to
    `none` on the Recording (neither xctrace nor sample starts), and no Chromium DevTools trace."""
    return argparse.Namespace(app=app, bundle=None, socket=None, out=out, scenario="stress-storm", seconds=seconds,
                              seconds_cap=600, recorder="none", system_trace=False, no_cef=True, cdp_port=0,
                              hang_ms=8, storm_hz=10, key_interval=0.12, chord_every=10, keep=False,
                              keep_recording=False, command=[])


def measured_stage_problems(meta: dict) -> List[str]:
    """Why trace.py's window is not the STRESS storm: an error or a passed bound in a stage up to the window, or a
    window that was not key."""
    problems = [f"{e.get('stage')}: {e.get('error')}" for e in meta.get("errors") or []
                if e.get("stage") in MEASURED_STAGES]
    problems += [f"{stage}: passed its bound" for stage in meta.get("timed_out") or [] if stage in MEASURED_STAGES]
    if str(meta.get("scenario_label") or "").endswith("-inactive"):
        problems.append("the app's window was not key (a GUI job took it): not a person's turns")
    return problems


def run_storm(opts, work: str, writer) -> Tuple[Leg, Optional[int]]:
    """The storm leg; returns it and the exit code of a signal that ended trace.py's run (else None)."""
    leg = Leg(name="storm", session="stress", metric_prefix="")
    trace = load_by_path("cmux_next_trace", TRACE)
    trace_dir = tempfile.mkdtemp(prefix="main-turn-storm-", dir=work)
    topts = trace_options(opts.app, trace_dir, opts.seconds)
    bundle = os.path.realpath(opts.app).rstrip("/")
    meta = {"host": os.uname().nodename, "macos": _macos_version(), "bundle": bundle, "scenario": topts.scenario,
            "seconds": topts.seconds, "argv": sys.argv[1:], "recorder": topts.recorder, "sources": {},
            "warnings": []}
    recording = storm_recording(trace)(topts, trace_dir, meta, trace.Stages(meta), bundle, topts.recorder)
    recording.record()
    _keep_trace(trace_dir, os.path.join(opts.out, "storm-trace"))
    if recording.terminated is not None:
        leg.reason = f"stopped by a signal (exit {recording.terminated})"
        return leg, recording.terminated
    window = recording.turns
    try:
        if window is not None and window.error is not None:
            raise window.error
        problems = measured_stage_problems(meta)
        if problems:
            raise LegError("; ".join(problems)[:600])
        if window is None:
            raise LegError("trace.py never reached its measured window")
        record_leg(recording.app.bench, writer, leg, window, opts.out, opts.config)
    except LegError as error:
        leg.reason = str(error)
    return leg, None


# ---------------------------------------------------------------- the corpus legs


def corpus_manifests(root: str, wanted: str) -> List[Tuple[str, str]]:
    """[(id, manifest path)] of the corpus stories to replay: `all` is every manifest whose tier is not T2 (the
    8 h soak is its own story), else the comma-separated ids. LegError for a named id with no manifest."""
    folder = os.path.join(root, "perf-corpus")
    found = {}
    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("id"), str):
            found[doc["id"]] = (path, doc.get("tier"))
    if wanted == "all":
        return [(story_id, path) for story_id, (path, tier) in sorted(found.items()) if tier != "T2"]
    picked = []
    for story_id in [s for s in wanted.split(",") if s]:
        if story_id not in found:
            raise LegError(f"no corpus manifest {story_id} in perf-corpus/")
        picked.append((story_id, found[story_id][0]))
    return picked


def run_corpus(play, story_id: str, manifest: str, opts, work: str, writer) -> Leg:
    """One corpus leg: play.replay with a window hook that opens a TurnWindow on the replay's BenchApp."""
    leg = Leg(name=f"corpus:{story_id}", session=f"corpus:{story_id}", metric_prefix=f"corpus.{story_id}.")
    opened: Dict[str, object] = {}

    def window(bench):
        opened["bench"], opened["window"] = bench, TurnWindow(bench.rpc)
        return opened["window"]

    try:
        if not callable(getattr(play, "replay", None)):
            raise LegError("scripts/perf-lab/corpus/play.py has no replay(manifest, app=, out=, window=) hook")
        play.replay(manifest, app=opts.app, out=tempfile.mkdtemp(prefix=f"main-turn-{story_id}-", dir=work),
                    window=window)
        if "window" not in opened:
            raise LegError("the replay never opened its measured window")
        record_leg(opened["bench"], writer, leg, opened["window"], opts.out, opts.config)
    except LegError as error:
        leg.reason = str(error)
    return leg


def corpus_legs(opts, work: str, writer, root: str = ROOT) -> Tuple[List[Leg], List[str]]:
    """The corpus legs, and notes for a checkout that has no corpus or no player (not failures)."""
    if not os.path.isdir(os.path.join(root, "perf-corpus")):
        return [], ["no perf-corpus/ in this checkout (p12-perf-process-110): no corpus legs"]
    try:
        manifests = corpus_manifests(root, opts.corpus)
    except LegError as error:
        return [Leg(name="corpus", session="corpus:none", metric_prefix="", reason=str(error))], []
    if not manifests:
        return [], ["perf-corpus/ has no manifest to replay"]
    play_path = os.path.join(root, "scripts", "perf-lab", "corpus", "play.py")
    if not os.path.isfile(play_path):
        return [], ["no scripts/perf-lab/corpus/play.py (p12-perf-process-115): corpus manifests not replayed"]
    play = load_by_path("perf_lab_corpus_play", play_path)
    return [run_corpus(play, story_id, path, opts, work, writer) for story_id, path in manifests], []


# ---------------------------------------------------------------- main


def parse_args(argv: Optional[Sequence[str]]):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True, help="the bench `cmux DEV <tag>.app` (not running)")
    p.add_argument("--tag", help="the app's tag (the runner passes it; the bundle names its own tag)")
    p.add_argument("--out", required=True, help="the run folder: result-v1 files, attachments, summary")
    p.add_argument("--legs", default="storm,corpus", help="storm, corpus, or both (comma-separated)")
    p.add_argument("--corpus", default="all", help="all (every non-T2 manifest) or corpus story ids")
    p.add_argument("--seconds", type=float, default=30, help="the storm's measured window")
    p.add_argument("--config", default=None, help="result-v1 build config of a bench-hooks bundle (bench)")
    opts = p.parse_args(argv)
    legs = {leg for leg in opts.legs.split(",") if leg}
    if not legs or legs - {"storm", "corpus"}:
        p.error(f"--legs takes storm and corpus, not {opts.legs!r}")
    opts.legs = legs
    if opts.seconds <= 0:
        p.error("--seconds must be positive")
    return opts


def main(argv: Optional[Sequence[str]] = None) -> int:
    opts = parse_args(argv)
    opts.out = os.path.abspath(opts.out)
    os.makedirs(opts.out, exist_ok=True)
    load_by_path("bench_launch", BENCH_LAUNCH)  # the one copy trace.py, play.py and BenchApp.record share
    writer = load_by_path("perf_result", PERF_RESULT)
    work = tempfile.mkdtemp(prefix="main-turn-")
    legs: List[Leg] = []
    notes: List[str] = []
    signalled = None
    code = EXIT_OK
    try:
        if "storm" in opts.legs:
            try:
                leg, signalled = run_storm(opts, work, writer)
                legs.append(leg)
            except NotMeasurable as error:
                return refuse(opts.out, str(error))
        if "corpus" in opts.legs and signalled is None:
            try:
                corpus, notes = corpus_legs(opts, work, writer)
            except NotMeasurable as error:
                return refuse(opts.out, str(error))
            legs += corpus
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if signalled is not None:
        code = signalled
    elif any(not leg.ok for leg in legs) or not legs:
        code = EXIT_FAILED
    write_summary(opts.out, {"story": STORY, "refusal": None, "legs": [leg.summary() for leg in legs],
                             "notes": notes, "exit": code})
    for leg in legs:
        shown = ", ".join(f"{m} {lo:.3g}..{hi:.3g} ms" for m, (lo, hi) in leg.intervals.items() if m.endswith("p99"))
        print(f"main-turn: {leg.name}: " + (f"ok ({shown}; turns {leg.counts})" if leg.ok else f"FAILED: {leg.reason}"))
        for line in leg.notes:
            print(f"main-turn: {leg.name}: {line}")
    for line in notes:
        print(f"main-turn: {line}")
    if not legs:
        print("main-turn: FAILED: no leg ran", file=sys.stderr)
    return code


def refuse(out: str, reason: str) -> int:
    """Not measurable: nothing stored, one reason line (stderr and the summary)."""
    write_summary(out, {"story": STORY, "refusal": {"kind": "not-measurable", "reason": reason}, "legs": [],
                        "notes": [], "exit": EXIT_NOT_MEASURABLE})
    print(f"main-turn: not-measurable: {reason}", file=sys.stderr)
    return EXIT_NOT_MEASURABLE


def write_summary(out: str, summary: dict) -> None:
    with open(os.path.join(out, "main-turn-summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")


def _keep_trace(trace_dir: str, dest: str) -> None:
    """Copies trace.py's timeline and summary into the run folder (no *.ndjson: the runner reads those as
    results)."""
    os.makedirs(dest, exist_ok=True)
    for name in TRACE_KEEP:
        source = os.path.join(trace_dir, name)
        if os.path.isfile(source):
            shutil.copy2(source, os.path.join(dest, name))


def _macos_version() -> str:
    try:
        return subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


if __name__ == "__main__":
    sys.exit(main())
