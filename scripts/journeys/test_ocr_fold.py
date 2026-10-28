#!/usr/bin/env python3
"""The frame checks' text matching (driver.ocr_contains), no fleet, no app.

    python3 scripts/journeys/test_ocr_fold.py

macOS text recognition reads a short Latin word at a line's start as a Cyrillic or Greek look-alike
(nested-splits on v2.2.1, 3 of 3 runs: the frame showed "a-574259-42 46 88" in pane a, the reader
returned "U+0430-574259-42 46 88" with CYRILLIC SMALL LETTER A). A frame that shows the text must match.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
# driver.py imports build_names.py, which run.py sends beside it; in the repo it is in scripts/cmux-next.
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402


class OcrContainsTests(unittest.TestCase):
    def test_cyrillic_a_read_for_latin_a_matches(self):
        # The exact reads of nested-splits run1 check-19.png ("rows" crop of pane a).
        lines = ["J> echo a-574259-$((6*7)) $(stty size)", "\u0430-574259-42 46 88", "J>"]
        self.assertTrue(D.ocr_contains(lines, "a-574259-42"))

    def test_cyrillic_and_greek_look_alikes_match_latin(self):
        # Lowercase and capital letters Vision returns for Latin ones in a monospace font.
        self.assertTrue(D.ocr_contains(["\u0435\u0441\u0440\u0445\u0443-1"], "ecpxy-1"))
        self.assertTrue(D.ocr_contains(["\u0410\u0412\u0415\u041a\u041c\u041d\u0420\u0421\u0422\u0425-1"], "ABEKMHPCTX-1"))
        self.assertTrue(D.ocr_contains(["\u03bf\u03b1-1"], "oa-1"))
        self.assertTrue(D.ocr_contains(["\u0391\u0392\u0395\u039a\u039c\u039d\u03a1\u03a4\u03a7-1"], "ABEKMNPTX-1"))

    def test_a_different_letter_still_fails(self):
        # Folding look-alikes must not make a wrong pane's text pass.
        self.assertFalse(D.ocr_contains(["b-574259-42 22 87"], "a-574259-42"))
        self.assertFalse(D.ocr_contains(["\u0431-574259-42"], "a-574259-42"))  # CYRILLIC SMALL LETTER BE
        self.assertFalse(D.ocr_contains(["a-574259-41"], "a-574259-42"))

    def test_wanted_text_in_cyrillic_still_matches_itself(self):
        # Both sides fold the same way: a journey that types Cyrillic still finds it.
        self.assertTrue(D.ocr_contains(["J> echo \u043f\u0440\u0438\u0432\u0435\u0442-42"], "\u043f\u0440\u0438\u0432\u0435\u0442-42"))

    def test_lacks_side_sees_a_look_alike(self):
        # `frame_text` with `lacks` uses the same matcher: a look-alike read of the text is the text.
        self.assertTrue(D.ocr_contains(["\u0430-1-42"], "a-1-42"))


if __name__ == "__main__":
    unittest.main()
