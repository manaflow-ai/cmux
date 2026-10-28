"""What the frame-pacing benches give the perf lab: result rows and the lab's one statistics module.

The lab stories `scripts/perf-lab/stories.d/frame_pacing.{instant,golden,fling}.json` run these benches through
`bench.sh --mode MODE --app PATH --out DIR` (lab_story.py). golden.py and summarize.py turn what they measured into
`Row`s, and lab_story.py records each row as one `cmux-perf-result/v1` result through `BenchApp.record`
(scripts/cmux-next/bench_launch.py), with the target reference the story file gives that metric.

Percentiles come from `scripts/perf-lab/perf_stats.py` (linear interpolation, the lab's one definition), loaded by
file path, so this also works under `python3 -I`. The frame-pacing workflow's sparse checkout lists
`scripts/perf-lab/`, so the judge there uses the same definition.

Stdlib only: the workflow runs this on the minis' system python3.
"""

from __future__ import annotations

import dataclasses
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PERF_STATS = ROOT / "scripts" / "perf-lab" / "perf_stats.py"
# A missed frame is a display-link interval longer than this many refresh periods: the app's own rule for its bench
# windows (BenchFrames `missed`, the `dropped` of instant-new-surfaces-bench.py), so a Cmd-T row of a frame-pacing
# story counts missed frames as the new-surfaces stories do.
MISSED_FRAME_PERIODS = 1.5


def _load_perf_stats():
    if "perf_stats" in sys.modules:
        return sys.modules["perf_stats"]
    spec = importlib.util.spec_from_file_location("perf_stats", PERF_STATS)
    module = importlib.util.module_from_spec(spec)
    sys.modules["perf_stats"] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules["perf_stats"]
        raise
    return module


perf_stats = _load_perf_stats()


@dataclasses.dataclass(frozen=True)
class Row:
    """One result-v1 result of a run: `samples` are the raw values, never a summary of them. The story file names
    the metric's unit, direction and target reference; lab_story.py refuses a row that disagrees with it."""

    metric: str
    unit: str
    better: str
    samples: tuple

    def __post_init__(self) -> None:
        if not self.samples:
            raise ValueError(f"{self.metric}: a row has at least one sample")


def missed_frames(intervals: list, refresh_ms: float) -> int:
    """How many of `intervals` (ms between display frames) missed their frame at `refresh_ms`."""
    if refresh_ms <= 0:
        return 0
    return sum(1 for interval in intervals if interval > MISSED_FRAME_PERIODS * refresh_ms)
