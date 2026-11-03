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


# The OCR lines of check-80.png, smoke round 5 on cmux22, job fc4afadcd8212e736b76177f (tip d5e0073cb091): the frame shows
# "t2-445843-42" in the focused pane's third tab (the daemon and app checks of the same step passed), but recognition
# read the "t" as "+" on every try of step 55. The same misread: job of tip 3bcae6ca5d46 (2026-10-31), "+2-942934-42".
PLUS_FRAME = ["$ D", "S \u0428", "0~0-0x+v:", "$ echo t2-445843-$((6*7))", "+2-445843-42", "Did you know?",
              "Command Palette", "Run any cmux action by typing", "its name.", "Try It", "196P", "a"]


class OcrFold(unittest.TestCase):
    # Run 64ef2a21, ctrlbt-real-palette step 18 (STATUS 9303): check-35.png shows "733287-42" clearly, but recognition
    # read it as "733287-4źął" on 6 of 6 reads (cmux23 and cmux24), and as "733287-4zł" at 2x scale.
    def test_a_digit_read_as_an_accented_look_alike_still_shows_the_output_line(self):
        for read in ("733287-4źął", "733287-4zł", "733287-4ž2"):
            self.assertTrue(D.ocr_contains(["J> echo 733287-$((6*7))", read, "J>"], "733287-42"), read)

    def test_dropping_accents_still_needs_every_digit(self):
        for read in ("733287-43", "733287-4", "733287-$((6*7))", "733288-42", "733287-4źą3"):
            self.assertFalse(D.ocr_contains([read], "733287-42"), read)

    def test_a_t_read_as_plus_still_shows_the_output_line(self):
        self.assertTrue(D.ocr_contains(PLUS_FRAME, "t2-445843-42"))
        self.assertTrue(D.ocr_contains(["+2-942934-42"], "t2-942934-42"))

    def test_plus_folding_still_needs_the_token_the_nonce_and_the_result(self):
        self.assertFalse(D.ocr_contains(["+1-445843-42"], "t2-445843-42"))
        self.assertFalse(D.ocr_contains(["+2-445844-42"], "t2-445843-42"))
        self.assertFalse(D.ocr_contains(["+2-445843-41"], "t2-445843-42"))
        self.assertFalse(D.ocr_contains(["$ echo t2-445843-$((6*7))"], "t2-445843-42"))

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
