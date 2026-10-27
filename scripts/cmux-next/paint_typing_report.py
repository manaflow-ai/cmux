"""The numbers and result-v1 series of the typing e2e, Cmd-N paint and zoom close checks (p12-perf-process-065).

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_paint_typing_report.py checks the
statistics and the names the lab stories match on any host. Percentiles come only from scripts/perf-lab/perf_stats.py
(linear interpolation, the one definition the lab judges with), as Chrome's benchmarks hand raw samples to one histogram
implementation (third_party/catapult/tracing/tracing/value/histogram.py).

| Check | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| cmd-n-paint-e2e.py | cmd-n-paint | `cmd_n_paint[.split<N>][.cold].cmd_<key>.{bad_frames,not_adopted}` (count) | webkit (the New Tab page) |
| new-workspace-real-typing-e2e.py | new-workspace-typing | `new_workspace_typing.<run kind>.{lost_keys,failed_runs}` (count) | webkit (the New Tab field) |
| home-typing-still.py | home-typing-still | `home_typing_still.resize_pace.width_pass` (ms), `.deferred`, `home_typing_still.failed_checks` (count) | none (native classic Home) |
| zoom-close-check.py | none | its report's `frame_gap_ms` (p50, p95, p99, max) | |

A check writes result-v1 only under an explicit --story whose engine is the run's (bench_story.story_problem) and only
for an app it launched through BenchApp: an attached app's launch env is unknown. zoom-close-check.py reads a
recording that zoom-close-record.py made from an attached app, so it writes none.
"""
import collections
import difflib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from split_pane_bench_report import Series, any_written, record_all  # noqa: E402,F401  (the checks' writer)
from typing_report import distribution, is_sample  # noqa: E402  (distribution: perf_stats.pct)

CMD_N_PAINT_STORY = "cmd-n-paint"
NEW_WORKSPACE_TYPING_STORY = "new-workspace-typing"
HOME_TYPING_STILL_STORY = "home-typing-still"
ENGINES = {CMD_N_PAINT_STORY: "webkit", NEW_WORKSPACE_TYPING_STORY: "webkit", HOME_TYPING_STILL_STORY: "none"}


# ---------------------------------------------------------------- zoom-close-check.py

def frame_gaps(times):
    """zoom-close-check's `frame_gap_ms` of the trace sample times (ms): the gaps between samples as
    {samples, p50, p95, p99, max, over_12_5, over_25}; None with fewer than two samples. `samples` is the number of
    trace samples (as before), the percentiles are of the gaps."""
    gaps = [b - a for a, b in zip(times, times[1:])]
    spread = distribution(gaps, mean=False)
    if spread is None:
        return None
    return {"samples": len(times), "p50": spread["p50"], "p95": spread["p95"], "p99": spread["p99"],
            "max": spread["max"], "over_12_5": sum(1 for g in gaps if g > 12.5), "over_25": sum(1 for g in gaps if g > 25)}


# ---------------------------------------------------------------- cmd-n-paint-e2e.py

def bad_frames(frames, cold):
    """The frames of one `debug.new_tab` frame strip that fail the check: a blank content area always, and a frame
    between the one before the key and the settled one (outside or in the content area) unless the opening is the
    cold one, where the sidebar may lead the content by a frame right after launch."""
    return [f for f in frames if f.get("blank") or ((f.get("intermediate") or f.get("content_intermediate")) and not cold)]


def paint_prefix(key, split=1, cold=False):
    """The series prefix of one kind of opening: `cmd_n_paint.cmd_n`, `cmd_n_paint.split3.cmd_n`,
    `cmd_n_paint.cold.cmd_n`. A split workspace's opening and the first Cmd-N after launch are their own series."""
    return "cmd_n_paint" + (f".split{split}" if split > 1 else "") + (".cold" if cold else "") + f".cmd_{key}"


def cmd_n_paint_series(openings):
    """cmd-n-paint-e2e.py openings -> series. Each opening is {key, split, cold, bad, spare}: `bad` the number of bad
    frames of its strip, `spare` whether it adopted the prewarmed page. Per kind of opening: `.bad_frames`, one sample
    per opening, and `.not_adopted`, how many warm openings adopted no spare (a cold one has none ready)."""
    groups = collections.OrderedDict()
    for opening in openings:
        groups.setdefault(paint_prefix(opening["key"], opening.get("split", 1), opening.get("cold", False)), []).append(opening)
    out = []
    for prefix, sel in groups.items():
        out.append(Series(f"{prefix}.bad_frames", "count", [float(o["bad"]) for o in sel]))
        warm = [o for o in sel if not o.get("cold")]
        if warm:
            out.append(Series(f"{prefix}.not_adopted", "count", [float(sum(1 for o in warm if not o.get("spare")))]))
    return out


# ---------------------------------------------------------------- new-workspace-real-typing-e2e.py

def lost_keys(expected, got):
    """How many characters of `expected` the field does not hold, in order (`hello world 123` read as
    `lo world 123` lost 3); every one when the field could not be read."""
    if not isinstance(got, str):
        return len(expected)
    matcher = difflib.SequenceMatcher(None, expected, got, autojunk=False)
    return len(expected) - sum(block.size for block in matcher.get_matching_blocks())


def landed_field(row):
    """The field text of the new page the run's keys went to, or None when they went to no new page: a run() row
    whose focused tab did not change (the old page, maybe the last run's, may hold the text already), or a new-pane
    run whose pane count did not grow. A run_window() row reads only a new window's field already."""
    if "tab_before" in row and row.get("tab_after") in (None, row["tab_before"]):
        return None
    panes = row.get("panes")
    if row.get("new_pane") and not (isinstance(panes, list) and len(panes) == 2 and panes[1] > panes[0]):
        return None
    return row.get("field")


def run_kind(name):
    """`cold-cmdn-3` -> `cold_cmdn`: the run's flow, its series key."""
    return name.rsplit("-", 1)[0].replace("-", "_")


def typing_series(rows, expected):
    """new-workspace-real-typing-e2e.py rows -> series per run kind: `.lost_keys`, one sample per run whose keys were
    sent (a failed setup sends none; every key is lost when the keys reached no new page, landed_field), and
    `.failed_runs`, the runs that did not pass (setup failures included)."""
    groups = collections.OrderedDict()
    for row in rows:
        groups.setdefault(run_kind(row["run"]), []).append(row)
    out = []
    for kind, sel in groups.items():
        lost = [float(lost_keys(expected, landed_field(r))) for r in sel if "field" in r]
        if lost:
            out.append(Series(f"new_workspace_typing.{kind}.lost_keys", "count", lost))
        out.append(Series(f"new_workspace_typing.{kind}.failed_runs", "count", [float(sum(1 for r in sel if not r.get("pass")))]))
    return out


# ---------------------------------------------------------------- home-typing-still.py

def home_typing_series(steps, failures):
    """home-typing-still.py: the main-thread ms of each width change's layout pass in the resize-pace step (`ms` of
    each `debug.home.drive resize` step), how many of them the 2 ms frame budget deferred, and the failed checks."""
    out = []
    passes = [float(s["ms"]) for s in steps if is_sample(s.get("ms"))]
    if passes:
        out.append(Series("home_typing_still.resize_pace.width_pass", "ms", passes))
    if len(steps) >= 2 and is_sample(steps[-1].get("deferred")) and is_sample(steps[0].get("deferred")):
        out.append(Series("home_typing_still.resize_pace.deferred", "count",
                          [float(steps[-1]["deferred"] - steps[0]["deferred"])]))
    out.append(Series("home_typing_still.failed_checks", "count", [float(len(failures))]))
    return out
