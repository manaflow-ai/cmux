#!/usr/bin/env python3
"""The driver's text match on recognized frame text (ocr_contains, OCR_FOLD): no app.

    python3 scripts/journeys/test_ocr_fold.py

Text recognition reads some glyphs of the terminal font as look-alikes. The match folds them to one form, so a
line the terminal really shows is found; a different line is still not found.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import driver as D  # noqa: E402

# The OCR lines of check-64.png, smoke round 2 on cmux18, job 4b39ae9a3bc53c739553cbc8 (tip 18dadc3e4db6, STATUS 5811):
# the frame shows "w3-543646-42", but recognition read the "w" as the Won sign for every try of step 17.
WON_FRAME = ["$ echo w3-543646-$((6*7))", "₩3-543646-42"]


class OcrFold(unittest.TestCase):
    def test_the_won_sign_read_for_w_still_shows_the_output_line(self):
        self.assertTrue(D.ocr_contains(WON_FRAME, "w3-543646-42"))

    def test_the_fullwidth_won_sign_and_capital_w_also_fold_to_w(self):
        self.assertTrue(D.ocr_contains(["￦3-543646-42"], "w3-543646-42"))
        self.assertTrue(D.ocr_contains(["W3-543646-42"], "w3-543646-42"))

    def test_the_echoed_command_alone_is_not_the_output(self):
        # "w3-543646-$((6*7))" holds no "-42": only the printed result passes the check.
        self.assertFalse(D.ocr_contains(["$ echo w3-543646-$((6*7))"], "w3-543646-42"))

    def test_another_token_or_another_number_is_not_folded_into_a_match(self):
        self.assertFalse(D.ocr_contains(["₩2-543646-42"], "w3-543646-42"))
        self.assertFalse(D.ocr_contains(["₩3-543647-42"], "w3-543646-42"))
        self.assertFalse(D.ocr_contains(["₩3-543646-41"], "w3-543646-42"))

    def test_a_lacks_text_read_with_the_won_sign_is_still_present(self):
        # The same fold applies to `lacks`: a stale line read with a look-alike is not hidden from the check.
        self.assertTrue(D.ocr_contains(["₩4-543646-42"], "w4-543646-42"))


if __name__ == "__main__":
    unittest.main()
