"""tab_switch_judge.py on synthetic frames: each budget catches the shape it names, and a clean switch passes."""
import json
import os
import random
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_judge as judge  # noqa: E402

W, H = 40, 30
FRAME_MS = 1000 / 120
FULL = (0, 0, W, H)


def textured(seed):
    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(W * H))


def flat(value=128):
    return bytes([value]) * (W * H)


def shifted_down(frame, rows):
    return frame[:rows * W] + frame[:len(frame) - rows * W]


MARK = 10.0


def at(ms):
    return MARK + ms / 1000


class ReturnSwitch(unittest.TestCase):
    def setUp(self):
        self.old, self.end = textured(1), textured(2)

    def test_instant_switch_passes(self):
        frames = [(at(-50), self.old), (at(5), self.end)]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end)
        self.assertEqual(s["to_content_ms"], 5.0)
        self.assertEqual((s["blank_frames"], s["wrong_frames"], s["shift_px"]), (0, 0, 0))
        self.assertEqual(judge.budget_fails(s, "x"), [])

    def test_late_content_fails_one_frame_budget(self):
        frames = [(at(-50), self.old), (at(30), self.end)]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end)
        self.assertEqual(s["to_content_ms"], 30.0)
        self.assertTrue(any("budget one display frame" in f for f in judge.budget_fails(s, "x")))

    def test_blank_frames_counted_in_display_frames(self):
        frames = [(at(-50), self.old), (at(8), flat()), (at(25), self.end)]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end)
        self.assertEqual(s["blank_frames"], 2)
        self.assertEqual(s["wrong_frames"], 0)
        self.assertTrue(any("blank" in f for f in judge.budget_fails(s, "x")))

    def test_wrong_intermediate_frame(self):
        composer = textured(3)  # neither the old tab nor the transcript: an empty composer in the middle
        frames = [(at(-50), self.old), (at(8), composer), (at(17), self.end)]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end)
        self.assertEqual(s["wrong_frames"], 1)
        self.assertEqual(s["blank_frames"], 0)

    def test_layout_shift_measured(self):
        frames = [(at(-50), self.old), (at(8), shifted_down(self.end, 3)), (at(17), self.end)]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end, px_per_point=1.0)
        self.assertEqual(s["shift_px"], 3)
        self.assertTrue(any("moved" in f for f in judge.budget_fails(s, "x")))

    def test_never_reached_reference(self):
        frames = [(at(-50), self.old), (at(8), textured(9))]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end)
        self.assertIsNone(s["to_content_ms"])
        self.assertFalse(s["end_matches_reference"])
        self.assertTrue(any("never showed" in f for f in judge.budget_fails(s, "x")))

    def test_old_tab_lag_is_not_a_wrong_frame(self):
        frames = [(at(-50), self.old), (at(3), self.old), (at(12), self.end)]
        s = judge.judge_switch(frames, MARK, W, FULL, FRAME_MS, reference=self.end)
        self.assertEqual((s["wrong_frames"], s["blank_frames"]), (0, 0))
        self.assertEqual(s["to_content_ms"], 12.0)


def strip_frame(tabs, content_seed=5):
    """A frame whose top 6 rows are a tab strip: background 40, each tab (x0, x1) drawn at 220."""
    rows = bytearray(flat(40)[:6 * W])
    for x0, x1 in tabs:
        for y in range(1, 5):
            for x in range(x0, x1):
                rows[y * W + x] = 220
    return bytes(rows) + textured(content_seed)[6 * W:]


class StripJudgement(unittest.TestCase):
    STRIP, CONTENT = (0, 0, W, 6), (0, 6, W, H)

    def judge(self, frames):
        return judge.judge_switch(frames, MARK, W, self.CONTENT, FRAME_MS, strip=self.STRIP, px_per_point=0.1)

    def test_insert_in_place_and_grow(self):
        frames = [(at(-50), strip_frame([(0, 10)], 5)),
                  (at(8), strip_frame([(0, 10), (10, 14)], 6)),
                  (at(17), strip_frame([(0, 10), (10, 17)], 6)),
                  (at(25), strip_frame([(0, 10), (10, 20)], 6))]
        s = self.judge(frames)
        self.assertTrue(s["insert_ok"])
        self.assertTrue(s["anim_end_ok"])

    def test_insert_at_the_end_then_sliding_fails(self):
        frames = [(at(-50), strip_frame([(0, 10)], 5)),
                  (at(8), strip_frame([(0, 10), (30, 40)], 6)),
                  (at(17), strip_frame([(0, 10), (20, 30)], 6)),
                  (at(25), strip_frame([(0, 10), (10, 20)], 6))]
        s = self.judge(frames)
        self.assertFalse(s["insert_ok"])
        self.assertTrue(any("appears where" in f for f in judge.budget_fails(s, "x")))

    def test_rest_off_layout_then_snap_fails(self):
        frames = [(at(-50), strip_frame([(0, 10)], 5)),
                  (at(8), strip_frame([(0, 10), (10, 16)], 6)),
                  (at(60), strip_frame([(0, 10), (10, 20)], 6))]  # held 52 ms off its layout, then snapped
        s = self.judge(frames)
        self.assertFalse(s["anim_end_ok"])


class ReportAndSheet(unittest.TestCase):
    def test_report_schema(self):
        ok = {"to_content_ms": 4.0, "display_frame_ms": 8.333, "blank_frames": 0, "wrong_frames": 0, "shift_px": 0,
              "insert_ok": None, "anim_end_ok": None}
        bad = dict(ok, blank_frames=3)
        rows = [judge.scenario_row("chat-long-return", "idle", [ok]), judge.scenario_row("chat-long-return", "cpu", [bad])]
        out = json.loads(json.dumps(judge.report("abc", 120, rows)))
        self.assertEqual(out["schema"], "tab-switch/v1")
        self.assertEqual(set(out), {"schema", "build", "display_hz", "scenarios", "pass"})
        self.assertFalse(out["pass"])
        self.assertEqual(out["scenarios"][0]["budget_fail"], [])
        self.assertEqual(len(out["scenarios"][1]["budget_fail"]), 1)
        for key in ("to_content_ms", "display_frame_ms", "blank_frames", "wrong_frames", "shift_px", "insert_ok", "anim_end_ok"):
            self.assertIn(key, out["scenarios"][0]["switches"][0])
        self.assertTrue(judge.report("abc", 120, rows[:1])["pass"])
        self.assertFalse(judge.report("abc", 120, [])["pass"])

    def test_contact_sheet_is_a_png(self):
        frames = [(at(-50), textured(1)), (at(8), flat()), (at(17), textured(2))]
        png, tiles = judge.contact_sheet(frames, MARK, W, H, reference=textured(2))
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        width, height = struct.unpack(">II", png[16:24])
        self.assertEqual((width, height), (4 * W + 3 * 4, H))
        idat = png.index(b"IDAT")
        (length,) = struct.unpack(">I", png[idat - 4:idat])
        self.assertEqual(len(zlib.decompress(png[idat + 4:idat + 4 + length])), height * (width + 1))
        self.assertEqual(tiles, [-50.0, 8.0, 17.0, "end"])

    def test_segment_round_trip(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "seg.bin")
            with open(path, "wb") as handle:
                for t, g in ((2.0, textured(2)), (1.0, textured(1))):
                    handle.write(struct.pack("<d", t) + g)
            frames = judge.read_segment(path, W, H)
        self.assertEqual([t for t, _ in frames], [1.0, 2.0])
        self.assertEqual(frames[0][1], textured(1))

    def test_content_rect_from_two_tabs(self):
        terminal = bytearray(flat(20))
        page = bytearray(flat(20))
        for y in range(8, 28):
            for x in range(5, 38):
                page[y * W + x] = 200
        self.assertEqual(judge.content_rect(bytes(terminal), bytes(page), W, H), (5, 8, 38, 28))
        self.assertIsNone(judge.content_rect(bytes(terminal), bytes(terminal), W, H))
        self.assertEqual(judge.strip_rect((5, 8, 38, 28), 0.2, H), (5, 0, 38, 8))


if __name__ == "__main__":
    unittest.main()
