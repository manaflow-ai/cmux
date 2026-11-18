#!/usr/bin/env python3
"""pane-perf-terminal.py's row inputs, from synthetic `debug.motion` samples and window states.

Run: python3 -I scripts/cmux-next/tests/test_pane_perf_rows.py
No app, display or subprocess is run: the definitions are loaded without the script's top-level app launch.
- moving_frames: New Column moves only the strip camera (column-scroll.md R3b), so a count of the pane and divider
  springs alone (`layout.travel`) read 0 for every New Column (BENCH BASE REDS 3).
- not_applicable: a one-column layout (1x2) has no vertical divider, so its drag is not applicable, not a FAIL.
- activate: the bench opens its bundle through LaunchServices and waits for a key window.
"""
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]


def definitions(path, names):
    """Load selected definitions without executing an app driver's launch block."""
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    missing = set(names) - {node.name for node in nodes}
    assert not missing, f"pane-perf-terminal.py lacks {sorted(missing)}"
    return compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")


BENCH = definitions(ROOT / "pane-perf-terminal.py", {"moving_frames", "not_applicable", "activate", "commit_frames",
                                                    "late_frames", "motion_arms"})


def loaded(**extra):
    namespace = dict(extra)
    exec(BENCH, namespace)
    return namespace


def frames(*pairs, camera=True):
    """One step per (travel, camera) pair, in the order ScreenContentView.step samples them."""
    samples = [{"name": "clock.dt_ms", "v": 8.33}]
    for travel, shift in pairs:
        samples.append({"name": "layout.travel", "v": travel})
        if camera:
            samples.append({"name": "layout.camera", "v": shift})
    return samples


class MovingFrames(unittest.TestCase):
    def setUp(self):
        self.moving_frames = loaded()["moving_frames"]

    def test_a_new_column_counts_the_frames_its_camera_moves(self):
        # The pane-perf red: New Column, no pane or divider spring, the camera on its spring for 4 frames.
        self.assertEqual(self.moving_frames(frames((0, 830), (0, 400), (0, 120), (0, 0.3), (0, 0))), 4)

    def test_a_split_counts_its_spring_frames(self):
        self.assertEqual(self.moving_frames(frames((600, 0), (200, 0), (10, 0), (0, 0))), 3)

    def test_a_frame_that_moves_both_counts_once(self):
        self.assertEqual(self.moving_frames(frames((50, 50), (0, 0))), 1)

    def test_a_build_without_the_camera_sample_counts_the_springs(self):
        self.assertEqual(self.moving_frames(frames((600, 0), (0, 0), camera=False)), 1)
        self.assertEqual(self.moving_frames(frames((0, 830), camera=False)), 0)

    def test_a_camera_sample_of_another_frame_is_not_paired(self):
        # A camera value only counts right after its own frame's travel sample.
        samples = [{"name": "layout.camera", "v": 500}, {"name": "layout.travel", "v": 0},
                   {"name": "clock.dt_ms", "v": 8.3}, {"name": "layout.camera", "v": 500}]
        self.assertEqual(self.moving_frames(samples), 0)

    def test_no_samples(self):
        for samples in (None, [], {}, [None, 3]):
            self.assertEqual(self.moving_frames(samples), 0)


class CommitFrames(unittest.TestCase):
    def setUp(self):
        self.commit_frames = loaded()["commit_frames"]

    def test_each_tick_with_a_pane_in_flight_counts(self):
        samples = [{"name": "clock.dt_ms", "v": 8.33}, {"name": "layout.commit", "v": 16}, {"name": "layout.travel", "v": 0},
                   {"name": "layout.commit", "v": 16}, {"name": "layout.commit", "v": 2}, {"name": "layout.commit", "v": 0}]
        self.assertEqual(self.commit_frames(samples), 3)

    def test_a_build_without_the_sample_counts_none(self):
        self.assertEqual(self.commit_frames(frames((600, 0), (200, 0), (0, 0))), 0)
        for samples in (None, [], {}, [None, 3]):
            self.assertEqual(self.commit_frames(samples), 0)


def probe(**changed):
    """A `debug.frames` reply at 120 Hz with two long intervals: one of 2 refreshes that holds the action's send (20 ms
    after the first frame) and one of 6 refreshes after it."""
    reply = {"refresh_ms": 8.333, "missed": 2, "first_frame_s": 100.0, "main_max_ms": 12.5,
             "intervals_ms": [8.33, 8.33, 16.67, 8.33, 50.42, 8.33], "missed_at_ms": [33.0, 92.0],
             "missed_split": {"main_late": 1, "commit_late": 0, "presented_late": 1},
             "missed_frames": [{"at_ms": 16.7, "interval_ms": 16.67, "next_tick_after_target_ms": 8.3, "cause": "main_late"},
                               {"at_ms": 41.7, "interval_ms": 50.42, "next_tick_after_target_ms": 42.1, "cause": "presented_late"}]}
    reply.update(changed)
    return {key: value for key, value in reply.items() if value is not None}


class LateFrames(unittest.TestCase):
    def setUp(self):
        self.late_frames = loaded()["late_frames"]

    def test_the_refreshes_that_the_long_intervals_skipped_are_summed(self):
        # `missed` is 2 (two long intervals); the screen skipped 1 + 5 refreshes.
        late = self.late_frames(probe(), 100.02)
        self.assertEqual(late["missed_refreshes"], 6)
        self.assertEqual([miss["refreshes"] for miss in late["missed_frames"]], [1, 5])

    def test_each_kept_stamp_is_placed_after_the_action(self):
        late = self.late_frames(probe(), 100.02)
        self.assertEqual(late["action_at_ms"], 20.0)
        # The first long interval began 3.3 ms before the send and ended after it: the action's own frame.
        self.assertEqual([miss["after_action_ms"] for miss in late["missed_frames"]], [-3.3, 21.7])
        self.assertEqual([miss["cause"] for miss in late["missed_frames"]], ["main_late", "presented_late"])

    def test_the_probes_own_fields_are_kept(self):
        late = self.late_frames(probe(), 100.02)
        self.assertEqual(late["missed_at_ms"], [33.0, 92.0])
        self.assertEqual(late["missed_split"], {"main_late": 1, "commit_late": 0, "presented_late": 1})
        self.assertEqual(late["main_max_ms"], 12.5)

    def test_without_every_interval_the_kept_stamps_give_the_sum(self):
        self.assertEqual(self.late_frames(probe(intervals_ms=None), 100.02)["missed_refreshes"], 6)

    def test_no_sum_when_the_probe_kept_fewer_stamps_than_it_counted(self):
        self.assertIsNone(self.late_frames(probe(intervals_ms=None, missed=40), 100.02)["missed_refreshes"])

    def test_no_place_without_the_two_times_on_one_clock(self):
        for reply, sent in ((probe(first_frame_s=None), 100.02), (probe(), None), (probe(), 5000.0), (probe(), 99.0)):
            late = self.late_frames(reply, sent)
            self.assertIsNone(late["action_at_ms"])
            self.assertEqual([miss["after_action_ms"] for miss in late["missed_frames"]], [None, None])
            self.assertEqual(late["missed_refreshes"], 6)

    def test_a_reply_with_no_long_interval_or_no_refresh(self):
        still = self.late_frames({"refresh_ms": 8.333, "missed": 0, "intervals_ms": [8.33, 8.34], "first_frame_s": 100.0}, 100.02)
        self.assertEqual((still["missed_refreshes"], still["missed_frames"]), (0, []))
        for reply in (None, {}, {"refresh_ms": 0, "missed": 1, "intervals_ms": [20.0]}):
            self.assertIsNone(self.late_frames(reply, 100.02)["missed_refreshes"])


class MotionArms(unittest.TestCase):
    def setUp(self):
        self.motion_arms = loaded()["motion_arms"]

    def test_the_option_names_each_arm_one_time_in_its_order(self):
        self.assertEqual(self.motion_arms("on,off"), ["on", "off"])
        self.assertEqual(self.motion_arms("off, on"), ["off", "on"])
        self.assertEqual(self.motion_arms("off"), ["off"])

    def test_no_option_is_no_arm(self):
        # The app's own setting, one pass: the rows of a run without the option keep their names.
        self.assertEqual(self.motion_arms(None), [])

    def test_another_word_is_refused(self):
        for value in ("", "both", "on,on", "on,of", ","):
            with self.assertRaises(ValueError, msg=value):
                self.motion_arms(value)


class NotApplicable(unittest.TestCase):
    def setUp(self):
        self.not_applicable = loaded()["not_applicable"]

    def test_a_one_column_layout_has_no_drag(self):
        self.assertIn("no vertical divider", self.not_applicable("drag", 1) or "")

    def test_drag_applies_with_two_columns_or_more_and_in_stress(self):
        for columns in (2, 4, 6, None):
            self.assertIsNone(self.not_applicable("drag", columns))

    def test_other_actions_apply_to_one_column(self):
        for step in ("split", "close", "column", "column-close", "zoom", "unzoom", "keys", "window-zoom"):
            self.assertIsNone(self.not_applicable(step, 1), step)


class Activate(unittest.TestCase):
    def run_activate(self, states):
        opened = []
        states = iter(states)
        last = {}

        def read_state():
            nonlocal last
            last = next(states, last)
            return last

        namespace = loaded(subprocess=SimpleNamespace(run=lambda argv, **_: opened.append(argv),
                                                      SubprocessError=Exception),
                           time=SimpleNamespace(sleep=lambda _: None, monotonic=iter(range(0, 1000)).__next__),
                           print=lambda *_, **__: None)
        return namespace["activate"]("/fleet/cmux DEV pp.app", read_state=read_state, timeout=5), opened

    def test_opens_the_bundle_and_waits_for_a_key_window(self):
        state, opened = self.run_activate([{"window_key": False}, {"window_key": False}, {"window_key": True}])
        self.assertEqual(opened, [["open", "/fleet/cmux DEV pp.app"]])
        self.assertTrue(state["window_key"])

    def test_gives_up_after_its_timeout_with_the_last_state(self):
        state, _ = self.run_activate([{"window_key": False, "frontmost": "io.tailscale.ipn.macsys"}])
        self.assertFalse(state["window_key"])
        self.assertEqual(state["frontmost"], "io.tailscale.ipn.macsys")


if __name__ == "__main__":
    unittest.main()
