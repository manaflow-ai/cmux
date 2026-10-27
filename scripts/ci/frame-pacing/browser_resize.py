"""Chromium page during a live window resize: how many display frames each stage trails.

Used by golden.py (`browser_resize`). A Chromium tab shows a local probe page that records
`[performance.timeOrigin + rAF timestamp, innerWidth, innerHeight]` on every animation frame.
The window is live-resized by its bottom-right corner (`debug.mouse`, one drag event per
120 Hz frame) while `debug.motion` `trace_*` samples, once per display frame, the window
size and each Chromium host (`page`: host size, the fork's page window size, wall ms;
CEFHostView+MotionSample.swift). The judge lines the two clocks up and reports, per drag:

- `host_lag`: frames the host view (the pane's page area) trails the window's size;
- `window_lag`: frames the page window (the fork's child NSWindow) trails the host;
- `layout_lag`: frames from the host taking a width to the page's first animation frame
  laid out at that width (p50, p95, max), and `stale_frames`, the display frames in which
  the page was laid out at a different width than its host.

A last drag runs under `debug.window_record` for before/after frames (it perturbs timing,
so it is not measured). Report only: no threshold fails a run. Percentiles come from the perf
lab's perf_stats (lab_rows.py), and `rows` gives the lab story `frame_pacing.golden` every lag
it measured as raw samples.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from lab_rows import Row, perf_stats

PROBE_PAGE = """<!doctype html><meta charset="utf-8"><title>Resize probe</title>
<style>
html,body{margin:0;min-height:100%;background:#0b5d3b;color:#fff;font:600 18px -apple-system,sans-serif}
header{display:flex;justify-content:space-between;align-items:center;height:64px;padding:0 20px;background:#08402a}
button{font:inherit;padding:8px 16px;border-radius:18px;border:0;background:#fff;color:#08402a}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;padding:20px}
.grid div{height:96px;border-radius:12px;background:#15895a}
</style>
<header><span>Resize probe</span><button>Add to cmux</button></header>
<div class="grid">""" + "<div></div>" * 30 + """</div>
<script>
window.__rz = [];
requestAnimationFrame(function frame(t) {
  if (__rz.length < 20000) __rz.push([performance.timeOrigin + t, innerWidth, innerHeight]);
  requestAnimationFrame(frame);
});
</script>
"""


def drive(driver, out: Path) -> None:
    """Opens the probe in a Chromium tab, then traces two drags out and back, then records one."""
    page = out / "browser-resize-probe.html"
    page.write_text(PROBE_PAGE)
    # The action takes its URL under `args` (a top-level `url` is ignored and opens the New Tab page).
    opened = driver.call("action.run", {"action": "openBrowser.chromium", "args": {"url": page.as_uri()}, "focus": True},
                         timeout=90)

    def evaluate(script: str):
        result = driver.call("browser.page.eval", {"script": script}, timeout=20)
        return result.get("value") if "error" not in result else None

    deadline = time.monotonic() + 60
    ready = False
    while time.monotonic() < deadline:
        if evaluate("document.readyState === 'complete' && Array.isArray(window.__rz) && window.__rz.length > 2") is True:
            ready = True
            break
        time.sleep(0.5)
    if not ready:
        state = driver.call("browser.page.state", {}, timeout=20)
        driver.save("browser_resize", {"error": "the probe page never ran in a Chromium tab", "opened": opened, "state": state})
        return
    time.sleep(1.5)

    drags = []
    for dx, dy in ((300, 150), (-300, -150), (300, 150), (-300, -150)):
        evaluate("window.__rz.length = 0, true")
        trace = driver.trace(["window", "page"], lambda dx=dx, dy=dy: driver.drag_corner(dx, dy), 0.5)
        raw = evaluate("JSON.stringify(window.__rz)")
        try:
            trace["page_frames"] = json.loads(raw) if isinstance(raw, str) else []
        except ValueError:
            trace["page_frames"] = []
        drags.append(trace)
        time.sleep(0.6)
    frames_dir = out / "browser-resize-frames"
    record = driver.call("debug.window_record", {"dir": str(frames_dir), "seconds": 2.0})
    time.sleep(0.1)
    recorded = driver.drag_corner(300, 150)
    time.sleep(2.2)
    driver.drag_corner(-300, -150)
    driver.save("browser_resize", {"drags": drags, "opened": opened, "record": record, "recorded_drag": recorded})


def _changes(series: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """(time, value) at each change of value, the first sample included."""
    out: list[tuple[float, float]] = []
    for time_, value in series:
        if not out or abs(value - out[-1][1]) > 0.5:
            out.append((time_, value))
    return out


def _lag_frames(leader: list[tuple[int, float]], follower: list[tuple[int, float]]) -> list[int]:
    """Per change of `leader` (frame index, value): frames until `follower` shows that value."""
    lags = []
    for index, value in _changes([(float(i), v) for i, v in leader])[1:]:
        hit = next((i for i, v in follower if i >= index and abs(v - value) <= 0.5), None)
        if hit is not None:
            lags.append(int(hit - index))
    return lags


def judge_drag(trace: dict, refresh: float) -> dict:
    samples = [sample for sample in trace.get("samples") or [] if sample.get("window") and sample.get("page")]
    if len(samples) < 3:
        return {"error": "no per-frame samples with a Chromium host"}
    window = [(i, float(sample["window"][0])) for i, sample in enumerate(samples)]
    host = [(i, float(sample["page"][0][0])) for i, sample in enumerate(samples)]
    page_window = [(i, float(sample["page"][0][2])) for i, sample in enumerate(samples)]
    walls = [float(sample["page"][0][4]) for sample in samples]
    # The host is narrower than the window by a constant (sidebar, padding): compare changes.
    offset = window[0][1] - host[0][1]
    host_lags = _lag_frames(window, [(i, v + offset) for i, v in host])
    window_lags = _lag_frames(host, page_window)

    page = sorted((float(row[0]), float(row[1])) for row in trace.get("page_frames") or [] if len(row) >= 2)
    layout_lags, stale = [], 0
    if page:
        for index, width in _changes([(float(i), v) for i, v in host])[1:]:
            wall = walls[int(index)]
            hit = next((t for t, w in page if t >= wall - refresh / 2 and abs(w - width) <= 0.5), None)
            if hit is not None:
                layout_lags.append(max(0.0, (hit - wall) / refresh))
        for (_, width), wall in zip(host, walls):
            shown = [w for t, w in page if t <= wall + refresh / 2]
            if shown and abs(shown[-1] - width) > 0.5:
                stale += 1
    moving = sum(1 for a, b in zip(host, host[1:]) if abs(b[1] - a[1]) > 0.5)
    # perf_stats.pct is None for no values: a drag with no lag measured reports 0 frames.
    return {
        "frames": len(samples),
        "host_moving_frames": moving,
        "host_lag": {"p50": perf_stats.pct(host_lags, 0.5) or 0.0, "max": max(host_lags, default=0)},
        "window_lag": {"p50": perf_stats.pct(window_lags, 0.5) or 0.0, "max": max(window_lags, default=0)},
        "layout_lag": {"p50": round(perf_stats.pct(layout_lags, 0.5) or 0.0, 2),
                       "p95": round(perf_stats.pct(layout_lags, 0.95) or 0.0, 2),
                       "max": round(max(layout_lags, default=0.0), 2), "measured": len(layout_lags)},
        "stale_frames": stale,
        "page_frames": len(page),
        # The raw lags, for result-v1 (`rows`).
        "host_lags": host_lags,
        "window_lags": window_lags,
        "layout_lags": [round(lag, 3) for lag in layout_lags],
    }


def judge(data: dict, refresh: float) -> dict:
    drags = [judge_drag(trace, refresh) for trace in data.get("drags") or []]
    measured = [drag for drag in drags if "error" not in drag]
    if not measured:
        # Report only: a run without the numbers says so, and never fails the judge.
        return {"ok": True, "problems": [], "measured": False,
                "note": "not measured: " + (data.get("error") or "no drag with a Chromium host")}
    lags = [drag["layout_lag"] for drag in measured]
    return {
        "ok": True,
        "problems": [],
        "measured": True,
        "drags": drags,
        "layout_lag_p50": max(lag["p50"] for lag in lags),
        "layout_lag_p95": max(lag["p95"] for lag in lags),
        "layout_lag_max": max(lag["max"] for lag in lags),
        "stale_frames": sum(drag["stale_frames"] for drag in measured),
        "moving_frames": sum(drag["host_moving_frames"] for drag in measured),
        "host_lag_max": max(drag["host_lag"]["max"] for drag in measured),
        "window_lag_max": max(drag["window_lag"]["max"] for drag in measured),
    }


def markdown_row(verdict: dict) -> str:
    if not verdict.get("measured"):
        return f"| browser_resize | report | | | | {verdict.get('note', 'not measured')} (reported only) |"
    return ("| browser_resize | ok | | | | Chromium page laid out at its host's width "
            f"{verdict['layout_lag_p50']:g}/{verdict['layout_lag_p95']:g}/{verdict['layout_lag_max']:g} frames after it "
            f"(p50/p95/max), stale in {verdict['stale_frames']} of {verdict['moving_frames']} moving frames; "
            f"host trails window ≤{verdict['host_lag_max']} and page window trails host ≤{verdict['window_lag_max']} frames "
            "(reported only) |")


def rows(verdict: dict, base: str = "golden.browser_resize") -> list[Row]:
    """result-v1 rows of a measured verdict: every frame lag of every measured drag (host behind the window, page
    window behind the host, page layout behind the host, in display frames), and the stale frames of each drag."""
    measured = [drag for drag in verdict.get("drags") or [] if "error" not in drag]
    found = []
    for key, metric in (("host_lags", "host_lag_frames"), ("window_lags", "window_lag_frames"),
                        ("layout_lags", "layout_lag_frames")):
        samples = tuple(lag for drag in measured for lag in drag.get(key) or [])
        if samples:
            found.append(Row(f"{base}.{metric}", "unitless" if key == "layout_lags" else "count", "lower", samples))
    if measured:
        found.append(Row(f"{base}.stale_frames", "count", "lower", tuple(drag["stale_frames"] for drag in measured)))
    return found
