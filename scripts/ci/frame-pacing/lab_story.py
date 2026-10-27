#!/usr/bin/env python3
"""The frame-pacing benches as perf-lab stories (plans/cmux-next/chrome-parity/p12-perf-process.md, section 3.3).

    bench.sh --mode instant|golden|fling --app PATH --tag TAG --out DIR [--session light] [--flings 3]

scripts/perf-lab/run_story.py runs this through bench.sh for the stories `frame_pacing.instant`,
`frame_pacing.golden` and `frame_pacing.fling` (scripts/perf-lab/stories.d), and appends `--app --tag --out`. It
never builds: PATH is the prebuilt bench app the runner fetched by digest, and the runner owns the 120 Hz virtual
display, so this starts no display of its own (the workflow's `bench.sh WORK_DIR` still does both). Chrome's
Telemetry splits the same way: a benchmark drives the browser that `--browser-executable` names and never builds it
(`tools/perf/core/benchmark_runner.py`).

- instant: the workflow's instant create bench, instant-new-surfaces-bench.py (Cmd-N, Cmd-T, Ctrl-`, Cmd-D and
  Cmd-Shift-D through the real key path, idle and with every core busy, each Cmd-T closed again by a measured
  Cmd-W), with story `frame_pacing.instant`. That bench launches the app and writes its own result-v1 files.
- golden: golden.py's drive and judge, then `golden.rows`;
- fling: the agent pane's fling at the capped and the full render rate, one launch per rate with
  `CMUX_NEXT_AGENT_PANE_FULL_RATE` pinning it (as bench.sh does), each fling's raw frames saved as bench.sh saves
  them, then `summarize.rows`. A pinned rate is not adaptive, so the page's policy cannot change it between or
  during flings; each fling is bracketed by a `full_rate` read, and a rate that is not the one asked for (an
  engine without the WebKit rate, a build without the pin) leaves that rate unmeasured.

golden and fling start the app through `BenchApp` (scripts/cmux-next/bench_launch.py: bench env, window frame,
teardown) and write each row as one `cmux-perf-result/v1` file in DIR through `BenchApp.record`, with the unit,
direction and target reference the story file gives that metric. A row the story does not list is refused, so the
story file stays the one list of what the bench writes. Their raw files (traces, verdicts, the summary, the app log)
go to DIR/raw. Exit 0 with at least one result; 1 when nothing was measured or a row disagrees with the story; 2 on
usage. A launch that fails exits with BenchApp's LaunchError reason.

Stdlib only.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))  # golden.py, summarize.py and lab_rows.py, also under `python3 -I`

import golden  # noqa: E402
import summarize  # noqa: E402
from lab_rows import Row  # noqa: E402

STORIES_DIR = ROOT / "scripts" / "perf-lab" / "stories.d"
INSTANT_BENCH = ROOT / "scripts" / "cmux-next" / "instant-new-surfaces-bench.py"
MODES = ("instant", "golden", "fling")
# golden.sh's window: golden.py's live-resize drag and its thresholds assume this frame.
WINDOW = (80, 80, 1100, 720)
# The workflow's instant create bench runs each command this many times, idle and loaded.
INSTANT_RUNS = 10
SEED_ROWS = 5000  # bench.sh's transcript for the fling
FLING_TIMEOUT = 90  # seconds: a waited 3 s fling, as bench.sh allows it
READY_SECONDS = 30  # a cold agent page: loaded and its composer shown

Rpc = Callable[..., dict]


class StoryMismatch(Exception):
    """A row the story file does not list, or lists with another unit or direction."""


class Unmeasurable(Exception):
    """The run cannot measure (no agent chat to fling); nothing is recorded."""


def load_by_path(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def story_id(mode: str) -> str:
    return f"frame_pacing.{mode}"


class StoryMetrics:
    """The story file's metrics: each row must fully match one, with its unit and direction."""

    def __init__(self, path: Path):
        doc = json.loads(path.read_text(encoding="utf-8"))
        self.id = doc["id"]
        self.metrics = [(re.compile(m["name"]), m) for m in doc["metrics"]]

    def spec(self, row: Row) -> dict:
        found = next((m for pattern, m in self.metrics if pattern.fullmatch(row.metric)), None)
        if found is None:
            raise StoryMismatch(f"{self.id} lists no metric {row.metric}")
        if (found["unit"], found["better"]) != (row.unit, row.better):
            raise StoryMismatch(f"{self.id}: {row.metric} is {row.unit}/{row.better}, the story says "
                                f"{found['unit']}/{found['better']}")
        return found


def wait_until(check: Callable[[], bool], seconds: float, step: float = 0.5,
               clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep) -> bool:
    """True once `check()` holds, False after `seconds`: a bounded poll of the live app's state."""
    deadline = clock() + seconds
    while True:
        if check():
            return True
        if clock() >= deadline:
            return False
        sleep(step)


# ---------------------------------------------------------------- instant


def instant_argv(opts) -> list[str]:
    """instant-new-surfaces-bench.py as the workflow's instant create step runs it (every command, idle and loaded,
    report only: no budget flags), with the lab's story, session and folders."""
    argv = [sys.executable, str(INSTANT_BENCH), "--tag", opts.tag, "--app", opts.app, "--out", opts.out,
            "--story", story_id("instant"), "--session", opts.session, "--runs", str(opts.runs),
            "--json", str(Path(opts.out) / "raw" / "instant-new-surfaces.json")]
    if opts.config:
        argv += ["--build-config", opts.config]
    return argv


# ---------------------------------------------------------------- golden and fling


def run_golden(socket_path: str, work: Path) -> list[Row]:
    golden.Driver(socket_path, work).run()
    verdicts = golden.judge(work)
    (work / "verdicts.json").write_text(json.dumps(verdicts, indent=1) + "\n")
    (work / "summary.md").write_text(golden.markdown(work, verdicts))
    return golden.rows(work, verdicts)


def pane_ready(reply: dict) -> bool:
    """The page has loaded and shows its composer (readiness answers before either, with no debug bridge yet)."""
    return not reply.get("error") and reply.get("document_ready") is True and reply.get("composer_visible") is True


def run_fling(rpc: Rpc, work: Path, mode: str, flings: int, wait: Callable[..., bool] = wait_until) -> None:
    """bench.sh's fling at one render rate (`mode`, a summarize.RATES key) in an app launched pinned to it: seeds the
    transcript, then saves each measured fling's raw frames as `<mode>-<n>.json`. The files are written only once
    every fling ran at the pinned rate, so an unmeasurable rate leaves none."""
    opened = rpc("action.run", {"action": "palette.newAgentChat"})
    if opened.get("error"):
        raise Unmeasurable(f"no agent chat opened: {json.dumps(opened)[:300]}")
    ready: dict = {}

    def answered() -> bool:
        ready.clear()
        ready.update(rpc("debug.agent_pane", {"action": "readiness"}, timeout=30))
        return pane_ready(ready)

    if not wait(answered, READY_SECONDS):
        raise Unmeasurable(f"the agent pane never got ready: {json.dumps(ready)[:300]}")
    target = {"pane": ready["pane"]} if ready.get("pane") else {}
    seeded = rpc("debug.agent_pane", {"action": "seed_rows", "count": SEED_ROWS, **target}, timeout=FLING_TIMEOUT)
    if seeded.get("error") or not isinstance(seeded.get("rows"), int) or seeded["rows"] < SEED_ROWS:
        raise Unmeasurable(f"the transcript was not seeded with {SEED_ROWS} rows: {json.dumps(seeded)[:300]}")
    want = mode == "1"

    def check_rate(when: str) -> None:
        reply = rpc("debug.agent_pane", {"action": "full_rate", **target})
        if reply.get("full_rate") is not want:
            raise Unmeasurable(f"the {summarize.RATES[mode]} rate was asked for; {when} the pane reported "
                               f"{json.dumps(reply)[:300]}")

    measured: list[tuple[int, dict]] = []
    for n in range(flings + 1):
        check_rate(f"before fling {n}")
        fling = rpc("debug.agent_pane", {"action": "fling", "wait": True, **target}, timeout=FLING_TIMEOUT)
        if n == 0:
            continue  # fling 0 warms the transcript's layout and is not reported (bench.sh)
        perf = rpc("debug.agent_pane", {"action": "perf_stats", "raw": True, **target})
        measured.append((n, {"fling": fling, "perf": perf}))
    check_rate("after the last fling")
    for n, reply in measured:
        (work / f"{mode}-{n}.json").write_text(json.dumps(reply) + "\n")


# ---------------------------------------------------------------- main


def parse_args(argv):
    p = argparse.ArgumentParser(description="Run one frame-pacing lab story against a prebuilt bench app.")
    p.add_argument("--mode", required=True, choices=MODES)
    p.add_argument("--app", required=True, help="the prebuilt `cmux DEV <tag>.app` (never built here)")
    p.add_argument("--tag", required=True, help="the app's tag (run_story.py appends it)")
    p.add_argument("--out", required=True, help="the folder for result-v1 files (run_story.py's run folder)")
    p.add_argument("--config", default=os.environ.get("PERF_LAB_CONFIG") or None,
                   help="the build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    p.add_argument("--session", default=os.environ.get("PERF_LAB_SESSION") or "light", choices=("light", "stress"))
    p.add_argument("--runs", type=int, default=INSTANT_RUNS, help="instant: runs of each command per phase")
    p.add_argument("--flings", type=int, default=3, help="fling: measured flings per render rate")
    opts = p.parse_args(argv)
    if opts.runs < 1 or opts.flings < 1:
        p.error("--runs and --flings are >= 1")
    return opts


def make_app(opts, work: Path, rate: str):
    """A BenchApp whose agent pane is pinned to `rate` (`1` full, `0` capped); golden.sh's launch is full rate."""
    bench_launch = load_by_path("bench_launch", ROOT / "scripts" / "cmux-next" / "bench_launch.py")
    env = {"CMUX_NEXT_AGENT_PANE_FULL_RATE": rate}
    log = f"app-{opts.mode}.log" if opts.mode == "golden" else f"app-{opts.mode}-{summarize.RATES[rate]}.log"
    # The app log goes to the raw folder: `out` holds only result files (os.path.join keeps an absolute log_name).
    return bench_launch.BenchApp(opts.app, out=opts.out, env=env, window=WINDOW, screen="last",
                                 log_name=str(work / log), build_config=opts.config, perf_session=opts.session)


def app_rpc(app) -> Rpc:
    def rpc(method: str, params: dict | None = None, timeout: float = 60) -> dict:
        reply = app.rpc(method, params, timeout=timeout)
        return reply if isinstance(reply, dict) else {"value": reply}

    return rpc


def launched(app_factory, opts, work: Path, rate: str, run: Callable):
    """Launches an app pinned to `rate`, runs `run(app)` and stops the app however `run` ends: (app, result)."""
    app = app_factory(opts, work, rate)
    try:
        app.launch()
        return app, run(app)
    finally:
        app.stop()


def measure(opts, app_factory, work: Path):
    """(an app to record with, the mode's rows); the app is None when no fling rate was measured."""
    if opts.mode == "golden":
        return launched(app_factory, opts, work, "1", lambda app: run_golden(app.socket, work))
    last = None
    for mode, rate in summarize.RATES.items():
        try:
            last, _ = launched(app_factory, opts, work, mode,
                               lambda app: run_fling(app_rpc(app), work, mode, opts.flings))
        except Unmeasurable as error:
            print(f"frame-pacing: {story_id('fling')}: the {rate} rate was not measured: {error}", file=sys.stderr)
    return last, (summarize.rows(work) if last is not None else [])


def record(app, story: StoryMetrics, rows: list[Row]) -> list[str]:
    """Writes each row as result-v1 (BenchApp.record) with the story's target reference; the written paths."""
    perf_result = load_by_path("perf_result", ROOT / "scripts" / "perf-lab" / "perf_result.py")
    specs = [story.spec(row) for row in rows]  # every row checked before any file is written
    written = []
    for row, spec in zip(rows, specs):
        ref = spec.get("target_ref")
        target = None if ref is None else perf_result.TargetRef.from_dict(ref)
        written.append(str(app.record(story.id, row.metric, row.unit, list(row.samples), better=row.better,
                                      engine="none", target_ref=target)))
    return written


def main(argv=None, app_factory=make_app, execv=os.execv) -> int:
    opts = parse_args(argv)
    story = StoryMetrics(STORIES_DIR / f"{story_id(opts.mode)}.json")
    expected = os.environ.get("PERF_LAB_STORY")
    if expected and expected != story.id:
        print(f"frame-pacing: the runner asked for story {expected}, --mode {opts.mode} is {story.id}", file=sys.stderr)
        return 2
    work = Path(opts.out).resolve() / "raw"
    work.mkdir(parents=True, exist_ok=True)
    if opts.mode == "instant":
        argv = instant_argv(opts)
        execv(argv[0], argv)
        return 0  # an injected execv returns
    app, rows = measure(opts, app_factory, work)
    if not rows:
        print(f"frame-pacing: {story.id}: nothing was measured (raw files in {work})", file=sys.stderr)
        return 1
    try:
        written = record(app, story, rows)
    except StoryMismatch as error:
        print(f"frame-pacing: {error}", file=sys.stderr)
        return 1
    print(f"frame-pacing: {story.id}: {len(written)} result files in {opts.out} (raw files in {work})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
