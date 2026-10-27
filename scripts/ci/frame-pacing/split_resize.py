"""Chromium page beside a terminal while the split divider between them is dragged.

Used by golden.py (`split_resize`). The workspace is split right, the right pane opens the
local probe page of browser_resize.py in a Chromium tab (it records
`[performance.timeOrigin + rAF timestamp, innerWidth, innerHeight]` on every animation frame),
and the divider is dragged through the real mouse path (`debug.mouse` down on the divider,
one drag event per 120 Hz frame, up), which the divider view tracks as a person's drag.
`debug.motion` `trace_*` samples, once per display frame, the divider (`dividers`,
ScreenContentView+MotionSample.swift) and each Chromium host (`page`,
CEFHostView+MotionSample.swift: host size, the fork's page window size, wall ms, then the
host's and the page window's screen x and the width of the pane's page area). The judge
reports, per drag:

- `area_lag`: frames the pane's page area trails the divider;
- `edge_lag`: frames the page window's left edge trails the page area's (the page's pixels
  follow the divider only as fast as its window does);
- `layout_lag`: frames, and ms, from the page area taking a width to the page's first
  animation frame laid out at that width (p50, p95, max), and `stale_frames`, the display
  frames in which the page was laid out at a different width than its area;
- `relayouts`: the widths the page laid out at while the divider moved (each one a step the
  page catches up by), and `settle_ms`, from the divider's last move to the page laid out at
  the area's final width;
- `gap_frames`: display frames in which the page area was wider than the page window
  (the host view shows there);
- `dropped`: display frames the app missed while the divider moved (an interval over 1.5
  refresh periods), and `page_dropped`, the same for the page's own animation frames.

Report only: no threshold fails a run.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import browser_resize

DRAGS = (-160, 160, -160, 160)


def _divider(sample: dict) -> list | None:
    """The vertical split divider (taller than wide) of a `dividers` sample, or None."""
    rows = [row for row in sample.get("dividers") or [] if len(row) >= 5 and float(row[4]) > float(row[3])]
    return min(rows, key=lambda row: float(row[1])) if rows else None


def _page(sample: dict) -> list | None:
    """The rightmost Chromium host of a `page` sample (the split's new pane), or None."""
    rows = [row for row in sample.get("page") or [] if len(row) >= 5]
    if not rows:
        return None
    return max(rows, key=lambda row: float(row[5]) if len(row) >= 8 else 0.0)


def drive(driver, out: Path, strip: bool = False) -> None:
    """Splits right, opens the probe in the right pane, then traces four divider drags.

    `strip`: then one more drag, held open while `debug.window_snapshot` takes the window every
    12 moves (`strip-NN.png` in `out`): a frame strip of where the page is while the divider moves.
    Snapshots perturb timing, so that drag is not measured."""
    page = out / "split-resize-probe.html"
    page.write_text(browser_resize.PROBE_PAGE)
    split = driver.call("action.run", {"action": "splitRight", "focus": True}, timeout=30)
    time.sleep(1.0)
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
        driver.save("split_resize", {"error": "the probe page never ran in a Chromium tab", "split": split, "opened": opened})
        return
    time.sleep(1.5)

    started = driver.call("debug.motion", {"action": "trace_start", "targets": ["dividers", "page"]})
    time.sleep(0.2)
    snapshot = driver.call("debug.motion", {"action": "trace_stop"})
    rest = [sample for sample in snapshot.get("samples") or [] if _divider(sample)]
    if "error" in started or not rest:
        driver.save("split_resize", {"error": "no split divider in the window", "split": split, "opened": opened,
                                     "snapshot": snapshot})
        return
    divider = _divider(rest[-1])
    x = float(divider[1]) + float(divider[3]) / 2
    y = float(divider[2]) + float(divider[4]) / 2

    def drag(dx: float, steps: int = 60) -> dict:
        """The divider pressed once at (x, y), then one drag event per 120 Hz frame, then released."""
        nonlocal x
        period = 1 / 120
        down = driver.call("debug.mouse", {"action": "down", "x": x, "y": y})
        began = time.monotonic()
        for step in range(1, steps + 1):
            at = x + dx * step / steps
            driver.call("debug.mouse", {"action": "drag", "x": at, "y": y, "to_x": at, "to_y": y, "steps": 1,
                                        "press": False, "release": False})
            wait = began + step * period - time.monotonic()
            if wait > 0:
                time.sleep(wait)
        driver.call("debug.mouse", {"action": "up", "x": x + dx, "y": y})
        x += dx
        return {"from_x": x - dx, "dx": dx, "down": down, "wall_s": round(time.monotonic() - began, 3)}

    drags = []
    for dx in DRAGS:
        evaluate("window.__rz.length = 0, true")
        trace = driver.trace(["dividers", "page"], lambda dx=dx: drag(dx), 0.8)
        raw = evaluate("JSON.stringify(window.__rz)")
        try:
            trace["page_frames"] = json.loads(raw) if isinstance(raw, str) else []
        except ValueError:
            trace["page_frames"] = []
        drags.append(trace)
        time.sleep(0.6)
    shots = []
    if strip:
        driver.call("debug.mouse", {"action": "down", "x": x, "y": y})
        for step in range(1, 97):
            at = x - 200 * step / 96
            driver.call("debug.mouse", {"action": "drag", "x": at, "y": y, "to_x": at, "to_y": y, "steps": 1,
                                        "press": False, "release": False})
            time.sleep(1 / 120)
            if step % 12 == 0:
                path = out / f"strip-{step // 12:02d}.png"
                shots.append({"step": step, "path": path.name,
                              "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
        driver.call("debug.mouse", {"action": "up", "x": x - 200, "y": y})
        time.sleep(1.0)
        path = out / "strip-landed.png"
        shots.append({"step": "landed", "path": path.name,
                      "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
    driver.save("split_resize", {"drags": drags, "split": split, "opened": opened, "strip": shots})


def judge_drag(trace: dict, refresh: float) -> dict:
    samples = [sample for sample in trace.get("samples") or [] if _divider(sample) and _page(sample)]
    if len(samples) < 3:
        return {"error": "no per-frame samples with a divider and a Chromium host"}
    lag_frames, changes, p = browser_resize._lag_frames, browser_resize._changes, browser_resize._percentile
    rows = [_page(sample) for sample in samples]
    extended = all(len(row) >= 8 for row in rows)
    divider = [(i, float(_divider(sample)[1])) for i, sample in enumerate(samples)]
    host = [(i, float(row[0])) for i, row in enumerate(rows)]
    # The pane's page area: the host view's superview (newer samplers), else the host itself.
    area = [(i, float(row[7]) if extended else float(row[0])) for i, row in enumerate(rows)]
    page_window = [(i, float(row[2])) for i, row in enumerate(rows)]
    walls = [float(row[4]) for row in rows]
    times = [float(sample.get("t", 0)) for sample in samples]
    # The right pane's width is a constant minus the divider's x.
    total = area[0][1] + divider[0][1]
    area_lags = lag_frames([(i, total - v) for i, v in divider], area)
    edge_lags: list[int] = []
    gap_frames = 0
    if extended:
        # The page window's left edge against the host's (both screen x): the offset at rest is kept.
        host_x = [(i, float(row[5])) for i, row in enumerate(rows)]
        found = [(i, row) for i, row in enumerate(rows) if float(row[6]) >= 0]
        rest = found[0][1] if found else rows[0]
        page_x = [(i, float(row[6]) - float(rest[6]) + float(rest[5])) for i, row in found]
        edge_lags = lag_frames(host_x, page_x)
        gap_frames = sum(1 for (_, a), (_, w) in zip(area, page_window) if w >= 0 and a - w > 0.5)

    moving = [i for (i, a), (_, b) in zip(divider, divider[1:]) if abs(b - a) > 0.5]
    first, last = (moving[0], moving[-1] + 1) if moving else (0, 0)
    page = sorted((float(row[0]), float(row[1])) for row in trace.get("page_frames") or [] if len(row) >= 2)
    layout_lags, stale, relayouts, settle_ms = [], 0, 0, None
    if page:
        for index, width in changes([(float(i), v) for i, v in area])[1:]:
            wall = walls[int(index)]
            hit = next((t for t, w in page if t >= wall - refresh / 2 and abs(w - width) <= 0.5), None)
            if hit is not None:
                layout_lags.append(max(0.0, (hit - wall) / refresh))
        for (_, width), wall in zip(area, walls):
            shown = [w for t, w in page if t <= wall + refresh / 2]
            if shown and abs(shown[-1] - width) > 0.5:
                stale += 1
        if moving:
            during = [w for t, w in page if walls[first] <= t <= walls[last] + refresh]
            relayouts = len(changes([(0.0, w) for w in during])) - 1 if during else 0
            final = area[-1][1]
            settled = next((t for t, w in page if t >= walls[last] - refresh / 2 and abs(w - final) <= 0.5), None)
            settle_ms = round(max(0.0, settled - walls[last]), 1) if settled is not None else None
    intervals = [b - a for a, b in zip(times[first:last + 1], times[first + 1:last + 1])]
    dropped = sum(max(0, round(interval / refresh) - 1) for interval in intervals if interval > 1.5 * refresh)
    page_times = [t for t, _ in page if walls[first] <= t <= walls[last] + refresh] if moving else []
    page_dropped = sum(max(0, round((b - a) / refresh) - 1) for a, b in zip(page_times, page_times[1:])
                       if b - a > 1.5 * refresh)
    def spread(values: list[float], scale: float = 1.0) -> dict | None:
        """p50/p95/max of `values` times `scale`; None when nothing was measured (never a zero lag)."""
        if not values:
            return None
        return {"p50": round(p(values, 0.5) * scale, 2), "p95": round(p(values, 0.95) * scale, 2),
                "max": round(max(values) * scale, 2), "measured": len(values)}

    return {
        "frames": len(samples),
        "divider_moving_frames": len(moving),
        # Samples whose page window was not found (no width): their edge and gap are not measured.
        "unmatched_page_window": sum(1 for _, w in page_window if w < 0),
        "area_moving_frames": sum(1 for a, b in zip(area, area[1:]) if abs(b[1] - a[1]) > 0.5),
        "area_lag": spread(area_lags),
        "edge_lag": spread(edge_lags),
        "layout_lag": spread(layout_lags),
        "layout_lag_ms": spread(layout_lags, refresh),
        "stale_frames": stale,
        "relayouts": relayouts,
        "settle_ms": settle_ms,
        "gap_frames": gap_frames,
        "dropped": dropped,
        "page_dropped": page_dropped,
        "page_frames": len(page),
        # The host's widths over the drag: one value when it held its size.
        "host_widths": {"min": min(v for _, v in host), "max": max(v for _, v in host),
                        "distinct": len({round(v) for _, v in host})},
    }


def judge(data: dict, refresh: float) -> dict:
    drags = [judge_drag(trace, refresh) for trace in data.get("drags") or []]
    measured = [drag for drag in drags if "error" not in drag]
    if not measured:
        return {"ok": True, "problems": [], "measured": False,
                "note": "not measured: " + (data.get("error") or "no drag with a divider and a Chromium host")}
    settles = [drag["settle_ms"] for drag in measured if drag["settle_ms"] is not None]

    def worst(key: str, field: str):
        """The largest `field` of `key` over the drags that measured it; None when none did."""
        values = [drag[key][field] for drag in measured if drag.get(key)]
        return max(values) if values else None

    return {
        "ok": True,
        "problems": [],
        "measured": True,
        "refresh_ms": refresh,
        "drags": drags,
        "layout_lag_p50": worst("layout_lag", "p50"),
        "layout_lag_p95": worst("layout_lag", "p95"),
        "layout_lag_max": worst("layout_lag", "max"),
        "layout_lag_ms_p95": worst("layout_lag_ms", "p95"),
        "stale_frames": sum(drag["stale_frames"] for drag in measured),
        "moving_frames": sum(drag["area_moving_frames"] for drag in measured),
        "relayouts": sum(drag["relayouts"] for drag in measured),
        "settle_ms_max": max(settles, default=None),
        "area_lag_max": worst("area_lag", "max"),
        "edge_lag_max": worst("edge_lag", "max"),
        "unmatched_page_window": sum(drag["unmatched_page_window"] for drag in measured),
        "gap_frames": sum(drag["gap_frames"] for drag in measured),
        "dropped": sum(drag["dropped"] for drag in measured),
        "page_dropped": sum(drag["page_dropped"] for drag in measured),
    }


def markdown_row(verdict: dict) -> str:
    if not verdict.get("measured"):
        return f"| split_resize | report | | | | {verdict.get('note', 'not measured')} (reported only) |"
    def shown(value) -> str:
        return "n/a" if value is None else f"{value:g}"

    return ("| split_resize | ok | | | | Chromium page beside a dragged divider: page edge trails the divider "
            f"≤{shown(verdict['edge_lag_max'])} frames ({verdict['unmatched_page_window']} samples with no page window); "
            f"laid out at its area's width {shown(verdict['layout_lag_p50'])}/{shown(verdict['layout_lag_p95'])}/"
            f"{shown(verdict['layout_lag_max'])} frames after it "
            f"(p50/p95/max; p95 {shown(verdict['layout_lag_ms_p95'])} ms), stale in {verdict['stale_frames']} of "
            f"{verdict['moving_frames']} moving frames, {verdict['relayouts']} relayouts while moving, settled "
            f"≤{shown(verdict['settle_ms_max'])} ms after the last move; {verdict['dropped']} app and {verdict['page_dropped']} "
            "page frames dropped (reported only) |")
