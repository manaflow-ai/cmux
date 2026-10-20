#!/usr/bin/env python3
"""A pull request that edits a cmux-next tour gets that tour's shots.

path_map.py picked tours only from UI source paths, so a pull request that
changed tours/core.json (new steps, a new running state to show) ran no tour
and never showed the steps it added.
"""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next", "media"))
import path_map  # noqa: E402


class TourFilePathTests(unittest.TestCase):
    def test_a_tour_file_selects_its_own_tour(self) -> None:
        for name in path_map.TOUR_ORDER:
            with self.subTest(name=name):
                self.assertEqual(path_map.tours_for_path(f"scripts/cmux-next/media/tours/{name}.json"), [name])

    def test_a_tour_edit_counts_as_ui(self) -> None:
        result = path_map.map_paths(["scripts/cmux-next/media/tours/core.json"])
        self.assertTrue(result["is_ui"])
        self.assertEqual(result["tours"], ["core"])

    def test_an_unknown_tour_file_and_the_tour_runner_select_nothing(self) -> None:
        self.assertEqual(path_map.tours_for_path("scripts/cmux-next/media/tours/draft.json"), [])
        self.assertEqual(path_map.tours_for_path("scripts/cmux-next/media/tour.py"), [])

    def test_ui_sources_still_route_by_name(self) -> None:
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/RowBadgeView.swift"), ["core"])
        self.assertEqual(
            path_map.tours_for_path("webviews/src/agent-session/acpmux/harnesses/harnesses.css"), ["agent-pane"])
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/WorkspaceHoverCard.swift"),
            ["hover-card"])
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeChiefSettingsView.swift"),
            ["chief-settings"])


if __name__ == "__main__":
    unittest.main()
