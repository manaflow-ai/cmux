#!/usr/bin/env python3
"""Story daemon-hangs: the daemon's hangs over 250 ms during the STRESS storm, on a `--config bench` build.

The daemon's hang watcher (p12-perf-process-232) counts every watched scope of its request and mux threads (a
request, a journal commit, a holder-link frame, an echo item) once it has been busy 250 ms, and `server-stats`
`include: ["hangs"]` answers `{over_250ms, records: [{sequence, span, duration_ms}]}`. The count is never reset, so
the story reads it on the daemon's own socket right before trace.py's measured window opens and right after it
closes, and stores the difference:

  daemon.hangs_over_250ms   hangs that began counting inside the window (target hangs.daemon: 0)
  daemon.hangs.duration_ms  the duration of each of the window's hangs, when there was one (monitored)

The window is the `stress-storm` scenario of scripts/cmux-next/trace.py (`light-storm` in the light session) with no
profiler. Chrome counts the same thing per process (`HangWatcher.IsThreadHung.*`, base/threading/hang_watcher.h);
blocking-hangs (task 037) reads the same section on a bench-checks build next to the app's own sources, and this
story measures the bench build, where no blocking detector runs.

A build whose daemon has no `hangs` section, or whose app cannot name its daemon (`debug.daemon`), is
not-measurable (exit 4), never 0. The window's records (span and duration) go to daemon-hangs-summary.json in --out.

Usage (the story runner appends --app, --tag and --out):
  python3 -I scripts/perf-lab/stories/daemon_hangs.py --app APP --tag TAG --out DIR [--seconds 60] [stress|light]
Exit: 0 a result; 1 the window was not the storm, or nothing could be written; 2 usage; 4 not measurable; 128+N
signal N. Not a CI gate (Lawrence 2026-10-23); the lab runs it as a T1 story (stories.d/daemon-hangs.json).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing trace.py and its siblings must not write __pycache__

import argparse
import importlib.util
import json
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from types import ModuleType
from typing import Callable, Mapping, Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_LAB = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PERF_LAB))
CMUX_NEXT = os.path.join(ROOT, "scripts", "cmux-next")

STORY = "daemon-hangs"
ENGINE = "none"
CONFIG = "bench"  # stories.d/daemon-hangs.json
COUNT_METRIC = "daemon.hangs_over_250ms"  # targets.json row hangs.daemon
DURATION_METRIC = "daemon.hangs.duration_ms"
TARGET = "hangs.daemon"
SCENARIOS = {"stress": "stress-storm", "light": "light-storm"}
SESSION = "stress"
SESSION_ENV = "PERF_LAB_SESSION"  # set by the story runner (task 008)
WINDOW_S = 60
SUMMARY = "daemon-hangs-summary.json"
TRACE_KEEP = ("SUMMARY.txt", "summary.json", "meta.json")

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_NOT_MEASURABLE = 0, 1, 2, 4


def load_by_path(name: str, path: str) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


# The daemon probe and the storm's stage checks are blocking-hangs' own (one copy of each).
blocking_hangs = load_by_path("perf_lab_blocking_hangs", os.path.join(HERE, "blocking_hangs.py"))


@dataclass
class Storm:
    """What one storm run saw: the daemon's readings around the window, trace.py's meta, the BenchApp that records
    results, and the exit code of a signal that ended the run (else None)."""
    before: object = None
    after: object = None
    meta: dict = field(default_factory=dict)
    bench: object = None
    terminated: Optional[int] = None


def window_metrics(window: dict) -> dict:
    """{metric: samples} of a blocking_hangs.daemon_window result that is not unseen."""
    metrics = {COUNT_METRIC: [window["over_250ms"]]}
    durations = [r["duration_ms"] for r in window["records"]
                 if isinstance(r.get("duration_ms"), (int, float)) and not isinstance(r.get("duration_ms"), bool)]
    if durations:
        metrics[DURATION_METRIC] = durations
    return metrics


def storm_problems(storm: Storm) -> list:
    """Why the window is not the session's storm, or why the daemon could not be read."""
    problems = list(blocking_hangs.measured_stage_problems(storm.meta))
    if storm.before is None or storm.after is None:
        problems.append("trace.py never reached its measured window")
    return problems


def record_storm(storm: Storm, window: dict, session: str, out: str, writer) -> str:
    """Writes the window's results as one result-v1 file in `out` and returns its path. BenchApp.record stages each
    result in the storm's own folder (it fills build, host and features); they are read back and written once."""
    bench = storm.bench
    bench.perf_session = session
    bench.build_config = CONFIG
    staged = []
    try:
        for metric, samples in sorted(window_metrics(window).items()):
            unit = "count" if metric == COUNT_METRIC else "ms"
            target = TARGET if metric == COUNT_METRIC else None
            staged.append(str(bench.record(STORY, metric, unit, samples, "lower", ENGINE, target_ref=target)))
        results = [result for path in staged for result in writer.read_file(path)]
        return str(writer.write_ndjson(out, results, repo_root=ROOT))
    finally:
        for path in staged:
            if os.path.exists(path):
                os.unlink(path)


def run_storm(app: str, out: str, session: str, seconds: float, probe_for: Optional[Callable] = None) -> Storm:
    """trace.py's storm of `session`, with the daemon's `hangs` read right before and right after its window.
    `probe_for(rpc)` makes the daemon probe (blocking_hangs.DaemonProbe; tests pass one with fake seams)."""
    trace = load_by_path("cmux_next_trace", os.path.join(CMUX_NEXT, "trace.py"))
    probe_for = probe_for or blocking_hangs.DaemonProbe
    storm = Storm()

    class HangsRecording(trace.Recording):
        def run_window(self):
            probe = probe_for(self.rpc)
            storm.before = probe.read()
            super().run_window()
            storm.after = probe.read()

    opts = blocking_hangs.trace_options(app, out, seconds)
    opts.scenario = SCENARIOS[session]
    bundle = os.path.realpath(app).rstrip("/")
    storm.meta = {"host": os.uname().nodename, "bundle": bundle, "scenario": opts.scenario, "seconds": seconds,
                  "argv": sys.argv[1:], "recorder": opts.recorder, "sources": {}, "warnings": []}
    recording = HangsRecording(opts, out, storm.meta, trace.Stages(storm.meta), bundle, opts.recorder)
    recording.record()
    storm.terminated = recording.terminated
    storm.bench = recording.app.bench if recording.app is not None else None
    return storm


def parse_args(argv: Optional[Sequence[str]]):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True, help="the bench `cmux DEV <tag>.app` (not running)")
    p.add_argument("--tag", help="the app's tag (the runner passes it; the bundle names its own tag)")
    p.add_argument("--out", required=True, help="the run folder: result-v1 files and the summary")
    p.add_argument("--seconds", type=float, default=WINDOW_S, help="the storm's measured window")
    p.add_argument("--session", default=None, help=f"the session (default ${SESSION_ENV}, else {SESSION})")
    p.add_argument("session_word", nargs="?", default=None, metavar="SESSION", help="the session, as a word")
    opts = p.parse_args(argv)
    sessions = {s for s in (opts.session, opts.session_word) if s is not None}
    if len(sessions) > 1:
        p.error(f"two sessions: {', '.join(sorted(sessions))}")
    opts.session = sessions.pop() if sessions else None
    if opts.seconds <= 0:
        p.error("--seconds must be positive")
    return opts


def main(argv: Optional[Sequence[str]] = None, environ: Optional[Mapping[str, str]] = None,
         storm_runner: Callable[[str, str, str, float], Storm] = run_storm) -> int:
    opts = parse_args(argv)
    environ = os.environ if environ is None else environ
    session = opts.session or environ.get(SESSION_ENV) or SESSION
    if session not in SCENARIOS:
        print(f"{STORY}: session {session!r}: this story runs {' or '.join(SCENARIOS)}", file=sys.stderr)
        return EXIT_USAGE
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    load_by_path("bench_launch", os.path.join(CMUX_NEXT, "bench_launch.py"))  # the copy trace.py and BenchApp share
    writer = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
    work = tempfile.mkdtemp(prefix=f"{STORY}-")
    try:
        storm = storm_runner(opts.app, work, session, opts.seconds)
        keep_trace(work, os.path.join(out, "storm-trace"))
        return judge(storm, session, out, writer)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def judge(storm: Storm, session: str, out: str, writer) -> int:
    """The story's exit for one storm run, with its result written when the window measured the daemon."""
    if storm.terminated is not None:
        return finish(out, storm.terminated, f"stopped by a signal (exit {storm.terminated})")
    problems = storm_problems(storm)
    if problems:
        return finish(out, EXIT_FAILED, "; ".join(problems)[:600])
    window = blocking_hangs.daemon_window(storm.before, storm.after)
    if "unseen" in window:
        return finish(out, EXIT_NOT_MEASURABLE, f"not-measurable: {window['unseen']}")
    if storm.bench is None:
        return finish(out, EXIT_FAILED, "trace.py launched no app to record with")
    try:
        path = record_storm(storm, window, session, out, writer)
    except Exception as error:  # noqa: BLE001 - bench_launch.RecordError or perf_result.ResultError: said, not raised
        return finish(out, EXIT_FAILED, f"{type(error).__name__}: {error}"[:600])
    spans = ", ".join(f"{r.get('span')} {r.get('duration_ms')} ms" for r in window["records"])
    print(f"{STORY}: {COUNT_METRIC} {window['over_250ms']}" + (f" ({spans})" if spans else ""))
    return finish(out, EXIT_OK, None, window=window, results=os.path.relpath(path, out))


def finish(out: str, code: int, reason: Optional[str], **summary) -> int:
    """Writes daemon-hangs-summary.json (what the window saw, or why nothing was stored) and returns `code`."""
    if reason:
        print(f"{STORY}: {reason}", file=sys.stderr)
    doc = {"story": STORY, "exit": code, "reason": reason, **summary}
    temporary = os.path.join(out, f".{SUMMARY}.tmp")
    with open(temporary, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")
    os.replace(temporary, os.path.join(out, SUMMARY))
    return code


def keep_trace(source: str, dest: str) -> None:
    """Copies trace.py's summary and meta into the run folder (no *.ndjson: the runner reads those as results)."""
    os.makedirs(dest, exist_ok=True)
    for name in TRACE_KEEP:
        path = os.path.join(source, name)
        if os.path.isfile(path):
            shutil.copy2(path, os.path.join(dest, name))


if __name__ == "__main__":
    sys.exit(main())
