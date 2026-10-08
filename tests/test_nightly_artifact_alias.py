#!/usr/bin/env python3
"""The accepted continuation artifact carries one DMG and recreates its alias safely."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"
RECONSTRUCT = ROOT / "scripts/ci/reconstruct-notarized-alias.py"


class NightlyArtifactAliasTests(unittest.TestCase):
    def test_accepted_artifact_omits_alias_and_reconstructs_it_from_verified_immutable(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        wait_steps = {
            step["name"]: step for step in workflow["jobs"]["wait-and-staple"]["steps"]
        }
        generate = wait_steps["Generate verified Sparkle feed"]["run"]
        self.assertNotIn(
            'cp "verified/$IMMUTABLE_NAME" "verified/$ALIAS_NAME"',
            generate,
        )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            immutable = root / "cmux-nightly-macos-arm64-123.dmg"
            alias = root / "cmux-nightly-macos-arm64.dmg"
            immutable.write_bytes(b"signed-and-stapled-dmg")
            expected_sha = hashlib.sha256(immutable.read_bytes()).hexdigest()
            (root / "appcast-arm64.xml").write_text("feed\n", encoding="utf-8")
            (root / "cmux-nightly-notarization-recovery.json").write_text(
                json.dumps({"immutable_path": immutable.name}), encoding="utf-8"
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(RECONSTRUCT),
                    str(immutable),
                    str(alias),
                    expected_sha,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(alias.read_bytes(), immutable.read_bytes())
            self.assertEqual(
                hashlib.sha256(alias.read_bytes()).hexdigest(),
                expected_sha,
            )


if __name__ == "__main__":
    unittest.main()
