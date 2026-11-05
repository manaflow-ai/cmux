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

3. A drag or key resize fails when a terminal does not change size with its pane (Lead, cmux-ad m16 (b), 2026-11-05):
   each round's pane check (`debug.terminal_display`, ``follow``) counts per terminal the frames in which its host asked
   another size than its pane's (held) and in which its layer showed another size (lagging). A held frame fails the
   round, and the message names the terminal, its held frames and the first sizes; lagging frames are data only. A
   held drag (`terminalDrag.holdSurface`, on by default since #32006) used to pass on laid-out views: it fails now. A
   round with no pane check fails: it judged nothing.
4. The key-resize layouts (keys, keys-stress) need a resized terminal and a counted frame in each round, and a round
   whose arm the bench could not set (`debug.tunables set`) fails; terminal_resize_arms alternates the arm order per
   round and pools each arm's per-frame data into p50/p95/p99/max.

5. A terminal resized when its full rebuilds for a new grid grew: full_resize (the drawn grid changed size) or
   full_swap (the reflow preview started or ended: a held grid's new size). Job b5834b1d on cmux24 counted only
   full_resize, which stays 0 in a key resize (full_swap grew by the grids sent), so every keys round and both probes
   failed although the terminals resized.

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

    def test_a_shipped_channels_state_never_moves(self):
        tags = self.base / "tags"
        for channel in ("nightly", "rc", "staging", "cmux-next", "NIGHTLY", "Staging"):
            write(tags / channel / "tui/sessions/mine.json", "mine")
            bl.start_fresh_state(channel)
            self.assertEqual((tags / channel / "tui/sessions/mine.json").read_text(), "mine", f"{channel}'s state moved")
            self.assertFalse((tags / f"{channel}.bench-prev").exists())

    def test_no_state_is_no_change(self):
        bl.start_fresh_state("split-spring")
        self.assertFalse((self.base / "tags").exists())

    def test_the_bench_app_uses_the_same_root(self):
        self.assertEqual(bl.tag_state_root("split-spring"), str(self.base / "tags/split-spring"))


def followed(held=0, frames=120, lagging=0, key="tab-1", first=None):
    """One terminal's pane check, as DebugTerminalPaneFollow reports it."""
    first = first if first is not None else [{"frame": 3, "area": [590, 400], "asked": [600, 400], "shown": [600, 400]}][:held]
    return {key: {"frames": frames, "held": held, "lagging": lagging, "first_held": first, "first_lagging": []}}


def pane_check(*terminals, frames=120):
    """A round's `follow` from its stop reply (terminal_resize_verdict.follow)."""
    merged = {}
    for terminal in terminals or (followed(frames=frames),):
        merged.update(terminal)
    return verdict.follow({"follow_frames": frames, "terminals_followed": merged})


def drag_round(resized=2, frames=120, drawn=40, follow=None):
    return {"terminals": 2, "resized_terminals": resized, "frames": {"frames": frames},
            "counters": {"frames": drawn}, "follow": follow or pane_check()}


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
        # An error fails even with measured rounds, and in a layout with no resize to check.
        found = verdict.problems({"layout": "light", "error": "no vertical divider", "rounds": [drag_round()]})
        self.assertEqual(found, ["light: no vertical divider"])
        self.assertEqual(verdict.problems({"layout": "idle-cursor", "error": "no terminal"}), ["idle-cursor: no terminal"])
        self.assertTrue(verdict.problems({"layout": "stress", "rounds": []}))

    def test_split_resize_that_resized_nothing_fails(self):
        self.assertTrue(verdict.problems({"layout": "split-resize", "rounds": [{"resized_terminals": 3}, {"resized_terminals": 0}]}))
        self.assertTrue(verdict.problems({"layout": "split-resize-stress", "rounds": []}))
        self.assertFalse(verdict.problems({"layout": "split-resize", "rounds": [{"resized_terminals": 3}]}))

    def test_measured_layouts_pass(self):
        self.assertEqual(verdict.problems({"layout": "light", "rounds": [drag_round(), drag_round()]}), [])
        self.assertEqual(verdict.problems({"layout": "stress", "rounds": [drag_round(resized=18)]}), [])
        self.assertEqual(verdict.problems({"layout": "idle-cursor", "frames": 0}), [])



def held_round(view_layouts=480, frames=240):
    """A round of a drag whose terminals held (cmux24, 2026-11-04): no resize, no terminal frame, the views laid out,
    and the pane check counting every frame after the first as held."""
    return {"terminals": 2, "resized_terminals": 0, "frames": {"frames": frames, "view_layouts": view_layouts},
            "counters": {"frames": 0}, "holds_terminals": True,
            "follow": pane_check(followed(held=frames - 1, frames=frames, lagging=frames - 1, key="left"),
                                 followed(held=frames - 1, frames=frames, lagging=frames - 1, key="right"), frames=frames)}


class PaneCheck(unittest.TestCase):
    def test_a_held_drag_fails_and_names_the_terminal_its_frames_and_sizes(self):
        # Jobs b945a41d (OFF) and a88aa2f9 (ON) on cmux24: terminalDrag.holdSurface kept both terminals through the drag
        # and the layout passed on laid-out views. It fails now.
        result = {"layout": "light", "drag_holds_terminals": True, "probe": {"ok": True, "moved_pt": -40.0, "resized_terminals": 2},
                  "rounds": [held_round()]}
        found = verdict.problems(result)
        self.assertTrue(found, "a held drag passed")
        held = found[0]
        self.assertIn("2 of 2 terminals did not change size with their pane in the drag", held)
        self.assertIn("left held 239 of 240 frames", held)
        self.assertIn("frame 3: pane 590x400, asked 600x400, shown 600x400", held)

    def test_a_held_key_resize_fails_per_arm(self):
        on = key_round(arm=True)
        off = dict(key_round(arm=False), follow=pane_check(followed(held=30, frames=150, key="bottom-left")))
        found = verdict.problems({"layout": "keys", "rounds": [off, on]})
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("keys round 1 (off): 1 of 1 terminals"), found[0])

    def test_lagging_frames_are_data_only(self):
        lagging = drag_round(follow=pane_check(followed(lagging=4)))
        self.assertEqual(verdict.problems({"layout": "stress", "rounds": [lagging]}), [])
        self.assertEqual(lagging["follow"]["lagging_frames"], 4)

    def test_a_round_with_no_pane_check_fails(self):
        # A build without the pane check, or no terminal shown at the round's start: nothing judged the rule.
        for follow in (None, verdict.follow({}), verdict.follow({"follow_frames": 0, "terminals_followed": {}})):
            entry = dict(drag_round(), follow=follow)
            found = verdict.problems({"layout": "light", "rounds": [entry]})
            self.assertTrue(found and "checked against its pane" in found[0], found)
        entry = dict(drag_round(), follow=pane_check(followed(frames=0), frames=0))
        self.assertIn("sampled no frame", verdict.problems({"layout": "light", "rounds": [entry]})[0])

    def test_follow_takes_the_check_out_of_the_stop_reply(self):
        display = {"calls": 12, "follow_frames": 90,
                   "terminals_followed": {**followed(held=2, frames=90, lagging=5, key="a"), **followed(frames=90, lagging=1, key="b")}}
        checked = verdict.follow(display)
        self.assertEqual(display, {"calls": 12}, "the per-terminal record moves to the round's `follow`")
        self.assertEqual((checked["frames"], checked["held_frames"], checked["held_terminals"], checked["lagging_frames"]), (90, 2, 1, 6))
        self.assertIsNone(verdict.follow({"calls": 3}))

    def test_holds_terminals_is_data(self):
        # A round's holds_terminals no longer excuses it, and a round that did not hold is judged as any other.
        resized = dict(drag_round(), holds_terminals=True)
        self.assertEqual(verdict.problems({"layout": "light", "drag_holds_terminals": True, "rounds": [resized]}), [])

    def test_a_probe_that_did_not_move_the_divider_fails(self):
        result = {"layout": "light", "error": "probe: the probe drag did not move the divider (moved 0.0 pt of -40)"}
        self.assertEqual(verdict.problems(result), [f"light: {result['error']}"])


def key_round(arm=False, resized=4, frames=150, drawn=60):
    return {"arm": arm, "terminals": 4, "resized_terminals": resized, "frames": {"frames": frames},
            "counters": {"frames": drawn}, "presses": [{"action": "resizePaneRight", "max_grids_per_terminal": 1}],
            "follow": pane_check(frames=frames)}


class KeyLayouts(unittest.TestCase):
    def test_a_key_resize_that_resized_nothing_fails(self):
        found = verdict.problems({"layout": "keys", "rounds": [key_round(), key_round(arm=True, resized=0)]})
        self.assertEqual(len(found), 1, found)
        self.assertIn("no terminal resized in the key resize", found[0])
        self.assertIn("(on)", found[0])

    def test_a_round_whose_arm_was_not_set_fails(self):
        entry = {"arm": True, "error": "debug.tunables set motion.frameOwner.terminals=True answered {'error': 'unknown key'}"}
        found = verdict.problems({"layout": "keys-stress", "rounds": [entry]})
        self.assertEqual(len(found), 1)
        self.assertIn("unknown key", found[0])

    def test_measured_key_layouts_pass(self):
        self.assertEqual(verdict.problems({"layout": "keys", "rounds": [key_round(), key_round(arm=True)]}), [])
        self.assertEqual(verdict.problems({"layout": "keys-stress", "rounds": [key_round(resized=6)]}), [])


def surface_row(ident, full_resize=0, full_swap=0, fit="80x24"):
    return {"id": ident, "fit": fit, "counters": {"full_resize": full_resize, "full_swap": full_swap}}


class ResizeCount(unittest.TestCase):
    def test_cmux24_key_resize_shows_as_a_swap(self):
        # Job b5834b1d on cmux24 (8c981e32979): in every keys round full_resize stayed 0 and full_swap grew by the grids
        # sent (4 terminals x 2 presses): a held grid's new size draws through the reflow preview (a swap).
        before = [surface_row(f"p{i}/t") for i in range(4)]
        after = [surface_row(f"p{i}/t", full_swap=2) for i in range(4)]
        self.assertEqual(verdict.resized(before, after), 4)

    def test_a_grid_change_counts_once_per_terminal(self):
        before = [surface_row("a/t", 3, 1), surface_row("b/t", 0, 0), surface_row("c/t", 5, 5)]
        after = [surface_row("a/t", 4, 1), surface_row("b/t", 1, 1), surface_row("c/t", 5, 5), surface_row("new/t", 9, 9)]
        self.assertEqual(verdict.resized(before, after), 2, "a, b resized; c did not; a terminal only in `after` is not paired")


class Arms(unittest.TestCase):
    def setUp(self):
        import terminal_resize_arms
        self.arms = terminal_resize_arms

    def test_the_arm_order_alternates_per_round(self):
        self.assertEqual(self.arms.order(0, "motion.frameOwner.terminals"), [False, True])
        self.assertEqual(self.arms.order(1, "motion.frameOwner.terminals"), [True, False])
        self.assertEqual(self.arms.order(2, "motion.frameOwner.terminals"), [False, True])
        self.assertEqual(self.arms.order(0, None), [None])
        self.assertEqual([self.arms.label(a) for a in (None, False, True)], ["build", "off", "on"])

    def test_distribution_is_nearest_rank(self):
        found = self.arms.distribution(list(range(100, 0, -1)))
        self.assertEqual(found, {"n": 100, "p50": 51, "p95": 95, "p99": 99, "max": 100})
        self.assertIsNone(self.arms.distribution([]))
        self.assertEqual(self.arms.motion([1.0, 5.0, 0.5], [0, 3, 0]), [5.0])
        self.assertEqual(self.arms.motion([1.0], [0, 3]), [])

    def test_summaries_pool_each_arm(self):
        def entry(arm, intervals, main, grids, held=0):
            return {"arm": arm, "frames": {"frames": len(intervals), "missed": sum(i > 12.5 for i in intervals)},
                    "raw": {"intervals_ms": intervals, "main_ms": main, "motion_main_ms": main[:1]},
                    "presses": [{"action": "resizePaneRight", "max_grids_per_terminal": g} for g in grids],
                    "held_frames": held, "lagging_frames": held + 1}
        rounds = [entry(False, [8.3, 8.3], [1.0, 2.0], [1, 1], held=7), entry(True, [8.3, 16.7], [3.0, 4.0], [1, 2]),
                  entry(True, [8.3], [5.0], [1]), entry(False, [8.3], [0.5], [0], held=2), {"arm": True, "error": "not set"}]
        found = self.arms.summaries(rounds)
        self.assertEqual(sorted(found), ["off", "on"])
        self.assertEqual((found["on"]["rounds"], found["on"]["frames"], found["on"]["missed"]), (2, 3, 1))
        self.assertEqual(found["on"]["main_ms"]["max"], 5.0)
        self.assertEqual(found["on"]["motion_main_ms"]["n"], 2)
        self.assertEqual((found["on"]["max_grids_per_press"], found["on"]["presses_over_one_grid"]), (2, 1))
        self.assertEqual((found["off"]["rounds"], found["off"]["main_ms"]["p50"], found["off"]["presses_over_one_grid"]), (2, 1.0, 0))
        self.assertEqual((found["off"]["held_frames"], found["off"]["held_rounds"], found["off"]["lagging_frames"]), (9, 2, 11))
        self.assertEqual((found["on"]["held_frames"], found["on"]["held_rounds"], found["on"]["lagging_frames"]), (0, 0, 2))


class MissedSplit(unittest.TestCase):
    def test_each_arm_counts_its_missed_refreshes_per_cause(self):
        # frame-owner-s4, 2026-11-05: Instruments' Animation Hitches records nothing on the virtual display, so
        # debug.frames splits each missed refresh by cause from cmux's own stamps; each arm sums the causes.
        import terminal_resize_arms as arms
        def entry(arm, split):
            return {"arm": arm, "frames": {"frames": 10, "missed": sum(split.values()), "missed_split": split}, "raw": {}}
        rounds = [entry(False, {"main_late": 2, "commit_late": 1, "presented_late": 0}),
                  entry(False, {"main_late": 1, "commit_late": 0, "presented_late": 3}),
                  entry(True, {"main_late": 0, "commit_late": 0, "presented_late": 1})]
        found = arms.summaries(rounds)
        self.assertEqual(found["off"]["missed_split"], {"main_late": 3, "commit_late": 1, "presented_late": 3})
        self.assertEqual(found["on"]["missed_split"], {"main_late": 0, "commit_late": 0, "presented_late": 1})

    def test_the_round_keeps_the_split_from_debug_frames(self):
        frames = {"frames": 10, "missed": 1, "missed_split": {"main_late": 1, "commit_late": 0, "presented_late": 0},
                  "missed_frames": [{"at_ms": 40.0, "interval_ms": 16.7, "next_tick_after_target_ms": 8.3, "cause": "main_late"}]}
        source = (HERE / "bench-terminal-resize.py").read_text()
        keys = source[source.index("FRAME_KEYS = "):source.index("\n\n", source.index("FRAME_KEYS = "))]
        namespace = {}
        exec(keys, namespace)
        self.assertIn("missed_split", namespace["FRAME_KEYS"])
        self.assertIn("missed_frames", namespace["FRAME_KEYS"])
        self.assertEqual({k: frames.get(k) for k in namespace["FRAME_KEYS"]}["missed_split"]["main_late"], 1)


if __name__ == "__main__":
    unittest.main()
