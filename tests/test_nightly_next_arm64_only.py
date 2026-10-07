#!/usr/bin/env python3
"""nightly-next publishes arm64 only; classic NIGHTLY and RC keep arm64, x86_64 and universal.

The nightly-next feed's legacy names (cmux-nightly-next-macos.dmg, appcast.xml) carry the arm64
build and its deltas, and every nightly-next item requires arm64 hardware, so Intel Macs keep
their last build. Dropping the universal leg also drops its sign and notarize time (9.5 min, the
longest of the three on beb1773b2fb) from green push to appcast live.
"""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"


class Arm64Only(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.jobs = yaml.safe_load(cls.text)["jobs"]

    def step(self, job, name):
        return next(s for s in self.jobs[job]["steps"] if s.get("name") == name)

    def test_decide_builds_only_arm64_for_nightly_next(self):
        script = self.step("decide", "Decide whether a nightly build is needed")["with"]["script"]
        self.assertIn("const arm64Only = fastBuild || track === 'nightly-next';", script)
        self.assertIn("const variants = arm64Only ? ['arm64'] : ['arm64', 'x86_64', 'universal'];", script)
        self.assertIn("core.setOutput('legacy_variant', arm64Only ? 'arm64' : 'universal');", script)

    def test_every_nightly_next_appcast_requires_arm64(self):
        expression = "${{ needs.decide.outputs.track == 'nightly-next' && 'arm64' || '' }}"
        for job, step in (("build-sign-notarize-nightly", "Generate Sparkle appcasts (nightly)"),):
            self.assertEqual(self.step(job, step)["env"]["SPARKLE_HARDWARE_REQUIREMENTS"], expression)
        self.assertEqual(self.jobs["generate-nightly-deltas"]["env"]["SPARKLE_HARDWARE_REQUIREMENTS"], expression)

    def test_legacy_names_follow_the_legacy_variant(self):
        run = self.step("publish-nightly", "Assemble legacy nightly names")["run"]
        self.assertIn('cp "${CHANNEL_DMG_PREFIX}-${NIGHTLY_LEGACY_VARIANT}.dmg" "${CHANNEL_DMG_PREFIX}.dmg"', run)
        self.assertIn('cp "appcast-arm64.xml" appcast.xml', run)
        delta = self.step("generate-nightly-deltas", "Generate one from-version delta and revised appcast")["run"]
        self.assertIn('NIGHTLY_LEGACY_VARIANT', delta)

    def test_publish_sends_only_the_built_variants(self):
        run = self.step("publish-nightly", "Publish nightly release assets")["run"]
        self.assertIn('for variant in $(jq -r', run)
        self.assertNotIn('--immutable "nightly-out/${CHANNEL_DMG_PREFIX}-x86_64-${NIGHTLY_BUILD}.dmg"', run)
        guard = self.step("publish-nightly", "Guard nightly-next publication")["run"]
        self.assertIn("for appcast in nightly-out/appcast*.xml; do", guard)


if __name__ == "__main__":
    unittest.main()
