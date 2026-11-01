#!/usr/bin/env python3
"""scripts/cmux-next/media/publish.py shows a step's other windows (floating panels, popovers,
sheets: tour.py's `windows`) beside its main-window shot, uploads them, and drops a window entry
whose path tour.py could not have written."""

from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("media_publish", ROOT / "scripts/cmux-next/media/publish.py")
publish = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(publish)
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32


class FakePrMedia:
    BRANCH = "pr-media"
    INLINE_MAX_BYTES = 10_000_000

    def __init__(self, fail=()):
        self.puts = []
        self.fail = fail
        self.checked = []
        self.gif_calls = []

    def check_privacy(self, items, repo, **options):
        self.checked.extend(remote for remote, _local in items)

    def family_of_content(self, path):
        return "png" if path.read_bytes().startswith(b"\x89PNG") else "other"

    def put_file(self, repo, branch, remote, local, message, checked=False):
        if any(remote.endswith(name) for name in self.fail):
            raise RuntimeError("secondary rate limit")
        self.puts.append(remote)

    def raw_url(self, repo, branch, remote):
        return f"https://raw.githubusercontent.com/{repo}/{branch}/{remote}"

    def tool_env(self):
        return {"PATH": "/usr/bin"}

    def gif_argv(self, source, destination, fps, width):
        self.gif_calls.append((source, destination, fps, width))
        return ["ffmpeg", str(source), str(destination)]

    def gif_attempts(self, widths, fps=None, source_rate=None):
        return publish.load_pr_media().gif_attempts(widths, fps, source_rate)

    def source_fps(self, path, runner=None, env=None):
        # A variable-rate capture's average can read low; publish.py must not probe and use it.
        return 7.0


STEP = {
    "index": 1, "title": "Open the pet", "status": "ok", "shot": "shots/01-open-the-pet.png",
    "windows": [
        {"id": 7, "kind": "chiefPet", "shot": "shots/01-open-the-pet--w7.png"},
        {"id": 8, "kind": "x<script>", "shot": "../../etc/passwd"},
        {"id": 9, "kind": "quickReply", "shot": "shots/01-open-the-pet--w9.png"},
    ],
}


class PublishWindowsTests(unittest.TestCase):
    def test_clean_step_keeps_only_window_shots_tour_py_writes(self):
        step = publish.clean_step(STEP)
        self.assertEqual([w["shot"] for w in step["windows"]],
                         ["shots/01-open-the-pet--w7.png", "shots/01-open-the-pet--w9.png"])
        self.assertEqual(step["windows"][0]["kind"], "chiefPet")

    def test_an_ok_shot_no_expect_checked_shows_as_unchecked(self):
        steps = [
            {"index": 1, "title": "Launch", "status": "ok", "checked": False},
            {"index": 2, "title": "Unchecked", "status": "ok", "checked": False, "shot": "shots/02-unchecked.png"},
            {"index": 3, "title": "Checked", "status": "ok", "checked": True, "shot": "shots/03-checked.png"},
            # A manifest from before tour.py wrote `checked` keeps its plain "ok".
            {"index": 4, "title": "Older", "status": "ok", "shot": "shots/04-older.png"},
            {"index": 5, "title": "Failed", "status": "failed", "checked": False, "shot": "shots/05-failed.png"},
        ]
        cleaned = [publish.clean_step(step) for step in steps]
        self.assertNotIn("checked", cleaned[3])
        rows = [publish.step_row(step) for step in cleaned]
        self.assertIn("| ok |", rows[0])
        self.assertIn(f"| {publish.UNCHECKED_TEXT} |", rows[1])
        self.assertIn("| ok |", rows[2])
        self.assertIn("| ok |", rows[3])
        self.assertIn("**failed**", rows[4])
        section = publish.tour_section({"title": "Demo", "result": "failed", "steps": cleaned}, {})
        self.assertIn("3 ok, 1 failed, 1 unchecked", section.splitlines()[0])

    def test_window_shots_are_uploaded_and_shown_beside_the_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "agent-pane"
            (directory / "shots").mkdir(parents=True)
            for name in ("01-open-the-pet.png", "01-open-the-pet--w7.png", "01-open-the-pet--w9.png"):
                (directory / "shots" / name).write_bytes(PNG)
            scratch = Path(tmp) / "scratch"
            scratch.mkdir()
            manifest = {"title": "Agent pane", "steps": [publish.clean_step(STEP)], "frames": []}
            fake = FakePrMedia()
            args = argparse.Namespace(pr=21672, sha="a" * 40, repo="manaflow-ai/cmux", dry_run=False)
            text = publish.publish_tour(directory, manifest, args, fake, scratch)
        self.assertEqual(sorted(fake.puts), [
            "21672/aaaaaaaa/next-agent-pane/shots/01-open-the-pet--w7.png",
            "21672/aaaaaaaa/next-agent-pane/shots/01-open-the-pet--w9.png",
            "21672/aaaaaaaa/next-agent-pane/shots/01-open-the-pet.png",
        ])
        main = text.index("shots/01-open-the-pet.png")
        self.assertLess(main, text.index("shots/01-open-the-pet--w7.png"))
        self.assertIn('alt="Open the pet (chiefPet)"', text)
        self.assertIn("shots/01-open-the-pet--w9.png", text)

    def test_a_failed_window_upload_drops_only_that_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "agent-pane"
            (directory / "shots").mkdir(parents=True)
            for name in ("01-open-the-pet.png", "01-open-the-pet--w7.png", "01-open-the-pet--w9.png"):
                (directory / "shots" / name).write_bytes(PNG)
            scratch = Path(tmp) / "scratch"
            scratch.mkdir()
            manifest = {"title": "Agent pane", "steps": [publish.clean_step(STEP)], "frames": []}
            fake = FakePrMedia(fail=("--w7.png",))
            args = argparse.Namespace(pr=21672, sha="a" * 40, repo="manaflow-ai/cmux", dry_run=False)
            text = publish.publish_tour(directory, manifest, args, fake, scratch)
        self.assertIn("shots/01-open-the-pet.png", text)
        self.assertIn("shots/01-open-the-pet--w9.png", text)
        self.assertNotIn("--w7.png", text)

class MakeVideoTests(unittest.TestCase):
    def test_ffmpeg_gets_only_the_tool_environment(self):
        envs = []

        def run(argv, **kwargs):
            envs.append(kwargs.get("env"))
            Path(argv[-1]).write_bytes(b"x")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(publish.shutil, "which", return_value="/usr/bin/ffmpeg"):
            mp4, gif = publish.make_video(Path(scratch), {"frames": [1, 2]}, Path(scratch), FakePrMedia(), run=run)
        self.assertIsNotNone(mp4)
        self.assertIsNotNone(gif)
        self.assertEqual(envs, [{"PATH": "/usr/bin"}] * 2)

    def test_native_window_recording_keeps_its_real_timestamps(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            Path(argv[-1]).write_bytes(b"x")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(publish.shutil, "which", return_value="/usr/bin/ffmpeg"):
            directory = Path(scratch) / "tour"
            directory.mkdir()
            (directory / "capture.mov").write_bytes(b"native 60 fps")
            media = FakePrMedia()
            mp4, gif = publish.make_video(directory, {"video": "capture.mov", "capture_fps": 60},
                                           Path(scratch), media, run=run)
        self.assertIsNotNone(mp4)
        self.assertIsNotNone(gif)
        encode = calls[0]
        self.assertIn("-i", encode)
        self.assertIn(str(directory / "capture.mov"), encode)
        self.assertIn("-fps_mode", encode)
        self.assertNotIn("-framerate", encode)
        self.assertNotIn("-frames:v", encode)
        self.assertEqual(encode[encode.index("-t") + 1], "300")
        # A 60 Hz recording that fits makes a 50 fps gif, the fastest a gif plays in a browser.
        self.assertEqual([(call[2], call[3]) for call in media.gif_calls], [(50, publish.GIF_WIDTHS[0])])

    def test_native_capture_must_be_the_tour_local_regular_file(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            directory = root / "tour"
            directory.mkdir()
            outside = root / "outside.mov"
            outside.write_bytes(b"outside")
            self.assertIsNone(publish.capture_file(directory, {"video": "../outside.mov"}))
            (directory / "capture.mov").symlink_to(outside)
            self.assertIsNone(publish.capture_file(directory, {"video": "capture.mov"}))

    def test_the_still_fallback_gif_keeps_its_measured_rate(self):
        media = FakePrMedia()

        def run(argv, **kwargs):
            Path(argv[-1]).write_bytes(b"x")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(publish.shutil, "which", return_value="/usr/bin/ffmpeg"):
            publish.make_video(Path(scratch), {"frames": [1, 2], "frame_interval": 0.5}, Path(scratch), media, run=run)
        self.assertEqual([call[2] for call in media.gif_calls], [2])

    def test_a_gif_over_the_limit_steps_down_instead_of_dropping_to_nothing(self):
        # Leo, 2026-10-31: "WHY ... IS IT NOT 30/60/120". Smooth first; narrower, then fewer frames, only to fit.
        media = FakePrMedia()
        media.INLINE_MAX_BYTES = 1024 * 1024  # the publisher keeps 512 KiB of headroom under it

        def run(argv, **kwargs):
            out = Path(argv[-1])
            fits = out.suffix == ".gif" and len(media.gif_calls) >= 4
            out.write_bytes(b"x" if fits or out.suffix != ".gif" else b"x" * (600 * 1024))
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(publish.shutil, "which", return_value="/usr/bin/ffmpeg"):
            directory = Path(scratch) / "tour"
            directory.mkdir()
            (directory / "capture.mov").write_bytes(b"native 60 fps")
            mp4, gif = publish.make_video(directory, {"video": "capture.mov"}, Path(scratch), media, run=run)
        self.assertIsNotNone(gif)
        self.assertEqual([(call[2], call[3]) for call in media.gif_calls],
                         [(50, 720), (30, 720), (30, 560), (30, 440)])

    def argv_for(self, manifest):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            Path(argv[-1]).write_bytes(b"x")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(publish.shutil, "which", return_value="/usr/bin/ffmpeg"):
            publish.make_video(Path(scratch), manifest, Path(scratch), FakePrMedia(), run=run)
        return calls[0]

    def seconds(self, frames, interval):
        argv = self.argv_for({"frames": list(range(frames)), "frame_interval": interval})
        return frames / float(argv[argv.index("-framerate") + 1])

    def test_a_15_second_tour_makes_a_15_second_video(self):
        # Leo, 2026-10-31: "you guys always only ever seem to be able to record 5 second videos".
        self.assertAlmostEqual(self.seconds(30, 0.5), 15.0)  # display route, a frame every 0.5 s
        self.assertAlmostEqual(self.seconds(15, 1.0), 15.0)  # app-window route, a frame every 1.0 s

    def test_a_missing_or_bad_interval_uses_the_default(self):
        for manifest in ({"frames": [1, 2]}, {"frames": [1, 2], "frame_interval": "fast"},
                         {"frames": [1, 2], "frame_interval": 0}, {"frames": [1, 2], "frame_interval": True}):
            argv = self.argv_for(manifest)
            self.assertEqual(argv[argv.index("-framerate") + 1], "2")

    def test_a_fast_still_fallback_uses_its_measured_rate(self):
        argv = self.argv_for({"frames": list(range(60)), "frame_interval": 1 / 60})
        self.assertEqual(argv[argv.index("-framerate") + 1], "60")

    def test_native_capture_encodes_at_least_thirty_fps_and_a_smooth_gif(self):
        """Exercise the real ScreenCaptureKit movie handoff and palette GIF chain with a 60fps source."""
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            self.skipTest("ffmpeg and ffprobe are required for the native media integration check")
        pr_media = publish.load_pr_media()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            directory = root / "tour"
            directory.mkdir()
            capture = directory / "capture.mov"
            generated = subprocess.run([
                "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi",
                "-i", "testsrc2=size=320x240:rate=60", "-t", "2", "-c:v", "libx264",
                "-pix_fmt", "yuv420p", str(capture),
            ], capture_output=True, text=True)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            mp4, gif = publish.make_video(directory, {"video": "capture.mov", "capture_fps": 60}, root,
                                          pr_media)
            self.assertIsNotNone(mp4)
            self.assertIsNotNone(gif)

            def probe(path):
                result = subprocess.run([
                    "ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                    "-show_entries", "stream=nb_read_frames,duration", "-of", "json", str(path),
                ], capture_output=True, text=True, check=True)
                stream = json.loads(result.stdout)["streams"][0]
                # GIF delays use hundredths of a second, so the demuxer's
                # avg_frame_rate can misreport an uneven cadence;
                # measure decoded frames over the complete playback duration.
                duration = float(stream["duration"])
                return int(stream["nb_read_frames"]) / duration, duration

            mp4_rate, mp4_duration = probe(mp4)
            gif_rate, gif_duration = probe(gif)
            print(f"Encoded capture: MP4 {mp4_rate:.3f} fps / {mp4_duration:.3f}s; "
                  f"GIF {gif_rate:.3f} fps / {gif_duration:.3f}s", flush=True)
            self.assertGreaterEqual(float(mp4_rate), 30)
            self.assertAlmostEqual(mp4_duration, 2, delta=0.1)
            # A small 60 fps clip fits at the top step: 50 fps (2/100 s a frame), never the old 15.
            self.assertGreaterEqual(float(gif_rate), 49)
            self.assertLessEqual(float(gif_rate), 50.1)
            self.assertAlmostEqual(gif_duration, 2, delta=0.1)

    def test_palette_gif_command_uses_the_requested_fps_and_a_palette_pass(self):
        command = publish.load_pr_media().gif_argv(Path("capture.mp4"), Path("tour.gif"), 50, 720)
        self.assertIn("fps=50", command[command.index("-filter_complex") + 1])
        graph = command[command.index("-filter_complex") + 1]
        self.assertIn("palettegen", graph)
        self.assertIn("paletteuse", graph)


if __name__ == "__main__":
    unittest.main()
