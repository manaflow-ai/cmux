#!/usr/bin/env python3
"""The Chief's chat is the native iMessage transcript (design/home.md, "The Chief's chat").

The Chief panel and conversation tabs draw `HomeHostView` over `CmuxNextHome/NativeTranscript`.
#37777 swapped both to the React Messages page and deleted the native transcript; Leo
(2026-11-10) had it turned back and reinforced. This fails a change that does that again.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Packages/macOS/CmuxNext/Sources"
SPEC = "design/home.md, \"The Chief's chat\""


def read(relative: str) -> str:
    path = SOURCES / relative
    if not path.is_file():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing; the Chief's chat is native ({SPEC})")
    return path.read_text(encoding="utf-8")


class ChiefNativeTranscriptTests(unittest.TestCase):
    def test_conversation_tabs_and_the_chief_panel_host_the_native_view(self) -> None:
        tab = read("CmuxNextApp/TabContent.swift")
        self.assertTrue(re.search(r"case conversation\(HomeHostView\)", tab),
                        f"a conversation tab (and the Chief panel, which reads its view) must be HomeHostView ({SPEC})")
        workspace = read("CmuxNextApp/Home/HomeService+Workspace.swift")
        body = re.search(r"func tabView\(for tab: TabModel\) -> HomeHostView\?(.*?)\n    }\n", workspace, re.S)
        self.assertIsNotNone(body, f"HomeService.tabView(for:) must return HomeHostView ({SPEC})")
        self.assertIn("HomeHostView(services: services, conversation: conversation)", body.group(1),
                      f"HomeService.tabView(for:) must make the native HomeHostView ({SPEC})")

    def test_the_native_transcript_is_kept(self) -> None:
        for relative in (
            "CmuxNextApp/Home/HomeHostView.swift",
            "CmuxNextHome/NativeTranscript/HomeNativeTranscriptView.swift",
        ):
            read(relative)

    def test_the_spec_names_it(self) -> None:
        spec = (ROOT / "design/home.md").read_text(encoding="utf-8")
        self.assertTrue("## The Chief's chat" in spec, "design/home.md keeps the Chief's chat spec")
        self.assertTrue("test_chief_native_transcript.py" in spec, "the spec names this guard")


if __name__ == "__main__":
    sys.exit(unittest.main())
