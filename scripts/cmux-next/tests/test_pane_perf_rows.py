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
                                                    "layout_spans", "placed_at", "part_times", "probe_notes",
                                                    "record_offset", "turn_notes", "stalls_in", "turn_text", "stall_text",
                                                    "arm_tag", "window_look", "look_tag", "look_config",
                                                    "look_terminal_lines", "look_problem", "look_resolved",
                                                    "windows_behind"})
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


class PartTimesAndProbeNotes(unittest.TestCase):
    def setUp(self):
        self.part_times, self.probe_notes = loaded()["part_times"], loaded()["probe_notes"]
        self.placed = [{"text": "layout.commit: close moves 2 panes", "t_ms": 100.0, "after_tick_ms": 1.0}]

    def test_a_part_says_when_its_longest_span_started_after_the_placement(self):
        parts = {"layout.release": {"count": 1, "sum_ms": 12.0, "max_ms": 12.0, "max_at_ms": 191.26},
                 "layout.hide": {"count": 1, "sum_ms": 1.0, "max_ms": 1.0, "max_at_ms": None}}
        self.assertEqual(self.part_times(parts, self.placed), {"layout.release": 91.3, "layout.hide": None})
        self.assertEqual(self.part_times(parts, []), {"layout.release": None, "layout.hide": None})

    def test_a_hide_or_release_note_has_its_time_after_the_placement(self):
        notes = [{"t_ms": 100.0, "text": "layout.commit: close moves 2 panes"}, {"t_ms": 190.5, "text": "layout.hide: 1 hosts"},
                 {"text": "layout.release: no time"}, {"t_ms": 3.0, "text": "tabs: rest"}, None]
        self.assertEqual(self.probe_notes(notes, self.placed), ["layout.hide: 1 hosts at +90.5 ms", "layout.release: no time"])
        self.assertEqual(self.probe_notes(notes, None), ["layout.hide: 1 hosts", "layout.release: no time"])
        self.assertEqual(self.probe_notes(None, self.placed), [])


class TurnsAndStallsOnTheActionsClock(unittest.TestCase):
    def setUp(self):
        self.bench = loaded()

    def test_a_record_start_is_in_ms_after_the_send(self):
        offset = self.bench["record_offset"]
        self.assertEqual(offset({"started_s": 99.98}, 100.0), -20.0)
        self.assertIsNone(offset({}, 100.0))  # a build without the field
        self.assertIsNone(offset({"started_s": 99.98}, None))
        self.assertIsNone(offset({"started_s": 5.0}, 100.0))  # another clock
        self.assertIsNone(offset(None, 100.0))

    def test_a_long_turn_has_its_parts_and_its_start_after_the_action(self):
        notes = [{"t_ms": 130.0, "text": "turn: total=11.5 wake=0.1 passes=0.3 events=0.0 before_commit=10.5 commit=0.2 "
                                         "after_commit=0.4 pass_count=2 view_layouts=31 window_layouts=1 before_commit_view_layouts=30"},
                 {"t_ms": 3.0, "text": "layout.hide: 1 hosts"}, {"text": "turn: total=5.0 odd"}, None]
        turns = self.bench["turn_notes"](notes, -20.0)
        self.assertEqual(len(turns), 2)
        self.assertEqual((turns[0]["total"], turns[0]["before_commit"], turns[0]["pass_count"], turns[0]["view_layouts"]), (11.5, 10.5, 2, 31))
        self.assertEqual((turns[0]["start_after_action_ms"], turns[0]["end_after_action_ms"]), (98.5, 110.0))
        # A note with no time has no place, and a word that is not name=number is left out.
        self.assertEqual(turns[1], {"total": 5.0, "start_after_action_ms": None, "end_after_action_ms": None})
        self.assertEqual(self.bench["turn_notes"](notes, None)[0]["start_after_action_ms"], None)
        self.assertEqual(self.bench["turn_notes"](None, -20.0), [])
        text = self.bench["turn_text"](turns[0])
        self.assertIn("11.5 ms from 98.5 ms after the action = wake 0.1 + passes 0.3 + events 0.0 + before commit 10.5", text)
        self.assertIn("2 passes, 31 view layouts (30 before the commit) in 1 window passes", text)

    def test_a_stall_has_its_start_after_the_action_and_what_the_run_loop_called(self):
        hangs = {"records": [
            {"duration_ms": 11.26, "cpu_ms": 10.94, "start_uptime_ns": 100_098_000_000.0, "verdict": "ours",
             "frames": ["AppKit -[NSView setHidden:]", "CoreFoundation __CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__",
                        "CoreFoundation __CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__"]},
            {"duration_ms": 5.0}, {"cpu_ms": 1.0}, None]}
        stalls = self.bench["stalls_in"](hangs, 100.0, keep=2)
        self.assertEqual(stalls[0], {"ms": 11.3, "cpu_ms": 10.9, "after_action_ms": 98.0, "verdict": "ours", "called": "observer",
                                     "frames": hangs["records"][0]["frames"][:2]})
        self.assertEqual(stalls[1], {"ms": 5.0, "cpu_ms": None, "after_action_ms": None, "verdict": None, "called": None, "frames": []})
        self.assertEqual(len(stalls), 2)  # a record with no duration is left out
        self.assertEqual(self.bench["stalls_in"]({"count": 0}, 100.0), [])
        self.assertEqual(self.bench["stalls_in"](None, 100.0), [])
        self.assertIn("11.3 ms (cpu 10.9) from 98.0 ms after the action, ours, the run loop called: observer: AppKit -[NSView setHidden:] < ",
                      self.bench["stall_text"](stalls[0]))
        self.assertIn("no stack sample", self.bench["stall_text"](stalls[1]))


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
        self.assertEqual(self.motion_arms("on,off,hide-first"), ["on", "off", "hide-first"])

    def test_an_arm_names_its_rows(self):
        tag = loaded()["arm_tag"]
        self.assertEqual([tag("6x5", arm) for arm in (None, "on", "off", "hide-first")],
                         ["6x5", "6x5", "6x5-motion-off", "6x5-motion-hide-first"])

    def test_no_option_is_no_arm(self):
        # The app's own setting, one pass: the rows of a run without the option keep their names.
        self.assertEqual(self.motion_arms(None), [])

    def test_another_word_is_refused(self):
        for value in ("", "both", "on,on", "on,of", ","):
            with self.assertRaises(ValueError, msg=value):
                self.motion_arms(value)


class WindowLook(unittest.TestCase):
    """`--window-look`: the keys that the command line names, and no other key, written the ways the app reads them."""

    PICTURE = "background=test-picture,opacity=0.5,blur=frosted"

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

    def test_the_look_holds_each_named_key_and_no_other(self):
        self.assertEqual(self.window_look(self.PICTURE), {"background": "test-picture", "opacity": 0.5, "blur": "frosted"})
        self.assertEqual(self.window_look("opacity=0.25"), {"opacity": 0.25})
        self.assertEqual(self.window_look(" blur = glass-clear , terminal-opacity=0.5,terminal-blur=8,behind=checker"),
                         {"blur": "glass-clear", "terminal_opacity": 0.5, "terminal_blur": 8, "behind": "checker"})

    def test_the_app_config_gets_the_named_keys_and_keeps_the_rest(self):
        config = {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark"}}
        made = self.look_config(config, self.window_look(self.PICTURE))
        self.assertEqual(made, {"layout": {"minimumPaneWidth": 80},
                                "appearance": {"theme": "dark", "background": "test-picture", "backgroundOpacity": 0.5,
                                               "backgroundBlur": "frosted"}})
        self.assertEqual(config, {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark"}})

    def test_a_key_that_is_not_named_is_not_written(self):
        self.assertEqual(self.look_config({}, self.window_look("background=test-picture")),
                         {"appearance": {"background": "test-picture"}})
        self.assertEqual(self.look_config({}, self.window_look("opacity=0.5")), {"appearance": {"backgroundOpacity": 0.5}})
        self.assertEqual(self.look_config({}, self.window_look("terminal-blur=8")), {})

    def test_no_terminal_line_is_written_unless_it_is_named(self):
        self.assertEqual(self.look_terminal_lines(self.window_look(self.PICTURE)), [])
        self.assertEqual(self.look_terminal_lines(self.window_look("terminal-opacity=0.5")), ["background-opacity = 0.5"])
        self.assertEqual(self.look_terminal_lines(self.window_look("terminal-blur=8,terminal-opacity=1")),
                         ["background-opacity = 1", "background-blur = 8"])

    def test_the_rows_name_says_each_named_value(self):
        self.assertEqual(self.look_tag(self.window_look(self.PICTURE)), "look-background-test-picture-opacity-0.5-blur-frosted")
        self.assertEqual(self.look_tag(self.window_look("terminal-blur=8,opacity=1,behind=stripes")),
                         "look-terminal-blur-8-opacity-1-over-stripes")

    def test_another_word_is_refused(self):
        for value in ("", "glass", "see-through", "opacity", "opacity=2", "opacity=-0.1", "opacity=nan", "blur=milk",
                      "terminal-blur=-1", "terminal-blur=2.5", "shade=1", "opacity=0.5,opacity=0.6", "behind=wall",
                      "behind=checker", "opaque,opacity=0.5", "opacity=0.5,", "background=", "background=A Picture",
                      "background=../picture", "opacity=unset"):
            with self.assertRaises(ValueError, msg=value):
                self.window_look(value)


class LookProblem(unittest.TestCase):
    """A run with a look does not go on as an opaque one: the launch's own config files must hold each named key."""

    ENV = {"CMUX_NEXT_CONFIG_FILE": "/scratch/cmux.json", "CMUX_NEXT_GHOSTTY_CONFIG": "/scratch/ghostty"}

    def problem(self, value, files, env=None):
        namespace = loaded(json=json)
        return namespace["look_problem"](namespace["window_look"](value), self.ENV if env is None else env,
                                         read=files.__getitem__)

    def test_an_opaque_window_reads_no_file(self):
        self.assertIsNone(self.problem("opaque", {}, env={}))

    def test_the_files_hold_the_named_keys(self):
        app = json.dumps({"layout": {}, "appearance": {"background": "test-picture", "backgroundOpacity": 0.5,
                                                       "backgroundBlur": "frosted"}})
        # No terminal line is named: the terminal config file is not read.
        self.assertIsNone(self.problem("background=test-picture,opacity=0.5,blur=frosted", {"/scratch/cmux.json": app}))
        files = {"/scratch/cmux.json": "{}", "/scratch/ghostty": "background-opacity = 0.5\nbackground-blur = 8\n"}
        self.assertIsNone(self.problem("terminal-opacity=0.5,terminal-blur=8", files))

    def test_a_missing_key_or_line_is_named(self):
        files = {"/scratch/cmux.json": json.dumps({"appearance": {"background": "other-picture", "backgroundOpacity": 0.5}}),
                 "/scratch/ghostty": "background-opacity = 0.5\n"}
        problem = self.problem("background=test-picture,opacity=0.5,terminal-opacity=0.5,terminal-blur=8", files)
        self.assertIn("background-blur = 8", problem)
        self.assertIn("'appearance.background'", problem)
        self.assertNotIn("backgroundOpacity", problem)
        self.assertNotIn("background-opacity = 0.5", problem)

    def test_a_file_that_is_not_there_is_a_problem(self):
        self.assertIn("not read", self.problem("opacity=0.5", {}))
        self.assertIn("not read", self.problem("opacity=0.5", {}, env={}))
        self.assertIn("not read", self.problem("terminal-blur=8", {"/scratch/cmux.json": "{}"}))


class LookResolved(unittest.TestCase):
    """The look is what the running app says that its window shows, not what a file says: the picture's id and the
    tint's alpha of `debug.themes`' backdrop, and the app's own settings answer for each named key."""

    LOOK = "background=test-picture,opacity=0.5,blur=frosted"
    BACKDROP = {"sheet": "", "tint": "#10203080", "glassTint": "", "picture": "test-picture", "blending": "false"}
    SETTINGS = {"background": "test-picture", "backgroundOpacity": 0.5, "backgroundBlur": "frosted"}

    def resolved(self, value, backdrop, settings):
        namespace = loaded()
        return namespace["look_resolved"](namespace["window_look"](value), backdrop, settings)

    def test_the_picture_at_the_named_opacity_passes(self):
        resolved, problem = self.resolved(self.LOOK, self.BACKDROP, self.SETTINGS)
        self.assertIsNone(problem)
        self.assertEqual((resolved["background"], resolved["picture"], resolved["blur"]), ("picture", "test-picture", "frosted"))
        self.assertAlmostEqual(resolved["opacity"], 128 / 255, places=3)
        self.assertFalse(resolved["glass"])

    def test_no_picture_or_another_picture_fails(self):
        resolved, problem = self.resolved(self.LOOK, {**self.BACKDROP, "picture": ""}, self.SETTINGS)
        self.assertEqual(resolved["background"], "none")
        self.assertIn("picture", problem)
        self.assertIn("other-picture", self.resolved(self.LOOK, {**self.BACKDROP, "picture": "other-picture"}, self.SETTINGS)[1])

    def test_another_opacity_fails(self):
        self.assertIn("opacity", self.resolved(self.LOOK, {**self.BACKDROP, "tint": "#102030C0"}, self.SETTINGS)[1])
        # An opaque window paints its sheet and shows no tint: its opacity is 1.
        resolved, problem = self.resolved(self.LOOK, {**self.BACKDROP, "tint": "", "sheet": "#102030FF"}, self.SETTINGS)
        self.assertEqual(resolved["opacity"], 1.0)
        self.assertIn("opacity", problem)

    def test_glass_carries_the_tint_itself(self):
        backdrop = {**self.BACKDROP, "tint": "", "glassTint": "#10203080"}
        resolved, problem = self.resolved("opacity=0.5,blur=glass", backdrop, {"backgroundOpacity": 0.5, "backgroundBlur": "glass"})
        self.assertIsNone(problem)
        self.assertTrue(resolved["glass"])

    def test_a_named_key_that_the_app_did_not_take_fails(self):
        problem = self.resolved(self.LOOK, self.BACKDROP, {**self.SETTINGS, "backgroundBlur": None})[1]
        self.assertIn("appearance.backgroundBlur", problem)
        self.assertNotIn("backgroundOpacity", problem)

    def test_no_picture_is_a_look_too(self):
        settings = {"background": "none", "backgroundOpacity": 0.5}
        self.assertIsNone(self.resolved("background=none,opacity=0.5", {**self.BACKDROP, "picture": ""}, settings)[1])
        self.assertIn("picture", self.resolved("background=none,opacity=0.5", self.BACKDROP, settings)[1])

    def test_an_opaque_window_is_read_and_never_fails(self):
        resolved, problem = self.resolved("opaque", {"sheet": "#102030FF", "tint": "", "picture": ""}, {})
        self.assertIsNone(problem)
        self.assertEqual((resolved["background"], resolved["opacity"]), ("none", 1.0))

    def test_a_backdrop_that_was_not_read_fails_a_look(self):
        for backdrop in (None, {}, {"error": "no window"}):
            resolved, problem = self.resolved(self.LOOK, backdrop, self.SETTINGS)
            self.assertIsNone(resolved["opacity"])
            self.assertIn("picture", problem)


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
