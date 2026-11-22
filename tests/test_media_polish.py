#!/usr/bin/env python3
"""scripts/media/media_polish.py: crop math, pairing rules, labels, trim windows and the sidecar.

No display is needed. ffmpeg is faked for the command tests; the end-to-end tests at the bottom make tiny
clips with ffmpeg's lavfi test sources and skip themselves where ffmpeg is not installed.
"""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/media/media_polish.py"
SPEC = importlib.util.spec_from_file_location("media_polish", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

Rect = MODULE.Rect
PolishError = MODULE.PolishError


class FakeTools:
    """Stands in for ffprobe (answers with `sizes[path name]`) and ffmpeg (records the argv, writes nothing)."""

    def __init__(self, sizes: dict[str, tuple[int, int]], fps: str = "30/1", duration: float = 4.0):
        self.sizes, self.fps, self.duration = sizes, fps, duration
        self.calls: list[list[str]] = []

    def __call__(self, argv, **_kwargs):
        self.calls.append(list(argv))
        if argv[0] == "ffprobe":
            width, height = self.sizes[Path(argv[-1]).name]
            body = {"streams": [{"width": width, "height": height, "r_frame_rate": self.fps}],
                    "format": {"duration": str(self.duration)}}
            return SimpleNamespace(returncode=0, stdout=json.dumps(body), stderr="")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def ffmpeg_calls(self) -> list[list[str]]:
        return [call for call in self.calls if call[0] == "ffmpeg"]


def run_main(argv: list[str], tools: FakeTools) -> tuple[int, str]:
    out = io.StringIO()
    code = MODULE.main(argv, runner=tools, out=out)
    return code, out.getvalue()


class TempDirTest(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.dir = Path(self._dir.name)

    def tearDown(self) -> None:
        self._dir.cleanup()

    def touch(self, name: str) -> Path:
        path = self.dir / name
        path.write_bytes(b"x")
        return path


class DeviceRectTests(unittest.TestCase):
    def test_retina_bounds_scale_with_the_margin_around_them(self):
        box = MODULE.device_rect(Rect(20, 20, 50, 40), 2, (400, 300), margin=8)
        self.assertEqual(box, Rect(24, 24, 132, 112))

    def test_fractional_bounds_never_shave_the_element(self):
        box = MODULE.device_rect(Rect(10.3, 5.6, 20.2, 10.1), 1.5, (200, 200))
        self.assertEqual((box.x, box.y), (15, 8))
        self.assertGreaterEqual(box.x + box.w, (10.3 + 20.2) * 1.5)
        self.assertGreaterEqual(box.y + box.h, (5.6 + 10.1) * 1.5)

    def test_float_noise_does_not_add_a_pixel(self):
        self.assertEqual(MODULE.device_rect(Rect(0.1, 0.1, 0.2, 0.2), 10, (10, 10)), Rect(1, 1, 2, 2))

    def test_a_crop_leaving_the_source_is_refused_naming_the_edge(self):
        with self.assertRaises(PolishError) as caught:
            MODULE.device_rect(Rect(150, 20, 50, 40), 2, (400, 300), margin=8)
        self.assertIn("right by 16 px", str(caught.exception))
        self.assertIn("--scale", str(caught.exception))

    def test_a_1x_guess_on_a_retina_capture_is_caught_by_the_bounds(self):
        # The element really is at 300,200 CSS px on a 2x capture of an 800x500 viewport.
        MODULE.device_rect(Rect(300, 200, 120, 60), 2, (1600, 1000))
        with self.assertRaises(PolishError):
            MODULE.device_rect(Rect(300, 200, 120, 60), 4, (1600, 1000))

    def test_offset_moves_the_box_for_window_chrome(self):
        box = MODULE.device_rect(Rect(0, 0, 10, 10), 2, (100, 100), offset=(0, 28))
        self.assertEqual(box, Rect(0, 56, 20, 20))

    def test_even_rounding_grows_inside_the_source_or_shrinks_at_its_edge(self):
        self.assertEqual(MODULE.device_rect(Rect(1, 1, 3, 3), 1, (10, 10), even=True), Rect(1, 1, 4, 4))
        self.assertEqual(MODULE.device_rect(Rect(7, 7, 3, 3), 1, (10, 10), even=True), Rect(6, 6, 4, 4))
        self.assertEqual(MODULE.device_rect(Rect(0, 0, 3, 3), 1, (3, 3), even=True), Rect(0, 0, 2, 2))


class BoundsJsonTests(unittest.TestCase):
    def test_dom_rect_with_device_pixel_ratio(self):
        rect, scale = MODULE.rect_from_json({"x": 1, "y": 2, "width": 3, "height": 4, "top": 2, "left": 1,
                                             "devicePixelRatio": 2})
        self.assertEqual((rect, scale), (Rect(1, 2, 3, 4), 2.0))

    def test_left_top_and_short_names(self):
        self.assertEqual(MODULE.rect_from_json({"left": 1, "top": 2, "width": 3, "height": 4})[0], Rect(1, 2, 3, 4))
        self.assertEqual(MODULE.rect_from_json({"x": 1, "y": 2, "w": 3, "h": 4})[0], Rect(1, 2, 3, 4))

    def test_ax_frames_and_lists(self):
        ax = {"frame": {"origin": {"x": 5, "y": 6}, "size": {"width": 7, "height": 8}}, "scale": 2}
        self.assertEqual(MODULE.rect_from_json(ax), (Rect(5, 6, 7, 8), 2.0))
        self.assertEqual(MODULE.rect_from_json("{{5, 6}, {7, 8}}")[0], Rect(5, 6, 7, 8))
        self.assertEqual(MODULE.rect_from_json([5, 6, 7, 8])[0], Rect(5, 6, 7, 8))

    def test_a_key_picks_one_rect_from_a_larger_document(self):
        data = {"devicePixelRatio": 2, "panes": [{"bounds": {"x": 0, "y": 0, "width": 1, "height": 1}},
                                                 {"bounds": {"x": 9, "y": 9, "width": 2, "height": 2}}]}
        self.assertEqual(MODULE.rect_from_json(data, "panes.1"), (Rect(9, 9, 2, 2), 2.0))
        with self.assertRaises(PolishError):
            MODULE.rect_from_json(data, "panes.5")

    def test_a_rect_without_area_is_refused(self):
        with self.assertRaises(PolishError):
            MODULE.rect_from_json({"x": 0, "y": 0, "width": 0, "height": 4})
        with self.assertRaises(PolishError):
            MODULE.rect_from_json({"x": "a", "y": 0, "width": 1, "height": 4})


class CanvasTests(unittest.TestCase):
    def test_identical_inputs_keep_their_pixels(self):
        canvas, placements = MODULE.plan_canvas([(400, 300), (400, 300)], fit=False)
        self.assertEqual(canvas, (400, 300))
        self.assertEqual([p.factor for p in placements], [1.0, 1.0])

    def test_mismatched_inputs_are_refused_without_fit(self):
        with self.assertRaises(PolishError) as caught:
            MODULE.plan_canvas([(400, 300), (320, 200)], fit=False)
        self.assertIn("2: 320x200", str(caught.exception))
        self.assertIn("--fit", str(caught.exception))

    def test_fit_letterboxes_without_scaling_a_smaller_input(self):
        canvas, placements = MODULE.plan_canvas([(400, 300), (320, 200)], fit=True)
        self.assertEqual(canvas, (400, 300))
        self.assertEqual(placements[1], MODULE.Placement(320, 200, 40, 50, 1.0))

    def test_fit_shrinks_a_larger_input_keeping_its_aspect(self):
        canvas, placements = MODULE.plan_canvas([(800, 400)], fit=True, canvas=(400, 400))
        self.assertEqual(canvas, (400, 400))
        self.assertEqual(placements[0], MODULE.Placement(400, 200, 0, 100, 0.5))

    def test_different_scales_are_refused_unless_fit_resamples_them(self):
        with self.assertRaises(PolishError) as caught:
            MODULE.plan_canvas([(200, 100), (100, 50)], fit=False, scales=[2, 1])
        self.assertIn("device pixel ratios", str(caught.exception))
        canvas, placements = MODULE.plan_canvas([(200, 100), (100, 50)], fit=True, scales=[2, 1])
        self.assertEqual(canvas, (200, 100))
        self.assertEqual((placements[1].w, placements[1].h, placements[1].factor), (200, 100, 2.0))

    def test_video_canvases_are_even(self):
        canvas, placements = MODULE.plan_canvas([(101, 51), (99, 49)], fit=True, even=True)
        self.assertEqual(canvas, (102, 52))
        self.assertTrue(all(p.w % 2 == 0 and p.h % 2 == 0 for p in placements))

    def test_place_filter_scales_only_when_needed(self):
        same = MODULE.place_filter(0, (10, 10), MODULE.Placement(10, 10, 0, 0, 1.0), (10, 10), "0x111111", "v")
        self.assertEqual(same, "[0:v]setsar=1[v]")
        padded = MODULE.place_filter(1, (8, 6), MODULE.Placement(8, 6, 1, 2, 1.0), (10, 10), "0x111111", "f1")
        self.assertNotIn("scale=", padded)
        self.assertIn("pad=10:10:1:2", padded)


class LabelTests(unittest.TestCase):
    def test_every_glyph_is_seven_rows_of_five_bits(self):
        for char, code in MODULE.FONT.items():
            rows = MODULE.glyph(char)
            self.assertEqual(len(rows), 7, char)
            self.assertTrue(all(0 <= row < 32 for row in rows), char)
        for char in "beforeafterBEFOREAFTER0123456789 .:%-_/()":
            self.assertIn(char, MODULE.FONT)

    def test_unknown_characters_draw_as_a_question_mark(self):
        self.assertEqual(MODULE.glyph("×"), MODULE.glyph("?"))

    def test_band_is_a_ppm_of_the_requested_size_with_text_pixels(self):
        data = MODULE.render_band([("after", (255, 255, 255))], 100, 30, 2, (0, 0, 0))
        header = b"P6\n100 30\n255\n"
        self.assertTrue(data.startswith(header))
        pixels = data[len(header):]
        self.assertEqual(len(pixels), 100 * 30 * 3)
        self.assertIn(b"\xff\xff\xff", pixels)

    def test_long_text_is_cut_to_the_band(self):
        self.assertEqual(MODULE.fit_text("abcdefghij", 6), "abcd..")
        self.assertEqual(MODULE.label_scale(60, ["a" * 40]), 1)
        self.assertEqual(MODULE.label_scale(1600, ["before"]), 4)


class TrimWindowTests(unittest.TestCase):
    def args(self, **values):
        base = dict(event_start_frame=None, event_end_frame=None, start=None, end=None, fps=None,
                    lead_in=0.3, lead_out=0.3)
        base.update(values)
        return argparse.Namespace(**base)

    def media(self, fps=30.0, duration=4.0):
        return MODULE.Media(Path("clip.mp4"), "video", 320, 240, fps, duration)

    def test_frames_become_times_with_the_last_frame_included(self):
        window = MODULE.trim_window(self.media(), self.args(event_start_frame=15, event_end_frame=29))
        self.assertEqual((window.event_start, window.event_end), (0.5, 1.0))
        self.assertEqual((window.start, window.end), (0.2, 1.3))

    def test_lead_in_and_out_stop_at_the_clip(self):
        window = MODULE.trim_window(self.media(duration=1.1), self.args(start=0.1, end=1.0))
        self.assertEqual((window.start, window.end), (0.0, 1.1))

    def test_frames_need_a_known_rate(self):
        with self.assertRaises(PolishError):
            MODULE.trim_window(self.media(fps=None), self.args(event_start_frame=1, event_end_frame=2))
        window = MODULE.trim_window(self.media(fps=None), self.args(event_start_frame=60, event_end_frame=119,
                                                                    fps=60))
        self.assertEqual(window.event_start, 1.0)

    def test_bad_windows_are_refused(self):
        for values in ({}, {"start": 1.0}, {"start": 2.0, "end": 1.0}, {"start": 5.0, "end": 6.0},
                       {"start": 1.0, "end": 2.0, "event_start_frame": 3, "event_end_frame": 4}):
            with self.subTest(values=values), self.assertRaises(PolishError):
                MODULE.trim_window(self.media(), self.args(**values))


class CommandTests(TempDirTest):
    def test_crop_requires_an_explicit_scale(self):
        source = self.touch("shot.png")
        tools = FakeTools({"shot.png": (400, 300)})
        code, _ = run_main(["crop", str(source), "--out", str(self.dir / "out.png"), "--bounds", "1,1,5,5"], tools)
        self.assertEqual(code, 1)
        self.assertEqual(tools.ffmpeg_calls(), [])

    def test_crop_runs_ffmpeg_and_writes_a_complete_sidecar(self):
        source = self.touch("shot.png")
        out = self.dir / "out" / "pane.png"
        tools = FakeTools({"shot.png": (400, 300)})
        code, _ = run_main(["crop", str(source), "--out", str(out), "--bounds", "20,20,50,40", "--scale", "2",
                            "--variable", "fold look", "--runs", "3", "--viewport", "200x150",
                            "--window-frames", "4:9"], tools)
        self.assertEqual(code, 0)
        (call,) = tools.ffmpeg_calls()
        self.assertIn("crop=132:112:24:24,setsar=1", call)
        record = json.loads((self.dir / "out" / "pane.png.media.json").read_text())
        for field in MODULE.SIDECAR_FIELDS:
            self.assertIn(field, record)
        self.assertEqual(record["dims"], {"w": 132, "h": 112})
        self.assertEqual(record["scale"], 2)
        self.assertEqual(record["margin"], 8)
        self.assertEqual(record["crop_bounds"]["css"], {"x": 20, "y": 20, "w": 50, "h": 40})
        self.assertEqual(record["variable"], "fold look")
        self.assertEqual(record["runs"], 3)
        self.assertEqual(record["viewport"], {"w": 200, "h": 150})
        self.assertEqual(record["window_frames"], {"start": 4, "end": 9})
        self.assertIsNone(record["control"])
        self.assertIsNone(record["split"])
        self.assertIsNone(record["labels"])

    def test_crop_takes_the_scale_from_bounds_json_and_refuses_a_disagreeing_flag(self):
        source = self.touch("clip.mp4")
        bounds = self.dir / "bounds.json"
        bounds.write_text(json.dumps({"x": 10.5, "y": 5, "width": 51, "height": 33, "devicePixelRatio": 2}))
        tools = FakeTools({"clip.mp4": (320, 240)})
        out = self.dir / "c.mp4"
        code, _ = run_main(["crop", str(source), "--out", str(out), "--bounds-json", str(bounds), "--margin", "0"],
                           tools)
        self.assertEqual(code, 0)
        crop = next(part for part in tools.ffmpeg_calls()[0] if part.startswith("crop="))
        width, height = (int(value) for value in crop.removeprefix("crop=").split(",")[0].split(":")[:2])
        self.assertEqual((width % 2, height % 2), (0, 0))
        self.assertIn("libx264", tools.ffmpeg_calls()[0])
        code, _ = run_main(["crop", str(source), "--out", str(out), "--bounds-json", str(bounds), "--scale", "1"],
                           tools)
        self.assertEqual(code, 1)

    def test_crop_refuses_writing_over_its_source_and_a_wrong_output_type(self):
        source = self.touch("shot.png")
        tools = FakeTools({"shot.png": (400, 300)})
        for out in (source, self.dir / "shot.mp4"):
            code, _ = run_main(["crop", str(source), "--out", str(out), "--bounds", "1,1,5,5", "--scale", "1"], tools)
            self.assertEqual(code, 1)

    def test_dry_run_writes_nothing(self):
        source = self.touch("shot.png")
        out = self.dir / "dry" / "pane.png"
        tools = FakeTools({"shot.png": (400, 300)})
        code, printed = run_main(["crop", str(source), "--out", str(out), "--bounds", "1,1,5,5", "--scale", "1",
                                  "--margin", "0", "--dry-run"], tools)
        self.assertEqual(code, 0)
        self.assertIn("would run: ffmpeg", printed)
        self.assertEqual(tools.ffmpeg_calls(), [])
        self.assertFalse((self.dir / "dry").exists())

    def test_pair_refuses_mismatched_inputs_unless_fit(self):
        before, after = self.touch("before.png"), self.touch("after.png")
        tools = FakeTools({"before.png": (400, 300), "after.png": (320, 200)})
        code, _ = run_main(["pair", str(before), str(after), "--out-dir", str(self.dir / "p")], tools)
        self.assertEqual(code, 1)
        code, _ = run_main(["pair", str(before), str(after), "--out-dir", str(self.dir / "p"), "--fit",
                            "--control", "same chat"], tools)
        self.assertEqual(code, 0)
        record = json.loads((self.dir / "p" / "after.png.media.json").read_text())
        self.assertEqual(record["dims"], {"w": 400, "h": 300})
        self.assertEqual(record["labels"], ["after"])
        self.assertEqual(record["control"], "same chat")
        self.assertEqual(record["placed"], {"x": 40, "y": 50, "w": 320, "h": 200})

    def test_pair_refuses_mixing_stills_and_clips(self):
        still, clip = self.touch("a.png"), self.touch("b.mp4")
        tools = FakeTools({"a.png": (10, 10), "b.mp4": (10, 10)})
        code, _ = run_main(["pair", str(still), str(clip), "--out-dir", str(self.dir / "p")], tools)
        self.assertEqual(code, 1)

    def test_grid_draws_labels_and_records_them_with_metrics(self):
        paths = [self.touch(name) for name in ("a.png", "b.png", "c.png")]
        out = self.dir / "grid.png"
        tools = FakeTools({"a.png": (400, 300), "b.png": (400, 300), "c.png": (400, 300)})
        code, _ = run_main(["grid", *map(str, paths), "--out", str(out), "--label", "off", "--label", "chevron",
                            "--label", "pill", "--metric", "12 ms", "--metric", "9 ms", "--metric", "10 ms",
                            "--cols", "2"], tools)
        self.assertEqual(code, 0)
        call = tools.ffmpeg_calls()[0]
        graph = call[call.index("-filter_complex") + 1]
        self.assertIn("xstack=inputs=3", graph)
        self.assertEqual(sum(part.endswith(".ppm") for part in call), 3)
        record = json.loads(Path(str(out) + ".media.json").read_text())
        self.assertEqual(record["labels"], ["off", "chevron", "pill"])
        self.assertEqual(record["metrics"], ["12 ms", "9 ms", "10 ms"])
        band = MODULE.band_height(2, MODULE.label_scale(400, ["off", "chevron", "pill", "12 ms", "9 ms", "10 ms"]))
        self.assertEqual(record["dims"], {"w": 2 * 400 + 8 + 16, "h": 2 * (300 + band) + 8 + 16})

    def test_grid_needs_one_metric_per_input(self):
        paths = [self.touch(name) for name in ("a.png", "b.png")]
        tools = FakeTools({"a.png": (4, 4), "b.png": (4, 4)})
        code, _ = run_main(["grid", *map(str, paths), "--out", str(self.dir / "g.png"), "--metric", "1"], tools)
        self.assertEqual(code, 1)

    def test_trim_writes_mp4_gif_and_poster_each_with_a_sidecar(self):
        clip = self.touch("clip.mp4")
        out = self.dir / "event.mp4"
        tools = FakeTools({"clip.mp4": (321, 240)})
        code, _ = run_main(["trim", str(clip), "--out", str(out), "--event-start-frame", "15",
                            "--event-end-frame", "29"], tools)
        self.assertEqual(code, 0)
        calls = tools.ffmpeg_calls()
        mp4 = calls[0]
        self.assertEqual(mp4[mp4.index("-ss") + 1], "0.200")
        self.assertEqual(mp4[mp4.index("-t") + 1], "1.100")
        for flag in ("libx264", "yuv420p", "+faststart"):
            self.assertIn(flag, mp4)
        self.assertTrue(any(str(part).endswith("event.poster.png") for part in calls[1]))
        gif = calls[2]
        self.assertTrue(any("palettegen" in str(part) for part in gif))
        self.assertTrue(any("min(720" in str(part) for part in gif))
        for name in ("event.mp4", "event.gif", "event.poster.png"):
            record = json.loads((self.dir / f"{name}.media.json").read_text())
            self.assertEqual(record["window_frames"], {"start": 15, "end": 29})
            self.assertEqual(record["trim"]["lead_in_s"], 0.3)
        self.assertEqual(json.loads((self.dir / "event.mp4.media.json").read_text())["dims"], {"w": 320, "h": 240})

    def test_redact_boxes_in_device_pixels_and_refuses_boxes_outside(self):
        source = self.touch("shot.png")
        out = self.dir / "r.png"
        tools = FakeTools({"shot.png": (400, 300)})
        code, _ = run_main(["redact", str(source), "--out", str(out), "--rect", "10,10,40,20", "--scale", "2"], tools)
        self.assertEqual(code, 0)
        self.assertIn("drawbox=x=20:y=20:w=80:h=40:color=0x000000:t=fill,setsar=1", tools.ffmpeg_calls()[0])
        code, _ = run_main(["redact", str(source), "--out", str(out), "--rect", "190,10,40,20", "--scale", "2"],
                           tools)
        self.assertEqual(code, 1)
        code, _ = run_main(["redact", str(source), "--out", str(out), "--rect", "1,1,4,4"], tools)
        self.assertEqual(code, 1)

    def test_scan_refuses_nothing_and_points_at_the_privacy_check(self):
        shot = self.touch("shot.png")
        tools = FakeTools({"shot.png": (400, 300)})
        code, printed = run_main(["scan", str(shot), str(self.dir / "missing.png")], tools)
        self.assertEqual(code, 0)
        self.assertIn("pr_media_privacy.py check", printed)
        self.assertIn("no .media.json sidecar", printed)

    def test_home_paths_are_recorded_with_a_tilde(self):
        home = str(Path.home())
        self.assertEqual(MODULE.private_path(Path(home) / "x.png"), "~/x.png")
        self.assertEqual(MODULE.private_path(Path("/tmp/x.png")), "/tmp/x.png")


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
class EndToEndTests(TempDirTest):
    """Real ffmpeg on 64x48 test patterns: what the tool writes has the size the sidecar says."""

    def make(self, name: str, size: str, seconds: float | None = None) -> Path:
        path = self.dir / name
        args = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc=size={size}:rate=30"]
        args += ["-t", str(seconds), "-pix_fmt", "yuv420p"] if seconds else ["-frames:v", "1"]
        subprocess.run([*args, str(path)], check=True)
        return path

    def dims(self, path: Path) -> dict[str, int]:
        media = MODULE.probe(path, subprocess.run)
        return {"w": media.w, "h": media.h}

    def test_crop_pair_grid_and_trim_outputs_match_their_sidecars(self):
        before = self.make("before.png", "64x48")
        after = self.make("after.png", "48x32")
        clip = self.make("clip.mp4", "64x48", 1.0)
        outputs = [self.dir / "crop.png", self.dir / "pair/before.png", self.dir / "pair/after.png",
                   self.dir / "grid.png", self.dir / "t/event.mp4", self.dir / "t/event.gif",
                   self.dir / "t/event.poster.png", self.dir / "clipcrop.mp4"]
        quiet = io.StringIO()
        self.assertEqual(MODULE.main(["crop", str(before), "--out", str(outputs[0]), "--bounds", "4,4,10,10",
                                      "--scale", "2", "--margin", "2"], out=quiet), 0)
        self.assertEqual(MODULE.main(["pair", str(before), str(after), "--out-dir", str(self.dir / "pair"),
                                      "--fit"], out=quiet), 0)
        self.assertEqual(MODULE.main(["grid", str(before), str(after), "--fit", "--out", str(outputs[3]),
                                      "--metric", "p50 12 ms", "--metric", "p50 9 ms"], out=quiet), 0)
        self.assertEqual(MODULE.main(["trim", str(clip), "--out", str(outputs[4]), "--start", "0.3",
                                      "--end", "0.5"], out=quiet), 0)
        self.assertEqual(MODULE.main(["crop", str(clip), "--out", str(outputs[7]), "--bounds", "3,3,11,9",
                                      "--scale", "1", "--margin", "0"], out=quiet), 0)
        for path in outputs:
            with self.subTest(path=path.name):
                record = json.loads(Path(str(path) + ".media.json").read_text())
                self.assertEqual(self.dims(path), record["dims"])
        self.assertEqual(self.dims(outputs[1]), self.dims(outputs[2]))
        self.assertEqual(self.dims(outputs[7]), {"w": 12, "h": 10})


if __name__ == "__main__":
    unittest.main()
