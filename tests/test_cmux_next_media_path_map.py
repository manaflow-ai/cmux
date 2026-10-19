#!/usr/bin/env python3
"""scripts/cmux-next/media/path_map.py: a pull request that adds or edits a tour file
gets that tour, so a new tour (a launch clip, a feature walkthrough) can be recorded on
the fleet by labeling its pull request `media-tour`, without touching app code."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next/media"))

import capture_paths  # noqa: E402
import path_map  # noqa: E402


class TourFilePathTests(unittest.TestCase):
    def test_an_edited_builtin_tour_selects_itself(self) -> None:
        result = path_map.map_paths(["scripts/cmux-next/media/tours/glass.json"])
        self.assertTrue(result["is_ui"])
        self.assertEqual(result["tours"], ["glass"])

    def test_a_new_tour_file_selects_itself_after_the_builtin_tours(self) -> None:
        result = path_map.map_paths([
            "scripts/cmux-next/media/tours/launch-themes.json",
            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/NewTabPage.swift",
        ])
        self.assertEqual(result["tours"], ["new-tab", "launch-themes"])
        self.assertEqual(result["matches"]["launch-themes"],
                         ["scripts/cmux-next/media/tours/launch-themes.json"])

    def test_other_media_scripts_select_no_tour(self) -> None:
        result = path_map.map_paths([
            "scripts/cmux-next/media/tour.py",
            "scripts/cmux-next/media/tours/README.md",
            "scripts/cmux-next/media/tours/nested/x.json",
        ])
        self.assertFalse(result["is_ui"])
        self.assertEqual(result["tours"], [])

    def test_capture_finds_the_file_for_a_new_tour(self) -> None:
        self.assertEqual(capture_paths.tour_file("launch-themes"),
                         capture_paths.TOURS / "launch-themes.json")
        self.assertEqual(capture_paths.tour_file("glass"), capture_paths.TOURS / "glass.json")

    def test_every_checked_in_tour_maps_to_itself(self) -> None:
        for path in sorted(capture_paths.TOURS.glob("*.json")):
            relative = path.relative_to(ROOT).as_posix()
            self.assertEqual(path_map.map_paths([relative])["tours"], [path.stem], relative)


if __name__ == "__main__":
    unittest.main()
