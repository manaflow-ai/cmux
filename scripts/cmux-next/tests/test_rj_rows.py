"""a823 (follow-up to a801): on a capture mini at load 350 the journey's quit-after read of
`debug.surfaces` failed, every pane came back empty, and all seven terminals were reported as
"no terminal grid drawn" while the window shot shows them drawn. A row must say what it saw: an
unreadable report or a pane missing from it is not a terminal that drew no grid.

  python3 -I scripts/cmux-next/tests/test_rj_rows.py
"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rj_rows  # noqa: E402

DRAWN = {"presence": "visible", "attach": "live", "surface": {"grid": "48x39", "fit_grid": "48x39"}}


class GridFitsView(unittest.TestCase):
    def test_a_drawn_grid_that_fits_passes(self):
        row = rj_rows.grid_fits_view("quit-after", "ws[rj-term].s0.pane0", DRAWN)
        self.assertEqual(row, ("quit-after: ws[rj-term].s0.pane0.view.grid_fits_view", True, "grid 48x39, view fits 48x39", "layout"))

    def test_a_terminal_with_no_grid_fails_as_layout(self):
        view = {"presence": "visible", "surface": {"exists": False, "grid": None, "fit_grid": None}}
        row = rj_rows.grid_fits_view("quit-after", "p", view)
        self.assertEqual((row[1], row[2], row[3]), (False, "no terminal grid drawn", "layout"))

    def test_an_unreadable_report_is_not_a_missing_grid(self):
        report = {"error": "timed out"}
        row = rj_rows.grid_fits_view("quit-after", "p", {}, report)
        self.assertFalse(row[1])
        self.assertEqual(row[3], "harness")
        self.assertIn("timed out", row[2])
        self.assertNotIn("no terminal grid", row[2])

    def test_a_pane_missing_from_a_readable_report_says_so(self):
        report = {"windows": [{"panes": [{"pane": "other"}]}]}
        row = rj_rows.grid_fits_view("quit-after", "p", {}, report)
        self.assertFalse(row[1])
        self.assertEqual(row[2], "pane not in the app's view report")

    def test_a_pane_with_no_surface_says_so(self):
        row = rj_rows.grid_fits_view("quit-after", "p", {"presence": "visible", "kind": "terminal"}, {"windows": []})
        self.assertFalse(row[1])
        self.assertIn("no terminal surface", row[2])


class ReportError(unittest.TestCase):
    def test_reads_the_error_of_a_failed_report(self):
        self.assertEqual(rj_rows.report_error({"error": "timed out"}), "timed out")
        self.assertEqual(rj_rows.report_error(None), "no report")
        self.assertIsNone(rj_rows.report_error({"windows": []}))


if __name__ == "__main__":
    unittest.main()
