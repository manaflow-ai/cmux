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
fits: clock not found, judged on the fixed clock; clock-late2-off-centre adds divider-off-centre's trace), clock-late-inset is clock-late with both edges 1 px inside their pane
edges while they move (device-pixel rounding: still the sample they show), strip-clock-late is clock-late with the tab strips, and still has no motion. blip: B's page 4 px right of its pane edge in frames 35-36 and 1 px in frame 40,
after the divider has landed (B's own defect). Pair C: the film never shows the divider layer (its band shows the shell),
so only the trace's divider is judged, against the gap between its two panes: divider-off-centre moves the trace's
divider rect 2 pt right of that gap's middle in samples 30-35, 0.5 pt (1 px) in sample 40 and 0.25 pt in sample 45 (the
film unchanged; and a pane below the window whose edge is in the gap); closing-slot puts a closing pane's
rect (pc, not a fixture pane, its slot drawn as its black ground) between A and B, with a divider on each side of it;
closing-key is the same film with the closing pane's ground only in the S3d trace key `closing` (its host is not in
`panes`, as the S3 sampler skips a host that shows a closing ground). The m6 films (3e), all with the tab strips on time:
strip-page-late (B's page one sample late: its left edge the previous frame's), strip-tui-b-late (B a terminal one sample
late), strip-whole-late (frames 15-18 show the previous sample, strips and content: late as a whole), strip-repeat
(B's page one sample late in frames 11-20, frame 20 a copy of frame 19: a dropped refresh), strip-stretch (B's page rings twice as wide in
frames 20-22) and strip-hidden (B's tab strip not drawn in frames 20-22).
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
# m18/m14 terminal surface films (the trace's `terminal` rows): held, stale, on its pane, and the owned (frame owner) rows
SURFACE_VARIANTS = ("strip-held", "strip-stale", "strip-surface", "strip-surface-owned", "strip-held-owned")
HELD_SAMPLES = {"strip-held": 14, "strip-held-owned": 5}  # samples 10.. whose committed surface keeps A_REST
# m18 text wrap (pixel-perfect's primary-screen fixture): A shows lines of solid blocks, one color per line, wrapped at its
# columns; strip-wrap re-wraps every frame, strip-wrap-crop keeps the rest wrap while A shrinks (its rows run past the last
# whole cell, cut by the view), strip-wrap-narrow keeps it while A grows (every row short at one column)
WRAP_VARIANTS = ("strip-wrap", "strip-wrap-crop", "strip-wrap-narrow")
# pixel-perfect's wrap kit fixture (kit 475fced167b): a pane of kind "wrap" (no rings, no fill), cell 16 px, padding 8 px,
# lines of #8000FF and #FF8000 (line 1 #8000FF), each line 2 full rows and a 5-cell last row; the judge's defaults
WRAP_KIND_VARIANTS = ("strip-wrap-kind", "strip-wrap-kind-crop")
WRAP_KIND_COLORS = [(0x80, 0x00, 0xFF), (0xFF, 0x80, 0x00)]
WRAP_KIND_PAD = 8
# m20 page films: B's page one sample late with the host clip at its pane edge; 2 samples late with a page-colored gap;
# its layout width frozen while its pane grows (a page-colored gap)
PAGE_LAG = {"strip-page-lag2": 2, "strip-page-lag3": 3, "strip-page-lag2-bg": 2}
PAGE_CLIP = {"strip-page-clip": 1, "strip-page-clip-wide": 8}  # samples late; the host's clip at the pane edge
WRAP_COLORS = [(200, 60, 20), (20, 160, 60), (60, 60, 200)]
WRAP_LINE_ROWS = 4         # each line: 3 full rows, then a last row of 5 cells


def wrap_cols(w_px, pad=PAD):
    return (int(round(w_px)) - 2 * pad) // CW


def wrap_cols_shown(s, variant):
    """The columns A's text is wrapped at in sample s."""
    pad = WRAP_KIND_PAD if variant in WRAP_KIND_VARIANTS else PAD
    if variant not in ("strip-wrap", "strip-wrap-kind") and MOVE[0] <= s < MOVE[1]:
        return wrap_cols(A_REST, pad)  # not re-wrapped: the rest wrap
    return wrap_cols(a_width(s, variant), pad)


def draw_wrap(img, x0, w, cols, y0, pad=PAD, colors=WRAP_COLORS, line_rows=WRAP_LINE_ROWS):
    """A primary-screen terminal in [x0, x0 + w) x [y0, H): its ground, then lines of solid blocks wrapped at COLS columns
    (cut by the view's edge), one color per line of LINE_ROWS rows (the last one 5 cells)."""
    x0, w = int(round(x0)), int(round(w))
    img[y0:, x0:x0 + w] = CYAN
    for r in range((H - y0 - 2 * pad) // CH):
        line, part = divmod(r, line_rows)
        n = cols if part < line_rows - 1 else min(5, cols)
        y = y0 + pad + r * CH
        img[y:y + CH, x0 + pad:min(x0 + pad + n * CW, x0 + w)] = colors[line % len(colors)]


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
    if variant in ("still", "strip-glow", "strip-glow-off3"):
        return float(A_REST)
    if variant == "strip-view-kept":
        return float(A_REST + 80 if k < MOVE[0] else A_REST)  # a Reduce Motion shrink: one jump at sample 10
    if variant in SURFACE_VARIANTS:
        return float(A_REST + 2 * min(max(k - MOVE[0] + 1, 0), 14))  # grows 2 px (1 pt) per sample over samples 10-23
    if variant == "strip-grid-grows":
        return float(A_REST + 4 * min(max(k - MOVE[0] + 1, 0), MOVE[1] - MOVE[0]))  # grows 80 px over samples 10-29
    if variant.startswith("spring"):
        t = (k - MOVE[0] + 1) * P
        if k < MOVE[0]:
            return float(A_REST)
        g = float(jp.spring_g(t, SPRING["response"], SPRING["damping"]))
        return A_REST + 40 * (1 - g)
    if variant == "strip-wrap-narrow":
        return float(A_REST + 4 * min(max(k - MOVE[0] + 1, 0), MOVE[1] - MOVE[0]))  # grows 80 px over samples 10-29
    sign = -1 if variant in ("cut", "backdrop", "strip-page-lag2", "strip-page-lag3", "strip-page-lag2-bg", "strip-page-frozen",
                             "strip-wrap-crop", "strip-wrap-kind-crop") else 1  # A shrinks
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


def draw_tui_at(img, x0, w, fill, y0=0):
    """tui_border.py's picture with FILL in [x0, x0 + w) x [y0, H) (a second terminal pane)."""
    x0, w = int(round(x0)), int(round(w))
    img[y0:, x0:x0 + w] = CYAN
    cols, rows = (w - 2 * PAD) // CW, (H - y0 - 2 * PAD) // CH
    for r in range(rows):
        for c in range(cols):
            k = min(r, c, rows - 1 - r, cols - 1 - c)
            img[y0 + PAD + r * CH:y0 + PAD + (r + 1) * CH, x0 + PAD + c * CW:x0 + PAD + (c + 1) * CW] = \
                [RED, WHITE, BLACK][k] if k < 3 else fill


def draw_page(img, x0, w, y0=0, fill=GREEN, rings=(2, 4, 6)):
    """page.html at DPR 2 in [x0, x0 + w) x [y0, H): 2, 4, 6 device px (RINGS) of red, white, black, then the fill."""
    x0, w = int(round(x0)), int(round(w))
    x0c = max(x0, 0)
    img[y0:, x0c:x0 + w] = fill
    inset = 0
    for color, width in zip((RED, WHITE, BLACK), rings):
        a, b = x0 + inset, x0 + w - inset
        top, bottom = y0 + inset, H - inset
        img[top:top + width, max(a, 0):b] = color
        img[bottom - width:bottom, max(a, 0):b] = color
        img[top:bottom, max(a, 0):max(a + width, 0)] = color
        img[top:bottom, b - width:b] = color
        inset += width


# The clock films: how many refreshes later than the fixed clock each frame shows its sample (+ later, - earlier).
CLOCK_SHIFT = {"clock-late": 1, "strip-clock-late": 1, "clock-early": -1, "clock-late2": 2, "clock-late-inset": 1,
               "clock-late2-off-centre": 2}


def frame(k, variant):
    """The picture shown at refresh k (sample k - 1 committed; the clock films shift it by CLOCK_SHIFT)."""
    if variant == "strip-repeat" and k == 20:
        return frame(19, variant)  # a dropped refresh: frame 20 repeats frame 19
    if variant in ("strip-repeat-clean", "strip-repeat-blink") and k == 20:
        img = frame(19, "strip")  # frame 20 repeats frame 19 (the strips' film: every layer on time otherwise)
        if variant == "strip-repeat-blink":
            img[ROWS[0], PAD + 5 * CW:PAD + 5 * CW + 6] = GLYPH  # a cursor blink: 6 px of one row inside A's fill
        return img
    if variant == "strip-nudge" and k == 20:
        img = frame(19, "strip")  # frame 20 shows frame 19 with A's right edge 1 px further: not a repeat
        aw = int(round(a_width(18, "strip")))
        img[ROWS[1], aw] = CYAN  # one pixel, at A's pane edge
        return img
    shift = CLOCK_SHIFT.get(variant, 0) + (1 if variant == "strip-whole-late" and 15 <= k <= 18 else 0)
    s = min(max(k - 1 - shift, 0), N - 1)
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
    if variant == "strip-tui-a-late" and 11 <= k <= 30:
        a_view = a_width(max(s - 1, 0), variant)  # m14: A's view keeps the previous sample's size (m6 "late"), anchored top-left
    if variant in WRAP_VARIANTS:
        draw_wrap(img, 0, a_view, wrap_cols_shown(s, variant), y0)
    elif variant in WRAP_KIND_VARIANTS:
        draw_wrap(img, 0, a_view, wrap_cols_shown(s, variant), y0, pad=WRAP_KIND_PAD, colors=WRAP_KIND_COLORS, line_rows=3)
    elif variant in HELD_SAMPLES and MOVE[0] <= s < MOVE[0] + HELD_SAMPLES[variant]:
        # m14 held: the surface keeps its old size (A_REST) while the pane grows; the host paints the terminal's ground
        # beside it, so the pixels show A's old grid padded by its own ground up to the new pane edge (they pass)
        draw_tui(img, 0, a_view, picture_w=A_REST, y0=y0)
    elif variant == "strip-view-kept" and s == MOVE[0]:
        # 3e.8: the first frame after the jump keeps A's old, wider view (its old grid), cut by A's new pane edge: fill up
        # to the pane edge, then the shell (as the S4 keep path in a Reduce Motion shrink)
        draw_tui_cut(img, 0, int(round(a_view)), A_REST + 80, y0=y0)
    elif variant == "strip-grid-grows" and MOVE[0] <= s < MOVE[1]:
        draw_tui_cut(img, 0, int(round(a_view)), A_REST + 80, y0=y0)  # the press's final grid, cut by the growing view
    else:
        draw_tui(img, 0, a_view, picture_w=a_width(max(s - 3, 0), variant) if variant == "cut" else None, y0=y0)
    if variant == "strip-tui-a-late" and 11 <= k <= 30:
        img[y0:, int(round(a_view)):int(round(aw))] = BLACK  # behind A's old-size view: no shell (m6 E4 does not fire)
    if variant == "glyph":
        # A ruler digit in the old black-class ink just inside A's left ring 3, on every row.
        img[y0:, PAD + 3 * CW + 2:PAD + 3 * CW + 6] = GLYPH
        if 30 <= k <= 33:
            # A's right rings and ground strip gone (its view shrank before the program redrew): the shell after the fill.
            img[:, int(round(aw)) - 60:int(round(aw))] = MAGENTA
    b_x = aw + DIV_PX + (1 if inset else 0)  # and B's 1 px inside its own
    b_strip_x = b_x  # B's tab strip: on time in the m6 films (its content may be late)
    if variant in ("strip-page-late", "strip-tui-b-late") or (variant == "strip-repeat" and k <= 20):
        b_x = a_width(max(s - 1, 0), variant) + DIV_PX  # B's content one sample late
    if variant in ("closing-slot", "closing-key"):
        img[:, int(round(aw)) + DIV_PX:int(round(aw)) + DIV_PX + SLOT_PX] = BLACK  # the closing pane's ground
        b_x = aw + DIV_PX + SLOT_PX + DIV_PX
    if variant == "lag1":
        b_x = a_width(max(k - 2, 0), variant) + DIV_PX  # B's page one frame late
    if variant in PAGE_LAG:
        # m18, m20: B grows (A shrinks); B's page shows the frame of 2 or 3 samples before: inside its pane, smaller than it
        b_x = a_width(max(s - PAGE_LAG[variant], 0), variant) + DIV_PX
    if variant in PAGE_CLIP:
        b_x = a_width(max(s - PAGE_CLIP[variant], 0), variant) + DIV_PX  # m20: B's page late, over the divider until the clip
    if variant == "hidden" and 30 <= k <= 32:
        # B's page covers A's view from the inner edge of A's ring 1 on (the cyan strip, the gap and ring 1).
        cols = (int(round(aw)) - 2 * PAD) // CW
        b_x = PAD + (cols - 1) * CW
    if variant == "blip" and k in (35, 36, 40):
        b_x += 1 if k == 40 else 4  # B's page right of its pane edge after the divider has landed (1 px: just off)
    if variant == "d4-cover" and s >= 30:
        draw_page(img, b_x - 1, W - b_x + 1, y0=y0)  # the page window 0.5 pt left of its host (and as much wider)
    elif variant == "strip-tui-b-late":
        draw_tui_at(img, b_x, W - b_x, GREEN, y0=y0)  # B: a terminal below its strip, one sample late
    elif variant == "strip-stretch" and 20 <= k <= 22:
        draw_page(img, b_x, W - b_x, y0=y0, rings=(4, 8, 12))  # B's page stretched: its rings twice as wide
    elif variant == "strip-squeeze" and 20 <= k <= 22:
        draw_page(img, b_x, W - b_x, y0=y0, rings=(1, 2, 3))  # m14: B's page squeezed: its rings half as wide
    elif variant == "strip-page-frozen" and MOVE[0] <= s < MOVE[1]:
        # m20: B's layout width frozen at rest while its pane grows: on its lo edge, the host's page-colored gap beyond
        rest_w = W - (A_REST + DIV_PX)
        img[y0:, int(round(b_x)):] = GREEN
        draw_page(img, b_x, rest_w, y0=y0)
    elif variant == "samefill":
        if not 30 <= k <= 32:
            draw_tui_at(img, b_x, W - b_x, YELLOW)  # B: a terminal of A's own fill; it shows nothing for 3 frames
    elif variant == "held" and 15 <= k <= 25:
        pass  # B shows nothing: the shell from A's content to the window's edge
    else:
        draw_page(img, b_x, W - b_x, y0=y0)
    if variant in PAGE_CLIP:
        # the host clips the page at its pane: the part over the divider is not drawn (the divider's shell shows)
        img[y0:, int(round(b_x)):int(round(aw + DIV_PX))] = MAGENTA
    if variant == "strip-page-lag2-bg":
        img[y0:, int(round(aw + DIV_PX)):int(round(b_x))] = GREEN  # m20 item 1: the lag gap in the page's own color
    if variant == "cue" and 12 <= k <= 28:
        img[:, int(round(b_x)):int(round(b_x)) + 6] = CUE  # the drag cue over B's rings 1 and 2
    if has_strip(variant):
        late = a_width(max(k - 2, 0), variant) + DIV_PX if 11 <= k <= 30 else b_x
        draw_strip(img, -SCROLL_PX if variant == "strip-scrolled" else 0, aw, 0)
        strip_x = late if variant == "strip-lag" else b_strip_x
        if not (variant == "strip-hidden" and 20 <= k <= 22):
            draw_strip(img, strip_x, W, late if variant in ("strip-lag", "pill-lag") else b_strip_x)
        if touching(variant):
            # The divider band on the strip row is the neighbour's strip ground, not the shell: the strips touch.
            img[:STRIP_PX, int(round(aw)):int(round(b_x))] = BLACK
    if variant in ("strip-glow", "strip-glow-off3") and 30 <= k <= 49:
        # 3e.7: the pressed divider's glow band over the strip row (ab-s2bmin-d8ac2f4 clamp-2x on-s0125 frame 390): over
        # the gap the cue (#FF04FF) and the halo (#ED65F5, 3 px), over B's strip its first pixel gray (#62646A) and dark
        # gray after (#111213). strip-glow-off3: B's strip truly starts 3 px early, in the gap, under the same glow.
        g = int(round(aw))
        img[:STRIP_PX, g] = (255, 4, 255)
        if variant == "strip-glow":
            img[:STRIP_PX, g + 1:g + 4] = (237, 101, 245)
            img[:STRIP_PX, g + 4] = (98, 100, 106)
            img[:STRIP_PX, g + 5:g + 10] = (17, 18, 19)
        else:
            img[:STRIP_PX, g + 1] = (98, 100, 106)
            img[:STRIP_PX, g + 2:g + 10] = (17, 18, 19)
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


# The stacked films (3e.5): pane T (terminal, yellow) over pane U (terminal, green), each with a tab strip at its top; a
# Reduce Motion row press moves the row divider ST_JUMP px up at sample MOVE[0] (one layout change, no spring).
SH = 800                   # the stacked films' height (device px)
ST_REST, ST_JUMP = 480, 80  # T's height at rest; the press moves the divider this far up
ST_ROWS = [12, 236, 496, 620]  # T's strip row, T's content (a fill row), U's strip row at rest, U's content (a fill row)


def stack_top_h(k):
    return ST_REST - (ST_JUMP if k >= MOVE[0] else 0)


def draw_tui_box(img, x0, x1, y0, y1, fill):
    """tui_border.py's picture with FILL in [x0, x1) x [y0, y1)."""
    img[y0:y1, x0:x1] = CYAN
    cols, rows = (x1 - x0 - 2 * PAD) // CW, (y1 - y0 - 2 * PAD) // CH
    for r in range(rows):
        for c in range(cols):
            k = min(r, c, rows - 1 - r, cols - 1 - c)
            img[y0 + PAD + r * CH:y0 + PAD + (r + 1) * CH, x0 + PAD + c * CW:x0 + PAD + (c + 1) * CW] = \
                [RED, WHITE, BLACK][k] if k < 3 else fill


def draw_strip_at(img, x0, x1, y0):
    """A tab strip over [x0, x1) x [y0, y0 + STRIP_PX): black ground, the selected pill in gray 22."""
    img[y0:y0 + STRIP_PX, x0:x1] = BLACK
    img[y0 + 4:y0 + STRIP_PX - 4, x0 + 16:x0 + 216] = PILL


def stack_frame(k, variant):
    """The stacked film's picture at refresh k (sample k - 1). stack-repeat: the first frame due to show the new layout
    (refresh MOVE[0] + 1) repeats the frame before (the window server presented the previous picture)."""
    if variant == "stack-repeat" and k == MOVE[0] + 1:
        return stack_frame(k - 1, variant)
    s = min(max(k - 1, 0), N - 1)
    ht = stack_top_h(s)
    img = np.zeros((SH, W, 3), np.uint8)
    img[:] = MAGENTA
    draw_strip_at(img, 0, W, 0)
    draw_tui_box(img, 0, W, STRIP_PX, ht, YELLOW)
    draw_strip_at(img, 0, W, ht + DIV_PX)
    draw_tui_box(img, 0, W, ht + DIV_PX + STRIP_PX, SH, GREEN)
    return img


def build_stack(root, name, variant):
    base = Path(root) / name
    header = {"width": W, "height": SH, "rows": ST_ROWS, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for k in range(N):
            px = bgra(stack_frame(k, variant))
            out.write(struct.pack("<d", T0 + k * P))
            for y in ST_ROWS:
                out.write(px[y].tobytes())
            for x in COLS:
                out.write(px[:, x].tobytes())
    cy, ww = STRIP_PX / SCALE, W / SCALE
    samples = []
    for k in range(N):
        ht = stack_top_h(k) / SCALE
        yu, hu = ht + DIV_PX / SCALE, (SH - stack_top_h(k) - DIV_PX) / SCALE
        t = ["pt", 0, 0, ww, ht, 1, 0, 0, 0, ww, ht, ww, ht - cy, 0, 0, cy, ww, ht - cy]
        u = ["pu", 0, yu, ww, hu, 1, 1, 0, yu, ww, hu, ww, hu - cy, 0, 0, yu + cy, ww, hu - cy]
        samples.append({"t": k * P * 1000, "window": [ww, SH / SCALE], "panes": [t, u],
                        "dividers": [["d0", 0, ht, ww, DIV_PX / SCALE, 1, 2]], "page": []})
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    rest_u = (ST_REST + DIV_PX) / SCALE
    note = {"scale": SCALE, "panes": {"pt": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pu": {"kind": "tui", "fill": "#00FF00", "label": "p1"}},
            "speed": 1.0, "reduce": True, "input": "keys", "window_frame": [WINDOW_X, 50, ww, SH / SCALE],
            "page_backdrop": False, "lines": {"strip_rows": {"pt": ST_ROWS[0], "pu": ST_ROWS[2]}},
            "chrome": [{"pane": "pt", "cell": [0, 0, ww, ST_REST / SCALE], "strip": [0, 0, ww, cy]},
                       {"pane": "pu", "cell": [0, rest_u, ww, SH / SCALE - rest_u], "strip": [0, rest_u, ww, cy]}]}
    journal = [{"seq": 1, "uptimeNanos": int((T0 + (MOVE[0] - 0.5) * P) * 1e9),
                "kind": {"key": {"_0": {"phase": "down", "keyCode": 38, "isRepeat": False}}}}]
    Path(f"{base}.events.json").write_text(json.dumps({"hid": [], "journal": journal}))
    meta = {"start": {"width": W, "height": SH, "scale": SCALE, "rows": ST_ROWS, "columns": COLS}, "notes": {"pixel": note}}
    Path(f"{base}.meta.json").write_text(json.dumps(meta))
    return base


# The touching-ground films (3e.3): terminal A's ground strip runs on into another ground of the same color with no shell
# between (#00FFFF: the fixture's terminal ground), past A's own pane edge.
#   touch-close: A | B | C (terminals A and B, page C), every pane touching the next with no shell band (as the columns
#     of ab-s3d-base-154073f px-close-column-c3-s1r-s1: A's right ground meets B's left ground). B closes over samples
#     10-29 while A grows over it; from sample 30 B is gone and A touches C.
#   ground-touch: A | band | P | band | C at rest; P closes over samples 10-29: its slot shows only its ground (S3d
#     `closing` key, not a pane row), A grows into it and touches it with no band, A's picture not yet redrawn for its new
#     grid (its fill runs to its view's last whole cell, no right ring), from sample 30 A redrawn at its new width.
#   page-late: A | C (page C touching terminal A, no band); A shrinks 2 px per sample over samples 10-29 and C grows into
#     its place; frames 15-18 show A and C one sample late (A's ground runs 2 px past A's pane edge, into C's rect).
TG_B, TG_P = 160, 60        # B's and P's widths at rest (device px; B wide enough to show its fill)


def tg_widths(k, variant):
    """(A's width, the closing pane's or ground's width) in sample k (device px)."""
    if variant == "page-late":
        return float(A_REST - 2 * min(max(k - MOVE[0] + 1, 0), MOVE[1] - MOVE[0])), 0.0
    full = TG_B if variant == "touch-close" else TG_P
    if k < MOVE[0]:
        return float(A_REST if variant == "touch-close" else A_REST), float(full)
    gone = min(k - MOVE[0] + 1, MOVE[1] - MOVE[0]) / (MOVE[1] - MOVE[0])
    grow = full * gone + (0 if variant == "touch-close" else DIV_PX * gone)
    return float(A_REST + grow), float(full * (1 - gone))


def tg_frame(k, variant):
    s = min(max(k - 1 - (1 if variant == "page-late" and 15 <= k <= 18 else 0), 0), N - 1)
    aw, cw = tg_widths(s, variant)
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = MAGENTA
    a = int(round(aw))
    closing = variant == "ground-touch" and MOVE[0] <= s < MOVE[1]
    if closing:
        draw_tui(img, 0, a, picture_w=a + 8 * CW)  # the old grid: no right ring, fill to the last whole cell
    else:
        draw_tui(img, 0, a)
    x = a
    if variant in ("touch-close", "page-late"):
        if cw >= 1:
            draw_tui_at(img, x, int(round(cw)), BLUE)  # B, touching A
        x += int(round(cw))
        draw_page(img, x, W - x)  # C, touching B (or A)
        return img
    else:
        if s < MOVE[0]:
            x += DIV_PX
            draw_tui_at(img, x, int(round(cw)), BLUE)  # P at rest, its own band on both sides
            x += int(round(cw))
        elif closing and cw >= 1:
            img[:, x:x + int(round(cw))] = CYAN  # P's closing ground, touching A
            x += int(round(cw))
    draw_page(img, x + DIV_PX, W - x - DIV_PX)
    return img


def build_touch(root, name, variant):
    base = Path(root) / name
    header = {"width": W, "height": H, "rows": ROWS, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for k in range(N):
            px = bgra(tg_frame(k, variant))
            out.write(struct.pack("<d", T0 + k * P))
            for y in ROWS:
                out.write(px[y].tobytes())
            for x in COLS:
                out.write(px[:, x].tobytes())
    samples = []
    for k in range(N):
        aw, cw = (v / SCALE for v in tg_widths(k, variant))
        a = ["pa", 0, 0, aw, 150, 1, 0, 0, 0, aw, 150, aw, 150, 0, 0, 0, aw, 150]
        panes, closing_key, x = [a], None, aw
        if variant in ("touch-close", "page-late"):
            if cw > 0:
                panes.append(["pb", x, 0, cw, 150, 1, 1, x, 0, cw, 150, cw, 150, 0, x, 0, cw, 150])
            x += cw
        elif k < MOVE[0]:
            x += DIV_PX / SCALE
            panes.append(["pp", x, 0, cw, 150, 1, 1, x, 0, cw, 150, cw, 150, 0, x, 0, cw, 150])
            x += cw
        elif k < MOVE[1]:
            closing_key = [["pp", x, 0, cw, 150, 1, 2]]
            x += cw
        cx = x + (0 if variant in ("touch-close", "page-late") else DIV_PX / SCALE)
        panes.append(["pc", cx, 0, 300 - cx, 150, 1, 2, cx, 0, 300 - cx, 150, 300 - cx, 150, 0, cx, 0, 300 - cx, 150])
        # touch-close: the divider's rect straddles the touching panes' edge (a hit area under them, as the app's).
        dx = x - DIV_PX / SCALE / 2 if variant in ("touch-close", "page-late") else x
        samples.append({"t": k * P * 1000, "window": [300, 150], "panes": panes,
                        "dividers": [["d0", dx, 0, DIV_PX / SCALE, 150, 1, 2]], "page": [],
                        **({"closing": closing_key} if closing_key else {})})
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    note = {"scale": SCALE, "panes": {"pa": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pb": {"kind": "tui", "fill": "#0000FF", "label": "p1"},
                                      "pp": {"kind": "tui", "fill": "#0000FF", "label": "p1"},
                                      "pc": {"kind": "page", "fill": "#00FF00", "label": "p2"}},
            "speed": 1, "reduce": False, "input": "drag", "window_frame": [WINDOW_X, 50, 300, 150], "page_backdrop": False}
    Path(f"{base}.events.json").write_text(json.dumps({"hid": [], "journal": []}))
    meta = {"start": {"width": W, "height": H, "scale": SCALE, "rows": ROWS, "columns": COLS}, "notes": {"pixel": note}}
    Path(f"{base}.meta.json").write_text(json.dumps(meta))
    return base


# The window-edge films (3e.2): the scan is wider than the window (the capture runs 40 device px past the window's right
# edge, as on the minis: 2872 px of scan for a 2722 px window), and the desktop beyond shows the wallpaper (DESKTOP:
# black, a red pixel, gray), as in ab-btl-sw-dbf5c8b px-keys-held-2-sw-keyresizetopleft-on-s1 frame 160.
#   page-clipped: terminal A | band | page C, C's right edge on the window's right edge. A grows 2 px per sample over
#     samples 10-29 and C's pane shrinks from the left; while it moves, C's page keeps 6 px more than its pane (anchored
#     top-left, as with browserResize.keyResizeTopLeft): its ring 3 shows inside the window, rings 2 and 1 are past the
#     window's edge (not drawn).
#   pane-past: the same, but C's pane runs 20 px past the window's edge in every sample and its page is at its size (its
#     right rings are past the window: C's right edge is not on screen).
#   page-far: as page-clipped, but C's page keeps 16 px more than its pane: its fill runs into the window's edge (every
#     ring past it), as in ab-btl-sw-dbf5c8b keyresizetopleft-on-s1 frames 161-165.
#   tui-grid: page C | band | terminal A (A's right edge on the window's right edge). C shrinks and A GROWS 2 px per
#     sample; while it grows, A's grid is the press's final one, wider than its view: its right edge shows fill, then
#     12 px of ring 3 up to the window's edge, and no ring 2, ring 1 or ground (ab-s4pin-44ab81a
#     px-keys-rk-3t-sw-terminals-on-s1 frame 158: one program grid per press).
#   tui-view-wider: the same picture while A SHRINKS (C grows): the view kept its old, wider size anchored top-left, so
#     its rings run past the window's edge.
#   tui-lo-cut (3e.8): A GROWS to the left as in tui-grid, but A's grid sits 60 px left of A's pane: A's pane edge cuts
#     its left rings, so A's fill runs into the shell at A's lo edge (content pushed past the pane's near edge).
WE_W = 640                  # scan width (device px); the window is W (600) wide
DESKTOP = [BLACK] * 17 + [(128, 128, 128)] + [RED] + [(128, 128, 128)] * 3 + [BLACK] * 2 + [(128, 128, 128)] * 16


def we_frame(k, variant):
    s = min(max(k - 1, 0), N - 1)
    aw = a_width(s, "strip")
    img = np.zeros((H, WE_W, 3), np.uint8)
    img[:] = MAGENTA
    if variant in ("tui-grid", "tui-view-wider", "tui-lo-cut"):
        if variant in ("tui-grid", "tui-lo-cut"):
            aw = 2 * A_REST - a_width(s, "strip")  # C shrinks while A grows
        draw_page(img, 0, int(round(aw)), y0=STRIP_PX)
        t_x = int(round(aw)) + DIV_PX
        if variant == "tui-lo-cut" and MOVE[0] <= s < MOVE[1]:
            tmp = np.zeros((H, W + 64, 3), np.uint8)
            draw_tui_at(tmp, 0, W - t_x + 60, BLUE, y0=STRIP_PX)  # the grid 60 px wider, its left 60 px past A's lo edge
            img[:, t_x:W] = tmp[:, 60:60 + W - t_x]
        else:
            draw_tui_at(img, t_x, W - t_x, BLUE, y0=STRIP_PX)
        if MOVE[0] <= s < MOVE[1] and variant != "tui-lo-cut":
            img[STRIP_PX + PAD + CH:H - PAD - CH, W - 40:W - 12] = BLUE  # the final grid's inner cells, then its ring 3
            img[STRIP_PX:, W - 12:W] = BLACK
        draw_strip(img, 0, int(round(aw)), 0)
        draw_strip(img, t_x, W, t_x)
        img[:, W:] = np.array(DESKTOP, np.uint8)[None, :, :]
        return img
    draw_tui(img, 0, aw, y0=STRIP_PX)
    c_x = int(round(aw)) + DIV_PX
    c_w = W - c_x + (20 if variant == "pane-past" else 0)
    late = MOVE[0] <= s < MOVE[1] and variant in ("page-clipped", "page-far")
    draw_page(img, c_x, c_w + ((16 if variant == "page-far" else 6) if late else 0), y0=STRIP_PX)
    draw_strip(img, 0, int(round(aw)), 0)  # each pane's tab strip on its own pane edges: cmux's layer
    draw_strip(img, c_x, c_x + c_w, c_x)
    img[:, W:] = np.array(DESKTOP, np.uint8)[None, :, :]  # past the window's edge: the desktop, never the app
    return img


def build_window_edge(root, name, variant):
    base = Path(root) / name
    rows = [STRIP_ROW] + ROWS
    header = {"width": WE_W, "height": H, "rows": rows, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for k in range(N):
            px = bgra(we_frame(k, variant))
            out.write(struct.pack("<d", T0 + k * P))
            for y in rows:
                out.write(px[y].tobytes())
            for x in COLS:
                out.write(px[:, x].tobytes())
    samples = []
    for k in range(N):
        aw = (2 * A_REST - a_width(k, "strip") if variant in ("tui-grid", "tui-lo-cut") else a_width(k, "strip")) / SCALE
        cx = aw + DIV_PX / SCALE
        cy = STRIP_PX / SCALE
        a = ["pa", 0, 0, aw, 150, 1, 0, 0, 0, aw, 150, aw, 150 - cy, 0, 0, cy, aw, 150 - cy]
        cw = 300 - cx + (10 if variant == "pane-past" else 0)  # pane-past: C's pane runs 20 device px past the window
        c = ["pc", cx, 0, cw, 150, 1, 1, cx, 0, cw, 150, cw, 150 - cy, 0, cx, cy, cw, 150 - cy]
        if variant in ("tui-grid", "tui-view-wider", "tui-lo-cut"):  # the page on the left, the terminal on the right
            a = ["pa", cx, 0, 300 - cx, 150, 1, 1, cx, 0, 300 - cx, 150, 300 - cx, 150 - cy, 0, cx, cy, 300 - cx, 150 - cy]
            c = ["pc", 0, 0, aw, 150, 1, 0, 0, 0, aw, 150, aw, 150 - cy, 0, 0, cy, aw, 150 - cy]
        samples.append({"t": k * P * 1000, "window": [300, 150], "panes": [a, c],
                        "dividers": [["d0", aw, 0, DIV_PX / SCALE, 150, 1, 2]], "page": []})
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    note = {"scale": SCALE, "panes": {"pa": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pc": {"kind": "page", "fill": "#00FF00", "label": "p1"}},
            "speed": 1, "reduce": False, "input": "keys", "window_frame": [WINDOW_X, 50, 300, 150], "page_backdrop": False,
            "lines": {"strip_rows": {"pa": STRIP_ROW, "pc": STRIP_ROW}}}
    a0, c0 = A_REST / SCALE, (A_REST + DIV_PX) / SCALE
    left, right = ("pc", "pa") if variant in ("tui-grid", "tui-view-wider", "tui-lo-cut") else ("pa", "pc")
    note["chrome"] = [{"pane": left, "cell": [0, 0, a0, 150], "strip": [0, 0, a0, 12], "pill": [8, 2, 100, 8]},
                      {"pane": right, "cell": [c0, 0, 300 - c0, 150], "strip": [c0, 0, 300 - c0, 12], "pill": [c0 + 8, 2, 100, 8]}]
    if variant in ("tui-grid", "tui-view-wider", "tui-lo-cut"):
        note["panes"]["pa"]["fill"] = "#0000FF"
    Path(f"{base}.events.json").write_text(json.dumps({"hid": [], "journal": []}))
    meta = {"start": {"width": WE_W, "height": H, "scale": SCALE, "rows": rows, "columns": COLS}, "notes": {"pixel": note}}
    Path(f"{base}.meta.json").write_text(json.dumps(meta))
    return base


# The rest-cut films (3e.6): terminal A | band | page B, as the strip films (no strips). At rest A's view is 18 px
# narrower than the grid it shows: the pane edge cuts A's last column (ring 1, 16 px) and 2 px of ring 2, so A's right
# side reads rings [0, 14, 16] at rest (as p1 in the Command films ab-cmdb-b5e96a1 / ab-cmdh-307045f
# px-cmd-col-edge-3t-s1: [0, 14, 16] and [0, 16, 16]). While A grows (samples 10-29) its grid fits its view: the rings
# show whole, [16, 16, 16], with the ground strip.
#   rest-cut-stretch: the same, and in samples 20-22 A's cells are drawn 2x wide (a real stretch).
def draw_tui_cut(img, x0, w, picture_w, cw=CW, y0=0, shift=0):
    """tui_border.py's picture for a view PICTURE_W wide, its grid SHIFT px further right, shown in a view W wide at x0
    (the part past W cut)."""
    tmp = np.zeros((H, picture_w + shift + 64, 3), np.uint8)
    tmp[:] = CYAN
    cols, rows = (picture_w - 2 * PAD) // cw, (H - y0 - 2 * PAD) // CH
    ring = [RED, WHITE, BLACK]
    for r in range(rows):
        for c in range(cols):
            k = min(r, c, rows - 1 - r, cols - 1 - c)
            x = PAD + shift + c * cw
            tmp[y0 + PAD + r * CH:y0 + PAD + (r + 1) * CH, x:x + cw] = ring[k] if k < 3 else YELLOW
    img[y0:, x0:x0 + w] = tmp[y0:, :w]


def rc_frame(k, variant):
    s = min(max(k - 1, 0), N - 1)
    aw = int(round(a_width(s, "strip")))
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = MAGENTA
    moving = MOVE[0] <= s < MOVE[1]
    cw = 2 * CW if variant == "rest-cut-stretch" and 20 <= k <= 22 else CW
    if moving:
        draw_tui_cut(img, 0, aw, aw, cw=cw)  # the grid of whole cells that fits, with its ground strip
    else:
        draw_tui_cut(img, 0, aw, aw + CW, shift=6)  # one column more, 6 px right: the pane edge cuts 18 px of it
    b_x = aw + DIV_PX
    draw_page(img, b_x, W - b_x)
    return img


def build_rest_cut(root, name, variant):
    base = Path(root) / name
    header = {"width": W, "height": H, "rows": ROWS, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for k in range(N):
            px = bgra(rc_frame(k, variant))
            out.write(struct.pack("<d", T0 + k * P))
            for y in ROWS:
                out.write(px[y].tobytes())
            for x in COLS:
                out.write(px[:, x].tobytes())
    samples = []
    for k in range(N):
        aw = int(round(a_width(k, "strip"))) / SCALE
        bx = aw + DIV_PX / SCALE
        a = ["pa", 0, 0, aw, 150, 1, 0, 0, 0, aw, 150, aw, 150, 0, 0, 0, aw, 150]
        b = ["pb", bx, 0, 300 - bx, 150, 1, 1, bx, 0, 300 - bx, 150, 300 - bx, 150, 0, bx, 0, 300 - bx, 150]
        samples.append({"t": k * P * 1000, "window": [300, 150], "panes": [a, b],
                        "dividers": [["d0", aw, 0, DIV_PX / SCALE, 150, 1, 2]], "page": []})
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    note = {"scale": SCALE, "panes": {"pa": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pb": {"kind": "page", "fill": "#00FF00", "label": "p1"}},
            "speed": 1, "reduce": False, "input": "keys", "window_frame": [WINDOW_X, 50, 300, 150], "page_backdrop": False}
    Path(f"{base}.events.json").write_text(json.dumps({"hid": [], "journal": []}))
    meta = {"start": {"width": W, "height": H, "scale": SCALE, "rows": ROWS, "columns": COLS}, "notes": {"pixel": note}}
    Path(f"{base}.meta.json").write_text(json.dumps(meta))
    return base


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
        nudge = {**{j: 2.0 for j in range(30, 36)}, 40: 0.5, 45: 0.25}.get(k, 0.0) \
            if variant in ("divider-off-centre", "clock-late2-off-centre") else 0.0
        dividers = [["d0", aw + nudge, 0, DIV_PX / SCALE, 150, 1, 2]]
        closing, closing_key = [], None
        if variant == "divider-off-centre":
            # A pane below the window (y 150-200) whose left edge is in the divider's gap: it shares no part of the
            # divider's extent (y 0-150), so it is no neighbour of the divider.
            closing = [["py", aw + 1, 150, 50, 50, 1, 2, aw + 1, 150, 50, 50, 50, 50, 0, aw + 1, 150, 50, 50]]
        if variant in ("closing-slot", "closing-key"):
            cx, cw = bx, SLOT_PX / SCALE
            if variant == "closing-slot":
                closing = [["pc", cx, 0, cw, 150, 0.4, 2, cx, 0, cw, 150, cw, 150, 0, cx, 0, cw, 150]]  # fading out
            else:
                closing_key = [["pc", cx, 0, cw, 150, 0.4, 2]]  # S3d: [pane, x, y, width, height, alpha, z]
            dividers.append(["d1", cx + cw, 0, DIV_PX / SCALE, 150, 1, 2])
            bx = cx + cw + DIV_PX / SCALE
        bw = 300 - bx
        b = ["pb", bx, 0, bw, 150, 1, 1, bx, 0, bw, 150, bw, 150 - cy, 0, bx, cy, bw, 150 - cy]
        # B's Chromium host fills its content view; d4-cover: its page window 0.5 pt left (and 0.5 pt wider) after the motion.
        shift = 0.5 if variant == "d4-cover" and k >= 30 else 0.0
        page = [bw, 150 - cy, bw + shift, 150 - cy, 0, WINDOW_X + bx, WINDOW_X + bx - shift, bw]
        extra = {"closing": closing_key} if closing_key else {}
        if variant in SURFACE_VARIANTS or variant in WRAP_VARIANTS or variant in WRAP_KIND_VARIANTS:
            # the trace's terminal rows (TerminalSurfaceView+MotionSample): the surface layer [x, y, w, h] (window points,
            # top-left), the shown IOSurface's w and h (device px), render counters, owned, presenter, host frame
            owned = variant.endswith("-owned")
            moving = MOVE[0] <= k <= MOVE[0] + 14
            sw = aw
            if variant == "strip-held" and MOVE[0] <= k < MOVE[0] + HELD_SAMPLES[variant]:
                sw = A_REST / SCALE  # the surface keeps its old size while the pane grows
            if owned and moving:
                # an owned surface whose present request waits: the window's present pass runs after the sampler in the
                # same turn, so the row shows the bounds the previous turn committed (the pane one sample before) ...
                sw = a_width(k - 1, variant) / SCALE
                if variant == "strip-held-owned" and k <= MOVE[0] + HELD_SAMPLES[variant]:
                    sw = A_REST / SCALE  # ... or the old size it keeps (ready-or-keep: its frame is not drawn yet)
            shown_w = A_REST if variant == "strip-stale" and MOVE[0] + 4 <= k <= MOVE[0] + 7 else sw * SCALE
            extra["terminal"] = [[0, cy, sw, 150 - cy, shown_w, (150 - cy) * SCALE, k, k, 2, 2, 0, 0, 1 if owned else 0,
                                  "request" if owned and moving else "-",
                                  ("pending" if moving else "shown") if owned else "-"]]
        samples.append({"t": k * P * 1000, "window": [300, 150], "panes": [a] + closing + [b],
                        "dividers": dividers, "page": [page], **extra})
    # Sample k is taken 1 ms before refresh k is displayed.
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    note = {"scale": SCALE, "panes": {"pa": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pb": {"kind": "page", "fill": "#00FF00", "label": "p1"}},
            "speed": 1, "reduce": False, "input": "drag", "window_frame": [WINDOW_X, 50, 300, 150], "page_backdrop": False}
    if variant == "samefill":
        note["panes"]["pb"] = {"kind": "tui", "fill": "#FFFF00", "label": "p1"}
    if variant == "strip-tui-b-late":
        note["panes"]["pb"] = {"kind": "tui", "fill": "#00FF00", "label": "p1"}
    if variant.startswith("reduce"):
        note.update(reduce=True, speed=1.0, input="drag" if variant == "reduce-drag" else "keys")
    journal = []
    if variant == "reduce-drag":
        journal = [{"seq": 1, "uptimeNanos": int((T0 + 9 * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "down", "x": 150, "y": 50}}}}]
        journal += [{"seq": 2 + i, "uptimeNanos": int((T0 + (10 + i) * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "drag", "x": 151 + i, "y": 50}}}}
                    for i in range(20)]
        journal.append({"seq": 30, "uptimeNanos": int((T0 + 30 * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "up", "x": 170, "y": 50}}}})
    if variant in ("strip-glow", "strip-glow-off3"):
        # the layout holds still; the mouse goes down on the divider (its rect: [A's width, + DIV_PX] pt) before frame 30
        # and up after frame 49 (a held press, as the clamp films' divider held at its limit)
        x = a_width(29, variant) / SCALE + DIV_PX / SCALE / 2
        journal = [{"seq": 1, "uptimeNanos": int((T0 + 29.5 * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "down", "x": x, "y": 50}}}},
                   {"seq": 2, "uptimeNanos": int((T0 + 49.5 * P) * 1e9), "kind": {"mouse": {"_0": {"phase": "up", "x": x + 40, "y": 50}}}}]
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
    if variant in WRAP_VARIANTS:
        note["panes"]["pa"]["wrap"] = {"cell_px": CW, "pad_px": PAD,
                                       "colors": ["#%02X%02X%02X" % c for c in WRAP_COLORS]}
    if variant in WRAP_KIND_VARIANTS:
        note["panes"]["pa"] = {"kind": "wrap", "label": "p0"}  # the kit's wrap pane: no fill, no wrap facts (defaults)
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
                                                                    "closing-slot", "closing-key")}

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

    def test_a_closing_ground_in_the_s3d_trace_key_counts_as_the_neighbour(self):
        # C.1 (frame-owner-s3b): the S3 sampler skips a host that shows a closing ground, so the closing pane is not in
        # `panes`; S3d records its ground in the sample key `closing` ([pane, x, y, width, height, alpha, z]). The
        # judge reads that key itself (video_judge's trace loader is unchanged) and counts each row as a pane rect.
        r = self.reports["closing-key"]
        self.assertEqual((divider(r, "divider p0|pc")["off_frames"], divider(r, "divider pc|p1")["off_frames"]), (0, 0))
        self.assertNotIn(DIVIDER_RECT, [f["check"] for f in r["findings"]])
        film = jp.Film(Path(self.tmp) / "closing-key")
        self.assertEqual(len(film.closing_rows), len(film.samples))
        self.assertEqual({tuple(row[:1]) for rows in film.closing_rows for row in rows}, {("pc",)})

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
        self.assertFalse([s for s in r["summary"].values() if s["label"] == "strip p0" and s["side"] == "lo"
                          and s["line"].startswith("row@") and s["frames"]])
        # Its top on the col@100 scan column (3e.1: cmux's own layer gives the pane's top edge) is judged, and on time.
        top = side(r, "strip p0", "col@100", "lo")
        self.assertEqual((top["frames"], top["off_frames"]), (60, 0))
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
                                                                    "clock-late-inset", "clock-late2-off-centre")}

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
        # 3e.1: a page is drawn by another window and never votes; it gets its own offset against the main window.
        r = self.reports["lag1"]
        self.assertEqual((r["clock"]["offset"], r["clock"]["votes"], r["clock"]["page"]["votes"]), (0, {"+0": 2}, {"+1": 2}))
        self.assertEqual(r["clock"]["page_window_offset"], 1)
        self.assertIn("page window offset", [f["check"] for f in r["info"]])
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

    def test_each_motion_finding_of_a_film_with_no_clock_says_so(self):
        # 3d.1 (FRAME OWNER): judged on the fixed clock, each finding read from the film's frames says that a lag in
        # motion can be one refresh off; the table marks the film. A trace-only finding does not depend on the clock.
        r = self.reports["clock-late2"]
        film_findings = [f for f in r["findings"] if f["check"] != "clock not found"]
        self.assertTrue(film_findings)
        for f in film_findings:
            self.assertTrue(f["detail"].endswith(jp.CLOCK_NOT_FOUND_NOTE), f)
        self.assertIn("clock not found", jp.markdown([r]).splitlines()[0])
        # clock-late2-off-centre adds a trace divider off its gap: that finding is the trace's, with no note.
        off = self.reports["clock-late2-off-centre"]
        rect = [f for f in off["findings"] if f["check"] == "divider rect not centred on its panes' gap"]
        self.assertEqual(len(rect), 1, off["findings"])
        self.assertNotIn(jp.CLOCK_NOT_FOUND_NOTE, rect[0]["detail"])
        clean = self.reports["clean"]
        self.assertFalse([f for f in clean["findings"] + clean["info"] if jp.CLOCK_NOT_FOUND_NOTE in f["detail"]])
        self.assertIn("clock +0 (fitted)", jp.markdown([clean]).splitlines()[0])
        self.assertIn("clock +1 (fitted)", jp.markdown([self.reports["clock-late"]]).splitlines()[0])

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


class M6ContractTests(unittest.TestCase):
    """3e (FRAME OWNER; cmux-ad m6 1d, the judge part): per film frame and content kind (terminal, page, agent), each
    content edge against its pane edge as cmux's own layer shows it in the same film frame (the tab strip; y edges and
    panes with no strip row: the trace sample on the 3d clock). E2: a lo edge on the current frame's pane edge (a page
    also on the previous frame's: "page late 1", the interim browser contract). E3: a hi edge on the current pane edge,
    or late: on the previous frame's size anchored top-left, clipped. E4: never the shell beyond it (gap). E5: never
    stretched (a ring wider than at rest). The previous frame is the last one whose strip differs (a dropped refresh
    does not widen the allowance). E7: frames where every strip is one sample late are late as a whole."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-m6-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v), all_frames=True)
                       for v in ("strip", "strip-page-late", "strip-tui-b-late", "strip-whole-late", "strip-repeat",
                                 "strip-stretch", "strip-hidden", "gap2", "clean", "strip-lag")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def kind(self, variant, kind):
        return self.reports[variant]["m6"]["kinds"][kind]

    def test_content_on_its_strips_passes(self):
        for kind in ("terminal", "page"):
            row = self.kind("strip", kind)
            self.assertGreater(row["frames"], 50, kind)
            self.assertEqual((row["pass"], row["late"], row["page_late_1"], row["fail"], row["not_judged"]),
                             (row["frames"], 0, 0, 0, 0), kind)
            self.assertGreater(row["sources"]["strip"], 0, kind)
        self.assertEqual(self.reports["strip"]["m6"]["late_as_a_whole"], 0)
        self.assertNotIn("m6 contract", [f["check"] for f in self.reports["strip"]["findings"]])

    def test_a_page_one_frame_late_is_page_late_1(self):
        row = self.kind("strip-page-late", "page")
        self.assertEqual((row["fail"], row["page_late_1"], row["page_late_1_ranges"]), (0, 20, "11-30"))
        self.assertEqual(self.kind("strip-page-late", "terminal")["fail"], 0)

    def test_a_terminal_lo_edge_one_frame_late_fails(self):
        row = self.kind("strip-tui-b-late", "terminal")
        self.assertEqual((row["fail_ranges"], row["fail_by_rule"]["E2"] >= 20), ("11-30", True))
        found = {(f["check"], f["where"]): f["detail"] for f in self.reports["strip-tui-b-late"]["findings"]}
        self.assertIn("20 of", found[("m6 contract", "terminal content")])

    def test_a_frame_late_as_a_whole_is_counted_not_failed(self):
        r = self.reports["strip-whole-late"]
        self.assertEqual((r["m6"]["late_as_a_whole"], r["m6"]["late_as_a_whole_ranges"]), (4, "15-18"))
        for kind in ("terminal", "page"):
            self.assertEqual(self.kind("strip-whole-late", kind)["fail"], 0, kind)
        self.assertIn("late as a whole", [f["check"] for f in r["info"]])
        # strip-lag: B's strip one sample late while A's moves on time: one layer late, not the whole frame.
        self.assertEqual(self.reports["strip-lag"]["m6"]["late_as_a_whole"], 0)

    def test_the_edge_rules(self):
        v = jp.m6_edge_verdict
        # E2: a lo edge on the current pane edge, within 1 device px (inclusive); a page also on the previous frame's.
        self.assertEqual(v("terminal", "lo", 11.0, (10, 100), (8, 100)), ("pass", None))
        self.assertEqual(v("terminal", "lo", 8.0, (10, 100), (8, 100)), ("fail", "E2"))
        self.assertEqual(v("page", "lo", 8.0, (10, 100), (8, 100)), ("page late 1", None))
        self.assertEqual(v("page", "lo", 6.0, (10, 100), (8, 100)), ("fail", "E2"))
        # E3: a hi edge on the current pane edge, or the previous size anchored at the current lo edge, clipped.
        self.assertEqual(v("terminal", "hi", 99.0, (0, 100), (0, 90)), ("pass", None))
        self.assertEqual(v("terminal", "hi", 90.0, (0, 100), (0, 90)), ("late", None))  # a growing pane
        self.assertEqual(v("terminal", "hi", 80.0, (0, 100), (0, 90)), ("fail", "E3"))
        self.assertEqual(v("terminal", "hi", 100.0, (0, 100), (0, 110)), ("pass", None))  # shrinking: clipped
        self.assertEqual(v("terminal", "hi", 110.0, (0, 100), (0, 110)), ("fail", "E3"))  # not clipped: past its pane
        # A pane that moved without a resize: the previous size anchored at the current lo edge is the current hi edge;
        # the content's hi edge at the previous place is neither.
        self.assertEqual(v("terminal", "hi", 100.0, (10, 110), (0, 100)), ("fail", "E3"))

    def test_a_dropped_refresh_does_not_widen_the_allowance(self):
        # Frame 20 repeats frame 19 (the whole screen): its page is late as frame 19's is, against the last frame whose
        # strip differs (18), not against frame 19 (the same strip as its own).
        row = self.kind("strip-repeat", "page")
        self.assertEqual((row["fail"], row["page_late_1_ranges"]), (0, "11-20"))

    def test_stretched_content_fails(self):
        row = self.kind("strip-stretch", "page")
        self.assertEqual((row["fail_ranges"], row["fail_by_rule"]["E5"] > 0), ("20-22", True))

    def test_a_pane_whose_strip_is_not_shown_is_not_judged_never_passed(self):
        # B's tab strip is not drawn in 20-22: B's lo x edges (2 row lines; its hi edge at the frame's edge is never read)
        # have no pane edge there: not judged, never a pass (6 edges). Its top edge has no strip top either, and the
        # shell where the strip was is a gap beyond its content (E4: a fact of the content, judged without a pane edge).
        hidden, shown = self.kind("strip-hidden", "page"), self.kind("strip", "page")
        self.assertEqual(hidden["edges"].get("not judged", 0) - shown["edges"].get("not judged", 0), 6)
        self.assertEqual(hidden["sources"]["strip"], shown["sources"]["strip"] - 6)
        self.assertEqual((hidden["fail_ranges"], hidden["fail_by_rule"]["E4"]), ("20-22", 3))

    def test_a_shell_gap_fails_even_where_no_layer_shows_the_pane_edge(self):
        # gap2 has no strip: no layer of cmux shows A's edges, so E2 and E3 are not judged (never on the trace, 3e.1);
        # the shell beyond A's content in 20-25 is a fact of the content itself: E4 fails.
        row = self.kind("gap2", "terminal")
        self.assertEqual((row["fail_ranges"], row["fail_by_rule"]["E4"] > 0, row["not_judged"]), ("20-25", True, 54))
        self.assertEqual(row["sources"], {})

    def test_a_film_with_no_strip_is_not_judged_never_on_the_trace(self):
        for kind in ("terminal", "page"):
            row = self.kind("clean", kind)
            self.assertEqual((row["pass"], row["fail"], row["not_judged"], row["sources"]), (0, 0, row["frames"], {}), kind)


class MainWindowTests(unittest.TestCase):
    """3e.1 (FRAME OWNER's FIX of 3e): every pane edge of the m6 check comes from cmux's own layer in the same film frame,
    never the trace: x edges from the tab strip on its strip row (only a side read from the pixels), y edges from the
    strip's top on each scan column that crosses it. The 3d clock is fitted from the main window's edges only (strips,
    terminal and agent content); a page is drawn by another window (Chromium's) and never votes: it gets its own offset
    against the main window ("page window offset"), and a page edge on the next frame's pane edge is "page early 1"
    (a failure). E7 counts the strip tops too, on the fixed clock."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-main-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v), all_frames=True)
                       for v in ("strip", "strip-lag", "strip-page-late", "strip-repeat", "lag1", "strip-stretch")}
        MainWindowTests.stretch = cls.reports["strip-stretch"]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_y_edges_come_from_the_strip_tops(self):
        row = self.reports["strip"]["m6"]["kinds"]["page"]
        self.assertGreater(row["sources"]["strip top"], 0)
        self.assertNotIn("trace", row["sources"])

    def test_a_page_never_sets_the_main_windows_clock(self):
        r = self.reports["strip-page-late"]  # B's page one sample late; the strips and A on time
        self.assertEqual((r["clock"]["offset"], r["clock"]["page"]["offset"], r["clock"]["page_window_offset"]), (0, 1, 1))
        info = {f["check"]: f["detail"] for f in r["info"]}
        self.assertIn("+1 refresh", info["page window offset"])

    def test_a_page_ahead_of_its_strip_is_page_early_1(self):
        # strip-lag: B's strip one sample late, B's page on time: the page is one frame ahead of its pane as cmux shows it.
        row = self.reports["strip-lag"]["m6"]["kinds"]["page"]
        self.assertEqual((row["fail_ranges"], row["fail_by_rule"]["page early 1"] > 0), ("11-30", True))
        self.assertEqual(row["fail_frames_by_rule"]["page early 1"], "11-30")

    def test_a_stretched_or_gapped_edge_is_not_also_counted_off(self):
        # strip-stretch: B's page rings twice as wide in 20-22 (E5); its outer edge moves with the stretch, which is the
        # defect: the frames fail E5 and are not counted again under E2.
        row = MainWindowTests.stretch["m6"]["kinds"]["page"]
        self.assertEqual((row["fail_frames_by_rule"]["E5"], row["fail_frames_by_rule"]["E2"]), ("20-22", ""))

    def test_a_dropped_refresh_is_a_frame_late_as_a_whole(self):
        # Frame 20 repeats frame 19: it shows sample 18's geometry where sample 19's is due: one frame late, every layer.
        r = self.reports["strip-repeat"]
        self.assertEqual((r["m6"]["late_as_a_whole"], r["m6"]["late_as_a_whole_ranges"]), (1, "20"))

    def test_late_as_a_whole_is_read_on_the_fixed_clock(self):
        # strip-clock-late: every layer one refresh late. Its own clock (3d) is +1, so against that clock nothing is
        # late; on the fixed clock every moving frame is late as a whole, and E7 counts them.
        r = jp.judge(build(self.tmp, "strip-clock-late", "strip-clock-late"))
        self.assertEqual(r["clock"]["offset"], 1)
        self.assertGreaterEqual(r["m6"]["late_as_a_whole"], 19)

    def test_late_as_a_whole_counts_the_strip_tops(self):
        # A pane that moves down (a row drag moves no strip x edge): its strip tops one sample late are the frame's lag.
        film = jp.Film(build(self.tmp, "e7-tops", "clean"))
        for k, smp in enumerate(film.samples):
            row = list(smp.panes["pb"])
            row[2] = 10.0 + min(max(k - 10, 0), 20)  # y: 10 pt, then 1 pt down per sample from sample 10 to 30
            smp.panes["pb"] = row
        shown = [film.committed(float(t)) for t in film.t]
        series = jp.edge_series(film, "pb", "col", "lo")
        late = [series[shown[f] - 1] if shown[f] and shown[f] >= 1 else series[0] for f in range(film.n)]
        strips = jp.judge_strips(film, shown, list(range(8)), None, False, {}, lambda f, e: None, {}, extents={},
                                 tops={("pb", "col@500"): late}, fixed=shown)
        lagged = sorted(f for f, lags in strips["lags_fixed"].items() if lags and all(v == 1 for v in lags))
        self.assertGreaterEqual(len(lagged), 15)

    def test_page_early_1_reads_the_next_frame_whose_strip_differs(self):
        # Frame 3 repeats frame 2 (a dropped refresh). The page in frame 2 is on frame 4's strip: one frame early.
        real = jp.Film(build(self.tmp, "early-next", "clean"))
        strip = [(100, None), (100, None), (102, None), (102, None), (104, None), (106, None)] + [(108, None)] * 4
        content = [100, 100, 104, 104, 104, 106] + [108] * 4
        n = len(strip)
        film = types.SimpleNamespace(n=n, panes=real.panes, samples=real.samples[:n], scale=real.scale)
        m = [{"status": "found", "view_edge": float(v), "gap": 0.0, "rings": [2.0, 4.0, 6.0]} for v in content]
        key = ("pb", "row@110", "row", "lo")
        out = jp.judge_m6(film, list(range(n)), {key: m}, {key: (0.0, [2.0, 4.0, 6.0])},
                          {"edges": {"pb": strip}, "tops": {}, "lags_fixed": {}})
        self.assertEqual(out["kinds"]["page"]["fail_frames_by_rule"]["page early 1"], "2-3")  # frame 3 shows frame 2

    def test_the_strip_reader_never_returns_the_pane_edge(self):
        S, X = 5, 1  # shell, strip
        codes = np.array([S] * 10 + [X] * 30 + [S] * 10)
        self.assertEqual(jp.strip_extent_read(codes, 25, S, 12, 38, 0, 0), (None, None))  # no shell inside: not read
        self.assertEqual(jp.strip_extent_read(codes, 25, S, 12, 38, 4, 4), (10, 40))
        touching = np.array([S] * 10 + [X] * 40)  # a strip that runs to the line's end
        self.assertEqual(jp.strip_extent_read(touching, 25, S, 12, 48, 4, 4), (10, None))

    def test_the_strip_top_reader(self):
        S, X, R = 5, 1, 4
        codes = np.array([S] * 20 + [X] * 12 + [R] * 2 + [X] * 2 + [S] * 14)
        self.assertEqual(jp.strip_top_on_line(codes, X, 22, 12, 10), 20)
        self.assertIsNone(jp.strip_top_on_line(codes, X, 22, 30, 10))  # under STRIP_SHARE of the height in the strip
        glyph = codes.copy()
        glyph[24:27] = 7  # a glyph of the pill crosses the column inside the strip
        self.assertEqual(jp.strip_top_on_line(glyph, X, 22, 12, 10), 20)

    def test_a_terminal_top_edge_is_ring_1_and_not_read_when_its_rings_are_cut(self):
        m = {"status": "found", "ring_edge": 120.0, "view_edge": 112.0}
        self.assertEqual(jp.content_value(m, "terminal", "col", "lo"), 120.0)
        self.assertEqual(jp.content_value(m, "page", "col", "lo"), 112.0)
        self.assertEqual(jp.content_value(m, "terminal", "row", "lo"), 112.0)
        self.assertIsNone(jp.content_value({"status": "cut", "ring_edge": None, "view_edge": 112.0}, "terminal", "col", "lo"))


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


class RepeatedFrameTests(unittest.TestCase):
    """3e.5 (pixel-perfect, 2026-11-04: px-keys-rk-3t-sw-terminals-on-reduce frames 258, 312, 463 and 522 repeat the frame
    before while the committed layout moved; 3e.1 gave them terminal E2): a frame whose scan lines equal the frame before
    shows what that frame showed, for every reader and judgment, and when the layout moved it is late as a whole. A frame
    that differs from the one before only by a few pixels inside one small rectangle away from every strip row and pane
    edge (a cursor blink) is a repeat too; any change at an edge (a 1 px move) is judged as it is."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-repeat-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v), all_frames=True)
                       for v in ("strip", "strip-repeat", "strip-repeat-clean", "strip-repeat-blink", "strip-nudge")}
        cls.reports.update({v: jp.judge(build_stack(cls.tmp, v, v), all_frames=True) for v in ("stack", "stack-repeat")})

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def kind(self, variant, kind):
        return self.reports[variant]["m6"]["kinds"][kind]

    def test_a_repeated_frame_is_late_as_a_whole_never_a_content_edge(self):
        # stack-repeat: the row press's first frame (11) repeats frame 10. Read against the new layout, the lower pane's
        # strip top is searched near its new place, where the old picture has the upper terminal's ring 3 (black, as the
        # strip): 3e.1 took it for the strip and gave the terminal E2 (px-keys-rk-3t-sw-terminals-on-reduce frames 258,
        # 312, 463, 522). The frame is one frame late as a whole, and no terminal frame fails.
        r = self.reports["stack-repeat"]
        self.assertEqual(self.kind("stack-repeat", "terminal")["fail"], 0)
        self.assertIn(MOVE[0] + 1, jp_frames(r["m6"]["late_as_a_whole_ranges"]))
        self.assertEqual(r["repeats"]["late"], [MOVE[0] + 1])
        # the same press shown on time: nothing late, nothing fails
        self.assertEqual((self.reports["stack"]["m6"]["late_as_a_whole"], self.kind("stack", "terminal")["fail"]), (0, 0))
        self.assertEqual(self.reports["stack"]["repeats"]["late"], [])

    def test_a_clean_repeat_is_late_as_a_whole_with_no_layer_fail(self):
        # Frame 20 repeats frame 19 while the layout moved (sample 18 to 19): one frame late, the whole window.
        r = self.reports["strip-repeat-clean"]
        self.assertIn(20, jp_frames(r["m6"]["late_as_a_whole_ranges"]))
        self.assertNotIn(20, jp_frames(self.kind("strip-repeat-clean", "terminal")["fail_ranges"]))
        self.assertNotIn(20, jp_frames(self.kind("strip-repeat-clean", "page")["fail_ranges"]))

    def test_a_repeated_frame_gives_no_layer_finding(self):
        # Every layer reader reads frame 20 as frame 19's sample: no strip, side or page-window problem comes from it.
        r = self.reports["strip-repeat-clean"]
        frame20 = [e for ff in r["frame_findings"] if ff["f"] == 20 for e in ff["entries"] if e.get("problems")]
        self.assertEqual(frame20, [])
        self.assertEqual(r["repeats"]["late"], [20])

    def test_a_cursor_blink_does_not_stop_a_repeat(self):
        r = self.reports["strip-repeat-blink"]
        self.assertEqual(r["repeats"]["late"], [20])
        self.assertEqual(r["repeats"]["near_px"], {"20": 6})
        self.assertIn(20, jp_frames(r["m6"]["late_as_a_whole_ranges"]))

    def test_a_1_px_move_of_an_edge_is_no_repeat(self):
        r = self.reports["strip-nudge"]
        self.assertEqual(r["repeats"]["late"], [])

    def test_a_film_that_moves_every_frame_has_no_repeat(self):
        self.assertEqual(self.reports["strip"]["repeats"]["late"], [])
        self.assertEqual(self.reports["strip"]["m6"]["late_as_a_whole"], 0)

    def test_the_dropped_refresh_film_keeps_its_answers(self):
        # strip-repeat (3e.1's own dropped refresh): frame 20 late as a whole, as before.
        r = self.reports["strip-repeat"]
        self.assertEqual(r["repeats"]["late"], [20])
        self.assertEqual((r["m6"]["late_as_a_whole"], r["m6"]["late_as_a_whole_ranges"]), (1, "20"))


class TouchingGroundTests(unittest.TestCase):
    """3e.3 (pixel-perfect, 2026-11-04): a terminal's ground strip that runs on into another ground of the same color with
    no shell between, past the terminal's own pane edge (the next pane's cell or a closing pane's ground starts there,
    in the shown sample), is not judged there: the edge between two grounds of one color is not in the pixels (never a
    pass, and never the trace's edge taken as the content's). Where it does not touch, the side is judged as before.
    Facts: ab-s3d-pr3-2f13aa4 px-close-pane-3t-s1r-s1 (p0's edge read at the closing ground's far end: E3 20, E4 33)
    and ab-s3d-base-154073f px-close-column-c3-s1r-s1 (p0's rest offset took p1's padding: E3 at rest after the close,
    60-63 frames)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-touch-")
        cls.reports = {v: jp.judge(build_touch(cls.tmp, v, v), all_frames=True)
                       for v in ("touch-close", "ground-touch", "page-late")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def terminal(self, variant):
        return self.reports[variant]["m6"]["kinds"]["terminal"]

    def touching(self, variant, label, which, frames):
        """The frames of FRAMES where LABEL's WHICH side on row@110 is not judged because its ground touches another's."""
        got = entries(self.reports[variant], label, "row@110", which)
        return {f for f in frames if got.get(f, {}).get("status") == "not found" and got[f].get("why") == jp.TOUCH_NOT_JUDGED}

    def test_a_neighbours_touching_ground_is_not_the_terminals(self):
        # touch-close: at rest A's right ground meets B's left ground; after B's close A touches C. 3e.1 took B's padding
        # into A's rest offset: A's right edge read off in every frame from the close on.
        t = self.terminal("touch-close")
        self.assertEqual(t["fail"], 0, t)
        hi = side(self.reports["touch-close"], "p0", "row@110", "hi")
        self.assertEqual(hi["off_ranges"], "", hi)
        # While A's ground meets B's (at rest and while B closes), A's right side is not judged, for that reason.
        meets = set(range(0, MOVE[0])) | set(range(MOVE[0] + 2, MOVE[1]))
        self.assertEqual(self.touching("touch-close", "p0", "hi", meets), meets)
        # m6 says so: those edges are counted as not judged, with their frames (never a pass, never silent).
        self.assertLessEqual(meets, jp_frames(t["touch_not_judged_ranges"]), t)
        self.assertGreaterEqual(t["touch_not_judged"], len(meets), t)
        # Once B is gone, A's ground ends at C's ring (no ground of A's color beyond): judged, on A's pane edge.
        got = entries(self.reports["touch-close"], "p0", "row@110", "hi")
        after = range(MOVE[1] + 2, N)
        self.assertEqual({f for f in after if got.get(f, {}).get("status") == "found"}, set(after))
        self.assertLess(max(abs(got[f]["edge_dev"]) for f in after), TOL_TEST_PX)

    def test_a_terminal_touching_a_closing_ground_is_not_judged_there(self):
        # ground-touch: A grows into P's closing ground with no band between; A's fill runs to its view's last cell and
        # its ground on into P's. 3e.1 read A's right edge at the closing ground's far end (up to + P's width).
        hi = side(self.reports["ground-touch"], "p0", "row@110", "hi")
        self.assertEqual(hi["off_ranges"], "", hi)
        self.assertLess(abs(hi["max_edge_dev_px"]), TOL_TEST_PX, hi)
        closing = set(range(MOVE[0] + 2, MOVE[1]))
        self.assertEqual(self.touching("ground-touch", "p0", "hi", closing), closing)
        # At rest (P behind its own shell band) and after P's close (A's band before C), A's right side is judged.
        got = entries(self.reports["ground-touch"], "p0", "row@110", "hi")
        judged = set(range(0, MOVE[0])) | set(range(MOVE[1] + 2, N))
        self.assertEqual({f for f in judged if got.get(f, {}).get("status") == "found"}, judged)

    def test_a_shrinking_edge_whose_ground_runs_into_a_neighbours_is_not_judged(self):
        # touch-close: B's left edge moves right while B closes, and its ground runs on into A's: a lag of B's content would
        # show only as more of the same color past B's edge, so that edge is not judged there (never a pass).
        lo = side(self.reports["touch-close"], "p1", "row@110", "lo")
        self.assertGreaterEqual(len(jp_frames(lo["not_found_ranges"]) & set(range(MOVE[0] + 2, MOVE[1]))), 15, lo)
        # While B still shows its fill on the line (to frame 15; then its rings fill its narrow view), for that reason.
        shows_fill = set(range(MOVE[0] + 2, MOVE[0] + 6))
        self.assertEqual(self.touching("touch-close", "p1", "lo", shows_fill), shows_fill)

    def test_a_terminals_ground_past_its_edge_into_a_page_is_its_own(self):
        # page-late: a page never shows the ground color (rings, then its fill), so A's ground past A's pane edge into C's
        # rect is A's: frames 15-18 are judged, one frame late (lag 1), never "not judged" (cmux22 S7 window resize:
        # px-window-resize-4-sw-liveresize-motion-off-reduce frames 155-174, p0's late ground into p1's page rect).
        # (Frame 15 repeats frame 14: 3e.5 reads it with frame 14's sample, late as a whole.)
        got = entries(self.reports["page-late"], "p0", "row@110", "hi")
        late = range(15, 19)
        self.assertEqual({f: got[f]["status"] for f in late}, {f: "found" for f in late})
        self.assertEqual({f: got[f].get("lag") for f in range(16, 19)}, {f: 1 for f in range(16, 19)})
        self.assertEqual(self.touching("page-late", "p0", "hi", range(N)), set())
        self.assertEqual(self.terminal("page-late").get("touch_not_judged", 0), 0)


class WindowEdgeTests(unittest.TestCase):
    """3e.2 (pixel-perfect, 2026-11-04: ab-btl-sw-dbf5c8b px-keys-held-2-sw-keyresizetopleft-on-s1, 38 frames of page E5,
    rings read [1.0, 0.0, 17.5-23.5] against [2, 4, 6]): the scan runs past the window's right edge (2872 px of scan, a
    2722 px window), and the walk read the desktop's black beyond the window as the page's ring 3. Pixels past the window's
    edge are not the app's: no reader takes them. A side on screen whose rings run past the window's edge shows content
    past its pane edge (the pane ends at or inside the window): it fails (m6 E3 on a hi side; m14 class edge), with a
    lower bound of its offset (the rest widths of the rings it does not show), never E5 (review of 2796367203bb). A pane
    that itself runs past the window has that edge off screen: not judged. Rings that end on the window's edge pass."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-window-edge-")
        cls.report = jp.judge(build_window_edge(cls.tmp, "page-clipped", "page-clipped"), all_frames=True)
        cls.past = jp.judge(build_window_edge(cls.tmp, "pane-past", "pane-past"), all_frames=True)
        cls.far = jp.judge(build_window_edge(cls.tmp, "page-far", "page-far"), all_frames=True)
        cls.grid = jp.judge(build_window_edge(cls.tmp, "tui-grid", "tui-grid"), all_frames=True)
        cls.wider = jp.judge(build_window_edge(cls.tmp, "tui-view-wider", "tui-view-wider"), all_frames=True)
        cls.lo_cut = jp.judge(build_window_edge(cls.tmp, "tui-lo-cut", "tui-lo-cut"), all_frames=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_the_desktop_past_the_window_is_no_ring(self):
        page = self.report["m6"]["kinds"]["page"]
        self.assertEqual(page["fail_by_rule"]["E5"], 0, page)
        self.assertEqual(self.report["m14"]["kinds"]["page"]["scaled"], 0)

    def test_content_past_its_pane_edge_at_the_window_edge_fails(self):
        # C's page keeps 6 px more than its pane, which ends on the window's edge: rings 2 and 1 (4 + 2 px) are past it
        got = entries(self.report, "p1", "row@110", "hi")
        moving = range(MOVE[0] + 2, MOVE[1])
        self.assertEqual({f: got.get(f, {}).get("status") for f in moving}, {f: "clipped" for f in moving})
        self.assertEqual({got[f].get("why") for f in moving}, {jp.WINDOW_CLIPPED})
        page = self.report["m6"]["kinds"]["page"]
        self.assertLessEqual(set(moving), jp_frames(page["fail_frames_by_rule"]["E3"]), page)
        m14 = self.report["m14"]["kinds"]["page"]
        self.assertLessEqual(set(moving), jp_frames(m14["edge_ranges"]), m14)
        self.assertEqual(m14["worst_px"], 6.0)  # a lower bound: ring 2 (4 px) and ring 1 (2 px) are not shown
        self.assertIn("clipped", m14["worst_edge"])

    def test_a_page_whose_fill_runs_into_the_window_edge_fails(self):
        # every ring is past the window's edge: no walk starts there, yet the content runs past its pane edge
        got = entries(self.far, "p1", "row@110", "hi")
        moving = range(MOVE[0] + 2, MOVE[1])
        self.assertEqual({got[f]["status"] for f in moving}, {"clipped"})
        m14 = self.far["m14"]["kinds"]["page"]
        self.assertLessEqual(set(moving), jp_frames(m14["edge_ranges"]), m14)
        self.assertEqual(m14["worst_px"], 12.0)  # a lower bound: rings 3, 2 and 1 (6 + 4 + 2 px) are not shown

    def test_a_growing_terminal_whose_grid_the_window_cuts_is_not_judged_there(self):
        # A terminal draws only inside its view: while its pane grows, the press's final grid is wider than the view and
        # the view (on the window's edge) cuts it: one program grid per press, never content past its pane edge.
        got = entries(self.grid, "p0", "row@180", "hi")  # row@110 crosses the terminal's ring rows: not judged there
        moving = range(MOVE[0] + 2, MOVE[1])
        self.assertEqual({got[f]["status"] for f in moving}, {"clipped"})
        t = self.grid["m6"]["kinds"]["terminal"]
        self.assertEqual((t["fail"], t["fail_by_rule"]["E5"]), (0, 0), t)
        self.assertGreaterEqual(t["clipped_grid_not_judged"], len(moving), t)
        self.assertEqual(self.grid["m14"]["kinds"]["terminal"]["fail"], 0)
        self.assertEqual({got[f]["status"] for f in range(0, MOVE[0])}, {"found"})

    def test_a_terminal_view_wider_than_its_pane_at_the_window_edge_fails(self):
        # the same picture while the pane shrinks: the view kept its old, wider size; its rings run past the window
        got = entries(self.wider, "p0", "row@180", "hi")
        moving = range(MOVE[0] + 2, MOVE[1])
        self.assertEqual({got[f]["status"] for f in moving}, {"clipped"})
        t = self.wider["m6"]["kinds"]["terminal"]
        self.assertLessEqual(set(moving), jp_frames(t["fail_frames_by_rule"]["E3"]), t)
        self.assertEqual(t["clipped_grid_not_judged"], 0, t)
        self.assertLessEqual(set(moving), jp_frames(self.wider["m14"]["kinds"]["terminal"]["edge_ranges"]))

    def test_a_terminal_grid_cut_on_its_lo_side_fails_even_while_its_pane_grows(self):
        # a grid is anchored top-left: one program grid per press can only be cut at the view's far (hi) edge; a cut at
        # the lo edge is content pushed past the pane's near edge, never allowed (review of 9901b18a1b7)
        got = entries(self.lo_cut, "p0", "row@180", "lo")
        moving = range(MOVE[0] + 2, MOVE[1])
        self.assertEqual({got[f]["status"] for f in moving}, {"clipped"})
        t = self.lo_cut["m6"]["kinds"]["terminal"]
        self.assertLessEqual(set(moving), jp_frames(t["fail_frames_by_rule"]["E2"]), t)
        self.assertLessEqual(set(moving), jp_frames(self.lo_cut["m14"]["kinds"]["terminal"]["edge_ranges"]))

    def test_a_pane_past_the_window_is_not_judged_there(self):
        page = self.past["m6"]["kinds"]["page"]
        self.assertEqual((page["fail"], page["fail_by_rule"]["E5"]), (0, 0), page)
        self.assertEqual(entries(self.past, "p1", "row@110", "hi"), {})

    def test_rings_that_end_on_the_window_edge_are_judged(self):
        got = entries(self.report, "p1", "row@110", "hi")
        at_rest = list(range(0, MOVE[0])) + list(range(MOVE[1] + 2, N))
        self.assertEqual({f: got[f]["status"] for f in at_rest}, {f: "found" for f in at_rest})
        self.assertEqual({tuple(got[f]["rings"]) for f in at_rest}, {(2.0, 4.0, 6.0)})
        self.assertEqual(side(self.report, "p1", "row@110", "hi")["off_ranges"], "")


class RestCutRingTests(unittest.TestCase):
    """3e.6 (pixel-perfect, 2026-11-05: the Command films ab-cmdb-b5e96a1 and ab-cmdh-307045f px-cmd-col-edge-3t-s1 and
    -reduce, every terminal "scaled" frame: p1's hi side with rest rings [0, 14, 16] or [0, 16, 16], ring 1 shown 1-3 px
    or ring 2 at 16 px in motion): the pane edge cut the side's outer rings at rest, so their rest widths are not the
    rings' widths. E5 compares each ring with its rest width on whichever of the pane's two sides of that line shows it
    wider (a ring the pane edge cuts on one side is whole on the other); a ring with no rest width on either side is
    not compared. A real stretch still fails."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-rest-cut-")
        cls.reports = {v: jp.judge(build_rest_cut(cls.tmp, v, v), all_frames=True) for v in ("rest-cut", "rest-cut-stretch")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_the_rest_rings_are_cut_by_the_pane_edge(self):
        hi = side(self.reports["rest-cut"], "p0", "row@110", "hi")
        self.assertEqual(hi["rest"]["rings"], [0.0, 14.0, 16.0], hi)

    def test_a_ring_the_pane_edge_cut_at_rest_is_not_stretched_when_it_shows_whole(self):
        t = self.reports["rest-cut"]["m6"]["kinds"]["terminal"]
        self.assertEqual(t["fail_by_rule"]["E5"], 0, t)
        self.assertEqual(self.reports["rest-cut"]["m14"]["kinds"]["terminal"]["scaled"], 0)

    def test_a_real_stretch_still_fails(self):
        t = self.reports["rest-cut-stretch"]["m6"]["kinds"]["terminal"]
        self.assertEqual(jp_frames(t["fail_frames_by_rule"]["E5"]), {20, 21, 22}, t)


class PressedDividerGlowTests(unittest.TestCase):
    """3e.7 (pixel-perfect, 2026-11-05: ab-s2bmin-d8ac2f4 px-keys-then-clamp-2x-sw-sharededges-on-s0125, strip row 28,
    frames 224-396: p2's tab strip read 3 px left of its pane edge, m14 "edge" in 162-173 frames per clamp film, both
    arms): while a divider is pressed, its glow band (CmuxNextDesign DividerGlowBand: a 2 pt core and a 3 pt halo each side
    of the line) covers the strip ends next to it: the halo (#ED65F5) over the gap is no strip class, so the strip reader
    took it for the strip. During a press, within 4 pt of the pressed divider's line, a pixel with red and blue on (the glow
    over the shell) is the shell and any other is the strip (the glow over the strip): the strip edge is read where it is.
    A strip that is truly off under the glow still fails."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-glow-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v), all_frames=True) for v in ("strip-glow", "strip-glow-off3")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_a_strip_edge_under_the_pressed_dividers_glow_reads_on_its_pane_edge(self):
        r = self.reports["strip-glow"]
        page = r["m6"]["kinds"]["page"]
        self.assertEqual(page["fail"], 0, page)
        self.assertEqual(r["m14"]["kinds"]["page"]["fail"], 0)
        strip = side(r, "strip p1", "row@12", "lo")
        self.assertEqual(strip["off_ranges"], "", strip)

    def test_a_strip_truly_off_under_the_glow_still_fails(self):
        r = self.reports["strip-glow-off3"]
        strip = side(r, "strip p1", "row@12", "lo")
        self.assertEqual(jp_frames(strip["off_ranges"]), set(range(30, 50)), strip)
        # m6 passes a page whose edge matches the frame before as "page late 1"; m14 fails it (cmux-ad m14)
        page = r["m14"]["kinds"]["page"]
        self.assertEqual(jp_frames(page["fail_ranges"]), set(range(30, 50)), page)


class ViewWiderThanPaneTests(unittest.TestCase):
    """3e.8 (pixel-perfect, 2026-11-05, for frame-owner-s4's window frame sync): inside the window, a terminal whose fill
    runs straight into the shell at its pane edge, with no ring and no ground, shows a grid its view cuts. In a pane that
    shrinks or rests on that axis it is a view wider than its pane (the S4 keep path: the old, wider frame kept after a
    Reduce Motion shrink): a fail (m6 E3; m14 edge, its offset a lower bound: the rest widths of the rings it does not
    show). In a pane that grows it is the press's final grid (one program grid per press): not judged, never a pass."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-view-kept-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v), all_frames=True) for v in ("strip-view-kept", "strip-grid-grows")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_a_kept_wider_view_in_a_shrinking_pane_fails(self):
        r = self.reports["strip-view-kept"]
        kept = MOVE[0] + 1  # the frame that shows sample 10 (the jump)
        got = entries(r, "p0", "row@180", "hi")  # row@110 is a ring row of A below its strip
        self.assertEqual(got[kept]["status"], "clipped", got.get(kept))
        t = r["m6"]["kinds"]["terminal"]
        self.assertIn(kept, jp_frames(t["fail_frames_by_rule"]["E3"]), t)
        m14 = r["m14"]["kinds"]["terminal"]
        self.assertIn(kept, jp_frames(m14["edge_ranges"]), m14)
        self.assertGreaterEqual(m14["worst_px"], 48.0)  # at least rings 3, 2 and 1 (16 px each) past the pane edge
        self.assertNotIn(kept + 1, jp_frames(t["fail_ranges"]))  # the next frame shows the new grid: it passes

    def test_the_presss_grid_cut_by_a_growing_view_is_not_judged(self):
        r = self.reports["strip-grid-grows"]
        cut = range(MOVE[0] + 1, MOVE[0] + 6)  # the view cuts the final grid inside its fill there
        got = entries(r, "p0", "row@180", "hi")  # row@110 is a ring row of A below its strip
        self.assertEqual({got[f]["status"] for f in cut}, {"clipped"})
        t = r["m6"]["kinds"]["terminal"]
        self.assertEqual(jp_frames(t["fail_ranges"]) & set(cut), set(), t)
        self.assertGreaterEqual(t["clipped_grid_not_judged"], len(cut), t)


class HeldSurfaceTests(unittest.TestCase):
    """m18 held and stale (Lead 2026-11-05, STATUS 13889; pixel-perfect, STATUS 13764): the pixels cannot see a HELD
    terminal surface when the host paints the terminal's ground beside it (a surface kept at its old size looks like a live
    one padded by its own ground: the drag hold terminalDrag.holdSurface and the S4-OFF key hold pass m14 in pixels while
    the terminal is frozen). The trace's `terminal` rows tell: per sample, the surface layer's rect and the shown
    IOSurface's size. A terminal frame (the film's clock) is `held` when the committed surface's width or height differs
    from its pane's area (its rect less the tab strip's header) by more than 0.5 pt, `stale` when the shown IOSurface
    differs from the surface's size x scale by more than 1 px; both fail m18 (m6 and m14 do not change). A surface at its
    pane's size with an old grid inside it is not held (only the surface rect and the shown IOSurface count: STATUS 13624).
    An owned row (the frame owner) whose present request waits (host frame pending or ready) is sampled before the window's
    present pass of the same turn: the bounds that turn commits are the next row's when the film's rows say so (the phase
    the moving samples fit: single-3k ON x1 50 held ticks in a same-row reading, 0 committed)."""

    VARIANTS = ("strip-held", "strip-stale", "strip-surface", "strip-surface-owned", "strip-held-owned")

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-held-")
        cls.bases = {v: build(cls.tmp, v, v) for v in cls.VARIANTS}
        cls.reports = {v: jp.judge(b, all_frames=True) for v, b in cls.bases.items()}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def row(self, variant, contract="m18"):
        return self.reports[variant][contract]["kinds"]["terminal"]

    def test_a_held_surface_fails_while_its_pixels_pass(self):
        held = set(range(MOVE[0] + 1, MOVE[0] + 15))  # the frames that show samples 10-23
        row = self.row("strip-held")
        self.assertEqual(jp_frames(row["held_ranges"]), held, row)
        self.assertLessEqual(held, jp_frames(row["fail_ranges"]), row)
        self.assertEqual(row["held_worst_pt"], 14.0)  # 28 device px at scale 2: the growth it missed
        self.assertEqual(self.reports["strip-held"]["m6"]["kinds"]["terminal"]["fail"], 0)  # the pixels pass (padded)
        self.assertEqual(self.row("strip-held", "m14")["fail"], 0)  # m14 stays the pixel contract of the m14 tables

    def test_a_stale_iosurface_fails(self):
        stale = set(range(MOVE[0] + 5, MOVE[0] + 9))  # the frames that show samples 14-17
        row = self.row("strip-stale")
        self.assertEqual(jp_frames(row["stale_ranges"]), stale, row)
        self.assertLessEqual(stale, jp_frames(row["fail_ranges"]), row)
        self.assertEqual((row["held"], row["stale_worst_px"]), (0, 16.0))

    def test_stale_is_not_judged_for_a_capacity_build(self):
        # ghostty-next #81 plan B: the IOSurface is the gesture's capacity and the layer shows a sub-rect
        row = jp.judge(self.bases["strip-stale"], stale=False)["m18"]["kinds"]["terminal"]
        self.assertEqual((row["stale"], row["fail"], row["stale_judged"]), (0, 0, False), row)

    def test_a_surface_on_its_pane_area_is_neither_held_nor_stale(self):
        row = self.row("strip-surface")
        self.assertEqual((row["held"], row["stale"], row["fail"]), (0, 0, 0), row)
        self.assertGreater(row["surface_frames"], 50)

    def test_an_owned_surface_sampled_before_its_present_pass_is_not_held(self):
        # each moving row shows the pane of the sample before (its request waits; the pass after the sampler commits the
        # new bounds): the next row holds the bounds that turn committed
        row = self.row("strip-surface-owned")
        self.assertEqual((row["held"], row["fail"], row["surface_phase"]), (0, 0, 1), row)

    def test_an_owned_surface_that_keeps_its_old_size_is_held(self):
        held = set(range(MOVE[0] + 1, MOVE[0] + 6))  # the frames that show samples 10-14: their next rows keep A_REST
        row = self.row("strip-held-owned")
        self.assertEqual((jp_frames(row["held_ranges"]), row["surface_phase"]), (held, 1), row)
        self.assertEqual(row["held_worst_pt"], 5.0)


class WrapTests(unittest.TestCase):
    """m18 text wrap (pixel-perfect, 2026-11-05: a primary-screen fixture, lines of solid one-color blocks, each line
    about 3 pane widths): on each scan row through a block, the colored run ends within one cell of the view's last whole
    cell, the columns from the trace (the committed surface's width less the padding, over the cell width; the note's
    `wrap`: cell_px, pad_px, colors). A run past the last whole cell is a crop (not re-wrapped); every row of a frame short
    of it at one column is a narrower wrap; one short row is a line's last row (information)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-wrap-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v), all_frames=True) for v in WRAP_VARIANTS}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def row(self, variant):
        return self.reports[variant]["m18"]["kinds"]["terminal"]

    def test_text_re_wrapped_every_frame_passes(self):
        row = self.row("strip-wrap")
        self.assertEqual((row["wrap"], row["fail"]), (0, 0), row)
        self.assertGreater(row["wrap_rows"], 100)

    def test_a_wrap_wider_than_the_frame_fails(self):
        want = {s + 1 for s in range(MOVE[0], MOVE[1])
                if min(wrap_cols(A_REST) * CW, int(round(a_width(s, "strip-wrap-crop"))) - PAD) >
                wrap_cols(a_width(s, "strip-wrap-crop")) * CW + 1}
        self.assertEqual(jp_frames(self.row("strip-wrap-crop")["wrap_ranges"]), want)

    def test_the_kits_wrap_pane_is_read(self):
        # pixel-perfect's kit (475fced167b) writes the pane as kind "wrap" with no fill and no rings: the judge reads it as a
        # terminal for the trace check and the wrap only, with the fixture's facts (cell 16, padding 8, #8000FF / #FF8000,
        # 2 full rows and a 5-cell last row per line)
        tmp = tempfile.mkdtemp(prefix="judge-pixel-wrap-kind-")
        try:
            ok = jp.judge(build(tmp, "strip-wrap-kind", "strip-wrap-kind"), all_frames=True)["m18"]["kinds"]["terminal"]
            self.assertEqual((ok["wrap"], ok["held"]), (0, 0), ok)
            self.assertGreater(ok["wrap_rows"], 100)
            crop = jp.judge(build(tmp, "strip-wrap-kind-crop", "strip-wrap-kind-crop"), all_frames=True)["m18"]["kinds"]["terminal"]
            pad = WRAP_KIND_PAD
            want = {s + 1 for s in range(MOVE[0], MOVE[1])
                    if min(wrap_cols(A_REST, pad) * CW, int(round(a_width(s, "strip-wrap-kind-crop"))) - pad) >
                    wrap_cols(a_width(s, "strip-wrap-kind-crop"), pad) * CW + 1}
            self.assertTrue(want)
            self.assertEqual(jp_frames(crop["wrap_ranges"]), want)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_a_wrap_narrower_than_the_frame_fails(self):
        # every full row ends at the rest wrap's last cell, short of the frame's last whole cell
        want = {s + 1 for s in range(MOVE[0], MOVE[1]) if wrap_cols(a_width(s, "strip-wrap-narrow")) != wrap_cols(A_REST)}
        self.assertTrue(want)
        self.assertEqual(jp_frames(self.row("strip-wrap-narrow")["wrap_ranges"]), want)


class M20ContractTests(unittest.TestCase):
    """m20 (Lead 2026-11-05, STATUS 14130; cmux-ad m20 items 2 and 8; pixel-perfect's review FIX at 19a5f7a0efc): pages
    lag as best they can and the judge REPORTS the lag (never a fail). The hard gates for a page, in every frame: no page
    pixel outside its pane (protrude: seen over the divider or in the neighbour); no non-page color between the page content
    and its pane edge (foreign: a page smaller than its pane shows its own background in the gap, m20 item 1); a page whose
    layout width never changes during a motion of its pane (> 2 px) fails (frozen). A page wider than its pane, clipped at
    its pane edge (by the host's clip, or by the window's edge), has no pixel outside its pane: it is lag. Terminals: m18,
    with the m19 allowance (STATUS 14113): a terminal's last frame may show for at most 2 refreshes, clipped, never
    stretched. Smooth: debug.frames' missed refreshes fail the film; no read: smoothness not judged, the film cannot pass."""

    VARIANTS = ("strip", "strip-page-late", "strip-page-clip", "strip-page-clip-wide", "strip-page-lag2", "strip-page-lag2-bg",
                "strip-page-lag3", "strip-page-frozen", "strip-grid-grows", "strip-tui-a-late", "strip-held", "strip-wrap-crop")

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-m20-")
        cls.bases = {v: build(cls.tmp, v, v) for v in cls.VARIANTS}
        cls.reports = {v: jp.judge(b, all_frames=True) for v, b in cls.bases.items()}
        cls.window = jp.judge(build_window_edge(cls.tmp, "page-clipped", "page-clipped"), all_frames=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def row(self, variant, kind, contract="m20"):
        return self.reports[variant][contract]["kinds"][kind]

    def test_content_on_its_strips_passes(self):
        for kind in ("terminal", "page"):
            row = self.row("strip", kind)
            self.assertGreater(row["judged"], 50, kind)
            self.assertEqual((row["fail"], row["worst_px"]), (0, 0.0), (kind, row))

    def test_a_page_past_its_pane_edge_fails(self):
        # B's page one sample late while B shrinks: its rings 2 px over the divider (no clip)
        row = self.row("strip-page-late", "page")
        self.assertEqual((row["protrude_ranges"], row["fail_ranges"]), ("11-30", "11-30"), row)

    def test_a_page_wider_than_its_pane_clipped_at_its_edge_is_lag(self):
        # the same page with the host's clip at its pane edge: ring 1 is not drawn, no pixel is outside the pane
        row = self.row("strip-page-clip", "page")
        self.assertEqual((row["fail"], row["protrude"]), (0, 0), row)
        self.assertLessEqual(set(range(11, 31)), jp_frames(row["lag_ranges"]), row)
        # 16 px wider (8 samples late): its rings and 4 px of its fill are not drawn; its fill runs to the clip
        wide = self.row("strip-page-clip-wide", "page")
        self.assertEqual((wide["fail"], wide["protrude"]), (0, 0), wide)
        self.assertLessEqual(set(range(11, 38)), jp_frames(wide["lag_ranges"]), wide)
        # and at the window's edge (3e.2's page-clipped: 6 px wider than its pane, which ends on the window's edge)
        page = self.window["m20"]["kinds"]["page"]
        self.assertGreater(self.window["m18"]["kinds"]["page"]["protrude"], 0)
        self.assertEqual(page["fail"], 0, page)
        self.assertLessEqual(set(range(MOVE[0] + 2, MOVE[1])), jp_frames(page["lag_ranges"]), page)

    def test_a_page_colored_gap_passes_and_a_shell_gap_fails(self):
        bg = self.row("strip-page-lag2-bg", "page")
        self.assertEqual(bg["fail"], 0, bg)
        self.assertGreaterEqual(bg["lag"], 15)
        shell = self.row("strip-page-lag2", "page")
        self.assertEqual((shell["foreign_ranges"], shell["fail_ranges"]), ("11-31", "11-31"), shell)
        self.assertEqual(self.row("strip-page-lag3", "page")["foreign_ranges"], "11-32")

    def test_a_frozen_page_fails(self):
        row = self.row("strip-page-frozen", "page")
        self.assertEqual((row["frozen_ranges"], row["fail_ranges"], row["foreign"]), ("11-30", "11-30", 0), row)

    def test_page_lag_is_measured_and_reported(self):
        # refreshes from the pane at size S to the page at size S (the page's ring-to-ring width on a row, against its
        # pane's width in the samples before)
        bg = self.row("strip-page-lag2-bg", "page")
        self.assertEqual((bg["lag_max"], bg["lag_p95"]), (2, 2), bg)
        self.assertEqual(self.row("strip", "page")["lag_max"], 0)

    def test_a_terminals_last_frame_for_at_most_2_refreshes_passes(self):
        # m19: A's view one sample late in 11-30 (m14 allowed, m18 fails it): within the allowance
        self.assertGreater(self.row("strip-tui-a-late", "terminal", "m18")["fail"], 0)
        late = self.row("strip-tui-a-late", "terminal")
        self.assertEqual(late["fail"], 0, late)
        # a surface held at its old size for 14 samples is older than 2 refreshes: it fails from its third frame
        held = self.row("strip-held", "terminal")
        self.assertEqual(jp_frames(held["held_ranges"]), set(range(MOVE[0] + 3, MOVE[0] + 15)), held)

    def test_a_grid_its_growing_view_cuts_fails(self):
        self.assertGreater(self.row("strip-grid-grows", "terminal")["edge"], 0)

    def test_text_wrapped_for_the_last_2_refreshes_passes(self):
        # strip-wrap-crop keeps the rest wrap while A shrinks: frames 11 and 12 show the wrap of samples 9 and 10's
        # surfaces (1 and 2 refreshes old); the frames after are older. In frames 20 and 28 the view's edge falls on a
        # column boundary of the wrap of 2 samples before (17 and 16 columns): the pixels are that frame's, and the rest
        # wrap's last column is cut off (the pixels cannot tell them apart: lag)
        m18 = jp_frames(self.row("strip-wrap-crop", "terminal", "m18")["wrap_ranges"])
        self.assertLessEqual({11, 12, 20, 28}, m18)
        self.assertEqual(jp_frames(self.row("strip-wrap-crop", "terminal")["wrap_ranges"]), m18 - {11, 12, 20, 28})

    def test_the_verdict_cli_gives_m20_by_default_and_judges_smoothness(self):
        import contextlib
        import io
        import judge_m14
        base = str(self.bases["strip"])
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            self.assertEqual(judge_m14.main([base]), 2)  # no debug.frames read: smoothness not judged, never a pass
        self.assertIn("smooth not judged", buf.getvalue())
        for missed, code in ((0, 0), (3, 1)):
            Path(f"{base}.frames.json").write_text(json.dumps({"reply": {"frames": 60, "missed": missed, "refresh_ms": 8.333,
                                                                        "intervals_ms": [8.333] * 60}}))
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(judge_m14.main([base]), code, missed)
            finally:
                Path(f"{base}.frames.json").unlink()
        out = Path(self.tmp) / "m20.json"
        with contextlib.redirect_stdout(io.StringIO()):
            judge_m14.main([str(self.bases["strip-page-lag2"]), "--json", str(out)])
        film = json.loads(out.read_text())["films"][0]
        self.assertEqual((film["contract"], film["status"]), ("m20", "fail"))


class M18ContractTests(unittest.TestCase):
    """m18 (Lead 2026-11-05, STATUS 13889): replaces m14's terminal and page rules where they differ.
    Pages: never past their pane edge in any frame (`protrude`); a page may show its last frame for at most 2 refreshes
    (an edge on the pane edge of one of the 2 frames before; on the hi side also that size anchored at the current lo
    edge and clipped at the current hi edge), and may be smaller than its pane then; a longer lag fails (`lag`).
    Terminals: the text is re-wrapped at every frame's pane size, drawn at the pane's pixel size: m14's pixel classes, the
    trace's held and stale, and a grid its view cuts fails while its pane grows too ("grid once per gesture" is gone)."""

    VARIANTS = ("strip", "strip-page-late", "strip-page-lag2", "strip-page-lag3", "strip-grid-grows")

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-m18-")
        cls.bases = {v: build(cls.tmp, v, v) for v in cls.VARIANTS}
        cls.reports = {v: jp.judge(b, all_frames=True) for v, b in cls.bases.items()}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def row(self, variant, kind, contract="m18"):
        return self.reports[variant][contract]["kinds"][kind]

    def test_content_on_its_strips_passes(self):
        for kind in ("terminal", "page"):
            row = self.row("strip", kind)
            self.assertGreater(row["judged"], 50, kind)
            self.assertEqual((row["fail"], row["worst_px"]), (0, 0.0), (kind, row))

    def test_a_page_past_its_pane_edge_fails_in_every_frame(self):
        # B's page one sample late while B shrinks: its left edge 2 px left of its pane edge (m6 "page late 1")
        m14, m18 = self.row("strip-page-late", "page", "m14"), self.row("strip-page-late", "page")
        self.assertEqual((m18["protrude"], m18["protrude_ranges"], m18["fail_ranges"]),
                         (m14["page_late"], m14["page_late_ranges"], m14["page_late_ranges"]))

    def test_a_page_two_refreshes_late_inside_its_pane_passes(self):
        m18 = self.row("strip-page-lag2", "page")
        self.assertEqual(m18["fail"], 0, m18)
        self.assertGreaterEqual(m18["lag_1_2"], 15)
        self.assertGreater(self.row("strip-page-lag2", "page", "m14")["fail"], 0)  # m14 fails it (E2)

    def test_a_page_three_refreshes_late_fails(self):
        m18 = self.row("strip-page-lag3", "page")
        self.assertEqual((m18["lag_ranges"], m18["fail_ranges"]), ("13-32", "13-32"), m18)

    def test_a_grid_its_growing_view_cuts_fails(self):
        cut = set(range(MOVE[0] + 1, MOVE[0] + 6))  # m14 does not judge them (one program grid per press)
        self.assertEqual(jp_frames(self.row("strip-grid-grows", "terminal", "m14")["fail_ranges"]) & cut, set())
        self.assertLessEqual(cut, jp_frames(self.row("strip-grid-grows", "terminal")["edge_ranges"]))

    def test_the_verdict_cli_gives_m18_by_default(self):
        import judge_m14
        lag2 = str(self.bases["strip-page-lag2"])
        self.assertEqual(judge_m14.main([lag2, "--contract", "m18"]), 0)  # m18: a page 2 refreshes late inside its pane passes
        self.assertEqual(judge_m14.main([lag2, "--contract", "m14"]), 1)  # m14 fails it
        out = Path(self.tmp) / "m18.json"
        judge_m14.main([str(self.bases["strip-page-lag3"]), "--contract", "m18", "--json", str(out)])
        film = json.loads(out.read_text())["films"][0]
        self.assertEqual((film["contract"], film["status"]), ("m18", "fail"))

    def test_the_verdict_reports_missed_refreshes_from_debug_frames(self):
        import contextlib
        import io
        import judge_m14
        base = self.bases["strip"]
        Path(f"{base}.frames.json").write_text(json.dumps({"reply": {"frames": 60, "missed": 3, "refresh_ms": 8.333,
                                                                    "intervals_ms": [8.333] * 56 + [16.7, 16.7, 25.0]}}))
        try:
            buf, out = io.StringIO(), Path(self.tmp) / "smooth.json"
            with contextlib.redirect_stdout(buf):
                judge_m14.main([str(base), "--contract", "m18", "--json", str(out)])
            smooth = json.loads(out.read_text())["films"][0]["smooth"]
            self.assertEqual((smooth["missed"], smooth["refreshes_skipped"], smooth["frames"]), (3, 4, 60), smooth)
            self.assertIn("smooth: 3 missed refreshes", buf.getvalue())
        finally:
            Path(f"{base}.frames.json").unlink()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            judge_m14.main([str(base), "--contract", "m18"])
        self.assertIn("smooth: no debug.frames read", buf.getvalue())


TOL_TEST_PX = 1.0


def jp_frames(ranges):
    """The frames of a ranges string ("11-20,25")."""
    out = set()
    for part in str(ranges or "").split(","):
        part = part.strip()
        if part:
            a, _, b = part.partition("-")
            out |= set(range(int(a), int(b or a) + 1))
    return out


class M14ContractTests(unittest.TestCase):
    """cmux-ad m14 (Lead 2026-11-05, Lawrence P0): in every frame every terminal and every page shows live pixels rendered
    at that frame's pane size: each content edge within TOL_PX of its pane edge as cmux's own layer shows it, never frozen,
    never stretched or squeezed, never the old frame anchored. m6's allowances fail: its "late" (the previous size,
    anchored top-left, clipped) is the class `allowed`, its "page late 1" the class `page_late`. Per kind, a frame takes the
    first class of: scaled (E5 stretched, or rings 2 and 3 narrower than at rest), gap (E4), edge (E2, E3, page early 1),
    allowed, page_late, pass. The m6 rows do not change (M6ContractTests)."""

    VARIANTS = ("strip", "strip-tui-a-late", "strip-page-late", "strip-stretch", "strip-squeeze", "gap2", "strip-whole-late")

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-m14-")
        cls.bases = {v: build(cls.tmp, v, v) for v in cls.VARIANTS}
        cls.reports = {v: jp.judge(b, all_frames=True) for v, b in cls.bases.items()}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def m14(self, variant, kind):
        return self.reports[variant]["m14"]["kinds"][kind]

    def m6(self, variant, kind):
        return self.reports[variant]["m6"]["kinds"][kind]

    def test_content_on_its_strips_passes(self):
        for kind in ("terminal", "page"):
            row = self.m14("strip", kind)
            self.assertGreater(row["judged"], 50, kind)
            self.assertEqual((row["fail"], row["pass"], row["worst_px"]), (0, row["judged"], 0.0), kind)
            for c in jp.M14_FAIL_CLASSES:
                self.assertEqual(row[c], 0, (kind, c))

    def test_the_allowed_frame_of_m6_fails(self):
        # A's terminal view keeps the previous sample's size in 11-30 (anchored top-left, 2 px short, no shell behind):
        # m6 passes it as late; m14 fails it as `allowed`, in exactly m6's late frames.
        m6, m14 = self.m6("strip-tui-a-late", "terminal"), self.m14("strip-tui-a-late", "terminal")
        self.assertEqual(m6["fail"], 0)
        self.assertGreaterEqual(m6["late"], 15)
        self.assertEqual((m14["allowed"], m14["fail"], m14["allowed_ranges"]), (m6["late"], m6["late"], m6["late_ranges"]))
        self.assertEqual(m14["worst_px"], 2.0)
        self.assertTrue(m14["worst_edge"].endswith(" hi"), m14["worst_edge"])

    def test_page_late_1_fails(self):
        m6, m14 = self.m6("strip-page-late", "page"), self.m14("strip-page-late", "page")
        self.assertEqual((m6["fail"], m6["page_late_1"]), (0, 20))
        self.assertEqual((m14["page_late"], m14["fail"], m14["page_late_ranges"]), (20, 20, "11-30"))
        self.assertEqual(self.m14("strip-page-late", "terminal")["fail"], 0)

    def test_stretched_and_squeezed_content_is_scaled(self):
        self.assertEqual((self.m14("strip-stretch", "page")["scaled"], self.m14("strip-stretch", "page")["scaled_ranges"]),
                         (3, "20-22"))
        row = self.m14("strip-squeeze", "page")
        self.assertEqual((row["scaled"], row["scaled_ranges"], row["fail_ranges"]), (3, "20-22", "20-22"))
        self.assertEqual(self.m6("strip-squeeze", "page")["fail_by_rule"]["E5"], 0)  # m6 has no squeeze rule

    def test_the_squeeze_rule_needs_one_scale_for_all_three_rings(self):
        # R-HARNESS review of 7cfd91442ece: an overlay (a menu over p2's left edge, ab-s4pin-44ab81a
        # px-keys-lowprompt-jjk-3kz-sw-terminals-on-s025 frames 264-433) leaves ring 1 at its rest width and reads rings 2
        # and 3 at 1 px: not a squeeze. A squeeze scales all three rings by one factor.
        rest = [2.0, 4.0, 6.0]
        self.assertFalse(jp.m14_squeezed({"status": "found", "rings": [2.0, 1.0, 1.0]}, rest))  # covered, not scaled
        self.assertTrue(jp.m14_squeezed({"status": "found", "rings": [1.0, 2.0, 3.0]}, rest))  # half size
        self.assertFalse(jp.m14_squeezed({"status": "found", "rings": [2.0, 4.0, 6.0]}, rest))  # at rest
        self.assertFalse(jp.m14_squeezed({"status": "found", "rings": [1.0, 4.0, 6.0]}, rest))  # only ring 1 narrower
        self.assertFalse(jp.m14_squeezed({"status": "cut", "rings": [1.0, 2.0, 3.0]}, rest))  # a cut side is no measure
        self.assertFalse(jp.m14_squeezed({"status": "found", "rings": [0.0, 2.0, 3.0]}, rest))  # ring 1 not found
        self.assertTrue(jp.m14_squeezed({"status": "found", "rings": [34.0, 17.0, 17.0]}, [68.0, 34.0, 34.0]))  # a terminal

    def test_a_shell_gap_is_its_own_class(self):
        row = self.m14("gap2", "terminal")
        self.assertEqual((row["gap"], row["gap_ranges"], row["fail_ranges"]), (6, "20-25", "20-25"))
        self.assertGreater(row["not_judged"], 0)  # no strip: its E2 and E3 are not judged (never the trace)

    def test_late_as_a_whole_is_information_not_a_content_class(self):
        r = self.reports["strip-whole-late"]
        self.assertEqual(r["m14"]["late_as_a_whole"], r["m6"]["late_as_a_whole"])
        for kind in ("terminal", "page"):
            self.assertEqual(self.m14("strip-whole-late", kind)["fail"], 0, kind)

    def test_m14_is_information_the_judge_exit_does_not_change(self):
        # The judge's defects stay m6's: a film that m14 alone fails (page late 1) has no m14 defect.
        r = self.reports["strip-page-late"]
        self.assertNotIn("m14 contract", [f["check"] for f in r["findings"]])
        self.assertIn("m14 contract", [f["check"] for f in r["info"]])

    def test_the_verdict_cli(self):
        import judge_m14
        out = Path(self.tmp) / "m14.json"
        # the m14 verdict (the default contract is m20 since R-HARNESS's m20 pair)
        code = judge_m14.main([str(self.bases["strip"]), str(self.bases["strip-tui-a-late"]), "--contract", "m14",
                               "--json", str(out)])
        self.assertEqual(code, 1)
        films = {Path(f["base"]).name: f for f in json.loads(out.read_text())["films"]}
        self.assertEqual((films["strip"]["status"], films["strip-tui-a-late"]["status"]), ("pass", "fail"))
        self.assertEqual(judge_m14.main([str(self.bases["strip"]), "--contract", "m14"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
