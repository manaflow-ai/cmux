#!/usr/bin/env python3
"""bench_memory.owned counts the app's WebKit processes after a direct launch too: macOS holds the
launching script's responsible process responsible for them then, not the app. A WebKit process that
ran before the launch, or that another app is responsible for, stays out. Off macOS the libproc
and libSystem handles are stubs: the test mocks every call it reaches."""

from __future__ import annotations

import ctypes
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402

BUNDLE = "/tmp/cmux DEV.app"
APP, SCRIPT_OWNER, OTHER = 100, 50, 70
WEBKIT = "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
TABLE = [
    (APP, 1, BUNDLE + "/Contents/MacOS/cmux DEV"),
    (201, 1, WEBKIT),  # the app's, started after the launch
    (202, 1, WEBKIT),  # the script owner's, running before the launch
    (203, 1, WEBKIT),  # another app's
]
RESPONSIBLE = {APP: SCRIPT_OWNER, 201: SCRIPT_OWNER, 202: SCRIPT_OWNER, 203: OTHER}


class WebKitAfterDirectLaunch(unittest.TestCase):
    def owned(self, direct: bool, before: set[int]):
        with mock.patch.object(bm, "process_table", return_value=TABLE), \
             mock.patch.object(bm, "_responsible", side_effect=lambda pid: RESPONSIBLE.get(pid, -1)), \
             mock.patch.object(bm, "_direct_launch", direct), \
             mock.patch.object(bm, "_webkit_before", before):
            return {pid for pid, (kind, _) in bm.owned(APP, BUNDLE).items() if kind.startswith("webkit-")}

    def test_direct_launch_counts_the_apps_webkit_processes(self):
        self.assertEqual(self.owned(direct=True, before={202}), {201})

    def test_launch_through_open_counts_only_the_app_as_responsible(self):
        self.assertEqual(self.owned(direct=False, before=set()), set())


if __name__ == "__main__":
    unittest.main()
