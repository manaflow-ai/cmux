#!/usr/bin/env python3
"""bench_memory --release-hidden-chats turns agents.hiddenChats.discard on through settings.set, which writes the
app's cmux.json. On an attached app (--socket) that is the person's own settings, never restored, so the run is
refused before it touches the app (review of #37867, F1)."""
from __future__ import annotations

import contextlib
import ctypes
import io
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


class ReleaseAttachedTest(unittest.TestCase):
    def run_main(self, *argv: str) -> tuple[int, str]:
        err = io.StringIO()
        with mock.patch.object(sys, "argv", ["bench_memory.py", *argv]), contextlib.redirect_stderr(err), \
                mock.patch.object(bm, "App", side_effect=AssertionError("the app was reached")):
            with self.assertRaises(SystemExit) as stop:
                bm.main()
        return stop.exception.code, err.getvalue()

    def test_release_on_an_attached_app_is_refused(self):
        code, err = self.run_main("--app", "/nonexistent/cmux.app", "--socket", "/tmp/none.sock", "--app-pid", "1",
                                  "--workspaces", "10", "--release-hidden-chats", "1")
        self.assertEqual(code, 2)
        self.assertIn("--release-hidden-chats needs an app that this run launches", err)


if __name__ == "__main__":
    unittest.main()
