#!/usr/bin/env python3
"""The nightly-next visual smoke (scripts/cmux-next/visual-smoke/): its judge
passes a drawn window and fails the visibly broken ones (blank, black, tiny, no
sidebar, empty transcript, missing composer, a layout far from the reference),
it tolerates small text changes, and nightly.yml runs it as a publish gate."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
SMOKE = ROOT / "scripts/cmux-next/visual-smoke"
spec = importlib.util.spec_from_file_location("visual_check", SMOKE / "visual_check.py")
vc = importlib.util.module_from_spec(spec)
sys.modules["visual_check"] = vc
spec.loader.exec_module(vc)

WHITE, INK, PANEL = 250, 40, 236


def encode_png(path, width, height, rows, channels, filters=(0,)):
    """rows: one bytes object per row, channels bytes per pixel; each row uses the next filter."""
    color = {1: 0, 2: 4, 3: 2, 4: 6}[channels]
    bpp, out, prev = channels, b"", bytes(width * channels)
    for y, row in enumerate(rows):
        kind = filters[y % len(filters)]
        enc = bytearray(len(row))
        for i, value in enumerate(row):
            left = row[i - bpp] if i >= bpp else 0
            up, corner = prev[i], (prev[i - bpp] if i >= bpp else 0)
            pred = [0, left, up, (left + up) // 2, vc._paeth(left, up, corner)][kind]
            enc[i] = (value - pred) & 0xFF
        out += bytes([kind]) + bytes(enc)
        prev = row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    Path(path).write_bytes(vc.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(out)) + chunk(b"IEND", b""))


class Canvas:
    """A grayscale window mock: flat panels with rows of text-like dashes."""

    def __init__(self, width, height, fill=WHITE):
        self.width, self.height = width, height
        self.px = bytearray([fill]) * (width * height)

    def rect(self, box, value):
        x0, y0, x1, y1 = (int(box[0] * self.width), int(box[1] * self.height), int(box[2] * self.width), int(box[3] * self.height))
        for y in range(y0, y1):
            self.px[y * self.width + x0:y * self.width + x1] = bytes([value]) * (x1 - x0)

    def text(self, box, seed=0):
        """Lines of 'words': 2-px-high dashes, 14 px apart."""
        x0, y0, x1, y1 = (int(box[0] * self.width), int(box[1] * self.height), int(box[2] * self.width), int(box[3] * self.height))
        for line, y in enumerate(range(y0 + 4, y1 - 4, 14)):
            x = x0 + 4 + (line * 7 + seed) % 11
            while x + 6 < x1 - 4:
                word = 6 + (x * 31 + line * 17 + seed) % 18
                for yy in (y, y + 1):
                    end = min(x + word, x1 - 4)
                    self.px[yy * self.width + x:yy * self.width + end] = bytes([INK]) * (end - x)
                x += word + 5

    def save(self, path):
        rows = [bytes(self.px[y * self.width:(y + 1) * self.width]) for y in range(self.height)]
        encode_png(path, self.width, self.height, rows, 1)


def window(width=620, height=400, sidebar=True, main=True, composer=True, seed=0, sidebar_right=False):
    c = Canvas(width, height)
    side = (0.83, 0, 1, 1) if sidebar_right else (0, 0, 0.2, 1)
    c.rect(side, PANEL)
    if sidebar:
        c.text((side[0] + 0.01, 0.08, side[2] - 0.01, 0.6), seed)
    content = (0.02, 0.1, 0.8, 0.65) if sidebar_right else (0.22, 0.1, 0.98, 0.65)
    if main:
        c.text(content, seed)
    if composer:
        box = (content[0], 0.82, content[2], 0.92)
        c.rect(box, 200)
        c.rect((box[0] + 0.005, box[1] + 0.01, box[2] - 0.005, box[3] - 0.01), WHITE)
        c.text((box[0] + 0.01, box[1], box[0] + 0.3, box[3]), seed)
    return c


def scene_window(name, seed=0):
    """A mock of each shipped scene at the real window's layout (scenes.json boxes): Home's
    sidebar, Chief column with its composer and New Tab; a new chat (its composer, the
    Inspector at the right); a chat with a prompt bubble, a reply and its composer."""
    c = Canvas(620, 400)
    c.rect((0, 0, 0.2, 1), PANEL)
    c.text((0.01, 0.08, 0.19, 0.6), seed)

    def composer(box):
        c.rect(box, 200)
        c.rect((box[0] + 0.005, box[1] + 0.01, box[2] - 0.005, box[3] - 0.01), WHITE)
        c.text((box[0] + 0.01, box[1], box[0] + 0.2, box[3]), seed)
    if name == "home":
        c.text((0.59, 0.14, 0.95, 0.58), seed)  # the Chief welcome pane
        composer((0.59, 0.9, 0.98, 0.995))
        composer((0.62, 0.15, 0.98, 0.3))  # New Tab's Ask anything
    else:
        c.rect((0.68, 0.06, 1, 1), PANEL)  # the chat's Inspector
        c.text((0.69, 0.08, 0.99, 0.2), seed)
        if name == "composer":
            c.text((0.3, 0.38, 0.6, 0.46), seed)  # the new chat's heading
            composer((0.24, 0.78, 0.64, 0.92))
        else:
            c.rect((0.47, 0.06, 0.65, 0.14), 160)  # the prompt bubble, right-aligned
            c.text((0.48, 0.07, 0.64, 0.13), seed)
            c.text((0.23, 0.18, 0.44, 0.38), seed)  # the reply
            composer((0.24, 0.82, 0.64, 0.92))
    return c


TINY_SCENES = {
    "defaults": {"min_size": [100, 60], "min_edge": 0.008, "max_dark": 0.9, "max_flat": 0.99,
                 "min_region_edge": 0.004, "min_ssim": 0.75},
    "scenes": {"shot": {"regions": {"sidebar": {"box": [0.01, 0.08, 0.17, 0.75], "min_edge": 0.006},
                                    "messages": {"box": [0.2, 0.08, 0.99, 0.7], "min_edge": 0.006},
                                    "composer": {"box": [0.2, 0.7, 0.99, 1.0]}}}},
}


class Judge(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "scenes.json").write_text(json.dumps(TINY_SCENES))
        (self.dir / "shots").mkdir()
        (self.dir / "refs").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def judge(self, canvas, reference=None):
        canvas.save(self.dir / "shots/shot.png")
        if reference is not None:
            reference.save(self.dir / "refs/shot.png")
        report = vc.run(self.dir / "scenes.json", self.dir / "shots", self.dir / "refs", self.dir / "report.json")
        return report["scenes"][0]

    def assertFails(self, result, words):
        self.assertFalse(result["ok"], result)
        self.assertTrue(any(words in f for f in result["failures"]), result["failures"])

    def test_a_drawn_window_passes(self):
        result = self.judge(window(220, 140))
        self.assertTrue(result["ok"], result)

    def test_a_blank_window_fails(self):
        self.assertFails(self.judge(Canvas(220, 140)), "blank")

    def test_an_opaque_black_window_fails(self):
        self.assertFails(self.judge(Canvas(220, 140, fill=0)), "opaque black")

    def test_a_collapsed_window_fails(self):
        self.assertFails(self.judge(window(90, 50)), "smaller than")

    def test_a_missing_sidebar_fails(self):
        self.assertFails(self.judge(window(220, 140, sidebar=False)), "sidebar is empty")

    def test_an_empty_transcript_fails(self):
        self.assertFails(self.judge(window(220, 140, main=False)), "messages is empty")

    def test_a_missing_composer_fails(self):
        self.assertFails(self.judge(window(220, 140, composer=False)), "composer is empty")

    def test_a_missing_capture_fails(self):
        report = vc.run(self.dir / "scenes.json", self.dir / "shots", None, None)
        self.assertFalse(report["ok"])
        self.assertIn("no capture", report["scenes"][0]["failures"][0])

    def test_other_text_with_the_same_layout_matches_the_reference(self):
        result = self.judge(window(220, 140, seed=5), reference=window(220, 140, seed=0))
        self.assertTrue(result["ok"], result)
        self.assertGreater(result["metrics"]["reference_ssim"], 0.8)
        self.assertTrue((self.dir / "shots/shot-diff.png").exists())

    def test_a_large_layout_shift_fails_the_reference(self):
        # The sidebar moved to the right edge: every region still holds content where the
        # structural boxes look, so only the reference catches it.
        shifted = window(220, 140, sidebar_right=True)
        result = self.judge(shifted, reference=window(220, 140))
        self.assertFails(result, "layout differs")

    def test_no_reference_means_structure_only(self):
        result = self.judge(window(220, 140))
        self.assertNotIn("reference_ssim", result["metrics"])


class PngReader(unittest.TestCase):
    def test_every_filter_and_alpha_on_white(self):
        width, height = 9, 10
        rgba = [bytes(v for x in range(width) for v in ((x * 29 + y * 7) % 256, (x * 3) % 256, (y * 40) % 256, 0 if x == 0 else 255))
                for y in range(height)]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.png"
            encode_png(path, width, height, rgba, 4, filters=(0, 1, 2, 3, 4))
            image = vc.read_png(path)
        self.assertEqual((image.width, image.height), (width, height))
        for y in range(height):
            self.assertEqual(image.at(0, y), 255)  # fully transparent: the white backdrop
            r, g, b = (5 * 29 + y * 7) % 256, 15, (y * 40) % 256
            self.assertEqual(image.at(5, y), (299 * r + 587 * g + 114 * b) // 1000)

    def test_written_png_reads_back(self):
        image = vc.Gray(3, 2, bytearray([0, 128, 255, 10, 20, 30]))
        with tempfile.TemporaryDirectory() as tmp:
            vc.write_png(Path(tmp) / "g.png", image)
            back = vc.read_png(Path(tmp) / "g.png")
        self.assertEqual(bytes(back.pixels), bytes(image.pixels))


class ShippedScenes(unittest.TestCase):
    """scenes.json as shipped, on a mock of the real 1000x640 window scaled to the minimum size."""

    def test_real_home_with_one_chief_conversation_is_drawn(self):
        config = json.loads((SMOKE / "scenes.json").read_text())
        fixture = ROOT / "tests/fixtures/nightly-visual-smoke/home-list.png"
        result = vc.check_scene("home", config["scenes"]["home"], config["defaults"], fixture)
        self.assertTrue(result["ok"], result["failures"])

    def test_real_home_requires_each_named_region(self):
        config = json.loads((SMOKE / "scenes.json").read_text())
        fixture = ROOT / "tests/fixtures/nightly-visual-smoke/home-list.png"
        for name, region in config["scenes"]["home"]["regions"].items():
            with self.subTest(region=name), tempfile.TemporaryDirectory() as tmp:
                image = vc.load(fixture)
                left, top, right, bottom = vc.region_box(image, region["box"])
                for y in range(top, bottom):
                    image.pixels[y * image.width + left:y * image.width + right] = bytes([255]) * (right - left)
                shot = Path(tmp) / "home.png"
                vc.write_png(shot, image)
                result = vc.check_scene("home", config["scenes"]["home"], config["defaults"], shot)
                self.assertTrue(any(f.startswith(f"{name} is empty") for f in result["failures"]), result)

    def test_shipped_limits_pass_a_drawn_window_and_fail_a_blank_one(self):
        config = json.loads((SMOKE / "scenes.json").read_text())
        self.assertEqual(list(config["scenes"]), ["home", "composer", "transcript"])
        with tempfile.TemporaryDirectory() as tmp:
            shots = Path(tmp)
            for name in config["scenes"]:
                scene_window(name).save(shots / f"{name}.png")
            report = vc.run(SMOKE / "scenes.json", shots, None, None)
            self.assertTrue(report["ok"], json.dumps(report, indent=1))
            Canvas(620, 400).save(shots / "transcript.png")
            report = vc.run(SMOKE / "scenes.json", shots, None, None)
            self.assertEqual([r["ok"] for r in report["scenes"]], [True, True, False])

    def test_a_scene_that_repeats_another_fails(self):
        # The driver never reached the new chat (it captures it after the transcript), so the
        # capture is the transcript scene again: every region is drawn, but it must still fail.
        config = json.loads((SMOKE / "scenes.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            shots = Path(tmp)
            for name in config["scenes"]:
                scene_window(name).save(shots / f"{name}.png")
            scene_window("transcript", seed=3).save(shots / "composer.png")
            report = vc.run(SMOKE / "scenes.json", shots, None, None)
            composer = report["scenes"][1]
            self.assertFalse(composer["ok"], composer)
            self.assertTrue(any("looks the same as the transcript scene" in f for f in composer["failures"]),
                            composer["failures"])
            self.assertEqual([r["ok"] for r in report["scenes"]], [True, False, True])

    def test_an_empty_chat_beside_a_drawn_inspector_fails(self):
        # The boxes cover the pane under test only: the Inspector's (or a Chief column's)
        # content beside an empty chat must not pass it.
        config = json.loads((SMOKE / "scenes.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            shots = Path(tmp)
            for name in config["scenes"]:
                scene_window(name).save(shots / f"{name}.png")
            empty = Canvas(620, 400)
            empty.rect((0, 0, 0.2, 1), PANEL)
            empty.text((0.01, 0.08, 0.19, 0.6))
            empty.rect((0.68, 0.06, 1, 1), PANEL)
            empty.text((0.69, 0.08, 0.99, 0.9))
            empty.save(shots / "transcript.png")
            transcript = vc.run(SMOKE / "scenes.json", shots, None, None)["scenes"][2]
            self.assertFalse(transcript["ok"], transcript)
            self.assertTrue(any(f.startswith("reply is empty") for f in transcript["failures"]), transcript["failures"])
            self.assertTrue(any(f.startswith("composer is empty") for f in transcript["failures"]), transcript["failures"])

    def shipped_with(self, name, canvas):
        config = json.loads((SMOKE / "scenes.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            shots = Path(tmp)
            for scene in config["scenes"]:
                scene_window(scene).save(shots / f"{scene}.png")
            canvas.save(shots / f"{name}.png")
            report = vc.run(SMOKE / "scenes.json", shots, None, None)
        return next(r for r in report["scenes"] if r["scene"] == name)

    def test_a_chat_with_the_prompt_but_no_reply_fails(self):
        c = scene_window("composer")  # sidebar, Inspector and composer, no heading
        c.rect((0.22, 0.3, 0.66, 0.5), WHITE)
        c.rect((0.47, 0.06, 0.65, 0.14), 160)
        c.text((0.48, 0.07, 0.64, 0.13))
        result = self.shipped_with("transcript", c)
        self.assertEqual([f.split(":")[0] for f in result["failures"]], ["reply is empty"])

    def test_a_new_chat_without_its_composer_fails(self):
        c = scene_window("composer")
        c.rect((0.22, 0.72, 0.66, 0.95), WHITE)  # the heading stays, the composer is gone
        result = self.shipped_with("composer", c)
        self.assertEqual([f.split(":")[0] for f in result["failures"]], ["composer is empty"])

    def test_every_pair_of_scenes_must_differ(self):
        config = json.loads((SMOKE / "scenes.json").read_text())
        names = list(config["scenes"])
        pairs = {frozenset((name, other)) for name, spec in config["scenes"].items() for other in spec.get("distinct_from", [])}
        self.assertEqual(pairs, {frozenset((a, b)) for i, a in enumerate(names) for b in names[i + 1:]})


class Wiring(unittest.TestCase):
    def test_the_driver_captures_every_scene_the_judge_reads(self):
        config = json.loads((SMOKE / "scenes.json").read_text())
        driver = (SMOKE / "drive.py").read_text()
        for name in config["scenes"]:
            self.assertRegex(driver, rf'scene\("{name}"')

    def test_nightly_publishes_only_after_the_visual_smoke(self):
        text = (ROOT / ".github/workflows/nightly.yml").read_text()
        job = text[text.index("\n  verify-signed-nightly:\n"):text.index("\n  verify-final-dmg-nightly:\n")]
        step = job[job.index("- name: Visual smoke the signed app"):]
        step = step[:step.index("\n      - name:", 1)]
        self.assertIn('visual-smoke/gate.sh "$CHANNEL_APP_PATH"', step)
        # Enforced: no continue-on-error and no repository variable can skip it.
        self.assertNotIn("continue-on-error", step)
        self.assertNotIn("vars.", step)
        recovered = text[text.index("\n  verify-recovered-nightly-next:\n"):text.index("\n  publish-nightly:\n")]
        self.assertIn("- name: Visual smoke the recovered app", recovered)
        self.assertIn("visual-smoke/gate.sh", recovered)
        publish = text[text.index("\n  publish-nightly:\n"):]
        needs = [n.strip() for n in re.search(r"\n    needs: \[([^\]]*)\]", publish).group(1).split(",")]
        self.assertIn("verify-signed-nightly", needs)
        self.assertIn("verify-recovered-nightly-next", needs)

    def test_the_gate_fails_unless_an_attempt_passes(self):
        gate = (SMOKE / "gate.sh").read_text()
        self.assertIn('smoke-signed-app-cli.sh" "$app" --visual', gate)
        self.assertIn("for attempt in 1 2", gate)
        self.assertTrue(gate.rstrip().endswith("exit 1"))

    def test_the_smoke_has_a_visual_mode(self):
        smoke = (ROOT / "scripts/smoke-signed-app-cli.sh").read_text()
        self.assertIn('"$2" == "--visual"', smoke)
        self.assertIn("visual-smoke/drive.py", smoke)
        self.assertIn("visual-smoke/visual_check.py", smoke)


if __name__ == "__main__":
    unittest.main()
