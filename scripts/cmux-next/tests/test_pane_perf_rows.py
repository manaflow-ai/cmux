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
                                                    "layout_spans", "windows_behind", "marker_color", "marker_command", "stills_facts",
                                                    "stills_clock", "stills_cost", "docked_state", "cli_settings", "theme_facts",
                                                    "move_facts", "animated_row", "proof_round_row", "proof_mark",
                                                    "pane_in_a_move", "move_ticks", "ticks_said", "move_times", "times_said",
                                                    "parts_said", "first_move_row", "measure"})
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


class RecordedStills(unittest.TestCase):
    """--record: each pane gets one line of text in a colour that no pixel of the window's backdrop can have, and each
    recording has its frames, its index and a pane trace (a reader compares the stills of a move with the rests)."""

    def setUp(self):
        self.bench = loaded(json=json)

    def test_the_marker_colour_is_the_farthest_from_what_the_backdrop_can_show(self):
        color = self.bench["marker_color"]
        # A tint of alpha 0.5 over a picture: a channel of the window is between tint x 0.5 and that + 127.5.
        # Red 0x20: 16 to 143 = white is farther (112) than black (16). Green 0xE0: 112 to 239 = black. Blue 0x7F:
        # 63.75 to 190.75 = white (64.25 against 63.75); blue 0x80: 64.25 to 191.25 = black.
        self.assertEqual(color({"tint": "#20E07F80", "picture": "test-picture"}), [255, 0, 255])
        self.assertEqual(color({"tint": "#20E08080", "picture": "test-picture"}), [255, 0, 0])
        # Liquid Glass carries the tint; an opaque window shows its sheet and nothing through it.
        self.assertEqual(color({"tint": "", "glassTint": "#000000CC"}), [255, 255, 255])
        self.assertEqual(color({"sheet": "#F0F0F0"}), [0, 0, 0])
        self.assertEqual(color({"sheet": "#101010", "tint": ""}), [255, 255, 255])
        for unread in (None, {}, {"tint": "20E08080"}, {"tint": "#20E0"}, {"tint": "#ZZE08080"}, "text"):
            self.assertIsNone(color(unread))

    def test_the_marker_command_prints_one_line_in_that_colour_and_no_command_without_one(self):
        command = self.bench["marker_command"]
        self.assertEqual(command([255, 0, 255]), "; printf '\\033[38;2;255;0;255m%s\\033[0m\\n' 'the pane text of the stills'")
        self.assertEqual(command(None), "")

    def test_a_recording_has_its_frames_its_index_and_a_pane_rect_in_each_sample(self):
        facts = self.bench["stills_facts"]
        row = [7, 0, 0, 100, 80, 1, 0, 0, 0, 100, 80, 100, 80, 1, 0, 0, 100, 80]
        trace = {"samples": [{"t": 0, "panes": [row]}, {"t": 8.3, "panes": [row, row]}], "t0_s": 50.0}
        names = ["frame-00000.jpg", "frame-00001.jpg", "frames.json"]
        found = facts(trace, {"samples": [{"t": 0}]}, names)
        self.assertEqual(found, {"frames": 2, "index": True, "samples": 2, "samples_with_panes": 2, "samples_at_record_start": 1,
                                 "presentation_rects": False, "samples_in_a_move": 0, "problem": None})
        # The sampler of a build that says where a pane is in each sample: 4 numbers more at each row's end.
        there = {"samples": [{"t": 0, "panes": [row + [0, 0, 100, 80]]}], "t0_s": 50.0}
        self.assertTrue(facts(there, {"samples": []}, names)["presentation_rects"])
        # A sample is in a move when a pane IS not where it ends (the row's first rect) by more than 0.5 pt.
        self.assertEqual(facts(there, None, names)["samples_in_a_move"], 0)
        moving = {"samples": [{"t": 0, "panes": [row + [0, 0, 100, 80]]}, {"t": 8.3, "panes": [row + [0, 0, 100.4, 80], row + [12, 0, 88, 80]]},
                              {"t": 16.6, "panes": [row + [0.6, 0, 100, 80]]}]}
        self.assertEqual(facts(moving, None, names)["samples_in_a_move"], 2)
        self.assertFalse(facts({"samples": [{"t": 0, "panes": [row + [0, 0, 100, 80], row]}]}, None, names)["presentation_rects"])

    def test_a_recording_with_no_frame_no_index_or_no_trace_says_which(self):
        facts = self.bench["stills_facts"]
        row = [7, 0, 0, 100, 80, 1, 0, 0, 0, 100, 80, 100, 80, 1, 0, 0, 100, 80]
        trace = {"samples": [{"t": 0, "panes": [row]}, {"t": 8.3, "panes": []}, {"t": 16.6}]}
        names = ["frame-00000.jpg", "frame-00001.jpg", "frames.json"]
        self.assertEqual(facts(trace, None, names)["problem"], "1 of 3 samples have a pane")
        self.assertEqual(facts(trace, None, names)["samples_at_record_start"], None)
        self.assertEqual(facts({"error": "no such window"}, None, names)["problem"], "no sample in the pane trace: {'error': 'no such window'}")
        self.assertEqual(facts(None, None, names)["problem"], "no sample in the pane trace: None")
        good = {"samples": [{"t": 0, "panes": [row]}]}
        self.assertEqual(facts(good, None, ["frame-00000.jpg", "frames.json"])["problem"], "1 frames")
        self.assertEqual(facts(good, None, ["frame-00000.jpg", "frame-00001.jpg", "notes.txt"])["problem"], "no frames.json")
        self.assertEqual(facts(good, None, [])["problem"], "0 frames; no frames.json")

    def test_a_recorded_act_says_its_missed_refreshes_beside_the_timed_rounds(self):
        cost = self.bench["stills_cost"]
        self.assertEqual(cost(4, [2, 3, 2]), {"missed_refreshes": 4, "rounds_missed_refreshes": [2, 3, 2], "more_than_each_round": True,
                                              "text": "4 missed refreshes with the trace and the recorder; the timed rounds of the same act: "
                                                      "[2, 3, 2] = MORE THAN EACH ROUND"})
        same = cost(3, [2, 3, 2])
        self.assertEqual((same["more_than_each_round"], same["text"]),
                         (False, "3 missed refreshes with the trace and the recorder; the timed rounds of the same act: [2, 3, 2]"))
        self.assertFalse(cost(0, [0, 0, 0])["more_than_each_round"])
        # A round with no count is not a round to compare with; no round, or no count of the recorded act = not known.
        self.assertEqual(cost(1, [None, 0])["rounds_missed_refreshes"], [0])
        none = cost(5, [])
        self.assertEqual((none["more_than_each_round"], none["text"]),
                         (None, "5 missed refreshes with the trace and the recorder; no timed round of the same act with the motion on"))
        unread = cost(None, [2, 3])
        self.assertEqual((unread["more_than_each_round"], unread["text"]),
                         (None, "the missed refreshes of the recorded act were not counted; the timed rounds of the same act: [2, 3]"))

    def test_the_first_frames_host_time_is_inside_the_trace(self):
        clock = self.bench["stills_clock"]
        trace = {"t0_s": 50.0, "samples": [{"t": 0}, {"t": 8.3}, {"t": 2400.0}]}
        index = {"times": [0, 0.0083, 1.2], "t0_s": 50.125}
        self.assertEqual(clock(index, trace), {"first_frame_t0_s": 50.125, "trace_t0_s": 50.0, "first_frame_in_trace_ms": 125.0,
                                               "clock_problem": None})
        # The ends of the trace are inside it: the first frame can be the trace's first or last tick.
        self.assertIsNone(clock({"times": [0, 0.0083, 3.0], "t0_s": 50.0}, trace)["clock_problem"])
        self.assertIsNone(clock({"times": [0, 0.0083, 3.0], "t0_s": 52.4}, trace)["clock_problem"])

    def test_a_recording_with_no_host_time_or_one_of_another_clock_says_which(self):
        clock = self.bench["stills_clock"]
        trace = {"t0_s": 50.0, "samples": [{"t": 0}, {"t": 2400.0}]}
        old = clock({"times": [0, 0.0083], "luminance": [1, 1], "peak": [1, 1]}, trace)
        self.assertEqual(old["clock_problem"], "frames.json has no t0_s (the recorder does not say its first frame's host time)")
        self.assertEqual((old["first_frame_t0_s"], old["first_frame_in_trace_ms"]), (None, None))
        self.assertEqual(clock(None, trace)["clock_problem"], "frames.json was not read")
        self.assertEqual(clock({"times": [0, 0.0083], "t0_s": True}, trace)["clock_problem"],
                         "frames.json has no t0_s (the recorder does not say its first frame's host time)")
        # A time since the process start, or a wall time: not on the trace's clock.
        for other in (3.5, 49.99, 52.41, 1795000000.0):
            found = clock({"times": [0, 0.0083, 3.0], "t0_s": other}, trace)
            self.assertEqual(found["clock_problem"], f"t0_s {other} is not inside the trace (50.0 to 52.4): not the trace's clock")
        # Inside the trace and farther from its start than the recording is long: 2 clocks too (the recorder starts
        # 0.1 s after the trace).
        late = clock({"times": [0, 0.0083, 1.2], "t0_s": 51.5}, trace)
        self.assertEqual(late["clock_problem"], "t0_s 51.5 is 1.5 s after the trace's t0_s 50.0, more than the recording's length 1.2 s: 2 clocks")
        self.assertIsNone(clock({"times": [0, 0.0083, 1.2], "t0_s": 51.125}, trace)["clock_problem"])
        self.assertEqual(clock({"times": [0], "t0_s": 50.1}, trace)["clock_problem"], "no second frame after the first (times [0])")
        self.assertEqual(clock({"times": [0, 0], "t0_s": 50.1}, trace)["clock_problem"], "no second frame after the first (times [0, 0])")
        self.assertEqual(clock({"times": [0, 0.0083], "t0_s": 50.1}, {"samples": [{"t": 0}]})["clock_problem"], "the trace has no t0_s")
        self.assertEqual(clock({"times": [0, 0.0083], "t0_s": 50.1}, {"t0_s": 50.0, "samples": []})["clock_problem"], "the trace has no sample")


def pane(name, end, now=None):
    """One pane row of the pane trace as the app's sampler gives it: the id, 21 numbers; the first rect is where the
    pane ends, the last 4 numbers where it IS in the sample."""
    return [name, *end, 1, 1, *end, end[2], end[3], 1, *end, *(now or end)]


class AMoveByThePaneTrace(unittest.TestCase):
    """The row `animated` of a proof round's act and the row of a recorded act read the pane trace: a pane that is not where
    it ends in 2 samples or more is a move. The app's `layout.commit` sample is only in a build with the probe: a
    build with no such sample and with a move in the trace is animated, and a build with no source says NO SOURCE."""

    def setUp(self):
        self.bench = loaded()
        self.facts, self.row = self.bench["move_facts"], self.bench["animated_row"]
        kept = [100, 6, 200, 190]
        widths = (100, 120.5, 160, 185.2, 199.2)  # each more than 0.5 pt from the end's 200
        self.close = {"samples": [{"t": 0, "panes": [pane("a", [100, 6, 100, 190]), pane("b", [200, 6, 100, 190])]}]
                      + [{"t": 8.3 * at, "panes": [pane("a", kept, [100, 6, width, 190]), pane("b", [200, 6, 100, 190])]}
                         for at, width in enumerate(widths, 1)]
                      + [{"t": 50, "panes": [pane("a", kept)]}]}
        # A split that the app shows in one frame: the new pane has a rect of 0 x 0 in its first sample, no more.
        self.one_frame = {"samples": [{"t": 0, "panes": [pane("a", kept)]},
                                      {"t": 8.3, "panes": [pane("a", kept), pane("n", [200, 6, 100, 190], [100, 6, 0, 0])]},
                                      {"t": 16.6, "panes": [pane("a", [100, 6, 100, 190]), pane("n", [200, 6, 100, 190])]}]}

    def test_a_pane_that_is_not_where_it_ends_counts_its_samples(self):
        self.assertEqual(self.facts(self.close), {"samples": 7, "samples_in_a_move": 5, "no_source": None})
        self.assertEqual(self.facts(self.one_frame), {"samples": 3, "samples_in_a_move": 1, "no_source": None})

    def test_a_trace_that_cannot_say_where_a_pane_is_has_no_source(self):
        old = [7, 0, 0, 100, 80, 1, 0, 0, 0, 100, 80, 100, 80, 1, 0, 0, 100, 80]  # a sampler with no presentation rect
        self.assertEqual(self.facts({"samples": [{"t": 0, "panes": [old]}]})["no_source"],
                         "the build's pane trace does not say where a pane is in a sample (a pane row of fewer than 22 entries)")
        self.assertEqual(self.facts({"samples": [{"t": 0}, {"t": 8.3, "panes": []}]})["no_source"], "no pane in the 2 samples of the pane trace")
        self.assertEqual(self.facts({"error": "no such window"})["no_source"], "no sample in the pane trace: {'error': 'no such window'}")
        self.assertEqual(self.facts(None), {"samples": 0, "samples_in_a_move": 0, "no_source": "no sample in the pane trace: None"})

    def test_a_move_in_the_trace_is_animated_in_a_build_with_no_commit_sample(self):
        name, expected, seen, ok = self.row("on", 0, 0, self.facts(self.close), [])
        self.assertTrue(ok)
        self.assertEqual(name, "animated (a pane's rect moves in the pane trace, or a layout spring, the strip camera or a commit motion moved)")
        self.assertEqual(expected, "2 samples in a move or more, or above 0 frames")
        self.assertEqual(seen, "5 of 7 samples of the pane trace in a move; 0 spring frames, 0 commit frames")
        self.assertTrue(self.row(None, 0, 0, self.facts(self.close), [])[3])  # no arm: the app's own setting

    def test_a_change_in_one_frame_is_not_animated_and_is_not_a_tools_fault(self):
        name, expected, seen, ok = self.row("on", 0, 0, self.facts(self.one_frame), ["layout.commit: no act"])
        self.assertFalse(ok)
        self.assertEqual(seen, "1 of 3 samples of the pane trace in a move; 0 spring frames, 0 commit frames; the app's notes: ['layout.commit: no act']")
        self.assertNotIn("NO SOURCE", seen)

    def test_a_row_with_no_source_says_so_and_fails(self):
        for arm in ("on", "off", None):
            name, expected, seen, ok = self.row(arm, 0, 0, self.facts({"samples": []}), [])
            self.assertFalse(ok, arm)
            self.assertTrue(seen.startswith("NO SOURCE: no sample in the pane trace: {'samples': []}; 0 spring frames, 0 commit frames"), seen)
        # A spring or the probe's own sample is a source too: a New Column moves only the strip camera.
        self.assertTrue(self.row("on", 12, 0, self.facts(None), [])[3])
        self.assertTrue(self.row("on", 0, 9, self.facts(None), [])[3])

    def test_the_off_arm_is_still_with_one_sample_at_the_most(self):
        name, expected, seen, ok = self.row("off", 0, 0, self.facts(self.one_frame), [])
        self.assertEqual((name, expected, ok), ("still (the pane motion is off)", "1 sample in a move at the most, 0 frames", True))
        self.assertFalse(self.row("off", 0, 0, self.facts(self.close), [])[3])
        self.assertFalse(self.row("off", 3, 0, self.facts(self.one_frame), [])[3])
        self.assertFalse(self.row("off", 0, 2, self.facts(self.one_frame), [])[3])


class Calls:
    """The app's debug socket as a list of the calls that the script made."""

    def __init__(self, trace):
        self.made, self.trace = [], trace

    def __call__(self, method, params=None, timeout=30):
        self.made.append((method, (params or {}).get("action"), tuple((params or {}).get("targets") or ())))
        return self.trace if (params or {}).get("action") == "trace_stop" else {}


class AProofRound(unittest.TestCase):
    """A timed round runs with no pane trace: its numbers have no cost of the tool's sampler and stay comparable with
    each older round. Each arm has one round more, first, with the trace: the proof round. It is not timed and not in
    the numbers, and its row says if the arm's acts moved."""

    def setUp(self):
        kept = [100, 6, 200, 190]
        self.move = {"samples": [{"t": 8.3 * at, "panes": [pane("a", kept, [100, 6, width, 190])]} for at, width in enumerate((100, 130, 160, 190))]
                     + [{"t": 50, "panes": [pane("a", kept)]}]}
        self.one_frame = {"samples": [{"t": 0, "panes": [pane("a", kept)]}, {"t": 8.3, "panes": [pane("a", kept), pane("n", kept, [100, 6, 0, 0])]}]}
        self.printed = []

    def bench(self, trace):
        calls = Calls(trace)
        clock = SimpleNamespace(sleep=lambda seconds: None, monotonic=lambda: 0.0)
        background = SimpleNamespace(sample=lambda: None, delta=lambda before: {"total_s": 0, "over_limit": False})
        made = loaded(rpc=calls, perform=lambda name: None, time=clock, bench_background=background,
                      opts=SimpleNamespace(browser=False), WINDOW_ACTIONS=("window-zoom", "window-unzoom"),
                      STILL=("drag", "scroll", "idle", "window-zoom", "window-unzoom"),
                      print=lambda *said, **more: self.printed.append(" ".join(str(part) for part in said)))
        return made, calls

    def test_a_timed_round_runs_with_no_pane_trace(self):
        made, calls = self.bench(self.move)
        run = made["measure"]("30p zoom #0 on", "zoom")
        self.assertEqual([call for call in calls.made if call[1] in ("trace_start", "trace_stop")], [])
        self.assertEqual((run["move"], run["samples_in_a_move"], run["proof"]), (None, None, False))
        self.assertIn("30p zoom #0 on", self.printed[-1])

    def test_a_proof_round_runs_with_the_pane_trace_and_says_that_it_is_not_timed(self):
        made, calls = self.bench(self.move)
        run = made["measure"]("30p zoom proof on", "zoom", proof=True)
        self.assertEqual([call for call in calls.made if call[1] in ("trace_start", "trace_stop")],
                         [("debug.motion", "trace_start", ("panes",)), ("debug.motion", "trace_stop", ())])
        self.assertEqual((run["samples_in_a_move"], run["proof"]), (4, True))
        self.assertIn("proof round (not timed, not in the numbers): 4 of 5 samples of the pane trace in a move; "
                      "4 ticks in the move, median interval 8.3 ms, largest 8.3 ms; the trace does not say the display's rate; "
                      "no time after the act: the trace does not say its ticks' host time; moved",
                      self.printed[-1])
        self.assertEqual(run["ticks"], {"ticks": 4, "median_ms": 8.3, "largest_ms": 8.3, "refresh_ms": None, "half_rate": False})
        self.assertNotIn("p95", self.printed[-1])

    def test_an_act_that_moves_no_pane_has_no_trace_in_a_proof_round(self):
        made, calls = self.bench(self.move)
        made["measure"]("30p scroll proof", "scroll", proof=True)
        self.assertEqual([call for call in calls.made if call[1] == "trace_start"], [])

    def test_a_timed_number_of_an_arm_with_no_proof_says_so(self):
        made, _ = self.bench(self.move)
        made["measure"]("30p split #1 on", "split", mark="NO MOVE PROVED")
        self.assertTrue(self.printed[-1].endswith("  NO MOVE PROVED"), self.printed[-1])
        made["measure"]("30p split #1 on", "split")
        self.assertNotIn("PROVED", self.printed[-1])

    def test_the_proof_rounds_row_is_the_arms_row_with_its_limit(self):
        made, _ = self.bench(self.move)
        facts, row, mark = made["move_facts"], made["proof_round_row"], made["proof_mark"]
        limit = "the move is proved for this arm's settings in one round, not in each timed round"
        ticks, times = made["move_ticks"], made["move_times"]
        run = {"moving_frames": 0, "commit_frames": 0, "move": facts(self.move), "ticks": ticks(self.move),
               "times": times(self.move | {"t0_s": 10.0}, 10.0), "commit_notes": []}
        name, expected, seen, ok = row("on", run)
        self.assertEqual((name, ok), ("proof round: animated (a pane's rect moves in the pane trace, or a layout spring, the strip camera "
                                      "or a commit motion moved)", True))
        self.assertEqual(expected, f"2 samples in a move or more, or above 0 frames ({limit})")
        self.assertEqual(seen, "4 of 5 samples of the pane trace in a move; 0 spring frames, 0 commit frames; "
                               "4 ticks in the move, median interval 8.3 ms, largest 8.3 ms; the trace does not say the display's rate; "
                               "first move 0.0 ms after the act, visible end 50.0 ms after the act "
                               "(the act's time is the script's send; a time is a tick's)")
        once = {"moving_frames": 0, "commit_frames": 0, "move": facts(self.one_frame), "ticks": ticks(self.one_frame),
                "times": times(self.one_frame, 0.0), "commit_notes": ["a note"]}
        self.assertFalse(row("on", once)[3])
        self.assertEqual(row("off", once)[:2], ("proof round: still (the pane motion is off)", f"1 sample in a move at the most, 0 frames ({limit})"))
        self.assertTrue(row("off", once)[3])
        self.assertFalse(row("off", run)[3])
        # What a number of a timed round of that arm gets beside it.
        self.assertEqual([mark("on", True), mark("off", True), mark(None, True)], ["", "", ""])
        self.assertEqual([mark("on", False), mark(None, False), mark("off", False)], ["NO MOVE PROVED", "NO MOVE PROVED", "MOTION OFF NOT PROVED"])
        self.assertEqual(mark("on", None), "NO MOVE PROVED")  # the arm's proof round did not run this act

    def test_a_move_at_half_the_displays_rate_is_a_print_in_the_row_and_no_fail(self):
        made, _ = self.bench(self.move)
        kept = [100, 6, 200, 190]
        slow = {"refresh_ms": 8.33, "samples": [{"t": 0, "panes": [pane("a", kept)]}]
                + [{"t": 16.7 * at, "panes": [pane("a", kept, [100, 6, width, 190])]} for at, width in enumerate((100, 130, 160, 190), 1)]}
        run = made["measure"]("30p zoom proof on", "zoom", proof=True) | {"move": made["move_facts"](slow), "ticks": made["move_ticks"](slow)}
        name, expected, seen, ok = made["proof_round_row"]("on", run)
        self.assertTrue(ok)
        self.assertIn("4 ticks in the move, median interval 16.7 ms, largest 16.7 ms; the window's display link says "
                      "8.33 ms a refresh (120 Hz)  MOVE AT HALF RATE; no time after the act: ", seen)


class TheTicksOfAMove(unittest.TestCase):
    """A proof round's pane trace has one sample for each tick of the window's display link. The ticks in which a pane
    is in a move say the rate of the move: their count, and the median and the largest of the intervals that end at
    such a tick, beside the link's own refresh. A median above 9 ms on a 120 Hz display is MOVE AT HALF RATE."""

    def setUp(self):
        self.bench = loaded()
        self.ticks, self.said = self.bench["move_ticks"], self.bench["ticks_said"]

    def trace(self, times, refresh=8.33, rest=2):
        """A pane at rest for `rest` samples, then in a move at each of `times` (ms), then at rest."""
        kept, last = [100, 6, 200, 190], (times[-1] if times else 0) + 8.33
        before = [{"t": round(8.33 * at, 2), "panes": [pane("a", kept)]} for at in range(rest)]
        return {"refresh_ms": refresh, "samples": before
                + [{"t": at, "panes": [pane("a", kept, [100, 6, 150, 190])]} for at in times] + [{"t": last, "panes": [pane("a", kept)]}]}

    def test_a_move_at_each_refresh_of_a_120_hz_display(self):
        facts = self.ticks(self.trace([16.66, 24.99, 33.32, 41.65, 49.98]))
        self.assertEqual(facts, {"ticks": 5, "median_ms": 8.33, "largest_ms": 8.33, "refresh_ms": 8.33, "half_rate": False})
        self.assertEqual(self.said(facts), "5 ticks in the move, median interval 8.33 ms, largest 8.33 ms; the window's display link says "
                                           "8.33 ms a refresh (120 Hz)")

    def test_a_move_at_each_second_refresh_of_a_120_hz_display_is_at_half_rate(self):
        facts = self.ticks(self.trace([25.0, 41.66, 58.32, 74.98, 108.3]))
        self.assertEqual(facts, {"ticks": 5, "median_ms": 16.66, "largest_ms": 33.32, "refresh_ms": 8.33, "half_rate": True})
        self.assertTrue(self.said(facts).endswith("(120 Hz)  MOVE AT HALF RATE"), self.said(facts))

    def test_one_late_tick_is_in_the_largest_and_is_not_half_rate(self):
        facts = self.ticks(self.trace([16.66, 24.99, 58.33, 66.66, 74.99]))
        self.assertEqual((facts["median_ms"], facts["largest_ms"], facts["half_rate"]), (8.33, 33.34, False))

    def test_the_same_intervals_on_a_60_hz_display_are_its_own_rate(self):
        facts = self.ticks(self.trace([25.0, 41.66, 58.32, 74.98], refresh=16.67))
        self.assertEqual((facts["median_ms"], facts["refresh_ms"], facts["half_rate"]), (16.66, 16.67, False))
        self.assertTrue(self.said(facts).endswith("the window's display link says 16.67 ms a refresh (60 Hz)"), self.said(facts))

    def test_a_trace_with_no_refresh_says_so_and_has_no_mark(self):
        for refresh in (None, 0, "8.33", True):
            facts = self.ticks(self.trace([25.0, 41.66, 58.32], refresh=refresh))
            self.assertEqual((facts["refresh_ms"], facts["half_rate"]), (None, False), refresh)
            self.assertTrue(self.said(facts).endswith("the trace does not say the display's rate"), self.said(facts))

    def test_a_change_in_one_frame_or_no_trace_has_no_rate(self):
        once = self.ticks(self.trace([50.0]))
        self.assertEqual(once, {"ticks": 1, "median_ms": None, "largest_ms": None, "refresh_ms": 8.33, "half_rate": False})
        self.assertEqual(self.said(once), "1 tick in the move: below 2, no rate of a move")
        for trace in (None, {"error": "no such window"}, {"samples": []}, self.trace([])):
            self.assertEqual(self.said(self.ticks(trace)), "0 ticks in the move: below 2, no rate of a move", trace)

    def test_a_move_from_the_traces_first_sample_has_one_interval_fewer(self):
        facts = self.ticks(self.trace([0, 8.33, 16.66], rest=0))
        self.assertEqual((facts["ticks"], facts["median_ms"], facts["largest_ms"]), (3, 8.33, 8.33))


class TheTimesOfAMove(unittest.TestCase):
    """A proof round's act has 2 times after the act, by the pane trace: the first tick with a pane in a move, and the
    visible end, the first tick at which each pane has 0.2 percent of its way or less left. The act's time is the
    script's clock before it sends the act; the trace says its first tick's host time on the same clock."""

    def setUp(self):
        self.bench = loaded()
        self.times, self.said = self.bench["move_times"], self.bench["times_said"]

    def trace(self, widths, start=100.0, step=8.33, more=()):
        """A pane that ends 1200 wide: at rest for 2 ticks, then as wide as each of `widths`, a tick each."""
        kept = [100, 6, 1200, 190]
        rows = [kept[2], kept[2], *widths]
        return {"t0_s": start, "samples": [{"t": round(step * at, 2), "panes": [pane("a", kept, [100, 6, width, 190]), *more]}
                                           for at, width in enumerate(rows)]}

    def test_the_first_move_and_the_visible_end_are_ticks_after_the_act(self):
        # The act at 100.00902 s; the ticks at 100.01666 s (the first in a move), ..., 100.04165 s (1.5 pt of 1,000 left).
        facts = self.times(self.trace([200, 700, 1100, 1198.5, 1200]), 100.00902)
        self.assertEqual(facts, {"first_move_ms": 7.6, "visible_end_ms": 32.6, "problem": None})
        self.assertEqual(self.said(facts), "first move 7.6 ms after the act, visible end 32.6 ms after the act "
                                           "(the act's time is the script's send; a time is a tick's)")

    def test_a_pane_with_more_than_the_share_of_its_way_left_is_not_at_its_end(self):
        facts = self.times(self.trace([200, 700, 1100, 1197.5, 1200]), 100.00902)  # 2.5 pt of 1,000 left: above 0.2 percent
        self.assertEqual(facts["visible_end_ms"], 41.0)

    def test_the_end_waits_for_each_pane(self):
        slow = [pane("b", [400, 6, 300, 190], [400, 6, 290, 190])]  # a second pane, 10 pt from its end in each tick but the last
        trace = self.trace([200, 700, 1198.5, 1200, 1200], more=slow)
        trace["samples"][-1]["panes"][1] = pane("b", [400, 6, 300, 190])
        self.assertEqual(self.times(trace, 100.0)["visible_end_ms"], 50.0)

    def test_a_trace_that_ends_in_the_move_has_no_visible_end(self):
        facts = self.times(self.trace([200, 700, 1100]), 100.00902)
        self.assertEqual(facts, {"first_move_ms": 7.6, "visible_end_ms": None, "problem": "the trace ends in the move"})
        self.assertEqual(self.said(facts), "first move 7.6 ms after the act, no visible end: the trace ends in the move "
                                           "(the act's time is the script's send; a time is a tick's)")

    def test_no_move_no_clock_or_another_clock_gives_no_time_and_says_why(self):
        moved = self.trace([200, 700, 1200])
        for trace, act, why in (
                (self.trace([1200, 1200]), 100.0, "no pane in a move in the trace"),
                (None, 100.0, "no pane in a move in the trace"),
                ({key: value for key, value in moved.items() if key != "t0_s"}, 100.0, "the trace does not say its ticks' host time"),
                (moved | {"t0_s": True}, 100.0, "the trace does not say its ticks' host time"),
                (moved, None, "the script has no time of the act"),
                (moved, 100.5, "the first move is before the act: the trace's clock is not the script's")):
            facts = self.times(trace, act)
            self.assertEqual(facts, {"first_move_ms": None, "visible_end_ms": None, "problem": why}, why)
            self.assertEqual(self.said(facts), "first move: NONE" if why.startswith("no pane") else f"no time after the act: {why}")

    def test_a_proof_round_of_a_pane_act_with_no_first_move_fails(self):
        row, none = self.bench["first_move_row"], self.times(self.trace([1200, 1200]), 100.0)
        moved = self.times(self.trace([200, 700, 1198.5, 1200]), 100.00902)
        for arm in ("on", None, ""):
            for act in ("split", "close", "zoom", "unzoom"):
                self.assertEqual(row(arm, act, none), ("proof round: a pane moves after the act", "a tick with a pane in a move",
                                                       "first move: NONE", False), (arm, act))
        self.assertEqual(row("on", "zoom", moved)[2:], ("first move 7.6 ms after the act", True))
        no_clock = self.times({"samples": self.trace([200, 1200])["samples"]}, 100.0)
        self.assertEqual(row("on", "zoom", no_clock)[2:], ("a pane moves; no time after the act: the trace does not say its ticks' host time", True))
        # The off arm moves no pane, and New Column moves the strip camera only: no such row.
        self.assertEqual([row("off", "zoom", none), row("on", "column", none), row("on", "drag", none)], [None, None, None])

    def test_the_apps_own_parts_of_the_acts_turn_are_in_the_proof_line(self):
        said = self.bench["parts_said"]
        self.assertEqual((said({}), said(None)), ("", ""))
        self.assertEqual(said({"layout.zoom.b": {"count": 1, "sum_ms": 2.5, "max_ms": 2.5, "max_at_ms": 4.0},
                               "layout.zoom.a": {"count": 3, "sum_ms": 6.0, "max_ms": 3.5, "max_at_ms": 1.0}}),
                         "; layout.zoom.a 3 x, sum 6.0 ms, max 3.5 ms at 1.0 ms; layout.zoom.b 1 x, sum 2.5 ms, max 2.5 ms at 4.0 ms")


def dock(mode="docked", shown=True, panes=("p7",), edge="left"):
    return {"column": "c1", "edge": edge, "mode": mode, "shown": shown, "panes": list(panes)}


def docks(*columns, supported=True, **more):
    return {"supported": supported, "windows": [{"window": "w1", "screen": {"dock": list(columns)}}], **more}


class DockedColumn(unittest.TestCase):
    """--record-docked: the acts are recorded on a pane of a column in the docked mode, and `debug.dock` says if the
    window has one (an overlay column and the strip have another ground under a pane)."""

    def setUp(self):
        self.state = loaded()["docked_state"]

    def test_one_shown_column_in_the_docked_mode_with_a_pane_is_the_fixture(self):
        self.assertEqual(self.state(docks(dock(panes=("p7", "p9")))),
                         {"problem": None, "columns": ["left docked, shown, 2 panes"], "panes": ["p7", "p9"]})
        # Each window's active screen counts.
        two = {"supported": True, "windows": [{"window": "w1"}, {"window": "w2", "screen": {"dock": [dock(edge="right")]}}]}
        self.assertEqual(self.state(two), {"problem": None, "columns": ["right docked, shown, 1 panes"], "panes": ["p7"]})

    def test_what_is_not_the_fixture_says_why(self):
        state = self.state
        self.assertEqual(state(docks())["problem"], "no docked column")
        self.assertEqual(state(docks(supported=False))["problem"], "the daemon does not serve dock columns")
        self.assertEqual(state(docks(dock(mode="overlay"))),
                         {"problem": "no shown column in the docked mode with a pane", "columns": ["left overlay, shown, 1 panes"], "panes": []})
        self.assertEqual(state(docks(dock(shown=False)))["columns"], ["left docked, not shown, 1 panes"])
        self.assertEqual(state(docks(dock(shown=False)))["problem"], "no shown column in the docked mode with a pane")
        self.assertEqual(state(docks(dock(panes=())))["problem"], "no shown column in the docked mode with a pane")
        # 2 docked columns: the focused pane's column is not known from this reply.
        self.assertEqual(state(docks(dock(), dock(edge="right", panes=("p2",))))["problem"], "2 columns in the docked mode: 1 is the fixture")
        self.assertEqual(state(docks(dock(), error="no column holds pane p1"))["problem"], "no column holds pane p1")
        for unread in (None, [], "text", {"error": "unknown method"}, {"supported": True, "windows": "none"}):
            self.assertTrue(state(unread)["problem"], unread)
            self.assertEqual(state(unread)["panes"], [])
        self.assertEqual(state({"error": "unknown method"})["problem"], "unknown method")
        self.assertEqual(state(None)["problem"], "no reply of debug.dock: None")


class ThemeFacts(unittest.TestCase):
    """The theme that the app resolved: the settings answer says the theme's name, `debug.themes` says what the first
    window and the terminals draw with."""

    def setUp(self):
        self.facts = loaded()["theme_facts"]

    def test_the_first_windows_scope_and_each_terminals_theme(self):
        window = {"spec": "Test Theme", "effective_spec": "Test Theme", "source": "settings", "window_background": "#102030",
                  "text_primary": "#F0F0F0", "is_dark": True, "appearance": "NSAppearanceNameDarkAqua", "backdrop": {"picture": ""}}
        themes = {"windows": [window, {"spec": "other"}], "ghostty_background": "#102030",
                  "terminals": [{"tab": "t1", "surface_theme": "Test Theme"}, {"tab": "t2", "surface_theme": None}, {"tab": "t3", "surface_theme": "Test Theme"}]}
        self.assertEqual(self.facts(themes), {"problem": None, "spec": "Test Theme", "effective_spec": "Test Theme", "source": "settings",
                                              "window_background": "#102030", "is_dark": True, "appearance": "NSAppearanceNameDarkAqua",
                                              "surface_themes": ["None", "Test Theme"], "terminal_background": "#102030"})

    def test_an_answer_with_no_window_is_a_problem_and_no_fact(self):
        for themes in (None, {}, {"error": "unknown method"}, {"windows": []}, {"windows": ["text"]}, "text"):
            self.assertEqual(list(self.facts(themes)), ["problem"], themes)
            self.assertIn("no window in debug.themes", self.facts(themes)["problem"])


class CliSettings(unittest.TestCase):
    """A try for the record: what the bundle's own CLI says for each settings path of the look. It never raises."""

    def lines(self, paths, answers):
        import os
        import subprocess
        calls = []

        def run(argv, **more):
            calls.append((argv, sorted(more), more["env"].get("CMUX_NEXT_CONFIG_FILE"), None in more["env"].values()))
            answer = answers[argv[2]]
            if isinstance(answer, Exception):
                raise answer
            return SimpleNamespace(returncode=answer[0], stdout=answer[1], stderr=answer[2])

        cli_settings = loaded(os=os, subprocess=subprocess)["cli_settings"]
        return cli_settings("/app/bin/cmux", paths, {"CMUX_NEXT_CONFIG_FILE": "/scratch/cmux.json", "GONE": None}, run=run), calls

    def test_each_path_is_asked_one_time_when_the_first_word_answers(self):
        lines, calls = self.lines({"ui.animationSpeed": "off", "appearance.chromeStyle": "card"},
                                  {"config": (0, '{"key": "ui.animationSpeed",\n "customized": true}\n', "")})
        self.assertEqual(lines, ['config get ui.animationSpeed: exit 0: {"key": "ui.animationSpeed", "customized": true}',
                                 'config get appearance.chromeStyle: exit 0: {"key": "ui.animationSpeed", "customized": true}'])
        # The launch's own environment, with no variable that the launch took out; 10 s at most for each call.
        self.assertEqual(calls[0], (["/app/bin/cmux", "--json", "config", "get", "ui.animationSpeed"],
                                    ["capture_output", "env", "text", "timeout"], "/scratch/cmux.json", False))

    def test_a_word_that_the_cli_refuses_gets_the_other_word_and_a_cli_that_does_not_run_is_said(self):
        lines, calls = self.lines({"ui.animationSpeed": "off"}, {"config": (2, "", "unknown command config"), "settings": (0, "off", "")})
        self.assertEqual(lines, ["config get ui.animationSpeed: exit 2: unknown command config", "settings get ui.animationSpeed: exit 0: off"])
        lines, calls = self.lines({"ui.animationSpeed": "off"}, {"config": OSError("no such file"), "settings": OSError("no such file")})
        self.assertEqual(len(lines), 2)
        self.assertIn("config get ui.animationSpeed: not run: OSError('no such file')", lines[0])
        # An opaque window has no path: no call.
        self.assertEqual(self.lines({}, {}), ([], []))


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
