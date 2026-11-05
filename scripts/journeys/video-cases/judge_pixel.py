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

Clock. The fixed clock: a film frame shown at host time t shows the trace sample of t minus one refresh
(video_judge.committed_sample). Per film the judge fits the offset from it (-1, 0 or +1 refresh: a whole film presented
late, or a trace that samples a tick off) from the content edges that follow the trace over the moving frames, and
judges every layer against that clock (fit_clock; `clock` in the JSON). An offset that is not 0 is the finding
"presentation offset". When no offset fits (most moving frames of every moving edge match none: content late by more
than a refresh), the finding "clock not found", and the film is judged on the fixed clock: its lags and deviations in
motion can be one refresh off.

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
  gap        shell-colored px just beyond the content edge, at most to the pane's own edge and the divider band to the
             next pane across that edge (16 px at most; 16 px where no pane is across it): never into the next pane
  rings      ring 1, 2, 3 widths; hidden: narrower than at rest by more than 1 px (an overlap or the clip)
  strip      the ground strip's width; remainder (high side): minus the low side's, the whole-cell remainder
  lag        k: the content edge shows the pane edge of k samples before the shown one (the first k of 0..12, -1..-3
             within 1 px)
and per pane and line, on one row of its own (side "inside", never on the side rows: it is no side's), shell inside
the pane: exact shell pixels in the pane's visible span on the line (beyond the rest count), and the frames that show
none of the pane's fill on the line (no fill).
Dividers (pair C): the fixture's divider band shows the shell, so the film never shows a divider layer; a film
"divider" (the middle of the two content edges beside it) would only restate those edges, so none is derived. Each
trace divider is judged from the trace: its rect's centre against the middle of the gap between the two panes it
separates (any pane row, and the S3d `closing` grounds), per sample; 1 px or more off is the finding "divider rect not centred on its
panes' gap", with its samples. The drag cue (below) stays information on the pane sides.
Tab strips (the note's strip rows): the strip's two edges against the pane's edges, each read inside the pane's own
rect of the shown sample and 48 pt around it (a strip that lags its pane): a neighbour's strip that touches it with no
shell between is never this strip (that side's edge is the pane's own edge); the selected tab's pill against the pane's
left edge (information: a pill also moves when the tabs reflow with the strip's width).
Page windows (D4): each Chromium host of the trace's page rows against its page window (trace) and the page's ring 1
(film): covers the divider, or loses edge columns.
Repeated frames (3e.5): a film frame whose scan lines equal the frame before (or differ only in a few pixels of one
small run inside a pane: a cursor blink, a glyph) shows that frame's picture: every reader reads it with that frame's
sample (`repeats` in the JSON). When the layout due in that frame differs where the scan can see it (an edge on a scan
line moved by 1 device px or more), the window presented an old picture: the frame is late as a whole (m6), and no layer
finding comes from it.
m14 (cmux-ad m14, Lead 2026-11-05): from the same edges as the m6 check, per kind, m6's allowances fail: a frame takes
the first class of scaled (E5, or all three rings narrower by one scale: squeezed), gap (E4), edge (E2, E3, page early 1),
allowed (m6 late: the previous size, anchored top-left, clipped), page_late (m6 page late 1), pass (`m14` in the JSON,
information lines here; the verdict is judge_m14.py's). Per kind also the worst edge offset from its pane edge.
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
OUTSIDE = -3                # 3e.2: past the window's edge (the capture runs on over the desktop): never the app's pixels
CLASS = {0: "black", 1: "blue", 2: "green", 3: "cyan", 4: "red", 5: "magenta", 6: "yellow", 7: "white", OTHER: "other",
         CUE: "cue", OUTSIDE: "outside"}
CODE = {v: k for k, v in CLASS.items()}
ROLE_DEFAULT = {"shell": "#FF00FF", "theme": "#00FFFF", "ring1": "#FF0000", "ring2": "#FFFFFF", "ring3": "#000000", "strip": "#000000"}
SHELL_TOL = 4               # an exact shell pixel: every channel this close to the shell's color
CUE_WIDEN_PT = 40.0         # the cue counts this far from a divider's rect (it trails the divider in a fast drag)
PILL_TOL = 6                # a strip pixel this far (max channel) from the strip's ground is not ground: the pill, text
PILL_BRIDGE = 2             # ground gaps this narrow inside a run (between glyphs) are bridged
PILL_MIN_PX = 12            # the selected tab's pill: the longest run of non-ground pixels, at least this long
PILL_WIDTH_SHARE = 0.25     # a pill run whose width is this share off its rest width is not the pill (a reflow, a title)
HOST_TOL_PX = 0.99          # a page window this far off its host (device px) or more: off
STRIP_REACH_PT = 48.0       # a strip edge is read this far outside its pane's rect (a strip that lags its pane)
STRIP_SHARE = 0.6           # a strip's top on a scan column: this share of its height in the strip class (a glyph may cross)
TOL_PX = 1.0                # device px: an edge this close is in place
SKIP_PT = 24.0              # points walked over (fill and "other": the rulers, glyphs) from the fill to ring 3
NEAR_PT = 48.0              # the walk starts this close to the pane edge
GAP_CAP_PX = 16.0           # a gap counts to the pane's own edge and this far past it (a divider's band)
GROUND_PAD_MAX_PX = 16      # a terminal's ground strip: at most one cell and this much padding (device px); longer: merged
MAX_CANDIDATES = 8          # walks tried per side
LAG_SEARCH = list(range(0, 13)) + [-1, -2, -3]
COMMIT_SLACK_S = 0.0005
MOVE_EPS_PX = 0.01
STILL_SAMPLES = 3           # a motion ends after this many still samples
REST_FALLBACK = 5           # frames used for rest values when nothing rests before the first motion
DIVIDER_RECT_CHECK = "divider rect not centred on its panes' gap"
CLOCK_NOT_FOUND_NOTE = " (clock not found: a lag in motion can be one refresh off)"
CLOCK_OFFSETS = (-1, 0, 1)  # the clock's offsets fitted per film (refreshes later than the fixed clock: + is later)
CLOCK_MIN_FRAMES = 4        # a track votes for the clock with at least this many moving frames that tell offsets apart
SPRING_T0_STEPS = 41        # t0 grid points (coarse, then as many again around the best)
DIVIDER_NEAR_PT = 12.0      # a pane edge this close to a divider's side is that divider's neighbour
NON_SPRING_INPUTS = ("drag", "held keys", "window resize")  # inputs whose motion follows the input by design
INPUT_KEY_WINDOW_S = 0.5    # key presses this long before a motion's first sample count as its input
REPEAT_MAX_PX = 16          # 3e.5: a frame that differs from the frame before in at most this many scan pixels ...
REPEAT_BOX_PX = 24          # ... all on one scan line and within this span (a cursor blink, one glyph) ...
REPEAT_EDGE_PX = 8          # ... and none this close to a pane edge of either frame's sample or on a strip row


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
        # Closing grounds per sample (S3d `closing`: [pane, x, y, width, height, alpha, z] per shown closing ground; the S3
        # sampler skips a host that shows one, so its pane is not in `panes`), in the samples' order.
        closing = sorted(((t0 + float(x.get("t", 0.0)) / 1000.0, [r for r in x.get("closing") or []
                                                                   if isinstance(r, list) and len(r) >= 5])
                          for x in trace.get("samples") or [] if isinstance(x, dict)), key=lambda e: e[0])
        self.closing_rows = [rows for _, rows in closing] if len(closing) == len(self.samples) else [[] for _ in self.samples]
        frame = self.note.get("window_frame") or ((meta.get("window") or {}).get("frame"))
        self.window_x = float(frame[0]) if frame else None
        self.strip_rows = {str(k): int(v) for k, v in ((self.note.get("lines") or {}).get("strip_rows") or {}).items()}
        self.chrome = {str(c.get("pane")): c for c in self.note.get("chrome") or [] if isinstance(c, dict)}
        # The panes' visible area (debug.pane_chrome's main_pane, window points): a pane's part outside it (a column the
        # strip scrolled under the sidebar or past the window's edge) is not on screen and is not read.
        main = self.note.get("main_pane")
        self.main_pane = [float(v) for v in main] if isinstance(main, list) and len(main) == 4 else None
        self.main_pane_source = "note" if self.main_pane else None
        if self.main_pane is None and self.samples and self.samples[0].window[0] > 0:
            # A film from before the note had it: the first sample's leftmost on-screen pane edge (the sidebar's edge at
            # rest) to the window's right edge.
            xs = [float(p[1]) for p in self.samples[0].panes.values() if len(p) >= 5 and float(p[1]) >= 0]
            win_w, win_h = self.samples[0].window
            x0 = min(xs) if xs else 0.0
            self.main_pane = [x0, 0.0, win_w - x0, win_h]
            self.main_pane_source = "the first trace sample (no main_pane in the note)"
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
def _touch_at_stop(outer, stop, step):
    """3e.3: whether a ground run that ends at OUTER (a pixel boundary, outward in STEP) runs on past STOP, the pane's
    own edge where another pane's cell or a closing ground begins: then the run is this pane's ground and the other
    pane's in one color with no boundary between them, and this pane's view edge is not in the pixels."""
    return (outer - stop) * step > 0.5


def walk_side(codes, start, step, kind, roles, fill, skip_px, stop=None):
    """From START (a fill pixel), outward in STEP (-1 or +1): skip fill and "other" up to skip_px, then rings 3, 2, 1,
    then the ground strip (terminal), then what is beyond (a cue run is skipped and counted). Positions are pixel
    boundaries; an "other" pixel between two runs counts half to each. `found`: how many rings were found. STOP (device
    px): the pane's own edge where another pane's cell or a closing ground begins (3e.3): `touch` is True when the
    ground strip runs on past it (_touch_at_stop)."""
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
    widths, edges, pos, cue_px, touch, clipped, unseen = {}, {}, i, 0.0, False, False, []
    cell = 0.0  # ring 1's width: one terminal cell along this line
    merged = False
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
            if codes[pos] == OUTSIDE and role != "theme":
                clipped = True  # 3e.2: a ring past the window's edge
                unseen.append(role)
            continue
        a = pos
        pos = run_end(pos, want)
        if role == "theme" and stop is not None:
            touch = _touch_at_stop(boundary(pos) if 0 <= pos < L else (float(L) if step > 0 else 0.0), stop, step)
        if role == "theme" and cell > 0 and abs(pos - a) > cell + GROUND_PAD_MAX_PX:
            # The ground strip is Ghostty's padding and the whole-cell remainder: at most a cell and the padding. A longer
            # run goes on into a neighbour that shows ground color too (an empty terminal): this pane's view edge does
            # not show on this line.
            merged = True
        widths[role] = float(abs(pos - a))
        if role == "ring1":
            cell = widths[role]
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
            "beyond": beyond, "beyond_px": beyond_px, "gap": gap, "skipped": skipped, "found": found, "cue_px": cue_px,
            "merged": merged, "touch": touch, "clipped": clipped, "unseen": unseen,
            "window_edge": (boundary(pos) if 0 <= pos < L else None) if clipped else None}


TOUCH_NOT_JUDGED = ("its ground strip runs on into another pane's ground past its own edge (two grounds of one color: "
                    "the edge between them is not in the pixels)")


WINDOW_CLIPPED = ("its rings run past the window's edge: its content runs past its pane edge (its offset is a lower "
                  "bound: the rest widths of the rings the window does not show)")


def find_side(codes, a, b, edge, step, kind, roles, fill, near, skip, stop=None):
    """One side of a pane on one line: {status: found | cut | cue | not found, ...walk_side's fields}. STOP: the pane's
    own edge where another pane's cell or a closing ground begins in the shown sample (3e.3, measure): a side whose ground
    runs on past it is not found (not judged, never a pass)."""

    def touched(w):
        if w.get("clipped"):
            # 3e.2: the window's edge cuts this side's rings: judge_m6 judges it against its pane edge (its own status)
            return dict(w, status="clipped", why=WINDOW_CLIPPED, view_edge=None)
        return {"status": "not found", "why": TOUCH_NOT_JUDGED} if w.get("touch") else None

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
    # 3e.2: the fill itself runs into the window's edge near the pane edge (an anti-aliased pixel between may count):
    # every ring of this side is past the window's edge.
    lo_, hi_ = max(0, e - near), min(L, e + near)
    outside = np.flatnonzero(codes[lo_:hi_] == OUTSIDE)
    if len(outside) and step > 0:
        o = lo_ + int(outside[0])
        j = o - 1 if o - 1 >= 0 and codes[o - 1] != OTHER else o - 2
        if j >= 0 and codes[j] == fill:
            return {"status": "clipped", "why": WINDOW_CLIPPED, "rings": [0.0, 0.0, 0.0], "unseen": ["ring3", "ring2", "ring1"],
                    "window_edge": float(o), "view_edge": None, "ring_edge": None, "strip": None, "beyond": "outside",
                    "beyond_px": 0.0, "gap": 0.0, "found": 0, "cue_px": 0.0, "skipped": 0, "clipped": True}
    for c in candidates(e - near, e + near):
        w = walk_side(codes, c, step, kind, roles, fill, skip, stop)
        if w["clipped"]:
            return touched(w)  # 3e.2: the nearest walk to the pane edge reaches the window's edge before its rings end
        if w["found"] >= 2 and w["merged"]:
            return {"status": "not found", "why": "its ground strip runs on into a neighbour's ground"}
        if w["found"] >= 2:
            return touched(w) or dict(w, status="found")
        if w["cue_px"] > 0:
            return dict(w, status="cue")
    for c in candidates(a, b):
        w = walk_side(codes, c, step, kind, roles, fill, skip, stop)
        if w["found"] == 3 and not w["merged"]:
            return touched(w) or dict(w, status="found")
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
                if stop is not None and _touch_at_stop(view_edge, stop, step):
                    return {"status": "not found", "why": TOUCH_NOT_JUDGED}
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


def visible_span(film, lo_pt, hi_pt, axis):
    """[lo, hi) points of a pane's span along a line inside the main pane area, and whether each end is its real edge
    (False: the pane runs on under the sidebar or past the window, so that edge is not on screen)."""
    if not film.main_pane:
        return lo_pt, hi_pt, True, True
    mx, my, mw, mh = film.main_pane
    a, b = (mx, mx + mw) if axis == "row" else (my, my + mh)
    return max(lo_pt, a), min(hi_pt, b), lo_pt >= a - 0.5, hi_pt <= b + 0.5


def band_to_neighbour(sample, pid, axis, side, s):
    """Device px from pane PID's SIDE edge to the nearest pane across it (a pane beyond that edge that shares part of
    its extent across the line's axis: the panes on the far side of the same divider), or None when no pane is
    there (the window's edge). A side's gap runs past its pane edge at most this far: past it, the shell is the
    next pane's (its own side and shell-inside checks judge it), not this pane's gap (FRAME OWNER's 3a: on the
    reduce row drag, the next column's moving row divider crossed p0's line)."""
    me = sample.panes.get(pid)
    (x, y, w, h), _ = pane_rect(me)
    lo, hi, a0, a1 = (x, x + w, y, y + h) if axis == "row" else (y, y + h, x, x + w)
    best = None
    for other, row in sample.panes.items():
        if other == pid or len(row) < 6 or float(row[5]) < 0.99 or float(row[3]) <= 0 or float(row[4]) <= 0:
            continue
        (ox, oy, ow, oh), _ = pane_rect(row)
        olo, ohi, o0, o1 = (ox, ox + ow, oy, oy + oh) if axis == "row" else (oy, oy + oh, ox, ox + ow)
        if min(a1, o1) - max(a0, o0) <= 0:
            continue  # no shared extent: not across this pane's edge
        gap = (olo - hi) if side == "hi" else (lo - ohi)
        if gap >= -0.01 and (best is None or gap < best):
            best = max(0.0, gap)
    return None if best is None else best * s


def touching_edge(film, sample, closing, pid, axis, side, coord_px):
    """3e.3: pane PID's SIDE edge (device px) when, in SAMPLE, another pane's rect that can show the terminal ground color
    at its edge (a terminal's padding; a pane the fixture does not know; faded or not) or a closing ground (CLOSING: the
    sample's S3d `closing` rows) begins at it (within TOL_PX) and spans the line at COORD_PX across it: ground past that
    edge may be the other pane's. A fixture page shows its rings and fill there, never the ground color: no stop (ground
    past the edge into a page is this pane's own). Else None."""
    s = film.scale
    (x, y, w, h), _ = pane_rect(sample.panes[pid])
    lo, hi = (x, x + w) if axis == "row" else (y, y + h)
    edge = (hi if side == "hi" else lo) * s
    for other, row in list(sample.panes.items()) + [(r[0], r) for r in closing]:
        if str(other) == str(pid) or len(row) < 5 or float(row[3]) <= 0 or float(row[4]) <= 0:
            continue
        info = film.panes.get(str(other))
        if info and info["kind"] == "page" and info["fill"] != film.roles["theme"] and not any(r is row for r in closing):
            continue
        (ox, oy, ow, oh), _ = pane_rect(row)
        o_lo, o_hi, a0, a1 = (ox, ox + ow, oy, oy + oh) if axis == "row" else (oy, oy + oh, ox, ox + ow)
        if not a0 * s <= coord_px < a1 * s:
            continue
        if abs((o_lo if side == "hi" else o_hi) * s - edge) <= TOL_PX:
            return edge
    return None


def measure(film, codes, axis, coord_px, sample, closing=()):
    """{pane id: {"lo": side, "hi": side, "span": [lo, hi], "shell_in": px, "has_fill": bool}} for the fixture panes whose
    content (below their tab strip) this line crosses. CLOSING: the sample's S3d closing grounds (3e.3: a side whose ground
    meets another pane's ground at its own edge)."""
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
        vlo, vhi, lo_shown, hi_shown = visible_span(film, lo_pt, hi_pt, axis)
        if vhi - vlo < 1:
            continue
        lo, hi = lo_pt * s, hi_pt * s
        a, b = max(0, int(math.floor(vlo * s))), min(len(codes), int(math.ceil(vhi * s)))
        sides = {}
        for side, step, edge, shown_edge in (("lo", -1, lo, lo_shown), ("hi", +1, hi, hi_shown)):
            if not shown_edge:
                sides[side] = None  # this edge is not on screen
                continue
            stop = touching_edge(film, sample, closing, pid, axis, side, coord_px) if info["kind"] == "tui" else None
            m = find_side(codes, a, b, edge, step, info["kind"], film.roles, info["fill"], near, skip, stop)
            if m.get("view_edge") is not None:
                band = band_to_neighbour(sample, pid, axis, side, s)
                band = GAP_CAP_PX if band is None else min(GAP_CAP_PX, band)
                m["gap"] = min(m.get("gap", 0.0), max(0.0, (edge - m["view_edge"]) * step) + band)
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
    sample's position; lag the samples back that match within TOL_PX. A settle counts a frame with no position as not
    landed (content that does not show has not landed)."""
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
def strip_extent(codes, center, shell, lo=0, hi=None, reach=0):
    """[lo, hi) of this pane's strip on a strip row: the run of non-shell pixels around CENTER, read inside [lo - reach,
    hi + reach) (the pane's own rect of the shown sample, widened by what a strip may lag). A side whose run goes on past
    that range touches a neighbour's strip (no shell between two strips of one color class: narrow panes, a column edge):
    its edge is the pane's own edge there, never the neighbour's far side. None when CENTER is shell."""
    L = len(codes)
    hi = L if hi is None else hi
    a, b = max(0, int(math.floor(lo)) - reach), min(L, int(math.ceil(hi)) + reach)
    c = int(round(center))
    if not a <= c < b or codes[c] == shell:
        return None
    seg = np.flatnonzero(codes[a:b] == shell) + a
    left, right = seg[seg < c], seg[seg > c]
    lo_edge = int(left[-1]) + 1 if len(left) else (int(round(lo)) if a > 0 else 0)
    hi_edge = int(right[0]) if len(right) else (int(round(hi)) if b < L else L)
    return lo_edge, hi_edge


def strip_extent_read(codes, center, shell, lo, hi, reach_lo, reach_hi):
    """(lo, hi) device px of this pane's strip on a strip row, each read from the pixels or None: a side is read when a
    shell pixel bounds the run around CENTER inside [lo - REACH_LO, CENTER) (or (CENTER, hi + REACH_HI)); a side that does
    not reach the shell there (a neighbour's strip touching it, or a strip farther away than the reach) is not read, never
    the pane's own edge (3e.1: cmux's own layer only, never the trace). None when CENTER is shell."""
    L = len(codes)
    a, b = max(0, int(math.floor(lo)) - reach_lo), min(L, int(math.ceil(hi)) + reach_hi)
    c = int(round(center))
    if not a <= c < b or codes[c] == shell:
        return None
    seg = np.flatnonzero(codes[a:b] == shell) + a
    left, right = seg[seg < c], seg[seg > c]
    return (int(left[-1]) + 1 if len(left) else None), (int(right[0]) if len(right) else None)


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


def outside_window(film, codes, axis, k):
    """CODES with OUTSIDE past the window's edge along the line (3e.2): the capture runs on past the window (2872 px of
    scan for a 2722 px window on the minis), and the desktop there is no pixel of the app. The edge is the trace's window
    size in samples k-1 to k+1, the largest (a frame may show the sample before or after on the film's clock): only what
    is past every window the frame can show is masked."""
    near = [film.samples[j].window for j in range(max(0, k - 1), min(len(film.samples), k + 2))]
    sizes = [float(w[0] if axis == "row" else w[1]) for w in near if w and len(w) >= 2 and float(w[0]) > 0 and float(w[1]) > 0]
    if not sizes:
        return codes
    limit = int(math.ceil(max(sizes) * film.scale - 1e-6))
    if limit >= len(codes):
        return codes
    out = codes.copy()
    out[max(0, limit):] = OUTSIDE
    return out


def measure_lines(film, lines, shown):
    """(measured, inside, line_codes) of every scan line with the clock SHOWN (per frame, the sample it shows): per line
    and frame the classes (with the divider cue) and the measurements of every fixture pane the line crosses.
    measured: (pid, line, axis, side) -> per frame a side dict or None; inside: (pid, line, axis) -> per frame (shell px
    inside the pane, has fill) or None; line_codes: line -> per frame codes (the cue marked), for the strips."""
    measured, inside, line_codes = {}, {}, {}
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
            codes = outside_window(film, with_cue(codes_all[f], near_shell[f], divider_bands(film, film.samples[k], axis, coord)),
                                   axis, k)
            per_line.append(codes)
            for pid, m in measure(film, codes, axis, coord, film.samples[k], film.closing_rows[k]).items():
                inside.setdefault((pid, name, axis), [None] * film.n)[f] = (m["shell_in"], m["has_fill"])
                for side in ("lo", "hi"):
                    measured.setdefault((pid, name, axis, side), [None] * film.n)[f] = m[side]
        line_codes[name] = per_line
    return measured, inside, line_codes


def content_value(m, kind, axis, side):
    """The content edge that the clock and the m6 check read from a measured side M of a pane of KIND: for a terminal's
    or an agent's top edge, ring 1's outer edge (the tab strip above may cover the surface's top: then the ground run
    below the strip shortens and the view edge stays at the strip, but ring 1 moves with the surface; 3e.1), None when
    ring 1 is not found (rings cut); else the view edge. None when the side is not judged in that frame."""
    if m is None or m.get("status") not in ("found", "cut"):
        return None
    if axis == "col" and side == "lo" and kind in ("terminal", "agent"):
        return m.get("ring_edge")  # no ring 1 (its rings cut): not read in that frame, never the view edge (another place)
    return m.get("view_edge")


def _vote_track(film, fixed, values, series):
    """(moving frames, hits per offset, the offsets each moving frame matches) of one edge track against the trace
    SERIES on the fixed clock FIXED, or None (no frame at rest, or fewer than CLOCK_MIN_FRAMES moving frames). Frames whose
    three candidate samples (fixed - 1, fixed, fixed + 1) are one position are at rest under any offset (the edge's rest
    offset); frames whose three differ by 1 px or more tell the offsets apart. A frame matches an offset within TOL_PX
    (inclusive), as the lag search matches a sample (a content edge 1 px inside its pane edge follows that sample)."""
    k_max = len(film.samples) - 1
    rest, frames = [], []
    for f in range(film.n):
        k = fixed[f]
        if values[f] is None or k is None or not 1 <= k < k_max:
            continue
        near = [series[j] for j in (k - 1, k, k + 1)]
        if any(v is None for v in near):
            continue
        spread = max(near) - min(near)
        if spread == 0:
            rest.append(f)
        elif spread >= TOL_PX:
            frames.append(f)
    if not rest or len(frames) < CLOCK_MIN_FRAMES:
        return None
    offset = float(np.median([values[f] - series[fixed[f]] for f in rest]))
    near = {f: [o for o in CLOCK_OFFSETS if abs(values[f] - offset - series[fixed[f] - o]) <= TOL_PX] for f in frames}
    return frames, {o: sum(1 for f in frames if o in near[f]) for o in CLOCK_OFFSETS}, near


def fit_clock(film, fixed, measured, strip_x=None, strip_y=None):
    """The film's clock (3d, FRAME OWNER; 3e.1): {"offset": refreshes later than the fixed clock (a frame shows the sample
    FIXED[f] - offset) or None when no offset fits, "status", "why", "votes", "tracks", "page"}. The main window's edges
    vote: each terminal's and agent's content edge track (a pane side on a scan line) and each tab strip edge (its x
    edges on the strip row, STRIP_X; its top on each scan column, STRIP_Y). A page is drawn by another window
    (Chromium's), which presents on its own time: page edges never vote; they give "page" (the same fit over the page
    edges) and "page_window_offset" (the page window's offset against the main window's clock). Per track (_vote_track),
    a track votes for the offset (of CLOCK_OFFSETS) at which more than half of its moving frames are within TOL_PX of the
    trace, and for none when no offset or two do. The clock is the smallest offset any main-window edge votes for: a frame
    composites the geometry of one layout transaction, and a layer can show an older geometry (late) but never a newer
    one, so the edges at the smallest offset show the frame's own sample and the edges at a larger offset are late layers,
    judged as such against that clock. A whole window late (presentation latency, or a trace that samples one tick early
    or late) moves every edge, so every vote moves with it. With no vote: 0 ("not confirmed") when most moving frames
    match some offset, None (clock not found: judged on the fixed clock, with that finding) when most match none; 0 with
    no moving edge (nothing to fit)."""
    groups = {"main": (collections.Counter(), []), "page": (collections.Counter(), [])}

    def add(group, label, values, series):
        got = _vote_track(film, fixed, values, series)
        if got is None:
            return
        frames, hits, near = got
        vote = track_vote(hits, len(frames))
        votes, tracks = groups[group]
        if vote is not None:
            votes[vote] += 1
        tracks.append({"track": label, "frames": len(frames), "within_1px": {f"{o:+d}": n for o, n in hits.items()},
                       "any_offset": sum(1 for f in frames if near[f]), "vote": vote})

    for (pid, name, axis, side), per in sorted(measured.items()):
        kind = m6_kind(film.panes[pid])
        add("page" if kind == "page" else "main", f"{film.panes[pid]['label']} {side} on {name}",
            [content_value(m, kind, axis, side) for m in per], edge_series(film, pid, axis, side))
    for pid, (y, _ext, read) in sorted((strip_x or {}).items()):
        label = film.panes.get(pid, {}).get("label", pid[:12])
        for si, side in ((0, "lo"), (1, "hi")):
            add("main", f"strip {label} {side} on row@{y}", [e[si] if e else None for e in read],
                edge_series(film, pid, "row", side))
    for (pid, name), tops in sorted((strip_y or {}).items()):
        add("main", f"strip {film.panes.get(pid, {}).get('label', pid[:12])} top on {name}", tops,
            edge_series(film, pid, "col", "lo"))
    clock = clock_verdict(*groups["main"])
    page = clock_verdict(*groups["page"])
    clock["page"] = page
    if page["tracks"] and page["offset"] is not None and clock["offset"] is not None:
        clock["page_window_offset"] = page["offset"] - clock["offset"]
    return clock


def track_vote(hits, frames):
    """The offset one edge votes for: the one at which more than half of its FRAMES moving frames are within TOL_PX of
    the trace (HITS: offset -> frames), or None when none is, or when two offsets have the most."""
    best = max(hits.values())
    winners = [o for o, n in hits.items() if n == best]
    return winners[0] if best * 2 > frames and len(winners) == 1 else None


def clock_verdict(votes, tracks):
    """fit_clock's answer from the edges' VOTES (offset -> edges) and TRACKS (each moving edge's frames, within_1px,
    any_offset, vote): the smallest offset voted for; with no vote, 0 ("not confirmed") when most moving frames match
    some offset, None ("not found") when most match none; 0 with no moving edge."""
    moving_tracks = len(tracks)
    clock = {"offsets": list(CLOCK_OFFSETS), "votes": {f"{o:+d}": n for o, n in sorted(votes.items())}, "tracks": tracks}
    if not moving_tracks:
        return dict(clock, offset=0, status="fixed: no motion",
                    why="no edge moved in frames that tell the offsets apart: the fixed clock")
    if not votes:
        total, matched = sum(t["frames"] for t in tracks), sum(t["any_offset"] for t in tracks)
        offsets = ", ".join(f"{o:+d}" for o in CLOCK_OFFSETS)
        if matched * 2 > total:
            return dict(clock, offset=0, status="fixed: not confirmed",
                        why=f"no offset of {offsets} puts more than half of any edge's moving frames within {TOL_PX:g} px "
                            f"of the trace, but {matched} of their {total} moving frames match one of them ({moving_tracks} "
                            "edges moved): the film cannot set its clock, judged on the fixed clock")
        return dict(clock, offset=None, status="not found",
                    why=f"{matched} of the {total} moving frames of {moving_tracks} moving edges are within {TOL_PX:g} px "
                        f"of the trace at any offset of {offsets}")
    o = min(votes)
    agree = [t for t in tracks if t["vote"] == o]
    frames = sum(t["frames"] for t in agree)
    within = sum(t["within_1px"][f"{o:+d}"] for t in agree)
    later = ", ".join(f"{v:+d}: {n}" for v, n in sorted(votes.items()) if v != o)
    return dict(clock, offset=o, status="fitted",
                why=f"{votes[o]} of {moving_tracks} moving edges follow the trace at {o:+d} ({within} of their {frames} "
                    f"moving frames within {TOL_PX:g} px)" + (f"; edges at a later offset (late layers) {later}" if later else ""))


def _line_edges(film, k, axis, coord):
    """The device px of the pane edges that scan line COORD (AXIS "row": a row at y; "col": a column at x) crosses in
    sample K, sorted: a pane's x edges on a row its rect spans, its y edges on a column it spans."""
    if k is None:
        return []
    out = []
    for row in film.samples[k].panes.values():
        if len(row) < 5:
            continue
        (x, y, w, h), _ = pane_rect(row)
        across, along = ((y, y + h), (x, x + w)) if axis == "row" else ((x, x + w), (y, y + h))
        if across[0] * film.scale <= coord < across[1] * film.scale:
            out += [along[0] * film.scale, along[1] * film.scale]
    return sorted(out)


def _scan_moved(film, a, b):
    """Whether the layout of sample B differs from sample A where the scan can see it: on some scan line a pane edge it
    crosses moved by TOL_PX or more (or a pane came onto or left the line). A layout change smaller than a device px, or
    away from every scan line, leaves the scan unchanged and proves no late frame."""
    if a is None or b is None or a == b:
        return False
    for axis, coords in (("row", film.rows), ("col", film.cols)):
        for coord in coords:
            ea, eb = _line_edges(film, a, axis, coord), _line_edges(film, b, axis, coord)
            if len(ea) != len(eb) or any(abs(p - q) >= TOL_PX for p, q in zip(ea, eb)):
                return True
    return False


def _strip_spans(film, k):
    """{strip row y: [(x0, x1) device px of each pane whose tab strip is on that row]} in sample K."""
    out = collections.defaultdict(list)
    if k is None:
        return out
    for pid, y in film.strip_rows.items():
        row = film.samples[k].panes.get(pid)
        if row is not None and len(row) >= 5:
            (x, _, w, _), _ = pane_rect(row)
            out[y].append((x * film.scale, (x + w) * film.scale))
    return out


def find_repeats(film, fixed, shown):
    """3e.5: the film frames that repeat the frame before. A frame repeats it when its scan lines equal the frame
    before's in every pixel, or differ in at most REPEAT_MAX_PX pixels, all on one scan line, within REPEAT_BOX_PX of
    each other, at least REPEAT_EDGE_PX from every pane edge on that line and on no pane's tab strip, in the samples
    of both frames on both clocks (a cursor blink or a glyph inside a pane, never an edge that moved or a strip).
    Returns {"held": {frame: the first frame of its run of repeats}, "late": the repeats whose frame was due to show a
    layout that the scan would show differently (_scan_moved, on the fixed clock FIXED, as E7 reads it): the window
    presented an old picture while the layout moved, late as a whole; "report": the JSON summary}."""
    held, late, near = {}, [], {}
    if not film.has_scan or film.n < 2:
        return {"held": held, "late": late, "report": {"frames": 0, "ranges": "", "late": [], "near_px": {}}}
    lines = [(i, "row", y) for i, y in enumerate(film.rows)] + [(i, "col", x) for i, x in enumerate(film.cols)]
    for f in range(1, film.n):
        changed, n_px = [], 0
        for i, axis, coord in lines:
            px = film.row_px[:, i] if axis == "row" else film.col_px[:, i]
            diff = np.flatnonzero((px[f] != px[f - 1]).any(axis=-1))
            if len(diff):
                changed.append((axis, coord, diff))
                n_px += len(diff)
            if n_px > REPEAT_MAX_PX or len(changed) > 1:
                break
        if n_px:
            if n_px > REPEAT_MAX_PX or len(changed) > 1:
                continue
            axis, coord, diff = changed[0]
            lo_px, hi_px = int(diff.min()), int(diff.max())
            if hi_px - lo_px >= REPEAT_BOX_PX:
                continue
            ks = {fixed[f - 1], fixed[f], shown[f - 1], shown[f]} - {None}
            if any(min(abs(e - lo_px), abs(e - hi_px)) < REPEAT_EDGE_PX for k in ks for e in _line_edges(film, k, axis, coord)):
                continue
            if axis == "row" and any(x0 - REPEAT_EDGE_PX <= hi_px and lo_px <= x1 + REPEAT_EDGE_PX
                                     for k in ks for x0, x1 in _strip_spans(film, k).get(coord, ())):
                continue
            near[str(f)] = n_px
        src = held.get(f - 1, f - 1)
        held[f] = src
        if _scan_moved(film, fixed[src], fixed[f]):
            late.append(f)
    return {"held": held, "late": late,
            "report": {"frames": len(held), "ranges": ranges(sorted(held)), "late": sorted(late), "near_px": near}}


def hold_repeats(clock, held):
    """CLOCK (per frame, the sample it shows) with each repeated frame showing the sample of the frame it repeats."""
    out = list(clock)
    for f in sorted(held):
        out[f] = out[held[f]]
    return out


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
    spring = film.note.get("spring") or None
    reduce = bool(film.note.get("reduce"))
    lines = film.lines()
    # The clock (3d): the fixed clock says a frame at t shows the sample of t minus one refresh; per film, the offset
    # that the film's own edges follow over the moving frames (presentation latency, or a trace sampled a tick off).
    fixed = [film.committed(float(t)) for t in film.t]
    measured, inside, line_codes = measure_lines(film, lines, fixed)
    strip_x, strip_y = strip_x_extents(film, fixed, line_codes), strip_tops(film, fixed, line_codes)
    clock = fit_clock(film, fixed, measured, strip_x, strip_y)
    report["clock"] = clock
    offset = clock["offset"] or 0  # clock not found: the fixed clock, and the finding says so
    shown = [None if k is None or not 0 <= k - offset < len(film.samples) else k - offset for k in fixed]
    # 3e.5: a frame that repeats the frame before shows that frame's sample: on the film's clock every reader below
    # reads and judges it so. The fixed clock is not held: E7 (late as a whole) reads it, and so do the late repeats.
    repeats = find_repeats(film, fixed, shown)
    report["repeats"] = repeats["report"]
    if offset or repeats["held"]:
        shown = hold_repeats(shown, repeats["held"])
        measured, inside, line_codes = measure_lines(film, lines, shown)
        strip_x, strip_y = strip_x_extents(film, shown, line_codes), strip_tops(film, shown, line_codes)
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
    side_rest = {}  # (pid, line, axis, side) -> (rest gap, rest rings) of each side the pane loop judges (3e)

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
        side_rest[key] = (gap_rest, rings_rest)
        strips = [per[f]["strip"] for f in pool if per[f].get("strip") is not None]
        strip_rest = float(np.median(strips)) if strips else None
        other = measured.get((pid, name, axis, "lo")) if side == "hi" else None
        worst = {"gap_dev": 0.0, "hidden": 0, "cut": 0, "strip_max": None, "remainder_max": None, "backdrop": 0,
                 "backdrop_max": 0.0}
        lists = {"not_found": [], "cue": [], "clipped": []}
        for f in range(film.n):
            m = per[f]
            if m is None:
                continue
            entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name, "pane": pid,
                     "label": info["label"], "side": side, "status": m.get("status")}
            problems = []
            status = m.get("status")
            if status == "clipped":
                lists["clipped"].append(f)
                entry.update(why=m["why"], rings=m["rings"], unseen=m.get("unseen"))
                entry["problems"] = problems  # the verdict is judge_m6's (a fail, or not judged for a growing terminal)
                add_frame(f, entry)
                continue
            if status == "not found":
                lists["not_found"].append(f)
                if m.get("why"):
                    entry["why"] = m["why"]  # why the side is not judged in this frame (3e.3: two grounds touch)
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
            rest={"edge_err": track["rest_offset"], "gap": gap_rest, "strip": strip_rest, "rings": rings_rest},
            max_gap_px=round(worst["gap_dev"], 2), hidden_ring_frames=worst["hidden"], cut_ring_frames=worst["cut"],
            not_found_frames=len(lists["not_found"]), not_found_ranges=ranges(lists["not_found"]),
            cue_frames=len(lists["cue"]), cue_ranges=ranges(lists["cue"]), clipped_frames=len(lists["clipped"]),
            clipped_ranges=ranges(lists["clipped"]), strip_max_px=worst["strip_max"],
            remainder_max_px=worst["remainder_max"], backdrop_frames=worst["backdrop"], backdrop_max_px=worst["backdrop_max"])

    judge_inside(film, shown, inside, rest_frames, summary, add_frame)

    judge_divider_rects(film, dividers, summary)
    strips = judge_strips(film, shown, rest_frames, spring, reduce, summary, add_frame, line_codes, strip_x, strip_y, fixed)
    judge_page_windows(film, shown, measured, summary, add_frame)
    report["m6"] = judge_m6(film, shown, measured, side_rest, strips, repeats["late"])
    report["m14"] = report["m6"].pop("m14")  # cmux-ad m14: the same edges, m6's allowances failed (judge_m14.py)
    if film.main_pane_source and film.main_pane_source != "note" and film.main_pane[0] > 0:
        report["notes"].append(f"the panes' visible area {film.main_pane} is from {film.main_pane_source}")
    if film.note.get("page_backdrop") is not False and any(i["kind"] == "page" for i in film.panes.values()):
        report["notes"].append("the page backdrop was on (browserResize.pageBackdrop: "
                               f"{film.note.get('page_backdrop')!r}): a page that lags a growing pane shows its own fill past its "
                               "rings (backdrop_frames), not the shell")
    report["summary"] = summary
    report["frame_findings"] = [{"f": f, "entries": frames_out[f]} for f in sorted(frames_out)]
    report["findings"], report["info"] = findings_of(report)
    m6_findings, m6_info = m6_findings_of(report["m6"])
    report["findings"] += m6_findings
    report["info"] += m6_info + m14_info_of(report["m14"])
    report["info"].insert(0, {"check": "clock", "where": "film", "detail": f"offset {offset:+d} ({clock['status']}): "
                                                                          f"{clock['why']}"})
    if "page_window_offset" in clock:
        page = clock["page"]
        report["info"].insert(1, {"check": "page window offset", "where": "film",
                                  "detail": f"{clock['page_window_offset']:+d} refresh(es) against the main window's clock "
                                            f"(the page edges fit {page['offset']:+d}, the main window {offset:+d}: "
                                            f"{page['why']})"})
    if clock["offset"] is None:
        # Every finding read from the film's frames was judged on the fixed clock (3d.1): it says so. A trace row's
        # finding (on trace) does not depend on the clock.
        for f in report["findings"]:
            if not f["where"].endswith(" on trace"):
                f["detail"] += CLOCK_NOT_FOUND_NOTE
        report["findings"].insert(0, {"check": "clock not found", "where": "film",
                                      "detail": f"{clock['why']}: judged on the fixed clock, so a lag or a deviation in "
                                                "motion can be one refresh off (at rest the clock does not matter)"})
    elif clock["offset"]:
        report["findings"].insert(0, {"check": "presentation offset", "where": "film",
                                      "detail": f"{clock['offset']:+d} refresh(es): the film shows the trace sample "
                                                f"{clock['offset']:+d} refresh(es) from the fixed clock's (a frame at t shows "
                                                f"the sample of t minus {1 + clock['offset']} refreshes); every layer is "
                                                f"judged against this clock; {clock['why']}"})
    return report


def judge_inside(film, shown, inside, rest_frames, summary, add_frame):
    """The shell inside each pane: one row per pane and line (side "inside"), never on its side rows. measure() counts it
    in the pane's whole visible span on the line, so it is no side's; on both side rows it was each defect twice (FRAME
    OWNER's 3c). INSIDE: (pid, line, axis) -> per frame (shell px, has fill) or None. A line that shows none of the
    pane's fill at rest (a ring row or its strip) is not judged. The rest count is the median over the rest frames that
    measure the pane (the first REST_FALLBACK frames when none do); a frame more than 0.5 px above it shows the shell
    inside the pane. No fill: the frames that show none of the pane's fill on the line."""
    for (pid, name, axis), per in sorted(inside.items()):
        info = film.panes[pid]
        rest_pool = [f for f in rest_frames if per[f] is not None] or [f for f in range(film.n) if per[f] is not None][:REST_FALLBACK]
        if not any(per[f][1] for f in rest_pool):
            continue  # the line shows none of the pane's fill at rest: not judged
        shell_rest = float(np.median([per[f][0] for f in rest_pool]))
        shell_in, no_fill, shell_max = [], [], 0.0
        for f in range(film.n):
            if per[f] is None:
                continue
            shell_px, has_fill = per[f]
            entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name, "pane": pid,
                     "label": info["label"], "side": "inside", "shell_px": shell_px}
            if not has_fill:
                no_fill.append(f)
                entry["no_fill"] = True
            if shell_px > shell_rest + 0.5:
                shell_in.append(f)
                shell_max = max(shell_max, shell_px - shell_rest)
                entry["shell_in"] = shell_px
                entry["problems"] = [f"shell inside the pane: {shell_px - shell_rest:.0f} px"]
            add_frame(f, entry)
        summary[f"{info['label']}:{pid}:{name}:inside"] = row_summary(
            "pane", pid, info["label"], "agent" if info["agent"] else info["kind"], name, "inside",
            rest={"shell_in": shell_rest}, shell_in_frames=len(shell_in), shell_in_ranges=ranges(shell_in),
            shell_in_max_px=round(shell_max, 1), no_fill_frames=len(no_fill), no_fill_ranges=ranges(no_fill))


def divider_panes(sample, rect, axis, closing=()):
    """(left, right): the two panes trace divider RECT separates in SAMPLE, as (pane id, edge in points), or None on a
    side with no pane. Any pane row counts, and each row of CLOSING (the sample's S3d `closing` grounds: with S3 a closing
    pane keeps its ground in its slot during the close, beside its own divider, and the sampler records it there, not in
    `panes`; frame-owner-s3b), fixture or not, faded or not. A pane shares part of the
    divider's extent across it; on the lo side, a pane that starts before the divider's centre and ends within
    DIVIDER_NEAR_PT of the rect; on the hi side, one that ends after the centre and starts within DIVIDER_NEAR_PT of it.
    On each side the pane whose edge is nearest the centre: the one beside the divider, not the next one past it."""
    x, y, w, h = rect
    lo, hi, c0, c1 = (x, x + w, y, y + h) if axis == "row" else (y, y + h, x, x + w)
    centre = (lo + hi) / 2
    left = right = None
    for pid, row in list(sample.panes.items()) + [(r[0], r) for r in closing]:
        if len(row) < 5 or float(row[3]) <= 0 or float(row[4]) <= 0:
            continue
        (px_, py_, pw_, ph_), _ = pane_rect(row)
        p_lo, p_hi, p0, p1 = (px_, px_ + pw_, py_, py_ + ph_) if axis == "row" else (py_, py_ + ph_, px_, px_ + pw_)
        if min(c1, p1) - max(c0, p0) <= 0:
            continue  # not beside the divider across its extent
        if p_lo < centre and lo - DIVIDER_NEAR_PT <= p_hi <= hi + DIVIDER_NEAR_PT \
                and (left is None or abs(p_hi - centre) < abs(left[1] - centre)):
            left = (str(pid), p_hi)
        if p_hi > centre and lo - DIVIDER_NEAR_PT <= p_lo <= hi + DIVIDER_NEAR_PT \
                and (right is None or abs(p_lo - centre) < abs(right[1] - centre)):
            right = (str(pid), p_lo)
    if left is not None and right is not None and left[0] == right[0]:
        return None, None  # one pane on both sides: it covers the divider; no gap to judge
    return left, right


def judge_divider_rects(film, dividers, summary):
    """Pair C (FRAME OWNER): the film never shows a divider layer (the fixture's divider band shows the shell), so a
    divider is judged from the trace alone. Per divider, per sample: the rect's centre against the middle of the gap
    between the two panes it separates (divider_panes), in device px; >= TOL_PX is off. One summary row per divider
    (what "divider rect", line "trace", side "mid"; its off spans are samples), labelled by its panes at the last
    sample judged."""
    s = film.scale
    closing = getattr(film, "closing_rows", None) or []  # S3d grounds per sample (a film without the key: none)
    for did, (axis, centres, rects) in sorted(dividers.items(), key=lambda kv: str(kv[0])):
        per, pair = {}, None
        for k, rect in enumerate(rects):
            if rect is None:
                continue
            left, right = divider_panes(film.samples[k], rect, axis, closing[k] if k < len(closing) else ())
            if left is None or right is None:
                continue
            per[k] = {"dev": round(centres[k] - (left[1] + right[1]) / 2 * s, 2), "lag": None}
            pair = (left[0], right[0])
        if pair is None:
            continue  # no sample shows a pane on each side of it
        stats = track_stats(per)
        names = [film.panes.get(p, {}).get("label", p) for p in pair]
        off = [k for k, t in per.items() if abs(t["dev"]) >= TOL_PX]
        detail = (f"{len(off)} of {len(per)} trace samples off the middle of its panes' gap by >= {TOL_PX:g} px (samples "
                  f"{ranges(off)}); max {stats['max_edge_dev_px']:+.1f} px") if off else f"{len(per)} trace samples centred"
        summary[f"divider:{did}:trace"] = row_summary("divider rect", did, f"divider {names[0]}|{names[1]}", "divider", "trace",
                                                      "mid", None, divider=did, detail=detail, **stats)


M6_KINDS = ("terminal", "page", "agent")
M6_RULES = ("E2", "E3", "E4", "E5", "page early 1")
# cmux-ad m14 (Lead 2026-11-05): a frame of a kind takes the first class that applies; every class but pass fails.
M14_FAIL_CLASSES = ("scaled", "gap", "edge", "allowed", "page_late")
M14_ORDER = M14_FAIL_CLASSES + ("pass", "not judged")
M14_OF_M6 = {"pass": "pass", "late": "allowed", "page late 1": "page_late", "not judged": "not judged"}


def m6_kind(info):
    """The content kind of a fixture pane for the m6 contract: agent, terminal (tui) or page."""
    return "agent" if info.get("agent") else {"tui": "terminal", "page": "page"}.get(info.get("kind"), info.get("kind"))


def _previous_distinct(values):
    """Per frame, the last earlier frame whose value is not None and differs from this frame's (None: none): the frame
    before as the screen showed it, so a repeated frame (a dropped refresh) does not widen a one-refresh allowance."""
    prev, runs = [None] * len(values), []  # runs: (first frame, value) of each run of one value
    for f, v in enumerate(values):
        if v is None:
            continue
        if runs and runs[-1][1] == v:
            prev[f] = runs[-2][0] if len(runs) > 1 else None
            prev[f] = None if prev[f] is None else max(g for g in range(prev[f], f) if values[g] == runs[-2][1])
        else:
            prev[f] = None if not runs else max(g for g in range(runs[-1][0], f) if values[g] == runs[-1][1])
            runs.append((f, v))
    return prev


def m6_edge_verdict(kind, side, c, cur, prev, nxt=None):
    """(verdict, rule) of one content edge at C (device px, its rest offset taken off) against its pane's edges (lo, hi)
    in the current frame CUR and the frame before PREV (either side None when not shown): E2 for a lo edge (top-left
    anchored: the current lo edge, within TOL_PX inclusive; a page also the previous frame's: "page late 1"), E3 for a
    hi edge (the current hi edge: pass; the previous frame's size anchored at the current lo edge, clipped at the
    current hi edge: "late"). NXT: the pane's edges in the next frame whose edge differs; a page lo edge on it is EARLY
    (rule "page early 1": the page window ahead of the main window), a failure counted on its own."""
    lo_i, hi_i = 0, 1
    si = lo_i if side == "lo" else hi_i
    if abs(c - cur[si]) <= TOL_PX:
        return "pass", None
    if side == "lo":
        if kind == "page" and prev is not None and prev[lo_i] is not None and abs(c - prev[lo_i]) <= TOL_PX:
            return "page late 1", None
        if kind == "page" and nxt is not None and nxt[lo_i] is not None and abs(c - nxt[lo_i]) <= TOL_PX \
                and abs(nxt[lo_i] - cur[lo_i]) > TOL_PX:
            return "fail", "page early 1"
        return "fail", "E2"
    if prev is not None and None not in prev and cur[lo_i] is not None:
        late_at = min(cur[lo_i] + (prev[hi_i] - prev[lo_i]), cur[hi_i])
    else:
        late_at = prev[hi_i] if prev is not None else None
    if late_at is not None and abs(c - late_at) <= TOL_PX:
        return "late", None
    return "fail", "E3"


def _next_distinct(values):
    """Per frame, the first later frame whose value is not None and differs from this frame's (None: none)."""
    out, nxt, cur_v = [None] * len(values), None, None
    for f in range(len(values) - 1, -1, -1):
        v = values[f]
        if v is None:
            continue
        if cur_v is not None and v != cur_v:
            nxt = last_start
        if v != cur_v:
            last_start, cur_v = f, v
        out[f] = nxt
    return out


def judge_m6(film, shown, measured, side_rest, strips, late_repeats=()):
    """3e, the judge part of cmux-ad m6 1d (FRAME OWNER): per film frame and content kind (terminal, page, agent), each
    content edge against its pane edge as cmux's own layer shows it in the same film frame (3e.1: never the trace): the
    pane's tab strip on its strip row (x edges) and the strip's top on each scan column that crosses it (the pane's top
    edge; a terminal's or agent's top content edge is ring 1, which moves with its surface). A pane edge that no layer
    shows (a pane with no strip; its bottom edge) is not judged, never a pass. Each edge, after its rest offset:
      E2  a lo edge (top-left anchored) on the current frame's pane edge, within TOL_PX; a page's also on the previous
          frame's ("page late 1": the interim browser contract until S5);
      E3  a hi edge on the current pane edge (pass) or on the previous frame's size anchored at the current lo edge and
          clipped at the current hi edge ("late"); the previous frame is the last one whose strip differs (a dropped
          refresh does not widen the allowance); for the trace source, the previous sample;
      E4  never the shell beyond it (gap over its rest: the page's own backdrop and the terminal's own ground are no gap);
      E5  never stretched (a ring wider than at rest by more than TOL_PX).
    A page edge on the NEXT frame's pane edge fails as "page early 1" (the page window ahead of the main window). A frame
    of a kind: fail if an edge fails, else late, else page late 1, else pass; not judged when none of its edges can be
    judged. E7: frames where every strip edge (x on the strip rows, the strip tops on the columns) that moved into the
    frame's sample on the fixed clock is one sample late are late as a whole (the window presented the whole frame late);
    against the film's own clock (3d) a whole-late film shows none (its clock took the lag), so E7 reads the fixed clock. Program grid size per press (E8) is not a film fact.
    3e.3: a terminal side whose ground runs on into another pane's ground past its own edge has no content edge in the
    pixels: it is not judged (never a pass); per kind, `touch_not_judged` counts those edges and
    `touch_not_judged_ranges` gives their frames."""
    edges = strips.get("edges") or {}
    tops = strips.get("tops") or {}
    prev_strip = {pid: _previous_distinct(ext) for pid, ext in edges.items()}
    prev_top = {key: _previous_distinct(t) for key, t in tops.items()}
    next_strip = {pid: _next_distinct(ext) for pid, ext in edges.items()}
    next_top = {key: _next_distinct(t) for key, t in tops.items()}
    frames = {kind: collections.defaultdict(list) for kind in M6_KINDS}  # kind -> frame -> [edge verdicts]
    edge_counts = {kind: collections.Counter() for kind in M6_KINDS}
    rules = {kind: collections.Counter() for kind in M6_KINDS}
    rule_frames = {kind: collections.defaultdict(set) for kind in M6_KINDS}  # kind -> rule -> frames that fail it
    sources = {kind: collections.Counter() for kind in M6_KINDS}
    touch_edges = collections.Counter()  # kind -> edges not judged because two grounds touch (3e.3)
    touch_frames = {kind: set() for kind in M6_KINDS}
    clipped_edges = collections.Counter()  # kind -> edges whose rings the window clips (3e.2: a fail, offset a lower bound)
    clipped_grid = collections.Counter()  # kind -> terminal edges the window cuts while the pane grows (not judged)
    m14_frames = {kind: collections.defaultdict(list) for kind in M6_KINDS}  # kind -> frame -> [(class, dev px, edge)]
    for key, per in sorted(measured.items()):
        if key not in side_rest:
            continue  # a side the pane loop does not judge (no fill on the line at rest)
        pid, name, axis, side = key
        kind = m6_kind(film.panes[pid])
        if kind not in frames:
            continue
        gap_rest, rings_rest = side_rest[key]
        si = 0 if side == "lo" else 1
        if axis == "row":
            strip, prev_i, next_i, source = edges.get(pid), prev_strip.get(pid), next_strip.get(pid), "strip"
            to_pair = lambda v: v
        else:  # a y edge: the pane's strip top on this scan column, as the pane's lo edge (3e.1); its hi edge: no layer
            strip, prev_i, next_i, source = tops.get((pid, name)), prev_top.get((pid, name)), next_top.get((pid, name)), "strip top"
            to_pair = lambda v: None if v is None else (v, None)
        if axis == "col" and side == "hi":
            strip = None  # a pane's bottom edge: no layer of cmux shows it on a scan column (not judged)
        series = {"lo": edge_series(film, pid, axis, "lo"), "hi": edge_series(film, pid, axis, "hi")}

        def pane_at(f):
            """((lo, hi) of the pane edge in frame f, in the frame before, in the next frame that differs), each None
            where not shown. From cmux's own layer only (the tab strip); a pane edge no layer shows is None (not judged,
            never the trace)."""
            if strip is None:
                return None, None, None
            g, h = prev_i[f], next_i[f]
            return to_pair(strip[f]), (to_pair(strip[g]) if g is not None else None), \
                (to_pair(strip[h]) if h is not None else None)

        values = [content_value(m, kind, axis, side) for m in per]
        rest = [f for f in range(film.n) if values[f] is not None and (pane_at(f)[0] or (None, None))[si] is not None]
        offset = float(np.median([values[f] - pane_at(f)[0][si] for f in rest[:REST_FALLBACK * 4]])) if rest else 0.0
        edge_name = f"{film.panes[pid].get('label') or pid} {name} {side}"
        for f in range(film.n):
            m = per[f]
            if m is not None and m.get("why") == TOUCH_NOT_JUDGED:
                touch_edges[kind] += 1
                touch_frames[kind].add(f)
                continue
            if m is not None and m.get("status") == "clipped":
                # 3e.2: the window clips this side's rings while its pane edge, as cmux's layer shows it, is on the window
                # or inside it: the content runs past its pane edge. m6 E2 (lo) or E3 (hi); m14 class edge; the offset is
                # a lower bound: from the pane edge to the window's edge, and the rest widths of the rings not shown.
                # The pane loop measures only a side whose pane edge is on screen (visible_span), so the pane edge is at
                # the window's edge or inside it: the strip's edge where the strip shows it, else (its run reaches the
                # window's edge) the window's edge, and the bound is then the rings not shown.
                cur, prev_pane, _ = pane_at(f)
                grows = None
                if kind != "page":
                    # A terminal draws only inside its view. While its pane grows on this axis (its other edge, as the strip
                    # shows it, moves away from this one since the frame before), the press's final grid is wider than the
                    # view and the view cuts it: one program grid per press, not judged. Otherwise (the pane shrinks or
                    # rests) the rings cut at the window's edge are a view wider than its pane: a fail, as for a page.
                    if cur is None or prev_pane is None or cur[0] is None or prev_pane[0] is None:
                        grows = True  # the other edge is not shown: the grid case cannot be ruled out
                    else:
                        grows = (prev_pane[0] - cur[0]) * (1 if side == "hi" else -1) >= TOL_PX
                if m.get("window_edge") is None or grows:
                    frames[kind][f].append("not judged")
                    edge_counts[kind]["not judged"] += 1
                    m14_frames[kind][f].append(("not judged", None, edge_name))
                    if grows:
                        clipped_grid[kind] += 1
                    continue
                pane_edge = cur[si] if cur is not None and cur[si] is not None else m["window_edge"]
                hidden = sum(rings_rest[r] or 0.0 for r, role in enumerate(("ring1", "ring2", "ring3"))
                             if role in (m.get("unseen") or ()))
                step = 1 if side == "hi" else -1
                bound = max(TOL_PX, (m["window_edge"] - pane_edge) * step + hidden)
                rule = "E3" if side == "hi" else "E2"
                rules[kind][rule] += 1
                rule_frames[kind][rule].add(f)
                frames[kind][f].append("fail")
                edge_counts[kind]["fail"] += 1
                m14_frames[kind][f].append(("edge", round(float(bound) * step, 2), edge_name + " (clipped: offset >=)"))
                clipped_edges[kind] += 1
                continue
            if m is None or m.get("status") not in ("found", "cut"):
                continue
            cur, prev, nxt = pane_at(f)
            dev = None
            if values[f] is None or cur is None or cur[si] is None or not rest:
                verdict, rule = "not judged", None  # E2 and E3 need the pane edge as shown and the content edge
            else:
                sources[kind][source] += 1
                verdict, rule = m6_edge_verdict(kind, side, values[f] - offset, cur, prev, nxt)
                dev = round(float(values[f] - offset - cur[si]), 2)  # m14: this edge's offset from its pane edge
            # E4 and E5 are facts of the content itself: they hold whether or not a layer shows the pane edge.
            # E4 and E5 explain an edge that is off: a shell gap shortens the content, a stretched ring moves its outer
            # edge. When one of them fails, the edge's E2 or E3 is not counted again (the frame fails either way).
            if m.get("gap", 0.0) - gap_rest >= TOL_PX:
                verdict, rule = "fail", "E4"
                rules[kind]["E4"] += 1
                rule_frames[kind]["E4"].add(f)
            if any(rings_rest[r] is not None and m["rings"][r] > rings_rest[r] + TOL_PX for r in range(3)):
                verdict, rule = "fail", "E5"
                rules[kind]["E5"] += 1
                rule_frames[kind]["E5"].add(f)
            if verdict == "fail" and rule in ("E2", "E3", "page early 1"):
                rules[kind][rule] += 1
                rule_frames[kind][rule].add(f)
            frames[kind][f].append(verdict)
            edge_counts[kind][verdict] += 1
            # m14: the same edge's class. Squeezed (m14_squeezed): content scaled down, as E5 is content scaled up.
            if rule == "E5" or m14_squeezed(m, rings_rest):
                m14_class = "scaled"
            elif rule == "E4":
                m14_class = "gap"
            elif verdict == "fail":
                m14_class = "edge"
            else:
                m14_class = M14_OF_M6[verdict]
            m14_frames[kind][f].append((m14_class, dev, edge_name))
    out = {"kinds": {}}
    order = ("fail", "late", "page late 1", "pass")
    for kind in M6_KINDS:
        per_frame = {}
        for f, verdicts in frames[kind].items():
            judged = [v for v in verdicts if v != "not judged"]
            per_frame[f] = next((v for v in order if v in judged), "not judged")
        if not per_frame:
            continue
        by = {v: sorted(f for f, w in per_frame.items() if w == v) for v in order + ("not judged",)}
        out["kinds"][kind] = {"frames": len(per_frame), "pass": len(by["pass"]), "late": len(by["late"]),
                              "page_late_1": len(by["page late 1"]), "fail": len(by["fail"]),
                              "not_judged": len(by["not judged"]), "fail_ranges": ranges(by["fail"]),
                              "late_ranges": ranges(by["late"]), "page_late_1_ranges": ranges(by["page late 1"]),
                              "not_judged_ranges": ranges(by["not judged"]),
                              "fail_by_rule": {r: rules[kind][r] for r in M6_RULES},
                              "fail_frames_by_rule": {r: ranges(rule_frames[kind][r]) for r in M6_RULES},
                              "sources": dict(sources[kind]), "edges": dict(edge_counts[kind]),
                              "touch_not_judged": touch_edges[kind], "touch_not_judged_ranges": ranges(touch_frames[kind]),
                              "clipped_edges": clipped_edges[kind], "clipped_grid_not_judged": clipped_grid[kind]}
    late = sorted(set(f for f, lags in (strips.get("lags_fixed") or {}).items() if lags and all(v == 1 for v in lags))
                  | set(late_repeats))
    out["late_as_a_whole"], out["late_as_a_whole_ranges"] = len(late), ranges(late)
    out["m14"] = m14_rows(m14_frames, touch_edges, touch_frames, out)
    return out


def m14_squeezed(m, rings_rest):
    """Whether side M shows its content scaled down (cmux-ad m14): all three rings found, rings 2 and 3 narrower than at
    rest by more than TOL_PX, and ring 1 not wider than its rest width at the larger of rings 2's and 3's scales plus
    TOL_PX (one scale for all three rings). A clip cuts only the ring it reaches, and an overlay (a menu over rings 2 and 3,
    ring 1 left at its rest width: R-HARNESS's review of 7cfd91442ece) does not scale ring 1: neither is a squeeze."""
    rings = m.get("rings") or [0.0, 0.0, 0.0]
    if m.get("status") != "found" or any(not rings_rest[r] or rings[r] <= 0 for r in range(3)):
        return False
    if not all(rings[r] < rings_rest[r] - TOL_PX for r in (1, 2)):
        return False
    scale = max(rings[1] / rings_rest[1], rings[2] / rings_rest[2])
    return rings[0] <= rings_rest[0] * scale + TOL_PX


def m14_rows(m14_frames, touch_edges, touch_frames, m6):
    """cmux-ad m14 per kind, from the edges judge_m6 judged (the same rest offsets and pane edges): frames (with an edge
    measured), judged (with a judged edge), pass, fail (+ ranges), a count and ranges per fail class, not judged,
    touch_not_judged (3e.3), and the worst edge offset from its pane edge (device px; its frame and edge). Late as a
    whole (E7 and 3e.5's repeats: the window presented a whole old frame) is m6's, information, not a content class."""
    kinds = {}
    for kind in M6_KINDS:
        frames = m14_frames[kind]
        if not frames:
            continue
        per_frame, worst = {}, (0.0, None, None)
        for f, edges in frames.items():
            classes = {c for c, _, _ in edges}
            per_frame[f] = next(c for c in M14_ORDER if c in classes)
            for _, dev, where in edges:
                if dev is not None and abs(dev) > abs(worst[0]):
                    worst = (dev, f, where)
        by = {c: sorted(f for f, w in per_frame.items() if w == c) for c in M14_ORDER}
        fail = sorted(f for c in M14_FAIL_CLASSES for f in by[c])
        kinds[kind] = {"frames": len(per_frame), "judged": len(per_frame) - len(by["not judged"]), "pass": len(by["pass"]),
                       "fail": len(fail), "fail_ranges": ranges(fail),
                       **{c: len(by[c]) for c in M14_FAIL_CLASSES}, **{f"{c}_ranges": ranges(by[c]) for c in M14_FAIL_CLASSES},
                       "not_judged": len(by["not judged"]), "not_judged_ranges": ranges(by["not judged"]),
                       "touch_not_judged": touch_edges[kind], "touch_not_judged_ranges": ranges(touch_frames[kind]),
                       "worst_px": abs(worst[0]), "worst_signed_px": worst[0], "worst_frame": worst[1], "worst_edge": worst[2]}
    return {"kinds": kinds, "late_as_a_whole": m6["late_as_a_whole"], "late_as_a_whole_ranges": m6["late_as_a_whole_ranges"]}


def m14_info_of(m14):
    """Information lines of the m14 contract per kind (never a defect: the judge's exit stays m6's; judge_m14.py gives the
    m14 verdict)."""
    info = []
    for kind, row in (m14.get("kinds") or {}).items():
        classes = ", ".join(f"{c} {row[c]}" for c in M14_FAIL_CLASSES if row[c])
        info.append({"check": "m14 contract", "where": f"{kind} content",
                     "detail": f"{row['fail']} of {row['judged']} judged frames fail" + (f" ({classes}; frames {row['fail_ranges']})"
                                                                                      if row["fail"] else "")
                               + f"; worst edge {row['worst_px']:g} px" + (f" (frame {row['worst_frame']}, {row['worst_edge']})"
                                                                           if row["worst_frame"] is not None else "")
                               + f"; {row['not_judged']} frames not judged, {row['touch_not_judged']} touching edges not judged"})
    return info


def m6_findings_of(m6):
    """(defects, information) of the m6 check: a finding per kind with a failing frame; information per kind (its counts)
    and the late-as-a-whole count."""
    out, info = [], []
    for kind, row in (m6.get("kinds") or {}).items():
        counts = (f"{row['pass']} pass, {row['late']} late, {row['page_late_1']} page late 1, {row['fail']} fail, "
                  f"{row['not_judged']} not judged of {row['frames']} frames")
        if row["fail"]:
            rules = ", ".join(f"{r} {n}" for r, n in row["fail_by_rule"].items() if n)
            out.append({"check": "m6 contract", "where": f"{kind} content",
                        "detail": f"{row['fail']} of {row['frames']} frames fail (frames {row['fail_ranges']}; edges: {rules}); "
                                  f"{counts}"})
        info.append({"check": "m6 contract", "where": f"{kind} content", "detail": counts})
    if m6.get("late_as_a_whole"):
        info.append({"check": "late as a whole", "where": "film",
                     "detail": f"{m6['late_as_a_whole']} frame(s) with every tab strip one sample late: the window presented "
                               f"the whole frame late (frames {m6['late_as_a_whole_ranges']})"})
    return out, info


def strip_x_extents(film, shown, line_codes):
    """{pid: (strip row y, ext, read)}: per frame (lo, hi) device px of the pane's tab strip on its strip row, None where
    the row is outside the strip's height now or no strip is found. EXT: as the strip rows have judged it (a side None
    when not on screen; a side that does not reach the shell inside the pane's rect is the pane's own edge there).
    READ: each side only as read from the pixels (strip_extent_read, the reach on each side shown), else None: cmux's own
    layer, the panes' x edges in each film frame, for the clock and the m6 check (never the trace)."""
    rows = {y: i for i, y in enumerate(film.rows)}
    shell = film.roles["shell"]
    out = {}
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
        codes_line = line_codes.get(f"row@{y}") or classify(film.row_px[:, rows[y]])
        ext, read = [None] * film.n, [None] * film.n
        for f in range(film.n):
            k = shown[f]
            row = film.samples[k].panes.get(pid) if k is not None else None
            if row is None or len(row) < 6 or float(row[5]) < 0.99:
                continue
            (x, py, w, h), _ = pane_rect(row)
            top = (py + off_y) * film.scale
            if not top + 1 <= y <= top + strip_h * film.scale - 1:
                continue
            vlo, vhi, lo_shown, hi_shown = visible_span(film, x, x + w, "row")
            if vhi - vlo < 1:
                continue
            codes = np.where(codes_line[f] == CUE, shell, codes_line[f])  # the cue is not the strip
            reach = int(STRIP_REACH_PT * film.scale)
            e = strip_extent(codes, (vlo + vhi) / 2 * film.scale, shell, vlo * film.scale, vhi * film.scale,
                             reach if lo_shown and hi_shown else 0)
            ext[f] = (e[0] if lo_shown else None, e[1] if hi_shown else None) if e else None
            r = strip_extent_read(codes, (vlo + vhi) / 2 * film.scale, shell, vlo * film.scale, vhi * film.scale,
                                  reach if lo_shown else 0, reach if hi_shown else 0)
            read[f] = (r[0] if lo_shown else None, r[1] if hi_shown else None) if r else None
        out[pid] = (y, ext, read)
    return out


def strip_top_on_line(codes, strip_code, expected, height, reach):
    """The y (device px) of a tab strip's top on one scan column's CODES: the first strip-class pixel below a pixel of
    another class (or at the line's first pixel), with at least STRIP_SHARE of the next HEIGHT pixels in the strip class
    (a glyph of the pill may cross the column; a neighbour's ring 3 or a terminal's cell row of black is shorter or
    farther), nearest EXPECTED within REACH; None when there is none."""
    lo, hi = max(0, int(expected - reach)), min(len(codes) - height, int(expected + reach))
    best = None
    for y in range(lo, hi + 1):
        if codes[y] == strip_code and (y == 0 or codes[y - 1] != strip_code) \
                and float(np.mean(codes[y:y + height] == strip_code)) >= STRIP_SHARE \
                and (best is None or abs(y - expected) < abs(best - expected)):
            best = y
    return best


def strip_tops(film, shown, line_codes):
    """{(pid, column line): per frame the y (device px) of the pane's tab strip top on that scan column, or None}: cmux's
    own layer, the panes' top edges in each film frame (3e.1). A column reads a pane's strip where it crosses the strip
    (its x range in the shown sample, from the note's chrome); the search starts at the strip's place in the shown
    sample (the trace only bounds the search; the value is read from the pixels)."""
    out = {}
    code = film.roles["strip"]
    s = film.scale
    columns = [(f"col@{x}", x) for x in film.cols]
    for pid, chrome in sorted(film.chrome.items()):
        strip, cell = chrome.get("strip"), chrome.get("cell")
        if not strip or not cell or pid not in film.panes:
            continue
        dx, dy = float(strip[0]) - float(cell[0]), float(strip[1]) - float(cell[1])
        inset_r = (float(cell[0]) + float(cell[2])) - (float(strip[0]) + float(strip[2]))
        height = int(round(float(strip[3]) * s))
        for name, coord in columns:
            codes_line = line_codes.get(name)
            if codes_line is None:
                continue
            tops, crossed = [None] * film.n, False
            for f in range(film.n):
                k = shown[f]
                row = film.samples[k].panes.get(pid) if k is not None else None
                if row is None or len(row) < 5:
                    continue
                (x, y, w, h), _ = pane_rect(row)
                if not (x + dx) * s <= coord <= (x + w - inset_r) * s:
                    continue
                crossed = True
                tops[f] = strip_top_on_line(codes_line[f], code, (y + dy) * s, height, int(STRIP_REACH_PT * s))
            if crossed:
                out[(pid, name)] = tops
    return out


def judge_strips(film, shown, rest_frames, spring, reduce, summary, add_frame, line_codes, extents=None, tops=None,
                 fixed=None):
    """Each pane's tab strip on its strip row: the strip's two edges against the pane's edges, and the selected tab's pill
    against the pane's left edge, per frame (frames where the row is outside the strip's height now are skipped); and
    each strip's top on the scan columns that cross it against the pane's top (3e.1). EXTENTS (strip_x_extents) and
    TOPS (strip_tops) are read here when not given. Returns {"edges": {pid: per frame (lo, hi) of the strip as shown (a
    side None when not on screen) or None}, "tops": TOPS, "lags": {frame: [the lag of each strip edge judged in it that
    moved into the frame's sample]}, "lags_fixed": the same against the fixed clock FIXED}: cmux's own layer in each film
    frame, for the m6 check."""
    rows = {y: i for i, y in enumerate(film.rows)}
    out = {"edges": {}, "tops": {}, "lags": collections.defaultdict(list), "lags_fixed": collections.defaultdict(list)}
    extents = strip_x_extents(film, shown, line_codes) if extents is None else extents
    tops = strip_tops(film, shown, line_codes) if tops is None else tops
    out["tops"] = tops
    fixed = shown if fixed is None else fixed

    def moved_lags(values, series):
        """The lag of each frame's edge (read from the pixels) that moved into its sample, against the film's clock SHOWN
        and against the fixed clock."""
        for clock, dest in ((shown, out["lags"]), (fixed, out["lags_fixed"])):
            t = judge_track(film, clock, values, series, rest_frames, None, False)
            for f, v in t["per_frame"].items():
                k = clock[f]
                if k is not None and 1 <= k and series[k] is not None and series[k - 1] is not None \
                        and abs(series[k] - series[k - 1]) >= TOL_PX:
                    dest[f].append(v["lag"])

    for (pid, name), top in sorted(tops.items()):
        if not any(v is not None for v in top):
            continue
        label = (film.panes.get(pid) or {}).get("label", pid[:12])
        series = edge_series(film, pid, "col", "lo")
        track = judge_track(film, shown, top, series, rest_frames, spring, reduce)
        moved_lags(top, series)
        for f, t in sorted(track["per_frame"].items()):
            entry = {"f": f, "t_ms": round((film.t[f] - film.t[0]) * 1000, 2), "sample": shown[f], "line": name, "pane": pid,
                     "label": f"strip {label}", "side": "lo", "dev": t["dev"], "lag": t["lag"], "at": top[f]}
            problems = []
            if abs(t["dev"]) >= TOL_PX:
                problems.append(f"tab strip top {t['dev']:+.1f} px off the pane edge")
            if t["lag"]:
                problems.append(f"tab strip lag {t['lag']} frame(s)")
            if problems:
                entry["problems"] = problems
            add_frame(f, entry)
        summary[f"strip:{label}:{pid}:{name}:lo"] = row_summary("strip", pid, f"strip {label}", "strip", name, "lo", track,
                                                                detail="its top against the pane's top edge")
    shell = film.roles["shell"]
    for pid, (y, ext, read) in sorted(extents.items()):
        chrome = film.chrome.get(pid) or {}
        px = film.row_px[:, rows[y]]
        codes_line = line_codes.get(f"row@{y}") or classify(px)
        rgb_all = px[..., 2::-1]
        out["edges"][pid] = read  # the m6 check reads only the sides read from the pixels
        for si, side in ((0, "lo"), (1, "hi")):
            moved_lags([e[si] if e else None for e in read], edge_series(film, pid, "row", side))
        # A side hidden under the sidebar or past the window is None; the run between the strip's shown ends (a hidden
        # end: the visible area's edge) gives the ground and the pill.
        spans = [None] * film.n
        for f in range(film.n):
            k = shown[f]
            if ext[f] is None or k is None or film.samples[k].panes.get(pid) is None:
                continue
            (x, _, w, _), _ = pane_rect(film.samples[k].panes[pid])
            vlo, vhi, _, _ = visible_span(film, x, x + w, "row")
            lo_px = ext[f][0] if ext[f][0] is not None else int(math.ceil(vlo * film.scale))
            hi_px = ext[f][1] if ext[f][1] is not None else int(math.floor(vhi * film.scale))
            spans[f] = (lo_px, hi_px) if hi_px > lo_px else None
        rest = [f for f in rest_frames if spans[f]] or [f for f in range(film.n) if spans[f]][:REST_FALLBACK]
        if not rest:
            continue
        ground = ground_color(film, [rgb_all[f] for f in rest[:REST_FALLBACK]], [spans[f] for f in rest[:REST_FALLBACK]])
        whole = [e if e and e[0] is not None and e[1] is not None else None for e in ext]  # the pill needs both real ends
        pill = [pill_run(rgb_all[f], whole[f][0], whole[f][1], ground) if whole[f] else None for f in range(film.n)]
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
    return out


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
        if s["off_frames"] and s["what"] == "divider rect":
            out.append({"check": DIVIDER_RECT_CHECK, "where": where, "detail": s["detail"]})
        elif s["off_frames"]:
            check = {"strip": "tab strip edge off", "pill": "tab pill off",
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
        if s.get("clipped_frames"):
            info.append({"check": "rings cut at the window's edge", "where": where,
                         "detail": f"{s['clipped_frames']} frame(s) (frames {s['clipped_ranges']}); the m6 and m14 rows judge them "
                                   "(3e.2)"})
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
        clock = r.get("clock") or {}
        mark = ("clock not found: lags in motion can be one refresh off" if clock.get("offset") is None and clock else
                f"clock {clock['offset']:+d} ({clock.get('status')})" if clock else "clock: not fitted")
        lines.append(f"### {r['case']} ({speed}, input {fx.get('input')}, page backdrop {fx.get('page_backdrop')}; {mark})")
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
