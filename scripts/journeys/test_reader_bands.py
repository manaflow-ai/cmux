#!/usr/bin/env python3
"""The text reader's band read, as the journeys' frame checks see it (cmux-ad m10 1, review 1 of #35282, finding B).

scripts/ci/pr_media_ocr.swift reads an image in which Vision finds no text at all again in 4 horizontal bands, and names
on stderr a band that read no text ("...; 19 lines in 4 bands; no text in band 4"): on macOS 27 such a band can hold
text (the "Did you know?" card in the r3fc frame of 8e8f5f70). The read is then partial: a check that text is ABSENT
(`lacks`) must not pass on it; a check that text is there, or a line count, may. A band that shows no ink at all (empty
terminal rows: band 3 in all 30 band reads of the 53-frame corpus) is named "blank": it holds no text, so the read is
not partial there (review 2 of #35282, notes 1-3). A forbidden text that the read does find fails the check, partial
read or not.

    python3 -I scripts/journeys/test_reader_bands.py
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))

import driver as D  # noqa: E402
import ext_smoke  # noqa: E402


def fake_reader(folder, stdout, stderr=""):
    """An executable that prints STDOUT and STDERR whatever image it is given, as the compiled reader would."""
    folder = Path(folder)
    (folder / "out.txt").write_text(stdout)
    (folder / "err.txt").write_text(stderr)
    tool = folder / "reader.sh"
    tool.write_text(f"#!/bin/sh\ncat '{folder / 'out.txt'}'\ncat '{folder / 'err.txt'}' >&2\n")
    tool.chmod(0o755)
    return tool


class StubApp:
    """The parts of driver.App a frame check uses: a snapshot that writes a file, and read_text as given."""
    snapshot_window = None

    def __init__(self, read):
        self.read = read

    def snapshot(self, path):
        Path(path).write_bytes(b"png")
        return Path(path)

    def read_text(self, image):
        return self.read

    def panes(self):
        return []


class ReadTextTests(unittest.TestCase):
    def test_a_band_that_read_nothing_is_kept_with_the_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool = fake_reader(tmp, "J> echo one\nJ> echo two\n",
                               "pr-media-ocr: no text in the whole image; 2 lines in 4 bands; no text in band 4\n")
            lines = D.App.read_text(type("Reader", (), {"ocr": str(tool)})(), Path(tmp) / "x.png")
        self.assertEqual(list(lines), ["J> echo one", "J> echo two"])
        self.assertEqual(D.unread_bands(lines), [4])

    def test_several_bands_and_a_whole_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool = fake_reader(tmp, "a\n", "pr-media-ocr: no text in the whole image; 1 lines in 4 bands; no text in bands 2, 4\n")
            self.assertEqual(D.unread_bands(D.App.read_text(type("Reader", (), {"ocr": str(tool)})(), Path(tmp) / "x.png")), [2, 4])
            tool = fake_reader(tmp, "a\nb\n")
            whole = D.App.read_text(type("Reader", (), {"ocr": str(tool)})(), Path(tmp) / "x.png")
        self.assertEqual(list(whole), ["a", "b"])
        self.assertEqual(D.unread_bands(whole), [])
        self.assertEqual(D.unread_bands(["a plain list"]), [])


    def test_a_blank_band_is_not_an_unread_band(self):
        # review 2 of #35282, note 1: the reader names a band with no ink "blank"; only a band with ink and no text is unread
        with tempfile.TemporaryDirectory() as tmp:
            tool = fake_reader(tmp, "a\nb\n", "pr-media-ocr: no text in the whole image; 2 lines in 4 bands; blank bands 2, 3; "
                                              "no text in band 4\n")
            lines = D.App.read_text(type("Reader", (), {"ocr": str(tool)})(), Path(tmp) / "x.png")
            self.assertEqual((D.unread_bands(lines), D.blank_bands(lines)), ([4], [2, 3]))
            tool = fake_reader(tmp, "a\n", "pr-media-ocr: no text in the whole image; 1 lines in 4 bands; blank band 3\n")
            lines = D.App.read_text(type("Reader", (), {"ocr": str(tool)})(), Path(tmp) / "x.png")
            self.assertEqual((D.unread_bands(lines), D.blank_bands(lines), lines.banded), ([], [3], True))
            tool = fake_reader(tmp, "a\n")
            whole = D.App.read_text(type("Reader", (), {"ocr": str(tool)})(), Path(tmp) / "x.png")
            self.assertEqual((D.unread_bands(whole), D.blank_bands(whole), whole.banded), ([], [], False))

class LacksOnAPartialReadTests(unittest.TestCase):
    def journey(self, tmp, read):
        return D.Journey({"id": "bands", "steps": []}, StubApp(read), tmp, D.now() + 60, 1.0)

    def test_frame_screen_lacks_is_not_held_when_a_band_read_nothing(self):
        partial = D.Read(["J> echo one", "J> echo two", "one"], [4])
        with tempfile.TemporaryDirectory() as tmp:
            ok, detail = self.journey(tmp, partial).cond_frame_screen({"shows": ["one"], "lacks": ["secret"]}, {})
            self.assertFalse(ok, detail)
            self.assertIn("band 4", detail.get("lacks_not_judged", ""))
            whole = D.Read(["J> echo one", "J> echo two", "one"], [])
            ok, detail = self.journey(tmp, whole).cond_frame_screen({"shows": ["one"], "lacks": ["secret"]}, {})
            self.assertTrue(ok, detail)
            # no lacks: a partial read still shows what it shows
            ok, detail = self.journey(tmp, partial).cond_frame_screen({"shows": ["one"]}, {})
            self.assertTrue(ok, detail)

    def test_smoke_frame_lacks_is_not_held_when_a_band_read_nothing(self):
        partial = D.Read(["J> echo one", "J> echo two", "J> echo three"], [3, 4])
        with tempfile.TemporaryDirectory() as tmp:
            ok, detail = ext_smoke.cond_smoke_frame(self.journey(tmp, partial), {"lacks": ["Bring your history"]}, {})
            self.assertFalse(ok, detail)
            self.assertIn("bands 3, 4", detail.get("lacks_not_judged", ""))
            ok, detail = ext_smoke.cond_smoke_frame(self.journey(tmp, partial), {}, {})
            self.assertTrue(ok, detail)  # 3 lines, no lacks: the frame is not blank
            ok, detail = ext_smoke.cond_smoke_frame(self.journey(tmp, D.Read(list(partial), [])), {"lacks": ["x"]}, {})
            self.assertTrue(ok, detail)


    def test_a_forbidden_text_the_read_finds_fails_on_a_partial_read(self):
        # review 2 of #35282, note 3: a partial read cannot prove a text absent, but a text it does read is there
        partial = D.Read(["J> echo one", "secret"], [4])
        with tempfile.TemporaryDirectory() as tmp:
            ok, detail = self.journey(tmp, partial).cond_frame_screen({"shows": ["one"], "lacks": ["secret"]}, {})
            self.assertFalse(ok, detail)
            self.assertNotIn("lacks_not_judged", detail)
            self.assertEqual(detail["present"], ["secret"])
            ok, detail = ext_smoke.cond_smoke_frame(self.journey(tmp, D.Read(["a", "b", "secret"], [2])), {"lacks": ["secret"]}, {})
            self.assertFalse(ok, detail)
            self.assertNotIn("lacks_not_judged", detail)

    def test_a_read_with_only_blank_bands_judges_a_lacks_check(self):
        read = D.Read(["J> echo one", "one"], [], blank=[3])
        with tempfile.TemporaryDirectory() as tmp:
            ok, detail = self.journey(tmp, read).cond_frame_screen({"shows": ["one"], "lacks": ["secret"]}, {})
            self.assertTrue(ok, detail)
            self.assertEqual(detail.get("bands"), {"unread": [], "blank": [3]})
            ok, detail = ext_smoke.cond_smoke_frame(self.journey(tmp, D.Read(["a", "b", "c"], [], blank=[2, 3])),
                                                    {"lacks": ["secret"]}, {})
            self.assertTrue(ok, detail)
            self.assertEqual(detail.get("bands"), {"unread": [], "blank": [2, 3]})

    def test_every_frame_check_on_a_band_read_records_its_bands(self):
        partial = D.Read(["J> echo one", "one"], [4], blank=[3])
        with tempfile.TemporaryDirectory() as tmp:
            ok, detail = self.journey(tmp, partial).cond_frame_screen({"shows": ["one"]}, {})
            self.assertTrue(ok, detail)
            self.assertEqual(detail.get("bands"), {"unread": [4], "blank": [3]})
            ok, detail = self.journey(tmp, D.Read(["one"], [])).cond_frame_screen({"shows": ["one"]}, {})
            self.assertNotIn("bands", detail)  # a whole read

if __name__ == "__main__":
    unittest.main()
