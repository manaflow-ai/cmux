#!/usr/bin/env python3
"""nightly-next's cmux NIGHTLY-identity notary probe (a979, user msg 20276).

The dogfood path for moving nightly-next off cmux NEXT
(com.cmuxterm.app.nightly.cmux-next) onto cmux NIGHTLY (com.cmuxterm.app.nightly).
Only the nightly-next branch can reach the release-next signing secrets, so a
branch dogfood cannot sign this track. A workflow_dispatch on nightly-next with
notary_probe_nightly_identity signs and notarizes the build as cmux NIGHTLY
(cmux.nightly.entitlements, the NIGHTLY Developer ID profile) and publishes
nothing, as the production-identity probe does.

This runs decide's own identity block from nightly.yml in node, with a fake
`core`, for each probe input, and checks the outputs the signing jobs read.
"""
from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")


def identity_block() -> str:
    start = WORKFLOW.index("const channelIdentity = {")
    end = WORKFLOW.index("core.setOutput('icon_name', channelIdentity.iconName);", start)
    return WORKFLOW[start:end] + "core.setOutput('icon_name', channelIdentity.iconName);"


def decide(track: str, env: dict[str, str]) -> dict[str, str]:
    script = (
        "const outputs = {};\n"
        "const core = { setOutput: (k, v) => { outputs[k] = String(v); } };\n"
        f"const track = {json.dumps(track)};\n"
        "const channel = track === 'rc' ? 'rc' : 'nightly';\n"
        "const isNextRef = track === 'nightly-next';\n"
        + identity_block()
        + "\nconsole.log(JSON.stringify(outputs));\n"
    )
    full_env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                "NIGHTLY_NEXT_FEED_BASE": "https://files-next.cmux.com/nightly-next/next", **env}
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, env=full_env, check=True)
    return json.loads(out.stdout)


class NightlyIdentityProbe(unittest.TestCase):
    def test_the_probe_signs_as_cmux_nightly(self):
        out = decide("nightly-next", {"NOTARY_PROBE": "true", "NOTARY_PROBE_IDENTITY": "nightly"})
        self.assertEqual(out["notary_probe"], "true")
        self.assertEqual(out["bundle_id"], "com.cmuxterm.app.nightly")
        self.assertEqual(out["app_name"], "cmux NIGHTLY")
        self.assertEqual(out["url_scheme"], "cmux-nightly")
        self.assertEqual(out["entitlements"], "cmux.nightly.entitlements")
        self.assertEqual(out["sign_channel"], "nightly")
        self.assertEqual(out["profile_channel"], "NIGHTLY")
        # Never a feed: the probe publishes nothing and can never update.
        self.assertEqual(out["feed_base"], "")
        self.assertNotEqual(out["dmg_prefix"], "cmux-nightly-next-macos")

    def test_the_production_probe_is_unchanged(self):
        out = decide("nightly-next", {"NOTARY_PROBE": "true"})
        self.assertEqual(out["bundle_id"], "com.cmuxterm.app")
        self.assertEqual(out["sign_channel"], "stable")
        self.assertEqual(out["profile_channel"], "RELEASE")

    def test_the_input_reaches_decide(self):
        self.assertIn("notary_probe_nightly_identity:", WORKFLOW)
        env = re.search(r"\n\s+NOTARY_PROBE_IDENTITY: ([^\n]+)\n", WORKFLOW)
        self.assertTrue(env, "decide gets no NOTARY_PROBE_IDENTITY")
        self.assertIn("inputs.notary_probe_nightly_identity", env.group(1))
        probe = re.search(r"\n\s+NOTARY_PROBE: ([^\n]+)\n", WORKFLOW).group(1)
        self.assertIn("inputs.notary_probe_nightly_identity", probe)


if __name__ == "__main__":
    unittest.main()
