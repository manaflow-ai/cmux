#!/usr/bin/env python3
"""ios-fast-verdict-seed.yml saves the warm DerivedData pr-pipeline.yml's `ios fast verdict` restores on a hosted Mac:
the same key script, the same path at the same workspace, the same FFI. cmux#61812 (2026-11-27): with the FFI cached,
the hosted verdict still built the kit (144 s) and the app (215 s) cold. Owned Macs keep their slot and never read it;
pull requests only restore; the seed saves only on the feat-cmux-next push."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
SEED = WORKFLOWS / "ios-fast-verdict-seed.yml"
KEY_RUN = 'python3 -I scripts/ci/ios_fast_dd_key.py --workspace "$GITHUB_WORKSPACE"'

spec = importlib.util.spec_from_file_location("ios_fast_dd_key", ROOT / "scripts/ci/ios_fast_dd_key.py")
key_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(key_mod)


def load(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def by_name(steps: list[dict], name: str) -> dict:
    return next(s for s in steps if s.get("name") == name)


class IosFastVerdictSeed(unittest.TestCase):
    def setUp(self):
        self.seed = load(SEED)
        self.seed_steps = self.seed["jobs"]["seed"]["steps"]
        self.fast = load(WORKFLOWS / "pr-pipeline.yml")["jobs"]["ios-fast"]["steps"]

    def test_runs_on_the_base_push_and_saves_only_there(self):
        on = self.seed.get("on") or self.seed.get(True)
        self.assertEqual(on["push"]["branches"], ["feat-cmux-next"])
        self.assertNotIn("pull_request", on)
        job = self.seed["jobs"]["seed"]
        self.assertFalse(job["concurrency"]["cancel-in-progress"])
        self.assertEqual(job["runs-on"], "blacksmith-6vcpu-macos-26")
        save = by_name(self.seed_steps, "Save the seed")
        self.assertIn("refs/heads/feat-cmux-next", save["if"])
        self.assertEqual(save["with"]["backend"], "r2")

    def test_seed_and_reader_share_the_key_the_path_and_the_build(self):
        seed_key = by_name(self.seed_steps, "Key")["run"]
        self.assertIn(KEY_RUN, seed_key)
        self.assertIn('DD_ROOT=$RUNNER_TEMP/ios-fast-dd', seed_key)
        reader_key = by_name(self.fast, "iOS fast DerivedData seed key (hosted Mac)")
        self.assertIn(KEY_RUN, reader_key["run"])
        restore = by_name(self.fast, "Restore the seeded iOS fast DerivedData")
        self.assertEqual(restore["uses"], "./.github/actions/cache-restore")
        self.assertEqual(restore["with"]["path"], "${{ runner.temp }}/ios-fast-dd")
        self.assertEqual(restore["with"]["restore-keys"], "${{ steps.dd-key.outputs.prefix }}")
        build = by_name(self.seed_steps, "Build the kit and the app as the verdict does")
        self.assertIn("bash scripts/ci/ios_fast_verdict.sh", build["run"])
        self.assertEqual(build["env"]["PLAN"], '{"tests":[],"build":true,"app":true}')
        # The seed's framework time is the one the reader gives a same-key framework.
        for run in (by_name(self.seed_steps, "Mark the restored CmuxMobileLinkFFI.xcframework as this job's copy")["run"],
                    by_name(self.fast, "Replay the seed's input times")["run"]):
            self.assertIn("touch -h -t 202601010000", run)

    def test_the_reader_is_hosted_only_and_ordered(self):
        names = [s.get("name") for s in self.fast]
        reader_key = by_name(self.fast, "iOS fast DerivedData seed key (hosted Mac)")
        self.assertEqual(reader_key["if"], "${{ steps.xcf-key.outputs.fleet_key != '' }}")  # blacksmith or hosted
        order = ["Restore the fleet-built CmuxMobileLinkFFI.xcframework",
                 "iOS fast DerivedData seed key (hosted Mac)",
                 "Restore the seeded iOS fast DerivedData",
                 "Replay the seed's input times",
                 "Mark the restored CmuxMobileLinkFFI.xcframework as this job's copy",
                 "Build the changed iOS target and run its tests"]
        self.assertEqual([names.index(n) for n in order], sorted(names.index(n) for n in order))
        for name in order[1:4]:
            self.assertTrue(by_name(self.fast, name).get("continue-on-error"), name)  # a miss builds cold
        self.assertFalse(any("cache-save" in str(s.get("uses", "")) for s in self.fast))
        self.assertIn('CMUX_IOS_FAST_DD_ROOT=$root" >> "$GITHUB_ENV"', by_name(self.fast, "Replay the seed's input times")["run"])

    def test_the_verdict_keeps_an_owned_slot_first(self):
        text = (ROOT / "scripts/ci/ios_fast_verdict.sh").read_text()
        slot = text.index('if [[ -n "${CMUX_DERIVED_DATA_SLOT:-}" ]]; then')
        self.assertLess(slot, text.index('elif [[ -n "$dd_root" ]]; then'))
        self.assertIn('-derivedDataPath "$app_dd"', text)

    def test_key_fields_and_due(self):
        prefix = key_mod.prefix("a" * 12, "b" * 12, "/Users/runner/_work/cmux/cmux")
        key = prefix + "202611271200"
        self.assertEqual(key_mod.fields(key)["inputs"], "b" * 12)
        self.assertIsNone(key_mod.fields("cmux-next-fast-v3-swift-x"))
        now = datetime(2026, 11, 27, 15, 0, tzinfo=timezone.utc)
        self.assertFalse(key_mod.due(key, now, 240, "b" * 12))
        self.assertTrue(key_mod.due(key, now, 120, "b" * 12))  # older than the interval
        self.assertTrue(key_mod.due(key, now, 240, "c" * 12))  # another package graph
        self.assertTrue(key_mod.due("", now, 240))  # no seed yet


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
