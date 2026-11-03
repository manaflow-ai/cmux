#!/usr/bin/env python3
"""Frame markers (ext_marker.py; REWRITE R-HARNESS stage S5): a journey's own line is read from the frame's pixels,
never by text recognition. No app, no fleet, standard library only (it also runs with the minis' /usr/bin/python3).

    python3 -I scripts/journeys/test_ext_marker.py

Why (STATUS 9303, 9402, 9444, 2026-11-03): three P0 journeys failed on frames that showed the right line, because
the text reader read "733287-42" as "733287-4źął", "jq-447486-400" as "j9-447486-400", and returned 0 lines for a
correct frame with a long digit line. A marker is one row of truecolor cells the terminal draws; a pixel reader
decodes it with no language model.

The corpus tests render thousands of markers into synthetic frames as the terminal draws them (solid cell rectangles
on the cell grid, 1x and 2x cell sizes, dark and light themes, glyph noise around them), pass them through the color
changes a capture can make (sRGB values shown as Display P3, P3 clipped to sRGB, a 30 % dimming overlay over a dark or
a light fill), encode each frame as a PNG and decode it with the module's own PNG reader. Every marker must decode to
its own token, every corrupted marker must be refused (never read as another token), and a frame with no marker must
give none.
"""
import hashlib
import json
import os
import random
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import ext_marker as M  # noqa: E402

SEED = 20261103


# ---- a frame as the terminal draws it --------------------------------------------------------------------------------

class Frame:
    """An RGBA frame: rows of bytearrays."""

    def __init__(self, width, height, color):
        self.width, self.height = width, height
        px = bytes((color[0], color[1], color[2], 255))
        self.rows = [bytearray(px * width) for _ in range(height)]

    def rect(self, x, y, w, h, color):
        px = bytes((color[0], color[1], color[2], 255))
        for yy in range(max(0, y), min(self.height, y + h)):
            row = self.rows[yy]
            x0, x1 = max(0, x), min(self.width, x + w)
            if x1 > x0:
                row[4 * x0:4 * x1] = px * (x1 - x0)

    def map(self, fn):
        """Applies fn((r, g, b)) -> (r, g, b) to every pixel (a capture's color change)."""
        cache = {}
        for row in self.rows:
            for o in range(0, len(row), 4):
                key = bytes(row[o:o + 3])
                if key not in cache:
                    cache[key] = bytes(fn(tuple(key)))
                row[o:o + 3] = cache[key]

    def png(self, path):
        raw = b"".join(b"\x00" + bytes(r) for r in self.rows)

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.width, self.height, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
        Path(path).write_bytes(data)
        return path


def draw_marker(frame, token, x, y, cell_w, cell_h, cells=None):
    """The marker of TOKEN as the terminal draws its line: one solid rectangle per cell, from cell column 0 at x."""
    for i, color in enumerate(cells if cells is not None else M.marker_cells(token)):
        frame.rect(x + i * cell_w, y, cell_w, cell_h, color)
    return len(cells if cells is not None else M.marker_cells(token)) * cell_w


def draw_text_noise(frame, rng, x, y, cols, cell_w, cell_h, ink):
    """A line of glyph-like strokes in INK over the background (no solid cells)."""
    for c in range(cols):
        if rng.random() < 0.25:
            continue
        gx = x + c * cell_w
        for _ in range(rng.randint(2, 5)):
            sx, sy = gx + rng.randint(1, max(1, cell_w - 2)), y + rng.randint(2, max(2, cell_h - 3))
            frame.rect(sx, sy, rng.randint(1, 2), rng.randint(1, max(1, cell_h // 2)), ink)


# ---- color changes a capture can make --------------------------------------------------------------------------------

def _to_linear(v):
    v /= 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def _to_srgb(v):
    v = min(1.0, max(0.0, v))
    v = v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055
    return int(round(v * 255))


SRGB_TO_P3 = ((0.8225, 0.1774, 0.0000), (0.0332, 0.9669, 0.0000), (0.0171, 0.0724, 0.9108))
P3_TO_SRGB = ((1.2249, -0.2247, 0.0000), (-0.0420, 1.0419, 0.0000), (-0.0197, -0.0786, 1.0979))


def _matrix(m):
    def fn(rgb):
        lin = [_to_linear(c) for c in rgb]
        return tuple(_to_srgb(sum(m[i][j] * lin[j] for j in range(3))) for i in range(3))
    return fn


def _dim(fill, opacity=0.7):
    def fn(rgb):
        return tuple(int(round(opacity * c + (1 - opacity) * f)) for c, f in zip(rgb, fill))
    return fn


TRANSFORMS = {
    "identity": lambda rgb: rgb,
    "srgb-shown-as-p3": _matrix(SRGB_TO_P3),
    "p3-clipped-to-srgb": _matrix(P3_TO_SRGB),
    "dim-over-dark": _dim((30, 30, 30)),
    "dim-over-light": _dim((246, 246, 246)),
}
THEMES = {"dark": ((30, 30, 30), (230, 230, 230)), "light": ((255, 255, 255), (40, 40, 40))}
CELLS_1X = [(7, 15), (8, 17), (9, 19), (10, 21)]
CELLS_2X = [(14, 30), (16, 34), (18, 38), (20, 42)]


def tokens(rng, n):
    """Tokens the journeys write: WORD-NONCE-VALUE (the nonce is six of 23456789)."""
    words = ["", "ok-", "after-", "first-", "second-", "right-", "back-", "jq-", "rp-", "t2-", "big-", "moving-"]
    out = set()
    while len(out) < n:
        nonce = "".join(rng.choice("23456789") for _ in range(6))
        out.add(f"{rng.choice(words)}{nonce}-{rng.choice([42, 31, 8, 400, 397, 7, 1234])}")
    return sorted(out)


def scan_png(frame, directory, name):
    path = frame.png(Path(directory) / f"{name}.png")
    width, height, rows = M.read_png(path)
    return M.scan_markers(width, height, rows)


# ---- the tests ---------------------------------------------------------------------------------------------------------

class EncodingTests(unittest.TestCase):
    def test_cells_use_only_the_capture_safe_colors_and_neighbours_always_differ(self):
        rng = random.Random(SEED)
        for token in tokens(rng, 500):
            cells = M.marker_cells(token)
            self.assertEqual(len(cells), M.MARKER_CELLS)
            self.assertTrue(all(c in M.SAFE_COLORS.values() for c in cells), token)
            self.assertTrue(all(a != b for a, b in zip(cells, cells[1:])), token)
            self.assertNotIn(cells[-1], (M.SAFE_COLORS["K"], M.SAFE_COLORS["W"]), "the last cell must differ from a theme ground")

    def test_the_value_round_trips_and_tokens_differ(self):
        rng = random.Random(SEED + 1)
        seen = {}
        for token in tokens(rng, 2000):
            value = M.token_value(token)
            self.assertEqual(M.decode_digits(M.encode_digits(value)), value)
            seen.setdefault(M.token_digest(token), set()).add(token)
        self.assertTrue(all(len(v) == 1 for v in seen.values()), "two tokens with one digest in the corpus")

    def test_the_marker_program_prints_the_text_line_and_the_cells(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = subprocess.run([sys.executable, "-I", str(HERE / "ext_marker.py"), "733287-42"],
                                  capture_output=True, text=True, env=dict(os.environ, COLUMNS="80"), cwd=tmp)
        self.assertEqual(done.returncode, 0, done.stderr)
        text, cells = done.stdout.split("\n")[:2]
        self.assertEqual(text, "733287-42")
        got = [tuple(int(v) for v in m) for m in re.findall(r"\x1b\[48;2;(\d+);(\d+);(\d+)m ", cells)]
        self.assertEqual(got, M.marker_cells("733287-42"))
        self.assertTrue(cells.endswith("\x1b[0m"))
        self.assertEqual(len(re.sub(r"\x1b\[[0-9;]*m", "", cells)), M.MARKER_CELLS, "one space per cell")

    def test_the_program_refuses_a_pane_too_narrow_for_the_marker(self):
        done = subprocess.run([sys.executable, "-I", str(HERE / "ext_marker.py"), "733287-42"],
                              capture_output=True, text=True, env=dict(os.environ, COLUMNS=str(M.MARKER_CELLS - 1)))
        self.assertEqual(done.returncode, 3)
        self.assertIn("columns", done.stdout + done.stderr)

    def test_the_program_refuses_a_token_it_cannot_mark(self):
        for bad in ("", "a b", "x" * 65, "café"):
            done = subprocess.run([sys.executable, "-I", str(HERE / "ext_marker.py"), bad], capture_output=True, text=True,
                                  env=dict(os.environ, COLUMNS="80"))
            self.assertEqual(done.returncode, 2, bad)

    def test_the_file_is_its_own_program(self):
        first = (HERE / "ext_marker.py").read_text().split("\n", 1)[0]
        self.assertEqual(first, "#!/usr/bin/python3 -I")


class PngReaderTests(unittest.TestCase):
    def test_every_filter_type_decodes_byte_exact(self):
        rng = random.Random(SEED + 2)
        w, h = 37, 23
        rows = [bytes(rng.randrange(256) for _ in range(w * 4)) for _ in range(h)]
        raw, prev = b"", bytes(w * 4)
        for y, row in enumerate(rows):  # encode each row with filter y % 5 (the decoder must undo each)
            ftype = y % 5
            out = bytearray()
            for x in range(len(row)):
                a = row[x - 4] if x >= 4 else 0
                b = prev[x]
                c = prev[x - 4] if x >= 4 else 0
                if ftype == 0:
                    pred = 0
                elif ftype == 1:
                    pred = a
                elif ftype == 2:
                    pred = b
                elif ftype == 3:
                    pred = (a + b) >> 1
                else:
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
                out.append((row[x] - pred) & 255)
            raw += bytes([ftype]) + bytes(out)
            prev = row

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "f.png"
            path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                             + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
            width, height, got = M.read_png(path)
        self.assertEqual((width, height), (w, h))
        self.assertEqual(got, rows)

    def test_an_unsupported_png_is_an_error_not_a_reading(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.png"
            path.write_bytes(b"not a png")
            with self.assertRaises(ValueError):
                M.read_png(path)


class CorpusTests(unittest.TestCase):
    """Thousands of markers in synthetic frames, through every capture color change, at 1x and 2x."""

    def test_every_marker_decodes_to_its_token(self):
        rng = random.Random(SEED + 3)
        all_tokens = tokens(rng, 1200)
        found = total = 0
        with tempfile.TemporaryDirectory() as tmp:
            for k, (tname, transform) in enumerate(sorted(TRANSFORMS.items())):
                for theme, (ground, ink) in sorted(THEMES.items()):
                    for cells in (CELLS_1X, CELLS_2X):
                        batch = all_tokens[(k * 120) % len(all_tokens):][:40] or all_tokens[:40]
                        for i in range(0, len(batch), 4):
                            group = batch[i:i + 4]
                            cell_w, cell_h = rng.choice(cells)
                            width = (M.MARKER_CELLS + 12) * cell_w + 40
                            frame = Frame(width, cell_h * (2 * len(group) + 2), ground)
                            placed = {}
                            for j, token in enumerate(group):
                                y = cell_h * (2 * j + 1)
                                x = rng.randint(0, 9)
                                draw_text_noise(frame, rng, x, y - cell_h, M.MARKER_CELLS + 6, cell_w, cell_h, ink)
                                draw_marker(frame, token, x, y, cell_w, cell_h)
                                placed[M.token_digest(token)] = token
                            frame.map(transform)
                            markers = scan_png(frame, tmp, f"c{k}-{theme}-{i}")
                            total += len(group)
                            good = [m for m in markers if m["ok"]]
                            self.assertFalse([m for m in markers if not m["ok"]],
                                             f"{tname} {theme} {cell_w}x{cell_h}: unreadable {markers}")
                            self.assertEqual(sorted(m["digest"] for m in good), sorted(placed),
                                             f"{tname} {theme} {cell_w}x{cell_h}: {good}")
                            found += len(good)
        self.assertEqual(found, total)
        self.assertGreaterEqual(total, 400)

    def test_a_corrupted_marker_is_refused_never_read_as_another_token(self):
        rng = random.Random(SEED + 4)
        corpus = tokens(rng, 3000)
        refused = wrong = 0
        with tempfile.TemporaryDirectory() as tmp:
            for n, token in enumerate(corpus):
                cells = list(M.marker_cells(token))
                kind = n % 5
                if kind == 0:  # one cell takes another capture-safe color
                    i = rng.randrange(len(M.START), len(cells) - 1)
                    cells[i] = rng.choice([c for c in M.SAFE_COLORS.values() if c != cells[i]])
                elif kind == 1:  # cut short (a narrower pane wrapped it, or a view covers its end)
                    cells = cells[:rng.randrange(len(M.START) + 1, len(cells) - 1)]
                elif kind == 2:  # two neighbours swapped
                    i = rng.randrange(len(M.START), len(cells) - 2)
                    cells[i], cells[i + 1] = cells[i + 1], cells[i]
                elif kind == 3:  # one cell in a color no marker uses
                    i = rng.randrange(len(M.START), len(cells) - 1)
                    cells[i] = (128, 128, 128)
                else:  # two cells changed
                    for i in rng.sample(range(len(M.START), len(cells) - 1), 2):
                        cells[i] = rng.choice([c for c in M.SAFE_COLORS.values() if c != cells[i]])
                cell_w, cell_h = rng.choice(CELLS_1X + CELLS_2X)
                frame = Frame((M.MARKER_CELLS + 4) * cell_w, cell_h * 3, (30, 30, 30))
                draw_marker(frame, token, 2 * cell_w, cell_h, cell_w, cell_h, cells=cells)
                if n % 500 == 0:  # the PNG path for some, the row decoder directly for the rest (speed)
                    markers = scan_png(frame, tmp, f"x{n}")
                else:
                    markers = M.scan_markers(frame.width, frame.height, [bytes(r) for r in frame.rows])
                good = [m for m in markers if m["ok"]]
                if good:
                    wrong += 1
                    self.fail(f"a corrupted marker of {token!r} ({kind}) read as {good}")
                refused += 1
        self.assertEqual(wrong, 0)
        self.assertEqual(refused, len(corpus))

    def test_frames_with_no_marker_give_none(self):
        rng = random.Random(SEED + 5)
        palette = list(M.SAFE_COLORS.values()) + [(0, 255, 0), (0, 255, 255), (40, 200, 64), (254, 188, 46), (255, 95, 87)]
        for n in range(150):
            cell_w, cell_h = rng.choice(CELLS_1X + CELLS_2X)
            frame = Frame(60 * cell_w, 12 * cell_h, rng.choice([(30, 30, 30), (255, 255, 255)]))
            for _ in range(80):  # solid blocks and strokes in every pure color, but no marker start
                color = rng.choice(palette)
                frame.rect(rng.randrange(frame.width), rng.randrange(frame.height), rng.randint(1, 4 * cell_w),
                           rng.randint(1, cell_h), color)
            markers = M.scan_markers(frame.width, frame.height, [bytes(r) for r in frame.rows])
            self.assertEqual(markers, [], n)


class RealFrameTests(unittest.TestCase):
    """The three frames the text reader failed on today (STATUS 9303, 9402, 9444), when this machine has them."""

    FRAMES = [
        "/work/wt/chrome-parity-design/p0-journey-runner/runs/64ef2a21/p0jr-64ef2a21-ctrlbt-real-palette-a1-s40/run/"
        "ctrlbt-real-palette/check-35.png",
        "/work/wt/chrome-parity-design/p0-journey-runner/runs/ecf26eee/p0jr-ecf26eee-quit-reopen-restore-a1-s56/run/"
        "quit-reopen-restore/check-74.png",
        "/work/wt/chrome-parity-design/p0-journey-runner/runs/8e149f2e/p0jr-8e149f2e-r3-after-switch-a1-s67/run/"
        "r3-after-switch/check-46.png",
    ]

    def frames(self):
        here = [p for p in self.FRAMES if Path(p).is_file()]
        if not here:
            self.skipTest("the real frames are not on this machine")
        return here

    def test_the_real_frames_hold_no_marker(self):
        for path in self.frames():
            width, height, rows = M.read_png(path)
            self.assertEqual(M.scan_markers(width, height, rows), [], path)

    def test_a_marker_drawn_into_the_real_frames_terminal_area_decodes(self):
        rng = random.Random(SEED + 6)
        for path in self.frames():
            width, height, rows = M.read_png(path)
            for trial in range(6):
                token = tokens(rng, 1)[0]
                cell_w, cell_h = rng.choice(CELLS_1X)
                x = width - (M.MARKER_CELLS + 2) * cell_w - rng.randint(0, 20)
                y = rng.randint(0, height - cell_h - 1)
                frame = Frame(width, height, (0, 0, 0))
                frame.rows = [bytearray(r) for r in rows]
                draw_marker(frame, token, x, y, cell_w, cell_h)
                markers = M.scan_markers(width, height, [bytes(r) for r in frame.rows])
                self.assertEqual([m["digest"] for m in markers if m["ok"]], [M.token_digest(token)], (path, trial))
                self.assertFalse([m for m in markers if not m["ok"]], (path, trial))


if __name__ == "__main__":
    unittest.main()
