"""tab_switch_matrix.py on synthetic frames: the page side and the sidebar settle on their own (Leo, 2026-11-18: "we
want that for the sidebar"), --scale parses, and the matrix table marks a scenario over 150 ms p95."""
import os
import random
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_frames as frames_mod  # noqa: E402
import tab_switch_matrix as matrix  # noqa: E402

W, H = 64, 48
FRAME_MS = 1000 / 60
MARK = 10.0
SIDEBAR = (0, 0, 16, H)  # one tile column


def at(ms):
    return MARK + ms / 1000


def textured(seed):
    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(W * H))


def paint(frame, rect, value):
    out = bytearray(frame)
    x0, y0, x1, y1 = rect
    for y in range(y0, y1):
        out[y * W + x0:y * W + x1] = bytes([value]) * (x1 - x0)
    return bytes(out)


def harness():
    h = types.SimpleNamespace(rec=types.SimpleNamespace(w=W, h=H, frame_ms=FRAME_MS), sidebar=SIDEBAR)
    h.between = frames_mod.Harness.between
    return h


class Regions(unittest.TestCase):
    def test_page_and_sidebar_settle_apart(self):
        base = textured(1)
        page_done = paint(base, (32, 16, 48, 32), 0)
        both_done = paint(page_done, (0, 16, 16, 32), 255)
        frames = [(at(-100), base), (at(17), base), (at(50), page_done), (at(120), page_done), (at(200), both_done),
                  (at(900), both_done)]
        switch = {}
        matrix.add_region_settle(harness(), switch, frames, frames, at(-50), MARK, at(1000))
        self.assertAlmostEqual(switch["page_settled_ms"], 50, delta=1)
        self.assertAlmostEqual(switch["sidebar_settled_ms"], 200, delta=1)

    def test_a_region_still_moving_at_the_end_has_no_settled_time(self):
        base = textured(2)
        frames = [(at(-100), base), (at(50), base)]
        for i in range(1, 40):
            frames.append((at(50 + i * 20), paint(base, (40, 0, 56, 16), (i * 37) % 256)))
        switch = {}
        matrix.add_region_settle(harness(), switch, frames, frames, at(-50), MARK, at(50 + 39 * 20 + 100))
        self.assertIsNone(switch["page_settled_ms"])
        self.assertIn("page_settle_note", switch)
        # The sidebar never changed: it was settled at the trigger, not never.
        self.assertEqual(switch["sidebar_settled_ms"], 0.0)


class Scale(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(matrix.parse_scale("leo"), (10789, 206))
        self.assertEqual(matrix.parse_scale("2000x50"), (2000, 50))
        self.assertIsNone(matrix.parse_scale("none"))
        with self.assertRaises(ValueError):
            matrix.parse_scale("huge")


class Table(unittest.TestCase):
    def test_over_budget_and_never_settled(self):
        rows = [{"name": "split", "load": "idle", "switches": [
                    {"settled_ms": 100, "page_settled_ms": 90, "sidebar_settled_ms": None},
                    {"settled_ms": 300, "page_settled_ms": 280, "sidebar_settled_ms": None}]},
                {"name": "new-chat", "load": "idle", "switches": [{"settled_ms": 40, "page_settled_ms": 40,
                                                                   "sidebar_settled_ms": 10}]}]
        lines = {x["scenario"]: x for x in matrix.table(rows)}
        self.assertTrue(lines["split"]["over_budget"])
        self.assertEqual(lines["split"]["settled_p95"], 300)
        self.assertEqual(lines["split"]["sidebar_settled_never"], 2)
        self.assertFalse(lines["new-chat"]["over_budget"])
        text = matrix.table_markdown(list(lines.values()))
        self.assertIn("| split | idle | 2 | 100 / 300 | 90 / 280 | - / - | 0 | no |", text)


if __name__ == "__main__":
    unittest.main()
