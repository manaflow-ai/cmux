"""The stages of a cmux NEXT launch (startup-tti), from its launch marks.

Each stage is the time from the app's process start (sysctl p_starttime, the launch marks' clock) to the earliest
of its marks that came. The app writes the same stages into each row of launch-times.jsonl (LaunchStages in
Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/LaunchTimesFile.swift) and
scripts/measure/launch-ready.swift prints them; tests/test_launch_stages.py keeps the three tables equal.

Leo, 2026-11-21: "you can build instrumentation if you havent already to properly measure each part of startup
times."
"""

from __future__ import annotations

import math
import statistics

# (stage, its marks), in launch order.
TABLE: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("dyld", ("premain.first_initializer",)),
    ("premain", ("main_start",)),
    ("main_setup", ("main.setup_done",)),
    ("did_finish_launching", ("did_finish_launching_start",)),
    ("daemon_connected", ("daemon_connected",)),
    ("first_window_shown", ("launch_snapshot_shown", "first_window_flushed", "dfl.windows")),
    ("first_frame", ("first_window_frame_committed",)),
    ("webview_ready", ("cef.ready",)),
    ("first_page_navigation", ("first_page.navigation_start",)),
    ("first_page_dom_content_loaded", ("first_page.dom_content_loaded",)),
    ("first_page_contentful_paint", ("first_page.first_contentful_paint",)),
    ("first_chat_paint", ("agent_pane.painted", "agent_pane.newtab_painted", "home.saved_page_shown", "home.first_page")),
    ("first_interaction", ("terminal_echo", "agent_pane.input_echoed", "window_usable")),
)
STAGES = tuple(stage for stage, _ in TABLE)
MARKS = tuple(mark for _, marks in TABLE for mark in marks)


def spans(marks: dict) -> dict:
    """Stage name to ms from process start (rounded to 0.1), for each stage one of whose marks is in `marks`."""
    out = {}
    for stage, names in TABLE:
        got = [float(marks[n]) for n in names if isinstance(marks.get(n), (int, float))]
        got = [v for v in got if math.isfinite(v) and v >= 0]
        if got:
            out[stage] = round(min(got), 1)
    return out


def medians(rows: list) -> dict:
    """Each stage's median over `rows` (dicts of `spans`), for the stages any row reached."""
    out = {}
    for stage in STAGES:
        got = [r[stage] for r in rows if isinstance(r, dict) and isinstance(r.get(stage), (int, float))]
        if got:
            out[stage] = round(statistics.median(got), 1)
    return out
