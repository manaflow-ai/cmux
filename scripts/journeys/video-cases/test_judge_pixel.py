#!/usr/bin/env python3
"""Tests for judge_pixel.py on synthetic pixel-fixture films (no app, no fleet), and for pixel/tui_border.py's frame.

Run: /work/tmp/bv-venv/bin/python -I scripts/journeys/video-cases/test_judge_pixel.py

A 600 x 300 px film at scale 2 (300 x 150 pt): pane A, a terminal (tui_border.py's picture: 4 px of theme padding,
16 x 32 px cells, rings 1/2/3 in the outermost cells, yellow fill, the whole-cell remainder on the right and bottom),
a 4 px divider that shows the shell (#FF00FF), and pane B, a page (page.html: borders of 2, 4 and 6 device px, green
body). The divider rests, moves right 2 px per trace sample for 20 samples, then rests. The film frame shown at
refresh k shows trace sample k-1 (video_judge.committed_sample), so a clean film is in step. Each variant damages
exactly one thing: B's content one frame late (lag), A's content 2 px short of its edge (a 2 px gap), B's content over
A's ring 1 (a hidden ring); two more declare a spring and move the divider on it (or on a slower one). The strip variants
add a 24 px black tab strip at the top of each pane with its selected tab's pill (gray 22, white glyphs) and a scan row
through it: in step, B's strip one frame late, B's pill one frame late. The trace has each page host (`page` rows) on its
pane; d4-cover puts B's page window 0.5 pt left of its host after the motion, and the film shows B's page 1 px left.
From the first real films (cmux22, kit ae6563d7d44, 2026-11-03): glyph (a black-class glyph beside A's left ring 3 while
A's right rings are cut: no walk starts at it), samefill (B a terminal of A's fill that shows nothing for 3 frames: B's
sides are not found, never A's rings), cue (the divider's drag cue, a 6 px band of near-shell color over B's rings 1
and 2 while the divider moves: a cue, not a gap or a hidden ring), held (A's pane grows while its content keeps its
rest width and B shows nothing: the shell inside A's pane, A's gap capped at A's own rect, B not found),
reduce-drag (a drag under Reduce Motion: input-driven, no finding) and reduce-keys (a key press whose motion takes 20
samples under Reduce Motion: a finding). The clock films (3d): clock-late shows every layer one refresh later than the
fixed clock (offset +1), clock-early one refresh earlier (-1), clock-late2 two refreshes later (no offset of -1, 0, +1
fits: clock not found, judged on the fixed clock), clock-late-inset is clock-late with both edges 1 px inside their pane
edges while they move (device-pixel rounding: still the sample they show), strip-clock-late is clock-late with the tab strips, and still has no motion. blip: B's page 4 px right of its pane edge in frames 35-36 and 1 px in frame 40,
after the divider has landed (B's own defect). Pair C: the film never shows the divider layer (its band shows the shell),
so only the trace's divider is judged, against the gap between its two panes: divider-off-centre moves the trace's
divider rect 2 pt right of that gap's middle in samples 30-35, 0.5 pt (1 px) in sample 40 and 0.25 pt in sample 45 (the
film unchanged; and a pane below the window whose edge is in the gap); closing-slot puts a closing pane's
rect (pc, not a fixture pane, its slot drawn as its black ground) between A and B, with a divider on each side of it.
"""
import collections
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import numpy as np  # noqa: E402

import judge_pixel as jp  # noqa: E402

W, H, SCALE = 600, 300, 2.0
P = 1 / 120
T0 = 5000.0
N = 60
MOVE = (10, 30)            # samples 10..29 move the divider 2 px each
DIV_PX = 4                 # divider width (device px); it shows the shell
A_REST = 296               # pane A's width at rest (device px)
PAD, CW, CH = 4, 16, 32    # Ghostty padding, cell size (device px)
RED, WHITE, BLACK = (255, 0, 0), (255, 255, 255), (0, 0, 0)
YELLOW, GREEN, CYAN, MAGENTA = (255, 255, 0), (0, 255, 0), (0, 255, 255), (255, 0, 255)
ROWS, COLS = [110, 180], [100, 500]
SPRING = {"response": 0.23, "damping": 0.95}
STRIP_PX, STRIP_ROW, PILL = 24, 12, (22, 22, 23)
WINDOW_X = 100.0           # the window's x on its screen (points): the page rows' screen x less this is window x
CUE = (252, 16, 254)       # the divider's drag cue: near the shell, not the shell
GLYPH = (48, 48, 48)       # the old fixtures' ink: the judge's black (ring 3)
BLUE = (0, 0, 255)


def has_strip(variant):
    return variant.startswith("strip") or variant.startswith("pill")


DIV_TOUCH = 0              # strip-touch: no divider band at all, the two strips touch


def rows_of(variant):
    return ([STRIP_ROW] if has_strip(variant) else []) + ROWS


def touching(variant):
    return variant == "strip-touch"


SLOT_PX = 20               # closing-slot: the closing pane's width (device px)
SIDEBAR_PX = 40            # strip-scrolled: the sidebar's width (device px), the main pane area's left edge
SCROLL_PX = 256            # strip-scrolled: pane A starts this far left of the window (under the sidebar)


def draw_strip(img, x0, x1, pill_x0):
    """A tab strip over [x0, x1) x [0, STRIP_PX): black ground, the selected pill [pill_x0 + 16, + 200) in gray 22 with a
    1 px white glyph column every 7 px inside its title."""
    x0, x1, p = int(round(x0)), int(round(x1)), int(round(pill_x0)) + 16
    img[:STRIP_PX, max(x0, 0):x1] = BLACK
    img[4:STRIP_PX - 4, p:p + 200] = PILL
    for g in range(p + 20, p + 180, 7):
        img[8:STRIP_PX - 8, g] = WHITE


def a_width(k, variant):
    """Pane A's width (device px, float) in trace sample k."""
    if variant == "still":
        return float(A_REST)
    if variant.startswith("spring"):
        t = (k - MOVE[0] + 1) * P
        if k < MOVE[0]:
            return float(A_REST)
        g = float(jp.spring_g(t, SPRING["response"], SPRING["damping"]))
        return A_REST + 40 * (1 - g)
    sign = -1 if variant in ("cut", "backdrop") else 1  # pane A shrinks, pane B grows
    return float(A_REST + sign * 2 * min(max(k - MOVE[0] + 1, 0), MOVE[1] - MOVE[0]))


def draw_tui(img, x0, w, picture_w=None, y0=0):
    """tui_border.py's picture in a terminal view [x0, x0 + w) x [y0, H) (device px). picture_w: the view width the
    program last drew for (a grid that shrank before the redraw: the picture is cut at the new grid's edge)."""
    x0, w = int(round(x0)), int(round(w))
    img[y0:, x0:x0 + w] = CYAN
    cols, rows = (int(round(picture_w or w)) - 2 * PAD) // CW, (H - y0 - 2 * PAD) // CH
    shown = (w - 2 * PAD) // CW
    ring = [RED, WHITE, BLACK]
    for r in range(rows):
        for c in range(min(cols, shown)):
            k = min(r, c, rows - 1 - r, cols - 1 - c)
            color = ring[k] if k < 3 else YELLOW
            img[y0 + PAD + r * CH:y0 + PAD + (r + 1) * CH, x0 + PAD + c * CW:x0 + PAD + (c + 1) * CW] = color


def draw_tui_at(img, x0, w, fill):
    """tui_border.py's picture with FILL in [x0, x0 + w) (a second terminal pane)."""
    x0, w = int(round(x0)), int(round(w))
    img[:, x0:x0 + w] = CYAN
    cols, rows = (w - 2 * PAD) // CW, (H - 2 * PAD) // CH
    for r in range(rows):
        for c in range(cols):
            k = min(r, c, rows - 1 - r, cols - 1 - c)
            img[PAD + r * CH:PAD + (r + 1) * CH, x0 + PAD + c * CW:x0 + PAD + (c + 1) * CW] = [RED, WHITE, BLACK][k] if k < 3 else fill


def draw_page(img, x0, w, y0=0, fill=GREEN):
    """page.html at DPR 2 in [x0, x0 + w) x [y0, H): 2, 4, 6 device px of red, white, black, then the fill."""
    x0, w = int(round(x0)), int(round(w))
    x0c = max(x0, 0)
    img[y0:, x0c:x0 + w] = fill
    inset = 0
    for color, width in ((RED, 2), (WHITE, 4), (BLACK, 6)):
        a, b = x0 + inset, x0 + w - inset
        top, bottom = y0 + inset, H - inset
        img[top:top + width, max(a, 0):b] = color
        img[bottom - width:bottom, max(a, 0):b] = color
        img[top:bottom, max(a, 0):max(a + width, 0)] = color
        img[top:bottom, b - width:b] = color
        inset += width


# The clock films: how many refreshes later than the fixed clock each frame shows its sample (+ later, - earlier).
CLOCK_SHIFT = {"clock-late": 1, "strip-clock-late": 1, "clock-early": -1, "clock-late2": 2, "clock-late-inset": 1}


def frame(k, variant):
    """The picture shown at refresh k (sample k - 1 committed; the clock films shift it by CLOCK_SHIFT)."""
    s = min(max(k - 1 - CLOCK_SHIFT.get(variant, 0), 0), N - 1)
    aw = a_width(s, variant)
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = MAGENTA
    a_view = aw
    if variant == "gap2" and 20 <= k <= 25:
        a_view = aw - 2  # A's content stops 2 px short: the shell shows
    inset = variant == "clock-late-inset" and MOVE[0] <= s < MOVE[1]
    if inset:
        a_view = aw - 1  # while moving, A's content 1 px inside its pane edge (device-pixel rounding)
    y0 = STRIP_PX if has_strip(variant) else 0
    if variant == "held" and 12 <= k <= 40:
        a_view = A_REST  # A's content keeps its rest width while its pane grows
    draw_tui(img, 0, a_view, picture_w=a_width(max(s - 3, 0), variant) if variant == "cut" else None, y0=y0)
    if variant == "glyph":
        # A ruler digit in the old black-class ink just inside A's left ring 3, on every row.
        img[y0:, PAD + 3 * CW + 2:PAD + 3 * CW + 6] = GLYPH
        if 30 <= k <= 33:
            # A's right rings and ground strip gone (its view shrank before the program redrew): the shell after the fill.
            img[:, int(round(aw)) - 60:int(round(aw))] = MAGENTA
    b_x = aw + DIV_PX + (1 if inset else 0)  # and B's 1 px inside its own
    if variant == "closing-slot":
        img[:, int(round(aw)) + DIV_PX:int(round(aw)) + DIV_PX + SLOT_PX] = BLACK  # the closing pane's ground
        b_x = aw + DIV_PX + SLOT_PX + DIV_PX
    if variant == "lag1":
        b_x = a_width(max(k - 2, 0), variant) + DIV_PX  # B's page one frame late
    if variant == "hidden" and 30 <= k <= 32:
        # B's page covers A's view from the inner edge of A's ring 1 on (the cyan strip, the gap and ring 1).
        cols = (int(round(aw)) - 2 * PAD) // CW
        b_x = PAD + (cols - 1) * CW
    if variant == "blip" and k in (35, 36, 40):
        b_x += 1 if k == 40 else 4  # B's page right of its pane edge after the divider has landed (1 px: just off)
    if variant == "d4-cover" and s >= 30:
        draw_page(img, b_x - 1, W - b_x + 1, y0=y0)  # the page window 0.5 pt left of its host (and as much wider)
    elif variant == "samefill":
        if not 30 <= k <= 32:
            draw_tui_at(img, b_x, W - b_x, YELLOW)  # B: a terminal of A's own fill; it shows nothing for 3 frames
    elif variant == "held" and 15 <= k <= 25:
        pass  # B shows nothing: the shell from A's content to the window's edge
    else:
        draw_page(img, b_x, W - b_x, y0=y0)
    if variant == "cue" and 12 <= k <= 28:
        img[:, int(round(b_x)):int(round(b_x)) + 6] = CUE  # the drag cue over B's rings 1 and 2
    if has_strip(variant):
        late = a_width(max(k - 2, 0), variant) + DIV_PX if 11 <= k <= 30 else b_x
        draw_strip(img, -SCROLL_PX if variant == "strip-scrolled" else 0, aw, 0)
        strip_x = late if variant == "strip-lag" else b_x
        draw_strip(img, strip_x, W, late if variant in ("strip-lag", "pill-lag") else b_x)
        if touching(variant):
            # The divider band on the strip row is the neighbour's strip ground, not the shell: the strips touch.
            img[:STRIP_PX, int(round(aw)):int(round(b_x))] = BLACK
    if variant == "strip-scrolled":
        # The sidebar covers A's left part: the shell color, and a white blob (the window's buttons) on the strip row.
        img[:, :SIDEBAR_PX] = MAGENTA
        img[4:20, 12:28] = WHITE
    if variant == "backdrop" and 15 <= k <= 18:
        # B grows and its page is one frame late, with its backdrop: B's own green from its pane edge to its late rings.
        late = a_width(max(k - 2, 0), variant) + DIV_PX
        draw_page(img, late, W - late)
        img[:, int(round(b_x)):int(round(late))] = GREEN
    if variant == "neighbour-gap" and 20 <= k <= 25:
        # B's page has a band of the shell across row 180 (B's own defect: its content is missing there). On that
        # row the shell runs on from A's right edge through the divider into B: the run past A's edge is B's, not a
        # gap of A (FRAME OWNER's 3a: the row divider of the next column crossing a pane's line).
        img[ROWS[1] - 3:ROWS[1] + 4, int(round(b_x)):] = MAGENTA
    if variant == "wide-ground" and 20 <= k <= 25:
        # B shows only the terminal ground (an empty terminal, as pane_2dabe in base03f6 px-window-resize-4-s1 frame 167),
        # over the divider band too: A's ground strip and B's area are one cyan run to the window's edge.
        img[:, int(round(aw)):] = CYAN
    return img


def bgra(img):
    return np.concatenate((img[..., ::-1], np.full(img.shape[:-1] + (1,), 255, np.uint8)), axis=-1)


def build(root, name, variant):
    base = Path(root) / name
    rows = rows_of(variant)
    header = {"width": W, "height": H, "rows": rows, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for k in range(N):
            px = bgra(frame(k, variant))
            out.write(struct.pack("<d", T0 + k * P))
            for y in rows:
                out.write(px[y].tobytes())
            for x in COLS:
                out.write(px[:, x].tobytes())
    samples = []
    cy = STRIP_PX / SCALE if has_strip(variant) else 0
    for k in range(N):
        aw = a_width(k, variant) / SCALE
        a = ["pa", 0, 0, aw, 150, 1, 0, 0, 0, aw, 150, aw, 150 - cy, 0, 0, cy, aw, 150 - cy]
        if variant == "strip-scrolled":
            ax = -SCROLL_PX / SCALE  # A's column scrolled left: its rect starts under the sidebar, off the window
            a = ["pa", ax, 0, aw - ax, 150, 1, 0, ax, 0, aw - ax, 150, aw - ax, 150 - cy, 0, ax, cy, aw - ax, 150 - cy]
        bx = aw + DIV_PX / SCALE
        nudge = {**{j: 2.0 for j in range(30, 36)}, 40: 0.5, 45: 0.25}.get(k, 0.0) if variant == "divider-off-centre" else 0.0
        dividers = [["d0", aw + nudge, 0, DIV_PX / SCALE, 150, 1, 2]]
        closing = []
        if variant == "divider-off-centre":
            # A pane below the window (y 150-200) whose left edge is in the divider's gap: it shares no part of the
            # divider's extent (y 0-150), so it is no neighbour of the divider.
            closing = [["py", aw + 1, 150, 50, 50, 1, 2, aw + 1, 150, 50, 50, 50, 50, 0, aw + 1, 150, 50, 50]]
        if variant == "closing-slot":
            cx, cw = bx, SLOT_PX / SCALE
            closing = [["pc", cx, 0, cw, 150, 0.4, 2, cx, 0, cw, 150, cw, 150, 0, cx, 0, cw, 150]]  # fading out
            dividers.append(["d1", cx + cw, 0, DIV_PX / SCALE, 150, 1, 2])
            bx = cx + cw + DIV_PX / SCALE
        bw = 300 - bx
        b = ["pb", bx, 0, bw, 150, 1, 1, bx, 0, bw, 150, bw, 150 - cy, 0, bx, cy, bw, 150 - cy]
        # B's Chromium host fills its content view; d4-cover: its page window 0.5 pt left (and 0.5 pt wider) after the motion.
        shift = 0.5 if variant == "d4-cover" and k >= 30 else 0.0
        page = [bw, 150 - cy, bw + shift, 150 - cy, 0, WINDOW_X + bx, WINDOW_X + bx - shift, bw]
        samples.append({"t": k * P * 1000, "window": [300, 150], "panes": [a] + closing + [b],
                        "dividers": dividers, "page": [page]})
    # Sample k is taken 1 ms before refresh k is displayed.
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    note = {"scale": SCALE, "panes": {"pa": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pb": {"kind": "page", "fill": "#00FF00", "label": "p1"}},
            "speed": 1, "reduce": False, "input": "drag", "window_frame": [WINDOW_X, 50, 300, 150], "page_backdrop": False}
    if variant == "samefill":
        note["panes"]["pb"] = {"kind": "tui", "fill": "#FFFF00", "label": "p1"}
    if variant.startswith("reduce"):
        note.update(reduce=True, speed=1.0, input="drag" if variant == "reduce-drag" else "keys")
    journal = []
    if variant == "reduce-drag":
        journal = [{"seq": 1, "uptimeNanos": int((T0 + 9 * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "down", "x": 150, "y": 50}}}}]
        journal += [{"seq": 2 + i, "uptimeNanos": int((T0 + (10 + i) * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "drag", "x": 151 + i, "y": 50}}}}
                    for i in range(20)]
        journal.append({"seq": 30, "uptimeNanos": int((T0 + 30 * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "up", "x": 170, "y": 50}}}})
    if variant == "reduce-keys":
        journal = [{"seq": 1, "uptimeNanos": int((T0 + 9.5 * P) * 1e9), "kind": {"key": {"_0": {"phase": "down", "keyCode": 37, "isRepeat": False}}}}]
    Path(f"{base}.events.json").write_text(json.dumps({"hid": [], "journal": journal}))
    if variant == "strip-scrolled":
        note["main_pane"] = [SIDEBAR_PX / SCALE, 0, (W - SIDEBAR_PX) / SCALE, 150]
    if has_strip(variant):
        a0, b0 = A_REST / SCALE, (A_REST + DIV_PX) / SCALE
        note["lines"] = {"strip_rows": {"pa": STRIP_ROW, "pb": STRIP_ROW}}
        note["chrome"] = [{"pane": "pa", "cell": [0, 0, a0, 150], "strip": [0, 0, a0, 12], "pill": [8, 2, 100, 8]},
                          {"pane": "pb", "cell": [b0, 0, 300 - b0, 150], "strip": [b0, 0, 300 - b0, 12], "pill": [b0 + 8, 2, 100, 8]}]
    if variant == "spring":
        note.update(spring=dict(SPRING), input="keys")
    if variant == "spring-slow":
        note.update(spring={"response": SPRING["response"] * 2, "damping": SPRING["damping"]}, input="keys")
    meta = {"start": {"width": W, "height": H, "scale": SCALE, "rows": rows, "columns": COLS}, "notes": {"pixel": note}}
    Path(f"{base}.meta.json").write_text(json.dumps(meta))
    return base


def side(report, label, line, which):
    for s in report["summary"].values():
        if s["label"] == label and s["line"] == line and s["side"] == which:
            return s
    raise AssertionError(f"no {label} {line} {which} in {sorted(report['summary'])}")


def entries(report, label, line, which):
    return {e["f"]: e for ff in report["frame_findings"] for e in ff["entries"]
            if e["label"] == label and e["line"] == line and e["side"] == which}


def divider(report, label="divider p0|p1"):
    """The trace row of the divider between LABEL's panes (pair C: a divider is judged from the trace only)."""
    for s in report["summary"].values():
        if s["what"] == "divider rect" and s["line"] == "trace" and s["label"] == label:
            return s
    raise AssertionError(f"no trace row {label!r} in {sorted(report['summary'])}")


DIVIDER_RECT = "divider rect not centred on its panes' gap"


class JudgeInsideTests(unittest.TestCase):
    """judge_inside's rules on a hand-made INSIDE series (no film): one row per pane and line, the rest count from the
    rest frames, half a px of slack, the frames with no fill, and a line with no fill at rest not judged."""

    def judge(self, inside, n=60):
        film = types.SimpleNamespace(n=n, t=np.arange(n) / 120.0, panes={"pa": {"label": "p0", "kind": "tui", "agent": False}})
        summary, frames = {}, {}

        def add_frame(f, entry):
            if entry.get("problems"):
                frames.setdefault(f, []).append(entry)

        jp.judge_inside(film, list(range(n)), inside, list(range(10)), summary, add_frame)
        return summary, frames

    def test_one_row_per_pane_and_line_from_the_rest_frames(self):
        # Rest frames 0-9 alternate 2 and 3 shell px (median 2.5); frame 10 shows 3 (within half a px of the rest);
        # frames 11-59, most of the film (a median over all frames would hide them), show 20; 50-52 show no fill.
        series = [(2 + f % 2, True) for f in range(10)] + [(3, True)] + [(20, f not in (50, 51, 52)) for f in range(11, 60)]
        summary, frames = self.judge({("pa", "row@1", "row"): series})
        self.assertEqual(list(summary), ["p0:pa:row@1:inside"])
        row = summary["p0:pa:row@1:inside"]
        self.assertEqual((row["side"], row["rest"]["shell_in"]), ("inside", 2.5))
        self.assertEqual((row["shell_in_ranges"], row["shell_in_max_px"]), ("11-59", 17.5))
        self.assertEqual((row["no_fill_frames"], row["no_fill_ranges"]), (3, "50-52"))
        self.assertEqual(frames[11][0]["problems"], ["shell inside the pane: 18 px"])
        self.assertNotIn(10, frames)

    def test_a_line_with_no_fill_at_rest_is_not_judged(self):
        # The line runs along a ring row at rest (none of the pane's fill), then shows the fill and the shell: no row.
        summary, frames = self.judge({("pa", "row@2", "row"): [(0, False)] * 10 + [(30, True)] * 50})
        self.assertEqual((summary, frames), ({}, {}))


class JudgePixelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v)) for v in ("clean", "lag1", "gap2", "hidden", "spring", "spring-slow", "cut",
                                                                    "backdrop", "strip", "strip-lag", "pill-lag", "d4-cover", "glyph",
                                                                    "samefill", "cue", "held", "reduce-drag", "reduce-keys",
                                                                    "strip-touch", "strip-scrolled", "wide-ground",
                                                                    "neighbour-gap", "blip", "divider-off-centre",
                                                                    "closing-slot")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_classes_are_cube_corners(self):
        px = bgra(np.array([[RED, CYAN, MAGENTA, (128, 128, 128), (250, 5, 240)]], np.uint8))
        self.assertEqual(jp.classify(px)[0].tolist(), [jp.CODE["red"], jp.CODE["cyan"], jp.CODE["magenta"], jp.OTHER,
                                                       jp.CODE["magenta"]])

    def test_clean_film_has_no_finding(self):
        r = self.reports["clean"]
        self.assertEqual(r["findings"], [], json.dumps(r["findings"], indent=1))
        self.assertGreaterEqual(r["rest_frames"], 5)
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertEqual(a_hi["rest"]["rings"], [16.0, 16.0, 16.0])
        self.assertEqual(a_hi["rest"]["gap"], 4.0)
        # Rest: 296 px - 8 px of padding = 18 cells and 0 px over: the strip is the 4 px right padding.
        self.assertEqual(a_hi["rest"]["strip"], 4.0)
        # Moving, the whole-cell remainder shows in the strip: 4 to 4 + 14 px.
        self.assertEqual(a_hi["strip_max_px"], 18.0)
        b_lo = side(r, "p1", "row@180", "lo")
        self.assertEqual(b_lo["rest"]["rings"], [2.0, 4.0, 6.0])
        self.assertEqual(b_lo["max_lag_frames"], 0)
        self.assertEqual([m["settle_frames"] for m in b_lo["motions"]], [0])
        self.assertEqual(b_lo["motions"][0]["travel_px"], 40.0)
        top = side(r, "p0", "col@100", "lo")
        self.assertEqual(top["rest"]["rings"], [32.0, 32.0, 32.0])
        self.assertEqual(top["rest"]["strip"], 4.0)

    def test_one_frame_lag_found(self):
        r = self.reports["lag1"]
        b_lo = side(r, "p1", "row@110", "lo")
        self.assertEqual(b_lo["max_lag_frames"], 1)
        self.assertEqual([m["settle_frames"] for m in b_lo["motions"]], [1])
        hits = entries(r, "p1", "row@110", "lo")
        # Frames 11..30 show the moving samples 10..29; the page shows each one a frame late.
        lagged = sorted(f for f, e in hits.items() if e.get("lag") == 1)
        self.assertEqual(lagged, list(range(11, 31)))
        self.assertEqual({hits[f]["edge_dev"] for f in lagged}, {-2.0})
        # Pane A is in step.
        self.assertEqual(side(r, "p0", "row@110", "hi")["max_lag_frames"], 0)
        self.assertIn("lag", [f["check"] for f in r["findings"]])

    def test_two_px_gap_found(self):
        r = self.reports["gap2"]
        a_hi = side(r, "p0", "row@180", "hi")
        self.assertEqual(a_hi["max_gap_px"], 2.0)
        hits = entries(r, "p0", "row@180", "hi")
        gaps = sorted(f for f, e in hits.items() if e.get("gap_dev") == 2.0)
        self.assertEqual(gaps, list(range(20, 26)))
        self.assertTrue(all(hits[f]["gap"] == 6.0 for f in gaps))
        self.assertEqual({hits[f]["edge_dev"] for f in gaps}, {-2.0})
        self.assertEqual(a_hi["hidden_ring_frames"], 0)
        self.assertIn("gap", [f["check"] for f in r["findings"]])

    def test_hidden_ring_found(self):
        r = self.reports["hidden"]
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertEqual(a_hi["hidden_ring_frames"], 3)
        hits = entries(r, "p0", "row@110", "hi")
        hidden = sorted(f for f, e in hits.items() if e.get("hidden"))
        self.assertEqual(hidden, [30, 31, 32])
        self.assertEqual(hits[30]["hidden"], [1])
        self.assertEqual(hits[30]["beyond"], "white")  # B's 4 px ring 2 lies past the 2 px of B's ring 1
        # A's content edge, as shown, is B's ring 1 now: 26 px inside A's pane edge (the cyan strip and ring 1 covered).
        self.assertEqual(a_hi["max_edge_dev_px"], -26.0)
        self.assertIn("hidden ring", [f["check"] for f in r["findings"]])
        self.assertEqual(side(r, "p0", "row@110", "lo")["hidden_ring_frames"], 0)

    def test_spring_curve(self):
        good = side(self.reports["spring"], "p1", "row@110", "lo")["motions"][0]
        self.assertLessEqual(good["spring_trace"]["max_px"], 0.05)
        self.assertLessEqual(good["spring_film"]["max_px"], 0.75)
        self.assertNotIn("off the spring curve", [f["check"] for f in self.reports["spring"]["findings"]])
        slow = side(self.reports["spring-slow"], "p1", "row@110", "lo")["motions"][0]
        self.assertGreater(slow["spring_trace"]["max_px"], 3.0)
        self.assertIn("off the spring curve", [f["check"] for f in self.reports["spring-slow"]["findings"]])

    def test_the_film_has_no_derived_divider(self):
        # Pair C (FRAME OWNER): the divider band shows the shell, so the film never shows a divider layer; the middle of
        # the two content edges only restated them (each content defect counted twice). No film row and no finding of a
        # divider, on any film; the content edges carry their own defects.
        for v in ("clean", "hidden", "lag1", "gap2", "blip", "samefill", "glyph", "spring", "cue"):
            with self.subTest(film=v):
                r = self.reports[v]
                self.assertFalse([k for k, row in r["summary"].items() if row["what"] == "divider"], v)
                self.assertFalse([f for f in r["findings"] if f["where"].startswith("divider")
                                  and f["check"] != DIVIDER_RECT], v)
                self.assertNotIn("divider not read", [f["check"] for f in r["info"]])
        hidden = self.reports["hidden"]
        self.assertIn(("content edge off", "p1 (page) lo on row@110"), [(f["check"], f["where"]) for f in hidden["findings"]])
        self.assertIn(("content edge off", "p1 (page) lo on row@110"),
                      [(f["check"], f["where"]) for f in self.reports["blip"]["findings"]])
        self.assertIn("divider cue", [f["check"] for f in self.reports["cue"]["info"]])  # the cue stays information

    def test_the_trace_divider_is_centred_on_its_panes_gap(self):
        # The trace alone: each sample's divider rect against the middle of the gap between the two panes it separates.
        row = divider(self.reports["clean"])
        self.assertEqual((row["side"], row["kind"], row["frames"], row["off_frames"]), ("mid", "divider", N, 0))
        self.assertNotIn(DIVIDER_RECT, [f["check"] for f in self.reports["clean"]["findings"]])

    def test_a_divider_rect_off_its_panes_gap_is_a_trace_finding(self):
        r = self.reports["divider-off-centre"]
        row = divider(r)
        # 4 px in 30-35 and exactly 1 px in 40 are off; 0.5 px in 45 is not (1 device px is the tolerance).
        self.assertEqual((row["off_frames"], row["off_ranges"], row["max_edge_dev_px"]), (7, "30-35,40", 4.0))
        found = {(f["check"], f["where"]): f["detail"] for f in r["findings"]}
        detail = found[(DIVIDER_RECT, "divider p0|p1 (divider) mid on trace")]
        self.assertIn("7 of 60 trace samples", detail)
        self.assertIn("samples 30-35,40", detail)
        self.assertIn("+4.0 px", detail)

    def test_a_closing_panes_rect_counts_as_the_neighbour(self):
        # S3 (frame-owner-s3b): a closing pane keeps its rect in its slot during the close, and a divider separates it
        # from its neighbour; the divider's panes are the two it separates in the trace at that sample (the closing
        # pane's rect too, faded or not, fixture or not), never the next fixture pane past it.
        r = self.reports["closing-slot"]
        self.assertEqual((divider(r, "divider p0|pc")["off_frames"], divider(r, "divider pc|p1")["off_frames"]), (0, 0))
        self.assertNotIn(DIVIDER_RECT, [f["check"] for f in r["findings"]])

    def test_rings_found_past_a_page_backdrop(self):
        r = self.reports["backdrop"]
        hits = entries(r, "p1", "row@110", "lo")
        late = sorted(f for f, e in hits.items() if e.get("beyond") == "fill")
        self.assertEqual(late, [15, 16, 17, 18])
        self.assertEqual({hits[f]["edge_dev"] for f in late}, {2.0})
        self.assertEqual({hits[f]["beyond_px"] for f in late}, {2.0})
        self.assertFalse(any(hits[f].get("hidden") for f in late))
        self.assertEqual(side(r, "p1", "row@110", "lo")["hidden_ring_frames"], 0)

    def test_rings_cut_when_the_grid_shrank_first(self):
        r = self.reports["cut"]
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertGreater(a_hi["cut_ring_frames"], 0)
        self.assertEqual(a_hi["hidden_ring_frames"], 0)
        self.assertEqual(a_hi["max_edge_dev_px"], 0.0)  # the terminal view itself keeps up
        self.assertIn("rings cut", [f["check"] for f in r["findings"]])
        hits = entries(r, "p0", "row@110", "hi")
        cut = [e for e in hits.values() if e.get("cut")]
        self.assertTrue(all(e["rings"][0] == 0 and e["strip"] > 0 for e in cut), cut[:2])

    def test_whole_cell_remainder(self):
        r = self.reports["clean"]
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertEqual(a_hi["remainder_max_px"], 14.0)  # 16 px cells: the remainder runs 0..14 px as the pane grows 2 px a sample
        self.assertEqual(side(r, "p0", "row@110", "lo")["rest"]["strip"], 4.0)

    def test_tab_strip_and_pill_follow_the_pane(self):
        r = self.reports["strip"]
        self.assertEqual(r["findings"], [], json.dumps(r["findings"], indent=1))
        strips = {(s["label"], s["side"]): s for s in r["summary"].values() if s["what"] in ("strip", "pill")}
        self.assertEqual(sorted(strips), [("pill p0", "hi"), ("pill p0", "lo"), ("pill p1", "hi"), ("pill p1", "lo"),
                                          ("strip p0", "hi"), ("strip p0", "lo"), ("strip p1", "hi"), ("strip p1", "lo")])
        self.assertEqual(strips[("strip p1", "lo")]["rest"]["offset"], 0.0)  # the strip starts at the pane's left edge
        self.assertEqual(strips[("pill p1", "lo")]["rest"]["offset"], 16.0)  # the pill 16 px inside it
        self.assertEqual(strips[("pill p1", "hi")]["rest"]["offset"], 216.0)
        self.assertEqual([m["travel_px"] for m in strips[("strip p1", "lo")]["motions"]], [40.0])
        self.assertEqual(strips[("strip p1", "lo")]["ground"], [0, 0, 0])

    def test_a_strip_stays_inside_its_pane(self):
        """The strips of two panes touch on the strip row (no shell between them: narrow panes, a column edge). Each
        strip is read inside its own pane's rect of the shown sample: cmux22 base films showed -300 px x155 and
        +1146 px x54 for strip p0 lo (the walk ran into the neighbour's strip)."""
        r = self.reports["strip-touch"]
        for label in ("strip p0", "strip p1"):
            for which in ("lo", "hi"):
                st = side(r, label, "row@12", which)
                self.assertLessEqual(abs(st["max_edge_dev_px"]), 1.0, (label, which, st["dev_top"]))
        self.assertNotIn("tab strip edge off", [f["check"] for f in r["findings"]])
        # The strip still moves with its pane (B's left edge travels 40 px).
        self.assertEqual([m["travel_px"] for m in side(r, "strip p1", "row@12", "lo")["motions"]], [40.0])

    def test_a_pane_partly_under_the_sidebar(self):
        """A's column is scrolled left: its rect starts 128 pt off the window, under the sidebar (cmux22 base03f6
        px-new-column-c2: the strip walk started at the middle of p0's rect, in the sidebar, on the window's buttons:
        -969..-1083 px). Only the part of a pane inside the main pane area (the note's main_pane) is read: A's right edge
        is judged, its left edge (hidden) is not."""
        r = self.reports["strip-scrolled"]
        hi = side(r, "strip p0", "row@12", "hi")
        self.assertEqual(hi["frames"], 60)
        self.assertLessEqual(abs(hi["max_edge_dev_px"]), 1.0, hi["dev_top"])
        self.assertFalse([s for s in r["summary"].values() if s["label"] == "strip p0" and s["side"] == "lo" and s["frames"]])
        # A's left edge (rows cross it) is hidden: never judged. Its top edge (the col@100 line's lo) shows and is.
        self.assertFalse([s for s in r["summary"].values() if s["label"] == "p0" and s["side"] == "lo"
                          and s["line"].startswith("row@") and s["frames"]])
        self.assertEqual(side(r, "p0", "col@100", "lo")["max_edge_dev_px"], 0.0)
        # Row 110 runs along one of A's ring rows here (no fill: not judged); row 180 crosses A's fill.
        self.assertEqual(side(r, "p0", "row@180", "hi")["max_edge_dev_px"], 0.0)
        self.assertNotIn("tab strip edge off", [f["check"] for f in r["findings"]])
        self.assertNotIn("shell inside the pane", [f["check"] for f in r["findings"]])

    def test_the_ground_strip_stops_at_its_own_width(self):
        """The ground strip is Ghostty's padding and the whole-cell remainder: at most a cell and the padding. Where it
        runs on into a neighbour that shows only ground color (an empty terminal), this pane's view edge cannot be seen:
        not found, never a deviation (base03f6 px-window-resize-4-s1 frame 167: p0's lo strip ran through the cyan pane
        beside it to x=416, -1057 px)."""
        r = self.reports["wide-ground"]
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertEqual(a_hi["not_found_ranges"], "20-25")
        self.assertLessEqual(abs(a_hi["max_edge_dev_px"]), 1.0, a_hi["dev_top"])
        self.assertLessEqual(a_hi["strip_max_px"], 4.0 + 14.0)
        self.assertEqual(a_hi["cut_ring_frames"], 0)
        self.assertEqual(side(r, "p1", "row@110", "lo")["max_edge_dev_px"], 0.0)

    def test_tab_strip_lag_found(self):
        r = self.reports["strip-lag"]
        lo = side(r, "strip p1", "row@12", "lo")
        self.assertEqual(lo["max_edge_dev_px"], -2.0)
        self.assertEqual(lo["max_lag_frames"], 1)
        self.assertEqual(side(r, "pill p1", "row@12", "lo")["max_lag_frames"], 1)  # the pill rides the strip
        self.assertEqual(side(r, "strip p0", "row@12", "hi")["max_edge_dev_px"], 0.0)
        self.assertIn("tab strip edge off", [f["check"] for f in r["findings"]])
        # The page below it is in step.
        self.assertEqual(side(r, "p1", "row@110", "lo")["max_lag_frames"], 0)

    def test_tab_pill_lag_found(self):
        r = self.reports["pill-lag"]
        self.assertEqual(side(r, "pill p1", "row@12", "lo")["max_edge_dev_px"], -2.0)
        self.assertEqual(side(r, "strip p1", "row@12", "lo")["max_edge_dev_px"], 0.0)
        # A pill's edges move with a tab reflow too (its width follows the strip's): information, not a defect.
        self.assertEqual([f["check"] for f in r["findings"] if f["check"].startswith("tab")], [])
        self.assertEqual([f["check"] for f in r["info"] if f["check"].startswith("tab")], ["tab pill off", "tab pill off"])

    def test_page_window_off_its_host(self):
        clean = [s for s in self.reports["clean"]["summary"].values() if s["what"] == "page window"]
        self.assertTrue(clean)
        self.assertTrue(all(s["max_edge_dev_px"] == 0.0 for s in clean), clean)
        r = self.reports["d4-cover"]
        trace = side(r, "page window p1", "trace", "lo/hi")
        self.assertEqual(trace["max_edge_dev_px"], -1.0)
        self.assertEqual(trace["off_samples"], list(range(30, 60)))
        self.assertEqual(trace["half_point_samples"], 0)  # B's host sits on whole points here
        film = side(r, "page window p1", "row@110", "lo")
        self.assertEqual(film["max_edge_dev_px"], -1.0)
        self.assertEqual(film["detail"], "covers the divider, film")
        hits = entries(r, "page window p1", "row@110", "lo")
        self.assertEqual(sorted(hits), list(range(31, 60)))
        self.assertEqual({hits[f]["host_offset_px"] for f in hits}, {-1.0})
        self.assertEqual({hits[f]["page_offset_px"] for f in hits}, {0.0})  # the film shows the page where its window is
        self.assertEqual(side(r, "page window p1", "row@110", "hi")["max_edge_dev_px"], 0.0)
        self.assertIn("page window off its host", [f["check"] for f in r["findings"]])

    def test_backdrop_note(self):
        self.assertEqual(self.reports["clean"]["notes"], [])
        base = build(self.tmp, "backdrop-on", "backdrop")
        meta = json.loads(Path(f"{base}.meta.json").read_text())
        meta["notes"]["pixel"]["page_backdrop"] = True
        Path(f"{base}.meta.json").write_text(json.dumps(meta))
        r = jp.judge(base)
        self.assertTrue(any("page backdrop was on" in n for n in r["notes"]), r["notes"])
        self.assertEqual(side(r, "p1", "row@110", "lo")["backdrop_frames"], 4)
        self.assertEqual(side(r, "p1", "row@110", "lo")["backdrop_max_px"], 2.0)

    def test_a_glyph_never_starts_a_walk(self):
        r = self.reports["glyph"]
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertEqual(a_hi["not_found_frames"], 4)
        self.assertEqual(a_hi["not_found_ranges"], "30-33")
        self.assertLessEqual(abs(a_hi["max_edge_dev_px"]), 1.0)  # was -1283 px on cmux22
        self.assertEqual(side(r, "p0", "row@110", "lo")["max_edge_dev_px"], 0.0)
        self.assertEqual(side(r, "p0", "row@110", "lo")["not_found_frames"], 0)

    def test_a_neighbour_of_the_same_fill_is_never_found(self):
        r = self.reports["samefill"]
        for which in ("lo", "hi"):
            b = side(r, "p1", "row@110", which)
            self.assertEqual(b["not_found_frames"], 3, which)
            self.assertLessEqual(abs(b["max_edge_dev_px"]), 1.0, which)
        self.assertEqual(side(r, "p1", "row@110", "lo")["rest"]["rings"], [16.0, 16.0, 16.0])
        self.assertLessEqual(side(r, "p0", "row@110", "hi")["max_gap_px"], 18.0)
        # B shows nothing in 30-32, the first frames that show the landed sample: B's own content has not landed there
        # (its settle counts them: 3 frames).
        self.assertEqual([mv["settle_frames"] for mv in side(r, "p1", "row@110", "lo")["motions"]], [3])

    def test_the_divider_cue_is_a_cue(self):
        r = self.reports["cue"]
        b_lo = side(r, "p1", "row@110", "lo")
        self.assertEqual(b_lo["cue_frames"], 17)
        self.assertEqual(b_lo["cue_ranges"], "12-28")
        self.assertEqual(b_lo["hidden_ring_frames"], 0)
        self.assertEqual(b_lo["max_gap_px"], 0.0)
        self.assertEqual(b_lo["not_found_frames"], 0)
        self.assertEqual(side(r, "p0", "row@110", "hi")["max_gap_px"], 0.0)
        self.assertNotIn("gap", [f["check"] for f in r["findings"]])
        self.assertNotIn("hidden ring", [f["check"] for f in r["findings"]])
        self.assertIn("divider cue", [f["check"] for f in r["info"]])

    def test_a_late_content_edge_is_its_own_finding_not_the_dividers(self):
        # 3b, then pair C: B's page one frame late (lag1) is B's own finding (content edge off, lag); the divider is
        # judged from the trace, where it is centred on its panes' gap.
        r = self.reports["lag1"]
        found = [(f["check"], f["where"]) for f in r["findings"]]
        self.assertIn(("lag", "p1 (page) lo on row@110"), found)
        self.assertFalse([w for c, w in found if w.startswith("divider")])
        self.assertEqual(divider(r)["off_frames"], 0)

    def test_the_shell_past_the_divider_is_the_neighbours_not_a_gap(self):
        # 3a (FRAME OWNER): a pane's gap is measured to its pane edge and the divider band to the next pane, never
        # into that pane; there the shell is the next pane's (its content missing), on its own side of the line.
        r = self.reports["neighbour-gap"]
        a_hi = side(r, "p0", "row@180", "hi")
        self.assertEqual(a_hi["max_gap_px"], 0.0)
        self.assertNotIn(("gap", "p0 (tui) hi on row@180"), [(f["check"], f["where"]) for f in r["findings"]])
        self.assertEqual(side(r, "p0", "row@110", "hi")["max_gap_px"], 0.0)
        b = side(r, "p1", "row@180", "lo")
        self.assertEqual(b["not_found_ranges"], "20-25")

    def test_held_content_shows_the_shell_inside_its_pane(self):
        r = self.reports["held"]
        # A's pane grows 2 px a sample while its content keeps 296 px: the shell inside A's pane, frame by frame. It is
        # the pane's and the line's (3c, FRAME OWNER), so it is on A's one "inside" row of row@110, not on a side row.
        a_in = side(r, "p0", "row@110", "inside")
        self.assertEqual(a_in["shell_in_ranges"], "12-40")
        self.assertEqual(a_in["shell_in_max_px"], 40.0)
        a_hi = side(r, "p0", "row@110", "hi")
        self.assertLessEqual(a_hi["max_gap_px"], 40.0 + 16)  # capped at A's own rect (and a divider's width)
        b_lo = side(r, "p1", "row@110", "lo")
        self.assertEqual(b_lo["not_found_ranges"], "15-25")
        # B shows nothing in 15-25: none of its fill on the line, counted once, on B's inside row.
        self.assertEqual(side(r, "p1", "row@110", "inside")["no_fill_frames"], 11)
        for label in ("p0", "p1"):
            for which in ("lo", "hi"):
                row = side(r, label, "row@110", which)
                self.assertEqual((row["shell_in_frames"], row["no_fill_frames"]), (0, 0), (label, which))
        # And B's pane shows only the shell in 15-25: B's own shell inside its pane. One finding per pane on row@110.
        hits = [f["where"] for f in r["findings"] if f["check"] == "shell inside the pane" and f["where"].endswith(" row@110")]
        self.assertEqual(hits, ["p0 (tui) inside on row@110", "p1 (page) inside on row@110"])

    def test_the_shell_inside_a_pane_is_one_finding_per_pane_and_line(self):
        # 3c (FRAME OWNER): v7 reported the shell inside a pane on both side rows of the pane and line (a duplicate).
        # samefill: B, a terminal of A's fill, shows nothing in 30-32 and the shell inside its pane on each line.
        r = self.reports["samefill"]
        hits = [f["where"] for f in r["findings"] if f["check"] == "shell inside the pane"]
        self.assertTrue(hits)
        self.assertEqual(len(hits), len(set(hits)))
        lines = [w.split(" on ")[1] for w in hits]
        self.assertEqual(len(lines), len(set(lines)), hits)  # one finding per pane and line
        self.assertTrue(all(w.startswith("p1 (tui) inside on ") for w in hits), hits)

    def test_reduce_motion_judged_per_input(self):
        drag = self.reports["reduce-drag"]
        self.assertNotIn("motion under Reduce Motion", [f["check"] for f in drag["findings"]])
        self.assertTrue(all(not m.get("reduce_motion_samples") for s in drag["summary"].values() for m in s["motions"]))
        self.assertTrue(any(m.get("input_driven") for s in drag["summary"].values() for m in s["motions"]))
        keys = self.reports["reduce-keys"]
        hits = [f for f in keys["findings"] if f["check"] == "motion under Reduce Motion"]
        self.assertTrue(hits)
        self.assertTrue(all("20 samples" in f["detail"] for f in hits), hits)

    def test_track_statistics(self):
        b_lo = side(self.reports["lag1"], "p1", "row@110", "lo")
        self.assertEqual(b_lo["frames"], 60)
        self.assertEqual(b_lo["off_frames"], 20)
        self.assertEqual(b_lo["off_ranges"], "11-30")
        self.assertEqual((b_lo["p50_px"], b_lo["p95_px"], b_lo["max_edge_dev_px"]), (0.0, 2.0, -2.0))
        self.assertEqual(b_lo["dev_top"], [[-2.0, 20]])
        clean = side(self.reports["clean"], "p1", "row@110", "lo")
        self.assertEqual((clean["off_frames"], clean["p95_px"], clean["not_found_frames"], clean["shell_in_frames"]), (0, 0.0, 0, 0))

    def test_markdown_and_cli(self):
        base = Path(self.tmp) / "gap2"
        out, md = Path(self.tmp) / "gap2.json", Path(self.tmp) / "gap2.md"
        done = subprocess.run([sys.executable, "-I", str(HERE / "judge_pixel.py"), str(base), "--json", str(out),
                               "--markdown", str(md)], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("gap", done.stdout)
        self.assertEqual(json.loads(out.read_text())["case"], "gap2")
        lines = md.read_text().splitlines()
        head = next(l for l in lines if l.startswith("| what |"))
        for column in ("judged", "off >= 1 px", "p50", "p95", "max dev", "shell in pane", "cue", "not found"):
            self.assertIn(column, head)
        row = next(l for l in lines if l.startswith("| p0 (tui) | hi | row@180 |"))
        self.assertIn("6 (20-25)", row)  # off >= 1 px: 6 frames
        self.assertIn("-2.0", row)


class ClockTests(unittest.TestCase):
    """3d (FRAME OWNER): judge_pixel fits the film's clock (the trace sample a frame shows: the fixed clock's, or one
    refresh later or earlier) from the edges that follow the trace over the moving frames, reports an offset as the
    finding "presentation offset", and judges every layer against that clock; when no offset fits it judges nothing
    ("clock not found": judged on the fixed clock, its lags in motion can be one refresh off). The fixed clock alone
    showed every layer of the 1x held-key film one frame late."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-clock-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v)) for v in ("clean", "lag1", "clock-late", "clock-early",
                                                                    "clock-late2", "strip-clock-late", "still",
                                                                    "clock-late-inset")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @staticmethod
    def checks(report):
        return [f["check"] for f in report["findings"]]

    def test_a_film_in_step_keeps_the_fixed_clock(self):
        r = self.reports["clean"]
        self.assertEqual(r["clock"]["offset"], 0)
        self.assertNotIn("presentation offset", self.checks(r))
        self.assertIn("clock", [f["check"] for f in r["info"]])

    def test_a_film_shown_one_refresh_late_is_judged_on_its_own_clock(self):
        r = self.reports["clock-late"]
        self.assertEqual(r["clock"]["offset"], 1)
        late = [f for f in r["findings"] if f["check"] == "presentation offset"]
        self.assertEqual(len(late), 1, r["findings"])
        self.assertIn("+1 refresh", late[0]["detail"])
        for row in r["summary"].values():
            if row["what"] == "pane":
                self.assertEqual((row["off_frames"], row["max_lag_frames"]), (0, 0), row)
        self.assertNotIn("lag", self.checks(r))
        self.assertNotIn("content edge off", self.checks(r))
        # Measured again on its clock: each pane's visible span is the shown sample's, so no shell inside the pane.
        self.assertNotIn("shell inside the pane", self.checks(r))

    def test_an_edge_1_px_inside_its_pane_edge_follows_its_sample(self):
        # Within 1 px, as the lag search matches a sample (the real col-drag film: 1584 px against the trace's 1585).
        self.assertEqual(self.reports["clock-late-inset"]["clock"]["offset"], 1)

    def test_an_edge_votes_for_the_offset_more_than_half_its_frames_follow(self):
        self.assertEqual(jp.track_vote({-1: 0, 0: 1, 1: 3}, 4), 1)
        self.assertIsNone(jp.track_vote({-1: 0, 0: 1, 1: 2}, 4))  # half, not more
        self.assertIsNone(jp.track_vote({-1: 0, 0: 3, 1: 3}, 4))  # two offsets: no vote

    def test_the_clock_is_the_smallest_offset_voted_for(self):
        def track(vote, frames=10, within=8, any_offset=8):
            return {"track": "t", "frames": frames, "within_1px": {"-1": 0, "+0": within, "+1": within},
                    "any_offset": any_offset, "vote": vote}

        got = jp.clock_verdict(collections.Counter({0: 1, 1: 3}), [track(0), track(1), track(1), track(1)])
        self.assertEqual((got["offset"], got["status"]), (0, "fitted"))
        got = jp.clock_verdict(collections.Counter(), [track(None, any_offset=6)])
        self.assertEqual((got["offset"], got["status"]), (0, "fixed: not confirmed"))
        got = jp.clock_verdict(collections.Counter(), [track(None, any_offset=5)])
        self.assertEqual((got["offset"], got["status"]), (None, "not found"))
        got = jp.clock_verdict(collections.Counter(), [])
        self.assertEqual((got["offset"], got["status"]), (0, "fixed: no motion"))

    def test_a_film_shown_one_refresh_early_is_minus_one(self):
        r = self.reports["clock-early"]
        self.assertEqual(r["clock"]["offset"], -1)
        self.assertNotIn("lag", self.checks(r))
        self.assertNotIn("content edge off", self.checks(r))

    def test_a_late_layer_is_late_against_the_films_own_clock(self):
        # lag1: A on time, B one refresh late. A frame shows its own sample's geometry and a layer can only be older,
        # so the smallest offset the edges follow (A's, 0) is the clock; B's lag stays B's finding.
        r = self.reports["lag1"]
        self.assertEqual((r["clock"]["offset"], r["clock"]["votes"]), (0, {"+0": 2, "+1": 2}))
        self.assertIn(("lag", "p1 (page) lo on row@110"), [(f["check"], f["where"]) for f in r["findings"]])

    def test_no_offset_that_fits_is_clock_not_found_and_the_fixed_clock(self):
        # Every layer two refreshes late: no offset of -1, 0, +1 fits. The film is judged on the fixed clock (its
        # rest findings do not depend on the clock), and "clock not found" says its lags in motion can be one refresh
        # off: the layers' lag is reported, not hidden.
        r = self.reports["clock-late2"]
        self.assertIsNone(r["clock"]["offset"])
        self.assertEqual(r["clock"]["status"], "not found")
        self.assertEqual(self.checks(r)[0], "clock not found")
        self.assertIn("lag", self.checks(r))
        self.assertEqual(side(r, "p1", "row@110", "lo")["max_lag_frames"], 2)

    def test_the_tab_strips_are_judged_against_the_films_clock(self):
        r = self.reports["strip-clock-late"]
        self.assertEqual(r["clock"]["offset"], 1)
        strips = [row for row in r["summary"].values() if row["what"] == "strip"]
        self.assertTrue(strips)
        self.assertEqual({(row["off_frames"], row["max_lag_frames"]) for row in strips}, {(0, 0)})
        self.assertNotIn("tab strip edge off", self.checks(r))

    def test_a_film_with_no_motion_keeps_the_fixed_clock(self):
        r = self.reports["still"]
        self.assertEqual(r["clock"]["offset"], 0)
        self.assertIn("no edge moved", r["clock"]["why"])


class TraceDividerTests(unittest.TestCase):
    """Pair C: judge_divider_rects on hand-made trace samples (no film)."""

    @staticmethod
    def pane(pid, lo, hi):
        return [pid, lo, 0, hi - lo, 100, 1]

    def rows(self, samples):
        film = types.SimpleNamespace(scale=2.0, panes={"pa": {"label": "p0"}, "pb": {"label": "p1"}, "pc": {"label": "p2"}},
                                     samples=[types.SimpleNamespace(panes={p[0]: p for p in panes},
                                                                    dividers={"d": ["d", x, 0, 7, 100, 1, 2]})
                                              for x, panes in samples])
        summary = {}
        jp.judge_divider_rects(film, {"d": jp.divider_series(film, "d")}, summary)
        return summary

    def test_the_row_is_labelled_by_the_panes_of_the_last_sample(self):
        # A closes: the divider first separates A and B, then C and B (as the old film rows were labelled).
        summary = self.rows([(97, [self.pane("pa", 0, 100), self.pane("pb", 104, 300)]),
                             (97, [self.pane("pc", 0, 100), self.pane("pb", 104, 300)])])
        self.assertEqual([row["label"] for row in summary.values()], ["divider p2|p1"])

    def test_one_pane_on_both_sides_is_no_gap(self):
        # A pane that runs under the whole divider is on both sides of it: there is no gap to judge, so no row.
        self.assertEqual(self.rows([(97, [self.pane("pa", 96, 102)])]), {})


class TuiBorderFrameTest(unittest.TestCase):
    """pixel/tui_border.py's one-frame mode: the cells it paints (SGR backgrounds) form the three rings and the fill."""

    def test_rings_and_fill(self):
        tool = HERE.parent / "pixel" / "tui_border.py"
        done = subprocess.run([sys.executable, "-I", str(tool), "--size", "20x10", "--frames", "1", "--fill", "#0000FF"],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        grid = [[None] * 20 for _ in range(10)]
        r = c = 0
        bgc = None
        import re
        token = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")
        i, data = 0, done.stdout
        while i < len(data):
            m = token.match(data, i)
            if m:
                args, cmd = m.group(1), m.group(2)
                if cmd == "H":
                    r, c = (int(v) - 1 for v in args.split(";"))
                elif cmd == "m" and args.startswith("48;2;"):
                    parts = [int(v) for v in args.split(";")]
                    j = parts.index(48)
                    bgc = tuple(parts[j + 2:j + 5])
                i = m.end()
                continue
            grid[r][c] = bgc
            c += 1
            i += 1
        names = {RED: "1", WHITE: "2", BLACK: "3", (0, 0, 255): "."}
        picture = ["".join(names.get(cell, "?") for cell in row) for row in grid]
        self.assertEqual(picture[0], "1" * 20)
        self.assertEqual(picture[1], "1" + "2" * 18 + "1")
        self.assertEqual(picture[2], "12" + "3" * 16 + "21")
        self.assertEqual(picture[5], "123" + "." * 14 + "321")
        self.assertEqual(picture[9], "1" * 20)

    def test_ctrl_c_leaves_no_typed_input_behind(self):
        """The fixture puts the tty back with TCSAFLUSH: keys typed while it ended are dropped, never read by the shell
        with its echo off (zsh then showed "cho" for "echo", cmux22 2026-11-03)."""
        text = (HERE.parent / "pixel" / "tui_border.py").read_text()
        restore = text[text.index("def restore_tty"):text.index("def run(")]
        self.assertIn("TCSAFLUSH", restore)
        self.assertNotIn("TCSADRAIN", restore)

    def test_glyph_inks_are_never_a_fixture_class(self):
        """Every glyph's color (the ruler, the centre text) on every fill is "other" for the judge: a black-class ink
        (48, 48, 48) next to ring 3 started walks at a ruler digit on cmux22 (px-col-drag-2-s1r-s1 frames 516-527)."""
        import re
        tool = HERE.parent / "pixel" / "tui_border.py"
        for fill in ("#FFFF00", "#00FF00", "#0000FF"):
            done = subprocess.run([sys.executable, "-I", str(tool), "--size", "40x16", "--frames", "1", "--fill", fill],
                                  capture_output=True, text=True, timeout=30)
            inks = {tuple(int(v) for v in m.group(1).split(";")) for m in re.finditer(r"\x1b\[38;2;([0-9;]+)m", done.stdout)}
            self.assertTrue(inks, fill)
            px = np.array([[list(ink[::-1]) + [255] for ink in sorted(inks)]], np.uint8)
            self.assertEqual(set(jp.classify(px)[0].tolist()), {jp.OTHER}, f"{fill}: inks {sorted(inks)}")
        page = (HERE.parent / "pixel" / "page.html").read_text()
        for gray in re.findall(r'(?:ink|other) = luma\(bg\) > 110 \? "(#[0-9A-F]{6})" : "(#[0-9A-F]{6})"', page)[0]:
            v = [int(gray[i:i + 2], 16) for i in (1, 3, 5)]
            self.assertEqual(jp.classify(np.array([[v[::-1] + [255]]], np.uint8))[0, 0], jp.OTHER, gray)


if __name__ == "__main__":
    unittest.main(verbosity=2)
