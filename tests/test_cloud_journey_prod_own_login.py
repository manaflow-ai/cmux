#!/usr/bin/env python3
"""The six-hourly real-model Cloud journey signs in with its own Claude login before the shared one.

The repository's CLAUDE_CODE_OAUTH_TOKEN is one login that claude.yml and every journey spend; its weekly
limit turned the real leg into quota skips (run 44649399953, 2026-11-20), so the
cloud-journey-first-text-production probe had no samples. backend.yml's journey-production already reads
CMUX_JOURNEY_CLAUDE_CODE_OAUTH_TOKEN first; this keeps cloud-journey-prod.yml on the same login.
When the gate picks route=machine (the login is spent), the real leg gets no login and runs on the machine's
own model route (SR2) instead of skipping.
"""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cloud-journey-prod.yml"
WANT = (
    "CLAUDE_CODE_OAUTH_TOKEN: ${{ matrix.agent == 'claude' && matrix.model == 'real' && "
    "steps.gate.outputs.route != 'machine' && "
    "(secrets.CMUX_JOURNEY_CLAUDE_CODE_OAUTH_TOKEN || secrets.CLAUDE_CODE_OAUTH_TOKEN) || '' }}"
)


class OwnLoginTest(unittest.TestCase):
    def test_real_leg_prefers_journey_login(self):
        lines = [l.strip() for l in WORKFLOW.read_text().splitlines()]
        self.assertIn(WANT, lines)

    def test_stub_leg_gets_no_login(self):
        # The expression's `|| ''` keeps the stub legs and the Codex rows free of any Claude secret.
        self.assertTrue(WANT.endswith("|| '' }}"))


if __name__ == "__main__":
    unittest.main()
