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
            path_map.tours_for_path("agent-chat/src/agent-pane/harnesses.css"), ["agent-pane"])
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabStripModel+PinnedClose.swift"), ["pinned-tabs"])
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/WorkspaceHoverCard.swift"),
            ["hover-card"])
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/SidebarUpdateCardView.swift"),
            ["update-card"])
        # The popup's page is webview UI: the gallery captures it (popover-media, popover-scroll).
        self.assertEqual(path_map.tours_for_path("webviews/src/pages/changelog/updateSurfaces.css"), [])
        self.assertTrue(path_map.is_gallery_path("webviews/src/pages/changelog/updateSurfaces.css"))


class WebviewPathTests(unittest.TestCase):
    """Webview UI renders the same in Linux Chromium, where the gallery advisory run captures it from
    fixture states, so a webview-only change takes no Mac. Glass and themes still tour on the Mac: they
    show the webview over the native window backdrop."""

    def test_webview_paths_take_no_mac_tour(self) -> None:
        for path in ("webviews/src/agent-session/acpmux/harnesses/harnesses.css",
                     "webviews/src/new-tab/NewTabRows.tsx",
                     "webviews/src/settings/Pages.tsx",
                     "webviews/test/session-rail.test.tsx",
                     "webviews/package.json"):
            with self.subTest(path=path):
                self.assertEqual(path_map.tours_for_path(path), [])

    def test_a_webview_only_change_is_captured_on_linux(self) -> None:
        paths = ["webviews/src/new-tab/NewTabRows.tsx", "webviews/src/agent-session/Composer.tsx"]
        result = path_map.map_paths(paths)
        self.assertFalse(result["is_ui"])
        self.assertEqual(result["tours"], [])
        self.assertEqual(result["gallery"], sorted(paths))

    def test_webview_themes_and_glass_still_tour_on_the_mac(self) -> None:
        self.assertEqual(path_map.tours_for_path("webviews/src/theme/composerStates.css"), ["glass"])
        self.assertEqual(path_map.tours_for_path("webviews/src/styles/glass.css"), ["glass"])

    def test_the_native_bridge_still_tours_on_the_mac(self) -> None:
        for path in ("webviews/src/agent-session/acpmux/native.ts",
                     "webviews/src/agent-session/acpmux/bridgeSocket.ts",
                     "webviews/src/comments/bridge.ts",
                     "webviews/src/protocol/generated/messages.ts"):
            with self.subTest(path=path):
                self.assertNotEqual(path_map.tours_for_path(path), [])
                self.assertEqual(path_map.map_paths([path])["gallery"], [])

    def test_a_native_change_beside_webview_changes_still_tours(self) -> None:
        result = path_map.map_paths([
            "webviews/src/new-tab/NewTabRows.tsx",
            "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/RowBadgeView.swift",
        ])
        self.assertTrue(result["is_ui"])
        self.assertEqual(result["tours"], ["core"])
        self.assertEqual(result["gallery"], ["webviews/src/new-tab/NewTabRows.tsx"])


if __name__ == "__main__":
    unittest.main()
