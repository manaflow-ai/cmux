#!/usr/bin/env python3
"""Tests for judge_pixel.py on synthetic pixel-fixture films (no app, no fleet), and for pixel/tui_border.py's frame.

Run: /work/tmp/bv-venv/bin/python -I scripts/journeys/video-cases/test_judge_pixel.py

A 600 x 300 px film at scale 2 (300 x 150 pt): pane A, a terminal (tui_border.py's picture: 4 px of theme padding,
16 x 32 px cells, rings 1/2/3 in the outermost cells, yellow fill, the whole-cell remainder on the right and bottom),
a 4 px divider that shows the shell (#FF00FF), and pane B, a page (page.html: borders of 2, 4 and 6 device px, green
body). The divider rests, moves right 2 px per trace sample for 20 samples, then rests. The film frame shown at
refresh k shows trace sample k-1 (video_judge.committed_sample), so a clean film is in step. Each variant damages
exactly one thing: B's content one frame late (lag), A's content 2 px short of its edge (a 2 px gap), B's content over
A's ring 1 (a hidden ring); two more declare a spring and move the divider on it (or on a slower one).
"""
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
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


def a_width(k, variant):
    """Pane A's width (device px, float) in trace sample k."""
    if variant.startswith("spring"):
        t = (k - MOVE[0] + 1) * P
        if k < MOVE[0]:
            return float(A_REST)
        g = float(jp.spring_g(t, SPRING["response"], SPRING["damping"]))
        return A_REST + 40 * (1 - g)
    sign = -1 if variant in ("cut", "backdrop") else 1  # pane A shrinks, pane B grows
    return float(A_REST + sign * 2 * min(max(k - MOVE[0] + 1, 0), MOVE[1] - MOVE[0]))


def draw_tui(img, x0, w, picture_w=None):
    """tui_border.py's picture in a terminal view [x0, x0 + w) x [0, H) (device px). picture_w: the view width the
    program last drew for (a grid that shrank before the redraw: the picture is cut at the new grid's edge)."""
    x0, w = int(round(x0)), int(round(w))
    img[:, x0:x0 + w] = CYAN
    cols, rows = (int(round(picture_w or w)) - 2 * PAD) // CW, (H - 2 * PAD) // CH
    shown = (w - 2 * PAD) // CW
    ring = [RED, WHITE, BLACK]
    for r in range(rows):
        for c in range(min(cols, shown)):
            k = min(r, c, rows - 1 - r, cols - 1 - c)
            color = ring[k] if k < 3 else YELLOW
            img[PAD + r * CH:PAD + (r + 1) * CH, x0 + PAD + c * CW:x0 + PAD + (c + 1) * CW] = color


def draw_page(img, x0, w):
    """page.html at DPR 2 in [x0, x0 + w) x [0, H): 2, 4, 6 device px of red, white, black, then green."""
    x0, w = int(round(x0)), int(round(w))
    x0c = max(x0, 0)
    img[:, x0c:x0 + w] = GREEN
    inset = 0
    for color, width in ((RED, 2), (WHITE, 4), (BLACK, 6)):
        a, b = x0 + inset, x0 + w - inset
        top, bottom = inset, H - inset
        img[top:top + width, max(a, 0):b] = color
        img[bottom - width:bottom, max(a, 0):b] = color
        img[top:bottom, max(a, 0):max(a + width, 0)] = color
        img[top:bottom, b - width:b] = color
        inset += width


def frame(k, variant):
    """The picture shown at refresh k (sample k - 1 committed)."""
    s = max(k - 1, 0)
    aw = a_width(s, variant)
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = MAGENTA
    a_view = aw
    if variant == "gap2" and 20 <= k <= 25:
        a_view = aw - 2  # A's content stops 2 px short: the shell shows
    draw_tui(img, 0, a_view, picture_w=a_width(max(s - 3, 0), variant) if variant == "cut" else None)
    b_x = aw + DIV_PX
    if variant == "lag1":
        b_x = a_width(max(k - 2, 0), variant) + DIV_PX  # B's page one frame late
    if variant == "hidden" and 30 <= k <= 32:
        # B's page covers A's view from the inner edge of A's ring 1 on (the cyan strip, the gap and ring 1).
        cols = (int(round(aw)) - 2 * PAD) // CW
        b_x = PAD + (cols - 1) * CW
    draw_page(img, b_x, W - b_x)
    if variant == "backdrop" and 15 <= k <= 18:
        # B grows and its page is one frame late, with its backdrop: B's own green from its pane edge to its late rings.
        late = a_width(max(k - 2, 0), variant) + DIV_PX
        draw_page(img, late, W - late)
        img[:, int(round(b_x)):int(round(late))] = GREEN
    return img


def bgra(img):
    return np.concatenate((img[..., ::-1], np.full(img.shape[:-1] + (1,), 255, np.uint8)), axis=-1)


def build(root, name, variant):
    base = Path(root) / name
    header = {"width": W, "height": H, "rows": ROWS, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for k in range(N):
            px = bgra(frame(k, variant))
            out.write(struct.pack("<d", T0 + k * P))
            for y in ROWS:
                out.write(px[y].tobytes())
            for x in COLS:
                out.write(px[:, x].tobytes())
    samples = []
    for k in range(N):
        aw = a_width(k, variant) / SCALE
        a = ["pa", 0, 0, aw, 150, 1, 0, 0, 0, aw, 150, aw, 150, 0, 0, 0, aw, 150]
        bx = aw + DIV_PX / SCALE
        bw = 300 - bx
        b = ["pb", bx, 0, bw, 150, 1, 1, bx, 0, bw, 150, bw, 150, 0, bx, 0, bw, 150]
        samples.append({"t": k * P * 1000, "window": [300, 150], "panes": [a, b],
                        "dividers": [["d0", aw, 0, DIV_PX / SCALE, 150, 1, 2]]})
    # Sample k is taken 1 ms before refresh k is displayed.
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples}))
    note = {"scale": SCALE, "panes": {"pa": {"kind": "tui", "fill": "#FFFF00", "label": "p0"},
                                      "pb": {"kind": "page", "fill": "#00FF00", "label": "p1"}},
            "speed": 1, "reduce": False, "input": "drag"}
    if variant == "spring":
        note["spring"] = dict(SPRING)
    if variant == "spring-slow":
        note["spring"] = {"response": SPRING["response"] * 2, "damping": SPRING["damping"]}
    meta = {"start": {"width": W, "height": H, "scale": SCALE, "rows": ROWS, "columns": COLS}, "notes": {"pixel": note}}
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


def divider(report, line):
    for s in report["summary"].values():
        if s["what"] == "divider" and s["line"] == line:
            return s
    raise AssertionError(f"no divider on {line} in {sorted(report['summary'])}")


class JudgePixelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-pixel-")
        cls.reports = {v: jp.judge(build(cls.tmp, v, v)) for v in ("clean", "lag1", "gap2", "hidden", "spring", "spring-slow", "cut",
                                                                    "backdrop")}

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

    def test_divider_follows_the_trace(self):
        clean = divider(self.reports["clean"], "row@110")
        self.assertEqual(clean["label"], "divider p0|p1")
        self.assertEqual(clean["max_edge_dev_px"], 0.0)
        self.assertEqual(clean["max_lag_frames"], 0)
        self.assertEqual([m["travel_px"] for m in clean["motions"]], [40.0])
        # B over A's ring 1: A's edge shows at B's ring 1 (-26 px), B's 32 px left of its pane edge: the middle, -29 px.
        self.assertEqual(divider(self.reports["hidden"], "row@110")["max_edge_dev_px"], -29.0)
        self.assertIn("divider off", [f["check"] for f in self.reports["hidden"]["findings"]])
        good = divider(self.reports["spring"], "row@110")["motions"][0]
        self.assertLessEqual(good["spring_trace"]["max_px"], 0.05)
        self.assertLessEqual(good["spring_film"]["max_px"], 0.75)

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

    def test_markdown_and_cli(self):
        base = Path(self.tmp) / "gap2"
        out, md = Path(self.tmp) / "gap2.json", Path(self.tmp) / "gap2.md"
        done = subprocess.run([sys.executable, "-I", str(HERE / "judge_pixel.py"), str(base), "--json", str(out),
                               "--markdown", str(md)], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("gap", done.stdout)
        self.assertEqual(json.loads(out.read_text())["case"], "gap2")
        lines = md.read_text().splitlines()
        self.assertTrue(lines[0].startswith("| case | what | side | line |"))
        self.assertTrue(any(l.startswith("| gap2 | p0 (tui) | hi | row@180 |") and "| 2 |" in l for l in lines), lines)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
