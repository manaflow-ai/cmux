#!/usr/bin/env python3
"""Frame markers (ext_marker.py; REWRITE R-HARNESS stage S5): a journey's own line is read from the frame's pixels,
never by text recognition. No app, no fleet, standard library only (it also runs with the minis' /usr/bin/python3).

    python3 -I scripts/journeys/test_ext_marker.py

Why (STATUS 9303, 9402, 9444, 2026-11-03): three P0 journeys failed on frames that showed the right line, because
the text reader read "733287-42" as "733287-4źął", "jq-447486-400" as "j9-447486-400", and returned 0 lines for a
correct frame with a long digit line. A marker is one row of truecolor cells the terminal draws; a pixel reader
decodes it with no language model.

The corpus tests render 800 markers (and 3000 corrupted ones) into synthetic frames as the terminal draws them (solid cell rectangles
on the cell grid, 1x and 2x cell sizes, dark and light themes, glyph noise around them), pass them through the color
changes a capture can make (sRGB values shown as Display P3, P3 clipped to sRGB, a 30 % dimming overlay over a dark or
a light fill), encode each frame as a PNG and decode it with the module's own PNG reader. Every marker must decode to
its own token, every corrupted marker must be refused (never read as another token), and a frame with no marker must
give none.
"""
import fcntl
import hashlib
import json
import os
import pty
import select
import random
import re
import struct
import subprocess
import sys
import tempfile
import time
import termios
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


def run_in_terminal(args, columns, env=None, timeout=20):
    """(exit code, output) of the marker program run in a pseudo-terminal COLUMNS wide, as a shell in a pane runs it."""
    pid, fd = pty.fork()
    if pid == 0:  # the child: the pty is its terminal; its size is set before the program can read it
        fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
        os.execve(sys.executable, [sys.executable, "-I", str(HERE / "ext_marker.py"), *args], env or dict(os.environ))
    out, end = b"", time.monotonic() + timeout
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:  # the program ended and closed the terminal
                break
            if not chunk:
                break
            out += chunk
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    return os.waitstatus_to_exitcode(status), out.decode().replace("\r\n", "\n")


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

    def test_the_marker_program_prints_the_text_line_and_the_cells_between_blank_lines(self):
        # The token line, a blank line, the 30 cells, a blank line: no glyph of a text line can reach a marker
        # pixel row (review of #34071: a glyph in the marker row makes it unreadable).
        code, out = run_in_terminal(["733287-42"], 80)
        self.assertEqual(code, 0, out)
        lines = out.split("\n")
        cells = lines[2]
        self.assertEqual(lines, ["733287-42", "", cells, "", ""], "the token, a blank line, the cells, a blank line")
        got = [tuple(int(v) for v in m) for m in re.findall(r"\x1b\[48;2;(\d+);(\d+);(\d+)m ", cells)]
        self.assertEqual(got, M.marker_cells("733287-42"))
        self.assertTrue(cells.endswith("\x1b[0m"))
        self.assertEqual(len(re.sub(r"\x1b\[[0-9;]*m", "", cells)), M.MARKER_CELLS, "one space per cell")

    def test_the_program_refuses_a_pane_too_narrow_for_the_marker(self):
        code, out = run_in_terminal(["733287-42"], M.MARKER_CELLS - 1)
        self.assertEqual(code, 3, out)
        self.assertIn(f"has {M.MARKER_CELLS - 1} columns", out)

    def test_a_pane_of_exactly_thirty_columns_gets_the_marker(self):
        code, out = run_in_terminal(["733287-42"], M.MARKER_CELLS)
        self.assertEqual(code, 0, out)
        self.assertEqual(len(re.findall(r"\x1b\[48;2;(\d+);(\d+);(\d+)m ", out)), M.MARKER_CELLS)

    def test_the_width_is_the_terminals_not_an_exported_columns(self):
        # A shell can export COLUMNS that is not the pane's width: the terminal's own size decides.
        code, out = run_in_terminal(["733287-42"], M.MARKER_CELLS - 1, env=dict(os.environ, COLUMNS="200"))
        self.assertEqual(code, 3, out)
        self.assertIn(f"has {M.MARKER_CELLS - 1} columns", out)
        code, out = run_in_terminal(["733287-42"], 80, env=dict(os.environ, COLUMNS="10"))
        self.assertEqual(code, 0, out)

    def test_the_program_refuses_an_output_that_is_no_terminal(self):
        done = subprocess.run([sys.executable, "-I", str(HERE / "ext_marker.py"), "733287-42"],
                              capture_output=True, text=True, env=dict(os.environ, COLUMNS="80"))
        self.assertEqual(done.returncode, 4, done.stdout)
        self.assertIn("terminal", done.stdout + done.stderr)
        self.assertNotIn("\x1b[48;2;", done.stdout)

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

    def test_a_cut_or_damaged_png_is_a_value_error(self):
        # Review of #34071 at 1ac0a680ca6 (finding 1): struct.error and zlib.error escaped the driver's handler.
        frame = Frame(16, 8, (0, 0, 0))
        with tempfile.TemporaryDirectory() as tmp:
            good = frame.png(Path(tmp) / "good.png").read_bytes()
            ihdr_end = 8 + 8 + 13 + 4
            idat = good.index(b"IDAT") - 4
            size = struct.unpack(">I", good[idat:idat + 4])[0]
            cases = {
                "cut inside IHDR": good[:8 + 8 + 5],
                "cut inside IDAT": good[:idat + 8 + size // 2],
                "damaged IDAT data": good[:idat + 8] + b"\xff" * size + good[idat + 8 + size:],
                "no IDAT": good[:ihdr_end] + good[idat + 12 + size:],
                "a chunk longer than the file": good[:idat] + struct.pack(">I", 10 ** 6) + good[idat + 4:],
                "cut at the end of IHDR": good[:ihdr_end],
                "cut inside the next length field": good[:ihdr_end + 2],
                "an IHDR of 12 bytes": good[:8] + struct.pack(">I", 12) + good[12:],
                "no IHDR (its type changed)": good[:12] + b"IHDx" + good[16:],
                "an IHDR one row taller than its data": good[:20] + struct.pack(">I", 9) + good[24:],
                "an IHDR one column wider than its data": good[:16] + struct.pack(">I", 17) + good[20:],
            }
            for name, data in cases.items():
                with self.subTest(case=name):
                    path = Path(tmp) / "bad.png"
                    path.write_bytes(data)
                    with self.assertRaises(ValueError):
                        M.read_png(path)

    def test_a_damaged_snapshot_fails_its_check_and_the_journey_not_the_driver(self):
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver as D

        class App:
            snapshot_window = None

            def snapshot(self, path):
                frame = Frame(16, 8, (0, 0, 0))
                data = frame.png(path).read_bytes()
                at = data.index(b"IDAT") + 4
                Path(path).write_bytes(data[:at] + b"\xff" * 12 + data[at + 12:])
                return Path(path)

            def panes(self):
                return []

        with tempfile.TemporaryDirectory() as tmp:
            spec = {"id": "damaged", "steps": [{"do": "expect", "all": [{"frame_marker": "ok-1-42"}], "timeout": 0.1}]}
            saved, D.FRAME_GRACE = getattr(D, "FRAME_GRACE", None), 0.3
            try:
                journey = D.Journey(spec, App(), tmp, D.now() + 60, 1.0)
                journey.clip_frames = lambda: 0  # the clip scales frames with macOS sips; this test runs anywhere
                result = journey.run()
            finally:
                if saved is not None:
                    D.FRAME_GRACE = saved
        self.assertEqual(result["status"], "fail", result)
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker")
        self.assertIn("does not decompress", json.dumps(check))


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


class ReadRuleTests(unittest.TestCase):
    """Each rule that keeps a cut, covered or blended marker from reading (review of #34071 at 1ac0a680ca6, finding 3:
    four of them could be removed with all 13 tests still passing)."""

    def frame(self):
        return Frame(400, 60, (0, 0, 0))

    def scan(self, frame):
        with tempfile.TemporaryDirectory() as tmp:
            return scan_png(frame, tmp, "rule")

    def test_rows_that_decode_to_two_markers_are_one_unreadable_marker(self):
        frame = self.frame()
        draw_marker(frame, "first-234567-42", 8, 10, 8, 9)
        draw_marker(frame, "second-234567-42", 8, 19, 8, 9)  # the same x and cell: one band of 18 rows
        got = self.scan(frame)
        self.assertEqual(len(got), 1, got)
        self.assertFalse(got[0]["ok"], got)
        self.assertIn("different markers", got[0]["why"])

    def test_a_data_cell_one_pixel_wider_is_unreadable(self):
        frame = self.frame()
        cells = M.marker_cells("ok-234567-42")
        x = 8
        for i, color in enumerate(cells):
            w = 9 if i == 6 else 8  # cell 6 (a data cell) one pixel wider; the cells after it shift by 1 px
            frame.rect(x, 10, w, 17, color)
            x += w
        got = self.scan(frame)
        self.assertEqual(len(got), 1, got)
        self.assertFalse(got[0]["ok"], got)
        self.assertIn("cell 6", got[0]["why"])

    def test_a_band_under_six_pixel_rows_is_no_marker_and_six_is_one(self):
        # The rule's numbers, not the module's constant: a test that reads MIN_ROWS follows any change of it.
        frame = self.frame()
        draw_marker(frame, "ok-234567-42", 8, 10, 8, 5)
        self.assertEqual(self.scan(frame), [])
        frame = self.frame()
        draw_marker(frame, "ok-234567-42", 8, 10, 8, 6)
        got = self.scan(frame)
        self.assertEqual([m["digest"] for m in got if m["ok"]], [M.token_digest("ok-234567-42")])

    def test_a_marker_right_after_runs_of_its_start_colors_is_read(self):
        # Magenta 2 px, yellow 3 px and blue 5 px just left of the marker: a false start there must not hide the
        # real START that follows (the search goes on from that false start's last run, not past it).
        frame = self.frame()
        frame.rect(28, 10, 2, 17, M.SAFE_COLORS["M"])
        frame.rect(30, 10, 3, 17, M.SAFE_COLORS["Y"])
        frame.rect(33, 10, 5, 17, M.SAFE_COLORS["B"])
        draw_marker(frame, "ok-234567-42", 38, 10, 8, 17)
        got = self.scan(frame)
        self.assertEqual([(m["x"], m["digest"]) for m in got if m["ok"]], [(38, M.token_digest("ok-234567-42"))])

    def test_start_runs_of_unequal_width_are_no_marker(self):
        frame = self.frame()
        cells = M.marker_cells("ok-234567-42")
        x = 8
        for i, color in enumerate(cells):
            w = 9 if i == 2 else 8  # the START's third run one pixel wider; every cell after it still 8 px
            frame.rect(x, 10, w, 17, color)
            x += w
        self.assertEqual(self.scan(frame), [])

    # A marker whose START and data show is reported, never dropped: frame_marker_lacks fails on an unreadable marker,
    # and holds on a frame where none is reported (review 5 of #34071, finding 1: each rule below could be removed with
    # all 32 tests passing, and then the negative held on a frame that shows T).
    def test_a_marker_cut_by_the_frames_right_edge_is_unreadable(self):
        frame = Frame(8 + 20 * 8, 40, (30, 30, 30))  # the frame ends on the boundary after cell 20
        draw_marker(frame, "ok-234567-42", 8, 10, 8, 17)
        got = self.scan(frame)
        self.assertEqual([(m["ok"], m["digest"]) for m in got], [(False, None)], got)
        self.assertIn("the line ends", got[0]["why"])

    def test_a_wrong_end_cell_is_unreadable(self):
        frame = Frame(400, 40, (30, 30, 30))
        cells = list(M.marker_cells("ok-234567-42"))
        i = len(M.START) + M.DATA_DIGITS + 1  # the second END cell, in another marker color unlike its neighbours
        cells[i] = next(c for c in M.SAFE_COLORS.values() if c not in (cells[i - 1], cells[i], cells[i + 1]))
        draw_marker(frame, "ok-234567-42", 8, 10, 8, 17, cells=cells)
        got = self.scan(frame)
        self.assertEqual([(m["ok"], m["digest"]) for m in got], [(False, None)], got)
        self.assertIn("no END", got[0]["why"])

    def test_a_marker_on_the_frames_last_rows_reads(self):
        frame = Frame(400, 27, (30, 30, 30))  # the band, rows 10-26, ends on the frame's last row
        draw_marker(frame, "ok-234567-42", 8, 10, 8, 17)
        self.assertEqual([m["digest"] for m in self.scan(frame) if m["ok"]], [M.token_digest("ok-234567-42")])


class ConditionTests(unittest.TestCase):
    """frame_marker and frame_marker_lacks decide on readable snapshots (review 2 of #34071, finding 1: no test failed
    when either condition always held)."""

    W, X = "with-234567-42", "gone-234567-42"

    class Journey:
        """The journey surface the conditions use: checks, out, app.snapshot (a frame DRAW paints)."""

        def __init__(self, out, draw):
            self.checks, self.out, self.draw, self.app = 0, Path(out), draw, self

        def snapshot(self, path):
            frame = Frame(400, 120, (30, 30, 30))
            self.draw(frame)
            return frame.png(path)

    def holds(self, condition, want, *markers):
        """Whether CONDITION holds for WANT on a frame with MARKERS: (token, y) or (token, y, cells)."""
        def draw(frame):
            for token, y, *cells in markers:
                draw_marker(frame, token, 8, y, 8, 17, cells=cells[0] if cells else None)
        with tempfile.TemporaryDirectory() as tmp:
            return condition(self.Journey(tmp, draw), want, {})[0]

    @staticmethod
    def one_cell_wrong(token):
        cells = list(M.marker_cells(token))
        cells[10] = next(c for c in M.SAFE_COLORS.values() if c not in (cells[9], cells[10], cells[11]))
        return cells

    def test_frame_marker_holds_only_for_a_readable_marker_of_its_token(self):
        W, X = self.W, self.X
        self.assertTrue(self.holds(M.cond_frame_marker, W, (W, 10)))
        self.assertFalse(self.holds(M.cond_frame_marker, W, (X, 10)), "another token's marker")
        self.assertFalse(self.holds(M.cond_frame_marker, W), "no marker")
        self.assertFalse(self.holds(M.cond_frame_marker, W, (W, 10, self.one_cell_wrong(W))), "one wrong cell")
        # A token the program refuses to mark ("a b": a space) never holds, even on a frame that shows the very cells
        # its digest would give: the check refuses the token before it reads the frame.
        self.assertFalse(self.holds(M.cond_frame_marker, "a b", ("a b", 10)), "a token it cannot mark")

    def test_frame_marker_lacks_needs_the_proof_the_absence_and_no_unreadable_marker(self):
        W, X = self.W, self.X
        want = {"token": X, "with": W}
        self.assertTrue(self.holds(M.cond_frame_marker_lacks, want, (W, 10)))
        self.assertFalse(self.holds(M.cond_frame_marker_lacks, want), "no proof marker")
        self.assertFalse(self.holds(M.cond_frame_marker_lacks, want, (W, 10), (X, 50)), "the token shows")
        self.assertFalse(self.holds(M.cond_frame_marker_lacks, want, (W, 10), (X, 50, self.one_cell_wrong(X))),
                         "an unreadable marker")
        self.assertFalse(self.holds(M.cond_frame_marker_lacks, want, (X, 50)), "the token without the proof")
        for bad in ("a b", "", "x" * 65):
            self.assertFalse(self.holds(M.cond_frame_marker_lacks, {"token": bad, "with": W}, (W, 10)),
                             f"a token it cannot mark: {bad!r}")


class NegativeFrameTests(unittest.TestCase):
    """frame_marker_lacks in a journey: a frame that shows T fails the check at once; a later frame without T does
    not undo it (review 3 of #34071, finding 2: the frame loop tried a failed frame condition again until one frame
    held, so a T marker on the first snapshot only, or a false read of T, was retried away)."""

    W, X = "with-234567-42", "gone-234567-42"

    def run_journey(self, frames_with_x=(), show=None):
        """Journey.run of one expect step with frame_marker_lacks {X, with W}. Check snapshot n shows show(n): "W" (the
        proof), "X" (the forbidden token), "U" (an unreadable marker); by default W, and X on FRAMES_WITH_X."""
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver as D
        W, X = self.W, self.X
        show = show or (lambda n: "WX" if n in frames_with_x else "W")

        class App:
            snapshot_window = None
            shots = 0

            def snapshot(self, path):
                # Only the check's own snapshots (check-NN.png) count; the driver's clip recorder takes others.
                frame = Frame(400, 120, (30, 30, 30))
                what = ""
                if Path(path).name.startswith("check-"):
                    App.shots += 1
                    what = show(App.shots)
                if "W" in what:
                    draw_marker(frame, W, 8, 10, 8, 17)
                if "X" in what:
                    draw_marker(frame, X, 8, 50, 8, 17)
                if "U" in what:
                    cells = list(M.marker_cells(X))
                    cells[10] = (128, 128, 128)  # a cell of no class: an unreadable marker
                    draw_marker(frame, X, 8, 80, 8, 17, cells=cells)
                return frame.png(path)

            def panes(self):
                return []

        with tempfile.TemporaryDirectory() as tmp:
            spec = {"id": "negative", "steps": [{"do": "expect", "timeout": 0.1,
                                                 "all": [{"frame_marker_lacks": {"token": X, "with": W}}]}]}
            saved, D.FRAME_GRACE = D.FRAME_GRACE, 0.6
            try:
                journey = D.Journey(spec, App(), tmp, D.now() + 60, 1.0)
                journey.clip_frames = lambda: 0  # the clip scales frames with macOS sips; this test runs anywhere
                return journey.run(), App.shots
            finally:
                D.FRAME_GRACE = saved

    def test_a_token_on_the_first_snapshot_only_fails_the_check(self):
        # (The journey itself fails for want of app and daemon evidence; the check is what is judged here.)
        result, shots = self.run_journey(frames_with_x={1})
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertFalse(check["pass"], check)
        self.assertTrue(check["detail"]["seen"], check)
        self.assertEqual(shots, 1, "no later snapshot is read once T showed")

    def test_the_token_on_a_frame_without_the_proof_does_not_fail_at_once(self):
        # A snapshot taken before the window draws the step's output still shows the old screen: T, and no W. That
        # frame is not this step's: it is tried again (review 4 of #34071, finding 1).
        result, shots = self.run_journey(show=lambda n: "W" if n >= 2 else "X")
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertTrue(check["pass"], check)
        self.assertEqual(shots, 2)

    def test_a_frame_before_the_proof_shows_is_tried_again(self):
        result, shots = self.run_journey(show=lambda n: "W" if n >= 2 else "")
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertTrue(check["pass"], check)
        self.assertEqual(shots, 2)

    def test_a_frame_with_an_unreadable_marker_is_tried_again(self):
        result, shots = self.run_journey(show=lambda n: "WU" if n == 1 else "W")
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertTrue(check["pass"], check)
        self.assertEqual(shots, 2)

    # Both halves of the seen rule beside an unreadable marker (review 5 of #34071, finding 1).
    def test_the_token_with_the_proof_fails_at_once_even_beside_an_unreadable_marker(self):
        result, shots = self.run_journey(show=lambda n: "WXU" if n == 1 else "W")
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertFalse(check["pass"], check)
        self.assertTrue(check["detail"]["seen"], check)
        self.assertEqual(shots, 1)

    def test_the_token_beside_an_unreadable_marker_without_the_proof_is_tried_again(self):
        result, shots = self.run_journey(show=lambda n: "XU" if n == 1 else "W")
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertTrue(check["pass"], check)
        self.assertEqual(shots, 2)

    def test_no_token_on_any_snapshot_passes(self):
        result, _ = self.run_journey(frames_with_x=set())
        check = next(e for e in result["evidence"] if e["check"] == "frame_marker_lacks")
        self.assertTrue(check["pass"], check)


class LimitTests(unittest.TestCase):
    """The cell and class limits (review 2 of #34071, note 3)."""

    def test_cells_under_four_pixels_are_no_marker(self):
        # A thumbnail of a pane (hover card, tab drag) draws the marker small: under MIN_CELL_PX it is not read.
        with tempfile.TemporaryDirectory() as tmp:
            frame = Frame(200, 40, (0, 0, 0))
            draw_marker(frame, "ok-234567-42", 4, 10, 3, 17)
            self.assertEqual(scan_png(frame, tmp, "small"), [])
            frame = Frame(200, 40, (0, 0, 0))
            draw_marker(frame, "ok-234567-42", 4, 10, 4, 17)
            self.assertEqual([m["digest"] for m in scan_png(frame, tmp, "four") if m["ok"]],
                             [M.token_digest("ok-234567-42")])

    def test_a_channel_between_the_limits_has_no_class(self):
        self.assertEqual(M.row_letters(bytes((128, 128, 128, 255))), b".")
        self.assertEqual(M.row_letters(bytes((160, 96, 160, 255))), b"M")
        self.assertEqual(M.row_letters(bytes((159, 96, 160, 255))), b".")
        self.assertEqual(M.row_letters(bytes((160, 97, 160, 255))), b".")


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
