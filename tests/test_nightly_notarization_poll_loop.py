#!/usr/bin/env python3
"""Keep nightly notarization polling from repeating artifact verification."""

from __future__ import annotations

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"


class NightlyNotarizationPollLoopTests(unittest.TestCase):
    def test_recovery_is_resolved_once_before_status_polling(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        poll_steps = workflow["jobs"]["poll"]["steps"]
        poll_run = next(step["run"] for step in poll_steps if step.get("id") == "poll")

        resolver = "scripts/ci/resolve-notarization-recovery.py"
        self.assertEqual(poll_run.count(resolver), 1)
        resolve_at = poll_run.index(resolver)
        loop_at = poll_run.index("while :; do")
        self.assertLess(resolve_at, loop_at)
        self.assertIn("--strict --extract-app", poll_run)
        self.assertIn("recovery-$variant.state-file", poll_run)
        self.assertLess(poll_run.index("state-file", resolve_at), loop_at)
        self.assertGreater(poll_run.index("cat \"$RUNNER_TEMP/recovery-$variant.state-file\"", loop_at), loop_at)

        # Polling remains fail-closed: only an explicit Accepted result admits
        # stapling, while query failures and terminal statuses stop the job.
        self.assertIn("0) ;;", poll_run)
        self.assertIn("2) pending=true ;;", poll_run)
        self.assertIn("*) terminal_failure=true ;;", poll_run)
        self.assertIn('if [ "$terminal_failure" = true ]; then', poll_run)
        self.assertIn('if [ "$pending" = false ]; then', poll_run)

    def test_staple_job_keeps_final_exact_artifact_resolution(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        staple_steps = workflow["jobs"]["wait-and-staple"]["steps"]
        resolve_run = next(
            step["run"] for step in staple_steps if step.get("name") == "Resolve manifest and verify exact DMG"
        )
        self.assertIn("scripts/ci/resolve-notarization-recovery.py", resolve_run)
        self.assertIn("--strict --extract-app", resolve_run)
        self.assertIn('> "$RUNNER_TEMP/recovery.env"', resolve_run)
        staple_run = next(
            step["run"] for step in staple_steps if step.get("name") == "Wait, staple, and validate exact submitted DMG"
        )
        self.assertIn('"$DMG_RELEASE"', staple_run)
        self.assertIn('"verified/$IMMUTABLE_NAME"', staple_run)


if __name__ == "__main__":
    unittest.main()
