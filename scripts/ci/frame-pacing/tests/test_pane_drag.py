#!/usr/bin/env python3
"""The judge of pane_drag.py (RFD 0022 item 1) on synthetic traces: input to move, blank frames, layout jumps,
frames over 8.33 ms and the pixel-late count, and the xbench report section that publishes them.
Run: python3 -I scripts/ci/frame-pacing/tests/test_pane_drag.py"""
import json, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "perf-bench"))
import pane_drag as pd  # noqa: E402

R = 1000 / 120


def row(pane, x, y, w, h, alpha=1.0):
    return [pane, x, y, w, h, alpha, 0]


def trace(frames, t0=100.0):
    """`frames`: per display frame, (panes rows, late rows, tabs rows)."""
    return {"t0_s": t0, "refresh_ms": R,
            "samples": [{"t": i * R, "panes": p, "late": l, "tabs": tb, "window": [1600, 1000]}
                        for i, (p, l, tb) in enumerate(frames)]}


BEFORE = [row("a", 0, 0, 800, 1000), row("b", 800, 0, 800, 1000)]
AFTER = [row("a", 0, 0, 800, 1000), row("b", 800, 0, 800, 500), row("c", 800, 500, 800, 500)]


def drop(frames, press_frame=5, up_frame=20, gesture="tab", **extra):
    t0 = 100.0
    return {"gesture": gesture, "kind": "chromium", "what": "split", "trace": trace(frames, t0),
            "press_s": t0 + press_frame * R / 1000 - 0.001, "first_move_s": t0 + (press_frame + 1) * R / 1000 - 0.001,
            "up_s": t0 + up_frame * R / 1000 - 0.001, **extra}


class Judge(unittest.TestCase):
    def test_a_clean_split_lands_in_one_frame_with_no_blank_and_no_jump(self):
        tabs_rest, tabs_lift = [["t1", 0, 100, 1]], [["t1", 0, 100, 0]]
        frames = [(BEFORE, [], tabs_rest)] * 7 + [(BEFORE, [], tabs_lift)] * 14 + [(AFTER, [], tabs_rest)] * 30
        got = pd.judge_drop(drop(frames))
        self.assertTrue(got["landed"])
        self.assertAlmostEqual(got["drop_ms"], 2 * R + 1, delta=0.5)  # sampled the frame after the up, shown at the next vsync
        self.assertEqual(got["blank_frames"], 0)
        self.assertEqual(got["jumps"], 0)
        self.assertEqual(got["panes_after"], 3)
        self.assertAlmostEqual(got["lift_ms"], 1 * R + 1, delta=0.5)

    def test_late_ground_and_a_pop_in_count_as_blank_frames(self):
        late_b = [row("b", 800, 0, 800, 500)]
        only_ab = AFTER[:2]
        frames = [(BEFORE, [], [])] * 21 + [(only_ab, late_b, [])] * 2 + [(AFTER, late_b, [])] + [(AFTER, [], [])] * 20
        got = pd.judge_drop(drop(frames))
        self.assertTrue(got["landed"])
        self.assertEqual(got["blank_frames"], 3)  # two with c missing (and b late), one with b late
        self.assertEqual(got["popin_pane_frames"], 2)

    def test_a_pane_that_moves_after_it_rested_is_a_jump(self):
        moved = [row("a", 0, 0, 800, 1000), row("b", 800, 0, 800, 520), row("c", 800, 520, 800, 480)]
        frames = [(BEFORE, [], [])] * 21 + [(AFTER, [], [])] * 8 + [(moved, [], [])] * 10
        got = pd.judge_drop(drop(frames))
        self.assertEqual(got["jumps"], 2)  # b and c both moved after resting
        self.assertEqual({j[0] for j in got["jumped"]}, {"b", "c"})

    def test_a_held_tick_whose_vsync_is_before_the_up_still_counts_as_the_commit(self):
        # The drop's work held the tick: its vsync time is 0.7 ms before the up, but it shows the new layout.
        frames = [(BEFORE, [], [])] * 20 + [(AFTER, [], [])] * 30
        got = pd.judge_drop(drop(frames, up_frame=20.2))
        self.assertTrue(got["landed"])
        self.assertEqual(got["blank_frames"], 0)

    def test_a_pane_that_pops_in_late_is_blank_not_a_jump(self):
        frames = [(BEFORE, [], [])] * 21 + [(AFTER[:2], [], [])] * 6 + [(AFTER, [], [])] * 20
        got = pd.judge_drop(drop(frames))
        self.assertEqual(got["popin_pane_frames"], 6)
        self.assertEqual(got["jumps"], 0)

    def test_a_drop_with_no_trace_still_counts_as_not_landed(self):
        got = pd.judge_drop({"gesture": "pane", "press_s": 1, "up_s": 2, "trace": {}})
        self.assertEqual(got["gesture"], "pane")
        self.assertEqual(pd.summarize([got])["drops"], 1)

    def test_a_pane_swap_lands_on_the_strips_change(self):
        rest, swapped = [["t1", 0, 100, 1], ["t2", 800, 100, 1]], [["t2", 0, 100, 1], ["t1", 800, 100, 1]]
        frames = [(BEFORE, [], rest)] * 21 + [(BEFORE, [], swapped)] * 20
        got = pd.judge_drop(drop(frames, gesture="pane"))
        self.assertTrue(got["landed"])
        self.assertEqual(got["jumps"], 0)

    def test_stall_stacks_keep_the_apps_frames_longest_first(self):
        hangs = {"records": [{"duration_ms": 40, "kind": "stall", "frames": ["libsystem x", "CmuxNextApp a"]},
                             {"duration_ms": 120.04, "kind": "stall", "frames": ["AppKit y", "CmuxNextBridge b"]}]}
        got = pd.stall_stacks(hangs)
        self.assertEqual([g["ms"] for g in got], [120.0, 40])
        self.assertEqual(got[0]["frames"], ["CmuxNextBridge b"])

    def test_no_layout_change_is_not_landed(self):
        got = pd.judge_drop(drop([(BEFORE, [], [])] * 40))
        self.assertFalse(got["landed"])

    def test_frames_over_budget_split_into_drag_and_drop(self):
        t0 = 100.0
        frames = {"intervals_ms": [R] * 10 + [3 * R] + [R] * 10, "main_ms": [2.0] * 5 + [9.5] + [2.0] * 9 + [12.0] + [2.0] * 5,
                  "first_frame_s": t0, "refresh_ms": R}
        got = pd.frame_phases(frames, press_s=t0, up_s=t0 + 14 * R / 1000)  # the long interval ends at 13 R
        self.assertEqual(got["drag_main_over_8_33"], 1)
        self.assertEqual(got["drop_main_over_8_33"], 1)
        self.assertEqual(got["drag_missed"], 1)
        self.assertEqual(got["drop_missed"], 0)
        self.assertEqual(got["drop_main_max_ms"], 12.0)

    def test_pixel_late_counts_frames_after_rest_that_differ_from_the_final_picture(self):
        width = 200
        head = {"width": width, "height": 100, "rows": [20, 60], "columns": []}
        painted = bytes([10, 20, 30, 255]) * width * 2
        blank = bytes([0, 0, 0, 255]) * width * 2
        frames = [(1.0, painted), (1.1, painted), (2.0, blank), (2.1, blank), (2.2, painted), (2.3, painted)]
        got = pd.pixel_late(head, frames, 1.0, {"a": (0, 0, 200, 100, 1)}, after_s=1.5, rest_rects={"a": (0, 0, 200, 100, 1)},
                            before_s=1.5)
        self.assertEqual(got["pixel_late_frames"], 2)
        self.assertEqual(got["pixel_noise_frames"], 0)

    def test_summary_and_report_section(self):
        frames = [(BEFORE, [], [])] * 21 + [(AFTER, [], [])] * 30
        each = [pd.judge_drop(drop(frames)) for _ in range(2)]
        summary = pd.summarize(each)
        self.assertEqual(summary["landed"], 2)
        self.assertEqual(summary["blank_frames_per_drop"], 0)
        # procs.py loads /usr/lib/libproc.dylib at import (macOS only): an empty module stands in on Linux, for this
        # import only (as scripts/perf-bench/tests/test_keep_movies.py does).
        import types
        stub = None
        try:
            import procs  # noqa: F401
        except OSError:
            stub = sys.modules["procs"] = types.ModuleType("procs")
        try:
            import xbench  # noqa: E402
        finally:
            if stub is not None and sys.modules.get("procs") is stub:
                del sys.modules["procs"]
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "pane-drag.json")
            json.dump({"counts": [{"asked": 2, "setup": {"panes": 2}, "tab": summary, "pane": {"drops": 0, "each": [{"error": "x"}]}}],
                       "theirs": pd.theirs()}, open(path, "w"))
            rows, lines = xbench.pane_drag_rows(path)
        text = "\n".join(lines)
        self.assertIn("| Tab drag | 2 | 2/2 |", text)
        self.assertIn("Pane header drag | 2 | not run: x", text)
        self.assertIn("Claude Code desktop", text)
        self.assertIn("pane-drag-tab-2-input-to-move", rows)


if __name__ == "__main__":
    unittest.main()
