#!/usr/bin/env python3
"""scripts/cmux-next/chromium-live.py: which helpers it ends, how it swaps, what it records.

Run it yourself after changing chromium-live.py (under 1 s, no build, no app):
python3 tests/test_chromium_live.py
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("chromium_live", ROOT / "scripts/cmux-next/chromium-live.py")
cl = importlib.util.module_from_spec(spec)
sys.modules["chromium_live"] = cl
spec.loader.exec_module(cl)

APP = "/Users/me/Applications/cmux NEXT DEV live.app"
PS = f"""\
  500     1 {APP}/Contents/MacOS/cmux NEXT DEV live
  501   500 {APP}/Contents/Frameworks/cmux NEXT DEV live Helper (Renderer).app/Contents/MacOS/x --type=renderer --lang=en
  502   500 {APP}/Contents/Frameworks/cmux NEXT DEV live Helper (Renderer).app/Contents/MacOS/x --type=renderer --extension-process
  503   500 {APP}/Contents/Frameworks/cmux NEXT DEV live Helper (GPU).app/Contents/MacOS/x --type=gpu-process
  504   500 {APP}/Contents/Frameworks/cmux NEXT DEV live Helper.app/Contents/MacOS/x --type=utility
  505   500 /bin/zsh -l
  600     1 /Applications/cmux.app/Contents/MacOS/cmux
  601   600 /Applications/cmux.app/Contents/Frameworks/cmux Helper (Renderer).app/Contents/MacOS/x --type=renderer
"""


class HelpersTest(unittest.TestCase):
    def test_only_this_apps_page_renderers_end(self):
        procs = cl.parse_ps(PS)
        app_pid = cl.app_process(Path(APP), procs)
        self.assertEqual(app_pid, 500)
        self.assertEqual(cl.helpers_to_end(procs, app_pid, gpu=False), [501])
        self.assertEqual(cl.helpers_to_end(procs, app_pid, gpu=True), [501, 503])

    def test_an_app_that_is_not_running_is_an_error(self):
        with self.assertRaises(cl.LiveError):
            cl.app_process(Path("/Applications/Other.app"), cl.parse_ps(PS))


class SwapTest(unittest.TestCase):
    def test_the_swap_renames_so_the_mapped_file_keeps_its_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            dest = Path(d) / "Chromium Embedded Framework"
            dest.write_bytes(b"old" * 1000)
            new = Path(d) / "built"
            new.write_bytes(b"new" * 1000)
            with dest.open("rb") as mapped, mock.patch.object(cl, "run") as run:
                run.return_value = mock.Mock(returncode=1)  # no `cp -c`, no codesign here
                cl.swap_in(new, dest)
                self.assertEqual(mapped.read(3), b"old")
            self.assertEqual(dest.read_bytes()[:3], b"new")
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ["Chromium Embedded Framework", "built"])


class RespawnTest(unittest.TestCase):
    def test_it_ends_renderers_then_reloads_every_chromium_tab(self):
        tabs = json.dumps({"tabs": [{"id": "tab_1", "engine": "chromium"},
                                    {"id": "tab_2", "engine": "webkit"},
                                    {"id": "tab_3"}]}).encode()
        calls = []

        def fake_run(argv, **_):
            calls.append(argv)
            if argv[0] == "ps":
                return mock.Mock(returncode=0, stdout=PS.encode())
            if argv[-3:] == ["tabs", "--all", "--json"]:
                return mock.Mock(returncode=0, stdout=tabs)
            return mock.Mock(returncode=0, stdout=b"")

        killed = []
        with mock.patch.object(cl, "run", fake_run), mock.patch.object(cl.os, "kill",
                                                                     lambda pid, sig: killed.append(pid)), \
                mock.patch.dict(os.environ, {"CMUX_CLI": "cmux"}):
            result = cl.respawn(Path(APP))
        self.assertEqual(killed, [501])
        self.assertEqual(result["reloaded"], 2)
        self.assertIn(["cmux", "browser", "tab_1", "reload"], calls)
        self.assertIn(["cmux", "browser", "tab_3", "reload"], calls)
        self.assertNotIn(["cmux", "browser", "tab_2", "reload"], calls)


class StatusTest(unittest.TestCase):
    def test_status_prints_the_last_cycle_and_nothing_when_unused(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ,
                                                                {"CMUX_CHROMIUM_LIVE_STATE_DIR": d}):
            self.assertEqual(cl.main(["status", "--if-used"]), 0)
            cl.record(Path(d), {"at": 0, "files": ["third_party/blink/x.cc"],
                                "respawn": {"ended": [1, 2], "reloaded": 3},
                                "seconds": {"save_to_reloaded": 9.5, "build": 8.0}})
            line = cl.summary(json.loads((Path(d) / "last.json").read_text()))
            self.assertIn("2 renderers ended, 3 pages reloaded", line)
            self.assertIn("9.5 s", line)


class SyncTest(unittest.TestCase):
    def test_the_tree_copy_is_kept_before_the_edit_is_sent(self):
        calls = []

        def fake_run(argv, **kw):
            calls.append((argv, kw.get("input") or b""))
            return mock.Mock(returncode=0, stdout=b"/Users/b" if "HOME" in argv[-1] else b"")

        with tempfile.TemporaryDirectory() as d, mock.patch.object(cl, "run", fake_run):
            builder = cl.Builder({"build_host": "h", "src": "~/cef/src", "out": "out/R",
                                  "target": "libcef", "session": "s1"}, Path(d))
            builder.sync(Path(d), ["third_party/blink/x.cc"])
        kinds = ["rsync" if argv[0] == "rsync" else "keep" if cl.KEEP_SCRIPT.encode() == data
                 else "home" for argv, data in calls]
        self.assertEqual(kinds, ["home", "keep", "rsync"])
        keep_cmd = calls[1][0][-1]
        self.assertEqual(keep_cmd, "bash -s -- /Users/b/cef/src /Users/b/.cmux-chromium-live/s1 "
                                   "third_party/blink/x.cc")
        self.assertEqual(calls[2][0][-1], "h:/Users/b/cef/src/")

    def test_a_crafted_path_reaches_the_host_as_one_word(self):
        calls = []

        def fake_run(argv, **kw):
            calls.append(argv)
            return mock.Mock(returncode=0, stdout=b'{"rc": 0}')

        with tempfile.TemporaryDirectory() as d, mock.patch.object(cl, "run", fake_run):
            builder = cl.Builder({"build_host": "h", "src": "/x/$(touch pwned)", "out": "out/R",
                                  "target": "libcef", "session": "s1"}, Path(d))
            builder._home = "/Users/b"
            builder.build()
        self.assertIn("'/x/$(touch pwned)'", calls[0][-1])
        self.assertEqual(cl.BUILT_BINARY_REL, "Chromium Embedded Framework.framework/Versions/A/"
                                              "Chromium Embedded Framework")
        self.assertNotIn("eval ", cl.BUILD_SCRIPT + cl.KEEP_SCRIPT + cl.RESTORE_SCRIPT)


if __name__ == "__main__":
    unittest.main()
