#!/usr/bin/env python3
"""iOS E2E installs AXe from its pinned archive, and the installer refuses an archive whose sha256 differs.

The Homebrew tap's formula uses a post-install DSL the runners' Homebrew lacks ("undefined method 'run' for an
instance of Homebrew::InstallSteps::DSL", ios-e2e job 132861077367), so `brew install cameroncooke/axe/axe` failed
every PR's prerequisites step. scripts/install-axe-ci.sh installs the formula's pinned archive instead.
"""

from __future__ import annotations

import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-e2e.yml"
INSTALLER = ROOT / "scripts" / "install-axe-ci.sh"


class IosE2EInstallsAxeWithoutTheTap(unittest.TestCase):
    def test_the_workflow_installs_axe_through_the_pinned_installer(self) -> None:
        text = WORKFLOW.read_text()
        self.assertNotIn("brew install cameroncooke/axe", text)
        self.assertIn("./scripts/install-axe-ci.sh", text)


class InstallerRefusesAWrongChecksum(unittest.TestCase):
    def test_a_wrong_sha256_is_refused_and_nothing_is_put_on_path(self) -> None:
        self.assertTrue(INSTALLER.is_file(), f"{INSTALLER} is missing")
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            payload = work / "payload"
            (payload / "Frameworks").mkdir(parents=True)
            (payload / "axe").write_text("#!/bin/sh\necho axe 0\n")
            archive = work / "axe.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                for item in payload.iterdir():
                    tar.add(item, arcname=item.name)
            github_path = work / "github_path"
            github_path.touch()
            runner_temp = work / "runner_temp"
            runner_temp.mkdir()
            env = {
                # No axe on this PATH, so the installer has to fetch and check the archive.
                "PATH": "/usr/bin:/bin",
                "HOME": str(work),
                "RUNNER_TEMP": str(runner_temp),
                "GITHUB_PATH": str(github_path),
                "AXE_URL": archive.as_uri(),
                "AXE_SHA256": "0" * 64,
            }
            done = subprocess.run(["bash", str(INSTALLER)], env=env, capture_output=True, text=True, timeout=60,
                                  stdin=subprocess.DEVNULL, check=False)
            self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
            # The checksum refused it, not a later step (codesign is absent off macOS).
            self.assertIn("FAILED", done.stderr)
            self.assertEqual(done.stdout, "", "a refused archive must print no axe directory")
            self.assertEqual(github_path.read_text(), "", "a refused archive must not reach GITHUB_PATH")


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main()
