#!/usr/bin/env python3
"""The tour's runner picker takes no Mac for a change the Mac tour would not capture.

The route job ran on Linux, picked a Mac's session runner, and only the Mac
read the changed paths: a pull request that changed only webview code (or no
UI at all) still queued for a mini, checked out the repository there and then
recorded "no UI paths". The picker now reads the changed paths first.
"""

import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PICKER = os.path.join(ROOT, "scripts", "ci", "cmux_next_media_runner.py")
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci"))
import cmux_next_media_runner  # noqa: E402



class ScopeTests(unittest.TestCase):
    def pick(self, paths: list[str] | None) -> str | None:
        return cmux_next_media_runner.scope_reason(paths)

    def test_webview_only_paths_take_no_mac(self) -> None:
        reason = self.pick(["webviews/src/new-tab/NewTabRows.tsx"])
        self.assertIsNotNone(reason)
        self.assertIn("gallery", reason)
        self.assertIn("Linux", reason)

    def test_no_ui_paths_take_no_mac(self) -> None:
        self.assertIn("no UI paths", self.pick(["docs/README.md"]))
        self.assertIn("no UI paths", self.pick([""]))  # an empty listing: the file holds one newline

    def test_native_paths_still_need_the_mac(self) -> None:
        self.assertIsNone(self.pick(["Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/RowBadgeView.swift"]))

    def test_unknown_paths_never_skip_the_tour(self) -> None:
        self.assertIsNone(self.pick(None))

    def test_the_cli_writes_an_empty_runner_for_a_webview_change(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            paths = os.path.join(temp, "paths.txt")
            out = os.path.join(temp, "out")
            with open(paths, "w") as handle:
                handle.write("webviews/src/agent-session/Composer.tsx\n")
            env = {**os.environ, "GITHUB_OUTPUT": out, "POOL_OWNED": "1"}
            done = subprocess.run([sys.executable, PICKER, "--same-repo", "true", "--paths-file", paths],
                                  capture_output=True, text=True, env=env, check=False)
            self.assertEqual(done.returncode, 0, done.stderr)
            with open(out) as handle:
                lines = handle.read().splitlines()
            self.assertIn("runs_on=", lines)
            self.assertTrue(any(line.startswith("reason=") and "gallery" in line for line in lines), lines)

    def test_a_missing_paths_file_keeps_the_old_pick(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            out = os.path.join(temp, "out")
            env = {**os.environ, "GITHUB_OUTPUT": out, "POOL_OWNED": "0"}
            done = subprocess.run([sys.executable, PICKER, "--same-repo", "true",
                                   "--paths-file", os.path.join(temp, "absent.txt")],
                                  capture_output=True, text=True, env=env, check=False)
            self.assertEqual(done.returncode, 0, done.stderr)
            with open(out) as handle:
                self.assertIn("CI_PR_POOL_OWNED", handle.read())

    def run_cli(self, temp: str, *extra: str, env: dict | None = None) -> list[str]:
        paths = os.path.join(temp, "paths.txt")
        out = os.path.join(temp, "out")
        with open(paths, "w") as handle:
            handle.write("webviews/src/agent-session/Composer.tsx\n")
        done = subprocess.run([sys.executable, PICKER, "--same-repo", "true", "--paths-file", paths, *extra],
                              capture_output=True, text=True, check=False,
                              env={**os.environ, "GITHUB_OUTPUT": out, "POOL_OWNED": "0", **(env or {})})
        self.assertEqual(done.returncode, 0, done.stderr)
        with open(out) as handle:
            return handle.read().splitlines()

    def test_the_media_tour_mac_label_tours_a_webview_change_on_a_mac(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            lines = self.run_cli(temp, "--force-mac")
        # Past the scope check, the usual pick decides (here: owned Macs are off).
        self.assertTrue(any("CI_PR_POOL_OWNED" in line for line in lines), lines)

    def test_a_broken_path_map_never_skips_the_tour(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            broken = os.path.join(temp, "media")
            os.makedirs(broken)
            with open(os.path.join(broken, "path_map.py"), "w") as handle:
                handle.write("raise RuntimeError('broken')\n")
            saved = cmux_next_media_runner.MEDIA
            cmux_next_media_runner.MEDIA = cmux_next_media_runner.Path(broken)
            sys.modules.pop("path_map", None)
            try:
                self.assertIsNone(cmux_next_media_runner.scope_reason(["webviews/src/a.tsx"]))
            finally:
                cmux_next_media_runner.MEDIA = saved
                sys.path.remove(broken)
                sys.modules.pop("path_map", None)


if __name__ == "__main__":
    unittest.main()
