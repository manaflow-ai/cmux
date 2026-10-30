#!/usr/bin/env python3
"""Check a zoom-close-record.py recording frame by frame.

Every pane shows one solid color (colors.json), so the pixels say which pane
shows where, child-window pages (Chromium) included. The layout trace
(trace.json, `debug.motion` trace_*) says where the layout put each host, its
alpha and its subview order on the same display frames.

zoom and unzoom scenarios (the zooming pane is the trace's `zoom` pane):
  foreign   pixels of another pane's color inside the zooming pane's presented
            rect (pixels: the bounding box of its own color), per frame. Any
            frame over 0.2 % of the rect fails: a page or pane drawn over it.
  monotone  that rect's area only grows (zoom) or only shrinks (unzoom) on the
            way, within 1 %, and its edges never step back by more than 2 pt.
  holes     unzoom: each other pane's color covers its resting area outside the
            zooming rect from the first changed frame (>= 90 %); a lower share
            is a blank hole or a fade-in under a pane that should be there.
  z         trace: while the zoom moves, no pane host or visible divider that
            overlaps the zooming rect is above it in the subview order.
close scenarios (a pane in before.json is not in after.json):
  hole      trace samples after the closed pane left in which no other pane has moved yet.
  ghost     frames after the first changed one that still show the closed
            pane's color.
  springs   trace: every remaining pane edge that moves covers the same share
            of its travel at each frame (one spring: spread <= 0.08), and the
            panes move in one run (no second motion after they came to rest).
static    (every scenario) the rects a gesture does not move keep their pixels in every frame: the
            sidebar, and each pane whose cell is the same before and after (a close: the panes
            outside the closed pane's chain; a zoom or unzoom: every other pane), less the moving
            pane's presented rect (its color's bounding box, 6 pt wider). A changed pixel differs
            from the first frame by more than 40 in a channel; over 50 of them in any frame fails.
            A fade, a dim change, a jump or a reflow outside the moving pane all show here.
travel    (trace) the moving pane's travel curve: time to 90 % of it, time until 1 pt is left,
            overshoot past the target, and the largest frame-to-frame change of its per-frame
            step (smoothness), all from the first frame it moved.
live      (trace, every scenario) each pane whose presented rect moves is laid out at it in every
            frame: its host frame is the presented rect (`held`: samples where it is not), and its
            content's size changes in every sample its rect's size does (`frozen`: samples where it
            did not; `end_jump`: the content's last size change as a share of its whole change, a
            layout held and then resized once at rest is 1.0).
header    (trace) the zooming pane's tab strip shows whole in every sample (share 1.0), and every
            other moving pane's too.
work      (work.json) main-thread time per display frame: the layout step and the whole tick,
            p50 / p95 / max ms (`debug.motion` work: `layout` the layout's step, `clock` the tick).
edges     (trace, split-* scenarios) on every sample the split pane's content edge, its tab
            strip's edge (`strip_edges`, builds that report it) and the new pane's content edge
            keep one distance to the divider between them, within 0.5 pt (1 px at 2x): the left
            (or top) pane lays out at its presented size every frame, edge to edge with the new
            pane; and the edge moves on every sample the divider does (no frozen frame).
perf-*    scenarios with a busy terminal: live, header and work only.
reduce scenarios (OUT dir recorded with --reduce-motion): frames between the
            first changed frame and the final one (one-step: <= 1).

Usage: zoom-close-check.py DIR [--json OUT] [--reduce]
Exit status 1 when any check fails.
"""
import argparse, json, os, subprocess, sys

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("dir")
parser.add_argument("--json", default=None)
parser.add_argument("--reduce", action="store_true", help="the recording ran with Reduce Motion")
parser.add_argument("--source", choices=["auto", "window", "video"], default="auto",
                    help="frames: the app's composited window record, or the capture daemon's display video "
                         "(video/*.mp4 cropped to the window, screen.json; it has Chromium pages). auto: video when present")
opts = parser.parse_args()

COLORS = {
    "orange": (255, 140, 0), "magenta": (255, 0, 255), "cyan": (0, 255, 255), "yellow": (255, 255, 0),
    "red": (255, 32, 32), "green": (0, 192, 0), "blue": (32, 64, 255), "purple": (128, 0, 255),
}


def load(path, default=None):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def frames_of(directory):
    names = sorted(n for n in os.listdir(directory) if n.startswith("frame-") and n.endswith(".jpg"))
    return [np.asarray(Image.open(os.path.join(directory, n)).convert("RGB"), dtype=np.int16) for n in names]


def video_frames(directory):
    """The display video's frames cropped to the app window (screen.json), and pixels per point."""
    folder = os.path.join(directory, "video")
    movies = [os.path.join(root, n) for root, _, names in os.walk(folder) for n in names if n.endswith(".mp4")] if os.path.isdir(folder) else []
    place = load(os.path.join(directory, "screen.json"), {}) or {}
    window, screen = place.get("window"), place.get("screen") or {}
    if not movies or not window:
        return None, None
    probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                                       "-of", "json", movies[0]], capture_output=True, text=True).stdout or "{}")
    stream = (probe.get("streams") or [{}])[0]
    width, height = stream.get("width"), stream.get("height")
    points = screen.get("width") or (screen.get("main") or {}).get("width")
    if not width or not points:
        return None, None
    scale = width / points
    b = window["bounds"]
    x, y, w, h = (int(round(v * scale)) for v in (b["x"], b["y"], b["width"], b["height"]))
    w, h = min(w, width - x) // 2 * 2, min(h, height - y) // 2 * 2
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", movies[0], "-vf", f"crop={w}:{h}:{x}:{y}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True).stdout
    size = w * h * 3
    frames = [np.frombuffer(raw[i:i + size], dtype=np.uint8).reshape(h, w, 3).astype(np.int16) for i in range(0, len(raw) - size + 1, size)]
    return frames, scale


def mask(frame, color):
    c = np.array(COLORS[color], dtype=np.int16)
    return (np.abs(frame - c).max(axis=2) < 48)


def panes_of(chrome):
    windows = ((chrome or {}).get("pane_chrome") or {}).get("windows") or []
    return (windows[0].get("panes") or [], windows[0].get("scale") or 2) if windows else ([], 2)


def bbox(m, share=0.3):
    """The rect a color fills: the rows and columns holding at least `share` of its fullest one."""
    cols, rows = m.sum(axis=0), m.sum(axis=1)
    if cols.max(initial=0) < 8:
        return None
    xs, ys = np.nonzero(cols >= cols.max() * share)[0], np.nonzero(rows >= rows.max() * share)[0]
    return (int(xs[0]), int(ys[0]), int(xs[-1]) + 1, int(ys[-1]) + 1)


def first_change(frames, threshold=6.0):
    base = frames[0]
    for index, frame in enumerate(frames[1:], 1):
        if np.abs(frame - base).mean() > threshold / 10:
            return index
    return None


def last_change(frames, threshold=6.0):
    final = frames[-1]
    for index in range(len(frames) - 1, -1, -1):
        if np.abs(frames[index] - final).mean() > threshold / 10:
            return index + 1
    return 0


def trace_samples(directory):
    return (load(os.path.join(directory, "trace.json"), {}) or {}).get("samples") or []


def zoom_pane(samples):
    for sample in samples:
        for pane in sample.get("zoom") or []:
            if pane:
                return pane
    return None


def overlaps(a, b):
    return min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]) > 1 and min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]) > 1


def rect_px(rect, scale, inset):
    x, y, w, h = rect
    return (int((x + inset) * scale), int((y + inset) * scale), int((x + w - inset) * scale), int((y + h - inset) * scale))


def check_static(directory, frames, colors, scale, moving_color=None, exclude=()):
    """Changed pixels per frame inside the rects that must not move (see the module doc)."""
    before, _ = panes_of(load(os.path.join(directory, "before.json")))
    after, _ = panes_of(load(os.path.join(directory, "after.json")))
    windows = ((load(os.path.join(directory, "before.json"), {}) or {}).get("pane_chrome") or {}).get("windows") or [{}]
    later = {p["pane"]: p["cell"] for p in after}
    rects = [("sidebar", windows[0]["sidebar"])] if windows[0].get("sidebar") else []
    for p in before:
        cell = p["cell"]
        if p["pane"] in exclude or p["pane"] not in later:
            continue
        if all(abs(a - b) <= 0.5 for a, b in zip(cell, later[p["pane"]])):
            rects.append((colors.get(p["pane"], p["pane"][-4:]), cell))
    base = frames[0]
    worst, failing = {}, []
    for index, frame in enumerate(frames[1:], 1):
        cover = bbox(mask(frame, moving_color)) if moving_color else None
        changed = np.abs(frame - base).max(axis=2) > 40
        if cover:
            pad = int(6 * scale)
            changed[max(0, cover[1] - pad):cover[3] + pad, max(0, cover[0] - pad):cover[2] + pad] = False
        for label, rect in rects:
            x0, y0, x1, y1 = rect_px(rect, scale, 4)
            count = int(changed[y0:y1, x0:x1].sum())
            worst[label] = max(worst.get(label, 0), count)
            if count > 50:
                failing.append(f"{index}:{label}:{count}px")
    return {"static_rects": [label for label, _ in rects], "static_worst_px": worst, "static_frames": failing[:16],
            "static_failing_frames": len(failing)}


def travel_curve(series):
    """Travel metrics of one (t ms, value) series from its first moving sample."""
    values = [v for _, v in series]
    if len(values) < 3 or abs(values[-1] - values[0]) < 4:
        return None
    start_value, end_value = values[0], values[-1]
    total = end_value - start_value
    moving = next((i for i in range(1, len(values)) if abs(values[i] - values[i - 1]) > 0.25), None)
    if moving is None:
        return None
    t0 = series[moving - 1][0]
    t90 = next((t for t, v in series if (v - start_value) / total >= 0.9), None)
    end = next((t for i, (t, v) in enumerate(series) if all(abs(end_value - w) < 1 for _, w in series[i:])), None)
    over = max(((v - end_value) * (1 if total > 0 else -1) for _, v in series), default=0)
    steps = [b - a for a, b in zip(values[moving - 1:], values[moving:])]
    jerk = max((abs(b - a) for a, b in zip(steps, steps[1:])), default=0)
    gaps = [b[0] - a[0] for a, b in zip(series[moving - 1:], series[moving:])]
    return {"travel_pt": round(total, 1), "t90_ms": round(t90 - t0) if t90 is not None else None,
            "end_ms": round(end - t0) if end is not None else None, "overshoot_pt": round(max(0, over), 2),
            "max_step_change_pt": round(jerk, 2), "max_frame_gap_ms": round(max(gaps, default=0), 1)}


def check_zoom(name, directory, frames, colors, scale, zooming_in):
    samples = trace_samples(directory)
    pane = zoom_pane(samples)
    result = {"zoom_pane": pane, "frames": len(frames), "trace_samples": len(samples)}
    failures = []
    widths = [(s["t"], row[3]) for s in samples for row in s.get("panes") or [] if row[0] == pane]
    result["travel"] = travel_curve(widths)
    static = check_static(directory, frames, colors, scale, moving_color=colors.get(pane), exclude=(pane,))
    result.update(static)
    if not colors.get(pane):
        result["static_note"] = "the zooming pane has no recorded color: the cover is not cut out"
    if static["static_failing_frames"]:
        failures.append(f"static rects changed in {static['static_failing_frames']} frames (first {static['static_frames'][0]})")
    if not pane:
        failures.append("no zoom motion in the trace (the zoom snapped or did not run)")
    color = colors.get(pane) if pane else None
    others = sorted({c for p, c in colors.items() if p != pane and c != color})
    start = first_change(frames)
    end = last_change(frames)
    result["first_changed_frame"], result["rest_frame"] = start, end
    result["moving_frames"] = (end - start) if start is not None else 0
    if color is None or start is None:
        if start is None:
            failures.append("no frame changed")
        return result, failures
    rects, foreign = [], []
    for index in range(max(0, start - 1), len(frames)):
        frame = frames[index]
        rect = bbox(mask(frame, color))
        if rect is None:
            rects.append((index, None))
            continue
        x0, y0, x1, y1 = rect
        inset = int(4 * scale)
        region = frame[y0 + inset:y1 - inset, x0 + inset:x1 - inset]
        area = max(1, region.shape[0] * region.shape[1])
        counts = {other: int(mask(region, other).sum()) for other in others}
        worst = max(counts.items(), key=lambda kv: kv[1]) if counts else (None, 0)
        rects.append((index, rect))
        foreign.append({"frame": index, "share": round(worst[1] / area, 4), "color": worst[0], "px": worst[1]})
    bad = [f for f in foreign if f["share"] > 0.002]
    result["foreign_frames"] = [f"{f['frame']}:{f['color']}:{f['share'] * 100:.1f}%" for f in bad]
    result["foreign_max_share"] = max((f["share"] for f in foreign), default=0)
    if bad:
        failures.append(f"another pane's pixels inside the zooming pane in {len(bad)} frames (first {bad[0]['frame']}, max {result['foreign_max_share'] * 100:.1f} %)")
    # Monotone presented rect.
    areas = [(i, (r[2] - r[0]) * (r[3] - r[1])) for i, r in rects if r]
    reversals = []
    for (i0, a0), (i1, a1) in zip(areas, areas[1:]):
        step = (a1 - a0) / max(1, max(a0, a1))
        if (zooming_in and step < -0.01) or (not zooming_in and step > 0.01):
            reversals.append(f"{i0}->{i1}:{step * 100:+.1f}%")
    edge_back = []
    shown = [(i, r) for i, r in rects if r]
    for (i0, r0), (i1, r1) in zip(shown, shown[1:]):
        for k, label in enumerate(("left", "top", "right", "bottom")):
            grow = (r0[k] - r1[k]) if k < 2 else (r1[k] - r0[k])  # positive: the rect grew on that side
            if (zooming_in and grow < -2 * scale) or (not zooming_in and grow > 2 * scale):
                edge_back.append(f"{i0}->{i1}:{label}{grow / scale:+.1f}pt")
    result["area_reversals"], result["edge_reversals"] = reversals, edge_back
    if reversals or edge_back:
        failures.append(f"the zooming rect stepped back ({len(reversals)} area, {len(edge_back)} edge steps)")
    result["rect_track"] = [f"{i}:{r[0] // int(scale)},{r[1] // int(scale)},{(r[2] - r[0]) // int(scale)}x{(r[3] - r[1]) // int(scale)}" if r else f"{i}:-"
                            for i, r in rects[:40]]
    # Holes: unzoom, the other panes under the shrinking one.
    if not zooming_in:
        final = frames[-1]
        holes = []
        for other in others:
            rest = mask(final, other)
            if rest.sum() < 2000:
                continue
            for index, rect in rects:
                if index < start:
                    continue
                visible = rest.copy()
                if rect:
                    x0, y0, x1, y1 = rect
                    visible[y0:y1, x0:x1] = False
                total = int(visible.sum())
                if total < 400:
                    continue
                share = float((mask(frames[index], other) & visible).sum()) / total
                if share < 0.9:
                    holes.append(f"{index}:{other}:{share * 100:.0f}%")
        result["hole_frames"] = holes
        if holes:
            failures.append(f"blank or faded panes outside the shrinking pane in {len(holes)} pane-frames (first {holes[0]})")
    # Z order from the trace.
    zviolations = []
    for sample in samples:
        if not any(sample.get("zoom") or []):
            continue
        rows = {row[0]: row for row in sample.get("panes") or []}
        mine = rows.get(pane)
        if not mine or mine[3] < 1:
            continue
        rect, z = mine[1:5], mine[6]
        for other, row in rows.items():
            if other != pane and row[6] > z and row[5] > 0.01 and overlaps(rect, row[1:5]):
                zviolations.append(f"{sample.get('t')}ms:pane {colors.get(other, other)} above")
        for row in sample.get("dividers") or []:
            if row[6] > z and row[5] > 0.01 and overlaps(rect, row[1:5]):
                zviolations.append(f"{sample.get('t')}ms:divider {row[0]} alpha {row[5]:.2f} above")
    result["z_violations"] = zviolations[:12]
    result["z_violation_count"] = len(zviolations)
    if zviolations:
        failures.append(f"{len(zviolations)} trace samples with a view above the zooming pane")
    return result, failures


def moving_panes(directory, zooming):
    """The panes a scenario moves: the zooming pane, else every pane whose cell differs before and
    after (a close's or split's) and a pane the change added."""
    if zooming:
        return {zooming}
    before = {p["pane"]: p["cell"] for p in panes_of(load(os.path.join(directory, "before.json")))[0]}
    after = {p["pane"]: p["cell"] for p in panes_of(load(os.path.join(directory, "after.json")))[0]}
    return {pane for pane, cell in after.items() if pane not in before or any(abs(a - b) > 0.5 for a, b in zip(cell, before[pane]))}


def check_live(directory, colors, focus_pane=None):
    """The live-layout, header and frame-time checks (module doc: live, header, work). A pane a
    split adds grows from no height, shorter than its tab strip at first: its header is not checked."""
    samples = [s for s in trace_samples(directory) if s.get("panes")]
    moving = moving_panes(directory, focus_pane)
    before_ids = {p["pane"] for p in panes_of(load(os.path.join(directory, "before.json")))[0]}
    rows = {}
    for sample in samples:
        for row in sample["panes"]:
            if len(row) >= 14:
                rows.setdefault(row[0], []).append(row)
    result, failures = {}, []
    if samples and not rows:
        return {"live": "no laid-out fields in the trace (an older build)"}, []
    live = {}
    for pane, series in rows.items():
        if pane not in moving:
            continue
        shown = [r[1:5] for r in series]
        if max((abs(a[k] - b[k]) for a, b in zip(shown, shown[1:]) for k in range(4)), default=0) < 1:
            continue
        held = sum(1 for r in series if r[3] > 1 and any(abs(r[1 + k] - r[7 + k]) > 0.5 for k in range(4)))
        frozen, changes = 0, []
        for a, b in zip(series, series[1:]):
            # Under a point is AppKit's pixel rounding of the content frame, not a held layout.
            size_moved = abs(a[3] - b[3]) > 1 or abs(a[4] - b[4]) > 1
            content_moved = abs(a[11] - b[11]) > 0.25 or abs(a[12] - b[12]) > 0.25
            if content_moved:
                changes.append(abs(a[11] - b[11]) + abs(a[12] - b[12]))
            if size_moved and not content_moved:
                frozen += 1
        total = sum(changes)
        end_jump = round(changes[-1] / total, 3) if total > 0 else None
        header = min((r[13] for r in series if r[11] > 1 and r[12] > 1), default=None)
        live[colors.get(pane, pane[-6:])] = {"samples": len(series), "held": held, "frozen": frozen, "content_steps": len(changes),
                                              "end_jump": end_jump, "header_min": header}
        label = colors.get(pane, pane[-6:])
        if held:
            failures.append(f"{label}: laid out away from its presented rect in {held} samples (a held frame)")
        if frozen:
            failures.append(f"{label}: content did not follow its rect in {frozen} samples")
        if end_jump is not None and len(changes) > 1 and end_jump > 0.5:
            failures.append(f"{label}: content jumped at the end ({end_jump * 100:.0f}% of its change in one step)")
        if header is not None and header < 0.999 and (focus_pane or pane in before_ids):
            failures.append(f"{label}: its tab strip showed only {header * 100:.0f}% in a frame")
    result["live"] = live
    work = (load(os.path.join(directory, "work.json"), {}) or {}).get("work") or {}
    budget = {name: work[name] for name in ("layout", "clock") if isinstance(work.get(name), dict)}
    result["work"] = budget
    # Frame pacing while anything moves: a main thread over budget skips display frames.
    times = [s["t"] for s in samples]
    gaps = sorted(b - a for a, b in zip(times, times[1:]))
    if gaps:
        result["frame_gap_ms"] = {"samples": len(times), "p50": round(gaps[len(gaps) // 2], 2), "max": round(gaps[-1], 2),
                                  "over_12_5": sum(1 for g in gaps if g > 12.5), "over_25": sum(1 for g in gaps if g > 25)}
    return result, failures


def content_rect(row):
    """A pane row's content rect (window points): the content view's window frame where the build
    reports it, else its host frame less the even pane padding."""
    if len(row) >= 18:
        return (row[14], row[15], row[14] + row[16], row[15] + row[17])
    fx, fy, fw, fh, cw, ch = row[7], row[8], row[9], row[10], row[11], row[12]
    return (fx + (fw - cw) / 2, fy + (fh - ch) / 2, fx + (fw + cw) / 2, fy + (fh + ch) / 2)


def check_split_edges(directory, colors):
    """The split pane's and the new pane's edges against the divider between them (module doc: edges)."""
    before = {p["pane"]: p["cell"] for p in panes_of(load(os.path.join(directory, "before.json")))[0]}
    after = {p["pane"]: p["cell"] for p in panes_of(load(os.path.join(directory, "after.json")))[0]}
    added = [p for p in after if p not in before]
    if len(added) != 1:
        return {"edges": f"{len(added)} panes added"}, ["the split added no pane"] if not added else []
    new = added[0]
    n = after[new]
    def beside(cell):
        right = abs(n[0] - (cell[0] + cell[2])) < 24 and min(n[1] + n[3], cell[1] + cell[3]) - max(n[1], cell[1]) > 8
        down = abs(n[1] - (cell[1] + cell[3])) < 24 and min(n[0] + n[2], cell[0] + cell[2]) - max(n[0], cell[0]) > 8
        return "right" if right else "down" if down else None
    sources = [(p, beside(c)) for p, c in after.items() if p in before and beside(c) and c[2] * c[3] < before[p][2] * before[p][3] - 1]
    if not sources:
        return {"edges": "no split pane beside the new one"}, ["no split pane beside the new pane"]
    source, axis = sources[0]
    samples = [s for s in trace_samples(directory) if s.get("panes")]
    lo, hi = (2, 0) if axis == "right" else (3, 1)  # source's far edge, new pane's near edge in content_rect
    series, last_div = [], None
    for sample in samples:
        rows = {r[0]: r for r in sample["panes"] if len(r) >= 14}
        if source not in rows or new not in rows or rows[new][9] < 1 or rows[new][10] < 1:
            continue
        src, nw = content_rect(rows[source]), content_rect(rows[new])
        edge, near = src[lo], nw[hi]
        # The divider between them: its center lies between the two edges.
        divs = [d for d in sample.get("dividers") or [] if (d[1] + d[3] / 2 if axis == "right" else d[2] + d[4] / 2) > edge - 4
                and (d[1] + d[3] / 2 if axis == "right" else d[2] + d[4] / 2) < near + 4
                and ((min(d[2] + d[4], src[3]) - max(d[2], src[1]) > 4) if axis == "right" else (min(d[1] + d[3], src[2]) - max(d[1], src[0]) > 4))]
        center = (divs[0][1] + divs[0][3] / 2 if axis == "right" else divs[0][2] + divs[0][4] / 2) if divs else None
        strip = None
        if axis == "right":
            for e in sample.get("strip_edges") or []:
                if abs(e[0] - src[0]) < 2 and abs(e[2] - src[1]) < 40:
                    strip = e
        series.append({"t": sample["t"], "edge": edge, "near": near, "div": center, "strip": strip[1] if strip else None,
                       "pills": strip[3] if strip else None})
    if len(series) < 3:
        return {"edges": "fewer than 3 samples with both panes"}, ["too few split samples"]
    with_div = [x for x in series if x["div"] is not None]
    def spread(values):
        return round(max(values) - min(values), 2) if values else None
    gap_src = spread([x["div"] - x["edge"] for x in with_div])
    gap_new = spread([x["near"] - x["div"] for x in with_div])
    gap_strip = spread([x["div"] - x["strip"] for x in with_div if x["strip"] is not None])
    clipped_pills = sum(1 for x in series if x["pills"] and x["strip"] and x["pills"] > x["strip"] + 0.5)
    frozen = sum(1 for a, b in zip(with_div, with_div[1:]) if abs(b["div"] - a["div"]) > 0.25 and abs(b["edge"] - a["edge"]) < 0.05)
    frozen_strip = sum(1 for a, b in zip(with_div, with_div[1:]) if a["strip"] is not None and b["strip"] is not None
                       and abs(b["div"] - a["div"]) > 0.25 and abs(b["strip"] - a["strip"]) < 0.05)
    moves = [abs(b["edge"] - a["edge"]) for a, b in zip(series, series[1:])]
    travel = sum(moves)
    result = {"edges": {"axis": axis, "samples": len(series), "with_divider": len(with_div), "source_to_divider_spread_pt": gap_src,
                        "divider_to_new_spread_pt": gap_new, "strip_to_divider_spread_pt": gap_strip, "frozen_samples": frozen,
                        "frozen_strip_samples": frozen_strip, "edge_steps": sum(1 for m in moves if m > 0.05),
                        "largest_step_share": round(max(moves) / travel, 3) if travel else None, "pills_past_strip": clipped_pills,
                        "track": [f"{round(x['t'])}:{round(x['edge'], 1)}|{x['div'] and round(x['div'], 1)}|{round(x['near'], 1)}|{x['strip'] and round(x['strip'], 1)}" for x in series[:40]]}}
    failures = []
    label = colors.get(source, source[-6:])
    if not with_div:
        failures.append("no divider between the split pane and the new pane in the trace")
    for value, what in ((gap_src, "the split pane's content edge"), (gap_new, "the new pane's content edge"), (gap_strip, "the split pane's tab strip edge")):
        if value is not None and value > 0.5:
            failures.append(f"{what} drifts {value} pt against the divider (1 px is 0.5 pt)")
    if frozen or frozen_strip:
        failures.append(f"{label}: frozen while the divider moved in {frozen} samples (tab strip {frozen_strip})")
    if result["edges"]["largest_step_share"] and result["edges"]["largest_step_share"] > 0.5:
        failures.append(f"{label}: one step moved {result['edges']['largest_step_share'] * 100:.0f}% of the edge's travel")
    if clipped_pills:
        failures.append(f"{label}: tab pills past the strip's edge in {clipped_pills} samples")
    return result, failures


def check_close(name, directory, frames, colors, scale):
    before, _ = panes_of(load(os.path.join(directory, "before.json")))
    after, _ = panes_of(load(os.path.join(directory, "after.json")))
    gone = [p["pane"] for p in before if p["pane"] not in {q["pane"] for q in after}]
    result = {"closed": [colors.get(p, p) for p in gone], "frames": len(frames)}
    failures = []
    static = check_static(directory, frames, colors, scale)
    result.update(static)
    if static["static_failing_frames"]:
        failures.append(f"static rects changed in {static['static_failing_frames']} frames (first {static['static_frames'][0]})")
    start = first_change(frames)
    end = last_change(frames)
    result["first_changed_frame"], result["rest_frame"] = start, end
    result["moving_frames"] = (end - start) if start is not None else 0
    if start is None:
        return result, ["no frame changed"]
    ghosts = []
    for pane in gone:
        color = colors.get(pane)
        if not color:
            continue
        for index in range(start + 1, len(frames)):
            count = int(mask(frames[index], color).sum())
            if count > 1500:
                ghosts.append(f"{index}:{color}:{count}px")
    result["ghost_frames"] = ghosts
    if ghosts:
        failures.append(f"the closed pane still shows in {len(ghosts)} frames after the first change")
    # One spring: each remaining pane's moving edges cover the same share of their travel.
    samples = [s for s in trace_samples(directory) if s.get("panes")]
    edges = {}
    for sample in samples:
        for row in sample["panes"]:
            pane, x, y, w, h = row[0], row[1], row[2], row[3], row[4]
            if pane in gone:
                continue
            for label, value in (("left", x), ("right", x + w), ("top", y), ("bottom", y + h)):
                edges.setdefault((pane, label), []).append((sample["t"], value))
    shares, runs = {}, []
    for key, series in edges.items():
        values = [v for _, v in series]
        if len(values) < 3:
            continue
        travel = values[-1] - values[0]
        if abs(travel) < 4:
            continue
        shares[key] = [(t, (v - values[0]) / travel) for t, v in series]
        # Separate motions: moving runs split by >= 3 still samples.
        moving = [abs(b - a) > 0.25 for a, b in zip(values, values[1:])]
        count, still = 0, 99
        for m in moving:
            if m:
                if still >= 3:
                    count += 1
                still = 0
            else:
                still += 1
        runs.append((f"{colors.get(key[0], key[0])}.{key[1]}", count))
    spread = 0.0
    if shares:
        # Aligned by sample time: a pane a split adds has no samples before it appears.
        by_time = {}
        for series in shares.values():
            for t, share in series:
                by_time.setdefault(t, []).append(share)
        count = len(shares)
        for values in by_time.values():
            if len(values) == count:
                spread = max(spread, max(values) - min(values))
    # Hole: samples after the closed pane left in which no remaining pane has moved yet.
    first = {row[0]: row[1:5] for row in (samples[0]["panes"] if samples else [])}
    holes = 0
    for sample in samples:
        rows = {row[0]: row[1:5] for row in sample["panes"]}
        if any(pane in rows for pane in gone):
            continue
        if any(pane in first and any(abs(a - b) > 0.5 for a, b in zip(rect, first[pane])) for pane, rect in rows.items()):
            break
        holes += 1
    result["hole_samples"] = holes
    if holes and gone and not opts.reduce:
        failures.append(f"{holes} frame(s) show the closed pane's space empty before its neighbours move")
    result["moving_edges"] = len(shares)
    result["travel"] = max((travel_curve(edges[key]) or {} for key in shares), key=lambda m: abs(m.get("travel_pt") or 0), default=None)
    result["spring_spread"] = round(spread, 3)
    result["motion_runs"] = runs
    if spread > 0.08:
        failures.append(f"the remaining panes do not move on one spring (share spread {spread:.2f})")
    if any(count > 1 for _, count in runs):
        failures.append("a second motion after the panes came to rest: " + ", ".join(f"{k}={c}" for k, c in runs if c > 1))
    if not shares and not opts.reduce:
        failures.append("no remaining pane moved in the trace (the close snapped)")
    return result, failures


def main():
    colors = load(os.path.join(opts.dir, "colors.json"), {}) or {}
    report, failed = {}, False
    for name in sorted(os.listdir(opts.dir)):
        directory = os.path.join(opts.dir, name)
        if not os.path.isdir(directory) or not os.path.exists(os.path.join(directory, "trace.json")):
            continue
        if name.startswith("perf"):
            result, failures = check_live(directory, load(os.path.join(directory, "colors.json"), {}) or colors,
                                          zoom_pane(trace_samples(directory)) if "zoom" in name else None)
            result["failures"] = failures
            report[name] = result
            failed = failed or bool(failures)
            print(f"{'FAIL' if failures else 'ok':4} {name}: " + "; ".join(failures or [json.dumps(result.get('work'))[:160]]), flush=True)
            continue
        frames, scale = (None, None) if opts.source == "window" else video_frames(directory)
        source = "video" if frames else "window"
        if opts.source == "video" and not frames:
            report[name] = {"failures": ["no display video"]}
            failed = True
            continue
        frames = frames or frames_of(directory)
        if len(frames) < 3 and name.startswith("split"):
            result, failures = check_split_edges(directory, load(os.path.join(directory, "colors.json"), {}) or colors)
            live, live_failures = check_live(directory, load(os.path.join(directory, "colors.json"), {}) or colors)
            result.update(live)
            failures = failures + live_failures
            result["failures"] = failures
            report[name] = result
            failed = failed or bool(failures)
            print(f"{'FAIL' if failures else 'ok':4} {name} [trace]: " + "; ".join(failures or [json.dumps({k: v for k, v in result['edges'].items() if k != 'track'} if isinstance(result.get('edges'), dict) else result.get('edges'))[:300]]), flush=True)
            continue
        if len(frames) < 3:
            report[name] = {"failures": ["fewer than 3 frames"]}
            failed = True
            continue
        local = load(os.path.join(directory, "colors.json"), {}) or colors
        scale = scale or panes_of(load(os.path.join(directory, "before.json")))[1]
        if "close" in name or "split" in name:
            result, failures = check_close(name, directory, frames, local, scale)
        else:
            result, failures = check_zoom(name, directory, frames, local, scale, zooming_in="unzoom" not in name)
        live, live_failures = check_live(directory, local, zoom_pane(trace_samples(directory)) if "zoom" in name else None)
        result.update(live)
        failures = failures + live_failures
        if name.startswith("split"):
            edges, edge_failures = check_split_edges(directory, local)
            result.update(edges)
            failures = failures + edge_failures
        if opts.reduce:
            steps = result.get("moving_frames", 0)
            result["reduce_steps"] = steps
            failures = [f for f in failures if "no zoom motion" not in f and "stepped back" not in f]
            if steps > 2:
                failures.append(f"Reduce Motion: {steps} frames between the first change and rest (one step expected)")
        result["failures"], result["source"] = failures, source
        report[name] = result
        failed = failed or bool(failures)
        status = "FAIL" if failures else "ok"
        print(f"{status:4} {name} [{source}]: " + "; ".join(failures or [f"{result.get('moving_frames')} moving frames"]), flush=True)
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(report, handle, indent=1)
    sys.exit(1 if failed else 0)


main()
