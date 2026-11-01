"""What a sidebar toggle costs the panes beside it.

Used by golden.py (`sidebar_collapse`, `sidebar_expand`, and their Reduce Motion rows). Leo,
2026-10-20: side panes lag when the sidebar opens and closes. Every frame of the sidebar's
width animation moves the content edge, so Auto Layout resizes every pane in the content
area, and each pane resizes what it holds.

Reported, not judged (no threshold fails a run):

- `relayouts`: display frames on which a pane's content view changed width. With
  `sidebar.slideHoldsContent` on (an opt-in comparison) the content takes its landing width when
  the slide starts and stays still, pinned to the far edge, so this is about one per toggle; with it
  off (the default) it is one per frame of the slide.
- `stalled`: frames on which the sidebar's own width moved and no pane's content width did.
  With the hold on that is every frame of the slide by design; with it off, a pane that stops
  following the edge shows up. Counted per frame against the same
  sample, not by matching one series against the other: a slide is a change on every frame,
  so "how many frames did the content trail by" has no well-defined answer, while "the edge
  moved and nothing followed" does.
- `grid_reports`: terminals' grid reports over the toggle (`debug.layout_counters`), one PTY
  resize and shell redraw each. A slide should add one per terminal, at the landing, not one
  per frame: that is what holding the grid through the motion buys
  (`RestingPlacement`, `ContentAreaMotionHosting`).
- `root_layouts`, `window_updates`: `LayoutRootView.layout()` passes and window notifications
  terminals handled over the toggle.

A pane row of a `panes` sample is `[pane, x, y, width, height, alpha, z, fx, fy, fwidth,
fheight, cwidth, cheight, header, cx, cy, cwidth, cheight]` (ScreenContentView+MotionSample.swift):
index 11 is the pane content view's width.
"""

from __future__ import annotations

CONTENT_WIDTH = 11
EPS = 0.75  # points: a width this close to the last one is the same width


def _rows(samples: list[dict]) -> list[dict[str, float]]:
    """Per frame, each pane's content width by pane id. One entry per sample, so a frame
    carrying no pane row (a hidden screen samples `[:]`) is an empty dict and the result
    still lines up index for index with the sidebar's own series."""
    frames = []
    for sample in samples:
        widths: dict[str, float] = {}
        for row in sample.get("panes") or []:
            if not isinstance(row, list) or len(row) <= CONTENT_WIDTH:
                continue
            try:
                widths[str(row[0])] = float(row[CONTENT_WIDTH])
            except (TypeError, ValueError):
                continue
        frames.append(widths)
    return frames


def _edge(samples: list[dict]) -> list[float | None]:
    """The sidebar's own width per frame: whichever of the frame width (index 0) and the
    presented width (index 1) changed on more frames, as golden.py's `sidebar_series`
    picks (the other may jump straight to its target)."""
    series: list[list[float | None]] = []
    for index in (0, 1):
        values: list[float | None] = []
        for sample in samples:
            row = sample.get("sidebar")
            try:
                values.append(float(row[index]))
            except (TypeError, ValueError, IndexError, KeyError):
                values.append(None)
        series.append(values)
    return max(series, key=_changes)


def _changes(values: list[float | None]) -> int:
    """Frames on which `values` differs from the frame before it."""
    return sum(1 for before, after in zip(values, values[1:])
               if before is not None and after is not None and abs(after - before) > EPS)


def _counter_delta(counters: dict, key: str) -> int | None:
    before, after = counters.get("before") or {}, counters.get("after") or {}
    if key not in before or key not in after:
        return None
    try:
        return int(after[key]) - int(before[key])
    except (TypeError, ValueError):
        return None


def metrics(data: dict) -> dict:
    """Report-only numbers for one toggle."""
    samples = data.get("samples") or []
    frames = _rows(samples)
    drawn = [frame for frame in frames if frame]
    result: dict = {"frames": len(drawn)}
    if drawn:
        panes = sorted(set(drawn[0]) & set(drawn[-1]))
        relayouts = 0
        for previous, current in zip(frames, frames[1:]):
            if any(pane in previous and pane in current and abs(current[pane] - previous[pane]) > EPS
                   for pane in panes):
                relayouts += 1
        result["relayouts"] = relayouts
        result["panes"] = len(panes)
        travel = [abs(drawn[-1][pane] - drawn[0][pane]) for pane in panes]
        if travel:
            result["travel"] = round(max(travel), 2)
        result["stalled"] = _stalled(_edge(samples), frames, panes)
    counters = data.get("counters") or {}
    for name, key in (("grid_reports", "terminal_grid_reports"), ("root_layouts", "layout_root_layouts"),
                      ("window_updates", "terminal_window_updates")):
        delta = _counter_delta(counters, key)
        if delta is not None:
            result[name] = delta
    return result


def _stalled(edge: list[float | None], frames: list[dict[str, float]], panes: list[str]) -> int:
    """Frames on which the sidebar's width moved and no pane's content width did.

    Both series come from the same samples, one entry per frame, so this needs no matching
    between traces: a frame counts only when the edge is known to have moved and at least
    one pane's width is known to have stayed. A content view that never follows the edge
    counts every frame of the slide; a perfect follow counts none.
    """
    count = min(len(edge), len(frames))
    stalled = 0
    for index in range(1, count):
        before, after = edge[index - 1], edge[index]
        if before is None or after is None or abs(after - before) <= EPS:
            continue
        previous, current = frames[index - 1], frames[index]
        shared = [pane for pane in panes if pane in previous and pane in current]
        if shared and all(abs(current[pane] - previous[pane]) <= EPS for pane in shared):
            stalled += 1
    return stalled


def note(result: dict) -> str:
    """The scenario row's note (reported only)."""
    parts = []
    if "relayouts" in result:
        parts.append(f"{result['panes']} pane(s) re-laid out on {result['relayouts']} of "
                     f"{result['frames']} frames")
    if "grid_reports" in result:
        parts.append(f"{result['grid_reports']} terminal grid report(s)")
    if result.get("stalled"):
        parts.append(f"the edge moved with no pane following it on {result['stalled']} frame(s)")
    if "root_layouts" in result:
        parts.append(f"{result['root_layouts']} layout root pass(es)")
    return "; ".join(parts) + " (reported only)" if parts else "no pane samples"
