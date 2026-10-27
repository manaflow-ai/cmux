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
- fling: the agent pane's fling at the capped and the full render rate (set live with `debug.agent_pane`
  `full_rate`), each fling's raw frames saved as bench.sh saves them, then `summarize.rows`.

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


def run_golden(socket_path: str, work: Path, session: str) -> list[Row]:
    golden.Driver(socket_path, work).run()
    verdicts = golden.judge(work)
    (work / "verdicts.json").write_text(json.dumps(verdicts, indent=1) + "\n")
    (work / "summary.md").write_text(golden.markdown(work, verdicts))
    return golden.rows(work, verdicts, session)


def run_fling(rpc: Rpc, work: Path, flings: int, wait: Callable[..., bool] = wait_until) -> list[Row]:
    """bench.sh's fling, in one launch: the render rate is set live, and each fling's raw frames are kept."""
    opened = rpc("action.run", {"action": "palette.newAgentChat"})
    if opened.get("error"):
        raise Unmeasurable(f"no agent chat opened: {json.dumps(opened)[:300]}")
    ready: dict = {}

    def answered() -> bool:
        ready.clear()
        ready.update(rpc("debug.agent_pane", {"action": "readiness"}, timeout=30))
        return not ready.get("error")

    if not wait(answered, 10):
        raise Unmeasurable(f"the agent pane never got ready: {json.dumps(ready)[:300]}")
    target = {"pane": ready["pane"]} if ready.get("pane") else {}
    rpc("debug.agent_pane", {"action": "seed_rows", "count": SEED_ROWS, **target}, timeout=FLING_TIMEOUT)
    for mode in summarize.RATES:
        rpc("debug.agent_pane", {"action": "full_rate", "enabled": mode == "1", **target})
        for n in range(flings + 1):
            fling = rpc("debug.agent_pane", {"action": "fling", "wait": True, **target}, timeout=FLING_TIMEOUT)
            if n == 0:
                continue  # fling 0 warms the transcript's layout and is not reported (bench.sh)
            perf = rpc("debug.agent_pane", {"action": "perf_stats", "raw": True, **target})
            (work / f"{mode}-{n}.json").write_text(json.dumps({"fling": fling, "perf": perf}) + "\n")
    return summarize.rows(work)


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


def make_app(opts, work: Path):
    bench_launch = load_by_path("bench_launch", ROOT / "scripts" / "cmux-next" / "bench_launch.py")
    # golden.sh's launch: the mock agent pane at the full render rate (fling sets the rate live per mode).
    env = {"CMUX_NEXT_AGENT_PANE_FULL_RATE": "1"}
    # The app log goes to the raw folder: `out` holds only result files (os.path.join keeps an absolute log_name).
    return bench_launch.BenchApp(opts.app, out=opts.out, env=env, window=WINDOW, screen="last",
                                 log_name=str(work / f"app-{opts.mode}.log"), build_config=opts.config,
                                 perf_session=opts.session)


def measure(opts, app, work: Path) -> list[Row]:
    def rpc(method: str, params: dict | None = None, timeout: float = 60) -> dict:
        reply = app.rpc(method, params, timeout=timeout)
        return reply if isinstance(reply, dict) else {"value": reply}

    if opts.mode == "golden":
        return run_golden(app.socket, work, opts.session)
    return run_fling(rpc, work, opts.flings)


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
    app = app_factory(opts, work)
    try:
        app.launch()
        rows = measure(opts, app, work)
    except Unmeasurable as error:
        print(f"frame-pacing: {story.id}: not measured: {error}", file=sys.stderr)
        return 1
    finally:
        app.stop()
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
