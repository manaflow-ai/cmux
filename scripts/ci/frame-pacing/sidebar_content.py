"""What a sidebar toggle costs the panes beside it.

Used by golden.py (`sidebar_collapse`, `sidebar_expand`, and their Reduce Motion rows). Leo,
2026-10-20: side panes lag when the sidebar opens and closes. Every frame of the sidebar's
width animation moves the content edge, so Auto Layout resizes every pane in the content
area, and each pane resizes what it holds.

Reported, not judged (no threshold fails a run):

- `relayouts`: display frames on which a pane's content view changed width. One per frame of
  the slide is the cost; the animation needs it to look right, so this is context for the rest.
- `lag_frames`: frames the widest pane's content trailed the sidebar's own width change, so a
  pane that stops following the edge shows up.
- `grid_reports`: terminals' grid reports over the toggle (`debug.layout_counters`), one PTY
  resize and shell redraw each. A slide should add one per terminal, at the landing, not one
  per frame: that is what holding the grid through the motion buys
  (`RestingPlacement`, `ContentAreaMotionHosting`).
- `root_layouts`, `window_updates`: `LayoutRootView.layout()` passes and window notifications
  terminals handled over the toggle.

A pane row of a `panes` sample is `[pane, x, y, width, height, alpha, z, fx, fy, fwidth,
fheight, cwidth, cheight, header, cx, cy, cwidth, cheight]` (ScreenContentView+MotionSample.swift):
index 9 is the pane host's width and index 11 its content view's.
"""

from __future__ import annotations

HOST_WIDTH = 9
CONTENT_WIDTH = 11
EPS = 0.75  # points: a width this close to the last one is the same width


def _rows(samples: list[dict]) -> list[dict[str, float]]:
    """Per frame, each pane's content width by pane id; frames with no pane row are dropped."""
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
        if widths:
            frames.append(widths)
    return frames


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
    result: dict = {"frames": len(frames)}
    if frames:
        panes = sorted(set(frames[0]) & set(frames[-1]))
        relayouts = 0
        for previous, current in zip(frames, frames[1:]):
            if any(pane in previous and pane in current and abs(current[pane] - previous[pane]) > EPS
                   for pane in panes):
                relayouts += 1
        result["relayouts"] = relayouts
        result["panes"] = len(panes)
        travel = {pane: abs(frames[-1][pane] - frames[0][pane]) for pane in panes}
        widest = max(travel, key=lambda pane: travel[pane]) if travel else None
        if widest is not None:
            result["travel"] = round(travel[widest], 2)
            result["lag_frames"] = _lag(samples, frames, widest)
    counters = data.get("counters") or {}
    for name, key in (("grid_reports", "terminal_grid_reports"), ("root_layouts", "layout_root_layouts"),
                      ("window_updates", "terminal_window_updates")):
        delta = _counter_delta(counters, key)
        if delta is not None:
            result[name] = delta
    return result


def _lag(samples: list[dict], frames: list[dict[str, float]], pane: str) -> int:
    """The most frames `pane`'s content trailed the sidebar's own last width change."""
    widths = [float((sample.get("sidebar") or [0, 0])[0]) for sample in samples]
    if len(widths) != len(samples) or len(frames) < 2:
        return 0
    content = [frame.get(pane) for frame in frames]
    # The traces are the same frames in order, but a frame without a pane row was dropped:
    # compare only the last min(len) frames of each, which is where the motion is.
    count = min(len(widths), len(content))
    widths, content = widths[-count:], content[-count:]
    worst, pending = 0, None
    for index in range(1, count):
        if widths[index] is not None and widths[index - 1] is not None and abs(widths[index] - widths[index - 1]) > EPS:
            pending = index
        if pending is not None and content[index] is not None and content[index - 1] is not None \
                and abs(content[index] - content[index - 1]) > EPS:
            worst = max(worst, index - pending)
            pending = None
    return worst


def note(result: dict) -> str:
    """The scenario row's note (reported only)."""
    parts = []
    if "relayouts" in result:
        parts.append(f"{result['panes']} pane(s) re-laid out on {result['relayouts']} of "
                     f"{result['frames']} frames")
    if "grid_reports" in result:
        parts.append(f"{result['grid_reports']} terminal grid report(s)")
    if result.get("lag_frames"):
        parts.append(f"content trailed the edge by {result['lag_frames']} frame(s)")
    if "root_layouts" in result:
        parts.append(f"{result['root_layouts']} layout root pass(es)")
    return "; ".join(parts) + " (reported only)" if parts else "no pane samples"
