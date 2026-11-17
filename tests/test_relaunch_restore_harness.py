#!/usr/bin/env python3
"""scripts/ci/relaunch_restore_check.py puts its test agent's harness profile where a DEV build's acpmux reads it.

A tagged bench build (bundle id com.cmuxterm.app.debug.<tag>) keeps its user harness folder in its own acpmux home
unless the run names its config root with XDG_CONFIG_HOME (acpmux config/profiles.rs ProfileSources::current), so a
profile written only to HOME/.config/cmux/harnesses was "unknown harness l5fake" on such a build. The run's
environment, which every launch (the relaunches too) starts from, must name that root and the profile must be in it.
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import relaunch_restore_check as l5  # noqa: E402


class PrepareHarness(unittest.TestCase):
    def test_profile_is_in_the_folder_the_env_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "h"
            home.mkdir()
            env = {"HOME": str(home)}
            l5.prepare_harness(env, "/tmp/fake_agent.py")
            self.assertIn("XDG_CONFIG_HOME", env)
            profile = Path(env["XDG_CONFIG_HOME"]) / "cmux" / "harnesses" / f"{l5.HARNESS}.toml"
            self.assertTrue(profile.is_file(), profile)
            self.assertIn(f'id = "{l5.HARNESS}"', profile.read_text())
            self.assertTrue(str(profile).startswith(str(home)), "the profile stays inside the instance's HOME")


if __name__ == "__main__":
    unittest.main()
