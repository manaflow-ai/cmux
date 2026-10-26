#!/usr/bin/env python3
"""Story daemon-ops: daemon op latency from the daemon's debug spans during a storm (perf-lead.md, rules D1-D8).

The story records the `stress-storm` scenario of scripts/cmux-next/trace.py (the `light-storm` one in the light
session): STRESS is built, then a CLI storm rearranges the sidebar while keys and action chords (new tab, split,
close) are typed. trace.py launches the app with CMUX_NEXT_TUI_DEBUG_SPANS, so the daemon writes one span line per
traced request (CMUX_TUI_DEBUG_SPANS, cmux-tui-util/src/debug_spans.rs). The lines are read with trace.py's own span
parser (`daemon_span_events`, never a copy), grouped by op (the span's label), and written as result-v1:

  daemon.<op>.ms           one sample per request of that op, arrival to reply queued (per op: stored, not alerted)
  daemon.ops.ms            every op's samples together (monitored: subscriptions.json `aggregate-daemon-ops`)
  daemon.ops.over_budget   the number of ops whose p95 is over OP_P95_BUDGET_MS (monitored)

As on Chrome's perf dashboard, where only the series a sheriff subscription matches can alert and the rest are
stored (catapult dashboard/dashboard/protobuf/sheriff.proto), the per-op series feed the monitored aggregates. The daemon traces resource creates (workspace, tab, pane), terminal creates (new-tab, pane-create,
create); other requests carry no span yet, so they are not in these series (trace.py `unobserved`). Spans that are not
a request of the daemon are left out: `<label>.follow` (a terminal's first output after its create), `host` (a
terminal host process's own launch) and `slow-request` (the request watchdog's record of a request already counted).

The story takes the runner's `--app APP --tag TAG --out DIR` (stories.d/README.md) and the session as
$PERF_LAB_SESSION, `--session` or a trailing word. The trace stays in DIR/trace; the per-op table goes beside the
result in daemon-ops.ops.json.

  python3 scripts/perf-lab/stories/daemon_ops.py --app APP --tag TAG --out DIR stress   # as the runner
  python3 scripts/perf-lab/stories/daemon_ops.py --from-trace DIR                       # the table of a recorded trace
  python3 scripts/perf-lab/stories/daemon_ops.py --from-trace DIR --json

Not a CI gate (Lawrence 2026-10-23); the lab runs it as a T1 story (stories.d/daemon-ops.json).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing trace.py and its siblings must not write __pycache__

import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Callable, Mapping, Sequence

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
SCRIPTS = PERF_LAB.parent
ROOT = SCRIPTS.parent
TRACE_PY = SCRIPTS / "cmux-next" / "trace.py"

STORY = "daemon-ops"
SELF_PATH = "scripts/perf-lab/stories/daemon_ops.py"  # target_ref path: the budget below is read from this file
# perf-lead.md "Daemon and acpmux targets", row T: every daemon op < 2 ms p95 send to reply, light and STRESS
# (the rules D1-D8 are how the daemon gets there). The one copy of the number: the story's target_ref names it.
OP_P95_BUDGET_MS = 2.0
BUDGET_KEY = "OP_P95_BUDGET_MS"
AGGREGATE = "ops"
NOT_REQUESTS = frozenset({"host", "slow-request"})
FOLLOW_SUFFIX = ".follow"
SCENARIOS = {"stress": "stress-storm", "light": "light-storm"}
SESSION = "stress"  # stories.d/daemon-ops.json
STORY_CONFIG = "bench"  # stories.d/daemon-ops.json: a latency story measures the bench build (README, R6)
WINDOW_S = 60  # the storm's window: about 15 creates of each chord kind at trace.py's default pace
TRACE_DIR = "trace"
OPS_FILE = "daemon-ops.ops.json"
SESSION_ENV = "PERF_LAB_SESSION"  # set by the story runner (task 008)
SPAN_PID = 1  # daemon_span_events places spans on tracks of a pid; the story reads only their durations
FORWARDED_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


class StoryError(RuntimeError):
    """The story has nothing to write (no app, an unknown session, a trace with no daemon op spans)."""


def load_by_path(name: str, path: Path) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


trace = load_by_path("perf_lab_daemon_ops_trace", TRACE_PY)  # puts scripts/cmux-next on sys.path, loads bench_launch
bench_launch = load_by_path("bench_launch", SCRIPTS / "cmux-next" / "bench_launch.py")
perf_result = load_by_path("perf_lab_daemon_ops_perf_result", PERF_LAB / "perf_result.py")
perf_stats = load_by_path("perf_lab_daemon_ops_perf_stats", PERF_LAB / "perf_stats.py")


def op_of(label: str) -> str | None:
    """The op a span label names, as one metric-name segment, or None for a span that is not a daemon request."""
    if label.endswith(FOLLOW_SUFFIX) or label in NOT_REQUESTS:
        return None
    op = re.sub(r"[^a-z0-9_-]+", "_", label.lower()).strip("_")
    return op if op and op != AGGREGATE else None


def metric(op: str, kind: str = "ms") -> str:
    return f"daemon.{op}.{kind}"


@dataclass(frozen=True)
class Report:
    ops: dict[str, tuple[float, ...]]  # op -> request times in ms, in the order the spans were read

    @property
    def all_ms(self) -> list[float]:
        return [ms for samples in self.ops.values() for ms in samples]

    def p95(self, op: str) -> float:
        return perf_stats.pct(self.ops[op], 0.95)

    @property
    def over_budget(self) -> list[str]:
        return [op for op in self.ops if self.p95(op) > OP_P95_BUDGET_MS]

    def table(self) -> dict:
        return {"budget_p95_ms": OP_P95_BUDGET_MS, "over_budget": self.over_budget,
                "ops": {op: {"n": len(samples), "p50": round(perf_stats.pct(samples, 0.5), 3),
                             "p95": round(self.p95(op), 3), "max": round(max(samples), 3)}
                        for op, samples in self.ops.items()}}


def read_spans(trace_dir: Path) -> Report:
    """Every daemon request span of a trace.py output folder (its daemon-spans-stamped.jsonl), grouped by op."""
    events, _info, _rows = trace.daemon_span_events(str(trace_dir), SPAN_PID, trace.SyntheticTracks(()))
    ops: dict[str, list[float]] = {}
    for event in events:
        # The request's own slice: a complete event with its args; its marks are children without args.
        if event.get("ph") != "X" or "args" not in event or not event["name"].startswith("daemon "):
            continue
        op = op_of(event["name"][len("daemon "):])
        if op is not None:
            ops.setdefault(op, []).append(float(event["dur"]) / 1000.0)
    if not ops:
        raise StoryError(f"{trace_dir}: no daemon op spans (was the app launched with CMUX_NEXT_TUI_DEBUG_SPANS, "
                         "and did the storm create any tab, pane or workspace?)")
    return Report({op: tuple(ops[op]) for op in sorted(ops)})


def results(report: Report, build, host, session: str, run=None) -> list:
    """result-v1 of a report: one series per op, the aggregate of every op, and the over-budget op count."""
    run = run or perf_result.Run.start()
    budget = perf_result.TargetRef(path=SELF_PATH, key=BUDGET_KEY)

    def result(name: str, unit: str, samples, target_ref):
        return perf_result.Result(story=STORY, metric=name, unit=unit, better="lower", samples=list(samples),
                                  build=build, host=host, engine="none", session=session, run=run,
                                  target_ref=target_ref)

    rows = [result(metric(op), "ms", samples, budget) for op, samples in report.ops.items()]
    rows.append(result(metric(AGGREGATE), "ms", report.all_ms, budget))
    rows.append(result(metric(AGGREGATE, "over_budget"), "count", [len(report.over_budget)], None))
    return rows


def write(report: Report, out: Path, build, host, session: str) -> Path:
    """result-v1 into OUT (validated first; nothing is written when it is invalid), and the per-op table beside it
    in OPS_FILE (not `*.ndjson`, so the ingest reads only the result)."""
    path = perf_result.write_ndjson(out, results(report, build, host, session), repo_root=ROOT)
    temporary = out / f".{OPS_FILE}.tmp"
    temporary.write_text(json.dumps(report.table(), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, out / OPS_FILE)
    return path


def trace_argv(app: Path, trace_dir: Path, session: str, seconds: float) -> list[str]:
    """trace.py's record of the session's storm. No DevTools port: a CDP trace client is load the op times would
    carry."""
    return [sys.executable, "-I", str(TRACE_PY), "record", "--app", str(app), "--out", str(trace_dir),
            "--scenario", SCENARIOS[session], "--seconds", f"{seconds:g}", "--no-cef"]


def run_trace(argv: Sequence[str]) -> int:
    """Runs trace.py and passes the runner's TERM, INT or HUP on to it, so its own stop path ends the app."""
    child = subprocess.Popen(list(argv))
    previous = {number: signal.signal(number, lambda signum, _frame: child.send_signal(signum))
                for number in FORWARDED_SIGNALS}
    try:
        return child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def measured(app: Path):
    """(result-v1 build, host) of the measured app on this Mac (bench_launch's build stamp and host block)."""
    binary = bench_launch.main_binary(str(app))
    build = perf_result.Build(sha=bench_launch.build_sha(str(app)),
                              config=bench_launch.build_config(str(app), binary, STORY_CONFIG),
                              measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)
    return build, perf_result.Host.from_dict(bench_launch.read_host())


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from-trace", type=Path, default=None,
                        help="read a recorded trace.py folder instead of recording one (prints the table)")
    parser.add_argument("--json", action="store_true", help="print the per-op table as JSON")
    parser.add_argument("--seconds", type=float, default=WINDOW_S, help="the storm's window in seconds")
    runner = parser.add_argument_group("story runner", "what scripts/perf-lab/run_story.py passes (stories.d/README.md)")
    runner.add_argument("--app", type=Path, default=None, help="the measured build")
    runner.add_argument("--tag", default=None, help="the measured build's tag (trace.py reads it from the bundle)")
    runner.add_argument("--out", type=Path, default=None, help="write result-v1 here; the trace goes into OUT/trace")
    runner.add_argument("--session", default=None, help=f"the session (default ${SESSION_ENV}, else {SESSION})")
    runner.add_argument("session_word", nargs="?", default=None, metavar="SESSION", help="the session, as a word")
    args = parser.parse_args(argv)
    sessions = {s for s in (args.session, args.session_word) if s is not None}
    if len(sessions) > 1:
        parser.error(f"two sessions: {', '.join(sorted(sessions))}")
    args.session = sessions.pop() if sessions else None
    if args.from_trace is None and (args.app is None or args.out is None):
        parser.error("recording needs --app and --out (or read a recorded trace with --from-trace)")
    return args


def main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None,
         record: Callable[[Sequence[str]], int] = run_trace, measure: Callable[[Path], tuple] = measured) -> int:
    args = parse_args(argv)
    environ = os.environ if environ is None else environ
    session = args.session or environ.get(SESSION_ENV) or SESSION
    if session not in SCENARIOS:
        print(f"daemon-ops: session {session!r}: this story runs {' or '.join(SCENARIOS)}", file=sys.stderr)
        return 2
    trace_dir = args.from_trace
    if trace_dir is None:
        trace_dir = args.out / TRACE_DIR
        code = record(trace_argv(args.app, trace_dir, session, args.seconds))
        if code != 0:  # a stage failed or a signal ended the window: its spans are not the whole storm
            print(f"daemon-ops: trace.py record exited {code}; no result (its folder: {trace_dir})", file=sys.stderr)
            return code
    try:
        report = read_spans(trace_dir)
    except StoryError as error:
        print(f"daemon-ops: {error}", file=sys.stderr)
        return 2
    if args.out is not None and args.app is not None:
        args.out.mkdir(parents=True, exist_ok=True)
        try:
            build, host = measure(args.app)
        except bench_launch.RecordError as error:
            print(f"daemon-ops: {error}", file=sys.stderr)
            return 3  # env-invalid: no build or host this result could name
        print(f"daemon-ops: wrote {write(report, args.out, build, host, session)}", file=sys.stderr)
    table = report.table()
    if args.json:
        print(json.dumps(table, sort_keys=True))
    else:
        for op, row in table["ops"].items():
            flag = "  over" if op in table["over_budget"] else ""
            print(f"{metric(op)} n={row['n']} p50={row['p50']} p95={row['p95']} max={row['max']}{flag}")
        print(f"{metric(AGGREGATE, 'over_budget')} {len(table['over_budget'])} (p95 budget {OP_P95_BUDGET_MS} ms)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
