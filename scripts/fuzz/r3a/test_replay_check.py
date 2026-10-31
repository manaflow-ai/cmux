import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay_check as R  # noqa: E402


class Rows(unittest.TestCase):
    def test_logical_line_rewraps_to_the_daemons_physical_rows(self):
        # e1's terminal: 21 cells at 20 columns are two physical rows; the app's view reports one logical line.
        daemon = "00 0A0a  0A0AA AaAA0\na"
        view = "00 0A0a  0A0AA AaAA0a"
        self.assertIsNone(R.difference(daemon, view, 20))

    def test_e1_lost_cell_is_a_difference(self):
        diff = R.difference("00 0A0a  0A0AA AaAA0\na", "00 0A0a  0A0AA AaAAa", 20)
        self.assertEqual(diff["row"], 0)

    def test_e2_shifted_row_is_a_difference(self):
        daemon = "top\n\nNu"
        view = "top\n\n" + " " * 43 + "Nu"
        self.assertEqual(R.difference(daemon, view, 164)["row"], 2)

    def test_wide_characters_take_two_cells(self):
        self.assertEqual(R.rows("世世世", 4), ["世世", "世"])

    def test_combining_marks_take_no_cell(self):
        self.assertEqual(R.rows("éé", 2), ["éé"])

    def test_trailing_blanks_and_rows_do_not_count(self):
        self.assertIsNone(R.difference("a  \nb\n\n\n", "a\nb", 10))

    def test_cursor_difference_reported_when_rows_match(self):
        self.assertEqual(R.difference("a", "a", 5, (0, 1), (0, 2)), {"cursor": {"daemon": [0, 1], "view": [0, 2]}})


class Settled(unittest.TestCase):
    def test_changing_screen_gives_no_verdict_not_a_fail(self):
        revisions = iter(range(100))
        result = R.settled_difference(lambda: {"revision": next(revisions), "text": "x", "cols": 10},
                                      lambda: "y", tries=3, pause=0)
        self.assertEqual(result["verdict"], "NOVERDICT")

    def test_stable_screen_is_judged(self):
        read = lambda: {"revision": "7", "text": "abc\nd", "cols": 3}
        self.assertEqual(R.settled_difference(read, lambda: "abcd", pause=0)["verdict"], "PASS")
        self.assertEqual(R.settled_difference(read, lambda: "abc", pause=0)["verdict"], "FAIL")


if __name__ == "__main__":
    unittest.main()
