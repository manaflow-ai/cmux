#!/usr/bin/env python3
"""scripts/ci/owned_catch_up.sh: argument checks and the result line glaeda-idle-warm reads.

The build itself runs only on an owned mini (glaeda-idle-warm); here every run stops before any
xcodebuild, at a root no mini uses (99), so nothing touches a real canonical root.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/ci/owned_catch_up.sh"


def run(*args: str, env: dict[str, str] | None = None, cwd: Path = REPO) -> subprocess.CompletedProcess:
    base = {key: value for key, value in os.environ.items() if not key.startswith(("CMUX_", "GITHUB_"))}
    return subprocess.run(["bash", str(SCRIPT), *args], cwd=cwd, env={**base, **(env or {})},
                          capture_output=True, text=True, timeout=120)


class OwnedCatchUpTest(unittest.TestCase):
    def test_rejects_bad_arguments(self) -> None:
        for args in ((), ("1",), ("0", "/state"), ("x", "/state"), ("100", "/state"), ("1", "relative")):
            with self.subTest(args=args):
                self.assertEqual(run(*args, env={"CMUX_CI_XCODE_APP": "/Applications/Xcode.app"}).returncode, 64)

    def test_needs_an_xcode_pin(self) -> None:
        result = run("99", "/nonexistent-state")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CMUX_CI_XCODE_APP", result.stderr)

    def test_runs_only_from_its_own_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as other:
            subprocess.run(["git", "init", "-q", other], check=True)
            result = run("99", "/nonexistent-state", env={"CMUX_CI_XCODE_APP": "/Applications/Xcode.app"},
                         cwd=Path(other))
        self.assertEqual(result.returncode, 64)

    def test_a_failed_step_prints_the_result_line_and_keeps_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as state, tempfile.TemporaryDirectory() as tools:
            # A stub `defaults`, so the run never touches this Mac's Xcode defaults.
            calls = Path(tools) / "calls"
            stub = Path(tools) / "defaults"
            stub.write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\n')
            stub.chmod(0o755)
            result = run("99", state, env=git_fixture_env.fixture_env({"CMUX_CI_XCODE_APP": "/nonexistent/Xcode.app",
                                           "CMUX_CATCH_UP_LOG": os.path.join(state, "log"),
                                           "PATH": f"{tools}:{os.environ['PATH']}"}))
            self.assertEqual(result.returncode, 1)
            # An override a killed run left behind is cleared before anything else.
            self.assertIn("delete com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges", calls.read_text())
            line = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual((line["kept"], line["root"], line["phase"], line["reason"]),
                             ("false", 99, "setup", "select-ci-xcode"))
            self.assertRegex(line["head"], r"^[0-9a-f]{40}$")
            self.assertEqual(os.listdir(state), ["log"])  # no store was written

    def test_makes_the_web_bundles_current_before_the_tree_is_copied_and_built(self) -> None:
        # The app's Verify web bundles phase fails a build without the web bundles and the App
        # Store packages (build output since #45083): two catch-ups of the NEXT tip on
        # 2026-11-22 failed `compile exit 65` there. canonical-resolve copies this checkout
        # into the root's src, so the bundles must be current before it, and a failed step
        # must be named in the result line.
        text = SCRIPT.read_text()
        step = text.index("bash scripts/ci/ensure-web-bundles.sh")
        self.assertLess(step, text.index("compile-app-host-test-product.sh canonical-resolve"))
        self.assertLess(step, text.index("compile-app-host-test-product.sh canonical-build"))
        self.assertIn('ensure-web-bundles.sh >>"$log" 2>&1 || fail "web-bundles"', text)

    def test_fetches_this_trees_cmux_tui_before_the_tree_is_copied_and_built(self) -> None:
        # The Bundle cmux-tui phase never downloads: the 2026-11-22 rerun past Verify web bundles
        # failed `compile exit 65` on "the same-tree cmux-tui ... is not downloaded". It must not
        # hold an idle Mac waiting for an unpublished tree.
        text = SCRIPT.read_text()
        step = text.index("bash scripts/cmux-next/pin-cmux-tui.sh fetch")
        self.assertLess(step, text.index("compile-app-host-test-product.sh canonical-resolve"))
        self.assertIn('CMUX_TUI_TREE_WAIT_SECONDS=0 bash scripts/cmux-next/pin-cmux-tui.sh fetch >>"$log" 2>&1 '
                      '|| fail "cmux-tui"', text)


if __name__ == "__main__":
    unittest.main()
