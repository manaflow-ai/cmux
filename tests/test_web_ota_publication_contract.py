#!/usr/bin/env python3
"""Keep the web OTA channel and publication contracts in sync.

This is deliberately a source test: a missing pointer writer is otherwise easy to
hide behind a valid setting enum, and a missing read-back check leaves a green
workflow with an unverified object.
"""
import ast
import json
import os
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-web-bundle-publish.yml"
POINTER = ROOT / "scripts/cmux-next/web-ota-pointer.py"
UPDATER = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/WebUpdates/WebUpdater.swift"
WEB_SCHEMA = ROOT / "schemas/settings/source/updates.json"
KEY = ROOT / "scripts/cmux-next/web-bundle-key.py"


class WebOTAPublicationContractTests(unittest.TestCase):
    def test_every_supported_channel_has_a_writer_and_readback(self):
        pointer = POINTER.read_text()
        channels = ast.literal_eval(re.search(r"^CHANNELS = (\(.+?\))$", pointer, re.M).group(1))
        self.assertEqual(channels, ("every-merge", "nightly"))

        updater = UPDATER.read_text()
        enum = re.search(r"enum Channel:.*?\{(.*?)\n    \}", updater, re.S).group(1)
        app_channels = set(re.findall(r"^        case (\w+)(?: = \"([^\"]+)\")?", enum, re.M))
        app_values = {raw or name for name, raw in app_channels}
        self.assertEqual(app_values, {"off", "every-merge", "nightly"})
        self.assertEqual(set(channels), app_values - {"off"})

        workflow = WORKFLOW.read_text()
        pointer_job = workflow.split("\n  pointer:\n", 1)[1]
        self.assertIn("github.ref_name == 'nightly-next' && 'nightly' || 'every-merge'", pointer_job)
        for channel in channels:
            self.assertIn('--channel "$CHANNEL"', pointer_job)
            self.assertIn('"cmux-next-web/ota/$CHANNEL.json"', pointer_job)
            self.assertIn('/cmux-next-web/ota/$CHANNEL.json?check=', pointer_job)

    def test_nightly_channel_has_a_promoted_branch_writer(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("branches: [feat-cmux-next, nightly-next]", workflow)
        self.assertIn("github.ref_name == 'nightly-next' && 'nightly'", workflow)
        settings = json.loads(WEB_SCHEMA.read_text())
        web = next(row for group in settings["lists"] for row in group["rows"] if row.get("key") == "updates.web")
        self.assertIn("nightly", {choice["value"] for choice in web["choices"]})

    def test_missing_production_signing_key_fails(self):
        pointer_job = WORKFLOW.read_text().split("\n  pointer:\n", 1)[1]
        guard = re.search(r'if \[\[ -z "\$SIGNING_KEY" \]\]; then(.*?)\n          fi', pointer_job, re.S)
        self.assertIsNotNone(guard)
        body = guard.group(1)
        self.assertIn("::error::", body)
        self.assertRegex(body, r"exit 1")
        self.assertNotIn("no web update pointer", body)

    def test_missing_outputs_digest_cannot_make_production_green(self):
        pointer_job = WORKFLOW.read_text().split("\n  pointer:\n", 1)[1]
        self.assertIn('[[ $rc == 0 ]] || exit "$rc"', pointer_job)
        self.assertNotIn("has no outputs digest; no web update pointer", pointer_job)

    def test_toolchain_change_moves_source_identity(self):
        namespace = {}
        exec(compile(KEY.read_text(), str(KEY), "exec"), namespace)
        old = os.environ.get("CMUX_WEB_BUN_VERSION")
        try:
            os.environ["CMUX_WEB_BUN_VERSION"] = "1.4.4"
            first = namespace["source_key"](str(ROOT))
            os.environ["CMUX_WEB_BUN_VERSION"] = "9.9.9"
            second = namespace["source_key"](str(ROOT))
        finally:
            if old is None:
                os.environ.pop("CMUX_WEB_BUN_VERSION", None)
            else:
                os.environ["CMUX_WEB_BUN_VERSION"] = old
        self.assertNotEqual(first, second)

    def test_same_toolchain_manifest_is_reused_across_runtime_prefixes(self):
        namespace = {}
        exec(compile(KEY.read_text(), str(KEY), "exec"), namespace)
        matches = namespace["manifest_matches_toolchain"]
        self.assertTrue(matches({"bun": "1.4.4", "node": "v24.22.1"}, "1.4.4", "24.22.1"))
        self.assertFalse(matches({"bun": "1.4.3", "node": "v24.22.1"}, "1.4.4", "24.22.1"))

    def test_workflow_pins_identity_and_records_manifest_toolchain(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('CMUX_WEB_NODE_VERSION: "24.22.1"', workflow)
        self.assertIn('bun-version: "1.4.4"', workflow)
        self.assertIn('node-version: ${{ env.CMUX_WEB_NODE_VERSION }}', workflow)
        self.assertIn('"bun": normalize(subprocess.run(["bun", "--version"]', workflow)
        self.assertIn('"node": normalize(subprocess.run(["node", "--version"]', workflow)
        self.assertIn('manifest_matches_toolchain"]', workflow)

    def test_toolchain_mismatch_fails_immutable_manifest_reuse(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('echo "::error::the existing manifest for $key has a different Bun/Node toolchain; refusing immutable-key publication"', workflow)
        self.assertIn('exit 1\n          fi', workflow)


if __name__ == "__main__":
    unittest.main()
