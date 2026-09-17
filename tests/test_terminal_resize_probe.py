"""Behavior checks for the diagnostic's reply decoder and measurement labels."""

import importlib.util
from pathlib import Path
import sys
import unittest


path = Path(__file__).resolve().parents[1] / "scripts" / "terminal-resize-probe.py"
spec = importlib.util.spec_from_file_location("terminal_resize_probe", path)
probe = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = probe
spec.loader.exec_module(probe)


class ResizeProbeTests(unittest.TestCase):
    def test_fragmented_cursor_reply_does_not_become_keyboard_input(self):
        decoder = probe.InputDecoder()
        self.assertEqual(decoder.feed(b"\x1b[4"), ([], b""))
        self.assertEqual(decoder.feed(b"4;13"), ([], b""))
        self.assertEqual(decoder.feed(b"4Rs"), ([probe.Grid(134, 44)], b"s"))

    def test_arrow_and_focus_sequences_do_not_trigger_commands(self):
        reports, keys = probe.InputDecoder().feed(b"\x1b[A\x1b[I\x1b[?1;2cq")
        self.assertEqual(reports, [])
        self.assertEqual(keys, b"q")

    def test_resize_during_query_is_not_reported_as_corruption(self):
        before, after = probe.Grid(134, 44), probe.Grid(43, 44)
        self.assertEqual(probe.classify(before, after, before, 2, 3), "overlapping_resize")

    def test_same_size_return_after_resize_is_still_a_transition(self):
        size = probe.Grid(134, 44)
        self.assertEqual(probe.classify(size, size, probe.Grid(43, 44), 2, 4),
                         "overlapping_resize")

    def test_distinct_parser_grid_with_stable_observations_is_recorded(self):
        size = probe.Grid(134, 44)
        self.assertEqual(probe.classify(size, size, probe.Grid(43, 44), 2, 2),
                         "grid_mismatch")
        self.assertEqual(probe.classify(size, size, size, 2, 2), "match")


if __name__ == "__main__":
    unittest.main()
