"""tab_switch_settle.py on synthetic frames: settled time, what is left out of it (the load's own motion, a blinking
cursor), and each oddity kind the harness logs (Leo, 2026-11-16: "testing it under actual extreme load is the point
and seeing what oddities arise is meaningful")."""
import os
import random
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_judge as judge  # noqa: E402
import tab_switch_settle as settle  # noqa: E402

W, H = 64, 48  # 4 x 3 tiles of 16
FRAME_MS = 1000 / 60
MARK = 10.0


def at(ms):
    return MARK + ms / 1000


def textured(seed):
    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(W * H))


def paint(frame, rect, value):
    """`frame` with the pixel rect (x0, y0, x1, y1) set to `value`."""
    out = bytearray(frame)
    x0, y0, x1, y1 = rect
    for y in range(y0, y1):
        out[y * W + x0:y * W + x1] = bytes([value]) * (x1 - x0)
    return bytes(out)


BASE = textured(1)


class SettledTime(unittest.TestCase):
    def test_settled_is_the_last_change_once_quiet_follows(self):
        frames = [(at(-100), BASE), (at(5), paint(BASE, (0, 0, 16, 16), 0)),
                  (at(20), paint(BASE, (0, 0, 32, 16), 0)), (at(40), paint(BASE, (0, 0, 48, 16), 0))]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(600))
        self.assertEqual(s["settled_ms"], 40.0)
        self.assertEqual(s["first_change_ms"], 5.0)
        self.assertEqual(s["changed_after_first"], 2)
        self.assertIsNone(s["settle_note"])

    def test_still_changing_at_the_end_never_settles(self):
        frames = [(at(-100), BASE)] + [(at(5 + 50 * i), paint(BASE, (0, 0, 16, 16), 10 * i + 10)) for i in range(12)]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(600))
        self.assertIsNone(s["settled_ms"])
        self.assertIn("still changing", s["settle_note"])
        kinds = [o["kind"] for o in settle.oddities({}, s, frame_ms=FRAME_MS)]
        self.assertIn("never-settled", kinds)

    def test_ambient_motion_before_the_action_is_left_out(self):
        # A sidebar spinner (tile 0) turning before and after the mark; the action changes tile 5 once.
        spin = [paint(BASE, (0, 0, 16, 16), 16 * v) for v in range(14)]  # a picture it never showed before
        frames = [(at(-400 + 100 * i), spin[i]) for i in range(4)]
        frames += [(at(5), paint(spin[3], (16, 16, 32, 32), 0))]
        frames += [(at(5 + 60 * i), paint(spin[3 + i], (16, 16, 32, 32), 0)) for i in range(1, 10)]
        windows = [(MARK - settle.AMBIENT_S, MARK)]
        amb = settle.ambient(frames, W, H, windows)
        self.assertEqual(amb, {0})
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(900), ambient_tiles=amb)
        self.assertEqual(s["settled_ms"], 5.0)
        self.assertEqual(s["changed_after_first"], 0)
        self.assertGreater(s["ambient_share"], 0)
        # Without the ambient tiles the spinner keeps the window from settling.
        self.assertIsNone(settle.settle(frames, MARK, W, H, FRAME_MS, end=at(700))["settled_ms"])

    def test_the_tail_of_the_action_before_is_not_ambient(self):
        frames = [(at(-400), textured(7)), (at(-300), BASE), (at(5), paint(BASE, (0, 0, 16, 16), 0))]
        self.assertEqual(settle.ambient(frames, W, H, [(MARK - settle.AMBIENT_S, MARK)]), set())

    def test_a_blinking_cursor_does_not_unsettle(self):
        # The new tab paints with its cursor on, then the cursor goes off and on every 200 ms.
        new = paint(BASE, (0, 0, 64, 16), 0)
        new_on = paint(new, (40, 30, 42, 40), 255)
        frames = [(at(-100), BASE), (at(8), new_on)]
        frames += [(at(8 + 200 * i), new if i % 2 else new_on) for i in range(1, 5)]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(1000))
        self.assertEqual(s["settled_ms"], 8.0)
        self.assertEqual(s["blinks"], 4)
        self.assertEqual(s["changed_after_first"], 0)

    def test_a_cursor_and_a_caret_blinking_together_do_not_unsettle(self):
        # A terminal cursor across two tiles and a caret in a third blink on and off every 600 ms, as a split's
        # terminal and the chat's composer did on a CI mini (2026-11-18): three tiles, more than BLINK_TILES.
        new = paint(BASE, (0, 0, 64, 16), 0)
        on = paint(paint(new, (12, 20, 20, 30), 255), (40, 36, 44, 46), 255)
        frames = [(at(-100), BASE), (at(8), new)]
        frames += [(at(8 + 600 * i), on if i % 2 else new) for i in range(1, 8)]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(6000))
        self.assertEqual(s["settled_ms"], 8.0)
        self.assertEqual(s["changed_after_first"], 0)

    def test_compression_noise_is_no_change(self):
        # The recorder redraws a still window with a few gray levels of noise (a CI mini, 2026-11-18): 1 to 6 levels on
        # every pixel of the window, 3 s after the action, is not a late change.
        new = paint(BASE, (0, 0, 64, 16), 0)
        rng = random.Random(3)
        noisy = bytes(min(255, max(0, v + rng.randint(-6, 6))) for v in new)
        frames = [(at(-100), BASE), (at(8), new), (at(3000), noisy)]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(6000))
        self.assertEqual(s["settled_ms"], 8.0)

    def test_a_change_that_never_returns_still_counts(self):
        # The same three tiles changing to a new picture each time (content still arriving) is no blink.
        new = paint(BASE, (0, 0, 64, 16), 0)
        frames = [(at(-100), BASE), (at(8), new)]
        frames += [(at(8 + 600 * i), paint(new, (12, 20, 44, 46), 40 * i)) for i in range(1, 5)]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(6000))
        self.assertEqual(s["settled_ms"], 2408.0)

    def test_quiet_then_change_again_is_a_late_change(self):
        frames = [(at(-100), BASE), (at(5), paint(BASE, (0, 0, 16, 16), 0)),
                  (at(450), paint(BASE, (0, 0, 64, 16), 0))]
        s = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(1000))
        self.assertEqual(s["late_change_frame"], 1)
        self.assertEqual(s["settled_ms"], 450.0)
        self.assertIn("late-change", [o["kind"] for o in settle.oddities({}, s, frame_ms=FRAME_MS)])

    def test_nothing_changed(self):
        s = settle.settle([(at(-100), BASE), (at(5), BASE)], MARK, W, H, FRAME_MS, end=at(600))
        self.assertIsNone(s["settled_ms"])
        self.assertIn("nothing", s["settle_note"])
        self.assertNotIn("never-settled", [o["kind"] for o in settle.oddities({}, s)])


class Oddities(unittest.TestCase):
    CONTENT = (0, 16, W, H)

    def test_layout_still_changing_after_the_content_is_right(self):
        end = paint(BASE, (0, 16, 64, 48), 200)
        frames = [(at(-100), BASE), (at(5), paint(end, (0, 0, 16, 16), 0)), (at(40), paint(end, (0, 0, 32, 16), 0)),
                  (at(90), paint(end, (0, 0, 48, 16), 0))]
        sw = judge.judge_switch(frames, MARK, W, self.CONTENT, FRAME_MS)
        st = settle.settle(frames, MARK, W, H, FRAME_MS, end=at(700))
        self.assertEqual(sw["to_content_ms"], 5.0)
        self.assertEqual(st["settled_ms"], 90.0)
        odd = settle.oddities(sw, st, frame_ms=FRAME_MS)
        self.assertEqual([(o["kind"], o["frame"]) for o in odd], [("layout-after-content", 2)])

    def test_flicker_content_back_to_a_picture_it_left(self):
        a, b, c = (paint(BASE, self.CONTENT, v) for v in (20, 120, 220))
        frames = [(at(-100), a), (at(5), b), (at(20), a), (at(40), c)]
        self.assertEqual(settle.flicker_frame(frames, MARK, W, self.CONTENT, 0.01), 1)
        self.assertIsNone(settle.flicker_frame([(at(-100), a), (at(5), b), (at(20), c)], MARK, W, self.CONTENT, 0.01))
        kinds = [o["kind"] for o in settle.oddities({}, {}, flicker=1)]
        self.assertEqual(kinds, ["flicker"])

    def test_blank_and_shift_oddities_carry_their_frames(self):
        old, end = textured(2), textured(3)
        blank = bytes([128]) * (W * H)
        frames = [(at(-50), old), (at(8), blank), (at(25), end)]
        sw = judge.judge_switch(frames, MARK, W, (0, 0, W, H), FRAME_MS, reference=end)
        self.assertEqual(sw["first_blank_frame"], 0)
        odd = settle.oddities(sw, {"settled_ms": 25.0}, frame_ms=FRAME_MS)
        self.assertEqual([(o["kind"], o["frame"]) for o in odd], [("blank", 0)])
        shifted = end[:3 * W] + end[:len(end) - 3 * W]
        sw = judge.judge_switch([(at(-50), old), (at(8), shifted), (at(17), end)], MARK, W, (0, 0, W, H), FRAME_MS,
                                reference=end)
        self.assertEqual(sw["first_content_frame"], 0)
        self.assertIn(("shift", 0), [(o["kind"], o["frame"]) for o in settle.oddities(sw, {"settled_ms": 17.0})])


def strip_frame(tabs, height=6):
    rows = bytearray(bytes([40]) * (height * W))
    for x0, x1 in tabs:
        for y in range(1, height - 1):
            rows[y * W + x0:y * W + x1] = bytes([220]) * (x1 - x0)
    return bytes(rows) + BASE[height * W:]


def sidebar_frame(rows_drawn):
    """A frame whose left 16 columns are a sidebar: each workspace row (y0, y1) drawn at 220."""
    out = bytearray(BASE)
    for y in range(H):
        out[y * W:y * W + 16] = bytes([40]) * 16
    for y0, y1 in rows_drawn:
        for y in range(y0, y1):
            out[y * W:y * W + 16] = bytes([220]) * 16
    return bytes(out)


class PlacementAndRetarget(unittest.TestCase):
    STRIP = (0, 0, W, 6)

    def test_placement_names_the_frame_the_tab_first_appeared(self):
        frames = [(at(-50), strip_frame([(0, 10)])), (at(8), strip_frame([(0, 10), (50, 60)])),
                  (at(17), strip_frame([(0, 10), (30, 40)])), (at(25), strip_frame([(0, 10), (10, 20)]))]
        s = judge.judge_strip(frames, MARK, W, self.STRIP, FRAME_MS, px_per_point=0.1)
        self.assertFalse(s["insert_ok"])
        self.assertEqual(s["strip_first_frame"], 0)
        odd = settle.oddities(s, {})
        self.assertIn(("placement", 0), [(o["kind"], o["frame"]) for o in odd])

    def test_retarget_names_the_frame_it_turned_around(self):
        frames = [(at(-50), strip_frame([(0, 10)])), (at(8), strip_frame([(0, 10), (10, 15)])),
                  (at(17), strip_frame([(0, 10), (10, 19)])), (at(25), strip_frame([(0, 10), (10, 13)])),
                  (at(33), strip_frame([(0, 10), (10, 20)]))]
        s = judge.judge_strip(frames, MARK, W, self.STRIP, FRAME_MS, px_per_point=0.1)
        self.assertFalse(s["anim_end_ok"])
        self.assertEqual(s["anim_bad_frame"], 2)
        self.assertEqual(s["anim_bad_why"], "moved away from its final layout")
        self.assertIn(("retarget", 2), [(o["kind"], o["frame"]) for o in settle.oddities(s, {})])

    def test_sidebar_rows_judge_a_new_workspace(self):
        side = (0, 0, 16, H)
        good = [(at(-50), sidebar_frame([(0, 6)])), (at(8), sidebar_frame([(0, 6), (8, 11)])),
                (at(17), sidebar_frame([(0, 6), (8, 14)]))]
        s = judge.judge_strip(good, MARK, W, side, FRAME_MS, px_per_point=0.1, axis="y")
        self.assertTrue(s["insert_ok"])
        bad = [(at(-50), sidebar_frame([(0, 6)])), (at(8), sidebar_frame([(0, 6), (40, 46)])),
               (at(17), sidebar_frame([(0, 6), (8, 14)]))]
        s = judge.judge_strip(bad, MARK, W, side, FRAME_MS, px_per_point=0.1, axis="y")
        self.assertFalse(s["insert_ok"])
        self.assertEqual(judge.sidebar_rect((20, 6, W, H), 0.2, H), (0, 0, 19, H))
        self.assertIsNone(judge.sidebar_rect((5, 6, W, H), 0.2, H))


class TableAndSheet(unittest.TestCase):
    def rows(self, l0, l4, moved=0):
        def sw(ms):
            return {"to_content_ms": 5.0, "settled_ms": ms, "changed_after_first": moved, "first_change_ms": 5.0,
                    "oddities": [{"kind": "retarget", "frame": 2}] if moved else []}
        return [{"name": "new-tab", "load": "L0", "switches": [sw(v) for v in l0], "budget_fail": []},
                {"name": "new-tab", "load": "L4", "switches": [sw(v) for v in l4], "budget_fail": []}]

    def test_pass_rule_is_settled_p95_within_1_2x_of_l0(self):
        lines = settle.table(self.rows([100, 110, 120], [110, 130, 140]))
        self.assertEqual(lines[1]["settled_vs_baseline"], round(140 / 120, 2))
        self.assertTrue(lines[1]["pass"])
        lines = settle.table(self.rows([100, 110, 120], [110, 130, 200]))
        self.assertFalse(lines[1]["pass"])
        lines = settle.table(self.rows([100], [100], moved=3))
        self.assertFalse(lines[0]["pass"])
        self.assertEqual(lines[0]["oddities"], {"retarget": 1})
        md = settle.table_markdown(lines)
        self.assertIn("| new-tab | L4 | 1 |", md)

    def test_oddity_sheet_is_a_png_around_the_frame(self):
        frames = [(at(-50), textured(1)), (at(8), textured(2)), (at(17), textured(3)), (at(25), textured(4))]
        png, tiles = settle.oddity_sheet(frames, MARK, W, H, 1)
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(tiles, [8.0, 17.0, 25.0, "end"])
        width, _height = struct.unpack(">II", png[16:24])
        self.assertEqual(width, 4 * W + 3 * 4)


if __name__ == "__main__":
    unittest.main()
