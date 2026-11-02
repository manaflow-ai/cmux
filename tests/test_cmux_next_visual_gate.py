#!/usr/bin/env python3
"""The nightly visual gate's checks (scripts/cmux-next/visual-gate/visual_gate.py) on
synthetic stills and text-box fixtures, so they run on Linux without Vision; the
state files load; and nightly.yml wires the gate in front of publish-nightly."""

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import plistlib
import re
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/cmux-next/visual-gate"
sys.path.insert(0, str(ROOT / "tests"))
from nightly_workflow_text import nightly_text  # noqa: E402
spec = importlib.util.spec_from_file_location("visual_gate", GATE / "visual_gate.py")
gate = importlib.util.module_from_spec(spec)
sys.modules["visual_gate"] = gate
spec.loader.exec_module(gate)


def png(width: int, height: int, pixel, *, channels: int = 4, filter_type: int = 0) -> bytes:
    """An 8-bit RGBA (or RGB) PNG; pixel(x, y) gives (r, g, b). Every row uses `filter_type`."""
    rows = []
    prev = bytearray(width * channels)
    for y in range(height):
        line = bytearray()
        for x in range(width):
            r, g, b = pixel(x, y)
            line += bytes((r, g, b, 255)[:channels])
        encoded = bytearray(line)
        if filter_type == 1:
            encoded = bytearray((line[i] - (line[i - channels] if i >= channels else 0)) & 0xFF for i in range(len(line)))
        elif filter_type == 2:
            encoded = bytearray((line[i] - prev[i]) & 0xFF for i in range(len(line)))
        elif filter_type == 3:
            encoded = bytearray((line[i] - (((line[i - channels] if i >= channels else 0) + prev[i]) >> 1)) & 0xFF
                                for i in range(len(line)))
        elif filter_type == 4:
            def paeth(a, b, c):
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                return a if pa <= pb and pa <= pc else b if pb <= pc else c
            encoded = bytearray((line[i] - paeth(line[i - channels] if i >= channels else 0, prev[i],
                                                 prev[i - channels] if i >= channels else 0)) & 0xFF
                                for i in range(len(line)))
        rows.append(bytes((filter_type,)) + bytes(encoded))
        prev = line

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    color = 6 if channels == 4 else 2
    return (gate.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def light_ui(x, y):
    """A light window: a sidebar, content and a darker card."""
    if x < 20:
        return (230, 230, 232)
    if 40 <= x < 70 and 10 <= y < 30:
        return (200, 200, 205)
    return (250, 250, 250)


def dark_ui(x, y):
    if x < 20:
        return (40, 40, 44)
    if 40 <= x < 70 and 10 <= y < 30:
        return (60, 60, 66)
    return (28, 28, 30)


def with_seam(base, at: int, colour=(0, 0, 0), *, axis: str = "x", start: int = 0, end: int = 10_000, gaps=()):
    def pixel(x, y):
        pos, along = (x, y) if axis == "x" else (y, x)
        if pos == at and start <= along < end and along not in gaps:
            return colour
        return base(x, y)
    return pixel


def decode(data: bytes):
    return gate.decode_png(data)


class PngTests(unittest.TestCase):
    def test_every_filter_decodes_to_the_same_pixels(self):
        pixel = lambda x, y: ((x * 37 + y * 11) % 256, (x * 5) % 256, (y * 9) % 256)
        want = decode(png(13, 7, pixel, filter_type=0)).pixels
        for kind in (1, 2, 3, 4):
            self.assertEqual(decode(png(13, 7, pixel, filter_type=kind)).pixels, want, f"filter {kind}")

    def test_rgb_and_rgba(self):
        rgb = decode(png(3, 2, lambda x, y: (10, 20, 30), channels=3))
        self.assertEqual((rgb.width, rgb.height, rgb.channels), (3, 2, 3))
        self.assertEqual(rgb.luminance(), bytes([18] * 6))
        self.assertEqual(rgb.chroma(), bytes([20] * 6))

    def test_refuses_what_it_cannot_read(self):
        with self.assertRaises(gate.BadInput):
            decode(b"GIF89a")


class StepsTests(unittest.TestCase):
    def test_failed_required_step_and_errors_fail_optional_is_info(self):
        result = {"steps": [{"title": "seed", "status": "ok"},
                            {"title": "ready", "status": "unavailable", "detail": "no page"},
                            {"title": "load", "status": "failed", "detail": "timeout"}],
                  "errors": ["dark still: no image"]}
        found = gate.check_steps(result, {"light.png": True, "dark.png": False})
        levels = [(f["level"], f["message"]) for f in found]
        self.assertIn(("info", "optional step unavailable: ready: no page"), levels)
        self.assertIn(("fail", "step failed: load: timeout"), levels)
        self.assertIn(("fail", "capture error: dark still: no image"), levels)
        self.assertIn(("fail", "dark.png is missing"), levels)

    def test_all_ok_has_no_failures(self):
        found = gate.check_steps({"steps": [{"title": "a", "status": "ok"}]}, {"light.png": True, "dark.png": True})
        self.assertEqual([f for f in found if f["level"] == "fail"], [])


def appearance(light: dict, dark: dict | None = None, **result):
    return {"host": "mini-7", "settings_source": "own",
            "appearance": {"light": light, "dark": dark or {"effective": "dark", "terminal_background": "#1E1E1E",
                                                          "themes": "/x/ghostty/themes"}}, **result}


LIGHT_OK = {"effective": "light", "terminal_background": "#FFFFFF", "themes": "/x/ghostty/themes"}


class AppearanceTests(unittest.TestCase):
    def same(self, result):
        light = decode(png(80, 40, light_ui))
        return gate.check_appearance(light, light, result)[0]

    def test_identical_stills_are_the_builds_fault_when_the_app_says_so(self):
        cases = {
            "stayed dark": appearance({"effective": "dark"}),
            "ships no Ghostty themes": appearance({"effective": "light", "terminal_background": "#1E1E1E", "themes": None}),
            "on the app's own settings": appearance({**LIGHT_OK, "terminal_background": "#1E1E1E"}),
            "did not repaint": appearance(LIGHT_OK),
        }
        for words, result in cases.items():
            found = self.same(result)
            self.assertEqual(found["level"], "fail", words)
            self.assertIn("same picture", found["message"])
            self.assertIn(words, found["message"])

    def test_identical_stills_are_host_drift_on_the_macs_own_settings(self):
        # cmux-mac-mini's shared cmux-next.json pinned a dark-only theme: every light still was dark.
        found = self.same(appearance({**LIGHT_OK, "terminal_background": "#000000"}, settings_source="host"))
        self.assertEqual(found["level"], "host")
        self.assertIn("mini-7", found["message"])
        self.assertEqual(found["host"], "mini-7")

    def test_identical_stills_without_the_apps_word_are_not_pinned_on_the_build(self):
        # HQ pr-capture's result.json records no appearance (the 3a63d6d9 stills).
        found = self.same({"host": "cmux-mac-mini-cua", "steps": []})
        self.assertEqual(found["level"], "host")
        self.assertIn("cmux-mac-mini-cua", found["message"])

    def test_a_real_switch_passes(self):
        found = gate.check_appearance(decode(png(80, 40, light_ui)), decode(png(80, 40, dark_ui)))
        self.assertEqual(found[0]["level"], "info", found)

    def test_a_small_change_is_still_the_same_picture(self):
        # A blinking caret or a spinner frame differs; the theme did not change.
        moved = lambda x, y: (0, 0, 0) if (x, y) == (50, 20) else light_ui(x, y)
        found = gate.check_appearance(decode(png(80, 40, light_ui)), decode(png(80, 40, moved)), appearance(LIGHT_OK))
        self.assertEqual(found[0]["level"], "fail")

    def test_inverted_is_a_warning(self):
        found = gate.check_appearance(decode(png(80, 40, dark_ui)), decode(png(80, 40, light_ui)))
        self.assertEqual(found[0]["level"], "warn")


class ScaleTests(unittest.TestCase):
    def test_1x_warns_2x_passes_unknown_warns(self):
        image = decode(png(110, 72, light_ui))
        self.assertEqual(gate.check_scale(image, [110, 72])[0]["level"], "warn")
        self.assertEqual(gate.check_scale(image, [55, 36])[0]["level"], "info")
        self.assertIn("unknown", gate.check_scale(image, None)[0]["message"])
        self.assertIn("backing scale 1x", gate.check_scale(image, [110, 72])[0]["message"])

    def test_the_require_switch_turns_below_2x_into_a_failure(self):
        image = decode(png(110, 72, light_ui))
        self.assertEqual(gate.check_scale(image, [110, 72], require=True)[0]["level"], "fail")
        self.assertEqual(gate.check_scale(image, None, require=True)[0]["level"], "fail")
        self.assertEqual(gate.check_scale(image, [55, 36], require=True)[0]["level"], "info")


class SeamTests(unittest.TestCase):
    def seams(self, pixel, width=120, height=80):
        image = decode(png(width, height, pixel))
        return gate.find_seams(image.luminance(), image.chroma(), width, height)

    def test_full_height_black_column_in_a_light_window(self):
        found = self.seams(with_seam(light_ui, 90, start=5))
        self.assertEqual([(s["axis"], s["at"], s["width"]) for s in found], [("x", 90, 1)])
        self.assertGreaterEqual(found[0]["fraction"], 0.9)

    def test_column_in_the_dark_still_and_a_row(self):
        self.assertEqual([s["at"] for s in self.seams(with_seam(dark_ui, 100, colour=(0, 0, 0)))], [])  # too close to the background
        self.assertEqual([s["at"] for s in self.seams(with_seam(dark_ui, 100, colour=(140, 140, 140)))], [100])
        rows = self.seams(with_seam(light_ui, 50, axis="y"))
        self.assertEqual([(s["axis"], s["at"]) for s in rows], [("y", 50)])

    def test_text_crossing_the_seam_does_not_break_it(self):
        found = self.seams(with_seam(light_ui, 90, gaps=set(range(30, 36))))
        self.assertEqual([s["at"] for s in found], [90])

    def test_two_px_seam_at_2x(self):
        def pixel(x, y):
            return (0, 0, 0) if x in (90, 91) else light_ui(x, y)
        found = self.seams(pixel)
        self.assertEqual([(s["at"], s["width"]) for s in found], [(90, 2)])
        # Content beside the run (a control drawn over its last rows) does not hide it.
        def covered(x, y):
            return (200, 0, 0) if y >= 70 and x in (90, 91) else pixel(x, y)
        self.assertEqual([(s["at"], s["width"]) for s in self.seams(covered)], [(90, 2)])

    def test_short_lines_edges_and_coloured_lines_are_not_seams(self):
        self.assertEqual(self.seams(with_seam(light_ui, 90, end=30)), [])               # 37% of the height
        self.assertEqual(self.seams(light_ui), [])                                       # the sidebar's edge is a step, not a line
        self.assertEqual(self.seams(with_seam(light_ui, 90, colour=(0, 120, 255))), [])  # a focus ring or accent

    def test_check_names_the_image(self):
        found = gate.check_seams(decode(png(120, 80, with_seam(light_ui, 90))), "light.png")
        self.assertEqual(found[0]["level"], "fail")
        self.assertIn("light.png: 1-px vertical seam at x=90", found[0]["message"])


def obs(text, box, **extra):
    return {"text": text, "confidence": 1.0, "box": box, **extra}


class OverlapTests(unittest.TestCase):
    def test_separate_boxes_that_overlap_fail(self):
        # Like the 3a63d6d9 long-session still: a queued prompt drawn over the Environment card,
        # here read as two lines whose boxes overlap.
        boxes = {"observations": [obs("Check the orders API still returns the", [362, 140, 238, 12]),
                                  obs("cmux ~/code", [378, 144, 84, 12]),
                                  obs("Working for 2s", [226, 230, 96, 14])]}
        found = gate.check_overlaps(boxes, "light.png")
        self.assertEqual([f["level"] for f in found], ["fail"])
        self.assertIn("overlaps", found[0]["message"])

    def test_neighbouring_lines_and_tiny_glyphs_pass(self):
        boxes = {"observations": [obs("Tell it what you want done.", [856, 242, 210, 14]),
                                  obs("quick things itself and hands", [858, 256, 206, 14]),
                                  obs(".", [900, 250, 3, 3])]}
        self.assertEqual(gate.check_overlaps(boxes, "light.png"), [])

    def test_missing_or_malformed_boxes_are_not_judged(self):
        # The overlap check could not run: an error (the run is `unavailable`), never a pass.
        self.assertEqual(gate.check_overlaps(None, "dark.png")[0]["level"], "error")
        self.assertEqual(gate.check_overlaps({"observations": "x"}, "dark.png")[0]["level"], "error")

    def lines(self, *special):
        normal = [obs(f"An ordinary line of text {i}", [10, 20 * i, 200, 14]) for i in range(6)]
        return {"observations": normal + list(special)}

    def test_a_tall_line_that_stays_garbled_fails(self):
        # 3a63d6d9: the Outputs card drawn over a chat message.
        bad = obs("It concatenates withutuatiosol'lladdan optionals-8", [226, 331, 408, 21],
                  reread={"lines": [{"text": "It concatenates withgutguefhatiorso I'll add an optionals -8",
                                     "box": [226, 331, 408, 21]}],
                          "misspelled": ["withgutguefhatiorso"]})
        found = gate.check_overlaps(self.lines(bad), "light.png")
        self.assertEqual(len(found), 1)
        self.assertIn("text over text", found[0]["message"])

    def test_a_tall_line_whose_reread_stacks_lines_on_each_other_fails(self):
        # A tab title under a "Terminal failed" toast reads as "Hoerminal failed".
        bad = obs("@ Hoerminal failed", [215, 6, 110, 30],
                  reread={"lines": [{"text": "Hame", "box": [220, 10, 40, 16]},
                                    {"text": "Terminal failed", "box": [232, 12, 90, 16]}], "misspelled": ["Hame"]})
        self.assertEqual(len(gate.check_overlaps(self.lines(bad), "light.png")), 1)

    def test_two_wrapped_lines_read_as_one_pass(self):
        ok = obs("Dow now, wah the pr status ir dsthare one", [325, 119, 257, 32],
                 reread={"lines": [{"text": "Done: the tab and session cards share one", "box": [325, 119, 257, 14]},
                                   {"text": "row now, with the PR status in color.", "box": [325, 137, 220, 14]}],
                         "misspelled": []})
        self.assertEqual(gate.check_overlaps(self.lines(ok), "light.png"), [])

    def test_a_word_clipped_at_a_pane_edge_and_product_names_pass(self):
        clipped = obs("paragraph. This sentence adds some width to the pa", [292, 441, 492, 23],
                      reread={"lines": [{"text": "paragraph. This sentence adds some width. This sentenc",
                                         "box": [292, 441, 492, 23]}], "misspelled": ["sentenc"]})
        named = obs("Open the acpmux session list", [10, 300, 220, 22],
                    reread={"lines": [{"text": "Open the acpmux session list", "box": [10, 300, 220, 22]}],
                            "misspelled": ["acpmux"]})
        self.assertEqual(gate.check_overlaps(self.lines(clipped, named), "light.png"), [])

    def test_wrapped_lines_read_together_and_again_are_not_an_overlap(self):
        # 5ae65cd7: Vision ran two wrapped lines together and read the second again on its own.
        joined = obs("Dow now, wah the pr status ir dsthare one", [325, 119, 257, 32],
                     reread={"lines": [{"text": "Done: the tab and session cards share one", "box": [325, 119, 257, 14]},
                                       {"text": "row now, with the PR status in color.", "box": [325, 137, 220, 14]}],
                             "misspelled": []})
        again = obs("row now, with the PR status in color.", [332, 136, 208, 17])
        self.assertEqual(gate.check_overlaps(self.lines(joined, again), "light.png"), [])

    def test_a_large_heading_with_one_jargon_word_passes(self):
        # A heading reads taller than body text; one word the spell checker lacks (and that
        # differs by host) reads the same in the reread, so it is not text over text.
        heading = obs("Kubernetes deployment overview", [10, 300, 320, 26], misspelled=["Kubernetes"],
                      reread={"lines": [{"text": "Kubernetes deployment overview", "box": [10, 300, 320, 26]}],
                              "misspelled": ["Kubernetes"]})
        self.assertEqual(gate.check_overlaps(self.lines(heading), "light.png"), [])
        # Without a reread one steady word is no evidence either.
        bare = obs("Kubernetes deployment overview", [10, 300, 320, 26], misspelled=["Kubernetes"])
        self.assertEqual(gate.check_overlaps(self.lines(bare), "light.png"), [])

    def test_a_tall_line_with_two_unknown_words_fails(self):
        both = obs("Kubernetes frobnicated overview", [10, 300, 320, 26],
                   reread={"lines": [{"text": "Kubernetes frobnicated overview", "box": [10, 300, 320, 26]}],
                           "misspelled": ["Kubernetes", "frobnicated"]})
        found = gate.check_overlaps(self.lines(both), "light.png")
        self.assertEqual(len(found), 1)
        self.assertIn("garbled 'frobnicated'", found[0]["message"])

    def test_a_garbled_line_of_normal_height_passes(self):
        # Garbled OCR alone (small text, an icon read as letters) is not evidence of overlap.
        meh = obs("Qxzvblorp frenulated nonsense", [10, 300, 200, 14], misspelled=["Qxzvblorp"])
        self.assertEqual(gate.check_overlaps(self.lines(meh), "light.png"), [])


class CaptureDirTests(unittest.TestCase):
    def test_end_to_end_report_and_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            good, bad, drift = Path(tmp) / "good", Path(tmp) / "bad", Path(tmp) / "drift"
            for directory in (good, bad, drift):
                directory.mkdir()
            (good / "light.png").write_bytes(png(120, 80, light_ui))
            (good / "dark.png").write_bytes(png(120, 80, dark_ui))
            (good / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "ok"}],
                                                          "window_points": [60, 40]}))
            (good / "text-boxes.json").write_text(json.dumps({
                str(good / "light.png"): {"observations": []}, str(good / "dark.png"): {"observations": []}}))
            seam = png(120, 80, with_seam(light_ui, 90))
            (bad / "light.png").write_bytes(seam)
            (bad / "dark.png").write_bytes(seam)
            (bad / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "failed"}],
                                                         **appearance({"effective": "dark"})}))
            same = png(120, 80, light_ui)
            (drift / "light.png").write_bytes(same)
            (drift / "dark.png").write_bytes(same)
            (drift / "result.json").write_text(json.dumps({"steps": [], "host": "cmux-mac-mini"}))
            (drift / "text-boxes.json").write_text(json.dumps({"light.png": {"observations": []},
                                                               "dark.png": {"observations": []}}))
            report = Path(tmp) / "report.json"
            summary = Path(tmp) / "summary.md"
            done = subprocess.run([sys.executable, str(GATE / "visual_gate.py"), "--json", str(report),
                                   "--summary", str(summary), str(good), str(bad)],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            reports = json.loads(report.read_text())
            self.assertEqual([r["ok"] for r in reports], [True, False])
            checks = {f["check"] for f in reports[1]["findings"] if f["level"] == "fail"}
            self.assertEqual(checks, {"steps", "appearance", "seam"})
            self.assertIn("| `good` |  | pass |", summary.read_text())
            # Host drift is named and reported, and never fails the gate.
            done = subprocess.run([sys.executable, str(GATE / "visual_gate.py"), str(good), str(drift)],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertIn("host appearance:", done.stdout)
            self.assertIn("cmux-mac-mini", done.stdout)


def good_capture(directory: Path) -> Path:
    directory.mkdir(parents=True)
    (directory / "light.png").write_bytes(png(120, 80, light_ui))
    (directory / "dark.png").write_bytes(png(120, 80, dark_ui))
    (directory / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "ok"}],
                                                       "window_points": [60, 40]}))
    (directory / "text-boxes.json").write_text(json.dumps({"light.png": {"observations": []},
                                                           "dark.png": {"observations": []}}))
    return directory


def run_gate(*args):
    return subprocess.run([sys.executable, str(GATE / "visual_gate.py"), *map(str, args)],
                          capture_output=True, text=True, timeout=120)


class RobustnessTests(unittest.TestCase):
    """One bad file is that state's finding; the other states are still judged, and a gate that
    could not judge is never a build failure (exit 3 or 2, which the workflow reads as unavailable)."""

    def test_missing_or_unreadable_text_boxes_leave_the_state_unjudged(self):
        # The workflow removes a failed read's output, so a missing text-boxes.json is what a failed
        # OCR leaves: the overlap check could not run, so the state is `error` and the run exits 3
        # (`unavailable`), never a pass that enforce mode would publish as checked.
        for content in (None, "", "[]"):
            with tempfile.TemporaryDirectory() as tmp:
                state = good_capture(Path(tmp) / "a")
                if content is None:
                    (state / "text-boxes.json").unlink()
                else:
                    (state / "text-boxes.json").write_text(content)
                report = gate.judge(state)
                self.assertEqual(report["verdict"], "error", (content, report))
                self.assertIn("overlap not checked", " ".join(f["message"] for f in report["findings"]))
                self.assertEqual(run_gate(state).returncode, 3, content)
                # A real failure in the same state still fails it.
                (state / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "failed"}],
                                                               "window_points": [60, 40]}))
                self.assertEqual(gate.judge(state)["verdict"], "fail", content)

    def test_a_bad_png_and_a_bad_result_are_errors_and_the_rest_are_judged(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = good_capture(Path(tmp) / "good")
            bad_png = good_capture(Path(tmp) / "bad-png")
            (bad_png / "dark.png").write_bytes(b"\x89PNG\r\n\x1a\nnot really")
            listed = good_capture(Path(tmp) / "listed")
            (listed / "result.json").write_text(json.dumps({"steps": ["ok"]}))  # a list where a dict belongs
            not_object = good_capture(Path(tmp) / "not-object")
            (not_object / "result.json").write_text("[]")
            report = Path(tmp) / "report.json"
            done = run_gate("--json", report, bad_png, listed, not_object, good)
            self.assertEqual(done.returncode, 3, done.stdout + done.stderr)
            verdicts = {r["state"]: r["verdict"] for r in json.loads(report.read_text())}
            self.assertEqual(verdicts, {"bad-png": "error", "listed": "error", "not-object": "error", "good": "pass"})
            # A real failure elsewhere still fails the gate.
            failed = good_capture(Path(tmp) / "failed")
            (failed / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "failed"}]}))
            self.assertEqual(run_gate(bad_png, failed).returncode, 1)
            # A failed step in the same state as a bad still keeps the state failed: the
            # step's failure is recorded before the still is read, and an error later in
            # the checks must not replace it (that maps to `unavailable` and publishes).
            both = good_capture(Path(tmp) / "both")
            (both / "dark.png").write_bytes(b"\x89PNG\r\n\x1a\nnot really")
            (both / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "failed"}],
                                                          "window_points": [60, 40]}))
            self.assertEqual(gate.judge(both)["verdict"], "fail")
            self.assertEqual(run_gate(both).returncode, 1)

    def test_a_malformed_result_json_is_unjudged_never_a_pass(self):
        # result.json's schema is the capture's contract: no `steps`, a step with no or an unknown
        # status, or `errors` that is not a list leave the state unjudged (`error`, exit 3), never a pass.
        for result in ({"window_points": [60, 40]},
                       {"steps": {"title": "a", "status": "ok"}, "window_points": [60, 40]},
                       {"steps": [{"title": "a"}], "window_points": [60, 40]},
                       {"steps": [{"title": "a", "status": "passed"}], "window_points": [60, 40]},
                       {"steps": [{"title": "a", "status": "ok"}], "errors": "boom", "window_points": [60, 40]}):
            with tempfile.TemporaryDirectory() as tmp:
                state = good_capture(Path(tmp) / "a")
                (state / "result.json").write_text(json.dumps(result))
                report = gate.judge(state)
                self.assertEqual(report["verdict"], "error", (result, report))
                self.assertEqual(run_gate(state).returncode, 3, result)
        # A failed step or a capture error still fails beside a malformed step.
        with tempfile.TemporaryDirectory() as tmp:
            state = good_capture(Path(tmp) / "a")
            (state / "result.json").write_text(json.dumps({"steps": [{"title": "a", "status": "failed"},
                                                                     {"title": "b", "status": "?"}]}))
            self.assertEqual(gate.judge(state)["verdict"], "fail")
            (state / "result.json").write_text(json.dumps({"steps": [], "errors": ["launch failed"]}))
            self.assertEqual(gate.judge(state)["verdict"], "fail")
        # No result.json at all still fails (the capture never finished).
        with tempfile.TemporaryDirectory() as tmp:
            state = good_capture(Path(tmp) / "a")
            (state / "result.json").unlink()
            self.assertEqual(gate.judge(state)["verdict"], "fail")

    def test_stills_of_different_sizes_are_unjudged_never_a_pass(self):
        # Light and dark of different sizes cannot be compared: a malformed capture, so the state is
        # `error` (exit 3, unavailable), never a pass enforce mode would publish as checked.
        with tempfile.TemporaryDirectory() as tmp:
            state = good_capture(Path(tmp) / "a")
            (state / "dark.png").write_bytes(png(100, 80, dark_ui))
            report = gate.judge(state)
            self.assertEqual(report["verdict"], "error", report)
            self.assertIn("not compared", " ".join(f["message"] for f in report["findings"]))
            self.assertEqual(run_gate(state).returncode, 3)

    def test_a_crash_is_exit_2_not_a_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = good_capture(Path(tmp) / "good")
            done = run_gate("--json", Path(tmp) / "missing-dir/report.json", good)
            self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
            self.assertIn("crashed", done.stderr)

    def test_a_state_never_captured_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            states = Path(tmp) / "states"
            states.mkdir()
            for name in ("good", "skipped"):
                (states / f"{name}.json").write_text("{}")
            good = good_capture(Path(tmp) / "out/good")
            self.assertEqual(run_gate(good).returncode, 0)
            report = Path(tmp) / "report.json"
            done = run_gate("--json", report, "--states", states, good)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            skipped = next(r for r in json.loads(report.read_text()) if r["state"] == "skipped")
            self.assertIn("never captured", skipped["findings"][0]["message"])


SCRIPT = ROOT / "scripts/ci/nightly_next_canary_mode.py"


class ModeResolverTests(unittest.TestCase):
    """The canary's resolver, reused under the gate's own variable and issue."""
    SCRIPT = SCRIPT
    ARGS = ["--variable", "NIGHTLY_NEXT_VISUAL_GATE", "--default-enforce-after", "2026-10-28T16:00:00Z",
            "--gate", "visual gate", "--issue-title", "nightly-next visual gate",
            "--failure-prefix", "cmux NEXT visual gate failed ", "--pass-prefix", "cmux NEXT visual gate passed ",
            "--min-passes", "3"]
    spec = importlib.util.spec_from_file_location("canary_mode_for_gate", SCRIPT)
    mode = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mode)
    OPTIONS = dict(variable="NIGHTLY_NEXT_VISUAL_GATE", default_enforce_after="2026-10-28T16:00:00Z",
                   failure_prefix="cmux NEXT visual gate failed ", gate="visual gate",
                   pass_prefix="cmux NEXT visual gate passed ", min_passes=3)

    def resolve(self, *extra, **env):
        return subprocess.run([sys.executable, str(self.SCRIPT), "resolve", *self.ARGS, *extra],
                              capture_output=True, text=True, timeout=60, env={"PATH": "/usr/bin:/bin", **env})

    def test_reads_its_own_variable_not_the_canarys(self):
        done = self.resolve("--now", "2026-10-22T00:00:00Z", NIGHTLY_NEXT_VISUAL_GATE="enforce",
                            NIGHTLY_NEXT_CANARY="off")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("mode=enforce", done.stdout)
        self.assertIn("why=NIGHTLY_NEXT_VISUAL_GATE=enforce", done.stdout)

    def test_unset_reports_until_its_own_date(self):
        done = self.resolve("--now", "2026-10-22T00:00:00Z", NIGHTLY_NEXT_CANARY="enforce")
        self.assertIn("mode=report", done.stdout)
        self.assertIn("until 2026-10-28T16:00Z", done.stdout)

    def test_a_typo_names_the_gates_variable(self):
        done = self.resolve(NIGHTLY_NEXT_VISUAL_GATE="enforec")
        self.assertEqual(done.returncode, 2)
        self.assertIn("NIGHTLY_NEXT_VISUAL_GATE='enforec'", done.stderr)

    def passes(self, count, flip, *extra):
        day = self.mode.REPORT_WEEK / 8
        return lambda _since: [(flip - day * (i + 1), f"cmux NEXT visual gate passed {i:040x}: run")
                               for i in range(count)] + list(extra)

    def test_the_report_week_counts_only_gate_failures(self):
        mode, flip = self.mode, self.mode.parse_when("2026-10-28T16:00:00Z")
        canary_only = self.passes(3, flip, (flip - mode.REPORT_WEEK / 2, "cmux NEXT build 9 failed the canary twice"))
        got, why = mode.resolve("", "", flip + mode.REPORT_WEEK, canary_only, **self.OPTIONS)
        self.assertEqual(got, "enforce", why)
        gate_failed = self.passes(3, flip, (flip - mode.REPORT_WEEK / 2, "cmux NEXT visual gate failed abc: run"))
        got, why = mode.resolve("", "", flip + mode.REPORT_WEEK, gate_failed, **self.OPTIONS)
        self.assertEqual(got, "report")
        self.assertIn("set NIGHTLY_NEXT_VISUAL_GATE=enforce", why)

    def test_auto_enforces_only_after_3_proven_passes(self):
        # A quiet week (the gate skipped or could not judge) is no evidence the gate works.
        mode, flip = self.mode, self.mode.parse_when("2026-10-28T16:00:00Z")
        for count, want in ((0, "report"), (2, "report"), (3, "enforce")):
            got, why = mode.resolve("", "", flip + mode.REPORT_WEEK, self.passes(count, flip), **self.OPTIONS)
            self.assertEqual(got, want, (count, why))
        got, why = mode.resolve("", "", flip + mode.REPORT_WEEK, self.passes(2, flip), **self.OPTIONS)
        self.assertIn("passed 2 build(s)", why)
        # Passes after the flip do not count toward the week before it.
        late = lambda _since: [(flip + mode.REPORT_WEEK / 8 * (i + 1), f"cmux NEXT visual gate passed {i:040x}: r")
                               for i in range(5)]
        self.assertEqual(mode.resolve("", "", flip + mode.REPORT_WEEK, late, **self.OPTIONS)[0], "report")

    def test_min_passes_counts_distinct_builds_not_comments(self):
        # A rerun of one build can record its pass three times; that is one validated build, and
        # auto must not enforce on it. Three distinct builds do meet --min-passes 3.
        mode, flip = self.mode, self.mode.parse_when("2026-10-28T16:00:00Z")
        day = mode.REPORT_WEEK / 8
        sha = "ab" * 20
        one_build = lambda _since: [(flip - day * (i + 1), f"cmux NEXT visual gate passed {sha}: rerun {i}")
                                    for i in range(3)]
        got, why = mode.resolve("", "", flip + mode.REPORT_WEEK, one_build, **self.OPTIONS)
        self.assertEqual(got, "report", why)
        self.assertIn("passed 1 build(s)", why)
        # The same SHA in another case is the same build.
        mixed_case = lambda _since: [(flip - day, f"cmux NEXT visual gate passed {sha}: a"),
                                     (flip - day * 2, f"cmux NEXT visual gate passed {sha.upper()}: b"),
                                     (flip - day * 3, f"cmux NEXT visual gate passed {'cd' * 20}: c")]
        self.assertEqual(mode.resolve("", "", flip + mode.REPORT_WEEK, mixed_case, **self.OPTIONS)[0], "report")
        three = lambda _since: [(flip - day * (i + 1), f"cmux NEXT visual gate passed {c * 40}: run")
                                for i, c in enumerate("abc")]
        got, why = mode.resolve("", "", flip + mode.REPORT_WEEK, three, **self.OPTIONS)
        self.assertEqual(got, "enforce", why)

    def test_each_build_has_its_own_verdict(self):
        mode, flip = self.mode, self.mode.parse_when("2026-10-28T16:00:00Z")
        a, b, c = "a" * 40, "b" * 40, "c" * 40
        entries = [(flip, f"cmux NEXT visual gate failed {b}: run 2\n\nThe gate is in `enforce` mode"),
                   (flip - mode.REPORT_WEEK, f"cmux NEXT visual gate passed {a}: run 1"),
                   (flip + mode.REPORT_WEEK, f"cmux NEXT visual gate passed {c}: run 3"),
                   (flip + mode.REPORT_WEEK, f"cmux NEXT build 7 {a} failed the canary"),
                   (flip, "The nightly-next visual gate's record: one comment per judged build")]
        verdicts = mode.build_verdicts(entries, "cmux NEXT visual gate passed ", "cmux NEXT visual gate failed ")
        self.assertEqual(verdicts, {a: "pass", b: "fail", c: "pass"})
        # A later judgment of the same build wins.
        again = entries + [(flip + mode.REPORT_WEEK * 2, f"cmux NEXT visual gate passed {b}: run 4")]
        self.assertEqual(mode.build_verdicts(again, "cmux NEXT visual gate passed ",
                                             "cmux NEXT visual gate failed ")[b], "pass")

    def test_only_the_workflow_writes_a_verdict(self):
        # The repo is public: anyone can comment on the record or open an issue with its title.
        mode, bad, good = self.mode, "b" * 40, "a" * 40
        bot, someone = {"login": "github-actions[bot]"}, {"login": "someone"}
        title = "nightly-next visual gate"
        issues = {"items": [{"number": 1, "title": title, "user": bot, "created_at": "2026-10-20T00:00:00Z",
                             "body": "The nightly-next visual gate's record"},
                            {"number": 2, "title": title, "user": someone, "created_at": "2026-10-22T00:00:00Z",
                             "body": f"cmux NEXT visual gate passed {bad}: fake"}]}
        comments = {1: [{"user": bot, "created_at": "2026-10-21T00:00:00Z",
                         "body": f"cmux NEXT visual gate failed {bad}: run 1"},
                        {"user": bot, "created_at": "2026-10-21T01:00:00Z",
                         "body": f"cmux NEXT visual gate passed {good}: run 2"},
                        {"user": someone, "created_at": "2026-10-21T02:00:00Z",
                         "body": f"cmux NEXT visual gate passed {bad}: fake"},
                        {"user": someone, "created_at": "2026-10-21T03:00:00Z",
                         "body": f"cmux NEXT visual gate failed {good}: fake"}],
                    2: [{"user": bot, "created_at": "2026-10-22T01:00:00Z",
                         "body": f"cmux NEXT visual gate passed {bad}: fake"}]}

        def fetch(path, _query):
            if path == "search/issues":
                return issues
            return comments[int(path.split("/")[-2])]

        read = mode.github_entries("manaflow-ai/cmux", "token", title, fetch=fetch)
        verdicts = mode.build_verdicts(read(mode.parse_when("2026-10-14")), "cmux NEXT visual gate passed ",
                                       "cmux NEXT visual gate failed ")
        self.assertEqual(verdicts, {bad: "fail", good: "pass"})
        self.assertEqual(mode.admit("enforce", bad, verdicts)[0], False)

    def test_a_recovered_build_is_refused_only_by_its_own_failed_verdict_in_enforce(self):
        failed, passed, unknown = "f" * 40, "e" * 40, "d" * 40
        verdicts = {failed: "fail", passed: "pass"}
        self.assertEqual(self.mode.admit("enforce", failed, verdicts)[0], False)
        self.assertEqual(self.mode.admit("enforce", passed, verdicts)[:2], (True, "notice"))
        # No verdict (the gate skipped or could not judge it): published, with a warning in enforce.
        self.assertEqual(self.mode.admit("enforce", unknown, verdicts)[:2], (True, "warning"))
        for quiet in ("report", "off", ""):
            self.assertTrue(self.mode.admit(quiet, failed, verdicts)[0], quiet)
        done = subprocess.run([sys.executable, str(self.SCRIPT), "admit", "--mode", "enforce", "--build-sha", failed,
                               "--verdicts", json.dumps(verdicts)], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::error", done.stdout)
        done = subprocess.run([sys.executable, str(self.SCRIPT), "admit", "--mode", "enforce", "--build-sha", unknown,
                               "--verdicts", ""], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("::warning", done.stdout)

    def test_unreadable_verdicts_are_none(self):
        done = subprocess.run([sys.executable, str(self.SCRIPT), "verdicts", "--issue-title", "nightly-next visual gate",
                               "--pass-prefix", "p ", "--failure-prefix", "f "], capture_output=True, text=True,
                              timeout=60, env={"PATH": "/usr/bin:/bin"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "{}")


# A fake app for capture_states.py: serves CMUX_NEXT_SOCKET_PATH, logs its launch
# (argv and the knobs the gate cares about) and every request.
def gate_job(status="queued", conclusion=None, runner="", marker=None, name="visual-gate-nightly", job_id=7):
    steps = [{"name": "Run the visual gate", "status": "completed", "conclusion": "success"}]
    if marker:
        steps.append({"name": "Hold publication", "status": "completed", "conclusion": marker})
    return {"id": job_id, "name": name, "status": status, "conclusion": conclusion, "runner_name": runner,
            "steps": steps if status == "completed" else []}


class AwaitGateTests(unittest.TestCase):
    """visual-gate-nightly-verdict: publication waits for the Mac gate only for a bounded time."""
    mode = ModeResolverTests.mode
    QUEUE, RUN = 15 * 60, (15 + 75) * 60 + 300
    OTHERS = [{"id": 1, "name": "build-nightly-app", "status": "in_progress", "runner_name": "r"}]

    def act(self, jobs, elapsed):
        return self.mode.gate_action(self.OTHERS + jobs, "visual-gate-nightly", elapsed, self.QUEUE, self.RUN)

    def test_queued_past_the_budget_is_unavailable_and_blocks_nothing(self):
        action, verdict, blocks, why = self.act([gate_job("queued")], self.QUEUE)
        self.assertEqual((action, verdict, blocks), ("done", "unavailable", False))
        self.assertIn("queue budget", why)

    def test_queued_within_the_budget_and_running_wait(self):
        self.assertEqual(self.act([gate_job("queued")], self.QUEUE - 60)[0], "wait")
        self.assertEqual(self.act([gate_job("waiting")], 60)[0], "wait")
        self.assertEqual(self.act([gate_job("in_progress", runner="mac")], self.QUEUE + 3600)[0], "wait")
        # A runner took it but the status still says queued: started, so the queue budget is over.
        self.assertEqual(self.act([gate_job("queued", runner="mac")], self.QUEUE + 60)[0], "wait")

    def test_a_gate_that_never_finishes_is_unavailable(self):
        self.assertEqual(self.act([gate_job("in_progress", runner="mac")], self.RUN)[1:3], ("unavailable", False))

    def test_only_the_hold_step_blocks(self):
        self.assertEqual(self.act([gate_job("completed", "failure", "mac", marker="success")], 600)[:3],
                         ("done", "fail", True))
        for conclusion, marker in (("success", None), ("failure", "skipped"), ("failure", None),
                                   ("cancelled", None), ("skipped", None)):
            with self.subTest(conclusion=conclusion, marker=marker):
                self.assertEqual(self.act([gate_job("completed", conclusion, "mac", marker=marker)], 600)[:3],
                                 ("done", conclusion, False))

    def test_a_missing_gate_waits_briefly_then_blocks_nothing(self):
        self.assertEqual(self.act([], 60)[0], "wait")
        self.assertEqual(self.act([], self.mode.MISSING_GRACE_S)[:3], ("done", "unavailable", False))
        # Another job's hold step never counts.
        other = gate_job("completed", "failure", "mac", marker="success", name="visual-gate-nightly-x")
        self.assertEqual(self.act([other], self.QUEUE)[2], False)

    def poll(self, responses):
        """await_gate on a fake clock: each look advances it by the interval."""
        now = [0.0]
        looks = []

        def fetch():
            looks.append(now[0])
            response = responses(now[0])
            if isinstance(response, Exception):
                raise response
            return self.OTHERS + response

        result = self.mode.await_gate(fetch, "visual-gate-nightly", self.QUEUE, self.RUN,
                                      clock=lambda: now[0], sleep=lambda s: now.__setitem__(0, now[0] + s))
        return result, looks

    def test_the_race_a_runner_taken_after_the_pick_no_longer_holds_publication(self):
        # route-visual-gate-nightly saw the runner idle, then another job took it: the gate stays
        # queued for a day. The verdict job gives up after the queue budget, cancels nothing, and
        # publication goes ahead.
        (verdict, blocks, why), looks = self.poll(lambda now: [gate_job("queued")])
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertIn("queue budget", why)
        self.assertEqual(looks[-1], self.QUEUE)
        self.assertEqual(len(looks), 16)

    def test_a_gate_that_starts_in_time_is_waited_for_and_its_hold_counts(self):
        def responses(now):
            if now < 10 * 60:
                return [gate_job("queued")]
            if now < 50 * 60:
                return [gate_job("in_progress", runner="mac")]
            return [gate_job("completed", "failure", "mac", marker="success")]
        (verdict, blocks, _), looks = self.poll(responses)
        self.assertEqual((verdict, blocks), ("fail", True))
        self.assertEqual(looks[-1], 50 * 60)

    def test_the_last_look_is_on_the_budget_and_a_later_hold_counts_for_nothing(self):
        queue, hold = 5 * 60, 10 * 60
        held = [gate_job("completed", "failure", "mac", marker="success")]
        running = [gate_job("in_progress", runner="mac")]
        # Looks drift off the minute (each read takes time): the last one is still on the budget.
        now, looks = [0.0], []

        def fetch():
            looks.append(now[0])
            now[0] += 3
            return self.OTHERS + (held if now[0] > hold - 1 else running)
        verdict, blocks, _ = self.mode.await_gate(fetch, "visual-gate-nightly", queue, hold,
                                                  clock=lambda: now[0],
                                                  sleep=lambda s: now.__setitem__(0, now[0] + s))
        self.assertEqual((verdict, blocks), ("fail", True))
        self.assertEqual(looks[-1], hold)
        # A read asked for just before the budget that answers well after it holds nothing.
        now = [0.0]

        def slow():
            now[0] += 590 if now[0] == 0 else 20
            return self.OTHERS + (held if now[0] > hold else running)
        verdict, blocks, why = self.mode.await_gate(slow, "visual-gate-nightly", queue, hold,
                                                    clock=lambda: now[0], sleep=lambda s: None)
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertIn("after the 10 min budget", why)
        # A hold seen only well past the budget (a slow read, a stalled runner) holds nothing.
        clock = iter([0.0, hold + 60, hold + 60, hold + 60])
        verdict, blocks, why = self.mode.await_gate(lambda: self.OTHERS + held, "visual-gate-nightly", queue, hold,
                                                    clock=lambda: next(clock), sleep=lambda s: None)
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertIn("after the 10 min budget", why)
        # An unreadable API near the budget is retried only up to it, not for five more minutes.
        now, looks = [hold - 10.0], []

        def failing():
            looks.append(now[0])
            raise RuntimeError("HTTP 502")
        start = iter([0.0])
        verdict, blocks, _ = self.mode.await_gate(failing, "visual-gate-nightly", queue, hold,
                                                  clock=lambda: next(start, now[0]),
                                                  sleep=lambda s: now.__setitem__(0, now[0] + s))
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertEqual(looks, [hold - 10, hold])

    def test_the_budget_runs_from_the_signed_dmg_check_by_githubs_clock(self):
        # The verdict job queued 8 min for its own Linux runner after the DMG check finished: the
        # 10 min run out 2 min after it starts, and a hold counts only if the gate finished in time.
        queue, hold, dmg_done = 5 * 60, 10 * 60, 1_000_000.0
        stamp = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        dmg = {"id": 2, "name": "Verify final nightly DMG (arm64)", "status": "completed",
               "conclusion": "success", "completed_at": stamp(dmg_done)}

        def run(gate_for, wall_start=dmg_done + 8 * 60):
            now, looks = [0.0], []

            def fetch():
                looks.append(now[0])
                return self.OTHERS + [dmg] + gate_for(wall_start + now[0])
            result = self.mode.await_gate(fetch, "visual-gate-nightly", queue, hold, since="Verify final nightly DMG",
                                          clock=lambda: now[0], wall=lambda: wall_start + now[0],
                                          sleep=lambda s: now.__setitem__(0, now[0] + s))
            return result, looks

        running = [gate_job("in_progress", runner="mac")]
        (verdict, blocks, _), looks = run(lambda wall: running)
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertEqual(looks[-1], 2 * 60)
        # Finished with a hold 9 min after the DMG check, before this job could even start: it counts.
        early = dict(gate_job("completed", "failure", "mac", marker="success"), completed_at=stamp(dmg_done + 540))
        (verdict, blocks, _), looks = run(lambda wall: [early], wall_start=dmg_done + 30 * 60)
        self.assertEqual((verdict, blocks), ("fail", True))
        self.assertEqual(looks, [0.0])
        # Finished with a hold 11 min after it: too late to hold anything.
        late = dict(early, completed_at=stamp(dmg_done + 660))
        (verdict, blocks, why), _ = run(lambda wall: [late], wall_start=dmg_done + 12 * 60)
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertIn("after the 10 min budget", why)
        # A slow read near the budget is not counted twice: a gate that finished with a hold inside
        # the budget still holds when the read that sees it takes 20 s.
        inside = dict(early, completed_at=stamp(dmg_done + 595))
        now = [0.0]
        wall_start = dmg_done + 580

        def slow_read():
            now[0] += 20
            return self.OTHERS + [dmg, inside]
        verdict, blocks, _ = self.mode.await_gate(slow_read, "visual-gate-nightly", queue, hold,
                                                  since="Verify final nightly DMG", clock=lambda: now[0],
                                                  wall=lambda: wall_start + now[0], sleep=lambda s: None)
        self.assertEqual((verdict, blocks), ("fail", True))
        # The DMG check still running (a re-run's view) or absent: the budget runs from now.
        (verdict, blocks, _), looks = run(lambda wall: [], wall_start=dmg_done)
        self.assertEqual(self.mode.all_finished_at([dict(dmg, status="in_progress")], "Verify final"), None)
        self.assertEqual(self.mode.all_finished_at([], "Verify final"), None)

    def test_an_unreadable_api_blocks_nothing_and_a_blip_is_retried(self):
        (verdict, blocks, why), looks = self.poll(lambda now: RuntimeError("HTTP 502"))
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertIn("HTTP 502", why)
        self.assertEqual(len(looks), 5)
        (verdict, blocks, _), _ = self.poll(
            lambda now: RuntimeError("blip") if now < 120 else [gate_job("completed", "failure", "mac",
                                                                          marker="success")])
        self.assertEqual((verdict, blocks), ("fail", True))

    def test_the_loop_is_bounded_even_when_the_clock_stands_still(self):
        looks = []

        def fetch():
            looks.append(1)
            return [gate_job("in_progress", runner="mac")]
        verdict, blocks, _ = self.mode.await_gate(fetch, "visual-gate-nightly", self.QUEUE, self.RUN,
                                                  clock=lambda: 0.0, sleep=lambda s: None)
        self.assertEqual((verdict, blocks), ("unavailable", False))
        self.assertLessEqual(len(looks), self.RUN // 60 + 10)

    def test_the_jobs_are_read_from_this_attempt_page_by_page(self):
        urls = []

        def get(url):
            urls.append(url)
            page = int(url.rsplit("page=", 1)[1])
            return {"jobs": [{"id": i, "name": f"j{i}"} for i in range(100 if page == 1 else 3)]}
        jobs = self.mode.github_jobs("o/r", "token", "42", "2", get=get)()
        self.assertEqual(len(jobs), 103)
        self.assertEqual(urls[0], "https://api.github.com/repos/o/r/actions/runs/42/attempts/2/jobs?per_page=100&page=1")
        with self.assertRaises(RuntimeError):
            self.mode.github_jobs("o/r", "", "42", "2", get=get)()
        with self.assertRaises(RuntimeError):
            self.mode.github_jobs("o/r", "token", "42", "2", get=lambda url: {"message": "Not Found"})()

    def test_outside_enforce_the_cli_waits_for_nothing(self):
        # Only enforce runs the gate's hold step, so a report-mode verdict can never hold the build:
        # publication must not wait for the Mac gate at all (no token is read, nothing is polled).
        for mode in ("report", "off", "Report"):
            with self.subTest(mode=mode):
                done = subprocess.run([sys.executable, str(SCRIPT), "await-gate", "--run-id", "1", "--mode", mode],
                                      capture_output=True, text=True, timeout=60,
                                      env={"PATH": "/usr/bin:/bin", "GH_TOKEN": "unused"})
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertEqual(done.stdout.split(), ["verdict=report", "blocks=false"])
                self.assertIn("::notice title=nightly-next visual gate::", done.stderr)

    def test_a_hold_bounds_a_running_gate_past_the_signed_build(self):
        # Attempt 1 starts once the signed build is ready: a gate running then gets at most the hold,
        # a gate still queued at most the queue budget, and publication goes ahead after either.
        queue, hold = 5 * 60, 10 * 60
        for jobs, last in (([gate_job("in_progress", runner="mac")], hold), ([gate_job("queued")], queue)):
            now = [0.0]
            looks = []

            def fetch(jobs=jobs):
                looks.append(now[0])
                return self.OTHERS + jobs
            verdict, blocks, _ = self.mode.await_gate(fetch, "visual-gate-nightly", queue, hold,
                                                      clock=lambda: now[0],
                                                      sleep=lambda s: now.__setitem__(0, now[0] + s))
            self.assertEqual((verdict, blocks), ("unavailable", False))
            self.assertEqual(looks[-1], last)

    def test_the_cli_without_a_token_blocks_nothing_and_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary"
            done = subprocess.run([sys.executable, str(SCRIPT), "await-gate", "--run-id", "1",
                                   "--summary", str(summary)],
                                  capture_output=True, text=True, timeout=60, env={"PATH": "/usr/bin:/bin"})
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(done.stdout.split(), ["verdict=unavailable", "blocks=false"])
            self.assertIn("::warning title=nightly-next visual gate::", done.stderr)
            self.assertIn("publishes unchecked", summary.read_text())


FAKE_APP = r'''#!/usr/bin/env python3
import json, os, socket, sys, threading
path, log = os.environ["CMUX_NEXT_SOCKET_PATH"], os.environ["FAKE_LOG"]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
state = {"mode": "dark"}
def write(entry):
    with open(log, "a") as out:
        out.write(json.dumps(entry) + "\n")
write({"method": "_launch", "argv": sys.argv[1:], "config": os.environ.get("CMUX_NEXT_CONFIG_FILE"),
       "showcase": os.environ.get("CMUX_NEXT_SHOWCASE")})
def answer(connection):
    with connection:
        data = b""
        while not data.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk:
                return
            data += chunk
        request = json.loads(data)
        method, params = request["method"], request.get("params") or {}
        write({"method": method, "params": params})
        if method == "debug.layers":
            result = {"windows": [{"frame": [0, 0, 550, 360]}]}
        elif method == "debug.appearance":
            state["mode"] = params.get("mode", state["mode"])
            result = {"effective": state["mode"], "terminal_background": "#FFFFFF" if state["mode"] == "light" else "#1E1E1E",
                      "themes": "/x/themes"}
        elif method == "debug.window_snapshot":
            with open(params["path"], "wb") as image:
                image.write(b"\x89PNG\r\n\x1a\n" + state["mode"].encode())
            result = {"path": params["path"], "width": 1100, "height": 720, "method": "composited"}
        elif method == "debug.fine":
            result = {"ok": True}
        else:
            connection.sendall(json.dumps({"id": 1, "ok": False, "error": "unknown method"}).encode() + b"\n")
            return
        connection.sendall(json.dumps({"id": 1, "ok": True, "result": result}).encode() + b"\n")
while True:
    connection, _ = server.accept()
    threading.Thread(target=answer, args=(connection,), daemon=True).start()
'''

FAKE_CLI = r'''#!/usr/bin/env python3
import json, sys
if "identify" in sys.argv:
    print(json.dumps({"app": "cmux-next", "version": "0.0.0", "build": "1", "bundle_id": "dev.cmux.test"}))
'''


def executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class CaptureStatesTests(unittest.TestCase):
    """capture_states.py against a fake app: the stills, the read-back appearance and the app's own settings."""

    def test_a_state_is_captured_with_its_own_settings_and_the_apps_word(self):
        with tempfile.TemporaryDirectory(prefix="visual-gate-test.") as tmp:
            root = Path(tmp)
            app = root / "cmux DEV test.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "fakeapp"}))
            executable(app / "Contents/MacOS/fakeapp", FAKE_APP)
            executable(app / "Contents/Resources/bin/cmux", FAKE_CLI)
            executable(root / "bin/stat", "#!/bin/sh\necho root\n")
            executable(root / "bin/pkill", "#!/bin/sh\nexit 1\n")
            state = root / "demo.json"
            state.write_text(json.dumps({"title": "Demo", "settings": None, "launch_args": ["--showcase"], "steps": [
                {"title": "fine", "rpc": {"method": "debug.fine", "params": {}}, "wait": 0},
                {"title": "maybe", "rpc": {"method": "debug.missing", "params": {}}, "wait": 0, "optional": True},
            ]}))
            log = root / "requests.jsonl"
            env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
            env.update(PATH=f"{root / 'bin'}{os.pathsep}{env.get('PATH', '')}", FAKE_LOG=str(log))
            out = root / "out"
            done = subprocess.run([sys.executable, str(GATE / "capture_states.py"), "--app", str(app),
                                   "--out", str(out), str(state)], capture_output=True, text=True, timeout=180, env=env)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            result = json.loads((out / "demo/result.json").read_text())
            self.assertEqual([s["status"] for s in result["steps"]], ["ok", "unavailable"])
            self.assertEqual(result["errors"], [])
            self.assertEqual(result["settings_source"], "own")
            self.assertEqual(result["window_points"], [550.0, 360.0])
            self.assertEqual(result["appearance"]["light"]["effective"], "light")
            self.assertEqual(result["appearance"]["dark"]["terminal_background"], "#1E1E1E")
            self.assertEqual((out / "demo/light.png").read_bytes()[-5:], b"light")
            self.assertEqual((out / "demo/dark.png").read_bytes()[-4:], b"dark")
            entries = [json.loads(line) for line in log.read_text().splitlines()]
            launch = next(e for e in entries if e["method"] == "_launch")
            # Never the Mac's own cmux-next.json, even for a state with no settings.
            self.assertTrue(launch["config"])
            self.assertIn("--showcase", launch["argv"])
            self.assertEqual(launch["showcase"], "1")

    def test_an_unreadable_bundle_is_each_states_error_and_every_state_runs(self):
        with tempfile.TemporaryDirectory(prefix="visual-gate-test.") as tmp:
            root = Path(tmp)
            app = root / "cmux DEV broken.app"  # no Contents/Info.plist
            app.mkdir()
            for name in ("one", "two"):
                (root / f"{name}.json").write_text(json.dumps({"settings": None, "steps": [{"title": "wait", "wait": 0}]}))
            env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
            out = root / "out"
            done = subprocess.run([sys.executable, str(GATE / "capture_states.py"), "--app", str(app), "--out", str(out),
                                   str(root / "one.json"), str(root / "two.json")],
                                  capture_output=True, text=True, timeout=120, env=env)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            for name in ("one", "two"):
                result = json.loads((out / name / "result.json").read_text())
                self.assertIn("Info.plist", result["errors"][0])

    def test_a_bad_state_file_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="visual-gate-test.") as tmp:
            bad = Path(tmp) / "bad.json"
            bad.write_text(json.dumps({"steps": [{"title": "wait only", "wait": 2},
                                                 {"title": "both", "cmux": ["app", "ping"], "rpc": {"method": "x"}}]}))
            done = subprocess.run([sys.executable, str(GATE / "capture_states.py"), "--check", str(bad)],
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 2)
            self.assertIn("step 2 has both `cmux` and `rpc`", done.stderr)


def load_media_runner():
    spec = importlib.util.spec_from_file_location("media_runner_for_gate", ROOT / "scripts/ci/cmux_next_media_runner.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def runner(name, *labels, busy=False, status="online"):
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


class IdleRunnerTests(unittest.TestCase):
    """The gate takes only a session (else gui) runner idle now: a queued job would hold publish-nightly."""
    media = load_media_runner()
    XCODE = "/Applications/Xcode_26.6.app"
    SESSION = "glaeda-session-std-xcode-26.6"
    GUI = "glaeda-gui-std-xcode-26.6"

    def pick(self, runners, **overrides):
        options = dict(same_repo=True, owned="1", pr_xcode_app=self.XCODE, runners=runners)
        options.update(overrides)
        return self.media.pick_idle(**options)

    def test_an_idle_session_runner_first_then_an_idle_gui_runner(self):
        both = [runner("a", "glaeda-std-xcode-26.6", self.GUI, self.SESSION, busy=True),
                runner("b", "glaeda-std-xcode-26.6", self.SESSION)]
        self.assertEqual(self.pick(both)[0], self.SESSION)
        gui_only = [runner("a", "glaeda-std-xcode-26.6", self.GUI), runner("b", self.SESSION, busy=True)]
        self.assertEqual(self.pick(gui_only)[0], self.GUI)

    def test_nothing_idle_or_unreadable_places_nothing(self):
        busy = [runner("a", self.GUI, self.SESSION, busy=True), runner("b", self.SESSION, status="offline")]
        label, reason = self.pick(busy)
        self.assertEqual(label, "")
        self.assertIn("idle", reason)
        self.assertEqual(self.pick(None)[0], "")
        self.assertEqual(self.pick([runner("b", self.SESSION)], owned="0")[0], "")
        self.assertEqual(self.pick([runner("b", self.SESSION)], same_repo=False)[0], "")

    def test_the_cli_without_a_token_places_nothing(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux_next_media_runner.py"), "--same-repo", "true",
                               "--idle-now"], capture_output=True, text=True, timeout=60,
                              env={"PATH": "/usr/bin:/bin", "POOL_OWNED": "1", "PR_XCODE_APP": self.XCODE,
                                   "OWNED_SLOTS": json.dumps({self.SESSION: 4})})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("runs_on=\n", done.stdout)


class StateFileTests(unittest.TestCase):
    def test_checked_in_states_load(self):
        done = subprocess.run([sys.executable, str(GATE / "capture_states.py"), "--check", str(GATE / "states")],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_states_carry_nothing_private(self):
        for path in (GATE / "states").glob("*.json"):
            text = path.read_text()
            self.assertNotRegex(text, r"@[A-Za-z0-9-]+\.[A-Za-z]{2,}", path.name)
            self.assertNotIn("/Users/", text, path.name)


class WiringTests(unittest.TestCase):
    nightly = nightly_text()  # moved step scripts put back inline

    def job(self, name):
        """The job's YAML, up to the next top-level job."""
        rest = self.nightly[self.nightly.index(f"\n  {name}:\n") + 1:]
        following = re.search(r"\n  [a-z0-9-]+:\n", rest[len(name) + 3:])
        return rest[:following.start() + len(name) + 3] if following else rest

    def jobs(self):
        """Return the workflow's top-level job bodies and their direct needs."""
        starts = list(re.finditer(r"(?m)^  ([a-z0-9-]+):\n", self.nightly))
        jobs = {}
        for i, match in enumerate(starts):
            body = self.nightly[match.end():starts[i + 1].start() if i + 1 < len(starts) else None]
            needs_match = re.search(r"(?m)^    needs:\s*(.+)$", body)
            raw = needs_match.group(1).strip() if needs_match else ""
            if raw.startswith("[") and raw.endswith("]"):
                needs = [item.strip() for item in raw[1:-1].split(",") if item.strip()]
            elif raw:
                needs = [raw]
            else:
                needs = []
            jobs[match.group(1)] = needs
        return jobs

    def test_sign_and_publish_jobs_never_depend_on_visual_jobs_transitively(self):
        jobs = self.jobs()
        visual = {name for name in jobs if "visual-gate" in name}
        targets = {name for name in jobs if re.search(r"(?:^|-)(?:sign|publish)(?:-|$)", name)}
        self.assertTrue(targets)
        for target in sorted(targets):
            seen = set()
            pending = list(jobs[target])
            while pending:
                dependency = pending.pop()
                if dependency in seen:
                    continue
                seen.add(dependency)
                self.assertNotIn(dependency, visual, f"{target} directly depends on visual job {dependency}")
                pending.extend(jobs.get(dependency, []))
            self.assertTrue(seen.isdisjoint(visual), f"{target} transitively depends on visual jobs: {seen & visual}")

    def test_publish_nightly_does_not_need_visual_jobs(self):
        publish = self.job("publish-nightly")
        needs = [name.strip() for name in
                 publish[publish.index("needs: [") + len("needs: ["):].split("]", 1)[0].split(",")]
        # Visual coverage is advisory: a display or Linux queue can never hold the feed.
        self.assertNotIn("visual-gate-nightly-verdict", needs)
        self.assertNotIn("route-visual-gate-nightly", needs)
        self.assertNotIn("visual-gate-nightly", needs)
        self.assertNotIn("needs.visual-gate-nightly", publish)
        # In every visual mode publication depends only on signed and verified build artifacts.
        condition = next(line for line in publish.splitlines() if line.strip().startswith(("if: \"!cancelled()", "if: \"always() && !cancelled()")))
        own, recovered = condition.split(" || (needs.recover-nightly-next-notarization")
        self.assertNotIn("visual-gate-nightly", recovered)
        self.assertNotIn("visual-gate-nightly-verdict.outputs.blocks", own)
        self.assertNotIn("route-visual-gate-nightly.outputs.mode", own)
        self.assertNotIn("OWN_GATE_BLOCKS", publish)

    def test_a_gate_mode_that_cannot_be_resolved_stays_advisory(self):
        # A mode error is visible and skips visual coverage, but cannot hold the signed build.
        body = self.step_body("route-visual-gate-nightly", "Resolve the visual gate mode")
        for code, mode in ((2, "invalid"), (1, "invalid"), (0, "report")):
            with tempfile.TemporaryDirectory() as tmp, self.subTest(code=code):
                tmp = Path(tmp)
                resolver = tmp / "scripts/ci/nightly_next_canary_mode.py"
                resolver.parent.mkdir(parents=True)
                resolver.write_text(f"import sys\nprint('mode=report')\nprint('why=test')\nsys.exit({code})\n"
                                    if code == 0 else f"import sys\nsys.exit({code})\n")
                out = tmp / "output"
                done = subprocess.run(["bash", "-e", "-c", body], cwd=tmp, capture_output=True, text=True,
                                      timeout=60, env=dict(os.environ, GITHUB_OUTPUT=str(out),
                                                           GITHUB_STEP_SUMMARY=str(tmp / "summary"),
                                                           NIGHTLY_NEXT_VISUAL_GATE="enforec"))
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn(f"mode={mode}", out.read_text().split("\n"))
                if mode == "invalid":
                    self.assertIn("::error title=nightly-next visual gate::", done.stdout)
        route = self.job("route-visual-gate-nightly")
        self.assertIn("steps.mode.outputs.mode != 'invalid'", route[route.index("id: pick"):][:200])
        for name in ("visual-gate-nightly", "visual-gate-nightly-verdict"):
            self.assertIn("needs.route-visual-gate-nightly.outputs.mode != 'invalid'", self.job(name))
        publish = self.job("publish-nightly")
        needs = publish[publish.index("needs: [") + len("needs: ["):].split("]", 1)[0]
        self.assertNotIn("route-visual-gate-nightly", [n.strip() for n in needs.split(",")])
        condition = next(line for line in publish.splitlines() if line.strip().startswith(("if: \"!cancelled()", "if: \"always() && !cancelled()")))
        own = condition.split(" || (needs.recover-nightly-next-notarization")[0]
        self.assertNotIn("needs.route-visual-gate-nightly.outputs.mode != 'invalid'", own)

    def test_the_verdict_job_is_skipped_with_the_gate_and_reads_only_actions(self):
        verdict = self.job("visual-gate-nightly-verdict")
        gate = self.job("visual-gate-nightly")

        def line(job, key):
            return next(l.strip() for l in job.splitlines() if l.startswith(f"    {key}:"))

        # The gate's `if`, after the signed build's own check: one of its two signing paths is always
        # skipped, so an implicit success() would skip this advisory verdict job.
        gate_if = line(gate, "if").removeprefix("if: ")
        self.assertEqual(line(verdict, "if"),
                         f'if: "!cancelled() && needs.verify-final-dmg-nightly.result == \'success\' && {gate_if}"')
        # The gate's needs, plus the signed build's last check: publication's wait for the gate
        # starts only once the build is ready, so it never runs beside the build for nothing.
        self.assertEqual(line(verdict, "needs"), line(gate, "needs").replace("]", ", verify-final-dmg-nightly]"))
        # A Linux runner of its own, never the gate's Mac.
        runs_on = line(verdict, "runs-on")
        self.assertIn("'blacksmith-32vcpu-ubuntu-2404'", runs_on)
        self.assertNotIn("route-visual-gate-nightly", runs_on)
        perms = verdict[verdict.index("    permissions:\n"):verdict.index("    outputs:\n")]
        self.assertEqual(re.findall(r"^      ([a-z-]+): ", perms, re.MULTILINE), ["contents", "actions"])
        self.assertIn("contents: read", perms)
        self.assertIn("actions: read", perms)
        self.assertNotIn("environment:", verdict)
        self.assertNotIn("secrets.", verdict)
        # Bounded: on attempt 1 at most 10 min past the signed build (5 for a gate still queued); a
        # re-run, which starts the gate beside this job, the queue budget plus the gate's own timeout.
        self.assertIn('budget=(--queue-budget-minutes 5 --hold-minutes 10 --since-job "Verify final nightly DMG")', verdict)
        self.assertIn("budget=(--queue-budget-minutes 15 --gate-timeout-minutes 75)", verdict)
        self.assertIn("GATE_MODE: ${{ needs.route-visual-gate-nightly.outputs.mode }}", verdict)
        self.assertIn("timeout-minutes: 75", gate)
        self.assertEqual(int(re.search(r"timeout-minutes: (\d+)", verdict).group(1)), 100)
        self.assertIn("persist-credentials: false", verdict)
        self.assertIn("sparse-checkout: |\n            scripts/ci/nightly_next_canary_mode.py\n", verdict)
        self.assertIn("blocks: ${{ steps.await.outputs.blocks }}", verdict)
        # A held build fails this job too, so "Re-run failed jobs" retries it with the gate instead
        # of keeping a successful job's stale `blocks=true`.
        hold = verdict[verdict.index("- name: Record failed advisory verdict"):]
        self.assertIn("if: steps.await.outputs.blocks == 'true'", hold.splitlines()[1])
        self.assertIn("exit 1", hold)
        self.assertLess(verdict.index("id: await"), verdict.index("- name: Record failed advisory verdict"))

    def test_the_wait_is_short_on_attempt_1_and_whole_on_a_re_run(self):
        body = self.step_body("visual-gate-nightly-verdict",
                              "Wait for the visual gate, at most 10 min past the signed build")
        for attempt, expected in (("1", ["--queue-budget-minutes", "5", "--hold-minutes", "10", "--since-job",
                                         "Verify", "final", "nightly", "DMG"]),
                                  ("2", ["--queue-budget-minutes", "15", "--gate-timeout-minutes", "75"])):
            with tempfile.TemporaryDirectory() as tmp, self.subTest(attempt=attempt):
                tmp = Path(tmp)
                fake = tmp / "scripts/ci/nightly_next_canary_mode.py"
                fake.parent.mkdir(parents=True)
                fake.write_text("import sys\nprint('args=' + ' '.join(sys.argv[1:]))\n")
                out = tmp / "output"
                done = subprocess.run(["bash", "-e", "-c", body], cwd=tmp, capture_output=True, text=True,
                                      timeout=60, env=dict(os.environ, GITHUB_OUTPUT=str(out), GITHUB_RUN_ID="9",
                                                           GITHUB_RUN_ATTEMPT=attempt, GITHUB_REPOSITORY="o/r",
                                                           GATE_MODE="enforce"))
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                args = out.read_text().split("args=", 1)[1].split()
                self.assertEqual(args[args.index("--mode"):args.index("--mode") + 2], ["--mode", "enforce"])
                self.assertEqual(args[-len(expected):], expected)

    def test_the_gate_marks_the_build_it_holds_in_a_step_the_verdict_job_reads(self):
        gate = self.job("visual-gate-nightly")
        step = gate[gate.index(f"- name: {ModeResolverTests.mode.GATE_MARKER}\n"):]
        self.assertIn("if: always() && steps.verdict.outputs.blocks == 'true'", step.splitlines()[1])
        # The gate's own outputs stay for the report job.
        self.assertIn("blocks: ${{ steps.verdict.outputs.blocks }}", gate)
        report = self.job("report-visual-gate-nightly")
        self.assertNotIn("HELD:", report)

    def test_recovery_keeps_visual_verdicts_advisory(self):
        find = self.job("find-nightly-next-recovery")
        self.assertIn("issues: read", find)
        self.assertNotIn("Read the visual gate's verdicts", find)
        job = self.job("recover-nightly-next-notarization")
        self.assertIn("run: bash scripts/ci/nightly-steps/recover-continue-pending-notarization.sh",
                      (ROOT / ".github/workflows/nightly.yml").read_text())
        self.assertNotIn("VISUAL_GATE_MODE", job)
        self.assertNotIn("VISUAL_GATE_VERDICTS", job)
        # The step's shell lives in its script (nightly.yml's size limit).
        recover = (ROOT / "scripts/ci/nightly-steps/recover-continue-pending-notarization.sh").read_text()
        # Recovery remains gated by the manifest, lineage, notarization and feed checks;
        # it has no visual publication gate. Keep that positive ordering explicit.
        self.assertNotIn("nightly_next_canary_mode.py admit", recover)
        self.assertLess(recover.index('source "$dir/manifest.env"'),
                        recover.index("./scripts/ci/notarize-nightly-dmg.sh"))
        self.assertLess(recover.index("./scripts/ci/notarize-nightly-dmg.sh"),
                        recover.index('echo "accepted=true"'))

    def test_every_judged_build_is_recorded(self):
        report = self.job("report-visual-gate-nightly")
        self.assertIn("needs.visual-gate-nightly.outputs.verdict == 'pass'", report)
        self.assertIn("cmux NEXT visual gate passed ${process.env.SHA}", report)
        self.assertIn("cmux NEXT visual gate failed ${process.env.SHA}", report)
        self.assertIn("const title = 'nightly-next visual gate';", report)

    def test_the_gate_is_placed_only_on_an_idle_runner_and_judges_every_state(self):
        route = self.job("route-visual-gate-nightly")
        self.assertIn("cmux_next_media_runner.py --same-repo true --idle-now", route)
        self.assertIn("permission-organization-self-hosted-runners: read", route)
        self.assertIn("verdict=unavailable", route)
        self.assertIn("GITHUB_STEP_SUMMARY", route)
        self.assertIn("--min-passes 3", route)
        job = self.job("visual-gate-nightly")
        # A failed read leaves no half-written text-boxes.json, and the next state is still read.
        self.assertIn('> "$state/text-boxes.json.part"; then', job)
        self.assertIn('mv "$state/text-boxes.json.part" "$state/text-boxes.json"', job)
        self.assertNotIn("set -euo pipefail\n          swiftc", job)
        self.assertIn("--states scripts/cmux-next/visual-gate/states", job)

    def step_body(self, job, name):
        """The `run: |` body of the named step, dedented."""
        text = self.job(job)
        start = text.index(f"- name: {name}\n")
        body = text[text.index("run: |\n", start) + len("run: |\n"):]
        lines = []
        for line in body.splitlines():
            if line.strip() and not line.startswith(" " * 10):
                break
            lines.append(line[10:])
        return "\n".join(lines) + "\n"

    def test_every_exit_code_of_the_gate_records_a_verdict(self):
        # Actions runs `run:` under `bash -e`: a failed gate must still write its verdict, or
        # enforce marks the advisory job when it fails, but never controls publication.
        body = self.step_body("visual-gate-nightly", "Run the visual gate")
        for code, verdict, blocks in ((0, "pass", "false"), (1, "fail", "true"), (3, "unavailable", "false"),
                                      (2, "unavailable", "false")):
            with tempfile.TemporaryDirectory() as tmp, self.subTest(code=code):
                tmp = Path(tmp)
                gate = tmp / "scripts/cmux-next/visual-gate/visual_gate.py"
                gate.parent.mkdir(parents=True)
                gate.write_text(f"import sys\nsys.exit({code})\n")
                (tmp / "runner/visual-gate/home").mkdir(parents=True)
                out = tmp / "output"
                env = dict(os.environ, RUNNER_TEMP=str(tmp / "runner"), GITHUB_OUTPUT=str(out),
                           GITHUB_STEP_SUMMARY=str(tmp / "summary"), GATE_MODE="enforce", GATE_WHY="test",
                           BUILD_SHA="abc")
                done = subprocess.run(["bash", "-e", "-c", body], cwd=tmp, env=env, capture_output=True,
                                      text=True, timeout=60)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(out.read_text().split(), [f"verdict={verdict}", f"blocks={blocks}"])
                # A capture cut off by a timeout or a cancel never fails the build.
                out.unlink()
                done = subprocess.run(["bash", "-e", "-c", body], cwd=tmp, capture_output=True, text=True,
                                      timeout=60, env=dict(env, CAPTURE_OUTCOME="cancelled"))
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(out.read_text().split(), ["verdict=unavailable", "blocks=false"])

    def test_the_gate_uses_the_shared_mode_resolver(self):
        route = self.job("route-visual-gate-nightly")
        self.assertIn("scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE", route)
        resolver = (ROOT / "scripts/ci/nightly-steps/visual-gate-resolve-mode.sh").read_text()
        recovery_resolver = (ROOT / "scripts/ci/nightly-steps/visual-gate-read-verdicts.sh").read_text()
        self.assertIn("--enforce-after never --default-enforce-after never", resolver)
        self.assertIn("--enforce-after never --default-enforce-after never", recovery_resolver)
        self.assertIn("scripts/ci/cmux_next_media_runner.py", route)
        job = self.job("visual-gate-nightly")
        self.assertIn("scripts/cmux-next/visual-gate/visual_gate.py", job)
        self.assertIn("scripts/cmux-next/visual-gate/capture_states.py", job)
        self.assertIn("VISUAL_GATE_REQUIRE_2X: ${{ vars.NIGHTLY_NEXT_VISUAL_GATE_REQUIRE_2X }}", job)
        self.assertIn("needs.route-visual-gate-nightly.outputs.runs_on", job)
        # Never an owned label in the workflow (tests/test_ci_self_hosted_guard.sh).
        self.assertNotRegex(job, r"runs-on:[^\n]*'glaeda-")

    def test_the_gate_never_waits_on_the_signed_build(self):
        # It runs beside the build: its needs hold no build, sign or verify job.
        job = self.job("visual-gate-nightly")
        needs = job[job.index("needs:"):].splitlines()[0]
        for name in ("build-nightly-app", "build-sign-notarize-nightly", "verify-signed-nightly"):
            self.assertNotIn(name, needs)


if __name__ == "__main__":
    unittest.main()
