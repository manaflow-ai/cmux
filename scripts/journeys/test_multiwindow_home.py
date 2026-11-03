#!/usr/bin/env python3
"""ext_multiwindow.is_home_item: the sidebar's Home item in both shapes debug.sidebar_rows gives. No fleet, no app.

    python3 scripts/journeys/test_multiwindow_home.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ext_multiwindow  # noqa: E402


class HomeItemTests(unittest.TestCase):
    def test_both_shapes_and_nothing_else(self):
        self.assertTrue(ext_multiwindow.is_home_item({"ref_kind": "built_in", "ref": "home"}))
        self.assertTrue(ext_multiwindow.is_home_item({"ref_kind": "app", "ref": "cmux/home"}))
        for other in ({"ref_kind": "app", "ref": "cmux/app-store"}, {"ref_kind": "built_in", "ref": "account"}, {}, None):
            self.assertFalse(ext_multiwindow.is_home_item(other))

    def test_sidebar_target_finds_the_app_home_item(self):
        side = {"window": "w", "items": [{"ref_kind": "app", "ref": "cmux/home", "window_frame": [0, 0, 10, 10]},
                                         {"ref_kind": "app", "ref": "cmux/app-store", "window_frame": [0, 10, 10, 10]}]}

        class J:
            class app:
                @staticmethod
                def rpc(method, params=None):
                    return {"windows": [side]}
        item, what = ext_multiwindow.sidebar_target(J(), "w", {"home": True})
        self.assertEqual((item["ref"], what), ("cmux/home", "home"))


if __name__ == "__main__":
    unittest.main()
