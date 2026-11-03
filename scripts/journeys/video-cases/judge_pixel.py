#!/usr/bin/env python3
"""PIXEL PERFECT judge: every pane edge, tab strip edge and divider of a pixel-fixture film, per film frame, from the
exact scan lines and the geometry trace (video-cases/gen_pixel.py records them; pixel/tui_border.py and pixel/page.html
draw the panes).

  judge_pixel.py BASE [BASE ...] [--json OUT.json] [--markdown OUT.md] [--all-frames]
      BASE: a recording without suffix (.../px-col-drag-2-s025), or any of its files

Reads BASE.mov.scan (exact BGRA rows and columns per complete film frame, `debug.motion` record_*), BASE.trace.json
(the app's pane and divider rects per display tick), BASE.meta.json (notes.pixel: which pane draws which fixture, the
speed or Reduce Motion, the declared spring, the input, the panes' chrome; ext_pixel.py px_record_start writes it) and
BASE.events.json (the app's input journal). Never the lossy movie.

Colors. Every fixture color is a corner of the RGB cube: shell #FF00FF (gaps), terminal ground #00FFFF (Ghostty's
padding: the strip outside the whole cells), ring 1 #FF0000, ring 2 #FFFFFF, ring 3 #000000 (the page's 1, 2 and 3
CSS px borders take the same colors in the same order), fills #FFFF00 / #00FF00 / #0000FF. A pixel is classed by each
channel being >= 160 (1) or <= 96 (0); any channel between is "other" (a glyph, an anti-aliased edge, app chrome). The
divider's drag cue (DividerHandleView lights a band from the mouse-down, drawn over the page through its occlusion rect)
is its own class: shell-class pixels that are not the exact shell color, within 40 pt of a divider of the shown sample.

Clock. A film frame shown at host time t shows the trace sample of t minus one refresh (video_judge.committed_sample).

Pane sides. Per film frame, per scan line, per fixture pane whose content the line crosses (its shown rect below its tab
strip: the note's chrome), on each side the walk starts at a fill pixel within 48 pt of the pane edge whose next pixel
outward is ring 3 and goes through ring 3, ring 2, ring 1 and (terminal) the ground strip. A side is
  found      two rings or more in that order (a candidate with one ring, such as a glyph, is not taken); far from the
             edge (a lag over 48 pt), only a walk of all three rings inside the pane's own rect
  cut        a terminal whose fill borders its ground strip with no ring: the grid shrank before the program redrew
  cue        the divider's drag cue covers the rings: not a gap, not a hidden ring, the edge not judged
  not found  anything else (a pane with none of its content on the line, a blank or loading page, a strip row): a
             separate count with its frames, never a deviation
A found (or cut) side gives:
  edge_err   the content's outer edge (the ground strip's outer end: the terminal view's edge; ring 1's for a page)
             minus the pane edge of the shown sample, device px (+ toward higher x or y); dev: minus its rest value
  gap        shell-colored px just beyond the content edge, at most to the pane's own edge and a divider's 16 px
  rings      ring 1, 2, 3 widths; hidden: narrower than at rest by more than 1 px (an overlap or the clip)
  strip      the ground strip's width; remainder (high side): minus the low side's, the whole-cell remainder
  lag        k: the content edge shows the pane edge of k samples before the shown one (the first k of 0..12, -1..-3
             within 1 px)
and per pane and line, shell inside the pane: exact shell pixels inside the pane's rect (beyond the rest count).
Dividers: the middle of the gap between the content edges of the two fixture panes beside each trace divider.
Tab strips (the note's strip rows): the strip's two edges against the pane's edges; the selected tab's pill against
the pane's left edge (information: a pill also moves when the tabs reflow with the strip's width).
Page windows (D4): each Chromium host of the trace's page rows against its page window (trace) and the page's ring 1
(film): covers the divider, or loses edge columns.
Motions (an edge of the trace that moves, then rests 3 samples): settle_frames (from the first frame that shows the
landed sample until the content is within 1 px of it for good) and, for a spring input with a declared spring, the
trace and the film against that spring's step response (omega0 = 2 pi / response; t0 fitted). A motion is input-driven
when a mouse drag or two key presses fall inside it, or the film's input is a drag, held keys or a window resize: it
follows the input, so neither the spring nor Reduce Motion (which lands a spring motion in one sample) judges it.

Per track: frames judged, frames off by >= 1 px (with ranges), p50, p95 and max |dev| in device px, the most common
deviations, frames with shell inside the pane, cue frames, not found frames. Writes one report per BASE (--json:
`findings` are defects, `info` the rest; `frame_findings` lists the frames with a problem, every judged frame with
--all-frames) and a markdown table per film (--markdown, else printed). Exit 0 with no defect, 1 with one, 2 when a BASE
has no scan, no trace or no fixture note. numpy (the VM venv /work/tmp/bv-venv/bin/python).
"""
from __future__ import annotations

import argparse
import bisect
import collections
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
CUE = -2                    # the divider's drag cue
CLASS = {0: "black", 1: "blue", 2: "green", 3: "cyan", 4: "red", 5: "magenta", 6: "yellow", 7: "white", OTHER: "other",
         CUE: "cue"}
CODE = {v: k for k, v in CLASS.items()}
ROLE_DEFAULT = {"shell": "#FF00FF", "theme": "#00FFFF", "ring1": "#FF0000", "ring2": "#FFFFFF", "ring3": "#000000", "strip": "#000000"}
SHELL_TOL = 4               # an exact shell pixel: every channel this close to the shell's color
CUE_WIDEN_PT = 40.0         # the cue counts this far from a divider's rect (it trails the divider in a fast drag)
PILL_TOL = 6                # a strip pixel this far (max channel) from the strip's ground is not ground: the pill, text
PILL_BRIDGE = 2             # ground gaps this narrow inside a run (between glyphs) are bridged
PILL_MIN_PX = 12            # the selected tab's pill: the longest run of non-ground pixels, at least this long
PILL_WIDTH_SHARE = 0.25     # a pill run whose width is this share off its rest width is not the pill (a reflow, a title)
HOST_TOL_PX = 0.99          # a page window this far off its host (device px) or more: off
TOL_PX = 1.0                # device px: an edge this close is in place
SKIP_PT = 24.0              # points walked over (fill and "other": the rulers, glyphs) from the fill to ring 3
NEAR_PT = 48.0              # the walk starts this close to the pane edge
GAP_CAP_PX = 16.0           # a gap counts to the pane's own edge and this far past it (a divider's band)
MAX_CANDIDATES = 8          # walks tried per side
LAG_SEARCH = list(range(0, 13)) + [-1, -2, -3]
COMMIT_SLACK_S = 0.0005
MOVE_EPS_PX = 0.01
STILL_SAMPLES = 3           # a motion ends after this many still samples
REST_FALLBACK = 5           # frames used for rest values when nothing rests before the first motion
SPRING_T0_STEPS = 41        # t0 grid points (coarse, then as many again around the best)
DIVIDER_NEAR_PT = 12.0      # a pane edge this close to a divider's side is that divider's neighbour
NON_SPRING_INPUTS = ("drag", "held keys", "window resize")  # inputs whose motion follows the input by design
INPUT_KEY_WINDOW_S = 0.5    # key presses this long before a motion's first sample count as its input


def code_of(hex_color):
    v = hex_color.lstrip("#")
    r, g, b = (int(v[i:i + 2], 16) for i in (0, 2, 4))
    bits = [1 if c >= HI else 0 if c <= LO else None for c in (r, g, b)]
    if None in bits:
        raise ValueError(f"{hex_color} is not a corner of the color cube (each channel >= {HI} or <= {LO})")
    return bits[0] * 4 + bits[1] * 2 + bits[2]


def rgb_of(hex_color):
    v = hex_color.lstrip("#")
    return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))


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


def ranges(frames):
    """[3, 4, 5, 9] -> "3-5,9"."""
    out, frames = [], sorted(frames)
    for f in frames:
        if out and f == out[-1][1] + 1:
            out[-1][1] = f
        else:
            out.append([f, f])
    return ",".join(f"{a}-{b}" if b > a else f"{a}" for a, b in out)


# ---------------------------------------------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------------------------------------------
class Film:
    def __init__(self, base):
        self.base = vj.base_path(base)
        self.name = self.base.name
        meta = _read(f"{self.base}.meta.json") or {}
        trace = _read(f"{self.base}.trace.json") or {}
        events = _read(f"{self.base}.events.json") or {}
        self.note = (meta.get("notes") or {}).get("pixel") or {}
        self.scale = float((meta.get("start") or {}).get("scale") or self.note.get("scale") or 2.0)
        self.samples = vj._parse_samples(trace)
        self.sample_t = [s.t for s in self.samples]
        # Chromium hosts per sample (`page`: [host w, host h, page window w, page window h, wall ms, host screen x, page
        # window screen x, page area w]), in the samples' order (the same stable sort on the same time).
        t0 = float(trace.get("t0_s") or 0.0)
        raw = sorted(((t0 + float(x.get("t", 0.0)) / 1000.0, x.get("page") or []) for x in trace.get("samples") or []
                      if isinstance(x, dict)), key=lambda e: e[0])
        self.page_rows = [rows for _, rows in raw] if len(raw) == len(self.samples) else [[] for _ in self.samples]
        frame = self.note.get("window_frame") or ((meta.get("window") or {}).get("frame"))
        self.window_x = float(frame[0]) if frame else None
        self.strip_rows = {str(k): int(v) for k, v in ((self.note.get("lines") or {}).get("strip_rows") or {}).items()}
        self.chrome = {str(c.get("pane")): c for c in self.note.get("chrome") or [] if isinstance(c, dict)}
        # The tab strip's height (points) above each pane's content: rows through it are the strip judge's, not a side's.
        self.headers = {}
        for pid, c in self.chrome.items():
            cell, border, strip = c.get("cell"), c.get("border"), c.get("strip")
            if cell and border:
                self.headers[pid] = max(0.0, float(border[1]) - float(cell[1]))
            elif cell and strip:
                self.headers[pid] = max(0.0, float(strip[1]) + float(strip[3]) - float(cell[1]))
        self.inputs = _journal_inputs(events.get("journal") or [])
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
        self.shell_rgb = np.array(rgb_of(roles["shell"]), np.int16)
        self.strip_rgb = rgb_of(roles["strip"])
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

    def input_driven(self, t0, t1):
        """Whether the input moves the layout over [t0, t1] (host s): a mouse drag inside it, or two key presses."""
        if str(self.note.get("input") or "").split(" (")[0] in NON_SPRING_INPUTS:
            return True
        drags = sum(1 for t, kind in self.inputs if kind == "mouse_drag" and t0 - 2 * self.period <= t <= t1)
        keys = sum(1 for t, kind in self.inputs if kind == "key_down" and t0 - INPUT_KEY_WINDOW_S <= t <= t1)
        return drags > 0 or keys >= 2


def _journal_inputs(journal):
    """[(host s, mouse_down | mouse_drag | mouse_up | key_down)] of the app's input journal, sorted."""
    out = []
    for e in journal:
        kind = e.get("kind") or {}
        if not isinstance(kind, dict) or not e.get("uptimeNanos"):
            continue
        t = float(e["uptimeNanos"]) / 1e9
        for name in ("mouse", "key"):
            body = kind.get(name)
            if isinstance(body, dict):
                body = body.get("_0", body)
                phase = (body or {}).get("phase")
                if name == "mouse" and phase in ("down", "drag", "up"):
                    out.append((t, f"mouse_{phase}"))
                if name == "key" and phase == "down":
                    out.append((t, "key_down"))
    return sorted(out)


# ---------------------------------------------------------------------------------------------------------------
# One line of one frame: classes and the divider cue
# ---------------------------------------------------------------------------------------------------------------
def divider_bands(film, sample, axis, coord_px):
    """[(lo, hi)] device px along the line around each divider of SAMPLE the line crosses, widened by CUE_WIDEN_PT."""
    s, out = film.scale, []
    for d in sample.dividers.values():
        if len(d) < 5:
            continue
        x, y, w, h = (float(v) for v in d[1:5])
        vertical = h > w
        if axis == "row" and vertical and y * s <= coord_px < (y + h) * s:
            out.append(((x - CUE_WIDEN_PT) * s, (x + w + CUE_WIDEN_PT) * s))
        elif axis == "col" and not vertical and x * s <= coord_px < (x + w) * s:
            out.append(((y - CUE_WIDEN_PT) * s, (y + h + CUE_WIDEN_PT) * s))
    return out


def with_cue(codes, near_shell, bands):
    """CODES with the cue's class where a shell-class pixel is not the exact shell (near_shell) inside a divider band."""
    if not bands or not near_shell.any():
        return codes
    mask = np.zeros(len(codes), bool)
    for lo, hi in bands:
        mask[max(0, int(lo)):max(0, int(math.ceil(hi)))] = True
    hit = near_shell & mask
    if not hit.any():
        return codes
    out = codes.copy()
    out[hit] = CUE
    return out


# ---------------------------------------------------------------------------------------------------------------
# One side of one pane on one line
# ---------------------------------------------------------------------------------------------------------------
def walk_side(codes, start, step, kind, roles, fill, skip_px):
    """From START (a fill pixel), outward in STEP (-1 or +1): skip fill and "other" up to skip_px, then rings 3, 2, 1,
    then the ground strip (terminal), then what is beyond (a cue run is skipped and counted). Positions are pixel
    boundaries; an "other" pixel between two runs counts half to each. `found`: how many rings were found."""
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
    widths, edges, pos, cue_px = {}, {}, i, 0.0
    for role in expected:
        if 0 <= pos < L and codes[pos] == CUE:
            j = run_end(pos, CUE)
            cue_px += abs(j - pos)
            pos = j
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
        if 0 <= pos < L and codes[pos] == OTHER and 0 <= pos + step < L and codes[pos + step] not in (OTHER, CUE):
            widths[role] += 0.5
            edges[role] = (edges[role][0], outer + 0.5 * step)
            pos += step
    for role in expected:
        widths.setdefault(role, 0.0)
    found = sum(1 for r in ("ring1", "ring2", "ring3") if widths[r] > 0)
    ring_edge = edges["ring1"][1] if "ring1" in edges else None
    view_edge = edges["theme"][1] if "theme" in edges else ring_edge
    if view_edge is None and found >= 2:
        view_edge = max((e[1] for e in edges.values()), key=lambda v: v * step)  # ring 1 hidden: the outermost ring shown
    if 0 <= pos < L and codes[pos] == CUE:
        j = run_end(pos, CUE)
        cue_px += abs(j - pos)
        pos = j
    beyond, beyond_px, gap = None, 0.0, 0.0
    if 0 <= pos < L:
        code = int(codes[pos])
        beyond = "fill" if code == fill else CLASS.get(code, "other")
        beyond_px = float(abs(run_end(pos, code) - pos))
        if code == roles["shell"]:
            gap = beyond_px
    return {"rings": [widths["ring1"], widths["ring2"], widths["ring3"]],
            "strip": widths["theme"] if kind == "tui" else None, "ring_edge": ring_edge, "view_edge": view_edge,
            "beyond": beyond, "beyond_px": beyond_px, "gap": gap, "skipped": skipped, "found": found, "cue_px": cue_px}


def find_side(codes, a, b, edge, step, kind, roles, fill, near, skip):
    """One side of a pane on one line: {status: found | cut | cue | not found, ...walk_side's fields}."""
    L = len(codes)
    ring3 = roles["ring3"]

    def candidates(lo, hi):
        lo, hi = max(0, lo), min(L, hi)
        if hi - lo < 1:
            return []
        idx = np.arange(lo, hi)
        nxt = codes[np.clip(idx + step, 0, L - 1)]
        nxt2 = codes[np.clip(idx + 2 * step, 0, L - 1)]
        ok = (codes[lo:hi] == fill) & ((nxt == ring3) | (nxt == CUE) | ((nxt == OTHER) & ((nxt2 == ring3) | (nxt2 == CUE))))
        return sorted((int(c) for c in idx[ok]), key=lambda c: abs(c + (1 if step > 0 else 0) - edge))[:MAX_CANDIDATES]

    e = int(round(edge))
    for c in candidates(e - near, e + near):
        w = walk_side(codes, c, step, kind, roles, fill, skip)
        if w["found"] >= 2:
            return dict(w, status="found")
        if w["cue_px"] > 0:
            return dict(w, status="cue")
    for c in candidates(a, b):
        w = walk_side(codes, c, step, kind, roles, fill, skip)
        if w["found"] == 3:
            return dict(w, status="found")
    if kind == "tui":
        # The grid shrank before the program redrew: inside the pane, near the edge, the fill borders the ground strip.
        lo, hi = max(a, e - near), min(b, e + near)
        fills = np.flatnonzero(codes[lo:hi] == fill) if hi > lo else []
        if len(fills):
            f = lo + int(fills[-1] if step > 0 else fills[0])
            n = f + step
            if 0 <= n < L and codes[n] == OTHER:
                n += step
            if 0 <= n < L and codes[n] == roles["theme"]:
                j = n
                while 0 <= j < L and codes[j] == roles["theme"]:
                    j += step
                view_edge = (float(j) if step > 0 else float(j + 1)) if 0 <= j < L else (float(L) if step > 0 else 0.0)
                beyond = CLASS.get(int(codes[j]), "other") if 0 <= j < L else None
                k = j
                while 0 <= k < L and codes[k] == roles["shell"]:
                    k += step
                return {"status": "cut", "rings": [0.0, 0.0, 0.0], "strip": float(abs(j - n)), "ring_edge": None,
                        "view_edge": view_edge, "beyond": beyond, "beyond_px": 0.0, "gap": float(abs(k - j)), "found": 0,
                        "cue_px": 0.0, "skipped": 0}
    return {"status": "not found"}


def pane_rect(row):
    x, y, w, h = (float(v) for v in row[1:5])
    content = [float(v) for v in row[14:18]] if len(row) >= 18 else [x, y, w, h]
    return (x, y, w, h), content


def measure(film, codes, axis, coord_px, sample):
    """{pane id: {"lo": side, "hi": side, "span": [lo, hi], "shell_in": px, "has_fill": bool}} for the fixture panes whose
    content (below their tab strip) this line crosses."""
    s = film.scale
    out = {}
    near, skip = int(NEAR_PT * s), int(SKIP_PT * s)
    for pid, row in sample.panes.items():
        info = film.panes.get(str(pid))
        if not info or len(row) < 6 or float(row[5]) < 0.99 or float(row[3]) <= 0 or float(row[4]) <= 0:
            continue
        (x, y, w, h), (cx, cy, cw, ch) = pane_rect(row)
        head = film.headers.get(str(pid), 0.0)
        if axis == "row":
            across, lo_pt, hi_pt = (max(y + head, cy), min(y + h, cy + ch)), x, x + w
        else:
            across, lo_pt, hi_pt = (max(x, cx), min(x + w, cx + cw)), y, y + h
        if not across[0] * s + 2 <= coord_px <= across[1] * s - 2:
            continue
        lo, hi = lo_pt * s, hi_pt * s
        a, b = max(0, int(math.floor(lo))), min(len(codes), int(math.ceil(hi)))
        sides = {}
        for side, step, edge in (("lo", -1, lo), ("hi", +1, hi)):
            m = find_side(codes, a, b, edge, step, info["kind"], film.roles, info["fill"], near, skip)
            if m.get("view_edge") is not None:
                m["gap"] = min(m.get("gap", 0.0), max(0.0, (edge - m["view_edge"]) * step) + GAP_CAP_PX)
            sides[side] = m
        out[str(pid)] = {"lo": sides["lo"], "hi": sides["hi"], "span": [round(lo, 2), round(hi, 2)],
                         "shell_in": int(np.count_nonzero(codes[a:b] == film.roles["shell"])),
                         "has_fill": bool(np.any(codes[a:b] == info["fill"]))}
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
    Returns {rest_offset, per_frame: {f: {dev, lag}}, motions: [...], stats}: dev is measured - rest offset - the shown
    sample's position; lag the samples back that match within TOL_PX."""
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
        driven = film.input_driven(film.sample_t[a] - film.period, film.sample_t[landed])
        mv["input_driven"] = driven
        first_landed = next((f for f in range(film.n) if shown[f] is not None and shown[f] >= landed), None)
        settle = None
        if first_landed is not None:
            ok_from = None
            for f in range(first_landed, film.n):
                on = measured[f] is not None and abs(measured[f] - offset - final) <= TOL_PX
                ok_from = (f if ok_from is None else ok_from) if on else None
            settle = (ok_from - first_landed) if ok_from is not None else None
        mv["settle_frames"] = settle
        if reduce and not driven and landed > a:
            mv["reduce_motion_samples"] = landed - a + 1
        if spring and not driven and before is not None and landed > a:
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
    return {"rest_offset": round(offset, 2), "per_frame": per_frame, "motions": motions, "stats": track_stats(per_frame)}


def track_stats(per_frame):
    """frames judged, off >= 1 px (count, ranges), p50 / p95 of |dev|, max dev (signed), the most common deviations, the
    largest lag."""
    devs = {f: t["dev"] for f, t in per_frame.items()}
    off = sorted(f for f, d in devs.items() if abs(d) >= TOL_PX)
    absd = np.abs(np.array(list(devs.values()), float)) if devs else np.zeros(0)
    top = collections.Counter(round(d, 1) for d in devs.values() if abs(d) >= TOL_PX).most_common(3)
    lags = [t["lag"] for t in per_frame.values() if t["lag"]]
    return {"frames": len(devs), "off_frames": len(off), "off_ranges": ranges(off),
            "p50_px": round(float(np.percentile(absd, 50)), 2) if len(absd) else 0.0,
            "p95_px": round(float(np.percentile(absd, 95)), 2) if len(absd) else 0.0,
            "max_edge_dev_px": round(max(devs.values(), key=abs), 2) if devs else 0.0,
            "dev_top": [[d, n] for d, n in top], "max_lag_frames": max(lags, key=abs) if lags else 0}


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
# Tab strips and Chromium page windows
# ---------------------------------------------------------------------------------------------------------------
def strip_extent(codes, center, shell):
    """[lo, hi) of the run of non-shell pixels around CENTER on a strip row (the strip and its tabs), or None."""
    c = int(round(center))
    if not 0 <= c < len(codes) or codes[c] == shell:
        return None
    shells = np.flatnonzero(codes == shell)
    left, right = shells[shells < c], shells[shells > c]
    return (int(left[-1]) + 1 if len(left) else 0), (int(right[0]) if len(right) else len(codes))


def pill_run(rgb, lo, hi, ground):
    """[a, b) of the selected tab's pill on a strip row: the longest run of non-ground pixels in [lo, hi) (gaps of ground of
    PILL_BRIDGE px or less bridged: the glyphs of its title), at least PILL_MIN_PX long; or None."""
    seg = rgb[lo:hi].astype(np.int16)
    off = np.abs(seg - np.array(ground, np.int16)).max(-1) > PILL_TOL
    m = np.concatenate(([0], off.astype(np.int8), [0]))
    d = np.diff(m)
    starts, ends = list(np.flatnonzero(d == 1)), list(np.flatnonzero(d == -1))
    runs = []
    for a, b in zip(starts, ends):
        if runs and a - runs[-1][1] <= PILL_BRIDGE:
            runs[-1][1] = b
        else:
            runs.append([a, b])
    runs = [r for r in runs if r[1] - r[0] >= PILL_MIN_PX]
    if not runs:
        return None
    a, b = max(runs, key=lambda r: r[1] - r[0])
    return lo + int(a), lo + int(b)


def ground_color(film, rgb_frames, lo_hi):
    """The strip's ground (RGB): the note's strip color when it covers a fifth of the strip at rest, else the strip's most
    common color."""
    want = np.array(film.strip_rgb, np.int16)
    pixels = np.concatenate([rgb[a:b] for rgb, (a, b) in zip(rgb_frames, lo_hi)]).astype(np.int16)
    if not len(pixels):
        return tuple(int(v) for v in want)
    if (np.abs(pixels - want).max(-1) <= PILL_TOL).mean() >= 0.2:
        return tuple(int(v) for v in want)
    values, counts = np.unique(pixels, axis=0, return_counts=True)
    return tuple(int(v) for v in values[int(np.argmax(counts))])


def page_hosts(film):
    """{pane id: [(host x, host w, page x | None, page w) in window points, or None] per sample}: each Chromium host of the
    trace matched to the fixture page pane whose content view it fills (nearest x and width, within 8 pt)."""
    out = {}
    if film.window_x is None:
        return out
    pages = [pid for pid, info in film.panes.items() if info["kind"] == "page"]
    for k, rows in enumerate(film.page_rows):
        for row in rows:
            if not isinstance(row, list) or len(row) < 7:
                continue
            host_w, page_w = float(row[0]), float(row[2])
            host_x = float(row[5]) - film.window_x
            page_x = None if float(row[6]) == -1 else float(row[6]) - film.window_x
            best, score = None, 8.0
            for pid in pages:
                prow = film.samples[k].panes.get(pid)
                if prow is None:
                    continue
                _, (cx, cy, cw, ch) = pane_rect(prow)
                d = abs(cx - host_x) + abs(cw - host_w)
                if d < score:
                    best, score = pid, d
            if best is not None:
                out.setdefault(best, [None] * len(film.samples))[k] = (host_x, host_w, page_x, page_w)
    return out


# ---------------------------------------------------------------------------------------------------------------
# The judge
# ---------------------------------------------------------------------------------------------------------------
def row_summary(what, key, label, kind, line, side, track=None, **extra):
    """One track's summary row: the track's statistics and motions, and the counts every table column shows."""
    stats = (track or {}).get("stats") or track_stats({})
    row = {"what": what, "pane": key, "label": label, "kind": kind, "line": line, "side": side,
           "rest": {"offset": track["rest_offset"]} if track else {}, "max_gap_px": 0.0, "hidden_ring_frames": 0,
           "cut_ring_frames": 0, "no_fill_frames": 0, "not_found_frames": 0, "not_found_ranges": "", "cue_frames": 0,
           "cue_ranges": "", "shell_in_frames": 0, "shell_in_ranges": "", "shell_in_max_px": 0.0, "strip_max_px": None,
           "remainder_max_px": None, "motions": track["motions"] if track else [], "detail": ""}
    row.update(stats)
    row.update(extra)
    return row


def judge(base, all_frames=False):
    film = Film(base)
    report = {"case": film.name, "base": str(film.base), "scale": film.scale, "period_ms": round(film.period * 1000, 3),
              "frames": film.n, "rows": film.rows, "columns": film.cols, "notes": [], "findings": [], "info": [],
              "fixture": {"panes": {p: {k: v for k, v in i.items() if k != "fill"} for p, i in film.panes.items()},
                          "speed": film.note.get("speed"), "reduce": film.note.get("reduce"), "spring": film.note.get("spring"),
                          "input": film.note.get("input"), "page_backdrop": film.note.get("page_backdrop")}}
    for why, bad in (("no scan file or no scan records", not film.has_scan or film.n == 0),
                     ("no fixture panes in the meta notes (notes.pixel)", not film.panes), ("no trace samples", not film.samples)):
        if bad:
            report["notes"].append(f"{why}: nothing judged")
            return report
    shown = [film.committed(float(t)) for t in film.t]
    spring = film.note.get("spring") or None
    reduce = bool(film.note.get("reduce"))
    # Per line, per frame: the classes (with the divider cue) and the measurements of every fixture pane the line crosses.
    measured = {}   # (pid, line, axis, side) -> per frame: side dict or None
    inside = {}     # (pid, line, axis) -> per frame: (shell px inside the pane, has fill) or None
    line_codes = {}  # line -> per frame codes (the cue marked), for the strips
    lines = film.lines()
    for name, axis, coord, px in lines:
        codes_all = classify(px)
        rgb = px[..., 2::-1].astype(np.int16)
        near_shell = (codes_all == film.roles["shell"]) & (np.abs(rgb - film.shell_rgb).max(-1) > SHELL_TOL)
        per_line = []
        for f in range(film.n):
            k = shown[f]
            if k is None:
                per_line.append(codes_all[f])
                continue
            codes = with_cue(codes_all[f], near_shell[f], divider_bands(film, film.samples[k], axis, coord))
            per_line.append(codes)
            for pid, m in measure(film, codes, axis, coord, film.samples[k]).items():
                inside.setdefault((pid, name, axis), [None] * film.n)[f] = (m["shell_in"], m["has_fill"])
                for side in ("lo", "hi"):
                    measured.setdefault((pid, name, axis, side), [None] * film.n)[f] = m[side]
        line_codes[name] = per_line
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

    def judged(m):
        return m is not None and m.get("status") in ("found", "cut") and m.get("view_edge") is not None

    # -- pane sides --
    for key, per in sorted(measured.items()):
        pid, name, axis, side = key
        info = film.panes[pid]
        # A line that shows none of the pane's fill at rest (it runs along a ring row or its strip) does not judge it.
        rest_pool = [f for f in rest_frames if per[f] is not None] or [f for f in range(film.n) if per[f] is not None][:REST_FALLBACK]
        if not any((inside[(pid, name, axis)][f] or (0, False))[1] for f in rest_pool):
            continue
        view = [m["view_edge"] if judged(m) else None for m in per]
        track = judge_track(film, shown, view, series[(pid, axis, side)], rest_frames, spring, reduce)
        pool = [f for f in rest_frames if per[f] is not None and per[f].get("status") == "found"] or \
            [f for f in range(film.n) if per[f] is not None and per[f].get("status") == "found"][-REST_FALLBACK:]
        rings_rest = [float(np.median([per[f]["rings"][r] for f in pool])) if pool else None for r in range(3)]
        gap_rest = float(np.median([per[f]["gap"] for f in pool])) if pool else 0.0
        strips = [per[f]["strip"] for f in pool if per[f].get("strip") is not None]
        strip_rest = float(np.median(strips)) if strips else None
        shell_rest = float(np.median([inside[(pid, name, axis)][f][0] for f in rest_pool if inside[(pid, name, axis)][f]] or [0]))
        other = measured.get((pid, name, axis, "lo")) if side == "hi" else None
        worst = {"gap_dev": 0.0, "hidden": 0, "cut": 0, "no_fill": 0, "strip_max": None, "remainder_max": None, "backdrop": 0,
                 "backdrop_max": 0.0, "shell_max": 0.0}
        lists = {"not_found": [], "cue": [], "shell_in": []}
        for f in range(film.n):
            m = per[f]
            if m is None:
                continue
            entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name, "pane": pid,
                     "label": info["label"], "side": side, "status": m.get("status")}
            problems = []
            shell_px, has_fill = inside[(pid, name, axis)][f] or (0, True)
            if shell_px > shell_rest + 0.5:
                lists["shell_in"].append(f)
                worst["shell_max"] = max(worst["shell_max"], shell_px - shell_rest)
                entry["shell_in"] = shell_px
                problems.append(f"shell inside the pane: {shell_px - shell_rest:.0f} px")
            if not has_fill:
                worst["no_fill"] += 1
                entry["no_fill"] = True
            status = m.get("status")
            if status == "not found":
                lists["not_found"].append(f)
                entry["problems"] = problems
                add_frame(f, entry)
                continue
            if status == "cue":
                lists["cue"].append(f)
                entry.update(cue_px=m["cue_px"], rings=m["rings"])
                if problems:
                    entry["problems"] = problems
                add_frame(f, entry)
                continue
            t = track["per_frame"].get(f)
            if t is not None:
                entry.update(edge_err=round(view[f] - series[(pid, axis, side)][shown[f]], 2), edge_dev=t["dev"], lag=t["lag"])
                if abs(t["dev"]) >= TOL_PX:
                    problems.append(f"content edge {t['dev']:+.1f} px off the pane edge")
                if t["lag"]:
                    problems.append(f"lag {t['lag']} frame(s)")
            if m.get("ring_edge") is not None:
                entry["ring_edge"] = m["ring_edge"]
            entry.update(gap=m["gap"], gap_dev=m["gap"] - gap_rest, beyond=m["beyond"], beyond_px=m["beyond_px"], rings=m["rings"])
            if m.get("cue_px"):
                entry["cue_px"] = m["cue_px"]
            if m["beyond"] == "fill" and m["beyond_px"] >= 1:
                # The pane's own fill past its rings: a page's backdrop (or stale content) where the gap would show.
                worst["backdrop"] += 1
                worst["backdrop_max"] = max(worst["backdrop_max"], m["beyond_px"])
            if m["gap"] - gap_rest >= TOL_PX:
                problems.append(f"shell visible: gap {m['gap']:.0f} px ({m['gap'] - gap_rest:+.0f} px from rest)")
                worst["gap_dev"] = max(worst["gap_dev"], m["gap"] - gap_rest)
            hidden = [r + 1 for r in range(3) if rings_rest[r] is not None and m["rings"][r] < rings_rest[r] - TOL_PX]
            # A terminal's missing outer rings followed by its own ground strip: its grid shrank before the program
            # redrew (cut); anything else in their place covers them (hidden: an overlap or the clip).
            if status == "cut" or (hidden and info["kind"] == "tui" and (m.get("strip") or 0) > 0):
                entry["cut"] = True
                worst["cut"] += 1
                problems.append("rings cut: the grid shrank and the program has not redrawn")
            elif hidden:
                entry["hidden"] = hidden
                entry["hidden_px"] = [round(rings_rest[r - 1] - m["rings"][r - 1], 1) for r in hidden]
                worst["hidden"] += 1
                problems.append(f"ring(s) {hidden} hidden (overlap or clip; beyond: {m['beyond']})")
            if m.get("strip") is not None:
                entry["strip"] = m["strip"]
                worst["strip_max"] = m["strip"] if worst["strip_max"] is None else max(worst["strip_max"], m["strip"])
                lo_side = other[f] if other else None
                if judged(lo_side) and lo_side.get("strip") is not None:
                    entry["remainder"] = m["strip"] - lo_side["strip"]
                    worst["remainder_max"] = entry["remainder"] if worst["remainder_max"] is None else max(worst["remainder_max"], entry["remainder"])
            if problems:
                entry["problems"] = problems
            add_frame(f, entry)
        summary[f"{info['label']}:{pid}:{name}:{side}"] = row_summary(
            "pane", pid, info["label"], "agent" if info["agent"] else info["kind"], name, side, track,
            rest={"edge_err": track["rest_offset"], "gap": gap_rest, "strip": strip_rest, "rings": rings_rest, "shell_in": shell_rest},
            max_gap_px=round(worst["gap_dev"], 2), hidden_ring_frames=worst["hidden"], cut_ring_frames=worst["cut"],
            no_fill_frames=worst["no_fill"], not_found_frames=len(lists["not_found"]), not_found_ranges=ranges(lists["not_found"]),
            cue_frames=len(lists["cue"]), cue_ranges=ranges(lists["cue"]), shell_in_frames=len(lists["shell_in"]),
            shell_in_ranges=ranges(lists["shell_in"]), shell_in_max_px=round(worst["shell_max"], 1), strip_max_px=worst["strip_max"],
            remainder_max_px=worst["remainder_max"], backdrop_frames=worst["backdrop"], backdrop_max_px=worst["backdrop_max"])

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
                if not judged(ma) or not judged(mb):
                    continue
                mid[f] = (ma["view_edge"] + mb["view_edge"]) / 2
                pair = (film.panes[left]["label"], film.panes[right]["label"])
            if not any(v is not None for v in mid):
                continue
            track = judge_track(film, shown, mid, centres, rest_frames, spring, reduce)
            for f, t in sorted(track["per_frame"].items()):
                entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name,
                         "divider": did, "label": f"divider {pair[0]}|{pair[1]}", "side": "mid", "dev": t["dev"], "lag": t["lag"]}
                problems = []
                if abs(t["dev"]) >= TOL_PX:
                    problems.append(f"shown divider {t['dev']:+.1f} px off the trace divider")
                if t["lag"]:
                    problems.append(f"divider lag {t['lag']} frame(s)")
                if problems:
                    entry["problems"] = problems
                add_frame(f, entry)
            summary[f"divider:{did}:{name}"] = row_summary("divider", did, f"divider {pair[0]}|{pair[1]}", "divider", name, "mid", track,
                                                           divider=did)
    judge_strips(film, shown, rest_frames, spring, reduce, summary, add_frame, line_codes)
    judge_page_windows(film, shown, measured, summary, add_frame)
    if film.note.get("page_backdrop") is not False and any(i["kind"] == "page" for i in film.panes.values()):
        report["notes"].append("the page backdrop was on (browserResize.pageBackdrop: "
                               f"{film.note.get('page_backdrop')!r}): a page that lags a growing pane shows its own fill past its "
                               "rings (backdrop_frames), not the shell")
    report["summary"] = summary
    report["frame_findings"] = [{"f": f, "entries": frames_out[f]} for f in sorted(frames_out)]
    report["findings"], report["info"] = findings_of(report)
    return report


def judge_strips(film, shown, rest_frames, spring, reduce, summary, add_frame, line_codes):
    """Each pane's tab strip on its strip row: the strip's two edges against the pane's edges, and the selected tab's pill
    against the pane's left edge, per frame (frames where the row is outside the strip's height now are skipped)."""
    rows = {y: i for i, y in enumerate(film.rows)}
    shell = film.roles["shell"]
    for pid, y in sorted(film.strip_rows.items()):
        if y not in rows or film.row_px is None:
            continue
        chrome = film.chrome.get(pid) or {}
        strip = chrome.get("strip")
        first = next((smp.panes.get(pid) for smp in film.samples if smp.panes.get(pid) is not None), None)
        if not strip or first is None:
            continue
        (_, py0, _, _), _ = pane_rect(first)
        off_y, strip_h = float(strip[1]) - py0, float(strip[3])
        px = film.row_px[:, rows[y]]
        codes_line = line_codes.get(f"row@{y}") or classify(px)
        rgb_all = px[..., 2::-1]
        ext = [None] * film.n
        for f in range(film.n):
            k = shown[f]
            row = film.samples[k].panes.get(pid) if k is not None else None
            if row is None or len(row) < 6 or float(row[5]) < 0.99:
                continue
            (x, py, w, h), _ = pane_rect(row)
            top = (py + off_y) * film.scale
            if not top + 1 <= y <= top + strip_h * film.scale - 1:
                continue
            codes = np.where(codes_line[f] == CUE, shell, codes_line[f])  # the cue is not the strip
            ext[f] = strip_extent(codes, (x + w / 2) * film.scale, shell)
        rest = [f for f in rest_frames if ext[f]] or [f for f in range(film.n) if ext[f]][:REST_FALLBACK]
        if not rest:
            continue
        ground = ground_color(film, [rgb_all[f] for f in rest[:REST_FALLBACK]], [ext[f] for f in rest[:REST_FALLBACK]])
        pill = [pill_run(rgb_all[f], ext[f][0], ext[f][1], ground) if ext[f] else None for f in range(film.n)]
        # The selected tab's pill keeps its width unless the tabs reflow: a run far from its rest width is a reflow or
        # another run (a title, the next tab), not the pill: not found.
        widths = [pill[f][1] - pill[f][0] for f in rest if pill[f]]
        if widths:
            rest_w = float(np.median(widths))
            pill = [p if p and abs((p[1] - p[0]) - rest_w) <= PILL_WIDTH_SHARE * rest_w else None for p in pill]
        else:
            pill = [None] * film.n
        label = (film.panes.get(pid) or {}).get("label", pid[:12])
        lo_series, hi_series = edge_series(film, pid, "row", "lo"), edge_series(film, pid, "row", "hi")
        tracks = (("strip", "lo", [e[0] if e else None for e in ext], lo_series),
                  ("strip", "hi", [e[1] if e else None for e in ext], hi_series),
                  ("pill", "lo", [p[0] if p else None for p in pill], lo_series),
                  ("pill", "hi", [p[1] if p else None for p in pill], lo_series))
        for what, side, measured, series in tracks:
            if not any(v is not None for v in measured):
                continue
            track = judge_track(film, shown, measured, series, rest_frames, spring, reduce)
            for f, t in sorted(track["per_frame"].items()):
                entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": f"row@{y}",
                         "pane": pid, "label": f"{what} {label}", "side": side, "dev": t["dev"], "lag": t["lag"], "at": measured[f]}
                problems = []
                if abs(t["dev"]) >= TOL_PX:
                    problems.append(f"tab {what} {side} edge {t['dev']:+.1f} px off the pane edge")
                if t["lag"]:
                    problems.append(f"tab {what} lag {t['lag']} frame(s)")
                if problems:
                    entry["problems"] = problems
                add_frame(f, entry)
            not_judged = [f for f in range(film.n) if measured[f] is None and ext[f] is None and shown[f] is not None]
            ref = "the pane's left edge" if what == "pill" else f"the pane's {'left' if side == 'lo' else 'right'} edge"
            summary[f"{what}:{label}:{pid}:row@{y}:{side}"] = row_summary(
                what, pid, f"{what} {label}", what, f"row@{y}", side, track, detail=f"against {ref}",
                not_found_frames=sum(1 for f in range(film.n) if ext[f] is not None and measured[f] is None),
                **({"ground": list(ground), "outside_strip_frames": len(not_judged)} if what == "strip" else {}))


def judge_page_windows(film, shown, measured, summary, add_frame):
    """D4: each Chromium page window against its host. From the trace: the page window's x and right edge minus its host's,
    device px, per sample. From the film: the page's ring 1 (its first and last CSS px) minus the host's edges, per frame
    and row line: negative on the left side (positive on the right) covers the divider; the other sign loses edge columns."""
    hosts = page_hosts(film)
    s = film.scale
    for pid, per_sample in sorted(hosts.items()):
        label = film.panes[pid]["label"]
        offs = []
        for k, v in enumerate(per_sample):
            if v is None or v[2] is None:
                continue
            host_x, host_w, page_x, page_w = v
            offs.append((k, round((page_x - host_x) * s, 2), round(((page_x + page_w) - (host_x + host_w)) * s, 2),
                         (host_x * s) % 2 == 1 if s == 2 else None))
        bad = [o for o in offs if abs(o[1]) >= HOST_TOL_PX or abs(o[2]) >= HOST_TOL_PX]
        worst = max((o[1] for o in offs), key=abs, default=0.0)
        worst_hi = max((o[2] for o in offs), key=abs, default=0.0)
        per = {o[0]: {"dev": o[1] if abs(o[1]) >= abs(o[2]) else o[2], "lag": None} for o in offs}
        stats = track_stats(per)
        summary[f"page window:{label}:{pid}:trace"] = row_summary(
            "page window", pid, f"page window {label}", "page window", "trace", "lo/hi", None,
            detail=(f"{len(bad)} of {len(offs)} samples off; left {worst:+.1f} px, right {worst_hi:+.1f} px; host on a half point in "
                    f"{sum(1 for o in bad if o[3])} of them") if bad else f"{len(offs)} samples on their host",
            off_samples=[o[0] for o in bad][:40], half_point_samples=sum(1 for o in bad if o[3]),
            **dict(stats, off_ranges=ranges(o[0] for o in bad), max_edge_dev_px=worst if abs(worst) >= abs(worst_hi) else worst_hi))
        for (p, line, axis, side), per_frame in sorted(measured.items()):
            if p != pid or axis != "row":
                continue
            devs = {}
            for f, m in enumerate(per_frame):
                k = shown[f]
                if not m or m.get("status") != "found" or m.get("ring_edge") is None or k is None or per_sample[k] is None:
                    continue
                host_x, host_w, page_x, page_w = per_sample[k]
                host_edge = (host_x if side == "lo" else host_x + host_w) * s
                dev = round(m["ring_edge"] - host_edge, 2)
                devs[f] = {"dev": dev, "lag": None}
                if abs(dev) < HOST_TOL_PX:
                    continue
                covers = dev < 0 if side == "lo" else dev > 0
                what = (f"covers the divider by {abs(dev):.0f} px" if covers else f"loses {abs(dev):.0f} edge column(s)")
                entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": k, "line": line, "pane": pid,
                         "label": f"page window {label}", "side": side, "host_offset_px": dev,
                         "page_offset_px": round(m["ring_edge"] - ((page_x if side == "lo" else page_x + page_w) * s), 2)
                         if page_x is not None else None, "problems": [f"page {what} (its ring 1 against its host's edge)"]}
                add_frame(f, entry)
            if devs:
                st = track_stats(devs)
                worst_dev = st["max_edge_dev_px"]
                detail = "" if abs(worst_dev) < HOST_TOL_PX else \
                    ("covers the divider" if (worst_dev < 0) == (side == "lo") else "loses edge columns") + ", film"
                summary[f"page window:{label}:{pid}:{line}:{side}"] = row_summary(
                    "page window", pid, f"page window {label}", "page window", line, side, None, detail=detail, **st)


def findings_of(report):
    """(defects, information) of a report's summary rows."""
    out, info = [], []
    for s in report["summary"].values():
        where = f"{s['label']} ({s['kind']}) {s['side']} on {s['line']}"
        stats = f"{s['off_frames']} of {s['frames']} frames off by >= 1 px (frames {s['off_ranges']}); p50 {s['p50_px']}, " \
                f"p95 {s['p95_px']}, max {s['max_edge_dev_px']:+.1f} px; most common {', '.join(f'{d:+.1f} px x{n}' for d, n in s['dev_top'])}"
        if s["off_frames"]:
            check = {"divider": "divider off", "strip": "tab strip edge off", "pill": "tab pill off",
                     "page window": "page window off its host"}.get(s["what"], "content edge off")
            (info if s["what"] == "pill" else out).append({"check": check, "where": where, "detail": stats
                                                           + (f" ({s['detail']})" if s.get("detail") else "")})
        if s["shell_in_frames"]:
            out.append({"check": "shell inside the pane", "where": where,
                        "detail": f"{s['shell_in_frames']} frame(s), up to {s['shell_in_max_px']:.0f} px (frames {s['shell_in_ranges']})"})
        if s["max_gap_px"] >= TOL_PX:
            out.append({"check": "gap", "where": where, "detail": f"shell visible up to {s['max_gap_px']:.0f} px past rest"})
        if s["hidden_ring_frames"]:
            out.append({"check": "hidden ring", "where": where, "detail": f"{s['hidden_ring_frames']} frame(s)"})
        if s["cut_ring_frames"]:
            out.append({"check": "rings cut", "where": where, "detail": f"{s['cut_ring_frames']} frame(s): the grid shrank before the redraw"})
        if s["max_lag_frames"] and s["what"] != "pill":
            out.append({"check": "lag", "where": where, "detail": f"up to {s['max_lag_frames']} frame(s) behind the trace"})
        if s["not_found_frames"]:
            info.append({"check": "not found", "where": where, "detail": f"{s['not_found_frames']} frame(s) (frames {s['not_found_ranges']})"})
        if s["cue_frames"]:
            info.append({"check": "divider cue", "where": where,
                         "detail": f"{s['cue_frames']} frame(s): the drag cue over the rings (frames {s['cue_ranges']})"})
        for mv in s["motions"]:
            target = info if s["what"] == "pill" else out
            if mv.get("settle_frames"):
                target.append({"check": "settle", "where": where, "detail": f"motion at samples {mv['samples']}: {mv['settle_frames']} frame(s) "
                                                                            "until the content reached the landed position"})
            if mv.get("reduce_motion_samples"):
                target.append({"check": "motion under Reduce Motion", "where": where,
                               "detail": f"{mv['reduce_motion_samples']} samples (motion at samples {mv['samples']}, no further input)"})
            for which in ("spring_trace", "spring_film"):
                fit = mv.get(which)
                if fit and fit["max_px"] > TOL_PX:
                    target.append({"check": "off the spring curve", "where": where,
                                   "detail": f"{which.split('_')[1]}: max {fit['max_px']} px, rms {fit['rms_px']} px (samples {mv['samples']})"})
    return out, info


def markdown(reports):
    head = ("| what | side | line | judged | off >= 1 px | p50 | p95 | max dev | top devs | shell in pane | cue | not found | "
            "hidden/cut | lag | settle | spring trace/film |")
    lines = []
    for r in reports:
        fx = r.get("fixture") or {}
        speed = "Reduce Motion" if fx.get("reduce") else f"x{fx.get('speed')}"
        lines.append(f"### {r['case']} ({speed}, input {fx.get('input')}, page backdrop {fx.get('page_backdrop')})")
        lines.append("")
        if not r.get("summary"):
            lines.append("; ".join(r["notes"]))
            lines.append("")
            continue
        lines += [head, "|" + "---|" * 16]
        for s in r["summary"].values():
            settle = max((m.get("settle_frames") or 0 for m in s["motions"]), default=0)
            st = [m["spring_trace"]["max_px"] for m in s["motions"] if m.get("spring_trace")]
            sf = [m["spring_film"]["max_px"] for m in s["motions"] if m.get("spring_film")]
            off = f"{s['off_frames']} ({s['off_ranges']})" if s["off_frames"] else "0"
            shell = f"{s['shell_in_frames']} ({s['shell_in_ranges']}) max {s['shell_in_max_px']:.0f}" if s["shell_in_frames"] else "0"
            cue = f"{s['cue_frames']} ({s['cue_ranges']})" if s["cue_frames"] else "0"
            nf = f"{s['not_found_frames']} ({s['not_found_ranges']})" if s["not_found_frames"] and s.get("not_found_ranges") else str(s["not_found_frames"])
            top = ", ".join(f"{d:+.1f}x{n}" for d, n in s["dev_top"]) or "-"
            lines.append(f"| {s['label']} ({s['kind']}) | {s['side']} | {s['line']} | {s['frames']} | {off} | {s['p50_px']} | "
                         f"{s['p95_px']} | {s['max_edge_dev_px']:+.1f} | {top} | {shell} | {cue} | {nf} | "
                         f"{s['hidden_ring_frames']}/{s['cut_ring_frames']} | {s['max_lag_frames']} | {settle} | "
                         f"{max(st) if st else '-'}/{max(sf) if sf else '-'} |")
        lines.append("")
        for f in r["findings"]:
            lines.append(f"- {f['check']}: {f['where']}: {f['detail']}")
        for f in r["info"]:
            lines.append(f"- (info) {f['check']}: {f['where']}: {f['detail']}")
        for n in r["notes"]:
            lines.append(f"- (note) {n}")
        lines.append("")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("base", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--markdown")
    ap.add_argument("--all-frames", action="store_true", help="list every judged frame, not only those with a problem")
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
