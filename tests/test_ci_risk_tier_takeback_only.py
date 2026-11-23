#!/usr/bin/env python3
"""risk-tier.yml keeps `risk evidence` red for one thing only: an unowned takeback.

GitHub runs pull_request_target workflows from main's copy, so this file grades every pull request into
feat-cmux-next. Its last step was "Hold high until a person looked" and failed whenever the classifier said
ready=false, with "risk:$TIER is held before merge". On cmux#50477 (run 45031562429) that read as a person hold on a
risk:normal pull request; the real reason, a takeback of #45314, was only in the job summary. It also turned a
BLOCK or a refused sign-off read on a high head red, which the feat-cmux-next copy stopped doing in cmuxterm-hq#5745:
land-judge refuses a BLOCK at the head, and a self or helper review clears it.

Run: python3 tests/test_ci_risk_tier_takeback_only.py
"""

from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
STEP = "Hold only an unowned takeback"
FIX = "If the base is stale, merge it and push; if it's on purpose, add a line `Takes back #45314: <why>`"


def hold_step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]["steps"]
    return next(s for s in steps if s.get("name") == STEP)


class TakebackOnly(unittest.TestCase):
    def run_step(self, tier: str, takes_back: str, fix: str = "") -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
        env.update(TIER=tier, TAKES_BACK=takes_back, TAKES_BACK_FIX=fix, ENFORCE_FROM="2026-10-21T00:00:00Z")
        return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", hold_step()["run"]],
                              env=env, capture_output=True, text=True, timeout=60)

    def test_the_step_runs_only_on_a_held_verdict(self) -> None:
        # A carried verdict (a label the grade never reads, tests/test_ci_risk_tier_label_noise.py) holds nothing.
        self.assertEqual(hold_step()["if"], "steps.carry.outputs.carried != 'true' && steps.grade.outputs.ready != 'true'")

    def test_an_unowned_takeback_is_red_in_any_tier_and_names_the_line_to_paste(self) -> None:
        for tier in ("low", "normal", "high"):
            done = self.run_step(tier, "true", FIX)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            self.assertIn(f"::error::risk:{tier} takes back a recent change. {FIX}", done.stdout)
            self.assertNotIn("held before merge", done.stdout)

    def test_a_block_or_an_unread_sign_off_on_a_high_head_only_warns(self) -> None:
        done = self.run_step("high", "false")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("::warning::risk:high", done.stdout)
        self.assertNotIn("::error::", done.stdout)

    def test_a_base_whose_classifier_predates_the_takeback_output_is_not_held(self) -> None:
        done = self.run_step("normal", "")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_the_step_reads_the_takeback_from_the_grade(self) -> None:
        env = hold_step()["env"]
        self.assertEqual(env["TAKES_BACK"], "${{ steps.grade.outputs.takes_back }}")
        self.assertEqual(env["TAKES_BACK_FIX"], "${{ steps.grade.outputs.takes_back_fix }}")


if __name__ == "__main__":
    unittest.main()
