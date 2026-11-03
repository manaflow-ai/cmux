#!/usr/bin/env python3
"""PIXEL PERFECT judge: every pane edge and divider of a pixel-fixture film, per film frame, from the exact scan lines
and the geometry trace (video-cases/gen_pixel.py records them; pixel/tui_border.py and pixel/page.html draw the panes).

  judge_pixel.py BASE [BASE ...] [--json OUT.json] [--markdown OUT.md] [--all-frames]
      BASE: a recording without suffix (.../px-col-drag-2-s025), or any of its files

Reads BASE.mov.scan (exact BGRA rows and columns per complete film frame, `debug.motion` record_*), BASE.trace.json
(the app's pane and divider rects per display tick) and BASE.meta.json (notes.pixel: which pane draws which fixture,
the speed or Reduce Motion, the declared spring; ext_pixel.py px_record_start writes it). Never the lossy movie.

Colors. Every fixture color is a corner of the RGB cube: shell #FF00FF (gaps), terminal ground #00FFFF (Ghostty's
padding: the strip outside the whole cells), ring 1 #FF0000, ring 2 #FFFFFF, ring 3 #000000 (the page's 1, 2 and 3
CSS px borders take the same colors in the same order), fills #FFFF00 / #00FF00 / #0000FF. A pixel is classed by each
channel being >= 160 (1) or <= 96 (0); any channel between is "other" (a glyph, an anti-aliased edge, a blend, app
chrome). So a dim overlay, a color-space round trip or a 1 px blend never moves a run by more than that pixel.

Clock. A film frame shown at host time t shows the trace sample of t minus one refresh (video_judge.committed_sample).

Pane sides. Per film frame, per scan line, per fixture pane the line crosses (its shown rect and content rect in that
sample), on each side: the fill run nearest the pane edge whose next run outward is ring 3 (at most 1 "other" px
between; else the outermost fill pixel and a walk over up to 24 pt of fill and "other": the rulers, glyphs), then
ring 3, ring 2, ring 1 and (terminal) the ground strip, then what lies beyond. Each side gives:
  edge_err   the content's outer edge (the ground strip's outer end: the terminal view's edge; ring 1's for a page)
             minus the pane edge of the shown sample, device px (+ toward higher x or y); edge_dev: minus its rest value
  ring_edge  ring 1's outer edge (a terminal: where the program drew its picture; moves in whole cells)
  gap        shell-colored px just beyond the content edge; gap_dev: minus the rest value (+: the shell shows more)
  beyond     the class just beyond the content edge and its run (beyond_px): the shell, the pane's own fill (a page's
             backdrop), white (Chromium's ground), "other"
  rings      ring 1, 2, 3 widths (px); hidden: narrower than at rest by more than 1 px, something covers them (an
             overlap or the clip); cut (terminal): the ground strip borders the fill, the program has not redrawn
             since its grid shrank
  strip      the ground strip's width; remainder (the high side): strip minus the low side's strip in that frame, the
             whole-cell remainder Ghostty leaves on the right and the bottom
  lag        k: the content edge shows the pane edge of k samples before the shown one (0 in step; the first k of
             0..12, -1..-3 within 1 px)
Dividers. Per trace divider a scan line crosses, per frame: the shown divider is the middle of the gap between the
content edges of the two fixture panes beside it; dev against the trace divider's centre (minus its rest value), lag.
Motions (an edge or divider of the trace that moves, then rests 3 samples): settle_frames (from the first frame that
shows the landed sample until the content is within 1 px of it for good) and, with a declared spring
(notes.pixel.spring: response and damping after the speed scale), the trace and the film against that spring's step
response (omega0 = 2 pi / response, damping fraction as given; its start t0 fitted): max and RMS px; the film's t0
minus the trace's is latency_ms. Under Reduce Motion (notes.pixel.reduce) a motion of more than one sample is a finding.

Writes one report per BASE (--json; `frame_findings` lists the frames with a finding, every judged frame with
--all-frames) and a markdown table (--markdown, else printed). Exit 0 with no finding, 1 with one, 2 when a BASE has
no scan, no trace or no fixture note. numpy (the VM venv /work/tmp/bv-venv/bin/python).
"""
from __future__ import annotations

import argparse
import bisect
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import video_judge as vj  # noqa: E402  (the scan and trace formats: read_scan, _parse_samples, base_path)

HI, LO = 160, 96            # a channel >= HI is on, <= LO is off; between: "other"
OTHER = -1
CLASS = {0: "black", 1: "blue", 2: "green", 3: "cyan", 4: "red", 5: "magenta", 6: "yellow", 7: "white"}
CODE = {v: k for k, v in CLASS.items()}
ROLE_DEFAULT = {"shell": "#FF00FF", "theme": "#00FFFF", "ring1": "#FF0000", "ring2": "#FFFFFF", "ring3": "#000000"}
TOL_PX = 1.0                # device px: an edge this close is in place
SKIP_PT = 24.0              # points walked over (fill and "other": the rulers, glyphs) from the fill to ring 3
NEAR_PT = 48.0              # a ring 3 candidate counts this far outside the pane edge
LAG_SEARCH = list(range(0, 13)) + [-1, -2, -3]
COMMIT_SLACK_S = 0.0005
MOVE_EPS_PX = 0.01
STILL_SAMPLES = 3           # a motion ends after this many still samples
REST_FALLBACK = 5           # frames used for rest values when nothing rests before the first motion
SPRING_T0_STEPS = 41        # t0 grid points (coarse, then as many again around the best)
DIVIDER_NEAR_PT = 12.0      # a pane edge this close to a divider's side is that divider's neighbour


def code_of(hex_color):
    v = hex_color.lstrip("#")
    r, g, b = (int(v[i:i + 2], 16) for i in (0, 2, 4))
    bits = [1 if c >= HI else 0 if c <= LO else None for c in (r, g, b)]
    if None in bits:
        raise ValueError(f"{hex_color} is not a corner of the color cube (each channel >= {HI} or <= {LO})")
    return bits[0] * 4 + bits[1] * 2 + bits[2]


def classify(px):
    """(..., 4) BGRA uint8 -> (...,) int8 class code (CLASS) or OTHER."""
    rgb = px[..., 2::-1].astype(np.int16)
    on, off = rgb >= HI, rgb <= LO
    code = on[..., 0] * 4 + on[..., 1] * 2 + on[..., 2]
    return np.where((on | off).all(-1), code, OTHER).astype(np.int8)


def _read(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------------------------------------------
class Film:
    def __init__(self, base):
        self.base = vj.base_path(base)
        self.name = self.base.name
        meta = _read(f"{self.base}.meta.json") or {}
        trace = _read(f"{self.base}.trace.json") or {}
        self.note = (meta.get("notes") or {}).get("pixel") or {}
        self.scale = float((meta.get("start") or {}).get("scale") or self.note.get("scale") or 2.0)
        self.samples = vj._parse_samples(trace)
        self.sample_t = [s.t for s in self.samples]
        scan = Path(f"{self.base}.mov.scan")
        self.has_scan = scan.is_file()
        self.rows, self.cols, self.t, self.row_px, self.col_px = [], [], np.zeros(0), None, None
        if self.has_scan:
            header, records, _ = vj.read_scan(scan)
            self.rows = [int(y) for y in header.get("rows") or []]
            self.cols = [int(x) for x in header.get("columns") or []]
            self.t = records["t"].astype(float)
            self.row_px = records["rows"] if self.rows else None
            self.col_px = records["cols"] if self.cols else None
        ms = trace.get("refresh_ms")
        if ms:
            self.period = float(ms) / 1000.0
        else:
            d = np.diff(np.sort(self.t))
            d = d[d > 0]
            self.period = float(np.median(d)) if len(d) else 1 / 120
        roles = dict(ROLE_DEFAULT, **(self.note.get("roles") or {}))
        self.roles = {k: code_of(v) for k, v in roles.items()}
        self.panes = {}  # trace pane id -> {kind, fill code, label}
        for pid, info in (self.note.get("panes") or {}).items():
            if info.get("kind") in ("tui", "page") and info.get("fill"):
                self.panes[str(pid)] = {"kind": info["kind"], "fill": code_of(info["fill"]), "label": info.get("label", pid),
                                        "fill_hex": info["fill"], "agent": bool(info.get("agent"))}

    @property
    def n(self):
        return len(self.t)

    def committed(self, t):
        k = bisect.bisect_right(self.sample_t, t - self.period + COMMIT_SLACK_S) - 1
        return k if k >= 0 else (0 if self.samples else None)

    def lines(self):
        """[(name, axis, coord_px, pixels (n, L, 4))]: axis "row" runs along x (crosses vertical edges)."""
        out = [(f"row@{y}", "row", y, self.row_px[:, i]) for i, y in enumerate(self.rows)]
        out += [(f"col@{x}", "col", x, self.col_px[:, i]) for i, x in enumerate(self.cols)]
        return out


# ---------------------------------------------------------------------------------------------------------------
# One side of one pane on one line
# ---------------------------------------------------------------------------------------------------------------
def start_pixel(codes, a, b, edge_px, step, fill, ring3, near_px):
    """The fill pixel the walk outward starts from: the fill pixel nearest the pane edge, inside [a - near, b + near),
    whose next pixel outward (or the one after an "other" pixel) is ring 3; else the outermost fill pixel in [a, b)."""
    L = len(codes)
    lo, hi = max(0, a - near_px), min(L, b + near_px)
    idx = np.arange(lo, hi)
    is_fill = codes[lo:hi] == fill
    nxt = np.clip(idx + step, 0, L - 1)
    nxt2 = np.clip(idx + 2 * step, 0, L - 1)
    ok = is_fill & ((codes[nxt] == ring3) | ((codes[nxt] == OTHER) & (codes[nxt2] == ring3)))
    cand = idx[ok]
    if len(cand):
        return int(cand[np.argmin(np.abs(cand + (1 if step > 0 else 0) - edge_px))])
    mine = np.flatnonzero(codes[a:b] == fill)
    if not len(mine):
        return None
    return a + int(mine[-1] if step > 0 else mine[0])


def walk_side(codes, start, step, kind, roles, fill, skip_px):
    """From START (a fill pixel), outward in STEP (-1 or +1): skip fill and "other" up to skip_px, then rings 3, 2, 1,
    then the ground strip (terminal), then what is beyond. Positions are pixel boundaries; an "other" pixel between two
    runs counts half to each."""
    L = len(codes)
    i, skipped = start + step, 0
    while 0 <= i < L and codes[i] in (fill, OTHER) and skipped < skip_px:
        i += step
        skipped += 1

    def boundary(idx):  # the boundary on the inner side of pixel idx
        return float(idx) if step > 0 else float(idx + 1)

    def run_end(idx, code):
        j = idx
        while 0 <= j < L and codes[j] == code:
            j += step
        return j

    expected = ["ring3", "ring2", "ring1"] + (["theme"] if kind == "tui" else [])
    widths, edges, pos = {}, {}, i
    for n, role in enumerate(expected):
        if not 0 <= pos < L:
            break
        want = roles[role]
        if codes[pos] == OTHER and role != "theme" and 0 <= pos + step < L and codes[pos + step] == want:
            pos += step  # one anti-aliased pixel before the run
        if codes[pos] != want:
            widths[role] = 0.0
            continue
        a = pos
        pos = run_end(pos, want)
        widths[role] = float(abs(pos - a))
        outer = boundary(pos) if 0 <= pos < L else (float(L) if step > 0 else 0.0)
        edges[role] = (boundary(a), outer)
        if 0 <= pos < L and codes[pos] == OTHER and 0 <= pos + step < L and codes[pos + step] != OTHER:
            widths[role] += 0.5
            edges[role] = (edges[role][0], outer + 0.5 * step)
            pos += step
    for role in expected:
        widths.setdefault(role, 0.0)
    ring_edge = edges["ring1"][1] if "ring1" in edges else None
    view_edge = edges["theme"][1] if "theme" in edges else ring_edge
    if view_edge is None and edges:
        view_edge = max((e[1] for e in edges.values()), key=lambda v: v * step)  # the outermost run found
    beyond, beyond_px, gap = None, 0.0, 0.0
    if 0 <= pos < L:
        code = int(codes[pos])
        beyond = "fill" if code == fill else CLASS.get(code, "other")
        beyond_px = float(abs(run_end(pos, code) - pos))
        if code == roles["shell"]:
            gap = beyond_px
    return {"rings": [widths["ring1"], widths["ring2"], widths["ring3"]],
            "strip": widths["theme"] if kind == "tui" else None, "ring_edge": ring_edge, "view_edge": view_edge,
            "beyond": beyond, "beyond_px": beyond_px, "gap": gap, "skipped": skipped}


def pane_rect(row):
    x, y, w, h = (float(v) for v in row[1:5])
    content = [float(v) for v in row[14:18]] if len(row) >= 18 else [x, y, w, h]
    return (x, y, w, h), content


def measure(film, codes, axis, coord_px, sample):
    """{pane id: {"lo": side, "hi": side, "span": [lo, hi]} | {"no_fill": True}} for the fixture panes this line crosses."""
    s = film.scale
    out = {}
    for pid, row in sample.panes.items():
        info = film.panes.get(str(pid))
        if not info or len(row) < 6 or float(row[5]) < 0.99 or float(row[3]) <= 0 or float(row[4]) <= 0:
            continue
        (x, y, w, h), (cx, cy, cw, ch) = pane_rect(row)
        if axis == "row":
            across, lo_pt, hi_pt = (max(y, cy), min(y + h, cy + ch)), x, x + w
        else:
            across, lo_pt, hi_pt = (max(x, cx), min(x + w, cx + cw)), y, y + h
        if not across[0] * s + 2 <= coord_px <= across[1] * s - 2:
            continue
        lo, hi = lo_pt * s, hi_pt * s
        a, b = max(0, int(math.floor(lo))), min(len(codes), int(math.ceil(hi)))
        near = int(NEAR_PT * s)
        sides = {}
        for side, step, edge in (("lo", -1, lo), ("hi", +1, hi)):
            start = start_pixel(codes, a, b, edge, step, info["fill"], film.roles["ring3"], near)
            if start is not None:
                sides[side] = walk_side(codes, start, step, info["kind"], film.roles, info["fill"], int(SKIP_PT * s))
        if not sides:
            out[str(pid)] = {"span": [round(lo, 2), round(hi, 2)], "no_fill": True}
            continue
        out[str(pid)] = dict(sides, span=[round(lo, 2), round(hi, 2)])
    return out


# ---------------------------------------------------------------------------------------------------------------
# Spring curve
# ---------------------------------------------------------------------------------------------------------------
def spring_g(t, response, damping):
    """Step response of a damped spring from 1 to 0 (SwiftUI semantics: omega0 = 2 pi / response, zeta = damping);
    1 for t < 0."""
    t = np.asarray(t, dtype=float)
    w0 = 2 * math.pi / max(response, 1e-6)
    z = damping
    tt = np.maximum(t, 0.0)
    if z < 1 - 1e-9:
        wd = w0 * math.sqrt(1 - z * z)
        g = np.exp(-z * w0 * tt) * (np.cos(wd * tt) + (z * w0 / wd) * np.sin(wd * tt))
    elif z > 1 + 1e-9:
        wd = w0 * math.sqrt(z * z - 1)
        g = np.exp(-z * w0 * tt) * (np.cosh(wd * tt) + (z * w0 / wd) * np.sinh(wd * tt))
    else:
        g = np.exp(-w0 * tt) * (1 + w0 * tt)
    return np.where(t < 0, 1.0, g)


def fit_spring(times, values, x0, x1, t0_lo, t0_hi, response, damping):
    """The start t0 in [t0_lo, t0_hi] that fits VALUES (at TIMES) best to the spring from x0 to x1 (a coarse grid, then a
    fine one around its best): {t0, max_px, rms_px}."""
    times, values = np.asarray(times, float), np.asarray(values, float)

    def score(t0):
        err = np.abs(values - (x1 + (x0 - x1) * spring_g(times - t0, response, damping)))
        return float(err.max()), float(np.sqrt((err ** 2).mean())), float(t0)

    best = min((score(t0) for t0 in np.linspace(t0_lo, t0_hi, SPRING_T0_STEPS)), key=lambda c: c[0])
    step = (t0_hi - t0_lo) / max(SPRING_T0_STEPS - 1, 1)
    best = min([best] + [score(t0) for t0 in np.linspace(best[2] - step, best[2] + step, SPRING_T0_STEPS)], key=lambda c: c[0])
    return {"t0": best[2], "max_px": round(best[0], 2), "rms_px": round(best[1], 2)}


# ---------------------------------------------------------------------------------------------------------------
# Tracks: a measured position per film frame against the trace's position per sample
# ---------------------------------------------------------------------------------------------------------------
def motions_of(series):
    """[(first moving sample, last moving sample)] of a series: moves between samples, ended by STILL_SAMPLES."""
    out, start, still, last_move = [], None, 0, None
    for k in range(1, len(series)):
        a, b = series[k - 1], series[k]
        if a is not None and b is not None and abs(b - a) > MOVE_EPS_PX:
            start = k if start is None else start
            still, last_move = 0, k
        elif start is not None:
            still += 1
            if still >= STILL_SAMPLES:
                out.append((start, last_move))
                start = None
    if start is not None:
        out.append((start, last_move))
    return out


def judge_track(film, shown, measured, series, rest_frames, spring, reduce):
    """measured: per frame a position (device px) or None; series: per sample the trace's position or None.
    Returns {rest_offset, per_frame: {f: {dev, lag}}, motions: [...]}: dev is measured - rest offset - the shown sample's
    position; lag the samples back that match within TOL_PX."""
    pool = [f for f in rest_frames if measured[f] is not None and series[shown[f]] is not None]
    if not pool:
        pool = [f for f in range(film.n) if measured[f] is not None and shown[f] is not None and series[shown[f]] is not None][-REST_FALLBACK:]
    offset = float(np.median([measured[f] - series[shown[f]] for f in pool])) if pool else 0.0
    per_frame = {}
    for f in range(film.n):
        k = shown[f]
        if measured[f] is None or k is None or series[k] is None:
            continue
        value = measured[f] - offset
        lag = None
        for kk in LAG_SEARCH:
            j = k - kk
            if 0 <= j < len(series) and series[j] is not None and abs(value - series[j]) <= TOL_PX:
                lag = kk
                break
        per_frame[f] = {"dev": round(value - series[k], 2), "lag": lag}
    motions = []
    for a, landed in motions_of(series):
        before = series[a - 1]
        final = series[landed]
        mv = {"samples": [a, landed], "travel_px": round(final - before, 2) if before is not None else None}
        first_landed = next((f for f in range(film.n) if shown[f] is not None and shown[f] >= landed), None)
        settle = None
        if first_landed is not None:
            ok_from = None
            for f in range(first_landed, film.n):
                on = measured[f] is not None and abs(measured[f] - offset - final) <= TOL_PX
                ok_from = (f if ok_from is None else ok_from) if on else None
            settle = (ok_from - first_landed) if ok_from is not None else None
        mv["settle_frames"] = settle
        if reduce and landed > a:
            mv["reduce_motion_samples"] = landed - a + 1
        if spring and before is not None and landed > a:
            response, damping = float(spring["response"]), float(spring["damping"])
            t_first = film.sample_t[a]
            times = [film.sample_t[j] for j in range(a, landed + 1)]
            fit = fit_spring(times, [series[j] for j in range(a, landed + 1)], before, final, t_first - 2 * film.period, t_first,
                             response, damping)
            mv["spring_trace"] = fit
            ft = [float(film.t[f]) for f in range(film.n) if measured[f] is not None and shown[f] is not None and a <= shown[f] <= landed]
            fv = [measured[f] - offset for f in range(film.n) if measured[f] is not None and shown[f] is not None and a <= shown[f] <= landed]
            if len(ft) >= 2:
                ffit = fit_spring(ft, fv, before, final, t_first - 2 * film.period, t_first + 6 * film.period, response, damping)
                mv["spring_film"] = {"max_px": ffit["max_px"], "rms_px": ffit["rms_px"], "frames": len(ft),
                                     "latency_ms": round((ffit["t0"] - fit["t0"]) * 1000, 2)}
        motions.append(mv)
    return {"rest_offset": round(offset, 2), "per_frame": per_frame, "motions": motions}


def edge_series(film, pid, axis, side):
    out = []
    for smp in film.samples:
        row = smp.panes.get(pid)
        if row is None or len(row) < 5:
            out.append(None)
            continue
        (x, y, w, h), _ = pane_rect(row)
        lo, length = (x, w) if axis == "row" else (y, h)
        out.append((lo if side == "lo" else lo + length) * film.scale)
    return out


def divider_series(film, did):
    """(axis, centre per sample in device px or None, rect per sample) of trace divider DID."""
    centres, rects, axis = [], [], None
    for smp in film.samples:
        d = smp.dividers.get(did)
        if d is None or len(d) < 5 or (len(d) > 5 and float(d[5]) < 0.99):
            centres.append(None)
            rects.append(None)
            continue
        x, y, w, h = (float(v) for v in d[1:5])
        axis = "row" if h > w else "col"  # a vertical divider is crossed by rows
        centres.append(((x + w / 2) if h > w else (y + h / 2)) * film.scale)
        rects.append((x, y, w, h))
    return axis, centres, rects


# ---------------------------------------------------------------------------------------------------------------
# The judge
# ---------------------------------------------------------------------------------------------------------------
def judge(base, all_frames=False):
    film = Film(base)
    report = {"case": film.name, "base": str(film.base), "scale": film.scale, "period_ms": round(film.period * 1000, 3),
              "frames": film.n, "rows": film.rows, "columns": film.cols, "notes": [], "findings": [],
              "fixture": {"panes": {p: {k: v for k, v in i.items() if k != "fill"} for p, i in film.panes.items()},
                          "speed": film.note.get("speed"), "reduce": film.note.get("reduce"), "spring": film.note.get("spring"),
                          "input": film.note.get("input")}}
    for why, bad in (("no scan file or no scan records", not film.has_scan or film.n == 0),
                     ("no fixture panes in the meta notes (notes.pixel)", not film.panes), ("no trace samples", not film.samples)):
        if bad:
            report["notes"].append(f"{why}: nothing judged")
            return report
    shown = [film.committed(float(t)) for t in film.t]
    spring = film.note.get("spring") or None
    reduce = bool(film.note.get("reduce"))
    # Per line, per frame: the measurements of every fixture pane the line crosses.
    measured = {}  # (pid, line, axis, side) -> [side dict | {"no_fill"} | None] per frame
    lines = film.lines()
    for name, axis, coord, px in lines:
        codes_all = classify(px)
        for f in range(film.n):
            if shown[f] is None:
                continue
            for pid, m in measure(film, codes_all[f], axis, coord, film.samples[shown[f]]).items():
                for side in ("lo", "hi"):
                    track = measured.setdefault((pid, name, axis, side), [None] * film.n)
                    track[f] = {"no_fill": True} if m.get("no_fill") or side not in m else m[side]
    # The first trace sample where any judged edge moves; frames before it (less one) are at rest.
    series = {}
    first = None
    for (pid, name, axis, side) in measured:
        key = (pid, axis, side)
        if key not in series:
            series[key] = edge_series(film, pid, axis, side)
            mv = motions_of(series[key])
            if mv:
                first = mv[0][0] if first is None else min(first, mv[0][0])
    dividers = {}
    for smp in film.samples:
        for did in smp.dividers:
            if did not in dividers:
                dividers[did] = divider_series(film, did)
    for did, (axis, centres, _) in dividers.items():
        mv = motions_of(centres)
        if mv and any(k[1] == axis for k in series):
            first = mv[0][0] if first is None else min(first, mv[0][0])
    rest_frames = [f for f in range(film.n) if shown[f] is not None and (first is None or shown[f] < first - 1)]
    report["rest_frames"] = len(rest_frames)
    summary, frames_out = {}, {}

    def add_frame(f, entry):
        if entry.get("problems") or all_frames:
            frames_out.setdefault(f, []).append(entry)

    # -- pane sides --
    for key, per in sorted(measured.items()):
        pid, name, axis, side = key
        info = film.panes[pid]
        view = [m["view_edge"] if m and not m.get("no_fill") and m.get("view_edge") is not None else None for m in per]
        track = judge_track(film, shown, view, series[(pid, axis, side)], rest_frames, spring, reduce)
        rings_rest = []
        pool = [f for f in rest_frames if per[f] and not per[f].get("no_fill")] or \
            [f for f in range(film.n) if per[f] and not per[f].get("no_fill")][-REST_FALLBACK:]
        for r in range(3):
            vals = [per[f]["rings"][r] for f in pool]
            rings_rest.append(float(np.median(vals)) if vals else None)
        gaps = [per[f]["gap"] for f in pool]
        gap_rest = float(np.median(gaps)) if gaps else 0.0
        strips = [per[f]["strip"] for f in pool if per[f].get("strip") is not None]
        strip_rest = float(np.median(strips)) if strips else None
        other = measured.get((pid, name, axis, "lo")) if side == "hi" else None
        worst = {"edge_dev": 0.0, "gap_dev": 0.0, "hidden": 0, "cut": 0, "lag": 0, "no_fill": 0, "strip_max": None,
                 "remainder_max": None, "frames": 0}
        for f in range(film.n):
            m = per[f]
            if m is None:
                continue
            worst["frames"] += 1
            entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name, "pane": pid,
                     "label": info["label"], "side": side}
            problems = []
            if m.get("no_fill"):
                worst["no_fill"] += 1
                entry["no_fill"] = True
                problems.append("no fill: the pane shows none of its content on this line")
                entry["problems"] = problems
                add_frame(f, entry)
                continue
            t = track["per_frame"].get(f)
            if t is not None:
                entry.update(edge_err=round(view[f] - series[(pid, axis, side)][shown[f]], 2), edge_dev=t["dev"], lag=t["lag"])
                if abs(t["dev"]) > TOL_PX:
                    problems.append(f"content edge {t['dev']:+.1f} px off the pane edge")
                worst["edge_dev"] = max(worst["edge_dev"], t["dev"], key=abs)
                if t["lag"]:
                    problems.append(f"lag {t['lag']} frame(s)")
                    worst["lag"] = max(worst["lag"], t["lag"], key=abs)
            if m.get("ring_edge") is not None:
                entry["ring_edge"] = m["ring_edge"]
            entry.update(gap=m["gap"], gap_dev=m["gap"] - gap_rest, beyond=m["beyond"], beyond_px=m["beyond_px"], rings=m["rings"])
            if m["gap"] - gap_rest >= TOL_PX:
                problems.append(f"shell visible: gap {m['gap']:.0f} px ({m['gap'] - gap_rest:+.0f} px from rest)")
                worst["gap_dev"] = max(worst["gap_dev"], m["gap"] - gap_rest)
            hidden = [r + 1 for r in range(3) if rings_rest[r] is not None and m["rings"][r] < rings_rest[r] - TOL_PX]
            if hidden:
                entry["hidden"] = hidden
                entry["hidden_px"] = [round(rings_rest[r - 1] - m["rings"][r - 1], 1) for r in hidden]
                if info["kind"] == "tui" and (m.get("strip") or 0) > 0 and m["rings"][0] == 0:
                    entry["cut"] = True
                    worst["cut"] += 1
                    problems.append(f"ring(s) {hidden} cut: the grid shrank and the program has not redrawn")
                else:
                    worst["hidden"] += 1
                    problems.append(f"ring(s) {hidden} hidden (overlap or clip; beyond: {m['beyond']})")
            if m.get("strip") is not None:
                entry["strip"] = m["strip"]
                worst["strip_max"] = m["strip"] if worst["strip_max"] is None else max(worst["strip_max"], m["strip"])
                lo_side = other[f] if other else None
                if lo_side and not lo_side.get("no_fill") and lo_side.get("strip") is not None:
                    entry["remainder"] = m["strip"] - lo_side["strip"]
                    worst["remainder_max"] = entry["remainder"] if worst["remainder_max"] is None else max(worst["remainder_max"], entry["remainder"])
            if problems:
                entry["problems"] = problems
            add_frame(f, entry)
        summary[f"{info['label']}:{pid}:{name}:{side}"] = {
            "what": "pane", "pane": pid, "label": info["label"], "kind": "agent" if info["agent"] else info["kind"], "line": name,
            "side": side, "rest": {"edge_err": track["rest_offset"], "gap": gap_rest, "strip": strip_rest, "rings": rings_rest},
            "frames": worst["frames"], "max_edge_dev_px": round(worst["edge_dev"], 2), "max_gap_px": round(worst["gap_dev"], 2),
            "hidden_ring_frames": worst["hidden"], "cut_ring_frames": worst["cut"], "no_fill_frames": worst["no_fill"],
            "max_lag_frames": worst["lag"], "strip_max_px": worst["strip_max"], "remainder_max_px": worst["remainder_max"],
            "motions": track["motions"]}

    # -- dividers: the middle of the gap between the two fixture panes beside each one --
    for did, (axis, centres, rects) in sorted(dividers.items(), key=lambda kv: str(kv[0])):
        for name, laxis, coord, _ in lines:
            if laxis != axis:
                continue
            mid = [None] * film.n
            pair = None
            for f in range(film.n):
                k = shown[f]
                if k is None or rects[k] is None:
                    continue
                x, y, w, h = rects[k]
                across = (y, y + h) if axis == "row" else (x, x + w)
                if not across[0] * film.scale <= coord < across[1] * film.scale:
                    continue
                lo_edge, hi_edge = (x, x + w) if axis == "row" else (y, y + h)
                left = right = None
                for pid in film.panes:
                    row = film.samples[k].panes.get(pid)
                    if row is None:
                        continue
                    (px_, py_, pw_, ph_), _ = pane_rect(row)
                    p_lo, p_hi = (px_, px_ + pw_) if axis == "row" else (py_, py_ + ph_)
                    if abs(p_hi - lo_edge) <= DIVIDER_NEAR_PT:
                        left = pid
                    if abs(p_lo - hi_edge) <= DIVIDER_NEAR_PT:
                        right = pid
                if left is None or right is None:
                    continue
                a = measured.get((left, name, axis, "hi"))
                b = measured.get((right, name, axis, "lo"))
                ma, mb = (a[f] if a else None), (b[f] if b else None)
                if not ma or not mb or ma.get("no_fill") or mb.get("no_fill") or ma.get("view_edge") is None or mb.get("view_edge") is None:
                    continue
                mid[f] = (ma["view_edge"] + mb["view_edge"]) / 2
                pair = (film.panes[left]["label"], film.panes[right]["label"])
            if not any(v is not None for v in mid):
                continue
            track = judge_track(film, shown, mid, centres, rest_frames, spring, reduce)
            worst_dev, worst_lag = 0.0, 0
            for f, t in sorted(track["per_frame"].items()):
                entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name,
                         "divider": did, "label": f"divider {pair[0]}|{pair[1]}", "side": "mid", "dev": t["dev"], "lag": t["lag"]}
                problems = []
                if abs(t["dev"]) > TOL_PX:
                    problems.append(f"shown divider {t['dev']:+.1f} px off the trace divider")
                    worst_dev = max(worst_dev, t["dev"], key=abs)
                if t["lag"]:
                    problems.append(f"divider lag {t['lag']} frame(s)")
                    worst_lag = max(worst_lag, t["lag"], key=abs)
                if problems:
                    entry["problems"] = problems
                add_frame(f, entry)
            summary[f"divider:{did}:{name}"] = {
                "what": "divider", "divider": did, "label": f"divider {pair[0]}|{pair[1]}", "kind": "divider", "line": name,
                "side": "mid", "rest": {"offset": track["rest_offset"]}, "frames": len(track["per_frame"]),
                "max_edge_dev_px": round(worst_dev, 2), "max_gap_px": 0.0, "hidden_ring_frames": 0, "cut_ring_frames": 0,
                "no_fill_frames": 0, "max_lag_frames": worst_lag, "strip_max_px": None, "remainder_max_px": None,
                "motions": track["motions"]}
    report["summary"] = summary
    report["frame_findings"] = [{"f": f, "entries": frames_out[f]} for f in sorted(frames_out)]
    report["findings"] = findings_of(report)
    return report


def findings_of(report):
    out = []
    for s in report["summary"].values():
        where = f"{s['label']} ({s['kind']}) {s['side']} on {s['line']}"
        if abs(s["max_edge_dev_px"]) > TOL_PX:
            out.append({"check": "divider off" if s["what"] == "divider" else "content edge off", "where": where,
                        "detail": f"max {s['max_edge_dev_px']:+.1f} px"})
        if s["max_gap_px"] >= TOL_PX:
            out.append({"check": "gap", "where": where, "detail": f"shell visible up to {s['max_gap_px']:.0f} px past rest"})
        if s["hidden_ring_frames"]:
            out.append({"check": "hidden ring", "where": where, "detail": f"{s['hidden_ring_frames']} frame(s)"})
        if s["cut_ring_frames"]:
            out.append({"check": "rings cut", "where": where, "detail": f"{s['cut_ring_frames']} frame(s): the grid shrank before the redraw"})
        if s["max_lag_frames"]:
            out.append({"check": "lag", "where": where, "detail": f"up to {s['max_lag_frames']} frame(s) behind the trace"})
        if s["no_fill_frames"]:
            out.append({"check": "no content", "where": where, "detail": f"{s['no_fill_frames']} frame(s)"})
        for mv in s["motions"]:
            if mv.get("settle_frames"):
                out.append({"check": "settle", "where": where, "detail": f"motion at samples {mv['samples']}: {mv['settle_frames']} frame(s) "
                                                                         "until the content reached the landed position"})
            if mv.get("reduce_motion_samples"):
                out.append({"check": "motion under Reduce Motion", "where": where, "detail": f"{mv['reduce_motion_samples']} samples"})
            for which in ("spring_trace", "spring_film"):
                fit = mv.get(which)
                if fit and fit["max_px"] > TOL_PX:
                    out.append({"check": "off the spring curve", "where": where,
                                "detail": f"{which.split('_')[1]}: max {fit['max_px']} px, rms {fit['rms_px']} px (samples {mv['samples']})"})
    return out


def markdown(reports):
    head = ("| case | what | side | line | frames | max dev px | max gap px | hidden/cut ring frames | max lag frames | "
            "settle frames | strip px rest/max | spring trace/film max px |")
    lines = [head, "|" + "---|" * 12]
    for r in reports:
        if not r.get("summary"):
            lines.append(f"| {r['case']} | - | - | - | 0 | - | - | - | - | - | - | {'; '.join(r['notes'])} |")
            continue
        for s in r["summary"].values():
            settle = max((m.get("settle_frames") or 0 for m in s["motions"]), default=0)
            st = [m["spring_trace"]["max_px"] for m in s["motions"] if m.get("spring_trace")]
            sf = [m["spring_film"]["max_px"] for m in s["motions"] if m.get("spring_film")]
            strip = f"{s['rest'].get('strip')}/{s['strip_max_px']}" if s["kind"] == "tui" else "-"
            lines.append(f"| {r['case']} | {s['label']} ({s['kind']}) | {s['side']} | {s['line']} | {s['frames']} | "
                         f"{s['max_edge_dev_px']:+.1f} | {s['max_gap_px']:.0f} | {s['hidden_ring_frames']}/{s['cut_ring_frames']} | "
                         f"{s['max_lag_frames']} | {settle} | {strip} | {max(st) if st else '-'}/{max(sf) if sf else '-'} |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("base", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--markdown")
    ap.add_argument("--all-frames", action="store_true", help="list every judged frame, not only those with a finding")
    opts = ap.parse_args(argv)
    reports = [judge(b, opts.all_frames) for b in opts.base]
    if opts.json:
        Path(opts.json).write_text(json.dumps(reports if len(reports) > 1 else reports[0], indent=1) + "\n")
    md = markdown(reports)
    if opts.markdown:
        Path(opts.markdown).write_text(md)
    else:
        print(md)
    for r in reports:
        for f in r["findings"]:
            print(f"{r['case']}: {f['check']}: {f['where']}: {f['detail']}")
        for n in r["notes"]:
            print(f"{r['case']}: note: {n}")
    if any(not r.get("summary") for r in reports):
        return 2
    return 1 if any(r["findings"] for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main())
