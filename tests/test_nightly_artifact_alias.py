#!/usr/bin/env python3
"""The accepted continuation artifact carries one DMG and recreates its alias safely."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"


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
        self.assertIn('verified recovery artifact must not contain a duplicate DMG alias', generate)
        publish_steps = {
            step["name"]: step for step in workflow["jobs"]["publish"]["steps"]
        }
        assemble = publish_steps["Assemble and verify all accepted publication inputs"]["run"]
        self.assertIn(
            'cp "$dir/$immutable" "nightly-out/${DMG_PREFIX}-${variant}.dmg"',
            assemble,
        )
        self.assertNotIn(
            'cp "$dir/${DMG_PREFIX}-${variant}.dmg"',
            assemble,
        )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verified = root / "verified"
            payloads = {}
            for variant in ("arm64", "x86_64", "universal"):
                folder = verified / f"accepted-{variant}-TEST"
                folder.mkdir(parents=True)
                immutable = folder / f"cmux-nightly-macos-{variant}-123.dmg"
                payload = f"signed-and-stapled-{variant}".encode()
                immutable.write_bytes(payload)
                payloads[variant] = payload
                feed = "appcast.xml" if variant == "universal" else f"appcast-{variant}.xml"
                (folder / feed).write_text("feed\n", encoding="utf-8")
                (folder / "cmux-nightly-notarization-recovery.json").write_text(
                    json.dumps({
                        "build": 123,
                        "immutable_path": immutable.name,
                        "final_dmg_sha256": hashlib.sha256(payload).hexdigest(),
                    }),
                    encoding="utf-8",
                )

            env = os.environ.copy()
            env.update({
                "SHORT_SHA": "TEST",
                "DMG_PREFIX": "cmux-nightly-macos",
                "GITHUB_ENV": str(root / "github.env"),
            })
            # Air's system Bash is 3.2 and cannot parse `${var,,}`. The real
            # publish job runs on Ubuntu; fixture hashes are already lowercase,
            # so direct comparison exercises the same gate here.
            portable_assemble = assemble.replace(
                '[ "${actual,,}" = "${expected,,}" ]',
                '[ "$actual" = "$expected" ]',
            )
            result = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", portable_assemble],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            for variant, payload in payloads.items():
                self.assertEqual(
                    (root / "nightly-out" / f"cmux-nightly-macos-{variant}.dmg").read_bytes(),
                    payload,
                )
            self.assertEqual(
                (root / "nightly-out" / "cmux-nightly-macos.dmg").read_bytes(),
                payloads["universal"],
            )


if __name__ == "__main__":
    unittest.main()
