#!/usr/bin/env python3
"""The divider the split-resize bench drags (scripts/ci/frame-pacing/split_resize.py `_divider`).

Run: python3 scripts/cmux-next/tests/test_split_resize_divider.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci" / "frame-pacing"))
import split_resize  # noqa: E402


def pane(name: str, x: float, width: float) -> list:
    return [name, x, 2, width, 714, 1, 0, x, 2, width, 714, width, 714, 1, x, 2, width, 714]


class Divider(unittest.TestCase):
    def test_a_chat_at_the_window_edge_drags_its_split_divider(self) -> None:
        # The chat run on 2026-11-18: the chat (662..1096) has a divider on each side; the right one is the
        # window's edge and doesn't move.
        sample = {
            "dividers": [["column:column:10", 1092, 2, 8, 714, 1, 2], ["column:column:6", 658, 2, 8, 714, 1, 4]],
            "panes": [pane("left", 228, 434), pane("chat", 662, 434)],
        }
        self.assertEqual(split_resize._divider(sample, "chat")[0], "column:column:6")

    def test_the_nearer_divider_still_wins(self) -> None:
        sample = {
            "dividers": [["far", 300, 2, 8, 714, 1, 2], ["near", 658, 2, 8, 714, 1, 4]],
            "panes": [pane("chat", 662, 434)],
        }
        self.assertEqual(split_resize._divider(sample, "chat")[0], "near")


class FromPoint(unittest.TestCase):
    """A divider drag reads where the divider is before its trace starts (split_resize.from_point)."""

    def test_the_point_is_read_when_prepared_not_inside_the_gesture(self) -> None:
        log: list = []

        def point_of():
            log.append("read")  # in the app, a short motion trace of its own
            return 662.0, 358.5

        prepare = split_resize.from_point(point_of, lambda x, y: log.append(("drag", x, y)) or "dragged")
        act = prepare()
        self.assertEqual(log, ["read"])
        log.append("trace_start")
        self.assertEqual(act(), "dragged")
        self.assertEqual(log, ["read", "trace_start", ("drag", 662.0, 358.5)])

    def test_no_divider_is_an_error_not_a_drag(self) -> None:
        act = split_resize.from_point(lambda: None, lambda x, y: self.fail("dragged with no divider"))()
        self.assertEqual(act(), {"error": "no divider"})


if __name__ == "__main__":
    unittest.main()
