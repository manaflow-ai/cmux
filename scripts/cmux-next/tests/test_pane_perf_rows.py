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
                                                    "stills_clock", "stills_cost", "docked_state", "cli_settings"})
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
