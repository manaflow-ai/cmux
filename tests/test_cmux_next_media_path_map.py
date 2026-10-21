#!/usr/bin/env python3
"""A pull request that edits or adds a cmux-next tour gets that tour's shots.

path_map.py picked tours only from UI source paths, so a pull request that
changed tours/core.json (new steps, a new running state to show) ran no tour
and never showed the steps it added. A new tour file (a launch clip, a feature
walkthrough) tours itself too, so it can be recorded on the fleet by labeling
its pull request `media-tour`, without touching app code.
"""

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

    def test_a_tour_file_selects_its_own_tour(self) -> None:
        for name in path_map.TOUR_ORDER:
            with self.subTest(name=name):
                self.assertEqual(path_map.tours_for_path(f"scripts/cmux-next/media/tours/{name}.json"), [name])

    def test_a_tour_edit_counts_as_ui(self) -> None:
        result = path_map.map_paths(["scripts/cmux-next/media/tours/core.json"])
        self.assertTrue(result["is_ui"])
        self.assertEqual(result["tours"], ["core"])

    def test_the_tour_runner_selects_nothing(self) -> None:
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
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeChiefSettingsView.swift"),
            ["chief-settings"])
        # The empty Chief conversation's front page is the chief-settings tour's first shot.
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextHome/NativeTranscript/HomeFirstRunHero.swift"),
            ["chief-settings"])
        self.assertEqual(
            path_map.tours_for_path("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/SidebarUpdateCardView.swift"),
            ["update-card"])
        # The popup's page is webview UI: the gallery captures it (popover-media, popover-scroll).
        self.assertEqual(path_map.tours_for_path("webviews/src/pages/changelog/updateSurfaces.css"), [])
        self.assertTrue(path_map.is_gallery_path("webviews/src/pages/changelog/updateSurfaces.css"))

    def test_the_home_list_routes_to_the_home_tour(self) -> None:
        for path in ("Packages/macOS/CmuxNext/Sources/CmuxNextHome/Sidebar/HomeSidebarView.swift",
                     "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/Vendor/appkit-native/SidebarView.swift",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/DebugHomeSidebarFixture.swift"):
            with self.subTest(path=path):
                self.assertEqual(path_map.tours_for_path(path), ["home"])
        # The transcript side of Home is not the list's tour.
        self.assertEqual(path_map.tours_for_path("Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/PaneHost.swift"), [])


class WebviewPathTests(unittest.TestCase):
    """Webview UI renders the same in Linux Chromium, where the gallery advisory run captures it from
    fixture states, so a webview-only change takes no Mac. Glass and themes still tour on the Mac: they
    show the webview over the native window backdrop."""

    def test_webview_paths_take_no_mac_tour(self) -> None:
        for path in ("webviews/src/agent-session/acpmux/harnesses/harnesses.css",
                     "webviews/src/new-tab/NewTabRows.tsx",
                     "webviews/src/settings/Pages.tsx",
                     "webviews/test/chat-inspector.test.tsx",
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
