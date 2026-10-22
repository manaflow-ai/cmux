#!/usr/bin/env python3
"""Dry run of publish-nightly's "Require every DMG to match a tested digest".

The step publishes only DMGs whose sha256 a verify job recorded in
tested/*.sha256 (`<sha256>  <name>` lines). This runs the step's own `run:`
block from nightly.yml, unchanged, against fixture DMGs, so a pull request that
breaks it (or the digest line format the verify jobs write) fails here and not
in the nightly.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"
JOB = "publish-nightly"
STEP = "Require every DMG to match a tested digest"


# The verify jobs that write tested/*.sha256, and the line each writes.
WRITERS = (("verify-final-dmg-nightly", "Smoke final DMG"),
           ("verify-recovered-nightly-next", "Smoke the recovered DMG"))
TESTED_LINE = 'printf \'%s  %s\\n\' "$actual" "$(basename "$dmg")"'


def step_script(job: str = JOB, name: str = STEP) -> str:
    workflow = yaml.safe_load(NIGHTLY.read_text(encoding="utf-8"))
    for step in workflow["jobs"][job]["steps"]:
        if step.get("name") == name:
            return step["run"]
    raise AssertionError(f"nightly.yml job {job} has no step {name!r}")


def tested_line(path: Path) -> str:
    # TESTED_LINE, as the verify jobs write it.
    return f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"


class TestedDmgGateTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name)
        (self.work / "nightly-out").mkdir()
        (self.work / "tested").mkdir()
        (self.work / "runner-temp").mkdir()
        self.script = self.work / "step.sh"
        self.script.write_text(step_script(), encoding="utf-8")

    def dmg(self, name: str, content: str) -> Path:
        path = self.work / "nightly-out" / name
        path.write_text(content, encoding="utf-8")
        return path

    def run_step(self) -> subprocess.CompletedProcess:
        env = dict(os.environ, RUNNER_TEMP=str(self.work / "runner-temp"))
        return subprocess.run(["bash", str(self.script)], cwd=self.work, env=env,
                              capture_output=True, text=True, timeout=60)

    def test_verify_jobs_write_the_line_format_this_test_uses(self) -> None:
        for job, name in WRITERS:
            self.assertIn(TESTED_LINE, step_script(job, name), f"{job} / {name}")

    def test_publishes_when_every_dmg_was_tested(self) -> None:
        arm = self.dmg("cmux-nightly-next-macos-arm64.dmg", "arm64 bytes")
        universal = self.dmg("cmux-nightly-next-macos-universal.dmg", "universal bytes")
        (self.work / "tested" / "tested-arm64.sha256").write_text(tested_line(arm))
        (self.work / "tested" / "tested-universal.sha256").write_text(tested_line(universal))
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("All 2 DMGs match", result.stdout)

    def test_refuses_a_dmg_whose_bytes_changed(self) -> None:
        arm = self.dmg("cmux-nightly-next-macos-arm64.dmg", "arm64 bytes")
        (self.work / "tested" / "tested-arm64.sha256").write_text(tested_line(arm))
        arm.write_text("bytes nobody launched", encoding="utf-8")
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not a DMG that a verify job tested", result.stderr)

    def test_refuses_a_dmg_no_verify_job_tested(self) -> None:
        arm = self.dmg("cmux-nightly-next-macos-arm64.dmg", "arm64 bytes")
        self.dmg("cmux-nightly-next-macos-x86_64.dmg", "untested bytes")
        (self.work / "tested" / "tested-arm64.sha256").write_text(tested_line(arm))
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmux-nightly-next-macos-x86_64.dmg", result.stderr)

    def test_refuses_to_publish_nothing(self) -> None:
        (self.work / "tested" / "tested-arm64.sha256").write_text("")
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no DMG to publish", result.stderr)


if __name__ == "__main__":
    unittest.main()
