"""The movers of a `debug.motion` trace and when each moved (one-motion-trace.py, one_motion_plot.py).

A mover is one animated thing on screen: the sidebar's width, a pane's frame, a pane's laid-out content, a terminal
surface, a Chromium page. `series` reads them from a trace's samples (MotionFrameTrace rows; the pane row is
ScreenContentView+MotionSample.swift's), `movement` says when one first and last changed, and `summarize` turns a
motion's trace into the per-mover table and the spreads that say whether everything moved as one. Standard library
only: the judge runs on Linux and on the mini's system python3.
"""

EPS = 0.5  # points: a value this close to the last frame's did not move

# A pane row: [pane, x, y, width, height, alpha, z, fx, fy, fwidth, fheight, cwidth, cheight, header, cx, cy, cwidth, cheight]
PANE_FRAME = slice(7, 11)
PANE_CONTENT = slice(14, 18)
PANE_ROW = 18


def series(samples):
    """{mover: [(t ms, values)]} from a trace's samples."""
    out = {}

    def add(key, t, values):
        out.setdefault(key, []).append((t, tuple(round(float(v), 2) for v in values)))
    for sample in samples:
        t = float(sample.get("t", 0))
        side = sample.get("sidebar")
        if isinstance(side, list) and side:
            add("sidebar", t, side[:1])
        for row in sample.get("panes") or []:
            if not isinstance(row, list) or len(row) < PANE_ROW:
                continue
            pane = str(row[0])[-6:]
            add(f"pane {pane} frame", t, row[PANE_FRAME])
            add(f"pane {pane} content", t, row[PANE_CONTENT])
        for index, row in enumerate(sample.get("terminal") or []):
            if isinstance(row, list) and len(row) >= 4:
                add(f"terminal {index}", t, row[0:4])
        for index, row in enumerate(sample.get("page") or []):
            if isinstance(row, list) and len(row) >= 7 and row[2] != -1:
                add(f"page {index}", t, [row[6], row[2], row[3]])  # the page window's x, width, height
    return out


def movement(points, acted_at):
    """When the value first and last changed, in ms after `acted_at`; None when it never moved."""
    first = last = None
    for (_, v0), (t1, v1) in zip(points, points[1:]):
        if len(v0) != len(v1) or any(abs(a - b) > EPS for a, b in zip(v0, v1)):
            first = t1 if first is None else first
            last = t1
    if first is None:
        return None
    return {"start_ms": round(first - acted_at, 1), "end_ms": round(last - acted_at, 1),
            "from": list(points[0][1]), "to": list(points[-1][1])}


def summarize(name, samples, acted_at, refresh_ms):
    """The motion's movers, when each started and ended, and the spreads between them.

    `spread_start_ms` / `spread_end_ms`: the largest gap between two movers' first / last moves (0 when all move in the
    same frames). `content_lag_ms`: per pane, how long after its frame's last move its content still moved (a content
    held through the motion and laid out at the landing shows a positive lag; negative: the content stopped first).
    """
    refresh = refresh_ms or 8.33
    movers = {}
    for key, points in series(samples).items():
        moved = movement(points, acted_at)
        if moved:
            moved["start_frame"] = round(moved["start_ms"] / refresh)
            moved["end_frame"] = round(moved["end_ms"] / refresh)
            movers[key] = moved
    starts = [m["start_ms"] for m in movers.values()]
    ends = [m["end_ms"] for m in movers.values()]
    lags = {}
    for key, moved in movers.items():
        if key.endswith(" content"):
            frame = movers.get(key[:-len(" content")] + " frame")
            if frame:
                lags[key[:-len(" content")]] = round(moved["end_ms"] - frame["end_ms"], 1)
    return {"motion": name, "frames": len(samples), "refresh_ms": refresh, "acted_at_ms": acted_at, "movers": movers,
            "spread_start_ms": round(max(starts) - min(starts), 1) if starts else None,
            "spread_end_ms": round(max(ends) - min(ends), 1) if ends else None, "content_lag_ms": lags}


def progress(points):
    """[(t, 0..1)] along the component of the value that travels furthest; None when it did not move. A value that
    left and came back (content that shifted and snapped back) is drawn by its widest swing instead."""
    if len(points) < 2:
        return None
    first, last = points[0][1], points[-1][1]
    travel = [abs(b - a) for a, b in zip(first, last)]
    if travel and max(travel) >= EPS:
        axis = travel.index(max(travel))
        span = last[axis] - first[axis]
        return [(t, (v[axis] - first[axis]) / span) for t, v in points]
    spans = [max(v[i] for _, v in points) - min(v[i] for _, v in points) for i in range(len(first))]
    if not spans or max(spans) < EPS:
        return None
    axis = spans.index(max(spans))
    low = min(v[axis] for _, v in points)
    return [(t, (v[axis] - low) / spans[axis]) for t, v in points]
