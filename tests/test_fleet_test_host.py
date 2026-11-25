#!/usr/bin/env python3
"""A fleet host whose registry entry says no_local_tests refuses a test run; every other host runs it.

tests/fleet_test_host.py reads the fleet registry ($FLEET_REGISTRY, else ~/.ssh/config.d/fleet-registry.json) and
matches this host by its key, hostnames or aliases. tests/real_git.py's real_git() never returns a wrapper script.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fleet_test_host  # noqa: E402

REGISTRY = {"machines": {
    "leo-mac-1": {"hostnames": ["Leos-MacBook"], "aliases": ["lm1"], "no_local_tests": "a person's own Mac"},
    "builder-1": {"hostnames": ["builder-1.local"], "aliases": []},
}}


class FleetTestHostTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.registry = Path(self.tmp.name) / "fleet-registry.json"
        self.registry.write_text(json.dumps(REGISTRY))
        self.env = {"FLEET_REGISTRY": str(self.registry), "HOME": self.tmp.name}

    def test_a_marked_host_is_refused_by_key_hostname_or_alias(self):
        for name in ("leo-mac-1", "leos-macbook.local", "LM1"):
            self.assertEqual(fleet_test_host.refusal(self.env, name), "a person's own Mac", name)

    def test_any_other_host_runs(self):
        for name in ("builder-1", "ci-runner-7", "localhost"):
            self.assertIsNone(fleet_test_host.refusal(self.env, name), name)

    def test_no_registry_or_a_broken_one_runs(self):
        self.assertIsNone(fleet_test_host.refusal({"HOME": self.tmp.name}, "leo-mac-1"))
        self.registry.write_text("{not json")
        self.assertIsNone(fleet_test_host.refusal(self.env, "leo-mac-1"))
        self.registry.write_text(json.dumps({"machines": []}))
        self.assertIsNone(fleet_test_host.refusal(self.env, "leo-mac-1"))

    def test_the_default_registry_is_the_deployed_copy_under_home(self):
        deployed = Path(self.tmp.name) / ".ssh" / "config.d" / "fleet-registry.json"
        deployed.parent.mkdir(parents=True)
        deployed.write_text(json.dumps(REGISTRY))
        self.assertEqual(fleet_test_host.refusal({"HOME": self.tmp.name}, "lm1"), "a person's own Mac")

    def test_importing_a_fixture_module_on_a_marked_host_exits_2_with_the_fleet_command(self):
        # This host's own name, marked: the import refuses before any test runs.
        me = fleet_test_host.this_host()
        self.registry.write_text(json.dumps({"machines": {me: {"no_local_tests": "no tests here"}}}))
        env = {**os.environ, "FLEET_REGISTRY": str(self.registry)}
        result = subprocess.run([sys.executable, "-c", "import git_fixture_env"], cwd=HERE, env=env,
                                capture_output=True, text=True, timeout=60, start_new_session=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("no tests here", result.stderr)
        self.assertIn("cmux-ci test -- ", result.stderr)


class RealGitTests(unittest.TestCase):
    def test_a_wrapper_first_on_path_that_execs_git_again_is_never_the_real_git(self):
        # The cosmic-gray loop (2026-11-10): a wrapper named git first on PATH; real_git() must not return it, and a
        # fake that execs real_git() finishes at once instead of handing the call back and forth.
        with tempfile.TemporaryDirectory() as tmp:
            wrapper_dir = Path(tmp) / "wrapper"
            wrapper_dir.mkdir()
            (wrapper_dir / "git").write_text('#!/bin/sh\nexec git "$@"\n')
            (wrapper_dir / "git").chmod(0o755)
            code = "import real_git; print(real_git.real_git())"
            env = {**os.environ, "PATH": f"{wrapper_dir}{os.pathsep}{os.environ['PATH']}", "FLEET_REGISTRY": os.devnull}
            started = time.monotonic()
            found = subprocess.run([sys.executable, "-c", code], cwd=HERE, env=env, capture_output=True, text=True,
                                   timeout=60, start_new_session=True)
            self.assertEqual(found.returncode, 0, found.stderr)
            real = found.stdout.strip()
            self.assertNotEqual(Path(real).parent, wrapper_dir)
            with open(real, "rb") as handle:
                self.assertNotEqual(handle.read(2), b"#!")
            fake_dir = Path(tmp) / "fake"
            fake_dir.mkdir()
            (fake_dir / "git").write_text(f'#!/bin/sh\nexec "{real}" "$@"\n')
            (fake_dir / "git").chmod(0o755)
            env["PATH"] = f"{fake_dir}{os.pathsep}{env['PATH']}"
            done = subprocess.run(["git", "--version"], env=env, capture_output=True, text=True, timeout=30,
                                  start_new_session=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertLess(time.monotonic() - started, 10)

    def test_run_bounded_kills_a_hung_group_and_fails(self):
        sys.path.insert(0, str(HERE))
        import real_git
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            real_git.run_bounded(["bash", "-c", "sleep 600 & wait"], timeout=1)
        self.assertLess(time.monotonic() - started, 30)


if __name__ == "__main__":
    unittest.main()
