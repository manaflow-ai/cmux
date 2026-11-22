#!/usr/bin/env python3
"""risk-tier.yml's label step reads the pull request's labels from the event, not from the API.

The step runs on every pull request event into feat-cmux-next (about 283 runs an hour on 2026-11-21 07Z), and
each one asked GitHub for the labels (`gh pr view --json labels`) with the job's GITHUB_TOKEN, though the event
payload it runs on already carries them (after the change, on a labeled or unlabeled event). The test runs the
step's own script with a recording gh and expects only the edits the grade needs.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
FAKE_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GH_LOG"
case "$*" in "pr view"*) printf '%s\\n' $FAKE_LABELS ;; esac
exit 0
"""


def label_step() -> dict:
    for job in yaml.safe_load(WORKFLOW.read_text())["jobs"].values():
        for step in job.get("steps", []):
            if step.get("name") == "Set the risk label":
                return step
    raise AssertionError("risk-tier.yml has no 'Set the risk label' step")


class RiskLabelFromEvent(unittest.TestCase):
    def run_step(self, grade: str, labels: list[str]) -> list[str]:
        root = Path(tempfile.mkdtemp(prefix="risk-label-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "gh").write_text(FAKE_GH)
        (root / "gh").chmod(0o755)
        event = root / "event.json"
        event.write_text(json.dumps({"pull_request": {"number": 7, "labels": [{"name": n} for n in labels]}}))
        env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
        env.update(PATH=f"{root}:{os.environ['PATH']}", GH_LOG=str(root / "gh.log"), FAKE_LABELS=" ".join(labels),
                   GITHUB_EVENT_PATH=str(event), GH_TOKEN="test-token-not-real", REPO="manaflow-ai/cmux",
                   NUMBER="7", LABEL=grade, LABELS_JSON=json.dumps(labels))
        done = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-c", label_step()["run"]], env=env,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        log = root / "gh.log"
        return log.read_text().splitlines() if log.exists() else []

    def test_an_unchanged_tier_makes_no_call(self):
        self.assertEqual(self.run_step("risk:low", ["risk:low", "hold"]), [])

    def test_a_new_tier_swaps_the_label_without_reading_the_labels(self):
        calls = self.run_step("risk:high", ["risk:low"])
        self.assertEqual(calls, ["pr edit 7 --repo manaflow-ai/cmux --remove-label risk:low",
                                 "pr edit 7 --repo manaflow-ai/cmux --add-label risk:high"])


if __name__ == "__main__":
    unittest.main()
