#!/usr/bin/env python3
"""PIXEL PERFECT judge: every pane edge of a pixel-fixture film, per film frame, from the exact scan lines and the
geometry trace (video-cases/gen_pixel.py records them; pixel/tui_border.py and pixel/page.html draw the panes).

  judge_pixel.py BASE [BASE ...] [--json OUT.json] [--markdown OUT.md] [--all-frames]
      BASE: a recording without suffix (.../px-col-drag-x1), or any of its files

Reads BASE.mov.scan (exact BGRA rows and columns per complete film frame, `debug.motion` record_*), BASE.trace.json
(the app's pane and divider rects per display tick) and BASE.meta.json (notes.pixel: which pane draws which fixture,
the springs and Reduce Motion the case set; ext_pixel.py px_record_start writes it). Never the lossy movie.

Colors. Every fixture color is a corner of the RGB cube: shell #FF00FF (gaps), terminal theme #00FFFF (Ghostty's
padding: the strip outside the whole cells), ring 1 #FF0000, ring 2 #FFFFFF, ring 3 #000000 (the page's 1, 2 and 3
CSS px borders take the same colors in the same order), fills #FFFF00 / #00FF00 / #0000FF. A pixel is classed by
each channel being >= 160 (1) or <= 96 (0); any channel between is "other" (a glyph, an anti-aliased edge, a blend,
app chrome). So a dim overlay, a color-space round trip or a 1 px blend never moves a run by more than that pixel.

Clock. A film frame shown at host time t shows the trace sample of t minus one refresh (video_judge.committed_sample).

Per film frame, per scan line, per fixture pane the line crosses (its content rect in that sample), the judge walks
from the pane's fill outward on both sides: ring 3, ring 2, ring 1, then (terminal) the theme strip, then what lies
beyond (the shell's color is a gap). Each side gives:
  edge_err   the content's outer edge (the theme strip's outer end, or ring 1's for a page) minus the pane edge of
             the shown sample, device px (+ = toward higher x or y); edge_dev: the same minus its value at rest
  gap        shell-colored px just beyond the content edge; gap_dev: minus the rest value (+: a gap opened)
  rings      the width of ring 1, 2, 3 (px); hidden: the rings narrower than at rest by more than 1 px (a neighbour
             or the clip covers them: an overlap), or cut (a terminal grid that shrank before the program redrew)
  strip      the theme strip's width: Ghostty's padding plus the whole-cell remainder (terminal panes)
  lag        k: the content edge shows the pane edge of k samples before the shown one (0: in step; the first k of
             0..12, -1..-3 within 1 px)
Per motion (a pane edge of the trace that moves, then rests): settle_frames, the film frames from the first frame
that shows the landed sample until the content edge is within 1 px of it for good; and, when the case declared a
spring (notes.pixel.spring: response and damping after the speed scale), the trace edge and the shown content edge
against that spring's curve (x1 + (x0 - x1) * g(t - t0), g the damped spring's step response with omega0 = 2 pi /
response, t0 fitted within two refreshes before the first moving sample): max and RMS error, px. Under Reduce Motion
(notes.pixel.reduce) a motion of more than one sample is a finding.

Writes one report per BASE (JSON with --json; `frames` lists only the frames with a finding unless --all-frames) and
a markdown table (--markdown, else printed). Exit 0 with no finding, 1 with one, 2 when a BASE has no scan or note.
numpy (the VM venv /work/tmp/bv-venv/bin/python).
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
SKIP_PT = 24.0              # points walked over (fill and "other": the ruler, glyphs) from the fill to ring 3
AA_PX = 1                   # "other" px allowed between two runs (an edge at a fractional pixel)
REST_FRAMES = 5             # frames before the first motion that set the rest values
LAG_SEARCH = list(range(0, 13)) + [-1, -2, -3]
COMMIT_SLACK_S = 0.0005
MOVE_EPS_PX = 0.01
STILL_SAMPLES = 3           # a motion ends after this many still samples
SPRING_T0_STEPS = 41        # t0 grid points (coarse, then as many again around the best)


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
        if self.has_scan:
            header, records, _ = vj.read_scan(scan)
            self.rows = [int(y) for y in header.get("rows") or []]
            self.cols = [int(x) for x in header.get("columns") or []]
            self.t = records["t"].astype(float)
            self.row_px = records["rows"] if self.rows else None
            self.col_px = records["cols"] if self.cols else None
        else:
            self.rows, self.cols, self.t, self.row_px, self.col_px = [], [], np.zeros(0), None, None
        ms = trace.get("refresh_ms")
        if ms:
            self.period = float(ms) / 1000.0
        else:
            d = np.diff(np.sort(self.t))
            d = d[d > 0]
            self.period = float(np.median(d)) if len(d) else 1 / 120
        roles = dict(ROLE_DEFAULT, **(self.note.get("roles") or {}))
        self.role_code = {k: code_of(v) for k, v in roles.items()}
        self.panes = {}  # trace pane id -> {kind, fill code, label}
        for pid, info in (self.note.get("panes") or {}).items():
            if info.get("kind") in ("tui", "page") and info.get("fill"):
                self.panes[str(pid)] = {"kind": info["kind"], "fill": code_of(info["fill"]), "label": info.get("label", pid),
                                        "fill_hex": info["fill"]}

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


def _read(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------------------------------------------
# One side of one pane on one line
# ---------------------------------------------------------------------------------------------------------------
def runs_of(codes):
    """[(code, start, end)] of a 1-D class array (end exclusive)."""
    if len(codes) == 0:
        return []
    change = np.flatnonzero(np.diff(codes)) + 1
    starts = np.concatenate(([0], change))
    ends = np.concatenate((change, [len(codes)]))
    return [(int(codes[s]), int(s), int(e)) for s, e in zip(starts, ends)]


def walk_side(codes, start, step, kind, roles, fill, skip_px):
    """From index START (the outermost fill pixel of the pane), walk in STEP (-1 or +1) direction: skip fill and
    "other" (ruler, glyphs) up to skip_px, then rings 3, 2, 1, then the theme strip (terminal), then what is beyond.
    Positions are pixel boundaries (floats); an "other" pixel between two runs counts half to each."""
    L = len(codes)
    i = start + step
    skipped = 0
    while 0 <= i < L and codes[i] in (fill, OTHER) and skipped < skip_px:
        i += step
        skipped += 1

    def boundary(idx):
        # The boundary on the inner side of pixel idx (between idx - step and idx).
        return float(idx) if step > 0 else float(idx + 1)

    def run_at(idx, code):
        """The run of CODE from idx outward: (end index exclusive in walk order, width px)."""
        j = idx
        while 0 <= j < L and codes[j] == code:
            j += step
        return j, abs(j - idx)

    expected = ["ring3", "ring2", "ring1"] + (["theme"] if kind == "tui" else [])
    widths = {}
    edges = {}
    pos = i
    inner_edge = boundary(pos) if 0 <= pos < L else None
    for idx, role in enumerate(expected):
        if not (0 <= pos < L):
            break
        code = int(codes[pos])
        want = roles[role]
        if code != want:
            # A ring missing here: is a later expected role here instead?
            later = [r for r in expected[idx + 1:] if roles[r] == code]
            if not later:
                if code == OTHER and role != "theme":
                    # One anti-aliased pixel before the run.
                    nxt = pos + step
                    if 0 <= nxt < L and codes[nxt] == want:
                        pos = nxt
                        code = want
                if code != want:
                    widths[role] = 0.0
                    continue
            else:
                widths[role] = 0.0
                continue
        a = pos
        pos, w = run_at(pos, want)
        widths[role] = float(w)
        edges[role] = (boundary(a), boundary(pos) if 0 <= pos < L else (float(L) if step > 0 else 0.0))
        # One "other" pixel between this run and the next counts half to each.
        if 0 <= pos < L and codes[pos] == OTHER:
            nxt = pos + step
            if 0 <= nxt < L and codes[nxt] != OTHER:
                widths[role] += 0.5
                edges[role] = (edges[role][0], edges[role][1] + 0.5 * step)
                pos = nxt
    for role in expected:
        widths.setdefault(role, 0.0)
    ring1 = edges.get("ring1")
    cell_edge = ring1[1] if ring1 else None
    view_edge = edges["theme"][1] if "theme" in edges else cell_edge
    if view_edge is None and edges:
        # No ring 1: the outermost run found is the content's edge as shown.
        view_edge = max((e[1] for e in edges.values()), key=lambda v: v * step)
    beyond, gap = None, 0.0
    if 0 <= pos < L:
        beyond = CLASS.get(int(codes[pos]), "other")
        if int(codes[pos]) == roles["shell"]:
            _, gap = run_at(pos, roles["shell"])
            gap = float(gap)
    return {"rings": [widths["ring1"], widths["ring2"], widths["ring3"]], "strip": widths.get("theme", 0.0) if kind == "tui" else None,
            "cell_edge": cell_edge, "view_edge": view_edge, "inner_edge": inner_edge, "beyond": beyond, "gap": gap,
            "skipped": skipped}


def measure(film, codes, axis, coord_px, sample):
    """{pane id: {"lo": side, "hi": side, "span": [lo, hi]}} for each fixture pane crossed by this line."""
    s = film.scale
    out = {}
    coord_pt = coord_px / s
    for pid, row in sample.panes.items():
        info = film.panes.get(str(pid))
        if not info or len(row) < 6 or float(row[5]) < 0.99 or float(row[3]) <= 0 or float(row[4]) <= 0:
            continue
        x, y, w, h = (float(v) for v in row[1:5])
        content = [float(v) for v in row[14:18]] if len(row) >= 18 else [x, y, w, h]
        cx, cy, cw, ch = content
        # The line must cross the pane's shown rect and its content, 2 px inside.
        if axis == "row":
            across = (max(y, cy), min(y + h, cy + ch))
            lo_pt, hi_pt = x, x + w
        else:
            across = (max(x, cx), min(x + w, cx + cw))
            lo_pt, hi_pt = y, y + h
        if not (across[0] * s + 2 <= coord_px <= across[1] * s - 2):
            continue
        lo, hi = lo_pt * s, hi_pt * s
        fill = info["fill"]
        a, b = max(0, int(math.floor(lo))), min(len(codes), int(math.ceil(hi)))
        mine = np.flatnonzero(codes[a:b] == fill)
        if len(mine) == 0:
            out[str(pid)] = {"span": [lo, hi], "no_fill": True}
            continue
        first, last = a + int(mine[0]), a + int(mine[-1])
        skip = int(SKIP_PT * s)
        roles = dict(film.role_code)
        out[str(pid)] = {"span": [round(lo, 2), round(hi, 2)],
                         "lo": walk_side(codes, first, -1, info["kind"], roles, fill, skip),
                         "hi": walk_side(codes, last, +1, info["kind"], roles, fill, skip)}
        _ = coord_pt
    return out


# ---------------------------------------------------------------------------------------------------------------
# Spring curve
# ---------------------------------------------------------------------------------------------------------------
def spring_g(t, response, damping):
    """Step response of a damped spring from 1 to 0 (SwiftUI semantics: omega0 = 2 pi / response, zeta = damping);
    t < 0 is 1."""
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
    """The t0 in [t0_lo, t0_hi] that fits VALUES (at TIMES) best to the spring from x0 to x1 (a coarse grid, then a
    fine one around its best): {t0, max_px, rms_px}."""
    times, values = np.asarray(times, float), np.asarray(values, float)

    def score(t0):
        curve = x1 + (x0 - x1) * spring_g(times - t0, response, damping)
        err = np.abs(values - curve)
        return float(err.max()), float(np.sqrt((err ** 2).mean())), float(t0)

    grid = np.linspace(t0_lo, t0_hi, SPRING_T0_STEPS)
    best = min((score(t0) for t0 in grid), key=lambda c: c[0])
    step = (t0_hi - t0_lo) / max(SPRING_T0_STEPS - 1, 1)
    fine = np.linspace(best[2] - step, best[2] + step, SPRING_T0_STEPS)
    best = min([best] + [score(t0) for t0 in fine], key=lambda c: c[0])
    return {"t0": best[2], "max_px": round(best[0], 2), "rms_px": round(best[1], 2)}


# ---------------------------------------------------------------------------------------------------------------
# The judge
# ---------------------------------------------------------------------------------------------------------------
def edge_series(film, pid, axis, side):
    """The pane edge (device px) along the axis, per trace sample (None when the pane is not in the sample)."""
    out = []
    for smp in film.samples:
        row = smp.panes.get(pid)
        if row is None or len(row) < 5:
            out.append(None)
            continue
        x, y, w, h = (float(v) for v in row[1:5])
        lo, length = (x, w) if axis == "row" else (y, h)
        out.append((lo if side == "lo" else lo + length) * film.scale)
    return out


def motions_of(series):
    """[(first moving sample, landed sample)] of an edge series: moves between samples, ended by STILL_SAMPLES."""
    out, start, still = [], None, 0
    for k in range(1, len(series)):
        a, b = series[k - 1], series[k]
        moved = a is not None and b is not None and abs(b - a) > MOVE_EPS_PX
        if moved:
            if start is None:
                start = k
            still = 0
            last_move = k
        elif start is not None:
            still += 1
            if still >= STILL_SAMPLES:
                out.append((start, last_move))
                start = None
    if start is not None:
        out.append((start, last_move))
    return out


def judge(base, all_frames=False):
    film = Film(base)
    report = {"case": film.name, "base": str(film.base), "scale": film.scale, "period_ms": round(film.period * 1000, 3),
              "frames": film.n, "rows": film.rows, "columns": film.cols, "notes": [], "findings": [],
              "fixture": {"panes": {p: {k: v for k, v in i.items() if k != "fill"} for p, i in film.panes.items()},
                          "speed": film.note.get("speed"), "reduce": film.note.get("reduce"), "spring": film.note.get("spring"),
                          "input": film.note.get("input")}}
    if not film.has_scan or film.n == 0:
        report["notes"].append("no scan file or no scan records: nothing judged")
        return report
    if not film.panes:
        report["notes"].append("no fixture panes in meta notes.pixel: nothing judged")
        return report
    if not film.samples:
        report["notes"].append("no trace samples: nothing judged")
        return report
    shown = [film.committed(float(t)) for t in film.t]
    # Measurements: tracks[(pid, line, side)] = per frame measurement or None.
    tracks = {}
    for name, axis, coord, px in film.lines():
        codes_all = classify(px)
        for f in range(film.n):
            k = shown[f]
            if k is None:
                continue
            for pid, m in measure(film, codes_all[f], axis, coord, film.samples[k]).items():
                for side in ("lo", "hi"):
                    key = (pid, name, axis, side)
                    tracks.setdefault(key, [None] * film.n)
                    if m.get("no_fill"):
                        tracks[key][f] = {"no_fill": True, "span": m["span"]}
                    else:
                        tracks[key][f] = dict(m[side], span=m["span"])
    # Motion: the first trace sample where any fixture pane edge moves.
    first_motion = None
    series_cache = {}
    for (pid, name, axis, side) in tracks:
        sk = (pid, axis, side)
        if sk not in series_cache:
            series_cache[sk] = edge_series(film, pid, axis, side)
        mv = motions_of(series_cache[sk])
        if mv:
            first_motion = mv[0][0] if first_motion is None else min(first_motion, mv[0][0])
    rest_frames = [f for f in range(film.n) if shown[f] is not None and (first_motion is None or shown[f] < first_motion - 1)]
    report["rest_frames"] = len(rest_frames)
    spring = film.note.get("spring") or {}
    reduce = bool(film.note.get("reduce"))
    summary, frames_out = {}, {}
    for key, per_frame in sorted(tracks.items()):
        pid, name, axis, side = key
        info = film.panes[pid]
        series = series_cache[(pid, axis, side)]
        sign = -1.0 if side == "lo" else 1.0
        # Rest values: the median of the rest frames where the side was measured; else of the last frames.
        def rest_of(field, frames):
            vals = [per_frame[f][field] for f in frames if per_frame[f] and not per_frame[f].get("no_fill")
                    and per_frame[f].get(field) is not None]
            return float(np.median(vals)) if vals else None
        rest_pool = [f for f in rest_frames if per_frame[f]] or [f for f in range(film.n) if per_frame[f]][-REST_FRAMES:]
        edge_errs = {}
        for f in rest_pool:
            m = per_frame[f]
            if m and not m.get("no_fill") and m.get("view_edge") is not None and series[shown[f]] is not None:
                edge_errs[f] = m["view_edge"] - series[shown[f]]
        rest = {"edge_err": float(np.median(list(edge_errs.values()))) if edge_errs else 0.0,
                "gap": rest_of("gap", rest_pool) or 0.0, "strip": rest_of("strip", rest_pool),
                "rings": [None, None, None]}
        for r in range(3):
            vals = [per_frame[f]["rings"][r] for f in rest_pool if per_frame[f] and not per_frame[f].get("no_fill")]
            rest["rings"][r] = float(np.median(vals)) if vals else None
        rows = []
        worst = {"edge_dev": 0.0, "gap_dev": 0.0, "hidden_frames": 0, "cut_frames": 0, "lag_max": 0, "no_fill_frames": 0,
                 "strip_max": None, "frames": 0}
        for f in range(film.n):
            m = per_frame[f]
            if m is None:
                continue
            k = shown[f]
            worst["frames"] += 1
            entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": k, "line": name, "pane": pid,
                     "label": info["label"], "side": side}
            problems = []
            if m.get("no_fill"):
                worst["no_fill_frames"] += 1
                entry["no_fill"] = True
                problems.append("no fill: the pane shows none of its content on this line")
            else:
                edge = series[k]
                if m["view_edge"] is not None and edge is not None:
                    err = m["view_edge"] - edge
                    dev = err - rest["edge_err"]
                    entry["edge_err"] = round(err, 2)
                    entry["edge_dev"] = round(dev, 2)
                    if abs(dev) > TOL_PX:
                        problems.append(f"content edge {dev:+.1f} px off the pane edge")
                    worst["edge_dev"] = max(worst["edge_dev"], dev, key=abs)
                    lag = None
                    for kk in LAG_SEARCH:
                        j = k - kk
                        if 0 <= j < len(series) and series[j] is not None and abs(m["view_edge"] - rest["edge_err"] - series[j]) <= TOL_PX:
                            lag = kk
                            break
                    entry["lag"] = lag
                    if lag:
                        problems.append(f"lag {lag} frame(s)")
                        worst["lag_max"] = max(worst["lag_max"], lag, key=abs)
                entry["gap"] = m["gap"]
                gap_dev = m["gap"] - rest["gap"]
                entry["gap_dev"] = gap_dev
                if gap_dev > TOL_PX - 1e-9 and gap_dev >= 1:
                    problems.append(f"shell visible: gap {m['gap']:.0f} px ({gap_dev:+.0f} px from rest)")
                    worst["gap_dev"] = max(worst["gap_dev"], gap_dev)
                entry["rings"] = m["rings"]
                hidden = [r + 1 for r in range(3) if rest["rings"][r] is not None and m["rings"][r] < rest["rings"][r] - TOL_PX]
                if hidden:
                    cut = info["kind"] == "tui" and m["beyond"] in ("cyan",) and m["rings"][0] == 0
                    entry["hidden"] = hidden
                    entry["hidden_px"] = [round(rest["rings"][r - 1] - m["rings"][r - 1], 1) for r in hidden]
                    if cut:
                        entry["cut"] = True
                        worst["cut_frames"] += 1
                        problems.append(f"ring(s) {hidden} cut: the grid shrank and the program has not redrawn")
                    else:
                        worst["hidden_frames"] += 1
                        problems.append(f"ring(s) {hidden} hidden (overlap or clip; beyond: {m['beyond']})")
                if m["strip"] is not None:
                    entry["strip"] = m["strip"]
                    worst["strip_max"] = m["strip"] if worst["strip_max"] is None else max(worst["strip_max"], m["strip"])
                entry["beyond"] = m["beyond"]
            if problems:
                entry["problems"] = problems
            if problems or all_frames:
                frames_out.setdefault(f, []).append(entry)
        # Motions of this edge: settle frames, spring fit, reduce motion.
        motions = []
        for (a, landed) in motions_of(series):
            mv = {"samples": [a, landed], "travel_px": round(series[landed] - series[a - 1], 2) if series[a - 1] is not None else None}
            final = series[landed]
            first_landed = next((f for f in range(film.n) if shown[f] is not None and shown[f] >= landed), None)
            settle = None
            if first_landed is not None:
                ok_from = None
                for f in range(first_landed, film.n):
                    m = per_frame[f]
                    on = m and not m.get("no_fill") and m.get("view_edge") is not None and \
                        abs(m["view_edge"] - rest["edge_err"] - final) <= TOL_PX
                    if on and ok_from is None:
                        ok_from = f
                    elif not on:
                        ok_from = None
                settle = (ok_from - first_landed) if ok_from is not None else None
            mv["settle_frames"] = settle
            if reduce and landed > a:
                mv["reduce_motion_samples"] = landed - a + 1
            if spring.get("response") and spring.get("damping") is not None and series[a - 1] is not None and landed > a:
                times = [film.sample_t[j] for j in range(a, landed + 1)]
                vals = [series[j] for j in range(a, landed + 1)]
                t_first = film.sample_t[a]
                fit = fit_spring(times, vals, series[a - 1], final, t_first - 2 * film.period, t_first,
                                 float(spring["response"]), float(spring["damping"]))
                mv["spring_trace"] = fit
                # The film: each frame's content edge at its display time, against the same spring with its own t0
                # (a constant latency is a time shift, reported as latency_ms; the shape error is max_px).
                ft, fv = [], []
                for f in range(film.n):
                    m = per_frame[f]
                    if shown[f] is None or not (a <= shown[f] <= landed) or not m or m.get("no_fill") or m.get("view_edge") is None:
                        continue
                    ft.append(float(film.t[f]))
                    fv.append(m["view_edge"] - rest["edge_err"])
                if len(ft) >= 2:
                    ffit = fit_spring(ft, fv, series[a - 1], final, t_first - 2 * film.period, t_first + 6 * film.period,
                                      float(spring["response"]), float(spring["damping"]))
                    mv["spring_film"] = {"max_px": ffit["max_px"], "rms_px": ffit["rms_px"], "frames": len(ft),
                                         "latency_ms": round((ffit["t0"] - fit["t0"]) * 1000, 2)}
            motions.append(mv)
        skey = f"{info['label']}:{pid}:{name}:{side}"
        summary[skey] = {"pane": pid, "label": info["label"], "kind": info["kind"], "line": name, "side": side,
                         "rest": {k: (round(v, 2) if isinstance(v, float) else v) for k, v in rest.items()},
                         "frames": worst["frames"], "max_edge_dev_px": round(worst["edge_dev"], 2),
                         "max_gap_px": round(worst["gap_dev"], 2), "hidden_ring_frames": worst["hidden_frames"],
                         "cut_ring_frames": worst["cut_frames"], "no_fill_frames": worst["no_fill_frames"],
                         "max_lag_frames": worst["lag_max"], "strip_max_px": worst["strip_max"], "motions": motions}
        _ = sign
    report["summary"] = summary
    report["frame_findings"] = [{"f": f, "entries": frames_out[f]} for f in sorted(frames_out)]
    report["findings"] = _findings(report)
    return report


def _findings(report):
    out = []
    for key, s in report["summary"].items():
        where = f"{s['label']} ({s['kind']}) {s['side']} edge on {s['line']}"
        if abs(s["max_edge_dev_px"]) > TOL_PX:
            out.append({"check": "content edge off", "where": where, "detail": f"max {s['max_edge_dev_px']:+.1f} px"})
        if s["max_gap_px"] >= 1:
            out.append({"check": "gap", "where": where, "detail": f"shell visible up to {s['max_gap_px']:.0f} px past rest"})
        if s["hidden_ring_frames"]:
            out.append({"check": "hidden ring", "where": where, "detail": f"{s['hidden_ring_frames']} frame(s)"})
        if s["cut_ring_frames"]:
            out.append({"check": "rings cut", "where": where, "detail": f"{s['cut_ring_frames']} frame(s): the grid shrank before the redraw"})
        if s["max_lag_frames"]:
            out.append({"check": "lag", "where": where, "detail": f"content up to {s['max_lag_frames']} frame(s) behind the pane edge"})
        if s["no_fill_frames"]:
            out.append({"check": "no content", "where": where, "detail": f"{s['no_fill_frames']} frame(s)"})
        for mv in s["motions"]:
            if mv.get("settle_frames"):
                out.append({"check": "settle", "where": where, "detail": f"motion at samples {mv['samples']}: {mv['settle_frames']} frame(s) "
                                                                         "until the content edge reached the landed pane edge"})
            if mv.get("reduce_motion_samples"):
                out.append({"check": "motion under Reduce Motion", "where": where, "detail": f"{mv['reduce_motion_samples']} samples"})
            for which in ("spring_trace", "spring_film"):
                fit = mv.get(which)
                if fit and fit["max_px"] > TOL_PX:
                    out.append({"check": "off the spring curve", "where": where,
                                "detail": f"{which.split('_')[1]}: max {fit['max_px']} px, rms {fit['rms_px']} px (samples {mv['samples']})"})
    return out


def markdown(reports):
    head = ("| case | pane | side | line | frames | max edge dev px | max gap px | hidden ring frames | max lag frames | "
            "settle frames | strip px rest/max | spring trace/film max px |")
    lines = [head, "|" + "---|" * 12]
    for r in reports:
        if not r.get("summary"):
            lines.append(f"| {r['case']} | - | - | - | 0 | - | - | - | - | - | - | {'; '.join(r['notes'])} |")
            continue
        for s in r["summary"].values():
            settle = max((m.get("settle_frames") or 0 for m in s["motions"]), default=0)
            st = [m.get("spring_trace", {}).get("max_px") for m in s["motions"] if m.get("spring_trace")]
            sf = [m.get("spring_film", {}).get("max_px") for m in s["motions"] if m.get("spring_film")]
            spring = f"{max(st) if st else '-'}/{max(sf) if sf else '-'}"
            strip = f"{s['rest'].get('strip')}/{s['strip_max_px']}" if s["kind"] == "tui" else "-"
            lines.append(f"| {r['case']} | {s['label']} ({s['kind']}) | {s['side']} | {s['line']} | {s['frames']} | "
                         f"{s['max_edge_dev_px']:+.1f} | {s['max_gap_px']:.0f} | {s['hidden_ring_frames']} | {s['max_lag_frames']} | "
                         f"{settle} | {strip} | {spring} |")
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
