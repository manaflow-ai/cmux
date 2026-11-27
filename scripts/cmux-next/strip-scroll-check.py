#!/usr/bin/env python3
"""Check a strip scroll recording (motion-record.py --surface strip) frame by frame.

For each scenario folder (left-1, left-2, right-1, right-2) it reads the
window frames and reports:

  camera   the strip camera's per-frame dx, measured on the terminal prompt
           line (best overlap of the two frames' text), in window points.
           When the frames share no prompt text, the shift most pill edges
           agree on (listed as camera_from_pills; a pill check there only
           compares pills against each other).
  pills    every tab pill edge in the tab bar that was on screen in the
           previous frame must have moved by the camera dx (within 1 px at
           2x, 0.5 pt). A pinned or creeping pill fails. Edges at the strip's
           clip edges are skipped (they are cut, not moved).
  blank    every column whose prompt text is on screen (at least 20 pt of
           it) must show text there. Columns are placed from the scenario's
           layout.json and the summed camera dx; the text's extent in the
           column comes from a frame where the column rests on screen.
  start    the first frame the camera moved, counted from the frame the key
           landed in (timing.json; without it the recorder's 0.15 s lead).

Usage: strip-scroll-check.py DIR [--scale 2] [--strip-left 240] [--json OUT]
DIR is the recorder's strip folder (DIR/left-1/frame-00000.jpg ...).
Exit status 1 when any check fails.
"""
import argparse, json, os, sys

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("dir")
parser.add_argument("--scale", type=float, default=2.0, help="pixels per window point in the frames")
parser.add_argument("--strip-left", type=float, default=None, help="the strip's left edge in window points (default: the layout's main pane)")
parser.add_argument("--json", default=None)
opts = parser.parse_args()
S = opts.scale
SCENARIOS = ["left-1", "left-2", "right-1", "right-2", "hidden-left-1", "hidden-right-1"]


def frames_of(directory):
    names = sorted(n for n in os.listdir(directory) if n.startswith("frame-") and n.endswith(".jpg"))
    return [np.asarray(Image.open(os.path.join(directory, n)).convert("L"), dtype=np.int16) for n in names]


def load_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def panes_of(layout):
    windows = ((layout or {}).get("pane_chrome") or {}).get("windows") or []
    return windows[0] if windows else {}


def camera_dx(a, b, x0, x1, y0, y1, search):
    """Integer pixel shift d that best maps frame a's prompt text onto frame b's (b[x] ~ a[x - d]):
    the highest overlap (IoU) of the two frames' text masks. None when they share too little text."""
    mask_a, mask_b = a[y0:y1, x0:x1] > 120, b[y0:y1, x0:x1] > 120
    if not mask_a.any() or not mask_b.any():
        return None
    width = x1 - x0
    best, best_d = 0.0, None
    for d in range(-search, search + 1):
        if abs(d) >= width:
            continue
        if d >= 0:
            sa, sb = mask_a[:, :width - d], mask_b[:, d:]
        else:
            sa, sb = mask_a[:, -d:], mask_b[:, :width + d]
        inter = (sa & sb).sum()
        if inter < 60:
            continue
        iou = inter / (sa | sb).sum()
        if iou > best:
            best, best_d = iou, d
    return best_d if best >= 0.5 else None


def pill_vote(prev, cur, x0, x1, sign, limit):
    """The shift most on-screen pill edges agree on (within 2 px), from (lefts, rights) of two
    frames; only shifts in the scroll's direction (`sign`) up to `limit` pixels."""
    best, best_d = 0, None
    for kind in (0, 1):
        for p in prev[kind]:
            for c in cur[kind]:
                d = c - p
                if d * sign <= 0 or abs(d) > limit:
                    continue
                votes = sum(1 for k in (0, 1) for e in cur[k] if x0 + 3 < e < x1 - 3
                            and any(abs(e - d - q) <= 2 for q in prev[k]))
                if votes > best:
                    best, best_d = votes, d
    return best_d


def pill_edges(frame, y, x0, x1):
    """Left and right edges (pixels) of the light pill runs on row y between x0 and x1."""
    row = frame[y, :]
    on = row > 48
    lefts, rights = [], []
    x = x0
    while x < x1:
        if on[x]:
            start = x
            while x < x1 and on[x]:
                x += 1
            if x - start >= 16:
                lefts.append(start)
                rights.append(x)
        x += 1
    return lefts, rights


def check(directory, layout, lead, sign):
    frames = frames_of(directory)
    times = (load_json(os.path.join(directory, "frames.json")) or {}).get("times") or []
    timing = load_json(os.path.join(directory, "timing.json"))
    window = panes_of(layout)
    main = window.get("main_pane") or [240, 0, 860, 720]
    left_pt = opts.strip_left if opts.strip_left is not None else main[0]
    right_pt = main[0] + main[2]
    x0, x1 = int(round(left_pt * S)) + 2, int(round(right_pt * S)) - 2
    h = frames[0].shape[0]
    # The prompt line (first cell row) and the pill row (above the tab titles).
    prompt_y0, prompt_y1 = int(38 * S), int(58 * S)
    pill_y = int(7 * S)
    cams = [0.0]
    sources = ["rest"]
    for i in range(1, len(frames)):
        d = camera_dx(frames[i - 1], frames[i], x0, x1, prompt_y0, prompt_y1, int(450 * S))
        source = "text"
        if d is None:
            # No shared prompt text (it is cut by the strip's edge): the pills' consensus.
            d = pill_vote(pill_edges(frames[i - 1], pill_y, x0, x1), pill_edges(frames[i], pill_y, x0, x1), x0, x1,
                          sign, int(450 * S))
            source = "pills"
        if d is None:
            d, source = 0, "none"
        cams.append(d / S)
        sources.append(source)
    # Pills: every on-screen edge moves by the camera dx.
    pill_fail = []
    for i in range(1, len(frames)):
        dx_px = cams[i] * S
        prev_l, prev_r = pill_edges(frames[i - 1], pill_y, x0, x1)
        cur_l, cur_r = pill_edges(frames[i], pill_y, x0, x1)
        worst = 0.0
        for kind, cur, prev in (("left", cur_l, prev_l), ("right", cur_r, prev_r)):
            for e in cur:
                if e <= x0 + 3 or e >= x1 - 3:
                    continue
                expected = e - dx_px
                if expected <= x0 + 20 or expected >= x1 - 20:
                    continue  # cut, off screen or a sliver (under the 16 px run floor) in the previous frame
                miss = min((abs(p - expected) for p in prev), default=9999)
                worst = max(worst, miss / S)
        if worst > 0.5 + 1e-6:
            pill_fail.append((i, round(worst, 1)))
    # Blank: place columns from the layout and the summed camera. Each column's prompt text
    # extent comes from a frame where it rests fully on screen (the first or the last).
    panes = window.get("panes") or []
    cells = [p["cell"] for p in panes if p.get("cell")]
    total = sum(cams)
    blank = []
    unchecked = 0
    checked = 0
    for cell in cells:
        extent = None
        for frame, offset in ((frames[0], 0.0), (frames[-1], total)):
            cx = cell[0] + offset
            if cx >= left_pt - 6 and cx + cell[2] <= right_pt + 6:
                band = frame[prompt_y0:prompt_y1, max(0, int(cx * S)):int((cx + cell[2]) * S)]
                xs = np.nonzero((band > 120).any(axis=0))[0]
                if len(xs):
                    extent = (xs[0] / S + max(0, -cx), xs[-1] / S + max(0, -cx))
                break
        if extent is None:
            continue
        for i, frame in enumerate(frames):
            cx = cell[0] + sum(cams[1:i + 1])
            a = max(cx + extent[0], left_pt + 1)
            b = min(cx + extent[1], right_pt - 1)
            if b <= a:
                continue
            if b - a < 20:
                unchecked += 1
                continue
            checked += 1
            region = frame[prompt_y0:prompt_y1, int(a * S):int(b * S)]
            if (region > 120).sum() < 6:
                blank.append((i, round(cell[0], 0)))
    # Start: the first frame the camera moved, from the key's frame.
    if timing and times:
        key_t = timing["trigger_sent"] - timing["record_reply"]
        key_t_late = timing["trigger_reply"] - timing["record_reply"]
        assumed = False
    else:
        key_t, key_t_late, assumed = lead, lead + 0.01, True
    key_frame = next((i for i, t in enumerate(times) if t >= key_t), None)
    moved = next((i for i in range(1, len(cams)) if abs(cams[i]) >= 0.5), None)
    return {
        "frames": len(frames),
        "camera_pt": [round(c, 1) for c in cams],
        "camera_total_pt": round(total, 1),
        "camera_from_pills": [i for i, src in enumerate(sources) if src == "pills"],
        "camera_unmeasured": [i for i, src in enumerate(sources) if src == "none"],
        "pill_fail_frames": pill_fail,
        "blank_frames": blank,
        "blank_checked": checked,
        "blank_unchecked": unchecked,
        "key_time_s": [round(key_t, 4), round(key_t_late, 4)],
        "key_time_assumed": assumed,
        "key_frame": key_frame,
        "camera_first_frame": moved,
        "frames_to_motion": None if moved is None or key_frame is None else moved - key_frame,
        "ok": not pill_fail and not blank and moved is not None and key_frame is not None and moved - key_frame <= 2,
    }, total


def shifted(layout, total):
    """The next scenario's start layout when it has none: this one's moved by the camera."""
    window = json.loads(json.dumps(panes_of(layout)))
    for pane in window.get("panes") or []:
        if pane.get("cell"):
            pane["cell"][0] += total
    return {"pane_chrome": {"windows": [window]}}


report = {}
fallback = load_json(os.path.join(opts.dir, "layout.json"))
failed = False
for name in SCENARIOS:
    directory = os.path.join(opts.dir, name)
    if not os.path.isdir(directory):
        continue
    layout = load_json(os.path.join(directory, "layout.json")) or fallback
    result, total = check(directory, layout, lead=0.15, sign=1 if "left" in name else -1)
    result["layout"] = "scenario" if os.path.exists(os.path.join(directory, "layout.json")) else "chained"
    report[name] = result
    fallback = shifted(layout, total)
    failed = failed or not result["ok"]
    print(f"{name}: ok={result['ok']} frames={result['frames']} camera_total={result['camera_total_pt']}pt "
          f"start={result['frames_to_motion']} frames after the key (key frame {result['key_frame']}"
          f"{', assumed 0.15 s lead' if result['key_time_assumed'] else ''}) "
          f"pill_fail={result['pill_fail_frames']} camera_from_pills={result['camera_from_pills']} unmeasured={result['camera_unmeasured']} blank={result['blank_frames']} "
          f"(prompt checks {result['blank_checked']}, unchecked {result['blank_unchecked']}, layout {result['layout']})")
    print(f"  camera dx/frame (pt): {result['camera_pt']}")
if opts.json:
    with open(opts.json, "w") as handle:
        json.dump(report, handle, indent=1)
sys.exit(1 if failed else 0)
