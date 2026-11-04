#!/usr/bin/env python3
"""bench-terminal-resize.py measures a session it built, or fails (FRAME OWNER S4 ON bench, cmux22, 2026-11-04).

The terminal-resize suite (split-spring.sh --suite=terminal-resize) launched the `split-spring` tag's app with the
worker's real HOME, so the app restored the tag's saved session from earlier runs on that mini, and each run's light
layout added a workspace: STRESS then refused ("the app already has 61 workspaces; STRESS has 60 in all"), and the
light layout dragged a divider while something else showed in front, so no terminal resized or drew (resized_terminals
0 and every render counter 0 in all 3 rounds). The script exited 0 either way, so the zeros read like results.

1. bench_launch.start_fresh_state(tag) moves only that tag's saved state aside (`<root>.bench-prev`), keeps its Debug
   Settings file, and never touches another tag's state.
2. terminal_resize_verdict.problems(result) names a drag layout (light, stress) in which no terminal resized, no
   frame was counted or no terminal drew, and a split-resize layout that resized no terminal; a layout that measured
   passes, and idle-cursor has no resize to check.

No app and no GUI: the state root is under a temporary base (BENCH_LAUNCH_STATE_BASE), and the results are data.

    python3 scripts/cmux-next/tests/test_bench_terminal_resize.py
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
# No test moves a real tag's saved state: every tag root is under a temporary base.
os.environ["BENCH_LAUNCH_STATE_BASE"] = tempfile.mkdtemp(prefix="bench-terminal-resize-state-")
import bench_launch as bl  # noqa: E402
import terminal_resize_verdict as verdict  # noqa: E402


def write(path: Path, text: str = "x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class FreshState(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="state-base-"))
        os.environ["BENCH_LAUNCH_STATE_BASE"] = str(self.base)

    def test_only_the_tags_state_moves_aside_and_its_debug_settings_stay(self):
        tags = self.base / "tags"
        write(tags / "split-spring/tui/sessions/61-workspaces.json", "61")
        write(tags / "split-spring/debug-tunables.json", '{"motion.frameOwner.terminals": true}')
        write(tags / "other-tag/tui/sessions/keep.json", "keep")
        write(tags / "split-spring-2/tui/sessions/keep.json", "keep")

        bl.start_fresh_state("split-spring")

        self.assertFalse((tags / "split-spring/tui").exists(), "the tag's saved session is still where the app restores it")
        self.assertEqual((tags / "split-spring.bench-prev/tui/sessions/61-workspaces.json").read_text(), "61")
        self.assertEqual((tags / "split-spring/debug-tunables.json").read_text(), '{"motion.frameOwner.terminals": true}')
        self.assertEqual((tags / "other-tag/tui/sessions/keep.json").read_text(), "keep")
        self.assertEqual((tags / "split-spring-2/tui/sessions/keep.json").read_text(), "keep")

    def test_a_second_run_keeps_one_earlier_state(self):
        tags = self.base / "tags"
        write(tags / "split-spring/tui/run-1")
        bl.start_fresh_state("split-spring")
        write(tags / "split-spring/tui/run-2")
        bl.start_fresh_state("split-spring")
        self.assertTrue((tags / "split-spring.bench-prev/tui/run-2").exists())
        self.assertFalse((tags / "split-spring.bench-prev/tui/run-1").exists())

    def test_no_state_is_no_change(self):
        bl.start_fresh_state("split-spring")
        self.assertFalse((self.base / "tags").exists())

    def test_the_bench_app_uses_the_same_root(self):
        self.assertEqual(bl.tag_state_root("split-spring"), str(self.base / "tags/split-spring"))


def drag_round(resized=2, frames=120, drawn=40):
    return {"terminals": 2, "resized_terminals": resized, "frames": {"frames": frames},
            "counters": {"frames": drawn}}


class Verdict(unittest.TestCase):
    def test_cmux22_light_layout_with_nothing_resized_fails(self):
        # Job e37ade05 on cmux22: all 3 rounds resized nothing and every render counter stayed 0.
        result = {"layout": "light", "rounds": [drag_round(0, 240, 0)] * 3}
        found = verdict.problems(result)
        self.assertTrue(found, "a light layout in which no terminal resized passed")
        self.assertIn("resized", " ".join(found))

    def test_a_drag_layout_with_no_frame_counted_fails(self):
        self.assertTrue(verdict.problems({"layout": "stress", "rounds": [drag_round(frames=0)]}))
        self.assertTrue(verdict.problems({"layout": "stress", "rounds": [drag_round(frames=None)]}))

    def test_a_drag_layout_in_which_no_terminal_drew_fails(self):
        self.assertTrue(verdict.problems({"layout": "light", "rounds": [drag_round(drawn=0)]}))

    def test_a_layout_error_or_no_round_fails(self):
        self.assertTrue(verdict.problems({"layout": "light", "error": "no vertical divider"}))
        self.assertTrue(verdict.problems({"layout": "stress", "rounds": []}))

    def test_split_resize_that_resized_nothing_fails(self):
        self.assertTrue(verdict.problems({"layout": "split-resize", "rounds": [{"resized_terminals": 3}, {"resized_terminals": 0}]}))
        self.assertTrue(verdict.problems({"layout": "split-resize-stress", "rounds": []}))
        self.assertFalse(verdict.problems({"layout": "split-resize", "rounds": [{"resized_terminals": 3}]}))

    def test_measured_layouts_pass(self):
        self.assertEqual(verdict.problems({"layout": "light", "rounds": [drag_round(), drag_round()]}), [])
        self.assertEqual(verdict.problems({"layout": "stress", "rounds": [drag_round(resized=18)]}), [])
        self.assertEqual(verdict.problems({"layout": "idle-cursor", "frames": 0}), [])


if __name__ == "__main__":
    unittest.main()
