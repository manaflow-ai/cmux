#!/usr/bin/env python3
"""bench_relaunch_reconnect's first-paint numbers: (a) to (d) from the window's first frame, and the
new-version bundle an update installs (every agent page script new, pane.css under a new name).

  python3 -I scripts/cmux-next/tests/test_bench_relaunch_first_paint.py
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
# The bench's helpers load macOS libproc when imported; these tests call none of it, so they run on
# Linux too with the library load stubbed for the import.
with mock.patch("ctypes.CDLL"):
    import bench_relaunch_reconnect as rr  # noqa: E402


class SeenTests(unittest.TestCase):
    def test_each_is_measured_from_the_window_first_frame(self):
        seen = rr.seen({"window first frame": 400, "terminal content": 420, "browser first paint": 600,
                        "pane painted": 900, "page settled drawn": 1500})
        self.assertEqual(seen, {"(a) terminal": 20, "(b) browser": 200, "(c) chat rows": 500, "(d) chat settled": 1100})

    def test_the_pane_picture_counts_as_the_chat_on_screen_when_it_came_first(self):
        seen = rr.seen({"window first frame": 400, "launch image shown": 410, "pane painted": 900})
        self.assertEqual(seen["(c) chat rows"], 10)

    def test_a_shift_after_the_settled_frame_moves_d(self):
        seen = rr.seen({"window first frame": 0, "page settled drawn": 1000, "page last layout shift": 1800})
        self.assertEqual(seen["(d) chat settled"], 1800)

    def test_a_shift_before_the_settled_frame_or_past_the_watch_does_not(self):
        before = rr.seen({"window first frame": 0, "page settled drawn": 1000, "page last layout shift": 700})
        late = rr.seen({"window first frame": 0, "page settled drawn": 1000,
                        "page last layout shift": 1000 + rr.SETTLE_WATCH_MS + 1})
        self.assertEqual(before["(d) chat settled"], 1000)
        self.assertEqual(late["(d) chat settled"], 1000)

    def test_a_missing_end_is_none(self):
        seen = rr.seen({"terminal content": 420})
        self.assertIsNone(seen["(a) terminal"])
        self.assertIsNone(rr.seen({"window first frame": 1})["(d) chat settled"])


class NewVersionTests(unittest.TestCase):
    def make_bundle(self, root: str) -> str:
        bundle = os.path.join(root, "cmux DEV x.app")
        page = os.path.join(bundle, "Contents", "Resources", "agent-pane")
        os.makedirs(os.path.join(page, "chunks"))
        os.makedirs(os.path.join(page, "locales"))
        for name, text in (("pane.js", "export {};"), ("chat-snapshot.js", "1;"), ("chunks/a.js", "2;"), ("locales/en.js", "3;"),
                           ("pane.css", "a{}"), ("index.html", '<link href="pane.css?h=0123456789abcdef" />')):
            with open(os.path.join(page, name), "w") as handle:
                handle.write(text)
        with open(os.path.join(bundle, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump({"CFBundleVersion": "100", "CFBundleShortVersionString": "0.1", "CMUXCommit": "a" * 40}, handle)
        return bundle

    def test_every_page_script_and_the_sheet_name_change_and_the_version_moves_on(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = self.make_bundle(root)
            page = os.path.join(bundle, "Contents", "Resources", "agent-pane")
            before = {name: open(os.path.join(page, name)).read() for name in ("pane.js", "chat-snapshot.js", "chunks/a.js", "locales/en.js", "pane.css")}
            ok = subprocess.CompletedProcess([], 0, "", "")
            with mock.patch.object(rr.subprocess, "run", return_value=ok) as run:
                rr.new_version_bundle(bundle, 1)
            for name, text in before.items():
                self.assertNotEqual(Path(page, name).read_text(), text, name)
            index = Path(page, "index.html").read_text()
            self.assertNotIn("0123456789abcdef", index)
            self.assertRegex(index, r"pane\.css\?h=[0-9a-f]{16}")
            with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
                info = plistlib.load(handle)
            self.assertEqual(info["CFBundleVersion"], "100.1")
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.1")
            self.assertTrue(re.fullmatch(r"[0-9a-f]{40}", info["CMUXCommit"]) and info["CMUXCommit"] != "a" * 40)
            self.assertIn("codesign", run.call_args[0][0][0])

    def test_a_bundle_without_an_agent_page_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = os.path.join(root, "empty.app")
            os.makedirs(os.path.join(bundle, "Contents"))
            with self.assertRaises(RuntimeError):
                rr.new_version_bundle(bundle, 1)


if __name__ == "__main__":
    unittest.main()
