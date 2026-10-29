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
  refresh periods), and `page_dropped`, the same for the page's own animation frames;
- `frame_ms` and `page_frame_ms`: p50/p95/p99/max of the app's display-frame intervals and of
  the page's animation-frame intervals while the divider moved;
- `cpu`: with the app's pid, CPU ms the app's main thread, the whole app and its Chromium
  helpers (renderer, GPU, other) spent over the drag, and the main thread's ms per drag step.

`drag_hz` is how many pointer events a drag sends per second (120 by default; a gaming mouse
or a high-rate trackpad sends 500 or more, several per display frame).

`page="heavy"` opens HEAVY_PAGE instead of the probe: the same recorder over a long page of
wrapping text, a table and a grid, so each width costs Chromium a real relayout (a long
docs page or a pull request diff), not the probe's 30 boxes.

Report only: no threshold fails a run.
"""

from __future__ import annotations

import json
import re
import subprocess
import time
from pathlib import Path

import browser_resize

DRAGS = (-160, 160, -160, 160)
STEPS = 60

_WORDS = ("resize divider chromium layout frame pane width wraps across the column while the page "
          "catches up with its host view and paints again at every new size").split()


def _heavy_page() -> str:
    """The probe's recorder over about 120k words of wrapping text, a 400-row table and a 600-cell grid."""
    paragraphs = "".join(
        "<p>" + " ".join(_WORDS[(i * 7 + j) % len(_WORDS)] for j in range(30 + i % 40)) + "</p>" for i in range(2400))
    rows = "".join(f"<tr><td>{i}</td><td>{' '.join(_WORDS[(i + j) % len(_WORDS)] for j in range(12))}</td>"
                   f"<td>{' '.join(_WORDS[(i * 3 + j) % len(_WORDS)] for j in range(18))}</td></tr>" for i in range(400))
    head, tail = browser_resize.PROBE_PAGE.split('<div class="grid">', 1)
    head = head.replace("</style>", "p{margin:6px 20px;font:400 14px/1.45 -apple-system,sans-serif}"
                        "table{margin:12px 20px;border-collapse:collapse;font:400 13px -apple-system,sans-serif}"
                        "td{border:1px solid #2a7;padding:3px 6px}</style>")
    tail = tail.replace("<div></div>" * 30, "<div></div>" * 600, 1)
    return head + '<div class="grid">' + tail.replace("</div>\n<script>", "</div>" + paragraphs + "<table>" + rows
                                                       + "</table>\n<script>", 1)


HEAVY_PAGE = _heavy_page()


def _cpu_seconds(text: str) -> float:
    """`ps` TIME ([[dd-]hh:]mm:ss.ss) in seconds."""
    days, _, clock = text.strip().rpartition("-")
    total = 0.0
    for part in clock.split(":"):
        total = total * 60 + float(part)
    return total + (float(days) * 86400 if days else 0.0)


def cpu_snapshot(pid: int | None) -> dict | None:
    """Cumulative CPU seconds of the app's main thread (the first thread `ps -M` lists), the whole app, and its
    Chromium helpers (child processes) by kind; None without a pid or when ps fails."""
    if not pid:
        return None
    try:
        threads = subprocess.run(["/bin/ps", "-M", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout
        procs = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,time=,comm="], capture_output=True, text=True,
                               timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    lines = [line for line in threads.splitlines()[1:] if line.strip()]
    times = re.findall(r"\s(\d+:\d+\.\d+)\s+(\d+:\d+\.\d+)", lines[0]) if lines else []
    if not times:
        return None
    snap = {"main": _cpu_seconds(times[0][0]) + _cpu_seconds(times[0][1]), "app": 0.0, "renderer": 0.0, "gpu": 0.0,
            "helper_other": 0.0}
    renderers: dict[int, float] = {}
    for line in procs.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        child, parent, used, comm = parts
        if int(child) == pid:
            snap["app"] = _cpu_seconds(used)
        elif int(parent) == pid:
            kind = "renderer" if "Renderer" in comm else "gpu" if "GPU" in comm else "helper_other"
            snap[kind] += _cpu_seconds(used)
            if kind == "renderer":
                renderers[int(child)] = _cpu_seconds(used)
    snap["_renderers"] = renderers
    return snap


def _cpu_delta(before: dict | None, after: dict | None, steps: int) -> dict | None:
    if not before or not after:
        return None
    delta = {key: round((after[key] - before[key]) * 1000, 1) for key in before if not key.startswith("_")}
    delta["main_ms_per_step"] = round(delta["main"] / steps, 2)
    grew = {pid: used - before["_renderers"].get(pid, 0.0) for pid, used in after["_renderers"].items()}
    delta["busiest_renderer"] = max(grew, key=grew.get) if grew else None
    return delta


def _sample(pid: int, seconds: int, path: Path) -> subprocess.Popen | None:
    """`/usr/bin/sample PID SECONDS 1 -file PATH` in the background (1 ms interval), returned once it has attached
    and started sampling (its "Sampling process" line: on a loaded Mac attaching takes seconds, and drags made
    before it would not be in the profile); None when it cannot start or never attaches within 30 s."""
    try:
        sampler = subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "1", "-file", str(path)],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True)
    except OSError:
        return None
    deadline = time.monotonic() + 30
    assert sampler.stdout is not None
    while time.monotonic() < deadline:
        line = sampler.stdout.readline()
        if not line:
            break
        if line.startswith("Sampling process"):
            return sampler
    sampler.kill()
    sampler.wait()
    return None


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


def drive(driver, out: Path, strip: bool = False, page_kind: str = "probe", pid: int | None = None,
          record: bool = False, drag_hz: float = 120, profile: bool = False) -> None:
    """Splits right, opens the probe (or HEAVY_PAGE) in the right pane, then traces four divider drags.

    `strip`: then one more drag, held open while `debug.window_snapshot` takes the window every
    12 moves (`strip-NN.png` in `out`): a frame strip of where the page is while the divider moves.
    `record`: then one more drag out and back under `debug.window_record` (JPEG frames per display
    frame in `out/record`). `profile` (with `pid`): then four more drags while `sample` profiles the app
    and the renderer that spent the most during the measured drags (`out/sample-app.txt`,
    `out/sample-renderer.txt`). Snapshots, the recording and profiling perturb timing, so those drags are
    not measured."""
    page = out / "split-resize-probe.html"
    page.write_text(HEAVY_PAGE if page_kind == "heavy" else browser_resize.PROBE_PAGE)
    # A fresh home opens on the agent chat dock, which never splits: start from a workspace with a terminal.
    workspace = driver.call("action.run", {"action": "newTab", "focus": True}, timeout=30)
    time.sleep(1.5)
    split = driver.call("action.run", {"action": "splitRight", "focus": True}, timeout=30)
    split = {**split, "workspace": workspace}
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

    def drag(dx: float, steps: int = STEPS) -> dict:
        """The divider pressed once at (x, y), then one drag event every 1/drag_hz s, then released."""
        nonlocal x
        steps = max(steps, round(steps * drag_hz / 120))
        period = 1 / drag_hz
        before = cpu_snapshot(pid)
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
        wall = time.monotonic() - began
        x += dx
        return {"from_x": x - dx, "dx": dx, "down": down, "wall_s": round(wall, 3),
                "cpu": _cpu_delta(before, cpu_snapshot(pid), steps)}

    drags = []
    for dx in DRAGS:
        evaluate("window.__rz.length = 0, true")
        trace = driver.trace(["dividers", "page"], lambda dx=dx: drag(dx), 0.8)
        raw = evaluate("JSON.stringify(window.__rz)")
        try:
            trace["page_frames"] = json.loads(raw) if isinstance(raw, str) else []
        except ValueError:
            trace["page_frames"] = []
        trace["cpu"] = (trace.get("acted") or {}).get("cpu")
        drags.append(trace)
        time.sleep(0.6)
    profiled = None
    if profile and pid:
        renderer = next((d["cpu"].get("busiest_renderer") for d in reversed(drags) if d.get("cpu")), None)
        samplers = {"app": _sample(pid, 6, out / "sample-app.txt")}
        if renderer:
            samplers["renderer"] = _sample(renderer, 6, out / "sample-renderer.txt")
        began = time.monotonic()
        profiled = {"renderer_pid": renderer, "attached": {name: bool(sampler) for name, sampler in samplers.items()},
                    "drags": [drag(dx) for dx in (-160, 160, -160, 160)]}
        profiled["drag_s"] = round(time.monotonic() - began, 2)
        for sampler in samplers.values():
            if sampler:
                try:
                    sampler.communicate(timeout=60)
                except subprocess.TimeoutExpired:
                    sampler.kill()
                    sampler.communicate()
        time.sleep(0.6)
    recorded = None
    if record:
        frames_dir = out / "record"
        recorded = {"record": driver.call("debug.window_record", {"dir": str(frames_dir), "seconds": 2.4})}
        time.sleep(0.1)
        recorded["out"] = drag(-160)
        recorded["back"] = drag(160)
        time.sleep(1.4)
    shots = []
    if strip:
        driver.call("debug.mouse", {"action": "down", "x": x, "y": y})
        for step in range(1, 97):
            at = x - 200 * step / 96
            driver.call("debug.mouse", {"action": "drag", "x": at, "y": y, "to_x": at, "to_y": y, "steps": 1,
                                        "press": False, "release": False})
            time.sleep(1 / 120)
            if step % STRIP_EVERY == 0:
                path = out / f"strip-{step // STRIP_EVERY:02d}.png"
                shots.append({"step": step, "path": path.name,
                              "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
        driver.call("debug.mouse", {"action": "up", "x": x - 200, "y": y})
        time.sleep(1.0)
        path = out / "strip-landed.png"
        shots.append({"step": "landed", "path": path.name,
                      "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
    driver.save("split_resize", {"drags": drags, "split": split, "opened": opened, "strip": shots, "page": page_kind,
                                 "recorded": recorded, "drag_hz": drag_hz,
                                 "profiled": profiled})


# The recording drag: a window snapshot every this many of its 96 moves (16 frames, then one after it landed).
STRIP_EVERY = 6


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
        # Only the frames the divider moved in, the same frames `moving_frames` counts.
        for index in moving:
            width, wall = area[index + 1][1], walls[index + 1]
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
    # The longest the app went without a display frame while the divider moved (a held commit shows here).
    worst_stall_ms = round(max(intervals), 1) if intervals else None
    page_times = [t for t, _ in page if walls[first] <= t <= walls[last] + refresh] if moving else []
    page_dropped = sum(max(0, round((b - a) / refresh) - 1) for a, b in zip(page_times, page_times[1:])
                       if b - a > 1.5 * refresh)
    page_intervals = [b - a for a, b in zip(page_times, page_times[1:])]
    def spread(values: list[float], scale: float = 1.0) -> dict | None:
        """p50/p95/max of `values` times `scale`; None when nothing was measured (never a zero lag)."""
        if not values:
            return None
        return {"p50": round(p(values, 0.5) * scale, 2), "p95": round(p(values, 0.95) * scale, 2),
                "max": round(max(values) * scale, 2), "measured": len(values)}

    def frame_spread(values: list[float]) -> dict | None:
        """p50/p95/p99/max of frame intervals in ms; None when nothing was measured."""
        if not values:
            return None
        return {"p50": round(p(values, 0.5), 2), "p95": round(p(values, 0.95), 2), "p99": round(p(values, 0.99), 2),
                "max": round(max(values), 2), "measured": len(values)}

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
        "worst_stall_ms": worst_stall_ms,
        "page_dropped": page_dropped,
        "frame_ms": frame_spread(intervals),
        "page_frame_ms": frame_spread(page_intervals),
        "cpu": trace.get("cpu"),
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

    def worst(key: str, field: str | None):
        """The largest `field` of `key` (or `key` itself, field None) over the drags that measured it; None when none did."""
        values = [drag[key] if field is None else drag[key][field] for drag in measured if drag.get(key) is not None]
        return max(values) if values else None

    def pooled(key: str) -> dict | None:
        """The worst p50/p95/p99/max of a `frame_spread` field over the drags."""
        rows = [drag[key] for drag in measured if drag.get(key)]
        return {f: max(row[f] for row in rows) for f in ("p50", "p95", "p99", "max")} if rows else None

    cpus = [drag["cpu"] for drag in measured if drag.get("cpu")]
    cpu = ({key: round(sum(c[key] for c in cpus) / len(cpus), 2) for key in cpus[0] if key != "busiest_renderer"}
           if cpus else None)
    return {
        "ok": True,
        "problems": [],
        "measured": True,
        "refresh_ms": refresh,
        "frame_ms": pooled("frame_ms"),
        "page_frame_ms": pooled("page_frame_ms"),
        "cpu_per_drag": cpu,
        "drags": drags,
        "layout_lag_p50": worst("layout_lag", "p50"),
        "layout_lag_p95": worst("layout_lag", "p95"),
        "layout_lag_max": worst("layout_lag", "max"),
        "layout_lag_ms_p95": worst("layout_lag_ms", "p95"),
        "stale_frames": sum(drag["stale_frames"] for drag in measured),
        "moving_frames": sum(drag["divider_moving_frames"] for drag in measured),  # the frames stale_frames reads
        "relayouts": sum(drag["relayouts"] for drag in measured),
        "settle_ms_max": max(settles, default=None),
        "area_lag_max": worst("area_lag", "max"),
        "edge_lag_max": worst("edge_lag", "max"),
        "unmatched_page_window": sum(drag["unmatched_page_window"] for drag in measured),
        "gap_frames": sum(drag["gap_frames"] for drag in measured),
        "dropped": sum(drag["dropped"] for drag in measured),
        "worst_stall_ms": worst("worst_stall_ms", None),
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
            f"page frames dropped, worst app frame {shown(verdict.get('worst_stall_ms'))} ms (reported only) |")
