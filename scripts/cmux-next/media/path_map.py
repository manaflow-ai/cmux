#!/usr/bin/env python3
"""Map changed paths to the smallest cmux-next UI tours.

The mapper deliberately uses paths rather than labels, titles, or PR metadata.
It is a small CLI so the same decision is used by pull-request media jobs and
incremental DEV builds.

Webview code (webviews/) takes no Mac tour: its look is checked in Linux
Chromium by the gallery advisory run (gallery-advisory.yml), which renders the
gallery fixture states a change touches. Those paths are listed under
"gallery". Two kinds still tour on the Mac: glass and themes, which show the
webview over the native window backdrop, and the native bridge (the files that
talk to the app, the daemon or the pane protocol), which only a real app
exercises.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


TOUR_ORDER = ("new-tab", "agent-pane", "now-playing", "pinned-tabs", "hover-card", "update-card", "chief-settings", "glass", "home", "new-message", "core")
UI_ROOTS = (
    re.compile(r"^(?:Packages/macOS/CmuxNext/Sources|webviews/(?:src|apps)|agent-chat/(?:src|app|components?)/)"),
    re.compile(r"^(?:Packages/macOS/CmuxNext/(?:Resources|Tests?)/|webviews/|agent-chat/)"),
    # cmux's own themes, which the app bundles next to Ghostty's.
    re.compile(r"^Resources/cmux-themes/"),
    # MessagesLab's conversation list, Home's left column.
    re.compile(r"^Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/"),
)
NEW_TAB = re.compile(r"(?:new.?tab|NewTab)", re.IGNORECASE)
AGENT_PANE = re.compile(r"(?:agent.?pane|agent-session|AgentPane|acpmux)", re.IGNORECASE)
NOW_PLAYING = re.compile(r"(?:now.?playing|music)", re.IGNORECASE)
# Pinned tabs and the tab strip's close rules: the pinned-tabs tour pins, closes others and unpins.
PINNED_TABS = re.compile(r"(?:Pinned|PinCommands|/Pins/)")
# The hover cards (the sidebar workspace card, the tab card, their shared rows and panel), in dark, light and over art.
HOVER_CARD = re.compile(r"(?:WorkspaceHoverCard|TabHoverCard|HoverCards/|HoverCardGallery)")
# The sidebar's native Update Ready card and its popup window (the popup's React page is gallery work).
UPDATE_CARD = re.compile(r"(?:SidebarUpdateCard|SidebarUpdateNotes|UpdateReadyCard|UpdateSurfaceIsland)")
# The Chief's settings popover, the Home view that opens it, and the empty Chief conversation's
# front page (its hero, rows and the Chief's default face) that the same tour shows first.
CHIEF_SETTINGS = re.compile(r"(?:HomeChiefSettings|HomeHostView|HomeEngineStrings|HomeFirstRun)")
# Themes, glass and background art: the glass tour shows them over art and opaque.
GLASS = re.compile(r"(?:theme|glass|backdrop|WindowBackground|SurfaceBackground|TerminalHostView|cmux-themes|composerStates\.css)", re.IGNORECASE)
# Home's conversation list column: its header, rows and width (the home tour's widths, light and dark).
HOME = re.compile(r"(?:MessagesLabSidebar|CmuxNextHome/Sidebar/|HomeSidebar|TopHomePage)")
# Home's New Message page: its To: field and the suggestion list under it (the Chiefs before typing).
NEW_MESSAGE = re.compile(r"(?:CmuxNextHome/NewMessage/|HomeNewMessage)")
# Webview code: the gallery advisory run captures it on Linux (glass and themes excepted).
WEBVIEW = re.compile(r"^webviews/")
# Webview code that talks to the app or the daemon: the gallery's mock providers never run it.
NATIVE_BRIDGE = re.compile(r"(?:/(?:native|nativeError|bridge|bridgeSocket|wire|message-port)\.tsx?$|/protocol/)")
# A tour file selects its own tour, a new one (a launch clip, a feature walkthrough) too, so a pull
# request that adds or edits one records it without touching app code.
TOUR_FILE = re.compile(r"^scripts/cmux-next/media/tours/(?P<name>[a-z0-9][a-z0-9-]{0,39})\.json$")


def is_ui_path(path: str) -> bool:
    normalized = path.strip().lstrip("./")
    return bool(normalized and any(pattern.search(normalized) for pattern in UI_ROOTS))


def tours_for_path(path: str) -> list[str]:
    normalized = path.strip().lstrip("./")
    tour_file = TOUR_FILE.match(normalized)
    if tour_file:
        return [tour_file.group("name")]
    if not is_ui_path(normalized):
        return []
    if WEBVIEW.search(normalized) and not NATIVE_BRIDGE.search(normalized):
        return ["glass"] if GLASS.search(normalized) else []
    selected: list[str] = []
    if NEW_TAB.search(normalized):
        selected.append("new-tab")
    if AGENT_PANE.search(normalized):
        selected.append("agent-pane")
    if NOW_PLAYING.search(normalized):
        selected.append("now-playing")
    if PINNED_TABS.search(normalized):
        selected.append("pinned-tabs")
    if HOVER_CARD.search(normalized):
        selected.append("hover-card")
    if UPDATE_CARD.search(normalized):
        selected.append("update-card")
    if CHIEF_SETTINGS.search(normalized):
        selected.append("chief-settings")
    if GLASS.search(normalized):
        selected.append("glass")
    if HOME.search(normalized):
        selected.append("home")
    if NEW_MESSAGE.search(normalized):
        selected.append("new-message")
    if not selected:
        selected.append("core")
    return selected


def is_gallery_path(path: str) -> bool:
    """Webview code the gallery advisory run captures on Linux instead of a Mac tour."""
    normalized = path.strip().lstrip("./")
    return bool(WEBVIEW.search(normalized)) and not NATIVE_BRIDGE.search(normalized) \
        and not tours_for_path(normalized)


def map_paths(paths: list[str]) -> dict[str, object]:
    clean = sorted({path.strip() for path in paths if path.strip()})
    matches: dict[str, list[str]] = {tour: [] for tour in TOUR_ORDER}
    for path in clean:
        for tour in tours_for_path(path):
            matches.setdefault(tour, []).append(path)
    # Built-in tours first, in their fixed order; tours named by their own file after.
    extra = sorted(tour for tour in matches if tour not in TOUR_ORDER)
    tours = [tour for tour in (*TOUR_ORDER, *extra) if matches[tour]]
    return {
        "is_ui": bool(tours),
        "tours": tours,
        "matches": matches,
        "gallery": [path for path in clean if is_gallery_path(path)],
        "paths": clean,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="*", help="changed repository paths")
    parser.add_argument("--paths-file", type=Path, help="newline-delimited changed paths")
    parser.add_argument("--json", action="store_true", help="write the mapping as JSON")
    args = parser.parse_args(argv)
    paths = list(args.paths)
    if args.paths_file:
        paths.extend(args.paths_file.read_text(encoding="utf-8").splitlines())
    result = map_paths(paths)
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print("ui=" + ("true" if result["is_ui"] else "false"))
        print("tours=" + ",".join(result["tours"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
