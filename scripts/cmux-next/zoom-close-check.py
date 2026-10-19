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
  ghost     frames after the first changed one that still show the closed
            pane's color.
  springs   trace: every remaining pane edge that moves covers the same share
            of its travel at each frame (one spring: spread <= 0.08), and the
            panes move in one run (no second motion after they came to rest).
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


def check_zoom(name, directory, frames, colors, scale, zooming_in):
    samples = trace_samples(directory)
    pane = zoom_pane(samples)
    result = {"zoom_pane": pane, "frames": len(frames), "trace_samples": len(samples)}
    failures = []
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


def check_close(name, directory, frames, colors, scale):
    before, _ = panes_of(load(os.path.join(directory, "before.json")))
    after, _ = panes_of(load(os.path.join(directory, "after.json")))
    gone = [p["pane"] for p in before if p["pane"] not in {q["pane"] for q in after}]
    result = {"closed": [colors.get(p, p) for p in gone], "frames": len(frames)}
    failures = []
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
        length = min(len(s) for s in shares.values())
        for index in range(length):
            values = [s[index][1] for s in shares.values()]
            spread = max(spread, max(values) - min(values))
    result["moving_edges"] = len(shares)
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
        if not os.path.isdir(directory) or not os.path.exists(os.path.join(directory, "frames.json")):
            continue
        frames, scale = (None, None) if opts.source == "window" else video_frames(directory)
        source = "video" if frames else "window"
        if opts.source == "video" and not frames:
            report[name] = {"failures": ["no display video"]}
            failed = True
            continue
        frames = frames or frames_of(directory)
        if len(frames) < 3:
            report[name] = {"failures": ["fewer than 3 frames"]}
            failed = True
            continue
        local = load(os.path.join(directory, "colors.json"), {}) or colors
        scale = scale or panes_of(load(os.path.join(directory, "before.json")))[1]
        if "close" in name:
            result, failures = check_close(name, directory, frames, local, scale)
        else:
            result, failures = check_zoom(name, directory, frames, local, scale, zooming_in="unzoom" not in name)
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
