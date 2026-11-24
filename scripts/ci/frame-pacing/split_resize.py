"""A page beside a terminal while its pane is resized: the split divider dragged, the sidebar
toggled, or the window's corner dragged.

Used by golden.py (`split_resize`, the browser pane and the divider) and
scripts/cmux-next/split-resize-bench.py (`--pane`, `--gesture`). The page is one of:

- `browser`: the workspace is split right and the right pane opens the local probe page of
  browser_resize.py in a Chromium tab; it records `[performance.timeOrigin + rAF timestamp,
  innerWidth, innerHeight]` on every animation frame (`window.__rz`, read with `browser.page.eval`);
- `chat`: the workspace is split right and the right pane opens an agent chat; the same recorder
  runs in the chat page through `debug.agent_pane` `resize_probe` (`start` resets it, `read`
  returns its frames and the app's clock), as `browser.page.eval` does not reach a chat.

The gestures (`GESTURES`), each traced four times:

- `divider`: the divider beside the page dragged through the real mouse path (`debug.mouse` down
  on the divider, one drag event per 120 Hz frame, up), which the divider view tracks as a
  person's drag;
- `sidebar`: `toggleSidebar` (hide, show, hide, show): the panes move and resize together;
- `window-edge`: the window's bottom-right corner dragged in and out by 200 x 100 points, one
  drag event per 120 Hz frame, as scripts/cmux-next/resize-frames-live.py does (AppKit's live
  resize).

`debug.motion` `trace_*` samples, once per display frame, the dividers and panes
(ScreenContentView+MotionSample.swift), the window size, and each Chromium host (`page`,
CEFHostView+MotionSample.swift: host size, the fork's page window size, wall ms, the host's and
the page window's screen x, the width of the pane's page area, then whether the page is
detached from the window and the hosted root's size and screen x, which show the page's pixels
while it is detached and no page window is over the pane). The judge reports, per gesture:

- `area_lag`: frames the pane's page area trails what moved it (the divider, the window's width);
- `edge_lag`: frames the page's left edge (its window's, else the hosted root's) trails the page
  area's (the page's pixels follow the pane only as fast as they do);
- `layout_lag`: frames, and ms, from the page area taking a width to the page's first
  animation frame laid out at that width (p50, p95, max), and `stale_frames`, the display
  frames in which the page was laid out at a different width than its area;
- `relayouts`: the widths the page laid out at while the pane moved (each one a step the
  page catches up by), and `settle_ms`, from the pane's last move to the page laid out at
  the area's final width;
- `gap_frames`: display frames in which the page area was wider than the page's pixels
  (the host view shows there);
- `dropped`: display frames the app missed while the pane moved (an interval over 1.5
  refresh periods), and `page_dropped`, the same for the page's own animation frames.

A chat's page area is its pane's content width (`panes`), offset by the chat page's width at
rest, and its wall clock the trace's `t0_s` on the app's clock (`resize_probe`'s `clock`).

Report only: no threshold fails a run.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import browser_resize

DRAGS = (-160, 160, -160, 160)
PANES = ("browser", "chat")
GESTURES = ("divider", "sidebar", "window-edge")
# The window corner's moves (points, window-local): in, out, in, out.
EDGE_DRAGS = ((-200, -100), (200, 100), (-200, -100), (200, 100))
# `controls`: each pane's top-right toolbar (TabStripDebug.controlsSample), for the lockstep count.
TARGETS = ["dividers", "panes", "page", "window", "controls"]


def _vertical(sample: dict) -> list:
    """The vertical split dividers (taller than wide) of a `dividers` sample."""
    return [row for row in sample.get("dividers") or [] if len(row) >= 5 and float(row[4]) > float(row[3])]


def _pane_row(sample: dict, pane: str | None) -> list | None:
    """The `panes` row of `pane` (the rightmost pane when it is None or not found), or None."""
    rows = [row for row in sample.get("panes") or [] if len(row) >= 12]
    if not rows:
        return None
    if pane:
        found = next((row for row in rows if str(row[0]) == pane), None)
        if found is not None:
            return found
    return max(rows, key=lambda row: float(row[1]))


def _divider(sample: dict, pane: str | None = None) -> list | None:
    """The divider the gestures drag: beside `pane` (its nearer edge), else the leftmost vertical one; or None."""
    rows = _vertical(sample)
    if not rows:
        return None
    row = _pane_row(sample, pane) if pane else None
    if row is None:
        return min(rows, key=lambda divider: float(divider[1]))
    left, right = float(row[1]), float(row[1]) + float(row[3])

    def distance(divider: list) -> float:
        middle = float(divider[1]) + float(divider[3]) / 2
        return min(abs(middle - left), abs(middle - right))
    return min(rows, key=distance)


def _page(sample: dict) -> list | None:
    """The rightmost Chromium host of a `page` sample (the split's new pane), or None."""
    rows = [row for row in sample.get("page") or [] if len(row) >= 5]
    if not rows:
        return None
    return max(rows, key=lambda row: float(row[5]) if len(row) >= 8 else 0.0)


def _pixels(row: list) -> tuple[float, float, str | None]:
    """(width, screen x, source) of where a `page` row's page shows its pixels: its page window, else (a detached
    or hosted page with no page window over the pane) the hosted root at the host's left edge; -1s when neither."""
    if float(row[2]) >= 0:
        return float(row[2]), float(row[6]) if len(row) >= 8 else -1.0, "window"
    if len(row) >= 12 and float(row[9]) >= 0:
        return float(row[9]), float(row[11]), "hosted"
    return -1.0, -1.0, None


def _pane_count(driver) -> int:
    """Panes in the snapshot's topology (every workspace's screens)."""
    topology = driver.read("snapshot.get", {}).get("topology") or {}
    return sum(len(screen.get("panes") or []) for workspace in topology.get("workspaces") or []
               for screen in workspace.get("screens") or [])


def drive(driver, out: Path, strip: bool = False, pane: str = "browser",
          gestures: tuple[str, ...] | list[str] = ("divider",)) -> None:
    """Splits right, opens the page (`pane`) in the right pane, then traces each of `gestures` four times.

    `strip`: then one more divider drag, held open while `debug.window_snapshot` takes the window every
    12 moves (`strip-NN.png` in `out`): a frame strip of where the page is while the divider moves.
    Snapshots perturb timing, so that drag is not measured."""
    if pane not in PANES:
        driver.save("split_resize", {"error": f"unknown pane {pane!r}"})
        return
    unknown = [gesture for gesture in gestures if gesture not in GESTURES]
    if unknown:
        driver.save("split_resize", {"error": f"unknown gestures {unknown}"})
        return
    panes_before = _pane_count(driver)
    split = driver.call("action.run", {"action": "splitRight", "focus": True}, timeout=30)
    driver.until(lambda: _pane_count(driver) > panes_before, "splitRight showing a new pane")
    driver.settle("the window after the split")
    chat_pane: str | None = None
    if pane == "browser":
        page = out / "split-resize-probe.html"
        page.write_text(browser_resize.PROBE_PAGE)
        opened = driver.call("action.run", {"action": "openBrowser.chromium", "args": {"url": page.as_uri()},
                                            "focus": True}, timeout=90)

        def evaluate(script: str):
            result = driver.call("browser.page.eval", {"script": script}, timeout=20)
            return result.get("value") if "error" not in result else None

        def reset() -> None:
            evaluate("window.__rz.length = 0, true")

        def read() -> tuple[list, dict | None]:
            raw = evaluate("JSON.stringify(window.__rz)")
            try:
                return (json.loads(raw) if isinstance(raw, str) else []), None
            except ValueError:
                return [], None

        def recording() -> bool:
            return evaluate("document.readyState === 'complete' && Array.isArray(window.__rz) && window.__rz.length > 2") is True
    else:
        # The chat opens in the split's new pane (the rightmost), not in a chat dock.
        driver.call("debug.motion", {"action": "trace_start", "targets": ["panes"]})
        time.sleep(0.2)  # sleep-ok: the trace window, a few frames sampled (trace_stop is its only read)
        snapshot = driver.call("debug.motion", {"action": "trace_stop"})
        rows = [sample for sample in snapshot.get("samples") or [] if sample.get("panes")]
        right = _pane_row(rows[-1], None) if rows else None
        opened = {"error": "no pane"}
        if right is not None:
            opened = driver.call("action.run", {"action": "palette.newAgentChat", "target": f"pane:{right[0]}", "focus": True})
        if "error" in opened:
            opened = driver.call("action.run", {"action": "palette.newAgentChat", "focus": True})
        ready: dict = {}
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            ready = driver.call("debug.agent_pane", {"action": "readiness"}, timeout=30)
            if "error" not in ready and ready.get("pane"):
                break
            time.sleep(0.5)
        chat_pane = ready.get("pane") if "error" not in ready else None
        target = {"pane": chat_pane} if chat_pane else {}

        def probe(step: str) -> dict:
            return driver.call("debug.agent_pane", {"action": "resize_probe", "step": step, **target}, timeout=20)

        def reset() -> None:
            probe("start")

        def read() -> tuple[list, dict | None]:
            result = probe("read")
            frames = result.get("frames")
            return (frames if isinstance(frames, list) else []), result.get("clock")

        def recording() -> bool:
            probe("start")
            # Until the probe holds a few frames; the caller retries a probe that has not started.
            until = time.monotonic() + 2.0
            while len(read()[0]) <= 2:
                if time.monotonic() >= until:
                    return False
                time.sleep(0.05)
            return True

    deadline = time.monotonic() + 60
    ready_page = False
    while time.monotonic() < deadline:
        if recording():
            ready_page = True
            break
        time.sleep(0.5)
    if not ready_page:
        driver.save("split_resize", {"error": f"the probe never ran in the {pane} pane", "pane": pane, "split": split,
                                     "opened": opened})
        return
    driver.settle(f"the window with the {pane} probe")

    def at_rest() -> dict | None:
        """One sample of the window at rest: the dividers, the panes and the window size."""
        if "error" in driver.call("debug.motion", {"action": "trace_start", "targets": TARGETS}):
            return None
        time.sleep(0.2)  # sleep-ok: the trace window, a few frames sampled at rest (trace_stop is its only read)
        snapshot = driver.call("debug.motion", {"action": "trace_stop"})
        rest = [sample for sample in snapshot.get("samples") or [] if sample.get("window")]
        return rest[-1] if rest else None

    rest = at_rest()
    if rest is None or (("divider" in gestures or strip) and not _divider(rest, chat_pane)):
        driver.save("split_resize", {"error": "no split divider in the window", "pane": pane, "split": split,
                                     "opened": opened, "rest": rest})
        return
    period = 1 / 120

    def drag_path(x0: float, y0: float, dx: float, dy: float, steps: int = 60) -> dict:
        """Pressed once at (x0, y0), then one drag event per 120 Hz frame to (x0 + dx, y0 + dy), then released."""
        down = driver.call("debug.mouse", {"action": "down", "x": x0, "y": y0})
        began = time.monotonic()
        for step in range(1, steps + 1):
            x, y = x0 + dx * step / steps, y0 + dy * step / steps
            driver.call("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                        "press": False, "release": False})
            wait = began + step * period - time.monotonic()
            if wait > 0:
                time.sleep(wait)
        driver.call("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
        return {"from": [x0, y0], "dx": dx, "dy": dy, "down": down, "wall_s": round(time.monotonic() - began, 3)}

    def divider_point() -> tuple[float, float] | None:
        sample = at_rest()
        divider = _divider(sample, chat_pane) if sample else None
        if divider is None:
            return None
        return float(divider[1]) + float(divider[3]) / 2, float(divider[2]) + float(divider[4]) / 2

    def acts(gesture: str) -> list:
        if gesture == "divider":
            point = divider_point()
            if point is None:
                return []
            x, y = point
            moves = []
            for dx in DRAGS:
                moves.append(lambda x=x, dx=dx: drag_path(x, y, dx, 0))
                x += dx
            return moves
        if gesture == "sidebar":
            return [lambda: driver.call("action.run", {"action": "toggleSidebar"}) for _ in range(4)]
        sample = at_rest()
        if not sample:
            return []
        w, h = float(sample["window"][0]), float(sample["window"][1])
        moves = []
        for dx, dy in EDGE_DRAGS:
            moves.append(lambda w=w, h=h, dx=dx, dy=dy: drag_path(w - 1, h - 1, dx, dy))
            w, h = w + dx, h + dy
        return moves

    drags = []
    for gesture in gestures:
        for act in acts(gesture):
            reset()
            trace = driver.trace(TARGETS, act, 0.8 if gesture != "sidebar" else 1.2)
            trace["page_frames"], clock = read()
            trace.update({"gesture": gesture, "pane": pane, "chat_pane": chat_pane, "clock": clock})
            drags.append(trace)
            time.sleep(0.6)
    shots = []
    point = divider_point() if strip else None
    if point is not None:
        x, y = point
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
        driver.settle("the window after the recording drag landed")
        path = out / "strip-landed.png"
        shots.append({"step": "landed", "path": path.name,
                      "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
    driver.save("split_resize", {"drags": drags, "pane": pane, "gestures": list(gestures), "split": split,
                                 "opened": opened, "chat_pane": chat_pane, "strip": shots})


# The recording drag: a window snapshot every this many of its 96 moves (16 frames, then one after it landed).
STRIP_EVERY = 6


def _controls_lag(samples: list[dict]) -> set[int]:
    """Frames where a pane's top-right buttons are off their rest place against the pane's trailing edge (>1 pt).

    Rows are `[minX, maxX, top, paneMaxX, buttonsMaxX]`, matched by order; a frame whose row count changed is skipped."""
    rest = samples[0].get("controls") or [] if samples else []
    lagging: set[int] = set()
    for i, sample in enumerate(samples):
        rows = sample.get("controls") or []
        if len(rows) != len(rest):
            continue
        for row, base in zip(rows, rest):
            if len(row) < 5 or len(base) < 5:
                continue
            if abs((row[3] - row[1]) - (base[3] - base[1])) > 1:
                lagging.add(i)
            if row[4] >= 0 and base[4] >= 0 and abs((row[3] - row[4]) - (base[3] - base[4])) > 1:
                lagging.add(i)
    return lagging


def judge_drag(trace: dict, refresh: float) -> dict:
    gesture = trace.get("gesture") or "divider"
    chat = trace.get("pane") == "chat"
    chat_pane = trace.get("chat_pane")
    if chat:
        samples = [sample for sample in trace.get("samples") or [] if _pane_row(sample, chat_pane)]
    else:
        samples = [sample for sample in trace.get("samples") or [] if _page(sample)]
    if gesture == "divider":
        samples = [sample for sample in samples if _divider(sample, chat_pane if chat else None)]
    if len(samples) < 3:
        return {"error": "no per-frame samples with a divider and a chat pane" if chat
                else "no per-frame samples with a divider and a Chromium host"}
    lag_frames, changes, p = browser_resize._lag_frames, browser_resize._changes, browser_resize._percentile
    times = [float(sample.get("t", 0)) for sample in samples]
    page = sorted((float(row[0]), float(row[1])) for row in trace.get("page_frames") or [] if len(row) >= 2)
    # The page's pixels: a Chromium host's row (a chat in CEF has one too: the only one then).
    rows = [_page(sample) for sample in samples]
    if chat and not all(row is not None and len(sample.get("page") or []) == 1 for row, sample in zip(rows, samples)):
        rows = []
    extended = bool(rows) and all(len(row) >= 8 for row in rows)
    if chat:
        # The chat page's width is its pane's content width at a constant offset (borders), read at rest.
        clock = trace.get("clock") or {}
        try:
            # The trace's host clock (`t0_s`, CACurrentMediaTime seconds) on the epoch the page's frames use.
            shift = float(clock["epoch_ms"]) - float(clock["host_s"]) * 1000
            walls = [float(trace["t0_s"]) * 1000 + t + shift for t in times]
        except (KeyError, TypeError, ValueError):
            return {"error": "no clock to line up the chat page's frames with the trace"}
        content = [float(_pane_row(sample, chat_pane)[11]) for sample in samples]
        # The page's width at rest: its last frame up to the first sample (else its first frame).
        before = [w for t, w in page if t <= walls[0]] or [w for _, w in page[:1]]
        offset = (before[-1] - content[0]) if before else 0.0
        area = [(i, v + offset) for i, v in enumerate(content)]
    else:
        # The pane's page area: the host view's superview (newer samplers), else the host itself.
        area = [(i, float(row[7]) if extended else float(row[0])) for i, row in enumerate(rows)]
        walls = [float(row[4]) for row in rows]
    pixels = [_pixels(row) for row in rows] if rows else []
    page_window = [(i, width) for i, (width, _, _) in enumerate(pixels)]

    divider_rows = [_divider(sample, chat_pane if chat else None) for sample in samples]
    divider = [(i, float(row[1])) for i, row in enumerate(divider_rows) if row is not None]
    window = [(i, float((sample.get("window") or [0])[0])) for i, sample in enumerate(samples)]
    # What moved the pane, and the area it should have taken from it.
    area_lags: list[int] = []
    expected: dict[int, float] = {}
    if gesture == "divider" and divider:
        pane_row = _pane_row(samples[0], chat_pane) if chat else None
        page_right = float(pane_row[1]) >= divider[0][1] if pane_row is not None else True
        if page_right:
            total = area[0][1] + divider[0][1]
            area_lags = lag_frames([(i, total - v) for i, v in divider], area)
            expected = {i: total - v for i, v in divider}
        else:
            offset = divider[0][1] - area[0][1]
            area_lags = lag_frames([(i, v - offset) for i, v in divider], area)
            expected = {i: v - offset for i, v in divider}
        driver_series = divider
    elif gesture == "window-edge":
        total = area[0][1] - window[0][1]
        area_lags = lag_frames([(i, v + total) for i, v in window], area)
        expected = {i: v + total for i, v in window}
        driver_series = window
    else:
        driver_series = area
    edge_lags: list[int] = []
    gap_frames = 0
    if extended:
        # The page's left edge against the host's (both screen x): a page window's offset at rest is kept; the
        # hosted root sits on the host's left edge.
        host_x = [(i, float(row[5])) for i, row in enumerate(rows)]
        windowed = [(i, row) for i, row in enumerate(rows) if pixels[i][2] == "window" and pixels[i][1] >= 0]
        rest = windowed[0][1] if windowed else None
        page_x = []
        for i, row in enumerate(rows):
            width, x, source = pixels[i]
            if source == "window" and x >= 0 and rest is not None:
                page_x.append((i, x - float(rest[6]) + float(rest[5])))
            elif source == "hosted" and x >= 0:
                page_x.append((i, x))
        edge_lags = lag_frames(host_x, page_x)
        gap_frames = sum(1 for (_, a), (_, w) in zip(area, page_window) if w >= 0 and a - w > 0.5)

    moving = [i for (i, a), (_, b) in zip(driver_series, driver_series[1:]) if abs(b - a) > 0.5]
    first, last = (moving[0], moving[-1] + 1) if moving else (0, 0)
    layout_lags, stale, relayouts, settle_ms = [], 0, 0, None
    stale_at: set[int] = set()
    if page:
        for index, width in changes([(float(i), v) for i, v in area])[1:]:
            wall = walls[int(index)]
            hit = next((t for t, w in page if t >= wall - refresh / 2 and abs(w - width) <= 0.5), None)
            if hit is not None:
                layout_lags.append(max(0.0, (hit - wall) / refresh))
        # Only the frames the pane moved in, the same frames `moving_frames` counts.
        for index in moving:
            width, wall = area[min(index + 1, len(area) - 1)][1], walls[min(index + 1, len(walls) - 1)]
            shown = [w for t, w in page if t <= wall + refresh / 2]
            if shown and abs(shown[-1] - width) > 0.5:
                stale += 1
                stale_at.add(index)
        if moving:
            during = [w for t, w in page if walls[first] <= t <= walls[min(last, len(walls) - 1)] + refresh]
            relayouts = len(changes([(0.0, w) for w in during])) - 1 if during else 0
            final = area[-1][1]
            end = walls[min(last, len(walls) - 1)]
            settled = next((t for t, w in page if t >= end - refresh / 2 and abs(w - final) <= 0.5), None)
            settle_ms = round(max(0.0, settled - end), 1) if settled is not None else None
    intervals = [b - a for a, b in zip(times[first:last + 1], times[first + 1:last + 1])]
    dropped = sum(max(0, round(interval / refresh) - 1) for interval in intervals if interval > 1.5 * refresh)
    # The longest the app went without a display frame while the pane moved (a held commit shows here).
    worst_stall_ms = round(max(intervals), 1) if intervals else None
    page_times = [t for t, _ in page if walls[first] <= t <= walls[min(last, len(walls) - 1)] + refresh] if moving else []
    page_dropped = sum(max(0, round((b - a) / refresh) - 1) for a, b in zip(page_times, page_times[1:])
                       if b - a > 1.5 * refresh)

    # Lockstep: frames, while the pane moved, where its page area or its top-right buttons were not where the
    # divider (or window) put them that frame. Leo wants 0 at any CPU load.
    moving_set = set(range(first, last + 1)) if moving else set()
    off_area = {i for i, a in area if i in expected and abs(expected[i] - a) > 1}
    off_controls = _controls_lag(samples)
    # A page whose pixels show another width than its area that frame (`stale_frames`) is out of lockstep too.
    lockstep = sorted((off_area | off_controls | stale_at) & moving_set)

    def spread(values: list[float], scale: float = 1.0) -> dict | None:
        """p50/p95/max of `values` times `scale`; None when nothing was measured (never a zero lag)."""
        if not values:
            return None
        return {"p50": round(p(values, 0.5) * scale, 2), "p95": round(p(values, 0.95) * scale, 2),
                "max": round(max(values) * scale, 2), "measured": len(values)}

    host = [(i, float(row[0])) for i, row in enumerate(rows)]
    return {
        "gesture": gesture,
        "pane": trace.get("pane") or "browser",
        "frames": len(samples),
        "divider_moving_frames": sum(1 for (_, a), (_, b) in zip(divider, divider[1:]) if abs(b - a) > 0.5),
        # The frames what moved the pane (the divider, the window's width, else the area) moved in.
        "moving_frames": len(moving),
        # Samples with no page window and no hosted root (no width): their edge and gap are not measured.
        "unmatched_page_window": sum(1 for _, w in page_window if w < 0),
        # Samples whose page was detached from the window, and those whose pixels were read from the hosted root.
        "detached_frames": sum(1 for row in rows if len(row) >= 12 and float(row[8]) > 0),
        "hosted_matched": sum(1 for _, _, source in pixels if source == "hosted"),
        "area_moving_frames": sum(1 for a, b in zip(area, area[1:]) if abs(b[1] - a[1]) > 0.5),
        "area_lag": spread(area_lags),
        "lockstep_lag_frames": len(lockstep),
        "controls_lag_frames": len(off_controls & moving_set),
        "controls_measured": bool(samples[0].get("controls")),
        "frame_ms": spread(intervals),
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
        "page_frames": len(page),
        # The host's widths over the drag: one value when it held its size (no Chromium host: None).
        "host_widths": {"min": min(v for _, v in host), "max": max(v for _, v in host),
                        "distinct": len({round(v) for _, v in host})} if host else None,
    }


def _summary(measured: list[dict]) -> dict:
    settles = [drag["settle_ms"] for drag in measured if drag["settle_ms"] is not None]

    def worst(key: str, field: str | None):
        """The largest `field` of `key` (or `key` itself, field None) over the drags that measured it; None when none did."""
        values = [drag[key] if field is None else drag[key][field] for drag in measured if drag.get(key) is not None]
        return max(values) if values else None

    return {
        "layout_lag_p50": worst("layout_lag", "p50"),
        "layout_lag_p95": worst("layout_lag", "p95"),
        "layout_lag_max": worst("layout_lag", "max"),
        "layout_lag_ms_p95": worst("layout_lag_ms", "p95"),
        "stale_frames": sum(drag["stale_frames"] for drag in measured),
        "moving_frames": sum(drag["moving_frames"] for drag in measured),  # the frames stale_frames reads
        "relayouts": sum(drag["relayouts"] for drag in measured),
        "settle_ms_max": max(settles, default=None),
        "area_lag_max": worst("area_lag", "max"),
        "lockstep_lag_frames": sum(drag["lockstep_lag_frames"] for drag in measured),
        "controls_lag_frames": sum(drag["controls_lag_frames"] for drag in measured),
        "frame_ms_p95": worst("frame_ms", "p95"),
        "edge_lag_max": worst("edge_lag", "max"),
        "unmatched_page_window": sum(drag["unmatched_page_window"] for drag in measured),
        "detached_frames": sum(drag["detached_frames"] for drag in measured),
        "hosted_matched": sum(drag["hosted_matched"] for drag in measured),
        "gap_frames": sum(drag["gap_frames"] for drag in measured),
        "dropped": sum(drag["dropped"] for drag in measured),
        "worst_stall_ms": worst("worst_stall_ms", None),
        "page_dropped": sum(drag["page_dropped"] for drag in measured),
    }


def judge(data: dict, refresh: float) -> dict:
    drags = [judge_drag(trace, refresh) for trace in data.get("drags") or []]
    measured = [drag for drag in drags if "error" not in drag]
    if not measured:
        return {"ok": True, "problems": [], "measured": False, "pane": data.get("pane") or "browser",
                "note": "not measured: " + (data.get("error") or next((drag["error"] for drag in drags), None)
                                            or "no drag with a divider and a Chromium host")}
    gestures = {}
    for gesture in GESTURES:
        of_gesture = [drag for drag in measured if drag["gesture"] == gesture]
        if of_gesture:
            gestures[gesture] = {"pane": data.get("pane") or "browser", "gesture": gesture, "measured": True,
                                 **_summary(of_gesture)}
    return {"ok": True, "problems": [], "measured": True, "pane": data.get("pane") or "browser",
            "refresh_ms": refresh, "drags": drags, "gestures": gestures, **_summary(measured)}


def markdown_row(verdict: dict) -> str:
    if not verdict.get("measured"):
        return f"| split_resize | report | | | | {verdict.get('note', 'not measured')} (reported only) |"

    def shown(value) -> str:
        return "n/a" if value is None else f"{value:g}"

    what = {"divider": "a dragged divider", "sidebar": "a toggled sidebar", "window-edge": "a dragged window corner"}
    gesture = verdict.get("gesture")
    page = "Agent chat" if verdict.get("pane") == "chat" else "Chromium page"
    return (f"| split_resize | ok | | | | {page} beside {what.get(gesture, 'a resized pane')}: "
            f"out of lockstep in {verdict.get('lockstep_lag_frames', 0)} frames "
            f"({verdict.get('controls_lag_frames', 0)} with the top-right buttons off), drag frame p95 "
            f"{shown(verdict.get('frame_ms_p95'))} ms; page edge trails the pane "
            f"≤{shown(verdict['edge_lag_max'])} frames ({verdict['unmatched_page_window']} samples with no page window, "
            f"{verdict.get('detached_frames', 0)} detached); "
            f"laid out at its area's width {shown(verdict['layout_lag_p50'])}/{shown(verdict['layout_lag_p95'])}/"
            f"{shown(verdict['layout_lag_max'])} frames after it "
            f"(p50/p95/max; p95 {shown(verdict['layout_lag_ms_p95'])} ms), stale in {verdict['stale_frames']} of "
            f"{verdict['moving_frames']} moving frames, {verdict['relayouts']} relayouts while moving, settled "
            f"≤{shown(verdict['settle_ms_max'])} ms after the last move; {verdict['dropped']} app and {verdict['page_dropped']} "
            f"page frames dropped, worst app frame {shown(verdict.get('worst_stall_ms'))} ms (reported only) |")
