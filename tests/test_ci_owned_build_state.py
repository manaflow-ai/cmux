#!/usr/bin/env python3
"""Tests for scripts/ci/owned_build_state.py and its compile-admission wiring (no network)."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import owned_build_state as state  # noqa: E402

OWNED = "startsWith(env.CMUX_PRODUCT_RUNNER, 'glaeda-')"


def run(function, *args):
    with unittest.mock.patch("sys.stdout", io.StringIO()), \
         unittest.mock.patch("owned_build_state.subprocess.run") as run_mock:
        run_mock.return_value.returncode = 1  # no `cp -c` here; fall back to a copy
        return function(*args)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.store, self.workspace = base / "store", base / "workspace"
        self.derived = base / "canonical" / "derived-data-compile-admission"
        self.packages = base / "canonical" / "src" / ".ci-source-packages"
        self.workspace.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def keep(self, fingerprint="fp", resolved="r1", ghostty="g1"):
        """A previous job's saved state."""
        (self.derived / "Build").mkdir(parents=True)
        (self.derived / "Build" / "obj.o").write_bytes(b"x" * 10)
        (self.derived / "Logs").mkdir()
        self.packages.mkdir(parents=True)
        (self.packages / "checkouts").mkdir()
        kit = self.workspace / "GhosttyKit.xcframework"
        kit.mkdir()
        (kit / "Info.plist").write_text("kit")
        return run(state.save, self.store, self.derived, self.packages, fingerprint, resolved, ghostty,
                   self.workspace, True)


class Check(Fixture):
    def test_cold_store(self):
        result = run(state.check, self.store, "fp", "r1", "g1", self.workspace)
        self.assertEqual((result["warm"], result["packages"], result["ghosttykit"]), ("false", "false", "false"))

    def test_warm_store_hands_everything_back(self):
        saved = self.keep()
        self.assertEqual(saved, {"derived_data": "true", "packages": "true", "ghosttykit": "true"})
        self.assertFalse((self.store / "derived-data" / "Logs").exists())
        result = run(state.check, self.store, "fp", "r1", "g1", self.workspace)
        self.assertEqual((result["warm"], result["packages"], result["packages_exact"], result["ghosttykit"]),
                         ("true", "true", "true", "true"))
        self.assertTrue((self.workspace / ".ci-source-packages" / "checkouts").is_dir())
        self.assertTrue((self.workspace / "GhosttyKit.xcframework" / "Info.plist").is_file())
        # The DerivedData stays in the store until adopt, after the resolve.
        self.assertTrue((self.store / "derived-data" / "Build" / "obj.o").is_file())

    def test_another_xcode_or_layout_drops_the_derived_data_but_keeps_packages(self):
        self.keep(fingerprint="old")
        result = run(state.check, self.store, "new", "r2", "g2", self.workspace)
        self.assertEqual((result["warm"], result["packages"], result["packages_exact"], result["ghosttykit"]),
                         ("false", "true", "false", "false"))
        self.assertFalse((self.store / "derived-data").exists())

    def test_an_oversized_derived_data_is_dropped(self):
        self.keep()
        with unittest.mock.patch.object(state, "MAX_DERIVED_BYTES", 5):
            result = run(state.check, self.store, "fp", "r1", "g1", self.workspace)
        self.assertEqual(result["warm"], "false")
        self.assertIn("grew", result["reason"])
        self.assertFalse((self.store / "derived-data").exists())

    def test_an_empty_fingerprint_is_never_warm(self):
        self.keep()
        self.assertEqual(run(state.check, self.store, "", "r1", "g1", self.workspace)["warm"], "false")


class AdoptAndSave(Fixture):
    def test_adopt_swaps_the_kept_derived_data_in(self):
        self.keep()
        self.derived.mkdir(parents=True)  # what the resolve step just recreated
        (self.derived / "fresh").write_text("resolve")
        self.assertEqual(run(state.adopt, self.store, self.derived), {"hit": "true"})
        self.assertTrue((self.derived / "Build" / "obj.o").is_file())
        self.assertFalse((self.derived / "fresh").exists())
        self.assertFalse((self.store / "derived-data").exists())

    def test_adopt_without_a_kept_derived_data_is_a_miss(self):
        self.assertEqual(run(state.adopt, self.store, self.derived)["hit"], "false")

    def test_a_failed_compile_keeps_packages_but_not_derived_data(self):
        self.keep()
        run(state.adopt, self.store, self.derived)
        result = run(state.save, self.store, self.derived, self.packages, "fp", "r1", "g1", self.workspace, False)
        self.assertEqual(result["derived_data"], "false")
        self.assertFalse(self.derived.exists())
        self.assertFalse((self.store / "derived-data").exists())
        self.assertNotIn("fingerprint", json.loads((self.store / "stamp.json").read_text()))
        self.assertEqual(run(state.check, self.store, "fp", "r1", "g1", self.workspace)["warm"], "false")

    def test_old_ghosttykit_revisions_are_pruned(self):
        kit = self.workspace / "GhosttyKit.xcframework"
        kit.mkdir()
        for revision in ("a", "b", "c"):
            run(state.save, self.store, self.derived, self.packages, "", "", revision, self.workspace, False)
        kept = sorted(path.name for path in (self.store / "ghosttykit").iterdir())
        self.assertEqual(len(kept), state.KEEP_GHOSTTYKIT_REVISIONS)
        self.assertIn("c", kept)

    def test_main_rejects_wrong_arguments(self):
        with unittest.mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(state.main(["x", "check", "only"]), 2)


class Wiring(unittest.TestCase):
    """Only an owned runner keeps state, and it never uploads it."""

    def setUp(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-macos.yml").read_text())
        self.job = workflow["jobs"]["macos-compile-admission"]
        self.steps = self.job["steps"]
        self.names = [step.get("name") for step in self.steps]
        self.by_id = {step.get("id"): step for step in self.steps if step.get("id")}

    def step(self, name):
        return self.steps[self.names.index(name)]

    def test_state_steps_run_only_on_an_owned_runner(self):
        self.assertIn(OWNED, self.by_id["owned-state"]["if"])
        self.assertIn(OWNED, self.step("Keep this owned Mac's build state")["if"])
        self.assertIn("steps.owned-state.outputs.warm == 'true'", self.by_id["owned-adopt"]["if"])
        for step in (self.by_id["owned-state"], self.by_id["owned-adopt"], self.step("Keep this owned Mac's build state")):
            self.assertIs(step.get("continue-on-error"), True, step["name"])
            self.assertNotIn("uses", step, step["name"])
        self.assertEqual(self.job["env"]["CMUX_OWNED_STATE_ROOT"], "/Users/Shared/cmux-build-fleet/ci")

    def test_a_warm_mac_skips_the_seed_and_the_package_cache(self):
        for step_id in ("seed-derived-data", "swift-package-cache"):
            self.assertIn("steps.owned-state.outputs.", self.by_id[step_id]["if"], step_id)
        self.assertIn("steps.owned-state.outputs.warm != 'true'", self.step("Start the DerivedData seed download")["if"])
        self.assertIn("steps.owned-state.outputs.ghosttykit != 'true'", self.by_id["cache-ghosttykit-admission"]["if"])

    def test_order(self):
        index = self.names.index
        self.assertLess(index("Capture Ghostty revision"), index("Reuse this owned Mac's build state"))
        self.assertLess(index("Reuse this owned Mac's build state"), index("Cache GhosttyKit.xcframework"))
        self.assertLess(index("Resolve Swift packages"), index("Adopt this owned Mac's DerivedData"))
        self.assertLess(index("Adopt the nightly DerivedData seed"), index("Adopt this owned Mac's DerivedData"))
        self.assertLess(index("Adopt this owned Mac's DerivedData"), index("Compile app-host test product"))
        self.assertLess(index("Seed node-local compiled product cache"), index("Keep this owned Mac's build state"))
        self.assertLess(index("Keep this owned Mac's build state"), index("Prepare isolated DerivedData"))
        self.assertIn("steps.owned-adopt.outcome", self.step("Forget the adopted-build inode override")["if"])

    def test_the_save_keeps_only_a_successful_compile(self):
        env = self.step("Keep this owned Mac's build state")["env"]
        self.assertEqual(env["COMPILED"], "${{ steps.hosted-compile.outcome == 'success' }}")
        self.assertTrue(self.step("Keep this owned Mac's build state")["if"].startswith("always()"))


if __name__ == "__main__":
    unittest.main()
