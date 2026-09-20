#!/usr/bin/env python3
"""Exercise Amp status/install safety through the shipped CLI in an owned HOME."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class AmpInstallStateTests(unittest.TestCase):
    def setUp(self):
        self.cli = os.environ["CMUX_CLI_BIN"]
        self.directory = tempfile.TemporaryDirectory(prefix="cmux-amp-state-")
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.env = {**os.environ, "HOME": str(self.home)}
        self.path = self.home / ".config/amp/plugins/cmux-session.ts"
        self.path.parent.mkdir(parents=True)

    def run_cli(self, *arguments):
        result = subprocess.run(
            [self.cli, "hooks", "amp", *arguments], env=self.env,
            capture_output=True, text=True, timeout=20,
        )
        self.assertGreaterEqual(result.returncode, 0, 'CLI terminated by a signal')
        return result

    def state(self):
        result = self.run_cli("install", "--status-json")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["state"]

    def test_missing_install_current_repair_and_remove(self):
        self.assertEqual(self.state(), "missing")
        self.assertFalse(self.path.exists(), "status must not create a hook")
        self.assertEqual(self.run_cli("install", "--yes").returncode, 0)
        self.assertEqual(self.state(), "installed")
        original = self.path.read_bytes()
        self.path.write_bytes(original + b"\n// older installation\n")
        self.assertEqual(self.state(), "stale")
        self.assertEqual(self.run_cli("install", "--yes").returncode, 0)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(self.state(), "installed")
        self.assertEqual(self.run_cli("uninstall").returncode, 0)
        self.assertEqual(self.state(), "missing")

    def test_foreign_and_empty_files_are_not_installable(self):
        for content in (b"// user plugin\n", b""):
            with self.subTest(content=content):
                self.path.write_bytes(content)
                self.assertEqual(self.state(), "conflict")
                self.assertNotEqual(self.run_cli("install", "--yes").returncode, 0)
                self.assertEqual(self.path.read_bytes(), content)

    def test_unreadable_content_is_not_missing_or_overwritten(self):
        content = b"\xff\xfe\x80user-owned plugin"
        self.path.write_bytes(content)
        status = self.run_cli("install", "--status-json")
        self.assertNotEqual(status.returncode, 0, status.stdout)
        self.assertNotEqual(self.run_cli("install", "--yes").returncode, 0)
        self.assertEqual(self.path.read_bytes(), content)
        self.assertNotEqual(self.run_cli("uninstall").returncode, 0)
        self.assertEqual(self.path.read_bytes(), content)
        self.path.unlink()
        self.assertEqual(self.state(), "missing", "status recovers after the user fixes the file")

    def test_dangling_symlink_is_preserved(self):
        target = self.home / "missing-user-plugin.ts"
        self.path.symlink_to(target)
        self.assertNotEqual(self.run_cli("install", "--status-json").returncode, 0)
        self.assertNotEqual(self.run_cli("install", "--yes").returncode, 0)
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(self.path.readlink(), target)
        self.assertFalse(target.exists())

    def test_install_does_not_replace_unreadable_hook(self):
        content = b"\xff\xfe\x80user-owned plugin"
        self.path.write_bytes(content)
        result = self.run_cli("install", "--yes")
        self.assertEqual(self.path.read_bytes(), content)
        self.assertNotEqual(result.returncode, 0)

    def test_directory_is_not_missing(self):
        self.path.mkdir()
        self.assertNotEqual(self.run_cli("install", "--status-json").returncode, 0)
        self.assertNotEqual(self.run_cli("install", "--yes").returncode, 0)
        self.assertTrue(self.path.is_dir())


if __name__ == "__main__":
    unittest.main()
