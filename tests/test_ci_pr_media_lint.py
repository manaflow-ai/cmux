#!/usr/bin/env python3
"""pr_media_lint: each rule warns on its fixture, stays quiet on a good one, and the lint always exits 0."""
from __future__ import annotations

import importlib.util
import io
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pr_media_lint", ROOT / "scripts/ci/pr_media_lint.py")
assert spec and spec.loader
lint_mod = importlib.util.module_from_spec(spec)
sys.modules["pr_media_lint"] = lint_mod
spec.loader.exec_module(lint_mod)


def png(w: int, h: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0")) + chunk(b"IEND", b""))


def gif(w: int, h: int) -> bytes:
    return b"GIF89a" + struct.pack("<HH", w, h) + b"\x00\x00\x00;"


def jpeg(w: int, h: int) -> bytes:
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, h, w, 1) + b"\x01\x11\x00"
    return b"\xff\xd8" + app0 + sof0 + b"\xff\xd9"


GOOD_BODY = """Variable under test: the fold look; control: the default fold (baseline), same chat.
Median of 3 runs, frames 10-40, viewport 720x640.

| look | max jump px | duration ms |
|---|---|---|
| fade | 16.2 | 376 |
| morph | 85.2 | 385 |
"""


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def file(self, name: str, data: bytes, side: dict | None = None) -> tuple[str, Path]:
        path = self.dir / name
        path.write_bytes(data)
        if side is not None:
            path.with_name(name + ".media.json").write_text(json.dumps(side), encoding="utf-8")
        return name, path

    def rules(self, media=(), body=None) -> list[str]:
        return [rule for _, rule, _ in lint_mod.lint(list(media), body)]


class DimensionTests(Fixture):
    def test_png_gif_jpeg_headers(self) -> None:
        self.assertEqual(lint_mod.dimensions(self.file("a.png", png(640, 480))[1]), (640, 480))
        self.assertEqual(lint_mod.dimensions(self.file("a.gif", gif(320, 200))[1]), (320, 200))
        self.assertEqual(lint_mod.dimensions(self.file("a.jpg", jpeg(800, 600))[1]), (800, 600))

    def test_a_clip_without_ffprobe_is_skipped_quietly(self) -> None:
        name, path = self.file("tour.mp4", b"\0\0\0\x18ftypmp42")
        with mock.patch.object(lint_mod.shutil, "which", return_value=None):
            self.assertIsNone(lint_mod.dimensions(path))
            self.assertEqual(self.rules([(name, path)]), [])

    def test_garbage_is_none(self) -> None:
        self.assertIsNone(lint_mod.dimensions(self.file("x.png", b"not a png")[1]))


class UncroppedTests(Fixture):
    def test_a_full_display_still_warns(self) -> None:
        for w, h in ((2880, 1800), (1440, 900), (1728, 1117), (864, 558)):
            self.assertEqual(self.rules([self.file(f"s{w}.png", png(w, h))]), ["uncropped-full-display"], (w, h))

    def test_a_cropped_still_is_quiet(self) -> None:
        self.assertEqual(self.rules([self.file("s.png", png(720, 640))]), [])

    def test_sidecar_crop_bounds_clears_it(self) -> None:
        side = {"crop_bounds": [0, 0, 1440, 900], "variable": "look", "control": "default", "runs": 3}
        self.assertEqual(self.rules([self.file("s.png", png(1440, 900), side)]), [])

    def test_sidecar_screen_source_without_crop_warns(self) -> None:
        side = {"source": "screen", "crop_bounds": None, "variable": "look", "control": "default", "runs": 3}
        self.assertEqual(self.rules([self.file("s.png", png(700, 500), side)]), ["uncropped-full-display"])

    def test_a_clip_uses_ffprobe(self) -> None:
        name, path = self.file("tour.mp4", b"\0")
        with mock.patch.object(lint_mod, "_ffprobe", return_value=(1920, 1080)):
            self.assertEqual(self.rules([(name, path)]), ["uncropped-full-display"])


class PairTests(Fixture):
    def test_mismatched_pairs_warn_with_both_sizes(self) -> None:
        for a, b in (("fold-before.png", "fold-after.png"), ("base_fold.png", "head_fold.png"),
                     ("fold-a.png", "fold-b.png")):
            with self.subTest(a=a):
                warnings = lint_mod.lint([self.file(a, png(720, 640)), self.file(b, png(700, 640))])
                self.assertEqual([w[1] for w in warnings], ["before-after-mismatch"])
                self.assertIn("720x640", warnings[0][2])
                self.assertIn("700x640", warnings[0][2])
                self.assertIn("aspect ratio", warnings[0][2])

    def test_matching_pair_and_unrelated_files_are_quiet(self) -> None:
        self.assertEqual(self.rules([self.file("fold-before.png", png(720, 640)),
                                     self.file("fold-after.png", png(720, 640)),
                                     self.file("other.png", png(300, 300)),
                                     self.file("a-menu.png", png(200, 100))]), [])

    def test_a_still_never_pairs_with_a_clip(self) -> None:
        self.assertEqual(self.rules([self.file("x-before.png", png(720, 640)),
                                     self.file("x-after.gif", gif(360, 320))]), [])


class MeasurementTableTests(Fixture):
    def test_a_qualified_table_is_quiet(self) -> None:
        self.assertEqual(self.rules(body=GOOD_BODY), [])

    def test_missing_qualifiers_are_listed(self) -> None:
        body = "| look | max jump px |\n|---|---|\n| fade | 16 |\n| morph | 85 |\n"
        warnings = lint_mod.lint([], body)
        self.assertEqual([w[1] for w in warnings], ["measurement-table-unqualified"])
        for what in ("variable under test", "control run", "run count", "frame window / viewport"):
            self.assertIn(what, warnings[0][2])

    def test_an_all_zero_column_is_suspect(self) -> None:
        body = GOOD_BODY.replace("| 16.2 |", "| 0 |").replace("| 85.2 |", "| 0.2 |")
        warnings = lint_mod.lint([], body)
        self.assertEqual(len(warnings), 1)
        self.assertIn("'max jump px' value is ~0", warnings[0][2])

    def test_a_group_of_zero_rows_is_suspect(self) -> None:
        body = GOOD_BODY.replace("| look | max jump px | duration ms |", "| chat | max jump px | duration ms |") + \
            "| sub | 0 | 200 |\n| sub | 0 | 190 |\n"
        warnings = lint_mod.lint([], body)
        self.assertEqual(len(warnings), 1)
        self.assertIn("for 'sub' is ~0", warnings[0][2])

    def test_off_screen_prose_is_suspect(self) -> None:
        body = GOOD_BODY + "\nOn the subagent chat the whole fold happens out of view.\n"
        self.assertEqual(self.rules(body=body), ["measurement-table-unqualified"])

    def test_a_non_measurement_table_is_quiet(self) -> None:
        self.assertEqual(self.rules(body="| file | owner |\n|---|---|\n| a.py | me |\n"), [])

    def test_the_49624_shape_warns(self) -> None:
        body = ("recorded the same way (headless, real speed, 720x640) against the baseline\n\n"
                "| chat | look | max jump px | duration ms | gap px |\n|---|---|---|---|---|\n"
                "| long | `fade` | 16.2 | 376 | 0 |\n| long | `morph` | 85.2 | 385 | 0 |\n"
                "| sub | `fade` | 0 | 207 | 0 |\n| sub | `morph` | 23.7 | 232 | 2 |\n")
        text = " ".join(w[2] for w in lint_mod.lint([], body))
        self.assertIn("variable under test", text)
        self.assertIn("run count", text)
        self.assertIn("'gap px' value for 'long' is ~0", text)


class SidecarTests(Fixture):
    def test_null_fields_warn(self) -> None:
        warnings = lint_mod.lint([self.file("s.png", png(720, 640), {"crop_bounds": [0, 0, 1, 1]})])
        self.assertEqual([w[1] for w in warnings], ["sidecar-gaps"])
        self.assertIn("variable, control, runs", warnings[0][2])

    def test_too_few_runs_warn(self) -> None:
        side = {"variable": "look", "control": "default", "runs": 1}
        self.assertEqual(self.rules([self.file("s.png", png(720, 640), side)]), ["sidecar-gaps"])

    def test_a_full_sidecar_is_quiet(self) -> None:
        side = {"variable": "look", "control": "default", "runs": 3}
        self.assertEqual(self.rules([self.file("s.png", png(720, 640), side)]), [])


HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
FULL_SIDE = {"variable": "look", "control": "default", "runs": 3}


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg and ffprobe")
class ClipTests(Fixture):
    """Tiny 64x48 clips made by ffmpeg at test time."""

    def clip(self, name: str, *lavfi: str) -> tuple[str, Path]:
        path = self.dir / name
        args = ["ffmpeg", "-v", "error", "-nostdin", "-y"]
        for source in lavfi:
            args += ["-f", "lavfi", "-i", source]
        if len(lavfi) > 1:
            args += ["-filter_complex", "".join(f"[{i}:v]" for i in range(len(lavfi))) +
                     f"concat=n={len(lavfi)}:v=1:a=0"]
        if path.suffix == ".mp4":
            args += ["-c:v", "mpeg4", "-pix_fmt", "yuv420p"]
        subprocess.run(args + [str(path)], check=True, capture_output=True, timeout=60)
        return name, path

    def test_a_long_static_clip_is_too_long_and_static(self) -> None:
        name, path = self.clip("long.mp4", "color=c=gray:s=64x48:r=1:d=22")
        warnings = lint_mod.lint([(name, path)])
        self.assertEqual(sorted(w[1] for w in warnings), ["clip-no-early-difference", "clip-too-long"])
        too_long = next(w[2] for w in warnings if w[1] == "clip-too-long")
        self.assertRegex(too_long, r"2[12]\.\d s long")
        self.assertIn("media_polish.py trim", too_long)
        self.assertIn("sbs", too_long)

    def test_static_for_four_seconds_then_changing_warns(self) -> None:
        clip = self.clip("late.mp4", "color=c=blue:s=64x48:r=4:d=4", "testsrc=s=64x48:r=4:d=2")
        warnings = lint_mod.lint([clip])
        self.assertEqual([w[1] for w in warnings], ["clip-no-early-difference"])
        self.assertIn("first 3 s are static", warnings[0][2])

    def test_a_clip_changing_from_the_first_frame_is_quiet(self) -> None:
        self.assertEqual(self.rules([self.clip("busy.mp4", "testsrc=s=64x48:r=4:d=4")]), [])

    def test_a_gif_is_a_clip(self) -> None:
        self.assertEqual(self.rules([self.clip("late.gif", "color=c=red:s=64x48:r=4:d=4",
                                               "testsrc=s=64x48:r=4:d=1")]), ["clip-no-early-difference"])
        self.assertEqual(self.rules([self.clip("busy.gif", "testsrc=s=64x48:r=4:d=4")]), [])


class ClipSidecarAndPairTests(Fixture):
    """No ffmpeg needed: durations from the sidecar, pairs from names."""

    def test_sidecar_duration_or_trim_counts_when_ffprobe_cannot_read(self) -> None:
        with mock.patch.object(lint_mod.shutil, "which", return_value=None):
            for extra in ({"duration": 25}, {"trim": {"start": 5, "end": 40, "diverge_start": 30,
                                                      "diverge_end": 38, "source_duration": 60}}):
                with self.subTest(extra=extra):
                    side = dict(FULL_SIDE, **extra)
                    self.assertEqual(self.rules([self.file("t.mp4", b"\0", side)]), ["clip-too-long"])
            side = dict(FULL_SIDE, trim={"start": 28, "end": 40})
            self.assertEqual(self.rules([self.file("t.webm", b"\0", side)]), [])

    def test_a_before_after_clip_pair_gets_the_sbs_hint(self) -> None:
        with mock.patch.object(lint_mod.shutil, "which", return_value=None):
            warnings = lint_mod.lint([self.file("fold-before.mp4", b"\0"), self.file("fold-after.mp4", b"\0")])
        self.assertEqual([w[1] for w in warnings], ["clip-pair-sbs"])
        self.assertIn("media_polish.py sbs fold-before.mp4 fold-after.mp4 --out X.mp4", warnings[0][2])

    def test_still_pairs_and_lone_clips_get_no_hint(self) -> None:
        with mock.patch.object(lint_mod.shutil, "which", return_value=None):
            self.assertEqual(self.rules([self.file("fold-before.png", png(720, 640)),
                                         self.file("fold-after.png", png(720, 640)),
                                         self.file("tour.mp4", b"\0")]), [])


class CliTests(Fixture):
    def run_main(self, argv, stdin="") -> tuple[int, str]:
        out = io.StringIO()
        with mock.patch.dict(lint_mod.os.environ, {}, clear=False):
            lint_mod.os.environ.pop("GITHUB_ACTIONS", None)
            code = lint_mod.main(argv, io.StringIO(stdin), out)
        return code, out.getvalue()

    def test_warnings_go_out_and_exit_is_zero(self) -> None:
        _, path = self.file("s.png", png(2880, 1800))
        code, text = self.run_main(["--body", "-", str(path)], json.dumps({"body": GOOD_BODY}))
        self.assertEqual(code, 0)
        self.assertEqual(text.splitlines(), [line for line in text.splitlines() if line.startswith("warning: ")])
        self.assertIn("uncropped-full-display", text)

    def test_a_crash_exits_zero_with_one_line(self) -> None:
        with mock.patch.object(lint_mod, "lint", side_effect=RuntimeError("boom")):
            code, text = self.run_main([])
        self.assertEqual(code, 0)
        self.assertEqual(len(text.splitlines()), 1)
        self.assertIn("crashed", text)

    def test_bad_arguments_and_missing_files_exit_zero(self) -> None:
        with mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(self.run_main(["--nope"])[0], 0)
        self.assertEqual(self.run_main(["--body", str(self.dir / "missing.md")])[0], 0)

    def test_annotations_only_under_github_actions(self) -> None:
        out = io.StringIO()
        lint_mod.report([("a.png", "sidecar-gaps", "fix 100%")], out, env={"GITHUB_ACTIONS": "true"})
        self.assertIn("::warning file=a.png,title=pr-media-lint sidecar-gaps::fix 100%25", out.getvalue())
        out = io.StringIO()
        lint_mod.report([("a.png", "sidecar-gaps", "fix")], out, env={})
        self.assertNotIn("::", out.getvalue())


if __name__ == "__main__":
    unittest.main()
