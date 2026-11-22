#!/usr/bin/env python3
"""A bounded nightly-next notarization wait that runs out leaves a recovery artifact.

nightly.yml waits for Apple in the build job on nightly-next. When the wait
runs out, notarize-nightly-dmg.sh records the submission with
wait_timed_out=true (notarytool itself exited nonzero), and the recovery step
must still package it for the next nightly-next run. A submission that failed
for any other reason must not be handed off.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"


def prepare_step() -> str:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["build-sign-notarize-nightly"]["steps"]
    step = next(s for s in steps if s.get("name") == "Prepare pending notarization recovery artifact")
    return re.sub(r"\$\{\{[^}]*\}\}", "fixture", step["run"])


def run_prepare(state_extra: dict[str, str]) -> subprocess.CompletedProcess[str]:
    temp = Path(tempfile.mkdtemp())
    dmg = temp / "cmux-nightly-next-macos-arm64.dmg"
    dmg.write_bytes(b"signed dmg")
    app = temp / "cmux NEXT.app"
    (app / "Contents").mkdir(parents=True)
    (Path(f"{dmg}.notarization.log")).write_text("log\n")
    sha = subprocess.run(["shasum", "-a", "256", str(dmg)], capture_output=True, text=True, check=True).stdout.split()[0]
    state = {
        "submission_id": "fixture-id",
        "status": "In Progress",
        "dmg_path": str(dmg),
        "dmg_sha256": sha,
        "submit_exit": "0",
        "immutable_path": str(temp / "cmux-nightly-next-macos-arm64-1.dmg"),
        "release_tag": "nightly-next",
        "dmg_prefix": "cmux-nightly-next-macos",
        "variant": "arm64",
        "channel": "nightly",
        "output_file": f"{dmg}.notarization.log",
    }
    state.update(state_extra)
    Path(f"{dmg}.notarization.state").write_text("".join(f"{k}={v}\n" for k, v in state.items()))
    env = dict(
        os.environ,
        NIGHTLY_DMG_RELEASE=str(dmg),
        CHANNEL_APP_PATH=str(app),
        CHANNEL="nightly",
        NIGHTLY_VARIANT="arm64",
        CHANNEL_RELEASE_TAG="nightly-next",
        NIGHTLY_BUILD="1",
    )
    result = subprocess.run(["bash", "-c", prepare_step()], cwd=temp, env=env, capture_output=True, text=True)
    result.manifest = temp / "cmux-nightly-notarization-recovery.json"  # type: ignore[attr-defined]
    return result


class NightlyNextNotaryHandoffTests(unittest.TestCase):
    def test_submit_only_state_is_handed_off(self):
        result = run_prepare({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.manifest.read_text())["submission_id"], "fixture-id")

    def test_timed_out_wait_is_handed_off(self):
        result = run_prepare({"submit_exit": "1", "wait_timed_out": "true"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.manifest.read_text())["submission_id"], "fixture-id")

    def test_failed_submit_is_not_handed_off(self):
        result = run_prepare({"submit_exit": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing automatic continuation", result.stderr)
        self.assertFalse(result.manifest.exists())


if __name__ == "__main__":
    unittest.main()
