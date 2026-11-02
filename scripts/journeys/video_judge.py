#!/usr/bin/env python3
"""Frame judge for real-app recordings of cmux layout motion (resize-videos kit, ext_video.py).

  video_judge.py BASE [BASE ...] [--json OUT.json] [--frames-dir DIR] [--markdown OUT.md] [--no-movie]

BASE is the common path of one recording (BASE.mov, BASE.mov.frames.json, BASE.mov.scan, BASE.trace.json,
BASE.events.json, BASE.meta.json; ext_video.py's docstring has the formats). The judge reads:
  - the scanlines (exact BGRA): geometry (edges, dividers, gaps, blends, jumps);
  - frames.json: pacing (one new complete frame per display refresh while something moves);
  - the trace (the app's model per display tick): what the app meant to show;
  - the movie (lossy HEVC): content only (blank, flash, stretch, reflow);
and writes one report per recording with findings. Library use: judge(base) -> dict, findings_markdown(reports).

Standard library + numpy + imageio_ffmpeg (for the ffmpeg binary). No opencv.
"""
from __future__ import annotations

import argparse
import bisect
import json
import re
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------------------------------------------
# Thresholds. Device pixels unless the name says otherwise.
# ---------------------------------------------------------------------------------------------------------------
DROP_FACTOR = 1.5          # an interval > 1.5 refreshes between complete frames in motion = dropped frames
CAPTURE_STALL_S = 0.050    # frames.json silent for this long (no entry at all) = a recorder stall
MOTION_JOIN_S = 0.050      # changed frames closer than this belong to one motion window
HID_LEAD_S = 0.020         # a HID action's span starts this long before t_sent
HID_TAIL_S = 0.300         # and ends this long after t_returned (the app may still settle)
MODEL_NEAR_S = 0.100       # a scanline change this close to model motion or HID counts as motion
REF_FRAMES = 5             # at-rest reference frames taken before and after each motion window
COMMIT_SLACK_S = 0.0005    # clock jitter allowed when picking the model sample a frame shows
COLOR_TOL = 3              # max channel difference for "the same color" in exact scanlines
TRACK_TOL = 6              # max channel difference to the divider's at-rest color while tracking it
TRACK_MAX_PX = 200         # a divider moves at most this far between two complete frames
MAX_DIVIDER_PX = 16        # a run wider than this is a pane, not a divider
BLEND_ALPHA = (0.15, 0.85)  # a pixel is a blend when it is a*left + (1-a)*right with a in this range
BLEND_MIN_DIFF = 12        # and differs from both neighbours by more than this in some channel
BLEND_RESID = 4            # and lies this close (max channel) to the straight blend line
EDGE_NEAR_PX = 4           # blends count only this close to an edge (the model's or a tracked divider's)
GAP_WINDOW_MIN_PX = 16     # half-width of the window around a divider searched for a gap
PALETTE_TOL = 8            # a color within this of an at-rest color near the divider is not new
REVERSAL_PX = 1            # a step against the drag direction larger than this is a jump back
JUMP_FACTOR = 3.0          # a step > 3x the local median step is a jump
JUMP_MIN_PX = 4            # and at least this many pixels
JUMP_LOCAL = 5             # steps on each side used for the local median
LAG_SEARCH = list(range(0, 13)) + [-1, -2, -3]  # model samples searched for the shown position, in order
MODEL_MATCH_PX = 1.0       # shown divider center within this of a model center = the same geometry
VISIBLE_ALPHA = 0.99       # model alpha from which a divider or pane must show
MOVIE_SCALE_DIV = 2        # the movie is decoded at 1/2 size for content checks
PANE_INSET_PT = 4          # content checks skip this border of each pane rect
MIN_PANE_PT = 20           # panes smaller than this are not judged for content
BLANK_FLAT = 0.97          # > 97% of a pane's pixels at one luminance = flat
FLAT_TOL = 6               # luminance levels around the mode that count as "one color" (lossy decode)
TEXT_STD = 4.0             # a reference pane with luminance std above this "has text"
FLASH_REL = 0.25           # a pane's mean luminance jumping by > 25% for 1-2 frames and back = flash
FLASH_FLOOR = 40.0         # ... measured against max(baseline, 40) so dark themes need >= 10 levels
SIZE_TOL_PT = 2.0          # content laid out more than 2 pt off its shown size = not at size
STALE_SAMPLES = 2          # ... for more than 2 model samples after the motion ends = defect
STRETCH_REL = 0.15         # text row period off the reference by > 15% = stretched
PERIOD_MIN_CORR = 0.30     # autocorrelation peak needed to trust a text row period
REFLOW_GRID = (24, 48)     # rows x columns of the binarized layout fingerprint
REFLOW_CHANGE = 0.04       # > 4% of fingerprint cells changed = a new layout
TEXT_LUMA_DIFF = 24        # luminance difference to the background that counts as ink in the fingerprint


def ffmpeg_exe():
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


# ---------------------------------------------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------------------------------------------
@dataclass
class Sample:
    """One trace sample: the app's model on one display tick."""
    t: float                 # host seconds
    panes: dict              # pane id -> list (see ext_video.py)
    dividers: dict           # divider id -> [id, x, y, w, h, alpha, z]


@dataclass
class Case:
    base: Path
    name: str
    build: str
    entries: list            # every frames.json entry [t, status, in_movie], sorted by t
    complete_t: np.ndarray   # display time (host s) of each complete frame
    in_movie: np.ndarray     # bool per complete frame
    t0: float                # display time of the first complete frame (movie PTS 0)
    period: float            # display refresh period, seconds
    scale: float             # device pixels per point
    width: int
    height: int
    rows: list               # scanline y positions (device px)
    columns: list            # scanline x positions (device px)
    row_px: np.ndarray       # (n complete, rows, width, 4) BGRA
    col_px: np.ndarray       # (n complete, columns, height, 4) BGRA
    has_scan: np.ndarray     # bool per complete frame: a scan record matched it
    scan_info: dict
    samples: list
    sample_t: list
    hid: list
    meta: dict
    movie: Path | None
    notes: list = field(default_factory=list)

    @property
    def n(self):
        return len(self.complete_t)

    def rel(self, i):
        return float(self.complete_t[i] - self.t0)


def _read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def read_scan(path):
    """Returns (header, records, trailing_bytes). records is a numpy structured array (t, rows, cols)."""
    raw = Path(path).read_bytes()
    newline = raw.index(b"\n")
    header = json.loads(raw[:newline])
    width, height = int(header["width"]), int(header["height"])
    rows, cols = list(header.get("rows") or []), list(header.get("columns") or [])
    fields = [("t", "<f8")]
    if rows:
        fields.append(("rows", "u1", (len(rows), width, 4)))
    if cols:
        fields.append(("cols", "u1", (len(cols), height, 4)))
    dtype = np.dtype(fields)
    body = memoryview(raw)[newline + 1:]
    count = len(body) // dtype.itemsize
    records = np.frombuffer(body, dtype=dtype, count=count)
    return header, records, len(body) - count * dtype.itemsize


def _parse_samples(trace):
    t0 = float(trace.get("t0_s") or 0.0)
    samples = []
    for s in trace.get("samples") or []:
        panes = {p[0]: p for p in s.get("panes") or [] if isinstance(p, list) and len(p) >= 5}
        dividers = {d[0]: d for d in s.get("dividers") or [] if isinstance(d, list) and len(d) >= 5}
        samples.append(Sample(t0 + float(s.get("t", 0.0)) / 1000.0, panes, dividers))
    samples.sort(key=lambda s: s.t)
    return samples


def _refresh_period(trace, entries):
    ms = (trace or {}).get("refresh_ms")
    if ms:
        return float(ms) / 1000.0
    times = np.array(sorted(e[0] for e in entries), dtype=float)
    deltas = np.diff(times)
    deltas = deltas[deltas > 0]
    return float(np.median(deltas)) if len(deltas) else 1 / 60


def base_path(base):
    """Accepts BASE or BASE.mov or any of its side files."""
    text = str(base)
    for suffix in (".mov.frames.json", ".mov.scan", ".trace.json", ".events.json", ".meta.json", ".mov"):
        if text.endswith(suffix):
            return Path(text[: -len(suffix)])
    return Path(text)


def load_case(base):
    base = base_path(base)
    frames_doc = _read_json(f"{base}.mov.frames.json", {}) or {}
    entries = sorted(([float(e[0]), str(e[1]), bool(e[2]) if len(e) > 2 else True]
                      for e in frames_doc.get("frames") or []), key=lambda e: e[0])
    complete = [e for e in entries if e[1] == "complete"]
    complete_t = np.array([e[0] for e in complete], dtype=float)
    in_movie = np.array([e[2] for e in complete], dtype=bool)
    trace = _read_json(f"{base}.trace.json", {}) or {}
    meta = _read_json(f"{base}.meta.json", {}) or {}
    events = _read_json(f"{base}.events.json", {}) or {}
    start = meta.get("start") or {}
    scale = float(start.get("scale") or 2.0)
    samples = _parse_samples(trace)
    case = Case(base=base, name=base.name, build=base.parent.name, entries=entries, complete_t=complete_t,
                in_movie=in_movie, t0=float(complete_t[0]) if len(complete_t) else 0.0,
                period=_refresh_period(trace, entries), scale=scale,
                width=int(frames_doc.get("width") or start.get("width") or 0),
                height=int(frames_doc.get("height") or start.get("height") or 0),
                rows=[], columns=[], row_px=np.zeros((len(complete_t), 0, 0, 4), np.uint8),
                col_px=np.zeros((len(complete_t), 0, 0, 4), np.uint8), has_scan=np.zeros(len(complete_t), bool),
                scan_info={}, samples=samples, sample_t=[s.t for s in samples], hid=list(events.get("hid") or []),
                meta=meta, movie=Path(f"{base}.mov") if Path(f"{base}.mov").is_file() else None)
    _attach_scan(case, Path(f"{base}.mov.scan"))
    return case


def _attach_scan(case, path):
    """Matches each scan record to its complete frame by time and stores the scanlines per complete frame."""
    if not path.is_file():
        case.scan_info = {"records": 0, "missing": True}
        case.notes.append("no scan file: geometry checks skipped")
        return
    header, records, trailing = read_scan(path)
    case.width = case.width or int(header["width"])
    case.height = case.height or int(header["height"])
    case.rows, case.columns = list(header.get("rows") or []), list(header.get("columns") or [])
    n, w, h = case.n, int(header["width"]), int(header["height"])
    case.row_px = np.zeros((n, len(case.rows), w, 4), np.uint8)
    case.col_px = np.zeros((n, len(case.columns), h, 4), np.uint8)
    unmatched = 0
    for k in range(len(records)):
        i = _nearest(case.complete_t, float(records["t"][k]), 0.001)
        if i is None or case.has_scan[i]:
            unmatched += 1
            continue
        case.has_scan[i] = True
        if case.rows:
            case.row_px[i] = records["rows"][k]
        if case.columns:
            case.col_px[i] = records["cols"][k]
    case.scan_info = {"records": int(len(records)), "unmatched": unmatched, "trailing_bytes": int(trailing)}


def _nearest(sorted_t, t, tol):
    """Index of the value of sorted_t nearest t, or None when it is farther than tol."""
    if len(sorted_t) == 0:
        return None
    j = int(np.searchsorted(sorted_t, t))
    best = min((k for k in (j - 1, j) if 0 <= k < len(sorted_t)), key=lambda k: abs(sorted_t[k] - t))
    return best if abs(sorted_t[best] - t) <= tol else None


def committed_sample(case, t):
    """The model sample a frame displayed at t shows: the latest one at or before t - one refresh."""
    k = bisect.bisect_right(case.sample_t, t - case.period + COMMIT_SLACK_S) - 1
    return k if k >= 0 else (0 if case.samples else None)


# ---------------------------------------------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------------------------------------------
def finding(case, check, first, last, detail, severity="defect"):
    first, last = int(first), int(last)
    return {"case": case.name, "check": check, "frames": [first, last],
            "t": [round(case.rel(first), 4), round(case.rel(last), 4)], "detail": detail, "severity": severity}


def frame_runs(indices):
    """[3, 4, 5, 9] -> [(3, 5), (9, 9)]."""
    out = []
    for i in sorted(set(int(i) for i in indices)):
        if out and i == out[-1][1] + 1:
            out[-1][1] = i
        else:
            out.append([i, i])
    return [tuple(r) for r in out]


def grouped_findings(case, check, hits, what, severity="defect"):
    """hits: frame index -> list of detail strings. One finding per run of consecutive frames."""
    out = []
    for first, last in frame_runs(hits):
        examples = hits[first][:3]
        count = last - first + 1
        out.append(finding(case, check, first, last,
                           f"{what} in {count} frame{'s' if count > 1 else ''}; first: {'; '.join(examples)}",
                           severity))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Motion windows
# ---------------------------------------------------------------------------------------------------------------
@dataclass
class Window:
    a: int                   # first complete frame that differs from its predecessor
    b: int                   # last one
    pre: list                # at-rest reference frames before
    post: list               # at-rest reference frames after (b is the final state)


def _geometry_key(sample):
    panes = tuple(sorted((k, tuple(round(float(v), 2) for v in p[1:6])) for k, p in sample.panes.items()))
    divs = tuple(sorted((k, tuple(round(float(v), 2) for v in d[1:6])) for k, d in sample.dividers.items()))
    return panes, divs


def model_motion_times(case):
    """Host times of the trace samples whose pane or divider geometry differs from the sample before."""
    times, prev = [], None
    for s in case.samples:
        key = _geometry_key(s)
        if prev is not None and key != prev:
            times.append(s.t)
        prev = key
    return times


def hid_spans(case):
    spans = []
    for h in case.hid:
        try:
            spans.append((float(h["t_sent"]) - HID_LEAD_S, float(h["t_returned"]) + HID_TAIL_S))
        except (KeyError, TypeError, ValueError):
            continue
    return spans


def scan_changed(case):
    """changed[i]: complete frame i's scanlines differ from frame i-1's (both scanned)."""
    n = case.n
    changed = np.zeros(n, bool)
    if n < 2:
        return changed
    both = case.has_scan[1:] & case.has_scan[:-1]
    diff = np.zeros(n - 1, bool)
    if case.row_px.shape[1]:
        diff |= (case.row_px[1:] != case.row_px[:-1]).reshape(n - 1, -1).any(1)
    if case.col_px.shape[1]:
        diff |= (case.col_px[1:] != case.col_px[:-1]).reshape(n - 1, -1).any(1)
    changed[1:] = diff & both
    return changed


def motion_windows(case):
    """Spans of changed frames that belong to the app's motion (HID input or model geometry change)."""
    changed = np.flatnonzero(scan_changed(case))
    if len(changed) == 0:
        return []
    t = case.complete_t
    spans, model_t = hid_spans(case), np.array(model_motion_times(case))

    def covered(t1, t2):
        if any(s0 <= t1 and t2 <= s1 for s0, s1 in spans):
            return True
        return bool(len(model_t)) and bool(((model_t > t1 - case.period) & (model_t < t2)).any())

    groups = [[changed[0], changed[0]]]
    for i in changed[1:]:
        last = groups[-1][1]
        if t[i] - t[last] <= MOTION_JOIN_S or covered(t[last], t[i]):
            groups[-1][1] = i
        else:
            groups.append([i, i])

    def near_motion(a, b):
        lo, hi = t[a] - MODEL_NEAR_S, t[b] + MODEL_NEAR_S
        if any(s0 <= hi and lo <= s1 for s0, s1 in spans):
            return True
        return bool(len(model_t)) and bool(((model_t >= lo - case.period) & (model_t <= hi)).any())

    if spans or len(model_t):
        groups = [g for g in groups if near_motion(*g)]
    else:
        groups = [g for g in groups if int(changed[(changed >= g[0]) & (changed <= g[1])].size) >= 3]
    windows = []
    for k, (a, b) in enumerate(groups):
        lo = groups[k - 1][1] + 1 if k else 0
        hi = groups[k + 1][0] - 1 if k + 1 < len(groups) else case.n - 1
        pre = [i for i in range(max(lo, a - REF_FRAMES), a) if case.has_scan[i]]
        post = [i for i in range(b, min(hi, b + REF_FRAMES - 1) + 1) if case.has_scan[i]]
        windows.append(Window(int(a), int(b), pre or ([0] if case.has_scan[0] else []), post))
    return windows


# ---------------------------------------------------------------------------------------------------------------
# A. Pacing
# ---------------------------------------------------------------------------------------------------------------
def check_pacing(case, windows):
    """Every refresh in motion should bring a new complete frame. Returns (findings, intervals_ms, dropped)."""
    findings, intervals, dropped = [], [], 0
    all_t = [e[0] for e in case.entries]
    p = case.period
    for w in windows:
        flagged = set()
        for i in range(w.a, w.b):
            t1, t2 = case.complete_t[i], case.complete_t[i + 1]
            gap = t2 - t1
            intervals.append(gap * 1000.0)
            if gap <= DROP_FACTOR * p:
                continue
            between = case.entries[bisect.bisect_right(all_t, t1):bisect.bisect_left(all_t, t2)]
            idle = sum(1 for e in between if e[1] == "idle")
            missed = max(1, round(gap / p) - 1)
            flagged.update(id(e) for e in between)
            if not between and gap > CAPTURE_STALL_S:
                findings.append(finding(case, "capture stall in motion", i, i + 1,
                                        f"no frames.json entry for {gap * 1000:.1f} ms during motion "
                                        f"({missed} refreshes): the recorder, not the app", "recorder"))
                continue
            dropped += missed
            findings.append(finding(case, "dropped frames", i, i + 1,
                                    f"{missed} refresh{'es' if missed > 1 else ''} without a new frame during motion "
                                    f"({gap * 1000:.1f} ms between frames, {idle} idle)"))
        t_a, t_b = case.complete_t[w.a], case.complete_t[w.b]
        for e in case.entries:
            if e[1] == "idle" and t_a < e[0] < t_b and id(e) not in flagged:
                i = int(np.searchsorted(case.complete_t, e[0])) - 1
                findings.append(finding(case, "idle refresh in motion", i, i + 1,
                                        "the window server composited nothing new for one refresh during motion"))
    return findings, intervals, dropped


def interval_stats(intervals, period):
    if not intervals:
        return {"p50": None, "p95": None, "p99": None, "max": None, "hist": {}}
    arr = np.array(intervals)
    hist = {}
    for v in arr:
        key = str(max(1, int(round(v / (period * 1000.0)))))
        hist[key] = hist.get(key, 0) + 1
    hist = dict(sorted(hist.items(), key=lambda kv: int(kv[0])))
    pct = lambda q: round(float(np.percentile(arr, q)), 3)  # noqa: E731
    return {"p50": pct(50), "p95": pct(95), "p99": pct(99), "max": round(float(arr.max()), 3), "hist": hist}


# ---------------------------------------------------------------------------------------------------------------
# B. Geometry from the exact scanlines
# ---------------------------------------------------------------------------------------------------------------
@dataclass
class Line:
    axis: str                # "row" (horizontal scanline at y: finds vertical dividers) or "col"
    coord: int               # y (row) or x (col), device px
    px: np.ndarray           # (n complete, length, 4) BGRA


def scan_lines(case):
    lines = [Line("row", int(y), case.row_px[:, r]) for r, y in enumerate(case.rows)]
    lines += [Line("col", int(x), case.col_px[:, c]) for c, x in enumerate(case.columns)]
    return lines


def _along(rect, axis):
    """(start, length) of an [.., x, y, w, h, ..] rect along the line's axis, in points."""
    return (float(rect[1]), float(rect[3])) if axis == "row" else (float(rect[2]), float(rect[4]))


def _crosses(rect, axis, coord_pt):
    start, length = (float(rect[2]), float(rect[4])) if axis == "row" else (float(rect[1]), float(rect[3]))
    return start <= coord_pt < start + length


def _divider_fits(d, axis):
    """Vertical dividers cross rows; horizontal ones cross columns."""
    vertical = float(d[4]) > float(d[3])
    return vertical if axis == "row" else not vertical


def _visible(rect):
    alpha = float(rect[5]) if len(rect) > 5 else 1.0
    return alpha >= VISIBLE_ALPHA and float(rect[3]) > 0 and float(rect[4]) > 0


def _runs(mask):
    """(starts, ends) of the True runs of a 1-D bool array; ends are exclusive."""
    m = np.concatenate(([0], mask.astype(np.int8), [0]))
    d = np.diff(m)
    return np.flatnonzero(d == 1), np.flatnonzero(d == -1)


def _run_around(line16, px, tol):
    """[r0, r1) of the run of pixels within tol of line16[px]."""
    same = np.abs(line16 - line16[px]).max(-1) <= tol
    left = np.flatnonzero(~same[:px])
    right = np.flatnonzero(~same[px:])
    return (int(left[-1]) + 1 if len(left) else 0), (px + int(right[0]) if len(right) else len(line16))


def _flat_runs(seg16, tol=COLOR_TOL):
    if len(seg16) == 0:
        return np.array([], int), np.array([], int)
    breaks = np.flatnonzero(np.abs(np.diff(seg16, axis=0)).max(-1) > tol) + 1
    starts = np.concatenate(([0], breaks))
    return starts, np.concatenate((breaks, [len(seg16)]))


def blend_mask(lines):
    """(..., L, 4) BGRA -> (..., L) bool: pixel is a linear blend of its two neighbours and differs from both."""
    c = lines[..., :3].astype(np.float32)
    a, p, b = c[..., :-2, :], c[..., 1:-1, :], c[..., 2:, :]
    d = a - b
    denom = (d * d).sum(-1)
    with np.errstate(divide="ignore", invalid="ignore"):
        alpha = ((p - b) * d).sum(-1) / denom
        resid = np.abs(p - (b + alpha[..., None] * d)).max(-1)
    ok = ((denom > 0) & (alpha >= BLEND_ALPHA[0]) & (alpha <= BLEND_ALPHA[1])
          & (resid <= np.maximum(BLEND_RESID, 0.08 * np.abs(d).max(-1)))
          & (np.abs(p - a).max(-1) > BLEND_MIN_DIFF) & (np.abs(p - b).max(-1) > BLEND_MIN_DIFF))
    out = np.zeros(lines.shape[:-1], bool)
    out[..., 1:-1] = ok
    return out


@dataclass
class Track:
    """One divider followed along one scanline through one motion window."""
    line: Line
    div_id: object           # model divider id, or a pixel-seeded label
    color: np.ndarray        # at-rest color (int16 BGRA)
    width: int               # at-rest run width
    ref_pos: float           # at-rest run center
    window: Window
    pos: dict = field(default_factory=dict)      # frame -> run center (device px) or None
    bounds: dict = field(default_factory=dict)   # frame -> (start, end)
    expect: dict = field(default_factory=dict)   # frame -> model center or None
    palette: np.ndarray | None = None

    def label(self):
        return f"divider {self.div_id} on {self.line.axis} {self.line.coord}"


def model_center(case, k, div_id, axis, coord_pt):
    """Center (device px) of divider div_id along the axis in sample k, or None when it does not show there."""
    if k is None or not (0 <= k < len(case.samples)):
        return None
    d = case.samples[k].dividers.get(div_id)
    if d is None or not _visible(d) or not _crosses(d, axis, coord_pt):
        return None
    start, length = _along(d, axis)
    return (start + length / 2) * case.scale


def _seed_model_tracks(case, line, window):
    coord_pt = line.coord / case.scale
    ids = []
    for f in window.pre + window.post + [window.a, window.b]:
        k = committed_sample(case, case.complete_t[f])
        if k is None:
            continue
        for did, d in case.samples[k].dividers.items():
            if did not in ids and _divider_fits(d, line.axis):
                ids.append(did)
    tracks = []
    for did in ids:
        for f in window.pre + window.post:
            center = model_center(case, committed_sample(case, case.complete_t[f]), did, line.axis, coord_pt)
            if center is None:
                continue
            row16 = line.px[f].astype(np.int16)
            px = min(max(int(center), 0), len(row16) - 1)
            r0, r1 = _run_around(row16, px, COLOR_TOL)
            if r1 - r0 <= MAX_DIVIDER_PX:
                tracks.append(Track(line, did, row16[px].copy(), r1 - r0, (r0 + r1) / 2, window))
            break
    return tracks


def _seed_pixel_tracks(case, line, window):
    """No model dividers: a narrow run between two long runs of other colors is a divider."""
    if not window.pre:
        return []
    f = window.pre[-1]
    row16 = line.px[f].astype(np.int16)
    starts, ends = _flat_runs(row16)
    tracks = []
    for k in range(1, len(starts) - 1):
        width = ends[k] - starts[k]
        if width <= MAX_DIVIDER_PX and ends[k - 1] - starts[k - 1] >= 32 and ends[k + 1] - starts[k + 1] >= 32:
            center = (starts[k] + ends[k]) / 2
            tracks.append(Track(line, f"px{int(center)}", row16[starts[k]].copy(), int(width), center, window))
    return tracks


def _follow(case, track, frames):
    """Finds the divider's run in every frame: the run of its color, about its width, nearest the model."""
    coord_pt = track.line.coord / case.scale
    prev = track.ref_pos
    for f in frames:
        k = committed_sample(case, case.complete_t[f])
        exp = model_center(case, k, track.div_id, track.line.axis, coord_pt) if case.samples else None
        track.expect[f] = exp
        row16 = track.line.px[f].astype(np.int16)
        starts, ends = _runs(np.abs(row16 - track.color).max(-1) <= TRACK_TOL)
        lengths = ends - starts
        ok = (lengths >= max(1, track.width - 2)) & (lengths <= track.width + 2)
        starts, ends = starts[ok], ends[ok]
        track.pos[f] = None
        if len(starts) == 0:
            continue
        centers = (starts + ends) / 2
        aim = exp if exp is not None else prev
        j = int(np.argmin(np.abs(centers - aim)))
        if abs(centers[j] - (prev if prev is not None else aim)) <= TRACK_MAX_PX:
            track.pos[f], track.bounds[f] = float(centers[j]), (int(starts[j]), int(ends[j]))
            prev = float(centers[j])


def _gap_half_width(track):
    return max(GAP_WINDOW_MIN_PX, 4 * track.width)


def _window_slice(track, center):
    half = _gap_half_width(track)
    length = track.line.px.shape[1]
    return max(0, int(center - half)), min(length, int(center + half) + 1)


def _palette(track):
    """Colors near the divider in the at-rest frames before and after the motion."""
    parts = []
    for f in track.window.pre + track.window.post:
        center = track.pos.get(f)
        if center is None:
            continue
        lo, hi = _window_slice(track, center)
        parts.append(track.line.px[f, lo:hi].astype(np.int16))
    if not parts:
        return np.zeros((0, 4), np.int16)
    return np.unique(np.concatenate(parts), axis=0)


def build_tracks(case, windows):
    tracks = []
    for window in windows:
        frames = sorted(set(window.pre + list(range(window.a, window.b + 1)) + window.post))
        frames = [f for f in frames if case.has_scan[f]]
        for line in scan_lines(case):
            seeded = _seed_model_tracks(case, line, window) if case.samples else []
            if not case.samples:
                seeded = _seed_pixel_tracks(case, line, window)
            for track in seeded:
                _follow(case, track, frames)
                track.palette = _palette(track)
                tracks.append(track)
    return tracks


def _edge_mask(case, line, f, tracks, length):
    """Positions near an edge in frame f: model pane/divider edges of nearby samples and tracked divider runs."""
    marks = np.zeros(length, bool)
    coord_pt = line.coord / case.scale
    k0 = committed_sample(case, case.complete_t[f])
    if k0 is not None:
        for k in range(max(0, k0 - 3), min(len(case.samples), k0 + 2)):
            s = case.samples[k]
            for rect in list(s.panes.values()) + list(s.dividers.values()):
                if _crosses(rect, line.axis, coord_pt):
                    start, size = _along(rect, line.axis)
                    for e in (start * case.scale, (start + size) * case.scale):
                        if 0 <= e < length:
                            marks[int(e)] = True
    for track in tracks:
        if track.line is line and f in track.bounds:
            s, e = track.bounds[f]
            marks[min(s, length - 1)] = marks[min(e, length - 1)] = True
    if not marks.any():
        return marks
    kernel = np.ones(2 * EDGE_NEAR_PX + 1, bool)
    return np.convolve(marks, kernel, mode="same") > 0


def check_blends(case, windows, tracks):
    """B1: new half-pixel blends on an edge during motion (absent from the at-rest reference frames)."""
    hits = {}
    use_edges = bool(case.samples) or bool(tracks)
    for window in windows:
        frames = [f for f in range(window.a, window.b + 1) if case.has_scan[f]]
        refs = window.pre + window.post
        if not frames or not refs:
            continue
        for line in scan_lines(case):
            ref_blends = blend_mask(line.px[refs]).any(0)
            masks = blend_mask(line.px[frames]) & ~ref_blends
            for f, mask in zip(frames, masks):
                if not mask.any():
                    continue
                if use_edges:
                    mask = mask & _edge_mask(case, line, f, tracks, len(mask))
                where = np.flatnonzero(mask)
                if len(where):
                    hits.setdefault(f, []).append(f"{line.axis} {line.coord} at {where[:4].tolist()}")
    return grouped_findings(case, "half-pixel blend", hits,
                            "edge off the device-pixel grid (a blended pixel absent at rest)")


def check_gaps(case, tracks):
    """B2: a run of a new color (background, black, transparent) wider than the divider beside it."""
    gaps, missing = {}, {}
    for track in tracks:
        prev = track.ref_pos
        for f in range(track.window.a, track.window.b + 1):
            if f not in track.pos:
                continue
            center = track.pos[f]
            if center is None:
                if track.expect.get(f) is not None:
                    missing.setdefault(f, []).append(f"{track.label()} near {round(prev, 1)}")
                center = track.expect.get(f) if track.expect.get(f) is not None else prev
            else:
                prev = center
            lo, hi = _window_slice(track, center)
            seg = track.line.px[f, lo:hi].astype(np.int16)
            starts, ends = _flat_runs(seg)
            for s, e in zip(starts, ends):
                if e - s <= track.width + 1:
                    continue
                if len(track.palette) and np.abs(track.palette - seg[s]).max(-1).min() <= PALETTE_TOL:
                    continue
                bgra = seg[s].tolist()
                gaps.setdefault(f, []).append(f"{track.label()}: {e - s} px of BGRA {bgra} at {lo + s}")
    out = grouped_findings(case, "gap or overlap", gaps,
                           "a band of a color absent at rest, wider than the divider, between panes")
    out += grouped_findings(case, "divider not shown", missing,
                            "the model shows a divider but the frame has none (covered or gapped)")
    return out


def _drag_direction(case, axis, t):
    """+1/-1 along the axis for a drag active at host time t, 0 for a drag across it, None without a drag."""
    for h in case.hid:
        if h.get("kind") != "drag":
            continue
        args = h.get("args") or {}
        try:
            active = float(h["t_sent"]) - HID_LEAD_S <= t <= float(h["t_returned"]) + HID_TAIL_S
        except (KeyError, TypeError, ValueError):
            continue
        if not active:
            continue
        src = args.get("window_from") or [args.get("from_x", 0), args.get("from_y", 0)]
        dst = args.get("window_to") or [args.get("to_x", 0), args.get("to_y", 0)]
        delta = float(dst[0]) - float(src[0]) if axis == "row" else float(dst[1]) - float(src[1])
        return int(np.sign(delta))
    return None


def check_steps(case, tracks):
    """B3: a divider must move with the drag (no reversal > 1 px) and without jumps (> 3x the local median step)."""
    back, back_anim, jumps = {}, {}, {}
    for track in tracks:
        frames = [f for f in range(track.window.a, track.window.b + 1) if track.pos.get(f) is not None]
        if track.window.pre and track.pos.get(track.window.pre[-1]) is not None:
            frames = [track.window.pre[-1]] + frames
        if len(frames) < 2:
            continue
        pos = np.array([track.pos[f] for f in frames])
        if abs(pos[-1] - pos[0]) <= 2 and np.ptp(pos) <= 2:
            continue  # this divider did not move
        steps = np.diff(pos)
        net = int(np.sign(pos[-1] - pos[0]))
        nonzero_all = np.abs(steps[steps != 0])
        for j, step in enumerate(steps):
            f = frames[j + 1]
            drag = _drag_direction(case, track.line.axis, case.complete_t[f])
            direction = drag if drag else net
            if direction and step * direction < -REVERSAL_PX:
                where = back if drag else back_anim
                where.setdefault(f, []).append(f"{track.label()} moved {step:+.1f} px against the "
                                               f"{'drag' if drag else 'motion'} ({pos[j]:.1f} -> {pos[j + 1]:.1f})")
            local = np.abs(np.concatenate((steps[max(0, j - JUMP_LOCAL):j], steps[j + 1:j + 1 + JUMP_LOCAL])))
            local = local[local != 0]
            if not len(local):
                local = nonzero_all
            median = float(np.median(local)) if len(local) else 0.0
            if abs(step) > max(JUMP_MIN_PX, JUMP_FACTOR * median):
                jumps.setdefault(f, []).append(f"{track.label()} jumped {step:+.1f} px (local median step "
                                               f"{median:.1f} px)")
    out = grouped_findings(case, "jump back", back, "a divider moved back against the drag")
    out += grouped_findings(case, "jump back (animation)", back_anim,
                            "a divider moved against its net motion (no drag active)", "note")
    out += grouped_findings(case, "jump", jumps, "a divider step far above its neighbours' steps")
    return out


# ---------------------------------------------------------------------------------------------------------------
# C. Model vs shown
# ---------------------------------------------------------------------------------------------------------------
def check_model(case, tracks):
    """Lag (in model samples) between the shown divider and the model; frames whose geometry is in no sample."""
    lags, hits, seen = {}, {}, set()
    if not case.samples:
        return [], {}
    for track in tracks:
        if isinstance(track.div_id, str) and str(track.div_id).startswith("px"):
            continue
        coord_pt = track.line.coord / case.scale
        for f in range(track.window.a, track.window.b + 1):
            shown = track.pos.get(f)
            if shown is None or (f, track.div_id) in seen:
                continue
            k0 = committed_sample(case, case.complete_t[f])
            lag = None
            for n in LAG_SEARCH:
                center = model_center(case, k0 - n, track.div_id, track.line.axis, coord_pt)
                if center is not None and abs(center - shown) <= MODEL_MATCH_PX:
                    lag = n
                    break
            seen.add((f, track.div_id))
            if lag is None:
                exp = track.expect.get(f)
                hits.setdefault(f, []).append(f"{track.label()} shown at {shown:.1f} px, model "
                                              f"{'none' if exp is None else f'{exp:.1f}'} px")
            else:
                lags[str(lag)] = lags.get(str(lag), 0) + 1
    findings = grouped_findings(case, "shown geometry not in the model", hits,
                                "a divider position that no recent model sample had")
    return findings, dict(sorted(lags.items(), key=lambda kv: int(kv[0])))


# ---------------------------------------------------------------------------------------------------------------
# D3. Content laid-out size (from the trace)
# ---------------------------------------------------------------------------------------------------------------
def _content_offset(pane):
    """(shown - content) size of a pane in points, or None when the trace has no content size."""
    if len(pane) < 13:
        return None
    return float(pane[3]) - float(pane[11]), float(pane[4]) - float(pane[12])


def _rest_offsets(case):
    """Per pane: the (shown - content) offset at rest in the first sample (covers headers). New panes get the median."""
    first = case.samples[0].panes if case.samples else {}
    offsets = {pid: _content_offset(p) for pid, p in first.items() if _content_offset(p) is not None}
    if offsets:
        values = np.array(list(offsets.values()))
        fallback = (float(np.median(values[:, 0])), float(np.median(values[:, 1])))
    else:
        fallback = (0.0, 0.0)
    return offsets, fallback


def _frame_at_or_after(case, t):
    return min(int(np.searchsorted(case.complete_t, t - COMMIT_SLACK_S)), case.n - 1)


def check_content_size(case, windows):
    """Content not at its shown size: a note during motion, a defect > 2 samples after the motion ends."""
    if not case.samples:
        return []
    offsets, fallback = _rest_offsets(case)
    model_t = np.array(model_motion_times(case))
    out = []
    for k, w in enumerate(windows):
        t_a, t_b = case.complete_t[w.a], case.complete_t[w.b]
        moving = model_t[(model_t >= t_a - 0.5) & (model_t <= t_b + 0.5)] if len(model_t) else model_t
        t_end = float(moving.max()) if len(moving) else t_b
        t_next = case.complete_t[windows[k + 1].a] if k + 1 < len(windows) else float("inf")
        during, after = {}, {}
        for j, s in enumerate(case.samples):
            if s.t < t_a - case.period or s.t >= t_next:
                continue
            for pid, pane in s.panes.items():
                off = _content_offset(pane)
                if off is None or not _visible(pane):
                    continue
                ref = offsets.get(pid, fallback)
                if abs(off[0] - ref[0]) > SIZE_TOL_PT or abs(off[1] - ref[1]) > SIZE_TOL_PT:
                    (during if s.t <= t_end else after).setdefault(pid, []).append(j)
        for pid, js in during.items():
            p = case.samples[js[0]].panes[pid]
            out.append(finding(case, "content size during motion", w.a, w.b,
                               f"pane {pid}: content laid out at {p[11]:.1f}x{p[12]:.1f} pt while shown "
                               f"{p[3]:.1f}x{p[4]:.1f} pt in {len(js)} model samples (expected for a scaled "
                               "snapshot)", "note"))
        for pid, js in after.items():
            for r0, r1 in frame_runs(js):
                if r1 - r0 + 1 <= STALE_SAMPLES:
                    continue
                p = case.samples[r0].panes[pid]
                f0 = _frame_at_or_after(case, case.samples[r0].t + case.period)
                f1 = _frame_at_or_after(case, case.samples[r1].t + case.period)
                out.append(finding(case, "content not at final size after motion", f0, max(f0, f1),
                                   f"pane {pid}: content laid out at {p[11]:.1f}x{p[12]:.1f} pt but shown "
                                   f"{p[3]:.1f}x{p[4]:.1f} pt for {r1 - r0 + 1} model samples after the motion ended"))
    return out


# ---------------------------------------------------------------------------------------------------------------
# D. Content from the movie (lossy)
# ---------------------------------------------------------------------------------------------------------------
def _movie_index(case):
    ids = np.flatnonzero(case.in_movie)
    return ids, case.complete_t[ids] - case.t0


def _seek_start(case, first_complete):
    """A PTS a little before the movie frame of complete frame first_complete, after the one before it."""
    ids, rel = _movie_index(case)
    m = int(np.searchsorted(ids, first_complete))
    if m == 0:
        return None
    margin = min(case.period / 2, (rel[m] - rel[m - 1]) / 2)
    return float(rel[m] - margin)


def decode_frames(case, first, last, div=MOVIE_SCALE_DIV):
    """Yields (complete index, RGB uint8 array) for each movie frame of complete frames first..last.

    One ffmpeg process: input seek to just before the first frame, rawvideo rgb24 to a pipe, showinfo on stderr
    for each frame's PTS (used to map the frame back to its complete frame)."""
    ids, rel = _movie_index(case)
    wanted = ids[(ids >= first) & (ids <= last)]
    if case.movie is None or not len(wanted):
        return
    w, h = max(2, case.width // div), max(2, case.height // div)
    start = _seek_start(case, int(wanted[0]))
    cmd = [ffmpeg_exe(), "-nostdin", "-hide_banner", "-loglevel", "info"]
    if start is not None:
        cmd += ["-ss", f"{start:.6f}"]
    cmd += ["-copyts", "-i", str(case.movie), "-frames:v", str(len(wanted)), "-vf", f"scale={w}:{h},showinfo",
            "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    pts, cond, done = [], threading.Condition(), []

    def read_stderr():
        for raw in proc.stderr:
            m = re.search(rb"pts_time:\s*(-?[0-9.]+)", raw)
            if m and b"showinfo" in raw.lower():
                with cond:
                    pts.append(float(m.group(1)))
                    cond.notify_all()
        with cond:
            done.append(True)
            cond.notify_all()

    reader = threading.Thread(target=read_stderr, daemon=True)
    reader.start()
    size = w * h * 3
    try:
        for n in range(len(wanted)):
            buf = proc.stdout.read(size)
            if len(buf) < size:
                break
            with cond:
                cond.wait_for(lambda: len(pts) > n or done, timeout=10)
                t = pts[n] if len(pts) > n else None
            j = _nearest(rel, t, case.period / 2) if t is not None else None
            idx = int(ids[j]) if j is not None else int(wanted[n])
            yield idx, np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    finally:
        proc.stdout.close()
        proc.wait()
        reader.join(timeout=5)
        proc.stderr.close()


def _pane_rects(case, f, div):
    """pane id -> (x0, y0, x1, y1) in decoded pixels for the model the frame shows (inset, visible panes only)."""
    k = committed_sample(case, case.complete_t[f])
    if k is None:
        return {}
    factor = case.scale / div
    out = {}
    for pid, p in case.samples[k].panes.items():
        x, y, w, h = (float(v) for v in p[1:5])
        if not _visible(p) or w < MIN_PANE_PT or h < MIN_PANE_PT:
            continue
        out[pid] = (int((x + PANE_INSET_PT) * factor), int((y + PANE_INSET_PT) * factor),
                    int((x + w - PANE_INSET_PT) * factor), int((y + h - PANE_INSET_PT) * factor))
    return out


def _row_period(profile):
    """Dominant period (px) of a vertical luminance profile, or None when there is no clear one."""
    p = profile - profile.mean()
    n = len(p)
    if n < 16 or not p.any():
        return None
    spec = np.fft.rfft(p, 2 * n)
    ac = np.fft.irfft(spec * np.conj(spec))[:n]
    if ac[0] <= 0:
        return None
    ac = ac / ac[0]
    hi = min(n // 2, 160)
    lags = np.arange(3, hi)
    if not len(lags):
        return None
    peaks = [k for k in lags if ac[k] >= ac[k - 1] and ac[k] >= ac[k + 1] and ac[k] >= PERIOD_MIN_CORR]
    if not peaks:
        return None
    best = max(ac[k] for k in peaks)
    return float(next(k for k in peaks if ac[k] >= 0.9 * best))


def _fingerprint(luma, mode):
    """Binarized, block-averaged layout of a pane: which cells hold ink."""
    ink = (np.abs(luma - mode) > TEXT_LUMA_DIFF).astype(np.float32)
    rows, cols = min(REFLOW_GRID[0], ink.shape[0]), min(REFLOW_GRID[1], ink.shape[1])
    ri = (np.arange(rows) * ink.shape[0]) // rows
    ci = (np.arange(cols) * ink.shape[1]) // cols
    blocks = np.add.reduceat(np.add.reduceat(ink, ri, axis=0), ci, axis=1)
    counts = np.outer(np.diff(np.append(ri, ink.shape[0])), np.diff(np.append(ci, ink.shape[1])))
    return (blocks / counts) > 0.2


def pane_stats(luma):
    """Mean, std, flat fraction, mode, text row period and layout fingerprint of one pane crop."""
    lu8 = np.clip(luma, 0, 255).astype(np.uint8)
    hist = np.bincount(lu8.ravel(), minlength=256)
    mode = int(hist.argmax())
    flat = float(hist[max(0, mode - FLAT_TOL):mode + FLAT_TOL + 1].sum()) / max(1, lu8.size)
    return {"mean": float(luma.mean()), "std": float(luma.std()), "flat": flat, "mode": mode,
            "period": _row_period(luma.mean(axis=1)), "print": _fingerprint(luma, mode)}


def _luma(rgb):
    return rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114


def window_content(case, window, lo, hi, div=MOVIE_SCALE_DIV):
    """Per-frame pane stats for complete frames lo..hi: {frame: {pane: stats}} (streamed, frames not kept)."""
    stats = {}
    for f, rgb in decode_frames(case, lo, hi, div):
        per = {}
        for pid, (x0, y0, x1, y1) in _pane_rects(case, f, div).items():
            crop = rgb[max(0, y0):y1, max(0, x0):x1].astype(np.float32)
            if crop.shape[0] >= 8 and crop.shape[1] >= 8:
                per[pid] = pane_stats(_luma(crop))
        stats[f] = per
    return stats


def _reference(stats, frames, pid):
    vals = [stats[f][pid] for f in frames if f in stats and pid in stats[f]]
    if not vals:
        return None
    periods = [v["period"] for v in vals if v["period"]]
    return {"std": float(np.median([v["std"] for v in vals])), "flat": float(np.median([v["flat"] for v in vals])),
            "period": float(np.median(periods)) if periods else None}


def judge_content(case, window, stats):
    """D1 blank, D2 flash, D3 stretch (pixels), D4 reflow count, for one motion window."""
    blank, flash, stretch, reflow = {}, {}, {}, []
    frames = sorted(stats)
    pre = [f for f in frames if f < window.a]
    post = [f for f in frames if f >= window.b]
    judged = [f for f in frames if f >= window.a]
    panes = sorted({pid for f in frames for pid in stats[f]}, key=str)
    for pid in panes:
        ref = _reference(stats, pre, pid) or _reference(stats, post[-REF_FRAMES:], pid)
        if ref is None:
            continue
        has_text = ref["std"] > TEXT_STD and ref["flat"] < BLANK_FLAT
        series = [(f, stats[f][pid]) for f in frames if pid in stats[f]]
        blank_frames = set()
        for f, s in series:
            if f in judged and has_text and s["flat"] > BLANK_FLAT:
                blank_frames.add(f)
                blank.setdefault(f, []).append(f"pane {pid} {s['flat'] * 100:.1f}% flat (at rest "
                                               f"{ref['flat'] * 100:.1f}%)")
            if (f in judged and window.a <= f <= window.b and ref["period"] and s["period"]
                    and abs(s["period"] / ref["period"] - 1) > STRETCH_REL):
                stretch.setdefault(f, []).append(f"pane {pid} text rows every {s['period']:.1f} px, at rest "
                                                 f"{ref['period']:.1f} px")
        _find_flashes(series, judged, blank_frames, pid, flash)
        changes = _layout_changes(series, window)
        if changes:
            reflow.append({"pane": pid, "layouts": len(changes) + 1, "frames": changes})
    out = grouped_findings(case, "blank pane", blank, "a pane that had text shows one flat color")
    out += grouped_findings(case, "flash", flash, "a pane's brightness jumps for 1-2 frames and returns")
    out += grouped_findings(case, "content stretched", stretch, "text rows scaled against the at-rest text")
    for r in reflow:
        out.append(finding(case, "reflow", r["frames"][0], r["frames"][-1],
                           f"pane {r['pane']} shows {r['layouts']} text layouts during motion "
                           f"(changes at frames {r['frames'][:12]})", "note"))
    return out, reflow


def _find_flashes(series, judged, skip, pid, hits):
    means = [s["mean"] for _, s in series]
    for j in range(1, len(series)):
        f = series[j][0]
        if f not in judged or f in skip:
            continue
        base = means[j - 1]
        thr = FLASH_REL * max(base, FLASH_FLOOR)
        for length in (1, 2):
            if j + length >= len(series):
                break
            spike = means[j:j + length]
            signs = {np.sign(m - base) for m in spike}
            if all(abs(m - base) > thr for m in spike) and len(signs) == 1 and abs(means[j + length] - base) <= thr / 2:
                for k in range(j, j + length):
                    hits.setdefault(series[k][0], []).append(f"pane {pid} mean luminance {base:.0f} -> "
                                                             f"{means[k]:.0f}")
                break


def _layout_changes(series, window):
    changes, prev = [], None
    for f, s in series:
        if not window.a - 1 <= f <= window.b:
            continue
        fp = s["print"]
        if prev is not None and (prev.shape != fp.shape or float(np.mean(prev != fp)) > REFLOW_CHANGE):
            changes.append(f)
        prev = fp
    return changes


def check_movie(case, windows):
    """Content checks for every motion window, windows decoded in parallel."""
    if case.movie is None or not windows or not case.samples:
        return [], []

    def one(k):
        w = windows[k]
        lo = max(windows[k - 1].b + 1 if k else 0, w.a - REF_FRAMES)
        hi = min(windows[k + 1].a - 1 if k + 1 < len(windows) else case.n - 1, w.b + REF_FRAMES)
        return judge_content(case, w, window_content(case, w, lo, hi))

    findings, reflow = [], []
    with ThreadPoolExecutor(max_workers=min(8, len(windows))) as pool:
        for f, r in pool.map(one, range(len(windows))):
            findings += f
            reflow += r
    return findings, reflow


# ---------------------------------------------------------------------------------------------------------------
# E. Recorder faults
# ---------------------------------------------------------------------------------------------------------------
def check_recorder(case, windows):
    out = []
    dropped = np.flatnonzero(~case.in_movie)
    for a, b in frame_runs(dropped):
        out.append(finding(case, "encoder dropped frames", a, b,
                           f"{b - a + 1} complete frame(s) not in the movie (the encoder dropped them)", "recorder"))
    info = case.scan_info
    if info.get("records", 0) != case.n or info.get("unmatched") or info.get("trailing_bytes"):
        out.append(finding(case, "scan count mismatch", 0, max(0, case.n - 1),
                           f"{info.get('records', 0)} scan records for {case.n} complete frames "
                           f"({info.get('unmatched', 0)} unmatched, {info.get('trailing_bytes', 0)} trailing bytes)",
                           "recorder"))
    stalls, motion_stalls = 0, 0
    spans = [(case.complete_t[w.a], case.complete_t[w.b]) for w in windows] + hid_spans(case)
    times = [e[0] for e in case.entries]
    for t1, t2 in zip(times, times[1:]):
        if t2 - t1 <= CAPTURE_STALL_S:
            continue
        stalls += 1
        if not any(s0 < t2 and t1 < s1 for s0, s1 in spans):
            continue  # at rest the capture may legitimately be silent
        motion_stalls += 1
        i = max(0, int(np.searchsorted(case.complete_t, t1, side="right")) - 1)
        j = min(case.n - 1, int(np.searchsorted(case.complete_t, t2)))
        out.append(finding(case, "capture stall", i, j, f"frames.json silent for {(t2 - t1) * 1000:.1f} ms "
                                                        "around motion", "recorder"))
    statuses = {}
    for e in case.entries:
        statuses[e[1]] = statuses.get(e[1], 0) + 1
    recorder = {"complete": case.n, "in_movie_false": int(len(dropped)), "scan": info,
                "capture_gaps": stalls, "capture_gaps_in_motion": motion_stalls, "statuses": statuses}
    return out, recorder


# ---------------------------------------------------------------------------------------------------------------
# Judge, report, Markdown, PNGs
# ---------------------------------------------------------------------------------------------------------------
def judge(base, movie=True):
    """Judges one recording. Returns the report dict (see the module docstring and the README of the kit)."""
    case = load_case(base)
    if case.n == 0:
        return {"case": case.name, "build": case.build, "frames": 0, "refresh_ms": round(case.period * 1000, 3),
                "motion": [], "intervals_ms": interval_stats([], case.period), "dropped": 0, "findings": [],
                "recorder": {"complete": 0}, "notes": ["no complete frames"]}
    windows = motion_windows(case)
    pacing, intervals, dropped = check_pacing(case, windows)
    tracks = build_tracks(case, windows)
    findings = list(pacing)
    findings += check_blends(case, windows, tracks)
    findings += check_gaps(case, tracks)
    findings += check_steps(case, tracks)
    model_findings, lag = check_model(case, tracks)
    findings += model_findings
    findings += check_content_size(case, windows)
    reflow = []
    if movie:
        movie_findings, reflow = check_movie(case, windows)
        findings += movie_findings
    else:
        case.notes.append("movie checks skipped (--no-movie)")
    recorder_findings, recorder = check_recorder(case, windows)
    findings += recorder_findings
    findings.sort(key=lambda x: (x["frames"][0], x["check"]))
    return {"case": case.name, "build": case.build, "frames": case.n, "refresh_ms": round(case.period * 1000, 3),
            "motion": [[round(case.rel(w.a), 4), round(case.rel(w.b), 4)] for w in windows],
            "motion_frames": [[w.a, w.b] for w in windows], "intervals_ms": interval_stats(intervals, case.period),
            "dropped": dropped, "model_lag": lag, "tracked_dividers": len(tracks), "reflow": reflow,
            "findings": findings, "recorder": recorder, "notes": case.notes, "base": str(case.base)}


def _video_t(t):
    return f"{t[0]:.3f} s" if t[0] == t[1] else f"{t[0]:.3f}-{t[1]:.3f} s"


def findings_markdown(reports):
    """A FINDINGS.md table: one row per finding of every report."""
    lines = ["| case | build | video t | frames | check | what is wrong |", "| --- | --- | --- | --- | --- | --- |"]
    for report in reports:
        for f in report.get("findings") or []:
            frames = f"{f['frames'][0]}" if f["frames"][0] == f["frames"][1] else f"{f['frames'][0]}-{f['frames'][1]}"
            what = f["detail"].replace("|", "\\|")
            if f["severity"] != "defect":
                what = f"({f['severity']}) {what}"
            lines.append(f"| {report['case']} | {report['build']} | {_video_t(f['t'])} | {frames} | {f['check']} | "
                         f"{what} |")
    return "\n".join(lines) + "\n"


def export_pngs(report, out_dir):
    """Writes the first and last frame of each finding as full-size PNGs. Returns the paths written."""
    case = load_case(report["base"])
    if case.movie is None:
        return []
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ids, rel = _movie_index(case)
    jobs = []
    for n, f in enumerate(report["findings"]):
        for which, idx in (("first", f["frames"][0]), ("last", f["frames"][1])):
            if not len(ids):
                continue
            m = int(np.argmin(np.abs(ids - idx)))
            slug = re.sub(r"[^a-z0-9]+", "-", f["check"].lower()).strip("-")
            jobs.append((out_dir / f"{case.name}-{n:03d}-{slug}-{which}-f{int(ids[m])}.png", m))

    def write(job):
        path, m = job
        start = _seek_start(case, int(ids[m]))
        cmd = [ffmpeg_exe(), "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        if start is not None:
            cmd += ["-ss", f"{start:.6f}"]
        cmd += ["-i", str(case.movie), "-frames:v", "1", "-update", "1", str(path)]
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return str(path) if path.is_file() else None

    with ThreadPoolExecutor(max_workers=16) as pool:
        return [p for p in pool.map(write, jobs) if p]


def summary(report):
    iv = report["intervals_ms"]
    motion = ", ".join(f"{a:.3f}-{b:.3f} s" for a, b in report["motion"]) or "none"
    counts = {}
    for f in report["findings"]:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    lines = [f"{report['case']} ({report['build']}): {report['frames']} complete frames, refresh "
             f"{report['refresh_ms']} ms, motion {motion}"]
    if iv["p50"] is not None:
        lines.append(f"  intervals in motion: p50 {iv['p50']:.2f} p95 {iv['p95']:.2f} p99 {iv['p99']:.2f} max "
                     f"{iv['max']:.2f} ms; refreshes per frame {iv['hist']}; dropped {report['dropped']}")
    lines.append(f"  model lag (samples): {report.get('model_lag') or {}}; findings: "
                 f"{counts.get('defect', 0)} defect, {counts.get('note', 0)} note, {counts.get('recorder', 0)} recorder")
    for f in report["findings"][:40]:
        lines.append(f"  - {_video_t(f['t'])} [{f['frames'][0]}-{f['frames'][1]}] {f['severity']} {f['check']}: "
                     f"{f['detail']}")
    if len(report["findings"]) > 40:
        lines.append(f"  ... {len(report['findings']) - 40} more in the JSON report")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", nargs="+", help="recording base path (BASE.mov etc.)")
    ap.add_argument("--json", help="write the report here (one object, or a list for several BASEs)")
    ap.add_argument("--frames-dir", help="write the first and last frame of each finding here as PNGs")
    ap.add_argument("--markdown", help="write the FINDINGS.md table here")
    ap.add_argument("--no-movie", action="store_true", help="skip the movie decode (content checks)")
    opts = ap.parse_args(argv)
    with ThreadPoolExecutor(max_workers=min(16, len(opts.base))) as pool:
        reports = list(pool.map(lambda b: judge(b, movie=not opts.no_movie), opts.base))
    for report in reports:
        print(summary(report))
        if opts.frames_dir:
            report["pngs"] = export_pngs(report, opts.frames_dir)
            print(f"  {len(report['pngs'])} PNGs in {opts.frames_dir}")
    if opts.json:
        Path(opts.json).write_text(json.dumps(reports[0] if len(reports) == 1 else reports, indent=1))
    if opts.markdown:
        Path(opts.markdown).write_text(findings_markdown(reports))
    return 0


if __name__ == "__main__":
    sys.exit(main())
