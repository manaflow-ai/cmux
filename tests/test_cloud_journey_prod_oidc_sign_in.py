#!/usr/bin/env python3
"""The production Cloud journey signs in by its GitHub OIDC token, never a stored Stack password (hq#7076).

The API's production CI_SESSION_TRUST row (backend/apps/api/wrangler.jsonc on feat-cmux-next, cmux#51437) trusts
only a token whose sub is repo:manaflow-ai/cmux:environment:cmux-next-cloud-journey, so the journey job must keep
that environment, ask for id-token: write, run the journey with --sign-in oidc and carry no Stack password.
"""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cloud-journey-prod.yml"


def journey_job() -> str:
    text = WORKFLOW.read_text()
    start = text.index("\n  journey:\n")
    m = re.search(r"\n  [A-Za-z0-9_-]+:\n", text[start + 1 :])
    return text[start : start + 1 + m.start()] if m else text[start:]


class OidcSignInTest(unittest.TestCase):
    def test_keeps_environment_the_trust_row_names(self):
        self.assertRegex(journey_job(), r"\n    environment: cmux-next-cloud-journey\n")

    def test_asks_for_oidc_token(self):
        self.assertRegex(journey_job(), r"\n      id-token: write\n")

    def test_runs_journey_with_oidc_sign_in(self):
        self.assertIn("scripts/cmux-next/cloud-journey.ts --backend prod --sign-in oidc", journey_job())

    def test_no_stored_password_reaches_the_job(self):
        self.assertNotIn("CMUX_DOGFOOD_STACK_PASSWORD", journey_job())
        self.assertNotIn("CMUX_DOGFOOD_STACK_EMAIL", journey_job())


    def test_only_the_codex_stub_skips_the_cold_create(self):
        # The test team's hourly create cap: the codex stub (four runs an hour) leaves out the second create.
        job = journey_job()
        self.assertIn('skip=sync,pause\n', job)
        self.assertIn('if [ "$AGENT" = codex ] && [ "$MODEL" = stub ]; then skip=sync,pause,cold; fi', job)
        self.assertIn('--skip "$skip"', job)


if __name__ == "__main__":
    unittest.main()
