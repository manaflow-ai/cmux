#!/usr/bin/env python3
"""pane-perf-terminal.py's row inputs, from synthetic `debug.motion` samples and window states.

Run: python3 -I scripts/cmux-next/tests/test_pane_perf_rows.py
No app, display or subprocess is run: the definitions are loaded without the script's top-level app launch.
- moving_frames: New Column moves only the strip camera (column-scroll.md R3b), so a count of the pane and divider
  springs alone (`layout.travel`) read 0 for every New Column (BENCH BASE REDS 3).
- commit_notes: the app's own notes of a commit motion (the act that moves, or why a change showed in one frame).
- pane-zoom-terminal.py's sample_frames: a zoom by a commit motion has `layout.commit` samples and no
  spring frame, so a row that counts the springs alone reads 0 for it.
- not_applicable: a one-column layout (1x2) has no vertical divider, so its drag is not applicable, not a FAIL.
- activate: the bench opens its bundle through LaunchServices and waits for a key window.
"""
import ast
import json
from pathlib import Path
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]


def definitions(path, names):
    """Load selected definitions without executing an app driver's launch block."""
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    missing = set(names) - {node.name for node in nodes}
    assert not missing, f"{path.name} lacks {sorted(missing)}"
    return compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")


BENCH = definitions(ROOT / "pane-perf-terminal.py", {"moving_frames", "not_applicable", "activate", "commit_frames",
                                                    "late_frames", "motion_arms", "commit_notes", "commit_placements",
                                                    "layout_spans", "window_look", "look_tag", "look_config",
                                                    "look_terminal_lines", "look_problem", "windows_behind"})
ZOOM = definitions(ROOT / "pane-zoom-terminal.py", {"sample_frames"})


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


class CommitNotes(unittest.TestCase):
    def setUp(self):
        self.commit_notes = loaded()["commit_notes"]

    def test_the_notes_of_the_commit_motion_are_kept_in_their_order(self):
        notes = [{"t_ms": 1, "text": "tabs: sync added 1"}, {"t_ms": 2, "text": "layout.commit: split moves 2 panes"},
                 None, {"t_ms": 3, "text": "layout.commit: no move, the motion is off"}]
        self.assertEqual(self.commit_notes(notes),
                         ["layout.commit: split moves 2 panes", "layout.commit: no move, the motion is off"])

    def test_a_reply_without_such_a_note_gives_none(self):
        for notes in (None, [], {}, [{"t_ms": 3}], [{"text": None}], [{"text": "layout: rest"}]):
            self.assertEqual(self.commit_notes(notes), [])


class CommitPlacements(unittest.TestCase):
    def setUp(self):
        self.commit_placements = loaded()["commit_placements"]

    def test_a_note_is_placed_after_the_start_of_its_own_tick(self):
        samples = [{"name": "clock.dt_ms", "t_ms": 100.0, "v": 8.33}, {"name": "layout.travel", "t_ms": 100.2, "v": 0},
                   {"name": "clock.dt_ms", "t_ms": 108.3, "v": 8.33}, {"name": "clock.dt_ms", "t_ms": 130.0, "v": 21.7}]
        notes = [{"t_ms": 118.9, "text": "layout.commit: unzoom moves 30 panes"}, {"t_ms": 119.0, "text": "tabs: sync"},
                 {"t_ms": 130.4, "text": "layout.commit: rest"}]
        self.assertEqual(self.commit_placements(samples, notes), [
            {"text": "layout.commit: unzoom moves 30 panes", "t_ms": 118.9, "after_tick_ms": 10.6},
            {"text": "layout.commit: rest", "t_ms": 130.4, "after_tick_ms": 0.4}])

    def test_a_note_before_each_tick_has_no_place(self):
        samples = [{"name": "clock.dt_ms", "t_ms": 50.0, "v": 8.33}]
        notes = [{"t_ms": 20.0, "text": "layout.commit: split moves 2 panes"}]
        self.assertEqual(self.commit_placements(samples, notes),
                         [{"text": "layout.commit: split moves 2 panes", "t_ms": 20.0, "after_tick_ms": None}])
        self.assertEqual(self.commit_placements(None, notes)[0]["after_tick_ms"], None)

    def test_a_reply_without_such_a_note_gives_none(self):
        for notes in (None, [], {}, [None], [{"text": "layout.commit: no time"}], [{"t_ms": 3, "text": "layout: rest"}]):
            self.assertEqual(self.commit_placements([{"name": "clock.dt_ms", "t_ms": 1.0, "v": 8.33}], notes), [])


class LayoutSpans(unittest.TestCase):
    def setUp(self):
        self.layout_spans = loaded()["layout_spans"]

    def test_each_named_part_has_its_count_its_sum_and_its_longest_span(self):
        spans = [{"name": "layout.hide", "ms": 8.1, "at_ms": 400.0}, {"name": "layout.place", "ms": 1.2, "at_ms": 100.0},
                 {"name": "layout.place", "ms": 9.6, "at_ms": 108.3}, {"name": "layout", "ms": 250.0, "at_ms": 100.0},
                 {"name": "tabs", "ms": 3.0, "at_ms": 90.0}]
        self.assertEqual(self.layout_spans(spans), {
            "layout.hide": {"count": 1, "sum_ms": 8.1, "max_ms": 8.1, "max_at_ms": 400.0},
            "layout.place": {"count": 2, "sum_ms": 10.8, "max_ms": 9.6, "max_at_ms": 108.3}})

    def test_a_build_without_the_spans_gives_none(self):
        for spans in (None, [], {}, [None, 3], [{"name": "layout", "ms": 250.0}], [{"name": "layout.place"}]):
            self.assertEqual(self.layout_spans(spans), {})


class ZoomSampleFrames(unittest.TestCase):
    def setUp(self):
        namespace = {}
        exec(ZOOM, namespace)
        self.sample_frames = namespace["sample_frames"]

    def test_a_zoom_by_a_commit_motion_has_commit_frames_and_no_spring_frame(self):
        samples = frames((0, 0), (0, 0), (0, 0))
        samples[1:1] = [{"name": "layout.commit", "v": 4}, {"name": "layout.commit", "v": 4}, {"name": "layout.commit", "v": 0}]
        self.assertEqual(self.sample_frames(samples, "layout.commit"), 2)
        self.assertEqual(self.sample_frames(samples, "layout.travel"), 0)

    def test_a_zoom_by_the_springs_counts_its_spring_frames(self):
        samples = frames((600, 0), (200, 0), (0, 0))
        self.assertEqual(self.sample_frames(samples, "layout.travel"), 2)
        self.assertEqual(self.sample_frames(samples, "layout.commit"), 0)

    def test_a_reply_without_samples_counts_none(self):
        for samples in (None, [], {}, [None, 3], [{"name": "layout.travel"}]):
            self.assertEqual(self.sample_frames(samples, "layout.travel"), 0)


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


class WindowLook(unittest.TestCase):
    """`--window-look`: a see-through window with a blur, written both ways the app reads it."""

    def setUp(self):
        namespace = loaded()
        self.window_look, self.look_tag = namespace["window_look"], namespace["look_tag"]
        self.look_config, self.look_terminal_lines = namespace["look_config"], namespace["look_terminal_lines"]

    def test_opaque_is_the_default_and_changes_nothing(self):
        # The launch, the config and each row's name stay as they were, so the old numbers compare.
        config = {"layout": {"minimumPaneWidth": 80}}
        for value in (None, "opaque"):
            look = self.window_look(value)
            self.assertIsNone(look)
            self.assertEqual(self.look_tag(look), "")
            self.assertIs(self.look_config(config, look), config)
            self.assertEqual(self.look_terminal_lines(look), [])

    def test_see_through_alone_takes_the_round_values_of_the_fixture(self):
        self.assertEqual(self.window_look("see-through"),
                         {"opacity": 0.8, "blur": "frosted", "terminal_opacity": 0.8, "terminal_blur": 10,
                          "behind": "desktop"})

    def test_each_value_is_an_argument(self):
        look = self.window_look("see-through:opacity=0.5,blur=glass-clear,terminal-opacity=0.25,terminal-blur=8,"
                                "behind=checker")
        self.assertEqual(look, {"opacity": 0.5, "blur": "glass-clear", "terminal_opacity": 0.25, "terminal_blur": 8,
                                "behind": "checker"})
        self.assertEqual(self.window_look("see-through: blur = none")["blur"], "none")

    def test_unset_leaves_a_key_out(self):
        look = self.window_look("see-through:opacity=unset,blur=unset")
        self.assertIsNone(look["opacity"])
        self.assertIsNone(look["blur"])
        self.assertEqual(self.look_config({}, look), {})
        self.assertEqual(self.look_terminal_lines(look), ["background-opacity = 0.8", "background-blur = 10"])
        only_app = self.window_look("see-through:terminal-opacity=unset,terminal-blur=unset")
        self.assertEqual(self.look_terminal_lines(only_app), [])
        self.assertEqual(self.look_config({}, only_app),
                         {"appearance": {"backgroundOpacity": 0.8, "backgroundBlur": "frosted"}})

    def test_the_app_config_gets_its_two_keys_and_keeps_the_rest(self):
        config = {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark"}}
        made = self.look_config(config, self.window_look("see-through"))
        self.assertEqual(made, {"layout": {"minimumPaneWidth": 80},
                                "appearance": {"theme": "dark", "backgroundOpacity": 0.8, "backgroundBlur": "frosted"}})
        self.assertEqual(config, {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark"}})

    def test_the_terminal_config_gets_an_opacity_and_a_blur_radius(self):
        self.assertEqual(self.look_terminal_lines(self.window_look("see-through")),
                         ["background-opacity = 0.8", "background-blur = 10"])
        self.assertEqual(self.look_terminal_lines(self.window_look("see-through:terminal-opacity=1,terminal-blur=0")),
                         ["background-opacity = 1", "background-blur = 0"])

    def test_the_rows_name_says_each_value(self):
        self.assertEqual(self.look_tag(self.window_look("see-through")), "see-through-0.8-frosted-0.8-10")
        self.assertEqual(self.look_tag(self.window_look("see-through:blur=unset,terminal-blur=8,behind=stripes")),
                         "see-through-0.8-unset-0.8-8-over-stripes")

    def test_another_word_is_refused(self):
        for value in ("", "glass", "see-through:", "see-through:opacity", "see-through:opacity=2",
                      "see-through:opacity=-0.1", "see-through:opacity=nan", "see-through:blur=milk",
                      "see-through:terminal-blur=-1", "see-through:terminal-blur=2.5", "see-through:shade=1",
                      "see-through:opacity=0.5,opacity=0.6", "see-through:behind=unset", "opaque:opacity=0.5",
                      "see-through:opacity=unset,blur=unset,terminal-opacity=unset,terminal-blur=unset"):
            with self.assertRaises(ValueError, msg=value):
                self.window_look(value)


class LookProblem(unittest.TestCase):
    """A see-through run does not go on as an opaque one: the launch's own 2 config files must hold the look."""

    ENV = {"CMUX_NEXT_CONFIG_FILE": "/scratch/cmux.json", "CMUX_NEXT_GHOSTTY_CONFIG": "/scratch/ghostty"}

    def problem(self, value, files, env=None):
        namespace = loaded(json=json)
        return namespace["look_problem"](namespace["window_look"](value), self.ENV if env is None else env,
                                         read=files.__getitem__)

    def test_an_opaque_window_reads_no_file(self):
        self.assertIsNone(self.problem("opaque", {}, env={}))

    def test_both_files_hold_the_look(self):
        files = {"/scratch/cmux.json": json.dumps({"layout": {}, "appearance": {"backgroundOpacity": 0.8,
                                                                                 "backgroundBlur": "frosted"}}),
                 "/scratch/ghostty": "background-opacity = 0.8\nbackground-blur = 10\n"}
        self.assertIsNone(self.problem("see-through", files))

    def test_a_missing_key_or_line_is_named(self):
        files = {"/scratch/cmux.json": json.dumps({"appearance": {"backgroundOpacity": 1, "backgroundBlur": "frosted"}}),
                 "/scratch/ghostty": "background-opacity = 0.8\n"}
        problem = self.problem("see-through", files)
        self.assertIn("background-blur = 10", problem)
        self.assertIn("appearance.backgroundOpacity", problem)
        self.assertNotIn("backgroundBlur", problem)
        self.assertNotIn("background-opacity = 0.8", problem)

    def test_a_file_that_is_not_there_is_a_problem(self):
        self.assertIn("not read", self.problem("see-through", {}))
        self.assertIn("not read", self.problem("see-through", {}, env={}))


class WindowsBehind(unittest.TestCase):
    """What a see-through window is over: the other apps' windows below it, from the screen's window list."""

    @staticmethod
    def window(pid, x, y, width, height, layer=0, owner="other"):
        return {"pid": pid, "layer": layer, "owner": owner, "bounds": {"x": x, "y": y, "width": width, "height": height}}

    def setUp(self):
        self.windows_behind = loaded()["windows_behind"]

    def test_nothing_behind_is_an_empty_list(self):
        listed = [self.window(9, 0, 0, 2000, 24, layer=24, owner="menu bar"), self.window(7, 40, 40, 1440, 900),
                  self.window(9, 0, 1000, 2000, 80, layer=20, owner="dock")]
        self.assertEqual(self.windows_behind(listed, 7), [])

    def test_a_window_of_another_app_below_and_under_it_is_named(self):
        under = self.window(5, 100, 100, 300, 200, owner="notes")
        listed = [self.window(4, 60, 60, 200, 100, owner="in front"), self.window(7, 40, 40, 1440, 900), under,
                  self.window(6, 3000, 40, 300, 200, owner="beside")]
        self.assertEqual(self.windows_behind(listed, 7), [{"owner": "notes", "bounds": under["bounds"]}])

    def test_the_apps_own_panel_behind_is_not_another_window(self):
        listed = [self.window(7, 40, 40, 1440, 900), self.window(7, 0, 0, 1600, 1000)]
        self.assertEqual(self.windows_behind(listed, 7), [])

    def test_the_apps_largest_window_is_the_one_measured(self):
        under = self.window(5, 100, 100, 300, 200, owner="notes")
        listed = [self.window(7, 500, 50, 200, 40), under, self.window(7, 40, 40, 1440, 900)]
        self.assertEqual(self.windows_behind(listed, 7), [])

    def test_no_window_of_the_app_is_not_known(self):
        self.assertIsNone(self.windows_behind([self.window(5, 0, 0, 10, 10)], 7))


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
