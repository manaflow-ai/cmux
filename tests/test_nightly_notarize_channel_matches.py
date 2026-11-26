#!/usr/bin/env python3
"""Every nightly notarize step checks the bundle against the channel the build was signed for.

Nightly macOS build 45798252585 (nightly-next 4871e79562, 2026-11-26) published NIGHTLY 4579825258501, then
failed `sign-live-code-variant` at "Notarize the variant and its DMG": `error: CFBundleName expected
'cmux NEXT', found 'cmux NIGHTLY'`. The nightly-next track ships as cmux NIGHTLY (decide's sign_channel),
but the variant's step pinned CMUX_CHANNEL to the literal `next`, so its metadata check expected the old
name and the live code variant was never published.

Run it yourself after changing a notarize step: python3 tests/test_nightly_notarize_channel_matches.py
(under a second, no network).
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
JOBS = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]


def notarize_steps():
    for job_name, job in JOBS.items():
        for step in job.get("steps", []):
            if "notarize-nightly-dmg.sh" in (step.get("run") or ""):
                yield job_name, step


class NotarizeChannelTest(unittest.TestCase):
    def test_there_are_notarize_steps(self) -> None:
        self.assertTrue(list(notarize_steps()))

    def test_no_notarize_step_pins_a_literal_channel(self) -> None:
        for job_name, step in notarize_steps():
            channel = str((step.get("env") or {}).get("CMUX_CHANNEL", ""))
            with self.subTest(job=job_name, step=step.get("name")):
                self.assertIn("needs.decide.outputs.", channel,
                              f"{job_name} checks the bundle as {channel!r}, not the channel decide signed it for")

    def test_the_live_code_variant_uses_the_sign_channel(self) -> None:
        steps = [s for j, s in notarize_steps() if j == "sign-live-code-variant"]
        self.assertTrue(steps)
        for step in steps:
            self.assertEqual(step["env"]["CMUX_CHANNEL"], "${{ needs.decide.outputs.sign_channel }}")


if __name__ == "__main__":
    unittest.main()
