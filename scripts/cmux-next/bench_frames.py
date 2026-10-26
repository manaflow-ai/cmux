"""The raw `debug.frames` stop reply of the benches (bench_tab_switch.py, bench_cli_storm.py, script-storm-bench.py).

`debug.frames` stopped with `raw: true` adds the measured window's per-frame arrays to its summary. The first two
are recorded as cmux-perf-result/v1 samples; none goes into a report, which keeps the app's summary statistics.
Chrome's benchmarks do the same: the trace's raw events become histogram samples
(third_party/catapult/tracing/tracing/value/histogram.py), the summary is computed from them, not stored beside them.
"""
from typing_report import is_sample

# These and every `*_per_frame` key are the per-frame arrays of a raw reply.
RAW_FRAME_KEYS = ("intervals_ms", "main_ms")


def split_raw_frames(frames):
    """(summary, {intervals_ms, main_ms}) of a `debug.frames` stop reply asked with `raw: true`. A reply that is not
    a dict (an error, or a profile with no frame probe) is its own summary and has no samples."""
    if not isinstance(frames, dict):
        return frames, {key: [] for key in RAW_FRAME_KEYS}
    raw = {key: [v for v in frames.get(key) or [] if is_sample(v)] for key in RAW_FRAME_KEYS}
    summary = {k: v for k, v in frames.items() if k not in RAW_FRAME_KEYS and not k.endswith("_per_frame")}
    return summary, raw
