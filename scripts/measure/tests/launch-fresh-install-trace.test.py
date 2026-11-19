#!/usr/bin/env python3
"""launch-fresh-install-trace.py reduces one traced first launch's fs_usage capture to when the app's process first
ran against its spawn, and what the system's checkers read in the bundle.

    python3 scripts/measure/tests/launch-fresh-install-trace.test.py
"""

import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("launch_fresh_install_trace", HERE.parent / "launch-fresh-install-trace.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

APP = "/Applications/cmux-fresh-install-x/cmux NEXT.app"
CAPTURE = f"""\
23:40:00.100000  open              F=4        (R_____)  {APP}/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework   0.400000   syspolicyd.901
23:40:00.200000  posix_spawn       {APP}/Contents/MacOS/cmux                     2.900000   launchd.11
23:40:00.300000  read              F=4    B=0x100000  {APP}/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp   1.200000   syspolicyd.901
23:40:01.500000  read              F=5    B=0x100000  {APP}/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp   0.300000   syspolicyd.901
23:40:03.150000  stat64            {APP}/Contents/MacOS/cmux                     0.000010   cmux.77
23:40:03.180000  open              F=3        (R_____)  {APP}/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp   0.000020   cmux.77
23:40:04.000000  open              F=9        (R_____)  {APP}/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework   0.000030   cmux.78
not an fs_usage line
"""


class TraceTest(unittest.TestCase):
    def reduce(self, capture=CAPTURE, log=()):
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
            f.write(capture)
            f.flush()
            events = module.parse(f.name)
        return module.reduce(events, list(log), APP, {"label": "q-T", "row": "q"})

    def test_spawn_and_the_app_s_first_call(self):
        out = self.reduce()
        self.assertEqual(out["spawns"], 1)
        self.assertEqual(out["spawn_by"], "launchd")
        self.assertEqual(out["spawn_elapsed"], 2900.0)
        self.assertEqual(out["app_first_call"], 2950.0)
        self.assertEqual(out["app_open_framework"], 2980.0)
        self.assertEqual(out["chromium_first_open"], 3800.0)
        self.assertEqual(out["chromium_first_open_by"], "cmux")

    def test_checkers_reads_against_the_spawn(self):
        out = self.reduce()
        self.assertEqual(out["checker_reads"], 3)
        self.assertEqual(out["checker_first_read"], -100.0)
        self.assertEqual(out["checker_last_read"], 1300.0)
        self.assertEqual(out["checker_reads_before_spawn"], 1)
        self.assertEqual(out["checker_reads_after_first_call"], 0)
        top = out["checker_files"]
        self.assertEqual(top[0], ["/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp", 2, 1500.0])
        self.assertEqual(top[1][0], "/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework")

    def test_no_spawn_line_reports_counts_only(self):
        out = self.reduce(capture="23:40:00.100000  stat64  /x   0.000010   cmux.1\n", log=["XProtect scan began", "other"])
        self.assertEqual(out["spawns"], 0)
        self.assertNotIn("spawn_elapsed", out)
        self.assertEqual(out["log_lines"], 2)
        self.assertEqual(out["log_scan_lines"], 1)


if __name__ == "__main__":
    unittest.main()
